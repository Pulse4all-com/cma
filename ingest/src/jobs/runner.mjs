/**
 * What every ingest job shares (DESIGN §5, brief B8): the arguments, the connections it serves
 * (every active connection of every tenant with an active Ingest user, src/core/connection.mjs),
 * one sync_run row per run and stream, structured logs (connection ids, counts, codes; never an
 * object id of a person or a payload) and the exit code: 0 when every connection was served, 1 when
 * any failed (the others are still served; the next scheduled run tries again).
 */
import { closeDb, dbErrorCode } from "../core/db.mjs";
import { SourceError } from "../core/http.mjs";
import { info, error } from "../core/log.mjs";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE = /^\d{4}-\d{2}-\d{2}$/;

export class UsageError extends Error {}

/**
 * --name value pairs → an object. spec: { name: "uuid" | "date" | "minutes" | "text" }; an unknown
 * argument or a value of the wrong shape is a UsageError.
 */
export function parseArgs(argv, spec) {
  const out = {};
  for (let i = 0; i < argv.length; i += 2) {
    const name = String(argv[i] ?? "").replace(/^--/, "");
    const value = argv[i + 1];
    if (!String(argv[i]).startsWith("--") || !Object.hasOwn(spec, name)) throw new UsageError(`unknown argument ${argv[i]}`);
    if (value === undefined) throw new UsageError(`--${name} needs a value`);
    const kind = spec[name];
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
 * One sync_run row around fn(counts): started, then finished once as succeeded, or failed with the
 * code of what fn threw (the counts so far are kept). Answers { ok, counts, error }.
 */
export async function withRun(store, { job, stream = null, from = null, to = null }, fn) {
  const counts = emptyCounts();
  const runId = await store.runStart(job, stream, from, to);
  try {
    const r = await fn(counts);
    const err = r?.error ?? null;
    await store.runFinish(runId, err ? "failed" : "succeeded", counts, err);
    return { ok: !err, counts, error: err };
  } catch (e) {
    const code = codeOf(e);
    await store.runFinish(runId, "failed", counts, code).catch(() => undefined);
    return { ok: false, counts, error: code };
  }
}

/** Runs a job's main function as a process: logs, closes the pool, sets the exit code. */
export async function main(job, fn) {
  const started = Date.now();
  let failed = 1;
  try {
    const r = await fn(process.argv.slice(2));
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
