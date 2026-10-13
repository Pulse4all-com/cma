/**
 * What an adapter may ask the database during a read-back, and how its results are written.
 *
 * Reads (short transactions as the tenant's Ingest user, row-level security applies):
 *   config()                    cma.connection_config(): field mapping, pipelines, settings
 *   heldContacts(ids)           the contacts the CMA holds or a record points to (0006's rule: the
 *                               contact base is never mirrored, so other contacts are not read back)
 *   recordContacts(type, ids)   the contact each record points to now
 *   currentAssociations(type, ids)   the stored, current associations from these objects
 *   tenantSlug()                for the per-tenant hash pepper's secret name
 *
 * For the jobs (brief B8), each its own short transaction:
 *   settings()                  the tenant's settings (cma.tenant_settings(): catalog defaults and values)
 *   tenantStartOf(date)         00:00 of a business date in the tenant's zone, as an instant
 *   cursor(stream), setCursor(stream, value)   cma.ingest_cursor_get / _set
 *   runStart(job, stream, from, to), runFinish(id, status, counts, error)   one sync_run row per run
 *   forms(), upsertForms(items), upsertSubmissions(items)   the form catalog and submissions
 *   recordsWithoutContact(maxAge)   cma.ingest_records_without_contact (the sweeper's second read)
 *   heldContactIds(after, limit)    the contacts the CMA holds, by id, for the contact backfill
 *   linkCalls(since)            cma.link_calls (migration 0007a), tenant-wide
 *
 * For a commerce source (migrations 0007b, 0008h):
 *   crmConnection(id)           the CRM connection a store's customers are matched to (settings
 *                               crm_connection_id), active, same tenant: its adapter and secret names
 *   refProperties(id, system)   that CRM connection's contact properties holding ids of a ref system
 *                               (connection fields: entity contact, field ref)
 *   customerLinks(ids)          the store customers' current contact links (0008h)
 *   heldRefContacts({...})      the contacts the CMA holds whose refs hold a customer id (crm_contact_ref)
 *   connectionKey()             the connection's key (the address of its webhooks; an identifier)
 *
 * For the outbox job (migration 0007c): outboxClaim(limit), outboxFinish(groups).
 *
 * For a telephony source (migration 0007a):
 *   lineMarkets(numberRefs)     the market configured on each of these lines (telephony_number)
 *   firstMarket()               the tenant's first active market (sort order, then code)
 *   lineCount()                 how many lines the connection's catalog holds
 *
 * Writes: a read-back answers units, one per object it read ({ eventIds, status, error?, writes }); a
 * unit's writes.alerts names the records that arrived by a created event, for cma.ingest_record_alerts;
 * writes.assignments names every record read back, for cma.ingest_assignment_alerts (0008a);
 * writes.telephonyTags and telephonyNumbers refresh the telephony catalogs (each the whole list),
 * writes.telephonyCalls upserts telephony calls, writes.commerceCustomers and commerceOrders upsert a
 * store's customers and orders (0007b, 0008g), writes.contactLinks sets or clears a customer's CRM
 * contact link ({ customerId, crmConnectionId, contactId }, cma.set_commerce_customer_contact of
 * 0008h) after them, writes.writebacks enqueues CRM contact write-backs ({ connectionId, contactId,
 * values, reason }, cma.enqueue_contact_writeback of 0007c; generic, no commerce use since 0008h),
 * writes.forgets runs a CRM privacy deletion (0007, and the commerce links to the contact, 0008h),
 * writes.tally adds named counts to the run's counts (no ids), writes.cursors moves sync cursors in
 * the same transaction as the writes they describe.
 * applyUnits() writes all units in one transaction and finishes their events; when that fails it
 * writes unit by unit, so one bad object fails its own events only.
 */
import { withTenant, dbErrorCode } from "./db.mjs";
import { chunks, finishEvents } from "./events.mjs";

const slugs = new Map();

