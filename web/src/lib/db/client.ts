import 'server-only';
import pg from 'pg';
import { trace } from '@opentelemetry/api';
import { AuthTypes, Connector, IpAddressTypes } from '@google-cloud/cloud-sql-connector';
import { CMA_SQLSTATE, CmaDbError, isCmaSqlState } from '@/lib/data/errors';

/**
 * Database client for the CMA web app.
 *
 * One connector and one pool per process, opened lazily on first use and closed on SIGTERM.
 * Every database interaction runs inside one transaction with the tenant context set via
 * set_config(..., true), which is transaction-local: a pooled connection can never carry one
 * request's tenant into the next. Two shapes exist on purpose:
 *
 *   withoutTenant  no app.tenant_id, for cma.find_tenants_for_identity() only
 *   withTenant     app.tenant_id and app.user_id set, everything else
 *
 * Authentication is automatic IAM database authentication through the Cloud SQL connector:
 * the Cloud Run service account is the database user (no password anywhere). The service
 * account is a member of cma_app with plain inheritance, so no SET ROLE is needed and the
 * audit log's session_user names the service.
 *
 * Environment:
 *   CMA_DB_INSTANCE   p4a-cma-dev:europe-west4:cma-dev-pg   (connection name, required)
 *   CMA_DB_USER       cma-web@p4a-cma-dev.iam                (IAM database user, required)
 *   CMA_DB_NAME       cma                                     (default cma)
 *   CMA_DB_POOL_MAX   5                                       (per Cloud Run instance)
 *   CMA_DB_POOL_MIN   1                                       (kept open between requests; within the budget's ceiling)
 *   CMA_DB_STATEMENT_TIMEOUT_MS  15000                        (a statement longer than this is cancelled: 57014 → DB_ERROR)
 *   CMA_DB_IP         PUBLIC | PRIVATE                        (default PUBLIC)
 *
 * Local only (never set on Cloud Run, which keeps the connector path above):
 *   CMA_DB_HOST       127.0.0.1 or a socket directory    a plain PostgreSQL connection for running the
 *   CMA_DB_PORT       5433                               API verifier against a local database before dev
 *   CMA_DB_PASSWORD   optional                           sees a change (8 October 2026, night build)
 */

// ---- Error translation -----------------------------------------------------------------------

export { CMA_SQLSTATE, CmaDbError, type CmaSqlState } from '@/lib/data/errors';

/** Turns a pg error into a CmaDbError; never leaks SQL text to the caller. */
export function translateDbError(err: unknown): CmaDbError {
  if (err instanceof CmaDbError) return err;
  const e = err as { code?: string; message?: string; detail?: string };
  if (isCmaSqlState(e.code)) {
    return new CmaDbError(e.code, CMA_SQLSTATE[e.code], e.message);
  }
  // A SQLSTATE (five characters) is the database answering; anything else (no code, a network
  // code, a credential or connector failure) means the database could not be reached
  if (e.code === '57014') return new CmaDbError('DB_ERROR', 'database error', `statement cancelled by its timeout: ${e.message ?? ''}`);
  const isSqlState = typeof e.code === 'string' && /^[0-9A-Z]{5}$/.test(e.code);
  const unavailableStates = new Set(['57P01', '57P03', '53300', '08000', '08001', '08003', '08006']);
  if (!isSqlState || unavailableStates.has(e.code as string)) {
    return new CmaDbError('DB_UNAVAILABLE', 'database unavailable', e.message);
  }
  return new CmaDbError('DB_ERROR', 'database error', e.message);
}

// ---- Type parsing ----------------------------------------------------------------------------

// int8 (bigint) arrives as a string by default; the time model's second counts fit a JS number
pg.types.setTypeParser(20, (v) => Number(v));
// date must stay a 'YYYY-MM-DD' string: a business date has no instant and must not shift zones
pg.types.setTypeParser(1082, (v) => v);

// ---- Configuration ---------------------------------------------------------------------------

function required(name: string): string {
  const v = process.env[name];
  if (!v) throw new CmaDbError('DB_UNAVAILABLE', `${name} is not set`);
  return v;
}

function dbConfig() {
  return {
    instanceConnectionName: required('CMA_DB_INSTANCE'),
    user: required('CMA_DB_USER'),
    database: process.env.CMA_DB_NAME ?? 'cma',
    poolMax: Number(process.env.CMA_DB_POOL_MAX ?? 5),
    ipType: process.env.CMA_DB_IP === 'PRIVATE' ? IpAddressTypes.PRIVATE : IpAddressTypes.PUBLIC,
  };
}

// ---- Pool (one per process, survives Next.js dev reloads via globalThis) ---------------------

