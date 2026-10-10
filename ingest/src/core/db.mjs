/**
 * Database access for the ingest service and its jobs: one pool per process, every unit of work one
 * transaction with the tenant context set by set_config(..., true), exactly as the web app's
 * src/lib/db/client.ts and the scheduler's job connect.
 *
 *   withoutTenant  no tenant context: only cma.ingest_connection(key), the SECURITY DEFINER lookup
 *   withTenant     app.tenant_id, app.user_id (the tenant's Ingest user) and app.actor_label
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
 * Local only (never set on Cloud Run): CMA_DB_HOST, CMA_DB_PORT, CMA_DB_PASSWORD for a plain
 * connection to a local PostgreSQL (the flow verifier), and CMA_DB_SET_ROLE=cma_app for a login that
 * holds cma_app without inheritance.
 */
import pg from "pg";

// A business date stays a YYYY-MM-DD string; bigint counts fit a JS number
pg.types.setTypeParser(1082, (v) => v);
pg.types.setTypeParser(20, (v) => Number(v));

function required(name) {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is not set`);
  return v;
}

let state = null;

async function open() {
  const database = process.env.CMA_DB_NAME ?? "cma";
  const max = Number(process.env.CMA_DB_POOL_MAX ?? 5);
  const setRole = process.env.CMA_DB_SET_ROLE;
  if (setRole && setRole !== "cma_app") throw new Error("CMA_DB_SET_ROLE can only be cma_app");
  let pool;
  let close = () => undefined;
  if (process.env.CMA_DB_HOST) {
    pool = new pg.Pool({
      host: process.env.CMA_DB_HOST, port: Number(process.env.CMA_DB_PORT ?? 5432), user: required("CMA_DB_USER"),
      password: process.env.CMA_DB_PASSWORD || undefined, database, max, idleTimeoutMillis: 30_000,
      connectionTimeoutMillis: 10_000, application_name: "cma-ingest-local",
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
      connectionTimeoutMillis: 10_000, application_name: "cma-ingest" });
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
  const client = await pool.connect();
  try {
    await client.query("begin");
    await setContext(client);
    const result = await fn(client);
    await client.query("commit");
    return result;
  } catch (err) {
    await client.query("rollback").catch(() => undefined);
    throw err;
  } finally {
    client.release();
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
