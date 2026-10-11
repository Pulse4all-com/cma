/**
 * The reconcile (DESIGN §2, §5, nightly at 02:30 Europe/Amsterdam): per active connection whose
 * adapter reconciles, per object type, everything modified in the look-back (26 hours by default;
 * --lookback-minutes shortens it, so the polling fallback of NIGHT_NOTES D3 is only a schedule
 * change) is listed by the adapter and read back through the same path as a webhook (synthetic
 * events, stale guard), one sync_run row per object type (job reconcile, stream the object type).
 * Events whose read-back fails are left to the sweep and counted as failed; the run still succeeds.
 */
import { ADAPTERS } from "../adapters/index.mjs";
import { servedConnections, contextOf } from "../core/connection.mjs";
import { storeFor } from "../core/store.mjs";
import { recordAndProcess, addCounts } from "../core/sync.mjs";
import { JobBudget } from "../core/budget.mjs";
import { info, warn } from "../core/log.mjs";
import { codeOf, withRun } from "./runner.mjs";

export const DEFAULT_LOOKBACK_MINUTES = 26 * 60;

export async function runReconcile({ connectionId = null, lookbackMinutes = DEFAULT_LOOKBACK_MINUTES, object = null, adapters = ADAPTERS } = {}) {
  const started = Date.now();
  const connections = await servedConnections({ connectionId, actorLabel: "ingest:reconcile" });
  const total = { connections: 0, runs: 0, fetched: 0, upserted: 0, stale: 0, skipped: 0, eventsFailed: 0, failed: 0 };
  for (const c of connections) {
    const adapter = Object.hasOwn(adapters, c.adapter) ? adapters[c.adapter] : null;
    if (!adapter?.reconcile) continue;
    total.connections += 1;
    const store = storeFor(contextOf(c), c.connectionId);
    const budget = new JobBudget(adapter.rates);
    const untilMs = Date.now();
    const sinceMs = untilMs - lookbackMinutes * 60_000;
    for (const obj of adapter.reconcileObjects.filter((o) => !object || o === object)) {
      try {
        const r = await withRun(store, { job: "reconcile", stream: obj, from: new Date(sinceMs), to: new Date(untilMs) }, async (counts) => {
          const process = async (type, items) => addCounts(counts, await recordAndProcess(adapter, c, type, items, budget, { job: "reconcile" }));
          await adapter.reconcile({ connection: c, store, budget, object: obj, sinceMs, untilMs, process, counts });
        });
        total.runs += 1;
        for (const k of ["fetched", "upserted", "stale", "skipped"]) total[k] += r.counts[k];
        total.eventsFailed += r.counts.failed;
        if (!r.ok) {
          total.failed += 1;
          warn("reconcile: stream failed", { connection: c.connectionId, stream: obj, code: r.error });
        }
      } catch (err) {
        total.failed += 1;
        warn("reconcile: run not recorded", { connection: c.connectionId, stream: obj, code: codeOf(err) });
      }
    }
  }
  info("reconcile", { ...total, lookbackMinutes, ms: Date.now() - started });
  return total;
}