export function storeFor(ctx, connectionId) {
  return {
    async config() {
      return withTenant(ctx, async (q) => (await q.query("select cma.connection_config($1) as c", [connectionId])).rows[0].c);
    },
    async heldContacts(ids) {
      if (!ids.length) return new Set();
      return withTenant(ctx, async (q) => {
        const r = await q.query(
          `select source_id from cma.crm_contact
            where tenant_id = cma.current_tenant_id() and connection_id = $1 and source_id = any ($2::text[])
           union
           select contact_source_id from cma.crm_record
            where tenant_id = cma.current_tenant_id() and connection_id = $1 and contact_source_id = any ($2::text[])`,
          [connectionId, ids]);
        return new Set(r.rows.map((x) => x.source_id));
      });
    },
    async recordContacts(recordType, ids) {
      if (!ids.length) return new Map();
      return withTenant(ctx, async (q) => {
        const r = await q.query(
          `select source_id, contact_source_id from cma.crm_record
            where tenant_id = cma.current_tenant_id() and connection_id = $1 and record_type = $2 and source_id = any ($3::text[])`,
          [connectionId, recordType, ids]);
        return new Map(r.rows.map((x) => [x.source_id, x.contact_source_id]));
      });
    },
    async currentAssociations(fromType, ids) {
      if (!ids.length) return [];
      return withTenant(ctx, async (q) => {
        const r = await q.query(
          `select from_type, from_id, to_type, to_id from cma.crm_association
            where tenant_id = cma.current_tenant_id() and connection_id = $1 and from_type = $2
              and from_id = any ($3::text[]) and removed_at is null`,
          [connectionId, fromType, ids]);
        return r.rows.map((x) => ({ fromType: x.from_type, fromId: x.from_id, toType: x.to_type, toId: x.to_id }));
      });
    },
    async tenantSlug() {
      if (slugs.has(ctx.tenantId)) return slugs.get(ctx.tenantId);
      const slug = await withTenant(ctx, async (q) =>
        (await q.query("select slug from cma.tenant where id = cma.current_tenant_id()")).rows[0]?.slug ?? null);
      if (slug) slugs.set(ctx.tenantId, slug);
      return slug;
    },
    async settings() {
      return withTenant(ctx, async (q) =>
        Object.fromEntries((await q.query("select key, value from cma.tenant_settings()")).rows.map((r) => [r.key, r.value])));
    },
    async tenantStartOf(date) {
      return withTenant(ctx, async (q) => (await q.query(
        "select ($1::date::timestamp at time zone t.timezone) as at from cma.tenant t where t.id = cma.current_tenant_id()", [date])).rows[0]?.at ?? null);
    },
    async cursor(stream) {
      return withTenant(ctx, async (q) => (await q.query("select cma.ingest_cursor_get($1, $2) as c", [connectionId, stream])).rows[0].c);
    },
    async setCursor(stream, value) {
      await withTenant(ctx, (q) => q.query("select cma.ingest_cursor_set($1, $2, $3::jsonb)", [connectionId, stream, JSON.stringify(value)]));
    },
    async runStart(job, stream, from = null, to = null) {
      return withTenant(ctx, async (q) => (await q.query("select cma.ingest_sync_run_start($1, $2, $3, $4, $5) as id",
        [connectionId, job, stream, from, to])).rows[0].id);
    },
    async runFinish(id, status, counts, error = null) {
      await withTenant(ctx, (q) => q.query("select cma.ingest_sync_run_finish($1, $2, $3::jsonb, $4)", [id, status, JSON.stringify(counts), error]));
    },
    async forms() {
      return withTenant(ctx, async (q) => (await q.query(
        `select source_form_id, name, is_counted, kept_fields, status from cma.connection_form
          where tenant_id = cma.current_tenant_id() and connection_id = $1 order by source_form_id`, [connectionId])).rows.map((r) => ({
        formId: r.source_form_id, name: r.name, isCounted: r.is_counted, keptFields: r.kept_fields ?? [], status: r.status,
      })));
    },
    async upsertForms(items) {
      return withTenant(ctx, async (q) => (await q.query("select cma.ingest_upsert_forms($1, $2::jsonb) as n", [connectionId, JSON.stringify(items)])).rows[0].n);
    },
    async upsertSubmissions(items) {
      const counts = {};
      for (const part of chunks(items)) {
        await withTenant(ctx, async (q) => {
          const r = await q.query("select outcome from cma.ingest_upsert_form_submissions($1, $2::jsonb)", [connectionId, JSON.stringify(part)]);
          for (const row of r.rows) counts[row.outcome] = (counts[row.outcome] ?? 0) + 1;
        });
      }
      return counts;
    },
    async recordsWithoutContact(maxAge = "1 hour") {
      return withTenant(ctx, async (q) => (await q.query(
        "select record_type, source_id from cma.ingest_records_without_contact($1, $2::interval)", [connectionId, maxAge])).rows
        .map((r) => ({ recordType: r.record_type, sourceId: r.source_id })));
    },
    async heldContactIds(after = null, limit = 500) {
      return withTenant(ctx, async (q) => (await q.query(
        `select id from (
           select source_id as id from cma.crm_contact
            where tenant_id = cma.current_tenant_id() and connection_id = $1 and source_deleted_at is null
           union
           select contact_source_id from cma.crm_record
            where tenant_id = cma.current_tenant_id() and connection_id = $1 and contact_source_id is not null and source_deleted_at is null
         ) h where $2::text is null or id > $2::text order by id limit $3`, [connectionId, after, limit])).rows.map((r) => r.id));
    },
    async linkCalls(since) {
      return withTenant(ctx, async (q) => (await q.query("select cma.link_calls($1) as n", [since])).rows[0].n);
    },
    async crmConnection(id) {
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(String(id ?? ""))) return null;
      return withTenant(ctx, async (q) => {
        const c = (await q.query(
          `select id, adapter, external_account_id, signing_secret_name, token_secret_name from cma.integration_connection
            where tenant_id = cma.current_tenant_id() and id = $1 and status = 'active'`, [id])).rows[0];
        return c ? { tenantId: ctx.tenantId, connectionId: c.id, adapter: c.adapter, externalAccountId: c.external_account_id,
          signingSecretName: c.signing_secret_name, tokenSecretName: c.token_secret_name, ingestUserId: ctx.userId } : null;
      });
    },
    async refProperties(crmConnectionId, refSystem) {
      return withTenant(ctx, async (q) => (await q.query(
        `select source_property from cma.connection_field
          where tenant_id = cma.current_tenant_id() and connection_id = $1 and entity = 'contact' and field = 'ref' and ref_system = $2
          order by slot`, [crmConnectionId, refSystem])).rows.map((r) => r.source_property));
    },
    async customerLinks(customerIds) {
      if (!customerIds.length) return new Map();
      return withTenant(ctx, async (q) => new Map((await q.query(
        `select source_id, crm_connection_id, crm_contact_source_id from cma.commerce_customer
          where tenant_id = cma.current_tenant_id() and connection_id = $1 and source_id = any ($2::text[]) and crm_contact_source_id is not null`,
        [connectionId, customerIds])).rows.map((r) => [r.source_id, { crmConnectionId: r.crm_connection_id, contactId: r.crm_contact_source_id }])));
    },
    async heldRefContacts({ crmConnectionId, refSystem, customerId }) {
      return withTenant(ctx, async (q) => (await q.query(
        `select distinct k.source_id from cma.crm_contact_ref r
           join cma.crm_contact k on k.tenant_id = r.tenant_id and k.id = r.contact_id
          where r.tenant_id = cma.current_tenant_id() and k.connection_id = $1 and r.system = $2 and r.external_id = $3
            and k.source_deleted_at is null
          order by 1 limit 3`, [crmConnectionId, refSystem, customerId])).rows.map((r) => r.source_id));
    },
    async connectionKey() {
      return withTenant(ctx, async (q) => (await q.query(
        "select key from cma.integration_connection where tenant_id = cma.current_tenant_id() and id = $1", [connectionId])).rows[0]?.key ?? null);
    },
    async outboxClaim(limit = 50) {
      return withTenant(ctx, async (q) => (await q.query(
        "select action_id, action, target_type, target_id, payload, reason, attempts from cma.outbox_claim($1, $2)", [connectionId, limit])).rows);
    },
    async outboxFinish(groups) {
      let n = 0;
      await withTenant(ctx, async (q) => {
        for (const g of groups) {
          if (!g.ids.length) continue;
          const r = await q.query("select cma.outbox_finish($1::uuid[], $2, $3::jsonb, $4) as n",
            [g.ids, g.outcome, g.result ? JSON.stringify(g.result) : null, g.outcome === "failed" ? (g.error ?? "failed") : null]);
          n += r.rows[0].n;
        }
      });
      return n;
    },
    async lineMarkets(numberRefs) {
      if (!numberRefs.length) return new Map();
      return withTenant(ctx, async (q) => new Map((await q.query(
        `select number_ref, market from cma.telephony_number
          where tenant_id = cma.current_tenant_id() and connection_id = $1 and number_ref = any ($2::text[]) and market is not null`,
        [connectionId, numberRefs])).rows.map((r) => [r.number_ref, r.market])));
    },
    async firstMarket() {
      return withTenant(ctx, async (q) => (await q.query(
        "select code from cma.market where tenant_id = cma.current_tenant_id() and status = 'active' order by sort_order, code limit 1")).rows[0]?.code ?? null);
    },
    async lineCount() {
      return withTenant(ctx, async (q) => Number((await q.query(
        "select count(*) as n from cma.telephony_number where tenant_id = cma.current_tenant_id() and connection_id = $1", [connectionId])).rows[0].n));
    },
  };
}

