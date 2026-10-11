/**
 * The sweep (DESIGN §5, every minute): per active connection, the due events (received, or failed
 * with their backoff passed) claimed and read back in parts of 100 until none is due or the run's
 * time is up, so what a webhook's read-back could not finish arrives within minutes; an event that
 * fails ingest.max_attempts times is parked as needs_review by the database and never claimed again.
 * Then the second read: records still without a contact, created in the last hour, are read again
 * (the CRM may associate the contact after the record was created), at most once per ten minutes
 * each. Last, per tenant, cma.link_calls(now() − 2 h) pairs telephony calls with CRM calls, one
 * sync_run row (job link_calls) on the tenant's first CRM connection.
 *
 * The event log is the sweep's own audit (every event's attempts, status and error); sync_run has
 * no job value for the sweep itself (migration 0007's vocabulary), so only the link step has a row.
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

export async function runSweep({ connectionId = null, adapters = ADAPTERS, maxMs = 45_000, now = () => Date.now() } = {}) {
  const started = now();
  const connections = await servedConnections({ connectionId, actorLabel: "ingest:sweep" });
  const total = { connections: 0, claimed: 0, processed: 0, ignored: 0, eventsFailed: 0, reread: 0, links: 0, failed: 0 };
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
  info("sweep", { ...total, ms: now() - started });
  return total;
}
