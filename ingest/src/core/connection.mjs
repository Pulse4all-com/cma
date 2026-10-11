/**
 * Finding the connection of a request before the tenant is known: the key in the address gives the
 * tenant, the connection, its adapter, its account and the NAMES of its secrets, through the
 * SECURITY DEFINER lookup cma.ingest_connection(key) (migration 0006). An unknown key, or an inactive
 * connection, tenant or Ingest user, gives null. The key is not a secret; the request's own
 * authentication is the proof.
 */
import { withoutTenant, withTenantOnly } from "./db.mjs";

export const KEY = /^[A-Za-z0-9_-]{24,64}$/;

export async function lookupConnection(key) {
  if (!KEY.test(key ?? "")) return null;
  const r = await withoutTenant((q) => q.query(
    `select tenant_id, connection_id, adapter, external_account_id, signing_secret_name, token_secret_name, ingest_user_id
       from cma.ingest_connection($1)`, [key]));
  const c = r.rows[0];
  if (!c) return null;
  return {
    tenantId: c.tenant_id, connectionId: c.connection_id, adapter: c.adapter, externalAccountId: c.external_account_id,
    signingSecretName: c.signing_secret_name, tokenSecretName: c.token_secret_name, ingestUserId: c.ingest_user_id,
  };
}

/** The tenant context for every database call made for this connection: its Ingest user. */
export function contextOf(connection) {
  return { tenantId: connection.tenantId, userId: connection.ingestUserId, actorLabel: `ingest:${connection.adapter}` };
}

/**
 * Every active connection the jobs serve, across tenants, without a key: the tenants come from the
 * SECURITY DEFINER lookup cma.find_tenants_for_identity('ingest', 'ingest') (each tenant's Ingest
 * user carries that login id, migration 0006); inside each tenant, under row-level security, its
 * active Ingest user and its active connections. Same shape as lookupConnection, plus the slug.
 * connectionId narrows the list to one connection (the backfill's --connection).
 */
export async function servedConnections({ connectionId = null, actorLabel = "ingest:job" } = {}) {
  const tenants = await withoutTenant(async (q) =>
    (await q.query("select tenant_id from cma.find_tenants_for_identity('ingest', 'ingest')")).rows.map((r) => r.tenant_id));
  const out = [];
  for (const tenantId of tenants) {
    const rows = await withTenantOnly(tenantId, actorLabel, async (q) => (await q.query(
      `select c.id, c.adapter, c.external_account_id, c.signing_secret_name, c.token_secret_name, u.id as ingest_user_id, t.slug
         from cma.integration_connection c
         join cma.tenant t on t.id = c.tenant_id
         join cma.app_user_external_id x on x.tenant_id = c.tenant_id and x.system = 'ingest' and x.external_id = 'ingest'
         join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id and u.status = 'active'
        where c.tenant_id = cma.current_tenant_id() and c.status = 'active' and ($1::uuid is null or c.id = $1::uuid)
        order by c.id`, [connectionId])).rows);
    for (const c of rows) {
      out.push({
        tenantId, tenantSlug: c.slug, connectionId: c.id, adapter: c.adapter, externalAccountId: c.external_account_id,
        signingSecretName: c.signing_secret_name, tokenSecretName: c.token_secret_name, ingestUserId: c.ingest_user_id,
      });
    }
  }
  return out;
}