type DbState = { connector: Connector | null; pool: pg.Pool };
// ---- Per-request database accounting (the IT audit of 17 October 2026, section 5.6) -------------------
// Correlated by the trace id of Next's request span (src/instrumentation.node.ts registers the provider and
// consumes the record when the response ends). Counts and milliseconds only: never SQL text, parameters or
// identities. With CMA_DB_TRACE=1 (local verification, never set in cloudbuild.yaml) the API routes also
// answer with an x-cma-db header and the Shell renders a cma-db meta, for verify/round-trips.mjs.
export interface DbStats { tx: number; rt: number; dbMs: number }
// On globalThis, as the pool is: Next bundles the instrumentation file apart from the server chunks, so this module
// is instantiated twice and a module-level map would never be shared between the writer and the reader
const gs = globalThis as unknown as { __cmaDbStats?: Map<string, DbStats> };
const stats = (gs.__cmaDbStats ??= new Map<string, DbStats>());
export const DB_TRACE = process.env.CMA_DB_TRACE === '1';

/** The current request's record, created on first use; undefined outside a traced request */
export function dbStats(): DbStats | undefined {
  const id = trace.getActiveSpan()?.spanContext().traceId;
  if (!id) return undefined;
  let s = stats.get(id);
  if (!s) {
    if (stats.size > 10_000) stats.clear(); // a safety valve, never expected: takeDbStats() removes each entry
    s = { tx: 0, rt: 0, dbMs: 0 };
    stats.set(id, s);
  }
  return s;
}
/** Removes and returns the record of a finished request (called from the span processor) */
export function takeDbStats(traceId: string): DbStats | undefined {
  const s = stats.get(traceId);
  stats.delete(traceId);
  return s;
}
export function formatDbStats(s: DbStats | undefined): string {
  return s ? `tx=${s.tx};rt=${s.rt};ms=${s.dbMs.toFixed(1)}` : 'tx=0;rt=0;ms=0';
}

const g = globalThis as unknown as { __cmaDb?: Promise<DbState> | undefined };

async function open(): Promise<DbState> {
  if (process.env.CMA_DB_HOST) {
    // Local verification path: no connector, no IAM; the Cloud Run configuration never sets this
    const pool = new pg.Pool({
      host: process.env.CMA_DB_HOST,
      port: Number(process.env.CMA_DB_PORT ?? 5432),
      user: required('CMA_DB_USER'),
      password: process.env.CMA_DB_PASSWORD || undefined,
      database: process.env.CMA_DB_NAME ?? 'cma',
      ...poolTuning(),
      application_name: 'cma-web-local',
    });
    pool.on('error', (err) => console.error('[cma-db] idle client error', err.message));
    const shutdown = async () => { await pool.end(); };
    process.once('SIGTERM', shutdown);
    process.once('SIGINT', shutdown);
    await warm(pool);
    return { connector: null, pool };
  }
  const cfg = dbConfig();
  const connector = new Connector();
  const clientOpts = await connector.getOptions({
    instanceConnectionName: cfg.instanceConnectionName,
    authType: AuthTypes.IAM,
    ipType: cfg.ipType,
  });
  const pool = new pg.Pool({
    ...clientOpts,
    user: cfg.user,
    database: cfg.database,
    ...poolTuning(),
    application_name: 'cma-web',
  });
  pool.on('error', (err) => console.error('[cma-db] idle client error', err.message));
  const shutdown = async () => {
    try { await pool.end(); } finally { connector.close(); }
  };
  process.once('SIGTERM', shutdown);
  process.once('SIGINT', shutdown);
  await warm(pool);
  return { connector, pool };
}

/**
 * The pool's tuning (the IT audit of 17 October 2026, finding 5.6-04). Before: no minimum and a 30-second
 * idle timeout, so after every quiet half minute the next page paid a fresh connection (the connector's
 * TLS handshake and the startup) for each of its parallel reads. Now one connection stays open per
 * instance (within the Database connection budget: the ceiling is unchanged, the idle floor is 1), idle
 * ones live five minutes, and every statement has a ceiling, so a slow report cannot hold a connection
 * for every other user. The statement timeout and the idle-in-transaction timeout are connection-level
 * settings sent at connect time: no role setting, no migration.
 */
function poolTuning() {
  const cfg = { poolMin: Number(process.env.CMA_DB_POOL_MIN ?? 1), statementTimeoutMs: Number(process.env.CMA_DB_STATEMENT_TIMEOUT_MS ?? 15_000) };
  return {
    min: Number.isFinite(cfg.poolMin) && cfg.poolMin >= 0 ? cfg.poolMin : 1,
    idleTimeoutMillis: 300_000,
    connectionTimeoutMillis: 10_000,
    // pg sends these as startup parameters: they bind the whole session
    statement_timeout: Number.isFinite(cfg.statementTimeoutMs) && cfg.statementTimeoutMs > 0 ? cfg.statementTimeoutMs : 15_000,
    idle_in_transaction_session_timeout: 30_000,
  };
}

