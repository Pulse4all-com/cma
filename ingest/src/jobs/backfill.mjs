/**
 * The backfill (DESIGN §2, §5; manual, no schedule): one connection, one object type, from a start
 * date (--from, default the tenant's intake.start_date) up to the run's start, through the adapter's
 * listing and the same read-back as a webhook, paced under half of the source's documented limits,
 * resumable (the adapter keeps where it stands in cma.sync_cursor after every page, and a run with
 * the same start continues there). One sync_run row (job backfill, stream the object type).
 *
 *   gcloud run jobs execute ingest-backfill --args=--connection,<id>,--object,<type>,--from,<date>
 */
import { ADAPTERS } from "../adapters/index.mjs";
import { servedConnections, contextOf } from "../core/connection.mjs";
import { storeFor } from "../core/store.mjs";
import { recordAndProcess, addCounts } from "../core/sync.mjs";
import { JobBudget } from "../core/budget.mjs";
import { info } from "../core/log.mjs";
import { UsageError, withRun } from "./runner.mjs";

export async function runBackfill({ connectionId, object, from = null, adapters = ADAPTERS }) {
  if (!connectionId || !object) throw new UsageError("--connection and --object are required");
  const started = Date.now();
  const [c] = await servedConnections({ connectionId, actorLabel: "ingest:backfill" });
  if (!c) throw new UsageError("no active connection with that id (or its tenant or Ingest user is inactive)");
  const adapter = Object.hasOwn(adapters, c.adapter) ? adapters[c.adapter] : null;
  if (!adapter?.backfill || !adapter.backfillObjects.includes(object)) {
    throw new UsageError(`the ${c.adapter} adapter backfills ${(adapter?.backfillObjects ?? []).join(", ") || "nothing"}`);
  }
  const store = storeFor(contextOf(c), c.connectionId);
  const date = from ?? (await store.settings())["intake.start_date"];
  if (!date) throw new UsageError("no --from and no intake.start_date setting");
  const fromAt = await store.tenantStartOf(date);
  const untilMs = Date.now();
  const budget = new JobBudget(adapter.rates);
  const r = await withRun(store, { job: "backfill", stream: object, from: fromAt, to: new Date(untilMs) }, async (counts) => {
    const process = async (type, items) => addCounts(counts, await recordAndProcess(adapter, c, type, items, budget, { job: "backfill" }));
    return adapter.backfill({ connection: c, store, budget, object, fromMs: fromAt.getTime(), untilMs, process, counts });
  });
  const total = { connection: c.connectionId, object, from: date, ...r.counts, error: r.error, failed: r.ok ? 0 : 1 };
  info("backfill", { ...total, ms: Date.now() - started });
  return total;
}
