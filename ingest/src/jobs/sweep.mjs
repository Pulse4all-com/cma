/**
 * The sweep (DESIGN §5, every minute): per active connection, the due events (received, or failed
 * with their backoff passed) claimed and read back in parts of 100 until none is due or the run's
 * time is up, so what a webhook's read-back could not finish arrives within minutes; an event that
 * fails ingest.max_attempts times is parked as needs_review by the database and never claimed again.
 * Then the second read: records still without a contact, created in the last hour, are read again
 * (the CRM may associate the contact after the record was created), at most once per ten minutes
 * each. An adapter with catalogs of its own (telephony lines and tags) refreshes them, at most hourly
 * per connection by its own cursor; a catalog that cannot be read now is logged and read on a later
 * run. Then, per tenant, cma.link_calls(now() − 2 h) pairs telephony calls with CRM calls, one
 * sync_run row (job link_calls) on the tenant's first CRM connection.
 *
 * Last, the outbox guard (sixth Gemini audit FIND-05, 13 October 2026): ingest-outbox runs without a
 * schedule since 0008h, so an action enqueued now would wait unseen. The sweep cannot see Cloud
 * Scheduler (cma-ingest holds no Scheduler role), so it reads the missing schedule from the rows: an
 * action still waiting OUTBOX_LATE after it fell due is one no outbox run claimed, which a scheduled
 * outbox (every minute) would have done. Per tenant the sweep counts them per connection, logs a
 * warning with the count (code outbox_pending, no ids) and returns the total as outboxPending; Data
 * quality shows the same count (web, getDataQuality), hidden at 0.
 *
 * The event log is the sweep's own audit (every event's attempts, status and error); sync_run has
 * no job value for the sweep itself (migration 0007's vocabulary), so only the link step has a row.
 * A connection whose read-backs made requests the adapter counts (HubSpot) gets one log line with them
 * per endpoint and the daily limit stated (backlog CMA-069).
 */
import { ADAPTERS } from "../adapters/index.mjs";
import { servedConnections, contextOf } from "../core/connection.mjs";
import { processEvents } from "../core/process.mjs";
import { storeFor } from "../core/store.mjs";
import { recordAndProcess } from "../core/sync.mjs";
import { JobBudget } from "../core/budget.mjs";
import { info, warn } from "../core/log.mjs";
import { codeOf, withRun } from "./runner.mjs";

const PART = 100;
const LINK_LOOKBACK_MS = 2 * 60 * 60_000;
const REREAD_EVERY_MS = 10 * 60_000;
export const OUTBOX_LATE = "10 minutes";

export async function runSweep({ connectionId = null, adapters = ADAPTERS, maxMs = 45_000, now = () => Date.now() } = {}) {
  const started = now();
  const connections = await servedConnections({ connectionId, actorLabel: "ingest:sweep" });
  const total = { connections: 0, claimed: 0, processed: 0, ignored: 0, eventsFailed: 0, reread: 0, catalogs: 0, links: 0, outboxPending: 0, failed: 0 };
  for (const c of connections) {
    const adapter = Object.hasOwn(adapters, c.adapter) ? adapters[c.adapter] : null;
    if (!adapter) continue;
    total.connections += 1;
    const budget = new JobBudget(adapter.rates);
    try {
      for (;;) {
        const r = await processEvents(adapter, c, null, budget);
        total.claimed += r.claimed;
        total.processed += r.events.processed;
        total.ignored += r.events.ignored;
        total.eventsFailed += r.events.failed;
        if (r.claimed < PART || now() - started > maxMs) break;
      }
      if (adapter.holdsRecords) {
        const store = storeFor(contextOf(c), c.connectionId);
        const rows = await store.recordsWithoutContact("1 hour");
        const version = new Date(Math.floor(now() / REREAD_EVERY_MS) * REREAD_EVERY_MS).toISOString();
        for (const type of [...new Set(rows.map((r) => r.recordType))]) {
          const items = rows.filter((r) => r.recordType === type).map((r) => ({ id: r.sourceId, version }));
          const counts = await recordAndProcess(adapter, c, type, items, budget, { job: "reread", prefix: "reread" });
          total.reread += counts.upserted;
        }
      }
    } catch (err) {
      total.failed += 1;
      warn("sweep: connection failed", { connection: c.connectionId, adapter: c.adapter, code: codeOf(err) });
    }
    if (adapter.refreshCatalogs) {
      try {
        if (await adapter.refreshCatalogs({ connection: c, store: storeFor(contextOf(c), c.connectionId), budget })) total.catalogs += 1;
      } catch (err) {
        warn("sweep: catalogs not refreshed", { connection: c.connectionId, adapter: c.adapter, code: codeOf(err) });
      }
    }
    // The connection's requests per endpoint and the daily limit stated, when it made any (CMA-069)
    const usage = budget.usage();
    if (usage.apiCalls) info("sweep: connection", { connection: c.connectionId, adapter: c.adapter, ...usage });
  }

  // Calls linked once per tenant, recorded on its first CRM connection (the side whose calls are linked)
  const crmOfTenant = new Map();
  for (const c of connections) if (adapters[c.adapter]?.holdsRecords && !crmOfTenant.has(c.tenantId)) crmOfTenant.set(c.tenantId, c);
  for (const c of crmOfTenant.values()) {
    const store = storeFor(contextOf(c), c.connectionId);
    const to = new Date(now());
    const from = new Date(to.getTime() - LINK_LOOKBACK_MS);
    try {
      const r = await withRun(store, { job: "link_calls", from, to }, async (counts) => {
        const n = await store.linkCalls(from);
        counts.upserted += n;
      });
      total.links += r.counts.upserted;
      if (!r.ok) {
        total.failed += 1;
        warn("sweep: link_calls failed", { connection: c.connectionId, code: r.error });
      }
    } catch (err) {
      total.failed += 1;
      warn("sweep: link_calls not recorded", { connection: c.connectionId, code: codeOf(err) });
    }
  }

  // The outbox guard, once per tenant as its Ingest user (any served connection gives the context)
  const anyOfTenant = new Map();
  for (const c of connections) if (!anyOfTenant.has(c.tenantId)) anyOfTenant.set(c.tenantId, c);
  for (const c of anyOfTenant.values()) {
    try {
      const late = await storeFor(contextOf(c), c.connectionId).outboxLate(OUTBOX_LATE, connectionId);
      for (const l of late) {
        total.outboxPending += l.count;
        warn("sweep: outbox actions overdue, ingest-outbox unscheduled or not running", { connection: l.connectionId, code: "outbox_pending", outboxPending: l.count });
      }
    } catch (err) {
      total.failed += 1;
      warn("sweep: outbox not checked", { connection: c.connectionId, code: codeOf(err) });
    }
  }
  info("sweep", { ...total, ms: now() - started });
  return total;
}
