/**
 * Database access for the ingest service and its jobs: one pool per process, every unit of work one
 * transaction with the tenant context set by set_config(..., true), exactly as the web app's
 * src/lib/db/client.ts and the scheduler's job connect.
 *
 *   withoutTenant  no tenant context: only cma.ingest_connection(key), the SECURITY DEFINER lookup
 *   withTenant     app.tenant_id, app.user_id (the tenant's Ingest user) and app.actor_label
 *   withTenantOnly app.tenant_id alone: a job finding the tenant's Ingest user and connections
 *
 * Authentication is automatic IAM database authentication through the Cloud SQL connector: the
 * service account cma-ingest@<project>.iam is the database user, a member of cma_app with plain
 * inheritance (no password anywhere).
 *
 * Environment:
 *   CMA_DB_INSTANCE   <project>:europe-west4:<instance>   connection name (required on Cloud Run)
 *   CMA_DB_USER       cma-ingest@<project>.iam            IAM database user (required)
 *   CMA_DB_NAME       cma                                 (default cma)
 *   CMA_DB_POOL_MAX   5                                   per instance
 *   CMA_DB_IP         PUBLIC | PRIVATE                    (default PUBLIC)
 *   CMA_DB_STATEMENT_TIMEOUT_MS   15000    a statement running longer is cancelled (SQLSTATE 57014, db_57014)
 *   CMA_DB_IDLE_TX_TIMEOUT_MS     30000    a transaction idle longer is ended by the server (25P03, db_25P03)
 * Both timeouts (from 1 s to 1 h; another value keeps the default) go to the server as startup parameters
 * of every pooled session, so a query the 30-second request timeout or a job's task timeout no longer
 * waits for is not left running (audit 17 October 2026, 5.2-07). A unit of work keeps its SQL inside
 * the transaction and its vendor calls outside it (process.mjs), so neither fires in normal running.
 * Local only (never set on Cloud Run): CMA_DB_HOST, CMA_DB_PORT, CMA_DB_PASSWORD for a plain
 * connection to a local PostgreSQL (the flow verifier), and CMA_DB_SET_ROLE=cma_app for a login that
 * holds cma_app without inheritance.
 *
 *   jobLock(name)  a session-level advisory lock for a scheduled job, held on one pooled client for the
 *                  run: a second execution Cloud Scheduler starts while the first still runs finds it held
 *                  and skips (src/jobs/runner.mjs; audit 17 October 2026, 5.2-02)
 *   measurePool(job, fn)  the clients a job's own code holds at once, its lock's among them, counted apart from
 *                  anything else the process runs (the flow verifiers host the service beside the jobs); a
 *                  checkout while the job's own clients already fill the pool waits on the job itself (a
 *                  self-wait). The jobs run with a pool of 2 (docs/ingest/deploy.sh): the lock and one unit of
 *                  work at a time (Database connection budget; Gemini audit of 28 October 2026, FIND-01)
 */
import { AsyncLocalStorage } from "node:async_hooks";
import pg from "pg";

// A business date stays a YYYY-MM-DD string; bigint counts fit a JS number
pg.types.setTypeParser(1082, (v) => v);
pg.types.setTypeParser(20, (v) => Number(v));

