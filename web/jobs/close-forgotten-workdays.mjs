/**
 * The scheduler's job (migration 0005a, Roadmap step 5): ends every workday that was never clocked
 * out once its business day has ended plus the tenant's grace (workday.auto_close_grace_minutes,
 * default 120), in every tenant of this database, as each tenant's own Scheduler user, so the
 * audit names it (actor_user_id the scheduler, actor_label "scheduler", source "system"). The day
 * stays flagged until a manager corrects or confirms it (README, Features 1).
 *
 * Runs as a Cloud Run job on the web image (command: node jobs/close-forgotten-workdays.mjs),
 * started by Cloud Scheduler every hour, with the same database variables as the service:
 *   CMA_DB_INSTANCE  <project>:<region>:<instance>   with the Cloud SQL connector and IAM auth
 *   CMA_DB_USER      <service account>@<project>.iam  member of cma_app
 *   CMA_DB_NAME      cma
 *   CMA_DB_HOST/PORT/PASSWORD  the local path for a verifier run (never set on Cloud Run)
 *   CMA_GRACE_MINUTES          optional override of every tenant's grace (a test aid, logged)
 *   CMA_DB_SET_ROLE=cma_app    a verifier aid for a personal login that holds cma_app without inheritance
 *                              (Cloud Shell through the Auth Proxy); never set on Cloud Run, where the
 *                              service account's IAM user inherits cma_app
 * Plain JavaScript on pg and the connector, so it needs no build step and no part of Next: the
 * tenant context is the same set_config(..., true) per transaction as src/lib/db/client.ts.
 * Idempotent: a second run in the same hour finds nothing. Exit code 0 when every tenant was
 * served, 1 when any tenant failed (the others are still served; Cloud Scheduler retries nothing,
 * the next hour does).
 */
import pg from "pg";

// A business date stays a YYYY-MM-DD string: it has no instant and must not shift zones (as client.ts)
pg.types.setTypeParser(1082, (v) => v);

const LOGIN_SYSTEM = "scheduler";   // the login id of each tenant's system user, as 0005a writes it
const LOGIN_ID = "scheduler";
const ACTOR_LABEL = "scheduler";

async function openPool() {
  const database = process.env.CMA_DB_NAME ?? "cma";
  if (process.env.CMA_DB_HOST) {
    return { pool: new pg.Pool({ host: process.env.CMA_DB_HOST, port: Number(process.env.CMA_DB_PORT ?? 5432), user: required("CMA_DB_USER"),
      password: process.env.CMA_DB_PASSWORD || undefined, database, max: 2, application_name: "cma-scheduler-local" }), close: () => undefined };
  }
  const { Connector, AuthTypes, IpAddressTypes } = await import("@google-cloud/cloud-sql-connector");
  const connector = new Connector();
  const opts = await connector.getOptions({
    instanceConnectionName: required("CMA_DB_INSTANCE"),
    authType: AuthTypes.IAM,
    ipType: process.env.CMA_DB_IP === "PRIVATE" ? IpAddressTypes.PRIVATE : IpAddressTypes.PUBLIC,
  });
  return { pool: new pg.Pool({ ...opts, user: required("CMA_DB_USER"), database, max: 2, application_name: "cma-scheduler" }), close: () => connector.close() };
}

function required(name) {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is not set`);
  return v;
}

const grace = process.env.CMA_GRACE_MINUTES ? Number(process.env.CMA_GRACE_MINUTES) : null;
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
  console.log(`close-forgotten-workdays: ${tenants.length} tenant(s)${grace !== null ? `, grace override ${grace} minutes` : ""}`);
  for (const { tenant_id } of tenants) {
    const client = await connect();
    try {
      await client.query("begin");
      await client.query("select set_config('app.tenant_id', $1, true), set_config('app.user_id', '', true), set_config('app.actor_label', $2, true)", [tenant_id, ACTOR_LABEL]);
      // Inside the tenant, as cma_app under row-level security: the scheduler's own user
      const who = await client.query(
        `select u.id, t.slug from cma.app_user_external_id x
           join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id
           join cma.tenant t on t.id = x.tenant_id
          where x.tenant_id = cma.current_tenant_id() and x.system = $1 and x.external_id = $2 and u.status = 'active'`, [LOGIN_SYSTEM, LOGIN_ID]);
      const me = who.rows[0];
      if (!me) throw new Error(`tenant ${tenant_id}: no active scheduler user`);
      await client.query("select set_config('app.user_id', $1, true)", [me.id]);
      const closed = await client.query("select workday_id, user_id, business_date, ended_at from cma.close_forgotten_workdays($1)", [grace]);
      await client.query("commit");
      // Counts and dates only: no names, no ids in the log
      console.log(`  ${me.slug}: closed ${closed.rowCount} day(s)${closed.rowCount ? ` (${[...new Set(closed.rows.map((r) => r.business_date))].sort().join(", ")})` : ""}`);
    } catch (e) {
      failed += 1;
      await client.query("rollback").catch(() => undefined);
      console.error(`  tenant ${tenant_id}: FAILED ${e.code ?? ""} ${e.message}`);
    } finally {
      client.release();
    }
  }
} finally {
  await pool.end();
  close();
}
process.exit(failed === 0 ? 0 : 1);