const ORDER = [
  ["pipelines", "select cma.ingest_upsert_pipelines($1, $2::jsonb) as n", false],
  ["callOutcomes", "select cma.ingest_upsert_call_outcomes($1, $2::jsonb) as n", false],
  ["records", "select outcome from cma.ingest_upsert_records($1, $2::jsonb)", true],
  ["contacts", "select outcome from cma.ingest_upsert_contacts($1, $2::jsonb)", true],
  ["calls", "select outcome from cma.ingest_upsert_calls($1, $2::jsonb)", true],
  ["associations", "select outcome from cma.ingest_upsert_associations($1, $2::jsonb)", true],
  ["telephonyTags", "select cma.ingest_upsert_telephony_catalog($1, 'tag', $2::jsonb) as n", false],
  ["telephonyNumbers", "select cma.ingest_upsert_telephony_catalog($1, 'number', $2::jsonb) as n", false],
  ["telephonyCalls", "select outcome from cma.ingest_upsert_telephony_calls($1, $2::jsonb)", true],
  ["commerceCustomers", "select outcome from cma.ingest_upsert_commerce_customers($1, $2::jsonb)", true],
  ["commerceOrders", "select outcome from cma.ingest_upsert_commerce_orders($1, $2::jsonb)", true],
];

// The links of one batch, the last one per customer: after the customers they belong to (0008h)
async function writeContactLinks(q, connectionId, units, counts) {
  const last = new Map();
  for (const l of units.flatMap((u) => u.writes?.contactLinks ?? [])) last.set(l.customerId, l);
  for (const l of last.values()) {
    const r = await q.query("select cma.set_commerce_customer_contact($1, $2, $3, $4) as outcome",
      [connectionId, l.customerId, l.contactId ? l.crmConnectionId : null, l.contactId ?? null]);
    const k = `link_${r.rows[0].outcome}`;
    counts[k] = (counts[k] ?? 0) + 1;
  }
}

