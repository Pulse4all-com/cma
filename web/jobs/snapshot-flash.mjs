/**
 * The Flash snapshot (addition 0008zn; Decision log, 1 November 2026): once a day per tenant, the figures of every
 * Reports → Flash overview for the business date that just ended, stored immutably (cma.flash_snapshot_take: the live
 * computation's rows, the id lists at a month end, the watch), as each tenant's own Scheduler user (flash.snapshot).
 *
 * Runs as a Cloud Run job on the web image (command: node jobs/snapshot-flash.mjs), started by Cloud Scheduler hourly
 * at minute 20 in UTC (docs/scheduler/deploy-flash.sh). Each run visits every tenant; the database decides whether that
 * tenant's date is due (its local time past flash.snapshot_local_time, no succeeded run for the date yet), so time
 * zones and summer time need no schedule change, and a run in the same hour as another finds the date taken. With the
 * same database variables as the service:
 *   CMA_DB_INSTANCE  <project>:<region>:<instance>   with the Cloud SQL connector and IAM auth
 *   CMA_DB_USER      <service account>@<project>.iam  member of cma_app
 *   CMA_DB_NAME      cma
 *   CMA_DB_POOL_MAX  1 (README, Database connection budget; the deploy script sets it; 1 when absent, at most 2)
 *   CMA_DB_HOST/PORT/PASSWORD  the local path for a verifier run (never set on Cloud Run)
 *   CMA_DB_SET_ROLE=cma_app    a verifier aid for a personal login that holds cma_app without inheritance; never set on
 *                              Cloud Run
 * Plain JavaScript on pg and the connector, no build step. Every tenant is served in turn and one tenant's failure never
 * stops the others. Each tenant leaves one sync_run row (job flash_snapshot, no connection) through cma.job_run_start()
 * and cma.job_run_finish(): succeeded with taken 1 and the rows stored, or with not_due or already 1 when nothing was
 * due; failed with the error's code (the take's own failure leaves its failed run row in cma.flash_snapshot_run too), so
 * Configuration → System health shows the job ("Flash snapshot"); and one JSON log line: the tenant's id, the date, the
 * rows, duration_ms. Never a name or a record id. Exit code 0 when every tenant was served, 1 when any failed. No
 * retries by Cloud Scheduler: the next hour is the retry (a date stays due until the day after it).
 *
 * A dropped database connection (jobs/lib/connection.mjs): as the follow-up refresh, a tenant's unit is retried once on a
 * fresh connection after a connection error, its run row kept; the take itself is idempotent (a date already taken
 * answers taken false, reason taken), so a retry after a commit whose answer was lost writes nothing twice.
 */
import pg from "pg";
import { codeOf, hearIdleErrors, isMain, retryOnce, withClient } from "./lib/connection.mjs";

const LOGIN_SYSTEM = "scheduler";   // the login id of each tenant's system user, as 0005a writes it
const LOGIN_ID = "scheduler";
const ACTOR_LABEL = "scheduler";
const JOB = "flash_snapshot";
// A take that runs past this is cancelled (57014) and the tenant's row says so; 123_verify_flash.sql reads the same value
// (verify.job_statement_timeout_ms) and holds a full take at volume under half of it
export const STATEMENT_TIMEOUT_MS = 240_000;

/** The pool's size: CMA_DB_POOL_MAX, 1 when absent, never more than 2 (the connection budget) */
export function poolMax(value) {
  const n = Number.parseInt(String(value ?? ""), 10);
  return Number.isInteger(n) && n >= 1 ? Math.min(n, 2) : 1;
}

