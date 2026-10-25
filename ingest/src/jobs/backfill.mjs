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
 * The daily floor (backlog CMA-069): with an adapter that names one (HubSpot: api_daily_floor_pct,
 * default 25) the run pauses once the source's remaining daily calls fall below it, finishes as
 * succeeded with error daily_floor, logs "backfill paused" and exits 0; the same command later continues
 * from the cursor. The log line carries the run's requests per endpoint and the daily limit stated.
 *
 * An adapter may read all history for an object (Trusted Shops' review, addition 0008zd: without --from and with
 * reviews.history_start_date empty, its backfillFrom answers { allHistory: true }): the run has no start, the adapter
 * walks from its own floor, and the cursor's from is null.
 *
 * Since addition 0008za (brief N21) --object takes a comma-separated list (deal,ticket): the objects run one after
 * the other on one budget (the daily floor's reading carries over), each its own sync_run row and its own log line
 * with its requests per endpoint; a pause stops the objects after it, which the same command continues later. An
 * --again run gives every object it lists a version of this run (the adapter's runAt), so an object whose modified
 * time is unchanged is read again too: that is what fills a stored record's stage times after the adapter learned to
 * read them (a run-specific version, as the contact backfill always had; one read per object and run).
 *
 *   gcloud run jobs execute ingest-backfill --args='^;^--connection;<id>;--object;<type>[,<type>…];--from;<date>[;--again]'
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

/**
 * The objects of one command (--object deal,ticket) one after the other, on one budget: the per-object totals, and a
 * pause stops the rest (their totals say skipped_after_pause). Answers { objects: [...totals], failed }.
 */
export async function runBackfills({ connectionId, objects, from = null, again = false, adapters = ADAPTERS }) {
  const list = String(objects ?? "").split(",").map((o) => o.trim()).filter(Boolean);
  if (!connectionId || !list.length) throw new UsageError("--connection and --object are required");
  if (new Set(list).size !== list.length) throw new UsageError("--object names an object twice");
  const out = [];
  let budget = null;
  let paused = false;
  for (const object of list) {
    if (paused) {
      out.push({ connection: connectionId, object, error: "skipped_after_pause", failed: 0 });
      continue;
    }
    const total = await runBackfill({ connectionId, object, from, again, adapters, budget: budget ?? undefined, onBudget: (b) => { budget = b; } });
    out.push(total);
    paused = Boolean(total.paused);
  }
  return { objects: out, failed: out.reduce((n, t) => n + (t.failed ?? 0), 0) };
}

export async function runBackfill({ connectionId, object, from = null, again = false, adapters = ADAPTERS, budget: given = null, onBudget = null }) {
  if (!connectionId || !object) throw new UsageError("--connection and --object are required");
  const started = Date.now();
  const [c] = await servedConnections({ connectionId, actorLabel: "ingest:backfill" });
  if (!c) throw new UsageError("no active connection with that id (or its tenant or Ingest user is inactive)");
  const adapter = Object.hasOwn(adapters, c.adapter) ? adapters[c.adapter] : null;
  if (!adapter?.backfill || !adapter.backfillObjects.includes(object)) {
    throw new UsageError(`the ${c.adapter} adapter backfills ${(adapter?.backfillObjects ?? []).join(", ") || "nothing"}`);
  }
  const store = storeFor(contextOf(c), c.connectionId);
  // An adapter may name an object's own default start (HubSpot's email objects: cma.email_start_date_of), or all history
  const own = from ? null : await adapter.backfillFrom?.(object, store);
  const allHistory = own?.allHistory === true;
  const date = from ?? (allHistory ? null : (own ?? (await store.settings())["intake.start_date"]));
  if (!date && !allHistory) throw new UsageError("no --from and no intake.start_date setting");
  const fromAt = date ? await store.tenantStartOf(date) : null;
  const untilMs = Date.now();
  const floorPct = adapter.dailyFloor ? await adapter.dailyFloor({ store, connection: c, job: "backfill" }) : null;
  const budget = given ?? new JobBudget(adapter.rates, undefined, { floorPct });
  onBudget?.(budget);
  const mark = budget.mark();
  const r = await withRun(store, { job: "backfill", stream: object, from: fromAt, to: new Date(untilMs) }, async (counts) => {
    const process = async (type, items) => addCounts(counts, await recordAndProcess(adapter, c, type, items, budget, { job: "backfill" }));
    return adapter.backfill({ connection: c, store: again ? walkAgain(store) : store, budget, object, fromMs: fromAt ? fromAt.getTime() : null, untilMs, process, counts,
      again, runAt: untilMs });
  });
  const total = { connection: c.connectionId, object, from: date ?? "all history", again, ...r.counts, error: r.error, paused: r.paused || undefined, failed: r.ok ? 0 : 1 };
  info(r.paused ? "backfill paused" : "backfill", { ...total, ...budget.usage(mark), ms: Date.now() - started });
  return total;
}
