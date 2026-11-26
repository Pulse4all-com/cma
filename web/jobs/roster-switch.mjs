/**
 * The roster drives the day (addition 0010a, brief B, E2 and E9; Decision log, 26 Nov 2026): once a minute, one statement
 * for every tenant, cma.roster_switch_all(), which serves each tenant as its own Scheduler user (permission
 * workday.roster_switch, actor label scheduler:roster): every agent with an open session whose published block starts at
 * a boundary passed since their last event is switched to the block's assignment and market (source roster), even during
 * a call; an absence block ends the workday at its start. Idempotent per person and boundary: a run that finds the switch
 * written, the agent's own Switch after it, or a later Clock in writes nothing, so an overlapping or repeated run is
 * harmless. The function refuses a connection that carries a tenant or a user (CMA06): only a job runs it.
 *
 * Runs as a Cloud Run job on the web image (command: node jobs/roster-switch.mjs), started by Cloud Scheduler every minute
 * (docs/scheduler/deploy-roster-switch.sh), with the same database variables as the service and the other jobs:
 *   CMA_DB_INSTANCE  <project>:<region>:<instance>   with the Cloud SQL connector and IAM auth
 *   CMA_DB_USER      <service account>@<project>.iam  member of cma_app
 *   CMA_DB_NAME      cma
 *   CMA_DB_HOST/PORT/PASSWORD  the local path for a verifier run (never set on Cloud Run)
 *   CMA_DB_SET_ROLE=cma_app    a verifier aid for a personal login that holds cma_app without inheritance
 * One JSON log line per tenant with work (severity, message roster-switch, tenant_id, switched, ended) and one per run
 * (tenants, switched, ended, failed, duration_ms): counts only, never a name or a person's id. A tenant whose switch failed
 * shows as failed with its SQLSTATE (the others are served); exit 1 then. A lost connection is retried once on a fresh
 * one, as the other jobs do (jobs/lib/connection.mjs); the retry repeats nothing, since the switch is idempotent.
 * It writes no cma.sync_run row: System health does not list it yet (the PR says so); its log line is the record.
 */
import pg from "pg";
import { codeOf, hearIdleErrors, isMain, retryOnce, withClient } from "./lib/connection.mjs";
import { sessionPoolOptions } from "./lib/session-options.mjs";

async function openPool() {
  const database = process.env.CMA_DB_NAME ?? "cma";
  if (process.env.CMA_DB_HOST) {
    return { pool: new pg.Pool({ host: process.env.CMA_DB_HOST, port: Number(process.env.CMA_DB_PORT ?? 5432), user: required("CMA_DB_USER"),
      password: process.env.CMA_DB_PASSWORD || undefined, database, max: 1, application_name: "cma-roster-switch-local", ...sessionPoolOptions() }), close: () => undefined };
  }
  const { Connector, AuthTypes, IpAddressTypes } = await import("@google-cloud/cloud-sql-connector");
  const connector = new Connector();
  try {
    const opts = await connector.getOptions({
      instanceConnectionName: required("CMA_DB_INSTANCE"),
      authType: AuthTypes.IAM,
      ipType: process.env.CMA_DB_IP === "PRIVATE" ? IpAddressTypes.PRIVATE : IpAddressTypes.PUBLIC,
    });
    return { pool: new pg.Pool({ ...opts, user: required("CMA_DB_USER"), database, max: 1, application_name: "cma-roster-switch", ...sessionPoolOptions() }), close: () => connector.close() };
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

const log = (severity, fields) => console.log(JSON.stringify({ severity, message: "roster-switch", ...fields }));

/**
 * One run: cma.roster_switch_all() in one transaction on a connection without a tenant or user; connect() gives a client.
 * Answers { tenants, switched, ended, failed } (tenants: the tenants with work or a failure in this run)
 */
export async function switchAll({ connect }) {
  const rows = await retryOnce(() => withClient(connect, async (client) => {
    try {
      await client.query("begin");
      await client.query("select set_config('app.tenant_id', '', true), set_config('app.user_id', '', true), set_config('app.actor_label', '', true)");
      const r = await client.query("select tenant_id, action from cma.roster_switch_all()");
      await client.query("commit");
      return r.rows;
    } catch (e) {
      await client.query("rollback").catch(() => undefined);
      throw e;
    }
  }), { log: (severity, fields) => log("WARNING", { reason: fields.reason, error: fields.error }), fields: { step: "switch" } });
  const per = new Map();
  for (const r of rows) {
    const t = per.get(r.tenant_id) ?? { switched: 0, ended: 0, failed: null };
    if (r.action === "switched") t.switched += 1;
    else if (r.action === "ended") t.ended += 1;
    else if (String(r.action).startsWith("failed:")) t.failed = String(r.action).slice(7);
    per.set(r.tenant_id, t);
  }
  let switched = 0, ended = 0, failed = 0;
  for (const [tenant_id, t] of per) {
    switched += t.switched;
    ended += t.ended;
    if (t.failed) failed += 1;
    log(t.failed ? "ERROR" : "INFO", { tenant_id, switched: t.switched, ended: t.ended, ...(t.failed ? { error: t.failed } : {}) });
  }
  return { tenants: per.size, switched, ended, failed };
}

if (isMain(import.meta.url)) {
  const t0 = Date.now();
  const setRole = process.env.CMA_DB_SET_ROLE;
  if (setRole && setRole !== "cma_app") throw new Error("CMA_DB_SET_ROLE can only be cma_app");
  let opened;
  try {
    opened = await retryOnce(openPool, { log: (s, f) => log("WARNING", { reason: f.reason, error: f.error }), fields: { step: "pool" } });
  } catch (e) {
    log("ERROR", { reason: "pool not opened", error: codeOf(e) });
    process.exit(1);
  }
  const { pool, close } = opened;
  hearIdleErrors(pool, (severity, fields) => log("WARNING", { reason: fields.reason, error: fields.error }));
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
  let code = 1;
  try {
    const r = await switchAll({ connect });
    log(r.failed ? "ERROR" : "INFO", { ...r, duration_ms: Date.now() - t0 });
    code = r.failed ? 1 : 0;
  } catch (e) {
    log("ERROR", { reason: "run failed", error: codeOf(e), duration_ms: Date.now() - t0 });
  } finally {
    await pool.end().catch(() => undefined);
    close();
  }
  process.exit(code);
}
