/**
 * The data-quality refresh (addition 0008zr; Decision log, 5 November 2026, night N06): computes every tenant's
 * stored data-quality result (cma.refresh_data_quality(): every check of cma.data_quality_of evaluated once, the
 * findings with their market and where they are fixed, stored in cma.data_quality_finding with the result's Refreshed
 * at in cma.data_quality_snapshot), as each tenant's own Scheduler user (data_quality.refresh), so Reports → Data
 * quality, Flash's data-quality overview and list, the snapshot take and the watch read a stored result instead of
 * running every check live (2 to 3.5 seconds in prod on 3 November 2026).
 *
 * Runs as a Cloud Run job on the web image (command: node jobs/refresh-data-quality.mjs), started by Cloud Scheduler
 * every minute (docs/scheduler/deploy-data-quality.sh); the database decides whether a tenant's result is due: a
 * result younger than the tenant's data_quality.refresh_minutes (5 by default) is kept (the run row says skipped with
 * reason fresh), so the setting is the cadence and the schedule only the clock. The same database variables as the
 * service:
 *   CMA_DB_INSTANCE  <project>:<region>:<instance>   with the Cloud SQL connector and IAM auth
 *   CMA_DB_USER      <service account>@<project>.iam  member of cma_app
 *   CMA_DB_NAME      cma
 *   CMA_DB_HOST/PORT/PASSWORD  the local path for a verifier run (never set on Cloud Run)
 *   CMA_DB_SET_ROLE=cma_app    a verifier aid for a personal login that holds cma_app without inheritance; never
 *                              set on Cloud Run, where the service account's IAM user inherits cma_app
 * Plain JavaScript on pg and the connector, so it needs no build step and no part of Next; pool of 1 (README,
 * Database connection budget: the job holds one connection, the tenants are served one after another). One
 * tenant's failure never stops the others. Each tenant leaves one sync_run row (job refresh_data_quality, no
 * connection: started, then succeeded with the rows and duration_ms, skipped 1 with the reason when the result was
 * fresh or another refresh of the tenant was running, or failed with a code) through cma.job_run_start() and
 * cma.job_run_finish(), so Configuration → System health shows the job; and one JSON log line: the tenant's id, the
 * rows, duration_ms. Never a name or a record id. Exit code 0 when every tenant was served, 1 when any tenant failed
 * (Cloud Scheduler retries nothing; the next minute does).
 *
 * A dropped database connection (jobs/lib/connection.mjs): as the follow-up refresh, a tenant's unit is retried once
 * on a fresh connection after a connection error, its run row kept; a second failure fails the tenant and its run row.
 */
import pg from "pg";
import { codeOf, hearIdleErrors, isMain, retryOnce, withClient } from "./lib/connection.mjs";

const LOGIN_SYSTEM = "scheduler";   // the login id of each tenant's system user, as 0005a writes it
const LOGIN_ID = "scheduler";
const ACTOR_LABEL = "scheduler";
const JOB = "refresh_data_quality";
// A refresh that runs past this is cancelled (57014) and the tenant's row says so: the next minute starts another
// (every check live took 2 to 3.5 s in prod on 3 November 2026; 4.5 s at three times that volume locally)
const STATEMENT_TIMEOUT_MS = 55_000;

