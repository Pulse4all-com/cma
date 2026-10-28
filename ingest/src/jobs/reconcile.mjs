/**
 * The reconcile (DESIGN §2, §5; nightly, Europe/Amsterdam, at the time docs/ingest/deploy.sh schedules): per active connection whose
 * adapter reconciles, per object type, everything modified in the look-back (26 hours by default;
 * --lookback-minutes shortens it, so the polling fallback of NIGHT_NOTES D3 is only a schedule
 * change) is listed by the adapter and read back through the same path as a webhook (synthetic
 * events, stale guard), one sync_run row per object type (job reconcile, stream the object type).
 * Events whose read-back fails are left to the sweep and counted as failed; the run still succeeds.
 * HubSpot's email objects (crm_email, inbox_thread; brief B17b) are reconciled only for connections
 * whose email poll is on, through the poll's own writes; its form submissions (form_submission, backlog
 * CMA-069) for every connection, every polled form's of the look-back, through the forms poll's writes.
 * An adapter with webhook subscriptions of its own to look after (Shopify) checks them after its
 * streams, one more sync_run row (job subscriptions_check, stream webhooks), unless --object narrows
 * the run. An asset register's (Airtable, addition 0008zj) one stream is its nightly full snapshot; a
 * connection the adapter does not serve (skipReason: an asset register without a token secret name,
 * loaded from files) gets one log line and no run.
 *
 * The daily floor (backlog CMA-069): an adapter that names one (HubSpot: api_daily_floor_pct, default
 * 25) has its streams pause once the source's remaining daily calls fall below it; a paused stream is
 * finished as succeeded with error daily_floor (runner.mjs), logged as paused, and its next run starts
 * at the paused run's start (cursor reconcile:<object>) when that lies before its own look-back. Each
 * stream logs its requests per endpoint and the daily limit the source stated.
 */
import { ADAPTERS } from "../adapters/index.mjs";
import { servedConnections, contextOf } from "../core/connection.mjs";
import { storeFor } from "../core/store.mjs";
import { recordAndProcess, addCounts } from "../core/sync.mjs";
import { JobBudget } from "../core/budget.mjs";
import { info, warn } from "../core/log.mjs";
import { codeOf, withRun } from "./runner.mjs";

export const DEFAULT_LOOKBACK_MINUTES = 26 * 60;
/** Where a paused stream resumes: { from: ms }, the paused run's start; { from: null } once a run finished */
export const resumeStream = (object) => `reconcile:${object}`;

/**
 * One stream of one connection: its sync_run row around the adapter's reconcile, from the look-back's
 * start or, after a paused run, from that run's start (whichever is earlier); a pause writes the resume
 * cursor, a finished run clears it. Only a budget with a floor reads or writes the cursor. process(counts)
 * gives the stream's way into the read-back. Answers { r, usage } (withRun's answer; the stream's
 * requests per endpoint).
 */
export async function reconcileStream({ adapter, connection, store, budget, object, lookbackFrom, untilMs, process }) {
  const resume = budget.floorPct === null ? null : await store.cursor(resumeStream(object));
  const sinceMs = Number.isFinite(resume?.from) ? Math.min(resume.from, lookbackFrom) : lookbackFrom;
  const mark = budget.mark();
  const r = await withRun(store, { job: "reconcile", stream: object, from: new Date(sinceMs), to: new Date(untilMs) }, async (counts) =>
    // An adapter may answer { error } after its listing (a check that failed); the run then fails with it
    adapter.reconcile({ connection, store, budget, object, sinceMs, untilMs, process: process(counts), counts }));
  if (r.paused) await store.setCursor(resumeStream(object), { from: sinceMs });
  else if (r.ok && Number.isFinite(resume?.from)) await store.setCursor(resumeStream(object), { from: null });
  return { r, usage: budget.usage(mark) };
}

export async function runReconcile({ connectionId = null, lookbackMinutes = DEFAULT_LOOKBACK_MINUTES, object = null, adapters = ADAPTERS } = {}) {
  const started = Date.now();
  const connections = await servedConnections({ connectionId, actorLabel: "ingest:reconcile" });
  const total = { connections: 0, notServed: 0, runs: 0, fetched: 0, upserted: 0, stale: 0, skipped: 0, eventsFailed: 0, paused: 0, failed: 0 };
  for (const c of connections) {
    const adapter = Object.hasOwn(adapters, c.adapter) ? adapters[c.adapter] : null;
    if (!adapter?.reconcile) continue;
    total.connections += 1;
    const skip = adapter.skipReason?.(c) ?? null;
    if (skip) {
      total.notServed += 1;
      info("reconcile: connection skipped", { connection: c.connectionId, code: skip });
      continue;
    }
    const store = storeFor(contextOf(c), c.connectionId);
    let floorPct = null;
    try {
      floorPct = adapter.dailyFloor ? await adapter.dailyFloor({ store, connection: c, job: "reconcile" }) : null;
    } catch (err) {
      total.failed += 1;
      warn("reconcile: connection not read", { connection: c.connectionId, code: codeOf(err) });
      continue;
    }
    const budget = new JobBudget(adapter.rates, undefined, { floorPct });
    const untilMs = Date.now();
    const lookbackFrom = untilMs - lookbackMinutes * 60_000;
    // An adapter may narrow its object types per connection (HubSpot: the email objects only where the email poll is on)
    let objects;
    try {
      objects = adapter.reconcileObjectsOf ? await adapter.reconcileObjectsOf(store) : adapter.reconcileObjects;
    } catch (err) {
      total.failed += 1;
      warn("reconcile: connection not read", { connection: c.connectionId, code: codeOf(err) });
      continue;
    }
    for (const obj of objects.filter((o) => !object || o === object)) {
      try {
        const process = (counts) => async (type, items) => addCounts(counts, await recordAndProcess(adapter, c, type, items, budget, { job: "reconcile" }));
        const { r, usage } = await reconcileStream({ adapter, connection: c, store, budget, object: obj, lookbackFrom, untilMs, process });
        total.runs += 1;
        for (const k of ["fetched", "upserted", "stale", "skipped"]) total[k] += r.counts[k];
        total.eventsFailed += r.counts.failed;
        if (r.paused) {
          total.paused += 1;
          info("reconcile: stream paused", { connection: c.connectionId, stream: obj, code: r.error, ...r.counts, ...usage });
        } else if (usage.apiCalls) {
          info("reconcile: stream", { connection: c.connectionId, stream: obj, ...r.counts, ...usage });
        }
        if (!r.ok) {
          total.failed += 1;
          warn("reconcile: stream failed", { connection: c.connectionId, stream: obj, code: r.error });
        }
      } catch (err) {
        total.failed += 1;
        warn("reconcile: run not recorded", { connection: c.connectionId, stream: obj, code: codeOf(err) });
      }
    }
    if (adapter.checkSubscriptions && !object) {
      try {
        const r = await withRun(store, { job: "subscriptions_check", stream: "webhooks", to: new Date() }, async (counts) => {
          const error = await adapter.checkSubscriptions({ connection: c, store, budget, counts });
          return error ? { error } : undefined;
        });
        total.runs += 1;
        if (!r.ok) {
          total.failed += 1;
          warn("reconcile: subscriptions", { connection: c.connectionId, code: r.error });
        }
      } catch (err) {
        total.failed += 1;
        warn("reconcile: subscriptions check not recorded", { connection: c.connectionId, code: codeOf(err) });
      }
    }
  }
  info("reconcile", { ...total, lookbackMinutes, ms: Date.now() - started });
  return total;
}
