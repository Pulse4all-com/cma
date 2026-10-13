/**
 * The jobs' way into the read-back: an object a job finds (reconcile, backfill, the sweeper's second
 * read) becomes a synthetic canonical event, recorded in the event log like a webhook's and processed
 * by the same read-back and upserts (DESIGN §2: log first, read back, upsert guarded by the source's
 * updated time, finish). So a job writes nothing a webhook would not, a 429 during a backfill leaves
 * its events for the sweeper with backoff, and every object a job touched has its event row.
 *
 * The key is sync:<object type>:<id>:<version>. An adapter gives the version (the source's modified
 * time for reconcile and backfill, so the same unchanged object is read once however often a job
 * lists it; a run-specific value where every run must read again). Adapters answer canonical
 * { id, version, inline? } items; inline, when the listing itself already holds the object as the
 * source's API answered it, is carried in memory to the adapter's read-back (never recorded), so the
 * object is not read a second time. Nothing here reads a vendor payload.
 */
import { contextOf } from "./connection.mjs";
import { recordEvents, inlineOf } from "./events.mjs";
import { processEvents } from "./process.mjs";

const ID = /^[^\s:][^\s]{0,99}$/;

/** One synthetic event. job: reconcile, backfill or reread; occurredAt: the version's time when it is one. */
export function syncEvent(job, objectType, item, prefix = "sync") {
  const id = String(item.id);
  const version = String(item.version ?? "").slice(0, 40);
  const at = Number.isFinite(Date.parse(version)) ? new Date(version).toISOString() : new Date().toISOString();
  const event = {
    key: `${prefix}:${objectType}:${id}:${version}`.slice(0, 200),
    sourceType: `cma.${job}`,
    kind: "changed",
    objectType,
    objectId: id,
    occurredAt: at,
    raw: { job },
  };
  if (item.inline !== undefined && item.inline !== null) event.inline = item.inline;
  return event;
}

/**
 * Records the items as events and processes the new ones (and known ones still due) with the
 * adapter's read-back. Answers sync_run counts: fetched (items given), upserted (events processed),
 * stale (rows the stale guard kept), skipped (versions already seen, nothing to read, or a telephony
 * call on a line that does not count), failed (events left for the sweeper).
 */
export async function recordAndProcess(adapter, connection, objectType, items, budget, { job, prefix = "sync" } = {}) {
  const counts = { fetched: items.length, upserted: 0, stale: 0, skipped: 0, failed: 0 };
  const valid = items.filter((i) => ID.test(String(i.id ?? "")));
  counts.skipped += items.length - valid.length;
  if (!valid.length) return counts;
  const events = valid.map((i) => syncEvent(job, objectType, i, prefix));
  const recorded = await recordEvents(contextOf(connection), connection.connectionId, events);
  const due = recorded.rows.filter((r) => r.isNew && r.status === "received").map((r) => r.eventId);
  counts.skipped += recorded.rows.length - due.length;
  if (!due.length) return counts;
  const r = await processEvents(adapter, connection, due, budget, inlineOf(events));
  // a telephony call on a line that does not count is read but not stored (migration 0008f)
  const uncounted = Math.min(r.counts.skipped_uncounted_line ?? 0, r.events.processed);
  counts.upserted += r.events.processed - uncounted;
  counts.skipped += r.events.ignored + uncounted;
  counts.failed += r.events.failed + Math.max(0, due.length - r.claimed);
  counts.stale += r.counts.stale ?? 0;
  return counts;
}

export function addCounts(total, part) {
  for (const k of ["fetched", "upserted", "stale", "skipped", "failed"]) total[k] = (total[k] ?? 0) + (part[k] ?? 0);
  return total;
}
