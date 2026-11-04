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
 * An adapter may read all history for an object (Trusted Shops' review, addition 0008ze: without --from and with
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
 * An adapter may read an object whole (an asset register's device, addition 0008zj: wholeObjects): the run is a full
 * snapshot, loaded as one (the devices the register no longer holds marked missing), and takes no --from. With
 * --dry-run (an adapter with dryRun) the run reads and counts and writes nothing: no staging, no load, no sync_run row,
 * no cursor; one log line "backfill dry run" with the counts. The dry run of an object that is not read whole (a store's
 * subscription_event, addition 0008zl) reads from the start a real run would take (--from, else the adapter's own or
 * intake.start_date) to the run's start. A connection the adapter does not serve (skipReason: an asset register without a
 * token secret name, loaded from files; a subscriptions connection without one) is a usage error with --connection.
 *
 * Since addition 0008zq (brief N05) --adapter <name> takes the place of --connection (one or the other, never both): one
 * execution walks every served connection of that adapter, every tenant the Ingest user serves, in id order, each
 * connection its own sync_run rows, its own budget and its own --object list exactly as with --connection; a connection's
 * failure or pause is counted and the next connection still runs; a connection the adapter skips (skipReason) is logged
 * `backfill: connection skipped` with its code and counted, never a usage error, so one store without a key does not stop
 * the others; --dry-run logs one `backfill dry run` line per connection. The finished line lists the per-connection
 * totals (connection id, object, counts, error) and the job exits 1 when any connection failed. This stays within FIND-01
 * of the Gemini audit of 29 October 2026: every store is read by the one job, a new store is a new connection, never a
 * new job. The job takes no lock, as before (it runs by hand).
 *
 *   gcloud run jobs execute ingest-backfill --args='^;^--connection;<id>;--object;<type>[,<type>…];--from;<date>[;--again]'
 *   gcloud run jobs execute ingest-backfill --args='^;^--connection;<id>;--object;device[;--dry-run]'
 *   gcloud run jobs execute ingest-backfill --args='^;^--adapter;juo;--object;subscription_event;--from;<date>'
 */
import { ADAPTERS } from "../adapters/index.mjs";
import { servedConnections, contextOf } from "../core/connection.mjs";
import { storeFor } from "../core/store.mjs";
import { recordAndProcess, addCounts } from "../core/sync.mjs";
import { JobBudget } from "../core/budget.mjs";
import { info, warn } from "../core/log.mjs";
import { UsageError, codeOf, withRun } from "./runner.mjs";
import { measurePool } from "../core/db.mjs";

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
 * A run's start: --from, else the adapter's own default for the object (HubSpot's email objects; all history for an
 * object read whole or for Trusted Shops' review without reviews.history_start_date), else intake.start_date. Answers
 * { date, allHistory, fromAt } (fromAt the date's 00:00 in the tenant's zone, null for all history).
 */
async function startOf(adapter, object, store, from) {
  const own = from ? null : await adapter.backfillFrom?.(object, store);
  const allHistory = own?.allHistory === true;
  const date = from ?? (allHistory ? null : (own ?? (await store.settings())["intake.start_date"]));
  if (!date && !allHistory) throw new UsageError("no --from and no intake.start_date setting");
  return { date: date ?? null, allHistory, fromAt: date ? await store.tenantStartOf(date) : null };
}

/**
 * The objects of one command (--object deal,ticket) one after the other, on one budget: the per-object totals, and a
 * pause stops the rest (their totals say skipped_after_pause). Answers { objects: [...totals], failed }.
 */
export function runBackfills(options) {
  return measurePool("backfill", () => backfillsJob(options));
}

/** --object as a list: deal,ticket → ["deal", "ticket"]; an object named twice is a usage error */
function objectList(objects) {
  const list = String(objects ?? "").split(",").map((o) => o.trim()).filter(Boolean);
  if (new Set(list).size !== list.length) throw new UsageError("--object names an object twice");
  return list;
}

async function backfillsJob({ connectionId, objects, from = null, again = false, adapters = ADAPTERS }) {
  const list = objectList(objects);
  if (!connectionId || !list.length) throw new UsageError("--connection and --object are required");
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

/** What the adapter can do with the command (the same for every connection of the adapter): a usage error otherwise */
function assertAdapterTakes(adapter, name, object, { from, dryRun }) {
  if (!adapter?.backfill || !adapter.backfillObjects.includes(object)) {
    throw new UsageError(`the ${name} adapter backfills ${(adapter?.backfillObjects ?? []).join(", ") || "nothing"}`);
  }
  if (from && adapter.wholeObjects?.includes(object)) throw new UsageError(`--object ${object} is read whole: it takes no --from`);
  if (dryRun && !adapter.dryRun) throw new UsageError(`the ${name} adapter has no dry run`);
}

/**
 * Every served connection of one adapter, in id order (addition 0008zq): each its own runs, budget and object list as
 * with --connection; a skipped connection (the adapter's skipReason) and a failed one are counted and the walk goes on.
 * Answers { adapter, connections, served, skipped, failed, results: [...per-connection totals] }.
 */
export function runAdapterBackfill(options) {
  return measurePool("backfill", () => adapterBackfillJob(options));
}

async function adapterBackfillJob({ adapter: name, objects, from = null, again = false, dryRun = false, adapters = ADAPTERS }) {
  const list = objectList(objects);
  if (!name || !list.length) throw new UsageError("--adapter and --object are required");
  if (!/^[a-z0-9]+$/.test(name) || !Object.hasOwn(adapters, name)) throw new UsageError(`no adapter ${String(name).slice(0, 40)}: one of ${Object.keys(adapters).join(", ")}`);
  if (dryRun && list.length > 1) throw new UsageError("--dry-run takes one --object");
  const adapter = adapters[name];
  for (const object of list) assertAdapterTakes(adapter, name, object, { from, dryRun });
  const connections = (await servedConnections({ actorLabel: "ingest:backfill" }))
    .filter((c) => c.adapter === name)
    .sort((a, b) => (a.connectionId < b.connectionId ? -1 : a.connectionId > b.connectionId ? 1 : 0));
  if (!connections.length) throw new UsageError(`no active connection of the ${name} adapter (or its tenant or Ingest user is inactive)`);
  const results = [];
  let skipped = 0;
  let failed = 0;
  for (const c of connections) {
    const skip = adapter.skipReason?.(c) ?? null;
    if (skip) {
      info("backfill: connection skipped", { connection: c.connectionId, adapter: name, code: skip });
      results.push({ connection: c.connectionId, skipped: skip, failed: 0 });
      skipped += 1;
      continue;
    }
    let budget = null;
    let stopped = null;
    for (const object of list) {
      if (stopped) {
        results.push({ connection: c.connectionId, object, error: stopped, failed: 0 });
        continue;
      }
      let total;
      try {
        total = await backfillConnection({ c, adapter, object, from, again, dryRun, budget: budget ?? undefined, onBudget: (b) => { budget = b; } });
      } catch (e) {
        // a connection's own problem (no intake.start_date, a source refusing its dry run, the database refusing its
        // context): counted with its code, the connection's other objects left, the walk goes on with the next connection
        const code = e instanceof UsageError ? "usage" : codeOf(e);
        warn("backfill: connection failed", { connection: c.connectionId, adapter: name, object, code, detail: e instanceof UsageError ? e.message : undefined });
        total = { connection: c.connectionId, object, error: code, failed: 1 };
        stopped = "skipped_after_failure";
      }
      results.push(total);
      failed += total.failed ?? 0;
      if (total.paused) stopped = "skipped_after_pause";
    }
  }
  return { adapter: name, connections: connections.length, served: connections.length - skipped, skipped, failed, results };
}

export function runBackfill(options) {
  return measurePool("backfill", () => backfillJob(options));
}

async function backfillJob({ connectionId, object, from = null, again = false, dryRun = false, adapters = ADAPTERS, budget: given = null,
  onBudget = null }) {
  if (!connectionId || !object) throw new UsageError("--connection and --object are required");
  const [c] = await servedConnections({ connectionId, actorLabel: "ingest:backfill" });
  if (!c) throw new UsageError("no active connection with that id (or its tenant or Ingest user is inactive)");
  const adapter = Object.hasOwn(adapters, c.adapter) ? adapters[c.adapter] : null;
  assertAdapterTakes(adapter, c.adapter, object, { from, dryRun });
  const skip = adapter.skipReason?.(c) ?? null;
  if (skip) throw new UsageError(`the connection is not read by the ingest (${skip}): it has no token secret name`);
  return backfillConnection({ c, adapter, object, from, again, dryRun, budget: given, onBudget });
}

/** One connection, one object: the dry run or the run with its sync_run row; the per-connection total */
async function backfillConnection({ c, adapter, object, from = null, again = false, dryRun = false, budget: given = null, onBudget = null }) {
  const started = Date.now();
  const store = storeFor(contextOf(c), c.connectionId);
  if (dryRun) {
    const budget = new JobBudget(adapter.rates);
    const start = adapter.wholeObjects?.includes(object) ? { fromAt: null } : await startOf(adapter, object, store, from);
    const counts = await adapter.dryRun({ connection: c, store, budget, object, fromMs: start.fromAt ? start.fromAt.getTime() : null, untilMs: Date.now() });
    const total = { connection: c.connectionId, object, dryRun: true, ...counts, failed: 0 };
    info("backfill dry run", { ...total, ...budget.usage(), ms: Date.now() - started });
    return total;
  }
  // An adapter may name an object's own default start (HubSpot's email objects: cma.email_start_date_of), or all history
  const { date, fromAt } = await startOf(adapter, object, store, from);
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
