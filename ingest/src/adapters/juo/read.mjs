/**
 * The Juo reads (addition 0008zl): a store's subscriptions and the events of its subscriptions, page by page, with the
 * Admin API's search query language (terms field:value, comparisons field:>value, AND, OR, parentheses; quoted values).
 *
 *   subscriptions   GET /subscriptions?limit=100&expand=paymentMethod[&query=<query>][&after=<endCursor>]: every
 *                   subscription of the store (canceled ones included), or those a query names (id:'<id>' OR …, at most
 *                   ID_BATCH ids a query). The payment method is expanded only for its instrument's type: map.mjs reads
 *                   nothing else of it
 *   events          GET /events?limit=100&sort=occurredAt:asc,id:asc&query=category:subscription AND occurredAt:>'<ISO>'
 *                   [AND occurredAt:<'<ISO>'][&after=<endCursor>]: the events of the store's subscriptions in a window,
 *                   oldest first (a timestamp carries its offset, Z)
 *
 * Each page is { data, hasNextPage, endCursor }; the read follows endCursor until a page says there is no next one. A
 * cursor that repeats, or a read past MAX_PAGES, fails too_many_pages.
 */
import { SourceError } from "../../core/http.mjs";
import { juoClient } from "./client.mjs";

export const PAGE_SIZE = 100;
const MAX_PAGES = 20_000;
/** Subscriptions read again by id: at most this many ids in one query */
export const ID_BATCH = 25;
const CURSOR = /^[A-Za-z0-9_=+/.-]{1,500}$/;
const QUOTABLE = /^[A-Za-z0-9_.:-]{1,100}$/;

/** A timestamp for the query language: ISO 8601 with its offset, in quotes. */
export const at = (ms) => `'${new Date(ms).toISOString()}'`;

/** The query of the events of a window: category subscription, occurred after fromMs (and, with untilMs, before it). */
export function eventsQuery(fromMs, untilMs = null, { inclusive = false } = {}) {
  const parts = ["category:subscription", `occurredAt:${inclusive ? ">=" : ">"}${at(fromMs)}`];
  if (Number.isFinite(untilMs)) parts.push(`occurredAt:<${at(untilMs)}`);
  return parts.join(" AND ");
}

/** The query of some subscriptions by id: (id:'a' OR id:'b' …); ids out of the id form are left out. */
export function idsQuery(ids) {
  const ok = ids.filter((id) => QUOTABLE.test(id));
  return ok.length ? `(${ok.map((id) => `id:'${id}'`).join(" OR ")})` : null;
}

/** The API of a connection with its settings (cma.connection_config). */
export function clientFor(connection, settings, budget) {
  const api = juoClient(connection, settings, budget);
  async function* pages(path, params) {
    let after = null;
    for (let page = 0; page < MAX_PAGES; page += 1) {
      const q = new URLSearchParams(params);
      if (after) q.set("after", after);
      const r = await api.get(`${path}?${q.toString()}`);
      const data = Array.isArray(r?.data) ? r.data : [];
      if (data.length) yield data;
      const next = typeof r?.endCursor === "string" && CURSOR.test(r.endCursor) ? r.endCursor : null;
      if (r?.hasNextPage !== true || !next) return;
      if (next === after) throw new SourceError("too_many_pages");
      after = next;
    }
    throw new SourceError("too_many_pages");
  }
  return {
    /** Every subscription of the store, or those of a query, page by page. */
    subscriptions({ query = null } = {}) {
      return pages("/subscriptions", { limit: String(PAGE_SIZE), expand: "paymentMethod", ...(query ? { query } : {}) });
    },
    /** Some subscriptions by id, ID_BATCH at a time: yields each batch's subscriptions. */
    async *subscriptionsById(ids) {
      for (let i = 0; i < ids.length; i += ID_BATCH) {
        const query = idsQuery(ids.slice(i, i + ID_BATCH));
        if (!query) continue;
        const found = [];
        for await (const page of this.subscriptions({ query })) found.push(...page);
        if (found.length) yield found;
      }
    },
    /** The events of the store's subscriptions in a window, oldest first, page by page. */
    events(query) {
      return pages("/events", { limit: String(PAGE_SIZE), sort: "occurredAt:asc,id:asc", query });
    },
  };
}
