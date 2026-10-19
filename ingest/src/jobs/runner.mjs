/**
 * What every ingest job shares (DESIGN §5, brief B8): the arguments, the connections it serves
 * (every active connection of every tenant with an active Ingest user, src/core/connection.mjs),
 * one sync_run row per run and stream, structured logs (connection ids, counts, codes; never an
 * object id of a person or a payload) and the exit code: 0 when every connection was served, 1 when
 * any failed (the others are still served; the next scheduled run tries again). The scheduled jobs run
 * one execution at a time (main's lock option: a session advisory lock named for the job, db.mjs
 * jobLock): Cloud Scheduler starts the next execution every minute whether or not the previous one has
 * finished, and a second one that finds the lock held logs `<job> skipped` with code locked, writes
 * nothing and exits 0 (audit 17 October 2026, 5.2-02). No sync_run row records a skip: the table knows
 * running, succeeded and failed only (migration 0007's vocabulary).
 */
import { closeDb, dbErrorCode, jobLock } from "../core/db.mjs";
import { SourceError } from "../core/http.mjs";
import { info, error } from "../core/log.mjs";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE = /^\d{4}-\d{2}-\d{2}$/;

export class UsageError extends Error {}

/**
 * --name value pairs → an object. spec: { name: "uuid" | "date" | "minutes" | "text" | "flag" }; a flag
 * takes no value and reads true; an unknown argument or a value of the wrong shape is a UsageError.
 */
export function parseArgs(argv, spec) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const name = String(argv[i] ?? "").replace(/^--/, "");
    if (!String(argv[i]).startsWith("--") || !Object.hasOwn(spec, name)) throw new UsageError(`unknown argument ${argv[i]}`);
    const kind = spec[name];
    if (kind === "flag") {
      out[name] = true;
      continue;
    }
    i += 1;
    const value = argv[i];
    if (value === undefined) throw new UsageError(`--${name} needs a value`);
    if (kind === "uuid" && !UUID.test(value)) throw new UsageError(`--${name} is not a uuid`);
    if (kind === "date" && (!DATE.test(value) || !Number.isFinite(Date.parse(`${value}T00:00:00Z`)))) throw new UsageError(`--${name} is not a date (YYYY-MM-DD)`);
    if (kind === "minutes" && !(/^\d+$/.test(value) && Number(value) >= 1 && Number(value) <= 100_000)) throw new UsageError(`--${name} is not a number of minutes`);
    out[name] = kind === "minutes" ? Number(value) : value;
  }
  return out;
}

/** A short code for a failure: the source's, the database's SQLSTATE, or a generic one. Never a message. */
export function codeOf(err) {
  if (err instanceof SourceError) return err.code;
  if (typeof err?.code === "string" && /^[0-9A-Z]{5}$/.test(err.code)) return dbErrorCode(err);
  if (typeof err?.code === "string" && /^[a-z][a-z0-9_]{0,59}$/.test(err.code)) return err.code;
  if (typeof err?.code === "string" && /^E[A-Z]+$/.test(err.code)) return "db_unavailable";
  return "job_error";
}

export const emptyCounts = () => ({ fetched: 0, upserted: 0, stale: 0, skipped: 0, failed: 0 });

/**
 * A pause, not a failure (backlog CMA-069): a backfill or reconcile stopped by the source's daily floor
 * (core/budget.mjs). sync_run knows running, succeeded and failed only, so a paused run is finished as
 * succeeded with this code as its error: the counts show how far it got, System health shows it as OK
 * with the code beside it, and the job exits 0. The run resumes on the next one: a backfill from its
 * cursor, a reconcile from the paused run's start (src/jobs/reconcile.mjs).
 */
export const PAUSE_CODE = "daily_floor";

/**
 * One sync_run row around fn(counts): started, then finished once as succeeded, or failed with the
 * code of what fn threw (the counts so far are kept), or as a pause (PAUSE_CODE). Answers
 * { ok, counts, error, paused }.
 */
export async function withRun(store, { job, stream = null, from = null, to = null }, fn) {
  const counts = emptyCounts();
  const runId = await store.runStart(job, stream, from, to);
  try {
    const r = await fn(counts);
    const err = r?.error ?? null;
    if (err === PAUSE_CODE) {
      await store.runFinish(runId, "succeeded", counts, err);
      return { ok: true, counts, error: err, paused: true };
    }
    await store.runFinish(runId, err ? "failed" : "succeeded", counts, err);
    return { ok: !err, counts, error: err, paused: false };
  } catch (e) {
    const code = codeOf(e);
    if (code === PAUSE_CODE) {
      await store.runFinish(runId, "succeeded", counts, code).catch(() => undefined);
      return { ok: true, counts, error: code, paused: true };
    }
    await store.runFinish(runId, "failed", counts, code).catch(() => undefined);
    return { ok: false, counts, error: code, paused: false };
  }
}

/**
 * Runs fn under the job's advisory lock: { ran: true, result }, or { ran: false } after one log line
 * (code locked) when another execution still holds it; nothing is written then.
 */
export async function withJobLock(job, fn) {
  const held = await jobLock(job);
  if (!held) {
    info(`${job} skipped`, { job, code: "locked" });
    return { ran: false, result: null };
  }
  try {
    return { ran: true, result: await fn() };
  } finally {
    await held.release();
  }
}

/** Runs a job's main function as a process: logs, closes the pool, sets the exit code. lock: one execution at a time. */
export async function main(job, fn, { lock = false } = {}) {
  const started = Date.now();
  let failed = 1;
  try {
    const run = () => fn(process.argv.slice(2));
    let r;
    if (lock) {
      const l = await withJobLock(job, run);
      if (!l.ran) {
        await closeDb();
        process.exitCode = 0;
        return;
      }
      r = l.result;
    } else {
      r = await run();
    }
    failed = r?.failed ?? 0;
    info(`${job} finished`, { job, ...r, ms: Date.now() - started });
  } catch (err) {
    if (err instanceof UsageError) {
      error(`${job} usage`, { job, code: "usage", detail: err.message });
      process.exitCode = 2;
      await closeDb();
      return;
    }
    error(`${job} failed`, { job, code: codeOf(err) });
  }
  await closeDb();
  process.exitCode = failed === 0 ? 0 : 1;
}
