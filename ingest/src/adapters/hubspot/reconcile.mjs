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
 * The CRM search answers at most 10,000 results per query; past that a new query starts at the last
 * value seen (an object at the boundary is listed twice and read once: its event key is known).
 */
import { SourceError } from "../../core/http.mjs";
import { hubspotClient, tokenOf } from "./read.mjs";
import { iso } from "./map.mjs";

export const RECONCILE_OBJECTS = ["deal", "ticket", "crm_call", "contact"];
export const MODIFIED = { deal: "hs_lastmodifieddate", ticket: "hs_lastmodifieddate", crm_call: "hs_lastmodifieddate", contact: "lastmodifieddate" };
const LIMIT = 100;
const SEARCH_MAX = 10_000;

const msOf = (v) => {
  const t = iso(v);
  return t ? Date.parse(t) : null;
};

/** The search body of one page: property between from and to (ms), ascending. */
export function searchBody(type, property, fromMs, toMs, after) {
  const filters = [{ propertyName: property, operator: "GTE", value: String(fromMs) }];
  if (toMs !== null && toMs !== undefined) filters.push({ propertyName: property, operator: "LTE", value: String(toMs) });
  return {
    filterGroups: [{ filters }],
    sorts: [{ propertyName: property, direction: "ASCENDING" }],
    properties: [...new Set([property, MODIFIED[type]])],
    limit: LIMIT,
    ...(after ? { after: String(after) } : {}),
  };
}

/** Pages of { items: [{ id, version }], last } (last: the page's highest value of property, ms). */
export async function* searchPages(api, type, property, fromMs, toMs) {
  let start = fromMs;
  let after;
  let seen = 0;
  for (;;) {
    const r = await api.search(type, searchBody(type, property, start, toMs, after));
    const results = (r?.results ?? []).filter((o) => o?.id !== undefined && o?.id !== null);
    const items = results.map((o) => ({ id: String(o.id), version: iso(o.properties?.[MODIFIED[type]]) ?? iso(o.updatedAt) ?? "unknown" }));
    const last = results.length ? msOf(results[results.length - 1].properties?.[property]) : null;
    seen += results.length;
    yield { items, last };
    const next = r?.paging?.next?.after;
    if (!next || !results.length) return;
    if (seen + LIMIT > SEARCH_MAX) {
      if (last === null || last <= start) throw new SourceError("search_window_full");
      start = last;
      after = undefined;
      seen = 0;
    } else {
      after = next;
    }
  }
}

/** Reconcile of one object type: modified between sinceMs and untilMs → process(items). */
export async function reconcile({ connection, store, budget, object, sinceMs, untilMs, process, counts }) {
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