async function openPool() {
  const database = process.env.CMA_DB_NAME ?? "cma";
  const common = { database, max: poolMax(process.env.CMA_DB_POOL_MAX), statement_timeout: STATEMENT_TIMEOUT_MS, connectionTimeoutMillis: 10_000 };
  if (process.env.CMA_DB_HOST) {
    return { pool: new pg.Pool({ host: process.env.CMA_DB_HOST, port: Number(process.env.CMA_DB_PORT ?? 5432), user: required("CMA_DB_USER"),
      password: process.env.CMA_DB_PASSWORD || undefined, ...common, application_name: "cma-snapshot-flash-local" }), close: () => undefined };
  }
  const { Connector, AuthTypes, IpAddressTypes } = await import("@google-cloud/cloud-sql-connector");
  const connector = new Connector();
  try {
    const opts = await connector.getOptions({
      instanceConnectionName: required("CMA_DB_INSTANCE"),
      authType: AuthTypes.IAM,
      ipType: process.env.CMA_DB_IP === "PRIVATE" ? IpAddressTypes.PRIVATE : IpAddressTypes.PUBLIC,
    });
    return { pool: new pg.Pool({ ...opts, user: required("CMA_DB_USER"), ...common, application_name: "cma-snapshot-flash" }), close: () => connector.close() };
  } catch (e) {
    connector.close();
    throw e;
  }
}

