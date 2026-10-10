/**
 * The event log (migration 0006): recording canonical events, claiming them and finishing them.
 * Canonical events come from an adapter's map step; nothing here reads a vendor payload.
 *
 * A canonical event: { key, sourceType, kind, objectType, objectId, propertyName?, occurredAt,
 * attempt?, raw?, ignore? }. raw holds ids and timestamps only. ignore names why the event needs no
 * read-back (for example portal_mismatch); such an event is recorded, kept in raw.ignored, and
 * finished as ignored in the same transaction, so it is never read back.
 */
import { withTenant } from "./db.mjs";

export const BATCH = 500;

function chunks(list, size = BATCH) {
  const out = [];
  for (let i = 0; i < list.length; i += size) out.push(list.slice(i, i + size));
  return out;
}

function toDb(e) {
  const raw = { ...(e.raw ?? {}) };
  if (e.ignore) raw.ignored = e.ignore;
  return {
    key: e.key, sourceType: e.sourceType, kind: e.kind, objectType: e.objectType, objectId: e.objectId,
    propertyName: e.propertyName ?? null, occurredAt: e.occurredAt, attempt: e.attempt ?? 1, raw,
  };
}

/**
 * Records events in one transaction (batches of at most 500 per call of ingest_record_events) and
 * finishes the ignored ones. Any database error rolls back the whole request: the caller answers
 * 500 and the source sends again. Answers { rows: [{eventId, key, isNew, status}], ignored: n }.
 */
export async function recordEvents(ctx, connectionId, events) {
  return withTenant(ctx, async (q) => {
    const rows = [];
    for (const part of chunks(events)) {
      const r = await q.query("select event_id, event_key, is_new, status from cma.ingest_record_events($1, $2::jsonb)",
        [connectionId, JSON.stringify(part.map(toDb))]);
      for (const x of r.rows) rows.push({ eventId: x.event_id, key: x.event_key, isNew: x.is_new, status: x.status });
    }
    const ignoreKeys = new Set(events.filter((e) => e.ignore).map((e) => e.key));
    const ignoredIds = rows.filter((r) => r.isNew && ignoreKeys.has(r.key)).map((r) => r.eventId);
    let ignored = 0;
    for (const part of chunks(ignoredIds)) {
      await q.query("select count(*) from cma.ingest_claim_events($1, $2::uuid[], $3)", [connectionId, part, part.length]);
      const f = await q.query("select cma.ingest_finish_events($1, $2::uuid[], 'ignored') as n", [connectionId, part]);
      ignored += f.rows[0].n;
    }
    for (const r of rows) if (r.isNew && ignoreKeys.has(r.key)) r.status = "ignored";
    return { rows, ignored };
  });
}

/**
 * Claims the given events (or the next due ones when ids is null) and returns them with what the
 * adapter needs to read back: source type, occurrence time and the recorded raw (ids only).
 */
export async function claimEvents(ctx, connectionId, ids, limit = BATCH) {
  return withTenant(ctx, async (q) => {
    const claimed = await q.query(
      "select event_id, kind, object_type, object_id, property_name, attempts from cma.ingest_claim_events($1, $2::uuid[], $3)",
      [connectionId, ids, limit]);
    if (claimed.rowCount === 0) return [];
    const detail = await q.query(
      `select id, source_type, occurred_at, raw from cma.ingest_event
        where tenant_id = cma.current_tenant_id() and connection_id = $1 and id = any ($2::uuid[])`,
      [connectionId, claimed.rows.map((r) => r.event_id)]);
    const byId = new Map(detail.rows.map((d) => [d.id, d]));
    return claimed.rows.map((r) => ({
      eventId: r.event_id, kind: r.kind, objectType: r.object_type, objectId: r.object_id, propertyName: r.property_name,
      attempts: r.attempts, sourceType: byId.get(r.event_id)?.source_type ?? null,
      occurredAt: byId.get(r.event_id)?.occurred_at?.toISOString() ?? null, raw: byId.get(r.event_id)?.raw ?? {},
    }));
  });
}

/** Finishes events by outcome inside a transaction q: [{ ids, status, error }]. Answers how many changed. */
export async function finishEvents(q, connectionId, groups) {
  let n = 0;
  for (const g of groups) {
    for (const part of chunks(g.ids)) {
      if (part.length === 0) continue;
      const r = await q.query("select cma.ingest_finish_events($1, $2::uuid[], $3, $4) as n",
        [connectionId, part, g.status, g.status === "failed" ? (g.error ?? "failed") : null]);
      n += r.rows[0].n;
    }
  }
  return n;
}

export { chunks };
