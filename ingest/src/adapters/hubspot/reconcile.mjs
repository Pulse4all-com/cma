/**
 * HubSpot reconcile (DESIGN §2, §5): everything modified in the look-back (26 hours by default), found
 * with the CRM search by the modified time, ascending, and handed to the core as { id, version }
 * items: the core records them as synthetic events and reads them back through the same path as a
 * webhook (stale guard included), so a change a webhook missed arrives and a newer row stays.
 *
 * Contacts: only the ones the CMA holds (0006: the contact base is never mirrored); the others are
 * counted as fetched and skipped. Deletions are not found by a search (HubSpot searches live
 * objects only): they arrive by webhook.
 *
 * Email engagements (crm_email) and inbox conversations (inbox_thread), brief B17b: listed for the
 * same look-back and written through the email poll's own path, not as synthetic events (email.mjs,
 * conversations.mjs), so a reconcile writes what the poll would have.
 *
 * The CRM search answers at most 10,000 results per query; past that a new query starts at the last
 * value seen (an object at the boundary is listed twice and read once: its event key is known).
 */
import { SourceError } from "../../core/http.mjs";
import { hubspotClient, tokenOf } from "./read.mjs";
import { MODIFIED, searchBody, searchPages } from "./search.mjs";
import { reconcileEmails } from "./email.mjs";
import { reconcileThreads } from "./conversations.mjs";

export { MODIFIED, searchBody, searchPages };
// task since addition 0008n: by hs_lastmodifieddate, the existing paging and budget, read back as a webhook's task
export const RECONCILE_OBJECTS = ["deal", "ticket", "crm_call", "contact", "task", "crm_email", "inbox_thread"];

/** Reconcile of one object type: modified between sinceMs and untilMs → process(items). */
export async function reconcile({ connection, store, budget, object, sinceMs, untilMs, process, counts }) {
  // The email objects are written by the email poll's own path (email.mjs, conversations.mjs), not as events
  if (object === "crm_email") return reconcileEmails({ connection, store, budget, sinceMs, untilMs, counts });
  if (object === "inbox_thread") return reconcileThreads({ connection, store, budget, sinceMs, untilMs, counts });
  if (!MODIFIED[object]) throw new SourceError("object_not_reconciled");
  const api = hubspotClient(await tokenOf(connection), budget);
  for await (const page of searchPages(api, object, MODIFIED[object], sinceMs, untilMs)) {
    let items = page.items;
    if (object === "contact" && items.length) {
      const held = await store.heldContacts(items.map((i) => i.id));
      items = items.filter((i) => held.has(i.id));
      counts.fetched += page.items.length - items.length;
      counts.skipped += page.items.length - items.length;
    }
    if (items.length) await process(object, items);
  }
}