async function writeAll(q, connectionId, units, counts) {
  for (const [kind, sql, chunked] of ORDER) {
    const items = units.flatMap((u) => u.writes?.[kind] ?? []);
    if (!items.length) continue;
    for (const part of chunked ? chunks(items) : [items]) {
      const r = await q.query(sql, [connectionId, JSON.stringify(part)]);
      if (chunked) for (const row of r.rows) counts[row.outcome] = (counts[row.outcome] ?? 0) + 1;
    }
  }
  await writeContactLinks(q, connectionId, units, counts);
  // CRM write-backs (0007c) after the facts they describe; one per contact and reason in this batch
  const seen = new Set();
  for (const w of units.flatMap((u) => u.writes?.writebacks ?? []).reverse()) {
    const k = `${w.connectionId}|${w.contactId}|${w.reason}`;
    if (seen.has(k)) continue;
    seen.add(k);
    const r = await q.query("select cma.enqueue_contact_writeback($1, $2, $3::jsonb, $4) as id", [w.connectionId, w.contactId, JSON.stringify(w.values), w.reason]);
    if (r.rows[0]?.id) counts.writebacks = (counts.writebacks ?? 0) + 1;
  }
  for (const t of units.map((u) => u.writes?.tally).filter(Boolean)) {
    for (const [k, v] of Object.entries(t)) if (typeof v === "number") counts[k] = (counts[k] ?? 0) + v;
  }
  for (const c of units.flatMap((u) => u.writes?.cursors ?? [])) {
    await q.query("select cma.ingest_cursor_set($1, $2, $3::jsonb)", [connectionId, c.stream, JSON.stringify(c.cursor)]);
  }
  for (const contactId of units.flatMap((u) => u.writes?.forgets ?? [])) {
    await q.query("select cma.ingest_contact_forget($1, $2)", [connectionId, contactId]);
    // the commerce customers linked to the contact lose the link too (0008h)
    const r = await q.query("select cma.forget_commerce_contact_links($1, $2) as n", [connectionId, contactId]);
    counts.forgotten = (counts.forgotten ?? 0) + 1;
    counts.linksForgotten = (counts.linksForgotten ?? 0) + Number(r.rows[0]?.n ?? 0);
  }
  // Record alerts (migration 0008): after the records are in, per record type, at most 500 ids a call;
  // the function resolves the rules and recipients and writes nothing for a record already alerted
  const alerts = units.flatMap((u) => u.writes?.alerts ?? []);
  const byType = new Map();
  for (const a of alerts) byType.set(a.recordType, [...(byType.get(a.recordType) ?? []), a.sourceId]);
  for (const [recordType, ids] of byType) {
    for (const part of chunks([...new Set(ids)])) {
      const r = await q.query("select cma.ingest_record_alerts($1, $2, $3::text[]) as n", [connectionId, recordType, part]);
      counts.alerts = (counts.alerts ?? 0) + Number(r.rows[0]?.n ?? 0);
    }
  }
  // Assignment alerts (0008a): per record type, the owner's person, once per record and owner
  const assignedByType = new Map();
  for (const a of units.flatMap((u) => u.writes?.assignments ?? [])) assignedByType.set(a.recordType, [...(assignedByType.get(a.recordType) ?? []), a.sourceId]);
  for (const [recordType, ids] of assignedByType) {
    for (const part of chunks([...new Set(ids)])) {
      const r = await q.query("select cma.ingest_assignment_alerts($1, $2, $3::text[]) as n", [connectionId, recordType, part]);
      counts.assignments = (counts.assignments ?? 0) + Number(r.rows[0]?.n ?? 0);
    }
  }
}

