/**
 * The asset register poll (addition 0008zj; every 5 minutes, Europe/Amsterdam): per active connection whose adapter
 * polls an asset register (Airtable today) and holds a token secret name, when due on its assets_poll_interval_minutes
 * (default 15), one sync_run row (job assets_poll, stream devices): the records modified since the connection's cursor
 * less five minutes, staged and loaded as a partial batch, so nothing is marked missing (src/adapters/airtable). A
 * connection not due writes nothing. A connection without a token secret name is loaded from files only: one log line
 * (code csv_only) and no run. One log line per connection carries the counts (the load's and fetched), the details
 * (mapped, date failures, values with an @, unreadable cells) and the requests per endpoint. Never a token or a value.
 */
import { ADAPTERS } from "../adapters/index.mjs";
import { servedConnections, contextOf } from "../core/connection.mjs";
import { storeFor } from "../core/store.mjs";
import { JobBudget } from "../core/budget.mjs";
import { info, warn } from "../core/log.mjs";
import { codeOf, withRun } from "./runner.mjs";

export async function runPollAssets({ connectionId = null, adapters = ADAPTERS } = {}) {
  const started = Date.now();
  const connections = await servedConnections({ connectionId, actorLabel: "ingest:poll-assets" });
  const total = { connections: 0, notServed: 0, notDue: 0, fetched: 0, inserted: 0, updated: 0, unchanged: 0, failed: 0 };
  for (const c of connections) {
    const adapter = Object.hasOwn(adapters, c.adapter) ? adapters[c.adapter] : null;
    if (!adapter?.pollAssets) continue;
    total.connections += 1;
    const skip = adapter.skipReason?.(c) ?? null;
    if (skip) {
      total.notServed += 1;
      info("poll-assets: connection skipped", { connection: c.connectionId, code: skip });
      continue;
    }
    const store = storeFor(contextOf(c), c.connectionId);
    try {
      if (!(await adapter.pollDue({ store, now: Date.now() }))) {
        total.notDue += 1;
        continue;
      }
      const budget = new JobBudget(adapter.rates);
      let detail = {};
      const r = await withRun(store, { job: "assets_poll", stream: "devices", to: new Date() }, async (counts) => {
        detail = (await adapter.pollAssets({ connection: c, store, budget, now: Date.now(), counts })).detail ?? {};
        return undefined;
      });
      info("poll-assets: connection", { connection: c.connectionId, ...r.counts, ...detail, ...budget.usage(), error: r.error ?? undefined });
      for (const k of ["fetched", "inserted", "updated", "unchanged"]) total[k] += r.counts[k] ?? 0;
      if (!r.ok) {
        total.failed += 1;
        warn("poll-assets: connection failed", { connection: c.connectionId, code: r.error });
      }
    } catch (err) {
      total.failed += 1;
      warn("poll-assets: run not recorded", { connection: c.connectionId, code: codeOf(err) });
    }
  }
  info("poll-assets", { ...total, ms: Date.now() - started });
  return total;
}