/** Opens the pool's first connection when the pool is created (pg-pool's min only exempts connections from reaping; it opens none) */
async function warm(pool: pg.Pool): Promise<void> {
  try {
    const c = await pool.connect();
    c.release();
  } catch (err) {
    // The first request will try again and report the failure as DB_UNAVAILABLE; startup must not fail here
    console.warn('[cma-db] warm-up connection failed', err instanceof Error ? err.message : String(err));
  }
}

/**
 * Called once at server start (src/instrumentation.ts) in api data mode: creates the pool and its first
 * connection before the first request, so the first page after a cold start does not pay the connector's
 * handshake. A failure is logged and left to the first request (DB_UNAVAILABLE), never thrown at startup.
 */
export async function warmDatabase(): Promise<void> {
  try {
    await db();
  } catch (err) {
    console.warn('[cma-db] startup warm-up failed', err instanceof Error ? err.message : String(err));
  }
}

function db(): Promise<DbState> {
  if (!g.__cmaDb) {
    g.__cmaDb = open().catch((err) => {
      g.__cmaDb = undefined; // allow a retry on the next request
      throw translateDbError(err);
    });
  }
  return g.__cmaDb;
}

// ---- Transactions ----------------------------------------------------------------------------

/** What a unit of work may do: run parameterised queries inside the current transaction. */
export interface Querier {
  query<R extends pg.QueryResultRow = pg.QueryResultRow>(
    text: string,
    values?: unknown[],
  ): Promise<pg.QueryResult<R>>;
}

export interface TenantContext {
  tenantId: string;
  /** The acting CMA user (cma.app_user.id). Omit only for system actors, which set actorLabel. */
  userId?: string;
  /** The acting process, for example 'scheduler:auto-logout'. */
  actorLabel?: string;
}

async function transaction<T>(
  setContext: (q: Querier) => Promise<void>,
  fn: (q: Querier) => Promise<T>,
): Promise<T> {
  const { pool } = await db();
  const s = dbStats();
  const t0 = performance.now();
  if (s) s.tx += 1;
  const client = await pool.connect().catch((err) => { throw translateDbError(err); });
  // A checked-out client has no error listener of its own (pg-pool removes its idle one on acquire), so a FATAL the
  // server sends between two statements (the idle-in-transaction timeout above, a restart) would be an unhandled
  // 'error' event and end the process. Heard here, it fails this transaction and the pool drops the connection.
  let fatal: Error | undefined;
  const onError = (err: Error) => { fatal ??= err; console.error('[cma-db] connection lost inside a transaction', err.message); };
  client.on('error', onError);
  const q: Querier = {
    query: (text, values) => { if (s) s.rt += 1; return client.query(text, values); },
  };
  try {
    await q.query('begin');
    await setContext(q);
    const result = await fn(q);
    await q.query('commit');
    return result;
  } catch (err) {
    await client.query('rollback').catch(() => undefined);
    throw translateDbError(fatal ?? err);
  } finally {
    if (s) s.dbMs += performance.now() - t0;
    client.off('error', onError);
    client.release(fatal);
  }
}

/**
 * A transaction with no tenant context. RLS hides every tenant-scoped row, so the only useful
 * call here is cma.find_tenants_for_identity(system, external_id), the SECURITY DEFINER lookup.
 */
export function withoutTenant<T>(fn: (q: Querier) => Promise<T>): Promise<T> {
  return transaction(async () => undefined, fn);
}

/**
 * A transaction with the tenant context set for its duration only (set_config(..., true)).
 * The write functions of migration 0002 read app.tenant_id and app.user_id from here.
 */
export function withTenant<T>(ctx: TenantContext, fn: (q: Querier) => Promise<T>): Promise<T> {
  if (!ctx.tenantId) throw new CmaDbError('DB_ERROR', 'tenant context missing');
  return transaction(async (q) => {
    await q.query(
      `select set_config('app.tenant_id', $1, true),
              set_config('app.user_id', $2, true),
              set_config('app.actor_label', $3, true)`,
      [ctx.tenantId, ctx.userId ?? '', ctx.actorLabel ?? ''],
    );
  }, fn);
}

/**
 * The single row a statement must return. A missing row is a database contract breach, reported
 * as DB_ERROR instead of an undefined surfacing somewhere later.
 */
export function one<R>(rows: R[], what: string): R {
  const row = rows[0];
  if (row === undefined) throw new CmaDbError('DB_ERROR', `${what} returned no row`);
  return row;
}

/** For /api/health: a round trip without any tenant context. */
export async function ping(): Promise<{ ok: true; user: string }> {
  return withoutTenant(async (q) => {
    const r = await q.query<{ u: string }>('select session_user as u');
    return { ok: true, user: one(r.rows, 'session_user').u };
  });
}
