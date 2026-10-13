/**
 * The customer's CRM contact (DESIGN §4.3a; VENDOR_SETUP §3.2 and §4): which contact of the CRM
 * connection named by the store connection's setting crm_connection_id gets the customer's id, store,
 * totals and, when empty, country, currency and language through the outbox.
 *
 * In this order, stopping at the first that answers:
 *   1. known     the contacts the CMA holds whose refs (connection field ref, the store adapter's ref
 *                system) hold the customer id; else the contact of the customer's latest write-back
 *                that was not dropped. No CRM call: repeat and renewal orders of a matched customer
 *                cost nothing
 *   2. email     the customer's email (defaultEmailAddress, the protected field Email), read in memory,
 *                searched in the CRM (exact match), then dropped
 *   3. ref       when the store withholds the email: the contacts whose write-back commerce_ref
 *                properties already hold the customer id (Make, or a person, wrote it; VENDOR_SETUP §4)
 * Exactly one contact → a write-back with the customer's values; none or several → nothing written,
 * counted in the run (match_none, match_several) and in data quality (0007d). A store without
 * crm_connection_id, or one whose CRM connection is inactive or of an adapter without contact
 * lookups, writes nothing back (match_not_configured). The email is never logged, stored or answered.
 */
import { ADAPTERS } from "../index.mjs";
import { idOf, writebackValues } from "./map.mjs";

/** The reason recorded on the customer's write-backs: ids only (store connection and customer). */
export function reasonOf(shopConnectionId, customerId) {
  return `commerce_customer:${shopConnectionId}:${customerId}`.slice(0, 100);
}

/**
 * The CRM side of a store connection: { crm, adapter, fields } or null when the store is not
 * connected to a CRM connection that can look contacts up.
 */
export async function crmOf(store, settings) {
  const id = typeof settings?.crm_connection_id === "string" ? settings.crm_connection_id.trim() : "";
  if (!id) return null;
  const crm = await store.crmConnection(id);
  const adapter = crm && Object.hasOwn(ADAPTERS, crm.adapter) ? ADAPTERS[crm.adapter] : null;
  if (!crm || !adapter?.crm) return null;
  return { crm, adapter, fields: await store.writebackFields(crm.connectionId) };
}

/**
 * One customer node → { outcome, writeback? }. outcome: known, one, none, several, not_configured.
 * Throws a SourceError when the CRM cannot answer (the caller fails the events: the sweep tries again).
 */
export async function matchCustomer({ connection, store, side, node, storeRow, budget }) {
  const customerId = idOf(node?.id);
  if (!side || !customerId) return { outcome: "not_configured" };
  const reason = reasonOf(connection.connectionId, customerId);
  const writeback = (contactId) => ({
    connectionId: side.crm.connectionId, contactId, reason, values: writebackValues(node, storeRow),
  });

  const known = await store.knownContacts({ crmConnectionId: side.crm.connectionId, refSystem: connection.adapter, customerId, reason });
  if (known.refContacts.length > 1) return { outcome: "several" };
  if (known.refContacts.length === 1) return { outcome: "known", writeback: writeback(known.refContacts[0]) };
  if (known.outboxContact) return { outcome: "known", writeback: writeback(known.outboxContact) };

  let email = typeof node?.defaultEmailAddress?.emailAddress === "string" ? node.defaultEmailAddress.emailAddress : null;
  let ids;
  try {
    if (email) {
      ids = await side.adapter.crm.findContactsByEmail({ connection: side.crm, email, budget });
    } else {
      const refProps = side.fields.filter((f) => f.field === "commerce_ref").map((f) => f.property);
      ids = await side.adapter.crm.findContactsByProperties({ connection: side.crm, properties: refProps, value: customerId, budget });
    }
  } finally {
    email = null;
  }
  if (ids.length === 1) return { outcome: "one", writeback: writeback(ids[0]) };
  return { outcome: ids.length ? "several" : "none" };
}
