/**
 * The follow-up refresh (addition 0008s; Decision log, 18 October 2026): computes every tenant's follow-up
 * snapshot once a minute (cma.refresh_follow_up(): open leads, tickets and tasks evaluated once each, the counts
 * and the figures per person), as each tenant's own Scheduler user (follow_up.refresh), so Reports → Follow-up,
 * the Live board's card and Welcome read figures at most about a minute old instead of building the three sets
 * on every request.
 *
 * Runs as a Cloud Run job on the web image (command: node jobs/refresh-follow-up.mjs), started by Cloud Scheduler
 * every minute (docs/scheduler/deploy-follow-up.sh), with the same database variables as the service:
 *   CMA_DB_INSTANCE  <project>:<region>:<instance>   with the Cloud SQL connector and IAM auth
 *   CMA_DB_USER      <service account>@<project>.iam  member of cma_app
 *   CMA_DB_NAME      cma
 *   CMA_DB_HOST/PORT/PASSWORD  the local path for a verifier run (never set on Cloud Run)
 *   CMA_DB_SET_ROLE=cma_app    a verifier aid for a personal login that holds cma_app without inheritance; never
 *                              set on Cloud Run, where the service account's IAM user inherits cma_app
 * Plain JavaScript on pg and the connector, so it needs no build step and no part of Next; pool of 2 (README,
 * Database connection budget). Every tenant is served in turn and one tenant's failure never stops the others.
 * Each tenant leaves one sync_run row (job refresh_follow_up, no connection: started, then succeeded with the rows
 * and duration_ms, skipped 1 when another refresh of the tenant was running, or failed with a code) through
 * cma.job_run_start() and cma.job_run_finish(), so Configuration → System health shows the job; and one JSON log
 * line: the tenant's id, the rows, duration_ms. Never a name or a record id. Exit code 0 when every tenant was
 * served, 1 when any tenant failed (Cloud Scheduler retries nothing; the next minute does).
 */
import pg from "pg";

const LOGIN_SYSTEM = "scheduler";   // the login id of each tenant's system user, as 0005a writes it
const LOGIN_ID = "scheduler";
const ACTOR_LABEL = "scheduler";
const JOB = "refresh_follow_up";
// A refresh that runs past this is cancelled (57014) and the tenant's row says so: the next minute starts another
const STATEMENT_TIMEOUT_MS = 55_000;

async function openPool() {
  const database = process.env.CMA_DB_NAME ?? "cma";
  const common = { database, max: 2, statement_timeout: STATEMENT_TIMEOUT_MS, connectionTimeoutMillis: 10_000 };
  if (process.env.CMA_DB_HOST) {
    return { pool: new pg.Pool({ host: process.env.CMA_DB_HOST, port: Number(process.env.CMA_DB_PORT ?? 5432), user: required("CMA_DB_USER"),
      password: process.env.CMA_DB_PASSWORD || undefined, ...common, application_name: "cma-refresh-follow-up-local" }), close: () => undefined };
  }
  const { Connector, AuthTypes, IpAddressTypes } = await import("@google-cloud/cloud-sql-connector");
  const connector = new Connector();
  const opts = await connector.getOptions({
    instanceConnectionName: required("CMA_DB_INSTANCE"),
    authType: AuthTypes.IAM,
    ipType: process.env.CMA_DB_IP === "PRIVATE" ? IpAddressTypes.PRIVATE : IpAddressTypes.PUBLIC,
  });
  return { pool: new pg.Pool({ ...opts, user: required("CMA_DB_USER"), ...common, application_name: "cma-refresh-follow-up" }), close: () => connector.close() };
}

function required(name) {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is not set`);
  return v;
}

/** One line for Cloud Logging (jsonPayload): severity, message, the tenant's id and counts only */
function log(severity, fields) {
  console.log(JSON.stringify({ severity, message: "refresh-follow-up", ...fields }));
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

const setRole = process.env.CMA_DB_SET_ROLE;
if (setRole && setRole !== "cma_app") throw new Error("CMA_DB_SET_ROLE can only be cma_app");
const { pool, close } = await openPool();
async function connect() {
  const client = await pool.connect();
  if (setRole) await client.query("set role cma_app");
  return client;
}
let failed = 0;
try {
  // Before a tenant is known: the SECURITY DEFINER lookup, tenant ids only
  const lookup = await connect();
  let tenants;
  try {
    tenants = (await lookup.query("select tenant_id from cma.find_tenants_for_identity($1, $2)", [LOGIN_SYSTEM, LOGIN_ID])).rows;
  } finally {
    lookup.release();
  }
  for (const { tenant_id } of tenants) {
    const client = await connect();
    let runId = null;
    let me = null;
    try {
      // 1. The scheduler's own user in this tenant, as cma_app under row-level security
      const who = await asScheduler(client, tenant_id, "",
        `select u.id from cma.app_user_external_id x join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id
          where x.tenant_id = cma.current_tenant_id() and x.system = $1 and x.external_id = $2 and u.status = 'active'`, [LOGIN_SYSTEM, LOGIN_ID]);
      me = who.rows[0]?.id ?? null;
      if (!me) throw Object.assign(new Error("no active scheduler user"), { code: "NO_SCHEDULER" });
      // 2. The run row, before the refresh, so a refresh that fails still leaves a failed row
      runId = (await asScheduler(client, tenant_id, me, "select cma.job_run_start($1) as id", [JOB])).rows[0].id;
      // 3. The refresh: skipped when another refresh of this tenant holds its lock (a run that overran its minute)
      const r = (await asScheduler(client, tenant_id, me, "select cma.refresh_follow_up() as r")).rows[0].r;
      const counts = r.refreshed
        ? { rows: r.rows, leads: r.leads, tickets: r.tickets, tasks: r.tasks, duration_ms: r.duration_ms, skipped: 0 }
        : { rows: 0, duration_ms: 0, skipped: 1 };
      await asScheduler(client, tenant_id, me, "select cma.job_run_finish($1::uuid, 'succeeded', $2::jsonb)", [runId, JSON.stringify(counts)]);
      log(r.refreshed ? "INFO" : "WARNING", { tenant_id, rows: counts.rows, duration_ms: counts.duration_ms, refreshed: Boolean(r.refreshed),
        ...(r.refreshed ? {} : { reason: r.reason ?? "running" }) });
    } catch (e) {
      failed += 1;
      log("ERROR", { tenant_id, rows: 0, duration_ms: 0, refreshed: false, error: e.code ?? "error" });
      if (runId && me) {
        await asScheduler(client, tenant_id, me, "select cma.job_run_finish($1::uuid, 'failed', '{}'::jsonb, $2)", [runId, e.code ?? "error"])
          .catch((f) => log("ERROR", { tenant_id, rows: 0, duration_ms: 0, refreshed: false, error: `run row not finished: ${f.code ?? "error"}` }));
      }
    } finally {
      client.release();
    }
  }
  if (tenants.length === 0) log("WARNING", { tenant_id: null, rows: 0, duration_ms: 0, refreshed: false, reason: "no tenant with a scheduler user" });
} finally {
  await pool.end();
  close();
}
process.exit(failed === 0 ? 0 : 1);