function required(name) {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is not set`);
  return v;
}

/** A timeout from the environment in milliseconds: a whole number from 1 s to 1 h, else the default. */
function timeoutMs(name, fallback) {
  const v = Number(process.env[name] ?? fallback);
  return Number.isInteger(v) && v >= 1000 && v <= 3_600_000 ? v : fallback;
}

/** The ingest's statement timeout when CMA_DB_STATEMENT_TIMEOUT_MS is not set (db/117 holds its budgets to this value) */
export const DEFAULT_STATEMENT_TIMEOUT_MS = 15_000;

/** The statement timeout every pooled session runs under, in milliseconds (the adapters' chunks adapt to it) */
export function statementTimeoutMs() {
  return timeoutMs("CMA_DB_STATEMENT_TIMEOUT_MS", DEFAULT_STATEMENT_TIMEOUT_MS);
}

/** The pool's size per process: CMA_DB_POOL_MAX, 5 when not set (the service; the jobs run with 2) */
export function poolMax() {
  return Number(process.env.CMA_DB_POOL_MAX ?? 5);
}

// A job's own clients: the run's use, set by measurePool for everything its code awaits
const jobUse = new AsyncLocalStorage();
const runsMeasured = [];

/**
 * Runs fn as job's run with its pool use counted (a nested call counts into the outer run) and keeps
 * { job, peak, work, selfWaits, max }: peak the clients held at once, work the same without the advisory
 * lock's, selfWaits the checkouts made while the job's own clients filled the pool.
 */
export async function measurePool(job, fn) {
  if (jobUse.getStore()) return fn();
  const use = { held: 0, locks: 0, peak: 0, work: 0, selfWaits: 0 };
  try {
    return await jobUse.run(use, fn);
  } finally {
    runsMeasured.push({ job, peak: use.peak, work: use.work, selfWaits: use.selfWaits, max: poolMax() });
  }
}

/** The runs measurePool kept in this process, oldest first */
export function poolRuns() {
  return runsMeasured.map((r) => ({ ...r }));
}

/** A client of the pool, counted into the job's run when there is one; answers { client, done } */
async function checkout(pool, { lock = false } = {}) {
  const use = jobUse.getStore() ?? null;
  if (use && use.held >= poolMax()) use.selfWaits += 1;
  const client = await pool.connect();
  if (!use) return { client, done: () => undefined };
  use.held += 1;
  if (lock) use.locks += 1;
  use.peak = Math.max(use.peak, use.held);
  use.work = Math.max(use.work, use.held - use.locks);
  let open = true;
  return {
    client,
    done: () => {
      if (!open) return;
      open = false;
      use.held -= 1;
      if (lock) use.locks -= 1;
    },
  };
}

let state = null;

async function open() {
  const database = process.env.CMA_DB_NAME ?? "cma";
  const max = poolMax();
  // pg sends both as startup parameters: they bind every session of the pool
  const timeouts = {
    statement_timeout: statementTimeoutMs(),
    idle_in_transaction_session_timeout: timeoutMs("CMA_DB_IDLE_TX_TIMEOUT_MS", 30_000),
  };
  const setRole = process.env.CMA_DB_SET_ROLE;
  if (setRole && setRole !== "cma_app") throw new Error("CMA_DB_SET_ROLE can only be cma_app");
  let pool;
  let close = () => undefined;
  if (process.env.CMA_DB_HOST) {
    pool = new pg.Pool({
      host: process.env.CMA_DB_HOST, port: Number(process.env.CMA_DB_PORT ?? 5432), user: required("CMA_DB_USER"),
      password: process.env.CMA_DB_PASSWORD || undefined, database, max, idleTimeoutMillis: 30_000,
      connectionTimeoutMillis: 10_000, application_name: "cma-ingest-local", ...timeouts,
    });
  } else {
    const { Connector, AuthTypes, IpAddressTypes } = await import("@google-cloud/cloud-sql-connector");
    const connector = new Connector();
    const opts = await connector.getOptions({
      instanceConnectionName: required("CMA_DB_INSTANCE"),
      authType: AuthTypes.IAM,
      ipType: process.env.CMA_DB_IP === "PRIVATE" ? IpAddressTypes.PRIVATE : IpAddressTypes.PUBLIC,
    });
    pool = new pg.Pool({ ...opts, user: required("CMA_DB_USER"), database, max, idleTimeoutMillis: 30_000,
      connectionTimeoutMillis: 10_000, application_name: "cma-ingest", ...timeouts });
    close = () => connector.close();
  }
  // An idle client's error (a dropped connection) must not crash the process; the next query reconnects
  pool.on("error", () => undefined);
  if (setRole) pool.on("connect", (client) => { client.query("set role cma_app").catch(() => undefined); });
  return { pool, close };
}

async function db() {
  if (!state) {
    state = open().catch((err) => {
      state = null;
      throw err;
    });
  }
  return state;
}

async function transaction(setContext, fn) {
  const { pool } = await db();
  const { client, done } = await checkout(pool);
  // A session the server ends while this client waits (the idle-in-transaction timeout, a restart)
  // arrives as an error event on the checked-out client, which pg-pool does not listen to: unheard it
  // would end the process. Heard, it is this transaction's failure (db_25P03) and the pool drops the client.
  let ended = null;
  const onEnded = (err) => { ended ??= err; };
  client.on("error", onEnded);
  try {
    await client.query("begin");
    await setContext(client);
    const result = await fn(client);
    await client.query("commit");
    return result;
  } catch (err) {
    await client.query("rollback").catch(() => undefined);
    throw ended ?? err;
  } finally {
    client.removeListener("error", onEnded);
    client.release();
    done();
  }
}

/** A transaction without tenant context: RLS hides every tenant row; for the key lookup only. */
export function withoutTenant(fn) {
  return transaction(async () => undefined, fn);
}

/** A transaction as the tenant's Ingest user (ctx: { tenantId, userId, actorLabel }). */
export function withTenant(ctx, fn) {
  if (!ctx?.tenantId || !ctx?.userId) throw new Error("tenant context missing");
  return transaction(async (q) => {
    await q.query(
      "select set_config('app.tenant_id', $1, true), set_config('app.user_id', $2, true), set_config('app.actor_label', $3, true)",
      [ctx.tenantId, ctx.userId, ctx.actorLabel ?? "ingest"],
    );
  }, fn);
}

/** A transaction with the tenant set and no acting user (reads only: every write needs a user). */
export function withTenantOnly(tenantId, actorLabel, fn) {
  if (!tenantId) throw new Error("tenant missing");
  return transaction(async (q) => {
    await q.query("select set_config('app.tenant_id', $1, true), set_config('app.user_id', '', true), set_config('app.actor_label', $2, true)",
      [tenantId, actorLabel ?? "ingest"]);
  }, fn);
}

const LOCK_SPACE = "cma-ingest";

/**
 * A session-level advisory lock named for a job, held on one pooled client until release(); null when
 * another session holds it. Cloud Scheduler starts an execution every minute whether or not the previous
 * one has finished (README, Database connection budget), so the runner takes this lock and a second
 * execution skips while the first runs. The two-key form pg_try_advisory_lock(int, int) with the space
 * hashtext('cma-ingest') keeps it apart from the database's own row locks (hashtextextended, one key).
 */
export async function jobLock(name) {
  const { pool } = await db();
  const { client, done: counted } = await checkout(pool, { lock: true });
  const onEnded = () => undefined; // the session ended under us: the lock went with it; the pool drops the client on release
  client.on("error", onEnded);
  const done = () => {
    client.removeListener("error", onEnded);
    client.release();
    counted();
  };
  let ok = false;
  try {
    ok = (await client.query("select pg_try_advisory_lock(hashtext($1), hashtext($2)) as ok", [LOCK_SPACE, name])).rows[0].ok === true;
  } finally {
    if (!ok) done();
  }
  if (!ok) return null;
  return {
    async release() {
      await client.query("select pg_advisory_unlock(hashtext($1), hashtext($2))", [LOCK_SPACE, name]).catch(() => undefined);
      done();
    },
  };
}

/** The SQLSTATE of a database error, or a short code when the database could not be reached. */
export function dbErrorCode(err) {
  const code = err?.code;
  if (typeof code === "string" && /^[0-9A-Z]{5}$/.test(code)) return `db_${code}`;
  return "db_unavailable";
}

export async function closeDb() {
  if (!state) return;
  const s = await state.catch(() => null);
  state = null;
  if (s) {
    await s.pool.end().catch(() => undefined);
    s.close();
  }
}
