/**
 * Finding the connection of a request before the tenant is known: the key in the address gives the
 * tenant, the connection, its adapter, its account and the NAMES of its secrets, through the
 * SECURITY DEFINER lookup cma.ingest_connection(key) (migration 0006). An unknown key, or an inactive
 * connection, tenant or Ingest user, gives null. The key is not a secret; the request's own
 * authentication is the proof.
 */
import { withoutTenant } from "./db.mjs";

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
