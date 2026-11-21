/**
 * The source figures (addition 0009zg, brief B39 continued, Part B39b; hourly at minute 41, Europe/Amsterdam): per
 * active connection whose adapter reads a source's own figures (Juo today) and holds a token secret name, when the day's
 * read is due (cma.source_figures_due_of: after source_figures.local_time, default 05:00, in the tenant's zone, once a
 * day until a run started after it has succeeded; a failed run leaves it due, so the next hour reads again), one sync_run
 * row (job source_figures, stream source_figure): the source's figures for yesterday and today, stored with the CMA's
 * value of the same scope (cma.ingest_upsert_source_figures). A connection not due writes nothing and costs one short
 * read. A connection without a token secret name is not read: one log line (code key_not_set) and no run. A figure the
 * source does not answer (400, 501, analytics off with 409, a filter it ignores) is a counted skip, never a failed run.
 *
 * Light on purpose (Martin, 21 November 2026: prod's one vCPU, the minute job's refresh cycle of about 25 s): its own
 * Cloud Run job and schedule, outside the minute job, about ten requests a store and one write of about 500 rows (most of
 * them the survival cells) a store and day, each write one short statement. One log line per connection carries the
 * counts, the queries, the skips by code and the requests per endpoint; never a value, a key or an id of a customer.
 */
import { ADAPTERS } from "../adapters/index.mjs";
import { servedConnections, contextOf } from "../core/connection.mjs";
import { storeFor } from "../core/store.mjs";
import { JobBudget } from "../core/budget.mjs";
import { info, warn } from "../core/log.mjs";
import { codeOf, withRun } from "./runner.mjs";
import { measurePool } from "../core/db.mjs";

export function runSourceFigures(options) {
  return measurePool("source-figures", () => sourceFiguresJob(options));
}

async function sourceFiguresJob({ connectionId = null, adapters = ADAPTERS } = {}) {
  const started = Date.now();
  const connections = await servedConnections({ connectionId, actorLabel: "ingest:source-figures" });
  const total = { connections: 0, notServed: 0, notDue: 0, read: 0, fetched: 0, inserted: 0, updated: 0, unchanged: 0, skipped: 0, failed: 0 };
  for (const c of connections) {
    const adapter = Object.hasOwn(adapters, c.adapter) ? adapters[c.adapter] : null;
    if (!adapter?.readFigures) continue;
    total.connections += 1;
    const skip = adapter.skipReason?.(c) ?? null;
    if (skip) {
      total.notServed += 1;
      info("source-figures: connection skipped", { connection: c.connectionId, code: skip });
      continue;
    }
    const store = storeFor(contextOf(c), c.connectionId);
    try {
      const due = await adapter.figuresDue({ store });
      if (!due?.due) {
        total.notDue += 1;
        continue;
      }
      const budget = new JobBudget(adapter.rates);
      let detail = {};
      const r = await withRun(store, { job: "source_figures", stream: "source_figure", from: due.dueAt ?? null, to: new Date() }, async (counts, runId) => {
        detail = (await adapter.readFigures({ connection: c, store, budget, counts, runId, due })) ?? {};
        return undefined;
      });
      info("source-figures: connection", { connection: c.connectionId, ...r.counts, ...detail, ...budget.usage(), error: r.error ?? undefined });
      total.read += 1;
      for (const k of ["fetched", "inserted", "updated", "unchanged", "skipped"]) total[k] += r.counts[k] ?? 0;
      if (!r.ok) {
        total.failed += 1;
        warn("source-figures: connection failed", { connection: c.connectionId, code: r.error });
      }
    } catch (err) {
      total.failed += 1;
      warn("source-figures: run not recorded", { connection: c.connectionId, code: codeOf(err) });
    }
  }
  info("source-figures", { ...total, ms: Date.now() - started });
  return total;
}