async function openPool() {
  const database = process.env.CMA_DB_NAME ?? "cma";
  const common = { database, max: 1, statement_timeout: STATEMENT_TIMEOUT_MS, connectionTimeoutMillis: 10_000 };
  if (process.env.CMA_DB_HOST) {
    return { pool: new pg.Pool({ host: process.env.CMA_DB_HOST, port: Number(process.env.CMA_DB_PORT ?? 5432), user: required("CMA_DB_USER"),
      password: process.env.CMA_DB_PASSWORD || undefined, ...common, application_name: "cma-refresh-data-quality-local" }), close: () => undefined };
  }
  const { Connector, AuthTypes, IpAddressTypes } = await import("@google-cloud/cloud-sql-connector");
  const connector = new Connector();
  try {
    const opts = await connector.getOptions({
      instanceConnectionName: required("CMA_DB_INSTANCE"),
      authType: AuthTypes.IAM,
      ipType: process.env.CMA_DB_IP === "PRIVATE" ? IpAddressTypes.PRIVATE : IpAddressTypes.PUBLIC,
    });
    return { pool: new pg.Pool({ ...opts, user: required("CMA_DB_USER"), ...common, application_name: "cma-refresh-data-quality" }), close: () => connector.close() };
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

/** One line for Cloud Logging (jsonPayload): severity, message, the tenant's id and counts only */
function log(severity, fields) {
  console.log(JSON.stringify({ severity, message: "refresh-data-quality", ...fields }));
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
 * Every tenant with a scheduler user, refreshed in turn; connect() gives a client of the pool. Answers
 * { tenants, failed }. Exported for verify/jobs.mjs, which runs it on a mocked pool.
 */
export async function refreshTenants({ connect, log }) {
  // Before a tenant is known: the SECURITY DEFINER lookup, tenant ids only
  const tenants = await retryOnce(() => withClient(connect, async (client) =>
    (await client.query("select tenant_id from cma.find_tenants_for_identity($1, $2)", [LOGIN_SYSTEM, LOGIN_ID])).rows), { log, fields: { tenant_id: null, step: "tenants" } });
  let failed = 0;
  for (const { tenant_id } of tenants) {
    let runId = null;
    let me = null;
    try {
      // One unit, retried once on a fresh connection after a connection error; what it already did is kept
      const { r, counts } = await retryOnce(() => withClient(connect, async (client) => {
        // 1. The scheduler's own user in this tenant, as cma_app under row-level security
        if (!me) {
          const who = await asScheduler(client, tenant_id, "",
            `select u.id from cma.app_user_external_id x join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id
              where x.tenant_id = cma.current_tenant_id() and x.system = $1 and x.external_id = $2 and u.status = 'active'`, [LOGIN_SYSTEM, LOGIN_ID]);
          me = who.rows[0]?.id ?? null;
          if (!me) throw Object.assign(new Error("no active scheduler user"), { code: "NO_SCHEDULER" });
        }
        // 2. The run row, before the refresh, so a refresh that fails still leaves a failed row; once per tenant and run
        if (!runId) runId = (await asScheduler(client, tenant_id, me, "select cma.job_run_start($1) as id", [JOB])).rows[0].id;
        // 3. The refresh: skipped while the tenant's result is younger than its setting (reason fresh) or when another
        // refresh of this tenant holds its lock (reason running)
        const r = (await asScheduler(client, tenant_id, me, "select cma.refresh_data_quality() as r")).rows[0].r;
        const counts = r.refreshed
          ? { rows: r.rows, duration_ms: r.duration_ms, skipped: 0 }
          : { rows: 0, duration_ms: 0, skipped: 1 };
        await asScheduler(client, tenant_id, me, "select cma.job_run_finish($1::uuid, 'succeeded', $2::jsonb)", [runId, JSON.stringify(counts)]);
        return { r, counts };
      }), { log, fields: { tenant_id } });
      // A fresh result is the normal case between two due minutes: INFO; a refresh skipped for a running one is a warning
      log(r.refreshed || r.reason === "fresh" ? "INFO" : "WARNING", { tenant_id, rows: counts.rows, duration_ms: counts.duration_ms, refreshed: Boolean(r.refreshed),
        ...(r.refreshed ? {} : { reason: r.reason ?? "running" }) });
    } catch (e) {
      failed += 1;
      log("ERROR", { tenant_id, rows: 0, duration_ms: 0, refreshed: false, error: codeOf(e) });
      if (runId && me) {
        await retryOnce(() => withClient(connect, (client) =>
          asScheduler(client, tenant_id, me, "select cma.job_run_finish($1::uuid, 'failed', '{}'::jsonb, $2)", [runId, codeOf(e)])), { log, fields: { tenant_id } })
          .catch((f) => log("ERROR", { tenant_id, rows: 0, duration_ms: 0, refreshed: false, error: `run row not finished: ${codeOf(f)}` }));
      }
    }
  }
  if (tenants.length === 0) log("WARNING", { tenant_id: null, rows: 0, duration_ms: 0, refreshed: false, reason: "no tenant with a scheduler user" });
  return { tenants: tenants.length, failed };
}

if (isMain(import.meta.url)) {
  const setRole = process.env.CMA_DB_SET_ROLE;
  if (setRole && setRole !== "cma_app") throw new Error("CMA_DB_SET_ROLE can only be cma_app");
  let opened;
  try {
    opened = await retryOnce(openPool, { log, fields: { tenant_id: null, step: "pool" } });
  } catch (e) {
    log("ERROR", { tenant_id: null, rows: 0, duration_ms: 0, refreshed: false, error: codeOf(e), reason: "pool not opened" });
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
    ({ failed } = await refreshTenants({ connect, log }));
  } catch (e) {
    log("ERROR", { tenant_id: null, rows: 0, duration_ms: 0, refreshed: false, error: codeOf(e), reason: "tenants not read" });
  } finally {
    await pool.end();
    close();
  }
  process.exit(failed === 0 ? 0 : 1);
}
