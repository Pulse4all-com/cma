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
 * Since addition 0008r (the IT audit of 17 October 2026) every execution leaves one sync_run row per tenant
 * (job close_forgotten_workdays: started, finished, the count of days closed, or failed with a code) through
 * cma.scheduler_run_start() and cma.scheduler_run_finish(), for Configuration → System health; a database
 * without 0008r writes no row and the close goes on.
 * Idempotent: a second run in the same hour finds nothing. Exit code 0 when every tenant was
 * served, 1 when any tenant failed (the others are still served; Cloud Scheduler retries nothing,
 * the next hour does).
 *
 * A dropped database connection (jobs/lib/connection.mjs; 18 October 2026): an idle connection's reset is a
 * warning line; a tenant's close, or the tenant lookup, that fails with a connection error is retried once on a
 * fresh connection, its run row kept (one row per tenant and run), and the run row's finish is retried on its
 * own, so a reset there never repeats the close. A second failure fails the tenant and its run row as before;
 * opening the pool or reading the tenants failing twice is one FAILED line and exit 1.
 */
import pg from "pg";
import { codeOf, hearIdleErrors, isConnectionError, isMain, retryOnce, withClient } from "./lib/connection.mjs";

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
  try {
    const opts = await connector.getOptions({
      instanceConnectionName: required("CMA_DB_INSTANCE"),
      authType: AuthTypes.IAM,
      ipType: process.env.CMA_DB_IP === "PRIVATE" ? IpAddressTypes.PRIVATE : IpAddressTypes.PUBLIC,
    });
    return { pool: new pg.Pool({ ...opts, user: required("CMA_DB_USER"), database, max: 2, application_name: "cma-scheduler" }), close: () => connector.close() };
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

/** A retry or an idle connection's loss as one line of this job's plain log */
const lineOf = (out) => (severity, fields) => out.warn(`  ${fields.tenant ? `tenant ${fields.tenant}: ` : ""}${fields.step ? `${fields.step}: ` : ""}${fields.reason} (${fields.error})`);

/**
 * The scheduler's run row (0008r): one short transaction of its own; a missing function (a database before 0008r) is
 * no error. A lost connection is thrown, so the tenant's work is retried on a fresh one; any other failure is a line.
 */
async function startRun(client, tenantId, userId, out) {
  try {
    await client.query("begin");
    await client.query("select set_config('app.tenant_id', $1, true), set_config('app.user_id', $2, true), set_config('app.actor_label', $3, true)", [tenantId, userId, ACTOR_LABEL]);
    const r = await client.query("select cma.scheduler_run_start() as id");
    await client.query("commit");
    return r.rows[0].id;
  } catch (e) {
    await client.query("rollback").catch(() => undefined);
    if (isConnectionError(e)) throw e;
    if (e.code !== "42883") out.warn(`  run row not started: ${e.code ?? ""}`);
    return null;
  }
}

async function finishRun(client, tenantId, userId, runId, status, closed, error, out) {
  if (!runId) return;
  try {
    await client.query("begin");
    await client.query("select set_config('app.tenant_id', $1, true), set_config('app.user_id', $2, true), set_config('app.actor_label', $3, true)", [tenantId, userId, ACTOR_LABEL]);
    await client.query("select cma.scheduler_run_finish($1::uuid, $2, $3::integer, $4)", [runId, status, closed, error]);
    await client.query("commit");
  } catch (e) {
    await client.query("rollback").catch(() => undefined);
    if (isConnectionError(e)) throw e;
    out.warn(`  run row not finished: ${e.code ?? ""}`);
  }
}

/** The run row's finish on a connection of its own, retried once after a lost connection; never fails the tenant */
async function finishRunRetried(connect, tenantId, userId, runId, status, closed, error, out) {
  await retryOnce(() => withClient(connect, (client) => finishRun(client, tenantId, userId, runId, status, closed, error, out)),
    { log: lineOf(out), fields: { tenant: tenantId, step: "run row" } })
    .catch((e) => out.warn(`  run row not finished: ${codeOf(e)}`));
}

/**
 * Every tenant with a scheduler user, its forgotten days closed in turn; connect() gives a client of the pool, out
 * is the console. Answers { tenants, failed }. Exported for verify/jobs.mjs, which runs it on a mocked pool.
 */
export async function closeTenants({ connect, grace = null, out = console }) {
  // Before a tenant is known: the SECURITY DEFINER lookup, tenant ids only
  const tenants = await retryOnce(() => withClient(connect, async (client) =>
    (await client.query("select tenant_id from cma.find_tenants_for_identity($1, $2)", [LOGIN_SYSTEM, LOGIN_ID])).rows), { log: lineOf(out), fields: { step: "tenants" } });
  out.log(`close-forgotten-workdays: ${tenants.length} tenant(s)${grace !== null ? `, grace override ${grace} minutes` : ""}`);
  let failed = 0;
  for (const { tenant_id } of tenants) {
    let runId;   // undefined until started; null when the database has no run rows (before 0008r)
    let me = null;
    try {
      // One unit, retried once on a fresh connection after a connection error; what it already did is kept
      const closed = await retryOnce(() => withClient(connect, async (client) => {
        try {
          // 1. Inside the tenant, as cma_app under row-level security: the scheduler's own user (a read of its own)
          if (!me) {
            await client.query("begin");
            await client.query("select set_config('app.tenant_id', $1, true), set_config('app.user_id', '', true), set_config('app.actor_label', $2, true)", [tenant_id, ACTOR_LABEL]);
            const who = await client.query(
              `select u.id, t.slug from cma.app_user_external_id x
                 join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id
                 join cma.tenant t on t.id = x.tenant_id
                where x.tenant_id = cma.current_tenant_id() and x.system = $1 and x.external_id = $2 and u.status = 'active'`, [LOGIN_SYSTEM, LOGIN_ID]);
            await client.query("commit");
            me = who.rows[0] ?? null;
            if (!me) throw new Error(`tenant ${tenant_id}: no active scheduler user`);
          }
          // 2. The run row System health shows (addition 0008r), in a transaction of its own before the close, so a
          //    close that fails still leaves a failed row; a database without 0008r leaves no row and the close goes on
          if (runId === undefined) runId = await startRun(client, tenant_id, me.id, out);
          // 3. The close, as the scheduler user
          await client.query("begin");
          await client.query("select set_config('app.tenant_id', $1, true), set_config('app.user_id', $2, true), set_config('app.actor_label', $3, true)", [tenant_id, me.id, ACTOR_LABEL]);
          const r = await client.query("select workday_id, user_id, business_date, ended_at from cma.close_forgotten_workdays($1)", [grace]);
          await client.query("commit");
          return r;
        } catch (e) {
          await client.query("rollback").catch(() => undefined);
          throw e;
        }
      }), { log: lineOf(out), fields: { tenant: tenant_id } });
      await finishRunRetried(connect, tenant_id, me.id, runId, "succeeded", closed.rowCount, null, out);
      // Counts and dates only: no names, no ids in the log
      out.log(`  ${me.slug}: closed ${closed.rowCount} day(s)${closed.rowCount ? ` (${[...new Set(closed.rows.map((r) => r.business_date))].sort().join(", ")})` : ""}`);
    } catch (e) {
      failed += 1;
      out.error(`  tenant ${tenant_id}: FAILED ${e.code ?? ""} ${e.message}`);
      if (runId && me) await finishRunRetried(connect, tenant_id, me.id, runId, "failed", 0, codeOf(e), out);
    }
  }
  return { tenants: tenants.length, failed };
}

if (isMain(import.meta.url)) {
  const grace = process.env.CMA_GRACE_MINUTES ? Number(process.env.CMA_GRACE_MINUTES) : null;
  const setRole = process.env.CMA_DB_SET_ROLE;
  if (setRole && setRole !== "cma_app") throw new Error("CMA_DB_SET_ROLE can only be cma_app");
  let opened;
  try {
    opened = await retryOnce(openPool, { log: lineOf(console), fields: { step: "pool" } });
  } catch (e) {
    console.error(`close-forgotten-workdays: FAILED, pool not opened: ${codeOf(e)}`);
    process.exit(1);
  }
  const { pool, close } = opened;
  hearIdleErrors(pool, lineOf(console));
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
    ({ failed } = await closeTenants({ connect, grace }));
  } catch (e) {
    console.error(`close-forgotten-workdays: FAILED, tenants not read: ${codeOf(e)}`);
  } finally {
    await pool.end();
    close();
  }
  process.exit(failed === 0 ? 0 : 1);
}
