import 'server-only';
import pg from 'pg';
import { AuthTypes, Connector, IpAddressTypes } from '@google-cloud/cloud-sql-connector';

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
 *   CMA_DB_IP         PUBLIC | PRIVATE                        (default PUBLIC)
 */

// ---- Error translation -----------------------------------------------------------------------

/** SQLSTATEs raised by the functions of migrations 0002 and 0003. The API maps codes, not text. */
export type CmaSqlState = 'CMA01' | 'CMA02' | 'CMA03' | 'CMA04' | 'CMA05' | 'CMA06';

export const CMA_SQLSTATE = {
  CMA01: 'no acting user or user inactive',
  CMA02: 'not found or not yours',
  CMA03: 'workday already ended',
  CMA04: 'invalid correction or event',
  CMA05: 'tenant configuration missing',
  CMA06: 'not permitted',
} as const satisfies Record<CmaSqlState, string>;

export class CmaDbError extends Error {
  readonly sqlState: CmaSqlState | 'DB_UNAVAILABLE' | 'DB_ERROR';
  readonly detail: string | undefined;
  constructor(sqlState: CmaDbError['sqlState'], message: string, detail?: string) {
    super(message);
    this.name = 'CmaDbError';
    this.sqlState = sqlState;
    this.detail = detail;
  }
}

function isCmaSqlState(code: unknown): code is CmaSqlState {
  return typeof code === 'string' && code in CMA_SQLSTATE;
}

/** Turns a pg error into a CmaDbError; never leaks SQL text to the caller. */
export function translateDbError(err: unknown): CmaDbError {
  if (err instanceof CmaDbError) return err;
  const e = err as { code?: string; message?: string; detail?: string };
  if (isCmaSqlState(e.code)) {
    return new CmaDbError(e.code, CMA_SQLSTATE[e.code], e.message);
  }
  // A SQLSTATE (five characters) is the database answering; anything else (no code, a network
  // code, a credential or connector failure) means the database could not be reached
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

type DbState = { connector: Connector; pool: pg.Pool };
const g = globalThis as unknown as { __cmaDb?: Promise<DbState> | undefined };

async function open(): Promise<DbState> {
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
    max: cfg.poolMax,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 10_000,
    application_name: 'cma-web',
  });
  pool.on('error', (err) => console.error('[cma-db] idle client error', err.message));
  const shutdown = async () => {
    try { await pool.end(); } finally { connector.close(); }
  };
  process.once('SIGTERM', shutdown);
  process.once('SIGINT', shutdown);
  return { connector, pool };
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
  const client = await pool.connect().catch((err) => { throw translateDbError(err); });
  try {
    await client.query('begin');
    await setContext(client);
    const result = await fn(client);
    await client.query('commit');
    return result;
  } catch (err) {
    await client.query('rollback').catch(() => undefined);
    throw translateDbError(err);
  } finally {
    client.release();
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