function finishGroups(units, override = null) {
  const groups = new Map();
  for (const u of units) {
    const status = override?.status ?? u.status;
    const error = override?.error ?? u.error ?? null;
    const k = `${status}|${error ?? ""}`;
    if (!groups.has(k)) groups.set(k, { ids: [], status, error });
    groups.get(k).ids.push(...u.eventIds);
  }
  return [...groups.values()].filter((g) => g.ids.length);
}

/**
 * Writes the units and finishes their events. Answers { counts, events: {processed, ignored, failed} }.
 * Units that failed in the read-back carry no writes and are finished as failed with their code.
 */
export async function applyUnits(ctx, connectionId, units) {
  const counts = {};
  const tally = (list) => {
    const t = { processed: 0, ignored: 0, failed: 0 };
    for (const u of list) t[u.status] += u.eventIds.length;
    return t;
  };
  try {
    await withTenant(ctx, async (q) => {
      await writeAll(q, connectionId, units.filter((u) => u.status !== "failed"), counts);
      await finishEvents(q, connectionId, finishGroups(units));
    });
    return { counts, events: tally(units) };
  } catch (err) {
    // One unit at a time: a unit whose writes fail is finished as failed with the database's code
    const done = [];
    for (const k of Object.keys(counts)) delete counts[k];
    for (const u of units) {
      try {
        await withTenant(ctx, async (q) => {
          if (u.status !== "failed") await writeAll(q, connectionId, [u], counts);
          await finishEvents(q, connectionId, finishGroups([u]));
        });
        done.push(u);
      } catch (unitErr) {
        const failed = { ...u, status: "failed", error: dbErrorCode(unitErr) };
        await withTenant(ctx, (q) => finishEvents(q, connectionId, finishGroups([failed]))).catch(() => undefined);
        done.push(failed);
      }
    }
    counts.retriedSingly = 1;
    counts.firstError = dbErrorCode(err);
    return { counts, events: tally(done) };
  }
}
