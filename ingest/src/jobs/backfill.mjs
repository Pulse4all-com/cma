/**
 * The backfill (DESIGN §2, §5; manual, no schedule): one connection, one object type, from a start
 * date (--from, default the tenant's intake.start_date, or the adapter's own default for the object:
 * HubSpot's crm_email and inbox_thread start at cma.email_start_date_of) up to the run's start, through the adapter's
 * listing and the same read-back as a webhook, paced under half of the source's documented limits,
 * resumable (the adapter keeps where it stands in cma.sync_cursor after every page, and a run with
 * the same start continues there). A finished backfill with the same start reads nothing, unless the run
 * has --again: it then walks the stream from the start again (a re-read after an adapter change, without
 * moving the start before email.start_date or intake.start_date). One sync_run row (job backfill, stream
 * the object type).
 *
 *   gcloud run jobs execute ingest-backfill --args=--connection,<id>,--object,<type>,--from,<date>[,--again]
 */
import { ADAPTERS } from "../adapters/index.mjs";
import { servedConnections, contextOf } from "../core/connection.mjs";
import { storeFor } from "../core/store.mjs";
import { recordAndProcess, addCounts } from "../core/sync.mjs";
import { JobBudget } from "../core/budget.mjs";
import { info } from "../core/log.mjs";
import { UsageError, withRun } from "./runner.mjs";

/**
 * The store as an --again run's adapter sees it: a finished backfill cursor (a stream backfill:…, done) reads
 * as absent until this run writes that stream, so the adapter walks it from the start. Every adapter reads
 * its cursor where a stream's walk begins and writes it after every page (done: false), so the same
 * command run again after a failed --again run continues where that one stopped; a done cursor of
 * another start is walked from the start by the adapter anyway.
 */
export function walkAgain(store) {
  const written = new Set();
  return {
    ...store,
    async cursor(stream) {
      const cur = await store.cursor(stream);
      return stream.startsWith("backfill:") && cur?.done === true && !written.has(stream) ? null : cur;
    },
    async setCursor(stream, value) {
      written.add(stream);
      return store.setCursor(stream, value);
    },
  };
}

export async function runBackfill({ connectionId, object, from = null, again = false, adapters = ADAPTERS }) {
  if (!connectionId || !object) throw new UsageError("--connection and --object are required");
  const started = Date.now();
  const [c] = await servedConnections({ connectionId, actorLabel: "ingest:backfill" });
  if (!c) throw new UsageError("no active connection with that id (or its tenant or Ingest user is inactive)");
  const adapter = Object.hasOwn(adapters, c.adapter) ? adapters[c.adapter] : null;
  if (!adapter?.backfill || !adapter.backfillObjects.includes(object)) {
    throw new UsageError(`the ${c.adapter} adapter backfills ${(adapter?.backfillObjects ?? []).join(", ") || "nothing"}`);
  }
  const store = storeFor(contextOf(c), c.connectionId);
  // An adapter may name an object's own default start (HubSpot's email objects: cma.email_start_date_of)
  const date = from ?? (await adapter.backfillFrom?.(object, store)) ?? (await store.settings())["intake.start_date"];
  if (!date) throw new UsageError("no --from and no intake.start_date setting");
  const fromAt = await store.tenantStartOf(date);
  const untilMs = Date.now();
  const budget = new JobBudget(adapter.rates);
  const r = await withRun(store, { job: "backfill", stream: object, from: fromAt, to: new Date(untilMs) }, async (counts) => {
    const process = async (type, items) => addCounts(counts, await recordAndProcess(adapter, c, type, items, budget, { job: "backfill" }));
    return adapter.backfill({ connection: c, store: again ? walkAgain(store) : store, budget, object, fromMs: fromAt.getTime(), untilMs, process, counts });
  });
  const total = { connection: c.connectionId, object, from: date, again, ...r.counts, error: r.error, failed: r.ok ? 0 : 1 };
  info("backfill", { ...total, ms: Date.now() - started });
  return total;
}
