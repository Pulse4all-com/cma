/**
 * The scheduler jobs' way through a dropped database connection (jobs/refresh-follow-up.mjs and
 * jobs/close-forgotten-workdays.mjs). A Cloud SQL connection can be reset while it sits idle in the pool or
 * between two statements (a network blip, maintenance, a failover). On 18 October 2026 at 16:04 UTC one such
 * reset (read ECONNRESET) ended a refresh-follow-up execution with exit 1, because the job's pool had no
 * listener for it (records/console-2026-10-18). As the ingest's pool (ingest/src/core/db.mjs) and the web's
 * (src/lib/db/client.ts), the jobs now
 *   - hear an idle client's error on the pool: one warning line with its code, never an unhandled 'error' event;
 *   - hear a checked-out client's error (the server ending the session between statements) as that piece of
 *     work's failure, and release the client with it, so the pool drops the connection;
 * and retry a piece of work once, on a fresh connection, when it failed with a connection error. A second
 * failure is the work's failure as before (the tenant's run row says failed, with its code). Any other error
 * (a statement timeout, a refusal of the database) is never retried. Plain JavaScript, no dependency.
 */
import { realpathSync } from "node:fs";
import { pathToFileURL } from "node:url";

// Network errors of the socket and Postgres's connection classes: 08 (connection exception), 57P01 to 57P03
// (the server shutting down or not accepting connections yet)
const NETWORK_CODES = new Set(["ECONNRESET", "ECONNREFUSED", "ECONNABORTED", "ETIMEDOUT", "EPIPE", "ENOTCONN", "EHOSTUNREACH", "ENETUNREACH",
  "EAI_AGAIN", "57P01", "57P02", "57P03"]);
// pg's own errors for a connection that ended carry no code, only these words
const NETWORK_WORDS = /connection terminated|terminating connection|connection error|not queryable|socket hang up|server closed the connection/i;

export function isConnectionError(err) {
  if (!err) return false;
  const code = typeof err.code === "string" ? err.code : "";
  return NETWORK_CODES.has(code) || /^08[0-9A-Z]{3}$/.test(code) || NETWORK_WORDS.test(String(err.message ?? ""));
}

/** A short code for a log line or a run row: the error's own code, connection for a dropped connection without one, else error */
export function codeOf(err) {
  if (typeof err?.code === "string" && err.code) return err.code;
  return isConnectionError(err) ? "connection" : "error";
}

/** An idle client's error (its connection reset while it waited in the pool) as one warning line, never a crash */
export function hearIdleErrors(pool, log) {
  pool.on("error", (err) => log("WARNING", { reason: "idle connection lost", error: codeOf(err) }));
}

/**
 * fn(client) on a client from connect(), released afterwards. An 'error' event on the client while it is out
 * (the server ended the session) is the work's failure. A client whose connection failed is released with the
 * error, so the pool drops it instead of handing it out again.
 */
export async function withClient(connect, fn) {
  const client = await connect();
  let lost = null;
  const onError = (err) => { lost ??= err; };
  client.on("error", onError);
  let failure = null;
  try {
    return await fn(client);
  } catch (err) {
    failure = lost ?? err;
    throw failure;
  } finally {
    client.removeListener("error", onError);
    const dropped = lost ?? (failure && isConnectionError(failure) ? failure : null);
    client.release(dropped ?? undefined);
  }
}

/**
 * work() once more when its first try failed with a connection error, after one warning line (fields name
 * what was retried: a tenant, a step); any other error, and a second failure, is thrown.
 */
export async function retryOnce(work, { log, fields = {} }) {
  try {
    return await work();
  } catch (err) {
    if (!isConnectionError(err)) throw err;
    log("WARNING", { ...fields, reason: "connection lost, retried once", error: codeOf(err) });
    return work();
  }
}

/** Whether a module is the script node was started with (so a verifier can import a job without running it) */
export function isMain(moduleUrl) {
  if (!process.argv[1]) return false;
  try {
    return moduleUrl === pathToFileURL(realpathSync(process.argv[1])).href;
  } catch {
    return false;
  }
}
