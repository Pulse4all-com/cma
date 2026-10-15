/**
 * The CRM search the jobs page through (reconcile, backfill, the email poll): a property between two
 * times, ascending, 100 a page. HubSpot's search answers at most 10,000 results per query; past that
 * a new query starts at the last value seen (an object at the boundary is listed twice: its event key
 * or the stale guard absorbs it).
 */
import { SourceError } from "../../core/http.mjs";
import { iso } from "./map.mjs";

export const MODIFIED = { deal: "hs_lastmodifieddate", ticket: "hs_lastmodifieddate", crm_call: "hs_lastmodifieddate", contact: "lastmodifieddate",
  crm_email: "hs_lastmodifieddate" };
const LIMIT = 100;
const SEARCH_MAX = 10_000;

const msOf = (v) => {
  const t = iso(v);
  return t ? Date.parse(t) : null;
};

/**
 * The search body of one page: property between from and to (ms), ascending. properties: what the
 * page brings (default the property and the version only, ids for a read-back).
 */
export function searchBody(type, property, fromMs, toMs, after, properties = null) {
  const filters = [{ propertyName: property, operator: "GTE", value: String(fromMs) }];
  if (toMs !== null && toMs !== undefined) filters.push({ propertyName: property, operator: "LTE", value: String(toMs) });
  return {
    filterGroups: [{ filters }],
    sorts: [{ propertyName: property, direction: "ASCENDING" }],
    properties: [...new Set([property, MODIFIED[type], ...(properties ?? [])])],
    limit: LIMIT,
    ...(after ? { after: String(after) } : {}),
  };
}

/**
 * Pages of { items: [{ id, version }], last, results } (last: the page's highest value of property,
 * ms; results: the objects as the search answered them, with the properties asked for).
 */
export async function* searchPages(api, type, property, fromMs, toMs, { properties = null } = {}) {
  let start = fromMs;
  let after;
  let seen = 0;
  for (;;) {
    const r = await api.search(type, searchBody(type, property, start, toMs, after, properties));
    const results = (r?.results ?? []).filter((o) => o?.id !== undefined && o?.id !== null);
    const items = results.map((o) => ({ id: String(o.id), version: iso(o.properties?.[MODIFIED[type]]) ?? iso(o.updatedAt) ?? "unknown" }));
    const last = results.length ? msOf(results[results.length - 1].properties?.[property]) : null;
    seen += results.length;
    yield { items, last, results };
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
