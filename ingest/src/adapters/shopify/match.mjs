/**
 * The customer's CRM contact, kept in the CMA (addition 0008h; README Decision log, 13 October 2026):
 * which contact of the CRM connection named by the store connection's setting crm_connection_id a
 * store's customer is, for indirect sales. Nothing is written to the CRM: its own commerce
 * integration writes the store's fields on the contact, and every property has one writer.
 *
 * In this order, stopping at the first that answers:
 *   1. known     the customer's link in the CMA (commerce_customer.crm_contact_source_id) to a contact
 *                of this CRM connection, checked to exist with one batch read for every linked
 *                customer of the batch (not a search). A contact the CRM deleted or merged into
 *                another is not there: the link is replaced by the steps below or cleared. Then the
 *                contacts the CMA holds whose refs hold the customer id (connection field ref, the
 *                store adapter's ref system). Repeat and renewal orders of a matched customer cost
 *                no search
 *   2. email     the customer's email (defaultEmailAddress, the protected field Email), read in memory,
 *                searched in the CRM (exact match, lower case), then dropped
 *   3. ref       when the store withholds the email: the contacts whose ref properties (the CRM
 *                connection's contact ref fields for this ref system) hold the customer id
 * Exactly one contact → the link set (cma.set_commerce_customer_contact); none or several → the link
 * cleared, counted in the run (match_none, match_several) and in data quality (0007d). A store without
 * crm_connection_id, or one whose CRM connection is inactive or of an adapter without contact lookups,
 * leaves the link as it is (match_not_configured). The email is never logged, stored or answered.
 */
import { SourceError } from "../../core/http.mjs";
import { ADAPTERS } from "../index.mjs";
import { idOf } from "./map.mjs";

/**
 * The CRM side of a store connection: { crm, adapter, refProperties } or null when the store is not
 * connected to a CRM connection that can look contacts up. refSystem: the store adapter's name, the
 * ref system under which the CRM holds the store's customer ids.
 */
export async function crmOf(store, settings, refSystem) {
  const id = typeof settings?.crm_connection_id === "string" ? settings.crm_connection_id.trim() : "";
  if (!id) return null;
  const crm = await store.crmConnection(id);
  const adapter = crm && Object.hasOwn(ADAPTERS, crm.adapter) ? ADAPTERS[crm.adapter] : null;
  if (!crm || !adapter?.crm) return null;
  return { crm, adapter, refProperties: await store.refProperties(crm.connectionId, refSystem) };
}

/**
 * The customers of one batch (customer id → GraphQL customer node) → customer id → { outcome, link }.
 * outcome: known, ref, one, none, several, not_configured, or error with its code (that customer's units
 * fail for the sweep; since the IT audit of 17 October 2026 one lookup the CRM cannot answer fails that
 * customer only, never the whole batch); link: { crmConnectionId, contactId } to set,
 * { crmConnectionId: null, contactId: null } to clear, or null to leave as it is. gone: how many
 * links pointed at a contact the CRM no longer has. Throws only when the CMA's own reads fail.
 */
export async function matchCustomers({ connection, store, side, nodes, budget }) {
  const out = new Map();
  const ids = [...nodes.keys()].filter((id) => idOf(id));
  if (!side) {
    for (const id of ids) out.set(id, { outcome: "not_configured", link: null });
    return { matches: out, gone: 0 };
  }
  const crmId = side.crm.connectionId;
  const set = (contactId) => ({ crmConnectionId: crmId, contactId });
  const clear = { crmConnectionId: null, contactId: null };

  // 1a. the links the CMA holds, checked in one read
  const links = await store.customerLinks(ids);
  const linked = ids.filter((id) => links.get(id)?.crmConnectionId === crmId);
  let gone = 0;
  // A CRM that cannot answer the batch read fails the linked customers only (outcome error, for the sweep);
  // the others go on to their own lookups (CMA-037 item 3)
  let existing = new Set();
  let existingError = null;
  if (linked.length) {
    try {
      existing = await side.adapter.crm.existingContacts({ connection: side.crm, ids: linked.map((id) => links.get(id).contactId), budget });
    } catch (err) {
      existingError = err instanceof SourceError ? err.code : "error";
    }
  }
  for (const id of linked) {
    if (existingError) out.set(id, { outcome: "error", link: null, code: existingError });
    else if (existing.has(links.get(id).contactId)) out.set(id, { outcome: "known", link: null });
    else gone += 1;
  }

  // One customer's lookup failing fails that customer only. A rate limit, a missed slot or a timeout on the
  // CRM's search stops the searches that follow (they would hit the same limit): those customers fail with the
  // same code and the sweep tries them again; the customers already matched keep their outcome
  let stopped = null;
  for (const id of ids) {
    if (out.has(id)) continue;
    if (stopped) {
      out.set(id, { outcome: "error", link: null, code: stopped });
      continue;
    }
    // 1b. the contacts the CMA holds whose refs hold the customer id
    const held = await store.heldRefContacts({ crmConnectionId: crmId, refSystem: connection.adapter, customerId: id });
    if (held.length === 1) {
      out.set(id, { outcome: "ref", link: set(held[0]) });
      continue;
    }
    if (held.length > 1) {
      out.set(id, { outcome: "several", link: clear });
      continue;
    }
    // 2. the email, in memory only; 3. without it, the ref properties
    const node = nodes.get(id);
    let email = typeof node?.defaultEmailAddress?.emailAddress === "string" ? node.defaultEmailAddress.emailAddress : null;
    let found;
    try {
      found = email
        ? await side.adapter.crm.findContactsByEmail({ connection: side.crm, email, budget })
        : await side.adapter.crm.findContactsByProperties({ connection: side.crm, properties: side.refProperties, value: id, budget });
    } catch (err) {
      const code = err instanceof SourceError ? err.code : "error";
      if (code === "rate_limited" || code === "paced" || code === "timeout") stopped = code;
      out.set(id, { outcome: "error", link: null, code });
      continue;
    } finally {
      email = null;
    }
    if (found.length === 1) out.set(id, { outcome: "one", link: set(found[0]) });
    else out.set(id, { outcome: found.length ? "several" : "none", link: clear });
  }
  return { matches: out, gone };
}
