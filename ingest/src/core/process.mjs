/**
 * Processing claimed events: the read-back and upsert step of every source (DESIGN §2: log first,
 * answer 200, read back, upsert guarded by the source's updated time, finish).
 *
 * The core claims the events, hands them to the adapter's readBack with the connection's
 * configuration, a store for the reads it needs and a budget, and writes the units it answers. It
 * never reads a vendor payload. What the read-back cannot do in time is finished as failed and the
 * sweeper (brief B8) reads it again with backoff; ten failures park an event as needs_review.
 */
import { contextOf } from "./connection.mjs";
import { claimEvents, chunks } from "./events.mjs";
import { storeFor, applyUnits } from "./store.mjs";
import { info, warn } from "./log.mjs";

/**
 * Processes the given events (in parts of at most 500, while the budget lasts) or, with ids null, the
 * next due ones. Answers the totals.
 */
export async function processEvents(adapter, connection, ids, budget) {
  const total = { claimed: 0, events: { processed: 0, ignored: 0, failed: 0 }, counts: {} };
  const parts = ids ? chunks(ids) : [null];
  for (const part of parts) {
    if (budget.expired()) break;
    const r = await processPart(adapter, connection, part, budget);
    total.claimed += r.claimed;
    for (const k of Object.keys(total.events)) total.events[k] += r.events?.[k] ?? 0;
    for (const [k, v] of Object.entries(r.counts ?? {})) total.counts[k] = (total.counts[k] ?? 0) + (typeof v === "number" ? v : 0);
  }
  return total;
}

async function processPart(adapter, connection, ids, budget) {
  const started = Date.now();
  const ctx = contextOf(connection);
  const claimed = await claimEvents(ctx, connection.connectionId, ids, ids ? ids.length : 100);
  if (!claimed.length) return { claimed: 0 };
  const store = storeFor(ctx, connection.connectionId);
  const config = await store.config();
  let units;
  try {
    units = await adapter.readBack({ connection, config, events: claimed, store, budget });
  } catch (err) {
    // An adapter that throws fails every claimed event with its code (never a message: it may hold data)
    const code = typeof err?.code === "string" ? err.code : "readback_error";
    warn("readback failed", { connection: connection.connectionId, adapter: connection.adapter, code });
    units = [{ eventIds: claimed.map((e) => e.eventId), status: "failed", error: code, writes: {} }];
  }
  // Every claimed event must be finished by exactly one unit; an event the adapter left out fails
  const covered = new Set(units.flatMap((u) => u.eventIds));
  const missing = claimed.filter((e) => !covered.has(e.eventId)).map((e) => e.eventId);
  if (missing.length) units.push({ eventIds: missing, status: "failed", error: "not_handled", writes: {} });
  const result = await applyUnits(ctx, connection.connectionId, units);
  info("processed", {
    connection: connection.connectionId, adapter: connection.adapter, claimed: claimed.length,
    events: result.events, upserts: result.counts, ms: Date.now() - started,
  });
  return { claimed: claimed.length, ...result };
}
