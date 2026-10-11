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
 * Writes: a read-back answers units, one per object it read ({ eventIds, status, error?, writes }); a
 * unit's writes.alerts names the records that arrived by a created event, for cma.ingest_record_alerts.
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
  };
}

const ORDER = [
  ["pipelines", "select cma.ingest_upsert_pipelines($1, $2::jsonb) as n", false],
  ["callOutcomes", "select cma.ingest_upsert_call_outcomes($1, $2::jsonb) as n", false],
  ["records", "select outcome from cma.ingest_upsert_records($1, $2::jsonb)", true],
  ["contacts", "select outcome from cma.ingest_upsert_contacts($1, $2::jsonb)", true],
  ["calls", "select outcome from cma.ingest_upsert_calls($1, $2::jsonb)", true],
  ["associations", "select outcome from cma.ingest_upsert_associations($1, $2::jsonb)", true],
];

async function writeAll(q, connectionId, units, counts) {
  for (const [kind, sql, chunked] of ORDER) {
    const items = units.flatMap((u) => u.writes?.[kind] ?? []);
    if (!items.length) continue;
    for (const part of chunked ? chunks(items) : [items]) {
      const r = await q.query(sql, [connectionId, JSON.stringify(part)]);
      if (chunked) for (const row of r.rows) counts[row.outcome] = (counts[row.outcome] ?? 0) + 1;
    }
  }
  for (const contactId of units.flatMap((u) => u.writes?.forgets ?? [])) {
    await q.query("select cma.ingest_contact_forget($1, $2)", [connectionId, contactId]);
    counts.forgotten = (counts.forgotten ?? 0) + 1;
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