function required(name) {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is not set`);
  return v;
}

/** One line for Cloud Logging (jsonPayload): severity, message, the tenant's id, the date and counts only */
function log(severity, fields) {
  console.log(JSON.stringify({ severity, message: "snapshot-flash", ...fields }));
}

/** A statement in a transaction of its own, as the tenant's scheduler user */
async function asScheduler(client, tenantId, userId, text, values = []) {
  await client.query("begin");
  try {
    await client.query("select set_config('app.tenant_id', $1, true), set_config('app.user_id', $2, true), set_config('app.actor_label', $3, true)",
      [tenantId, userId, ACTOR_LABEL]);
    const r = await client.query(text, values);
    await client.query("commit");
    return r;
  } catch (e) {
    await client.query("rollback").catch(() => undefined);
    throw e;
  }
}

/**
 * A take's answer as the run row's counts (whole numbers only): taken, not_due, already, failed (one of them 1), the rows
 * stored, the ids frozen at a month end, the watch's findings opened and open, the dates missed before, duration_ms
 */
export function countsOf(r) {
  const n = (v) => (Number.isFinite(Number(v)) ? Math.max(0, Math.round(Number(v))) : 0);
  const overviews = ["customers", "subscriptions", "installed_base", "churn", "orders", "payments", "open_deals", "open_tickets", "open_tasks",
    "reviews", "data_quality"];
  return {
    taken: r?.taken ? 1 : 0,
    not_due: r?.reason === "not_due" ? 1 : 0,
    already: r?.reason === "taken" ? 1 : 0,
    failed: r?.reason === "failed" ? 1 : 0,
    rows: overviews.reduce((s, k) => s + n(r?.[k]), 0),
    ids: n(r?.ids_customer) + n(r?.ids_subscription) + n(r?.ids_device),
    watch_opened: n(r?.watch_opened),
    watch_open: n(r?.watch_open),
    missed_before: n(r?.missed_before),
    duration_ms: n(r?.duration_ms),
  };
}

/**
 * Every tenant with a scheduler user, its date taken when due; connect() gives a client of the pool. Answers
 * { tenants, failed }. Exported for verify/jobs.mjs, which runs it on a mocked pool.
 */
export async function snapshotTenants({ connect, log }) {
  const tenants = await retryOnce(() => withClient(connect, async (client) =>
    (await client.query("select tenant_id from cma.find_tenants_for_identity($1, $2)", [LOGIN_SYSTEM, LOGIN_ID])).rows), { log, fields: { tenant_id: null, step: "tenants" } });
  let failed = 0;
  for (const { tenant_id } of tenants) {
    let runId = null;
    let me = null;
    try {
      const { r, counts } = await retryOnce(() => withClient(connect, async (client) => {
        // 1. The scheduler's own user in this tenant, as cma_app under row-level security
        if (!me) {
          const who = await asScheduler(client, tenant_id, "",
            `select u.id from cma.app_user_external_id x join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id
              where x.tenant_id = cma.current_tenant_id() and x.system = $1 and x.external_id = $2 and u.status = 'active'`, [LOGIN_SYSTEM, LOGIN_ID]);
          me = who.rows[0]?.id ?? null;
          if (!me) throw Object.assign(new Error("no active scheduler user"), { code: "NO_SCHEDULER" });
        }
        // 2. The run row, before the take, so a take that fails still leaves a failed row; once per tenant and run
        if (!runId) runId = (await asScheduler(client, tenant_id, me, "select cma.job_run_start($1) as id", [JOB])).rows[0].id;
        // 3. The take: the database decides whether the tenant's date is due, and takes it once
        const r = (await asScheduler(client, tenant_id, me, "select cma.flash_snapshot_take(cma.current_tenant_id()) as r")).rows[0].r;
        const counts = countsOf(r);
        if (r?.reason === "failed") {
          await asScheduler(client, tenant_id, me, "select cma.job_run_finish($1::uuid, 'failed', $2::jsonb, $3)",
            [runId, JSON.stringify(counts), String(r.error ?? "failed").slice(0, 60)]);
        } else {
          await asScheduler(client, tenant_id, me, "select cma.job_run_finish($1::uuid, 'succeeded', $2::jsonb)", [runId, JSON.stringify(counts)]);
        }
        return { r, counts };
      }), { log, fields: { tenant_id } });
      if (r?.reason === "failed") failed += 1;
      log(r?.reason === "failed" ? "ERROR" : "INFO", { tenant_id, date: r?.date ?? null, taken: Boolean(r?.taken), reason: r?.reason ?? null,
        rows: counts.rows, ids: counts.ids, watch_opened: counts.watch_opened, duration_ms: counts.duration_ms, ...(r?.error ? { error: r.error } : {}) });
    } catch (e) {
      failed += 1;
      log("ERROR", { tenant_id, date: null, taken: false, rows: 0, duration_ms: 0, error: codeOf(e) });
      if (runId && me) {
        await retryOnce(() => withClient(connect, (client) =>
          asScheduler(client, tenant_id, me, "select cma.job_run_finish($1::uuid, 'failed', '{}'::jsonb, $2)", [runId, codeOf(e)])), { log, fields: { tenant_id } })
          .catch((f) => log("ERROR", { tenant_id, date: null, taken: false, rows: 0, duration_ms: 0, error: `run row not finished: ${codeOf(f)}` }));
      }
    }
  }
  if (tenants.length === 0) log("WARNING", { tenant_id: null, date: null, taken: false, rows: 0, duration_ms: 0, reason: "no tenant with a scheduler user" });
  return { tenants: tenants.length, failed };
}

if (isMain(import.meta.url)) {
  const setRole = process.env.CMA_DB_SET_ROLE;
  if (setRole && setRole !== "cma_app") throw new Error("CMA_DB_SET_ROLE can only be cma_app");
  let opened;
  try {
    opened = await retryOnce(openPool, { log, fields: { tenant_id: null, step: "pool" } });
  } catch (e) {
    log("ERROR", { tenant_id: null, date: null, taken: false, rows: 0, duration_ms: 0, error: codeOf(e), reason: "pool not opened" });
    process.exit(1);
  }
  const { pool, close } = opened;
  hearIdleErrors(pool, (severity, fields) => log(severity, { tenant_id: null, ...fields }));
  const connect = async () => {
    const client = await pool.connect();
    if (setRole) {
      try {
        await client.query("set role cma_app");
      } catch (e) {
        client.release(e);
        throw e;
      }
    }
    return client;
  };
  let failed = 1;
  try {
    ({ failed } = await snapshotTenants({ connect, log }));
  } catch (e) {
    log("ERROR", { tenant_id: null, date: null, taken: false, rows: 0, duration_ms: 0, error: codeOf(e), reason: "tenants not read" });
  } finally {
    await pool.end();
    close();
  }
  process.exit(failed === 0 ? 0 : 1);
}
