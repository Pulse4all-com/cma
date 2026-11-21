/**
 * The Juo reads (addition 0008zl): a store's subscriptions and the events of its subscriptions, page by page, with the
 * Admin API's search query language (terms field:value, comparisons field:>value, AND, OR, parentheses; quoted values).
 *
 *   subscriptions   GET /subscriptions?limit=100&sort=createdAt:asc,id:asc&expand=paymentMethod&includeCanceledItems=true
 *                   [&query=<query>][&after=<endCursor>]: every subscription of the store (canceled ones included) with all its lines
 *                   (canceled lines included, since addition 0009za), or those a query names (id:'<id>' OR …, at most
 *                   ID_BATCH ids a query). The payment method is expanded only for its instrument's type: map.mjs reads
 *                   nothing else of it. The sort names a unique last key (id, since addition 0009zc): Juo's default
 *                   sort is createdAt alone and its endCursor then holds createdAt alone, so a page boundary inside a tie
 *                   (migrated subscriptions share one createdAt) skipped the rest of the tie (Decision log, 20 Nov 2026)
 *   events          GET /events?limit=100&sort=occurredAt:asc,id:asc&query=<family> AND occurredAt:>'<ISO>'
 *                   [AND occurredAt:<'<ISO>'][&after=<endCursor>]: one family's events in a window, oldest first (a
 *                   timestamp carries its offset, Z). Two families, each its own query and backfill cursor (addition
 *                   0009za): subscription, category:subscription, the events of the store's subscriptions (Juo's renewal
 *                   notice, category notification, is never requested: Decision log, 19 Nov 2026); billing,
 *                   (type:'chargeback:created' OR type:'refund:created' OR …), the ten billing types of BILLING_TYPES,
 *                   whose category is billing or order
 *   query           POST /analytics/query (addition 0009zg): one of Juo's own figures (figures.mjs builds the body)
 *   products        GET /products?limit=100&sort=id:asc[&after=<endCursor>] (addition 0009za): the store's catalog, each
 *                   product with its variants (id, title, SKU); map.mjs reads ids, titles, SKU and status only. id:asc is
 *                   Juo's default and unique; it is sent so the read never rests on a default (addition 0009zc)
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

/** Every paged read names a sort whose last key is unique, so a cursor never falls inside a tie (addition 0009zc) */
export const SUBSCRIPTIONS_SORT = "createdAt:asc,id:asc";
export const PRODUCTS_SORT = "id:asc";
export const EVENTS_SORT = "occurredAt:asc,id:asc";

/** A timestamp for the query language: ISO 8601 with its offset, in quotes. */
export const at = (ms) => `'${new Date(ms).toISOString()}'`;

/** The billing family's types: chargebacks, refunds, invoice renewals and orders the app could not place (addition 0009za). */
export const BILLING_TYPES = ["chargeback:created", "refund:created", "refund:completed", "refund:failed", "invoice:placed", "invoice:paid",
  "invoice:overdue", "invoice:payment-failed", "order:placement-failed", "order:draft-created"];
/** The two families of events, each its own query (and backfill cursor) */
export const FAMILIES = {
  subscription: "category:subscription",
  billing: `(${BILLING_TYPES.map((t) => `type:'${t}'`).join(" OR ")})`,
};

/**
 * The query of one family's events in a window: occurred after fromMs (and, with untilMs, before it). family: subscription
 * (the default) or billing.
 */
export function eventsQuery(fromMs, untilMs = null, { inclusive = false, family = "subscription" } = {}) {
  if (!FAMILIES[family]) throw new SourceError("family_unknown");
  const parts = [FAMILIES[family], `occurredAt:${inclusive ? ">=" : ">"}${at(fromMs)}`];
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
      return pages("/subscriptions", { limit: String(PAGE_SIZE), sort: SUBSCRIPTIONS_SORT, expand: "paymentMethod", includeCanceledItems: "true",
        ...(query ? { query } : {}) });
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
    /** One family's events in a window (eventsQuery), oldest first, page by page. */
    events(query) {
      return pages("/events", { limit: String(PAGE_SIZE), sort: EVENTS_SORT, query });
    },
    /** The store's catalog, page by page: products with their variants. */
    products() {
      return pages("/products", { limit: String(PAGE_SIZE), sort: PRODUCTS_SORT });
    },
    /** One analytics query (POST /analytics/query, a read with a body; addition 0009zg, figures.mjs) */
    query(path, body) {
      return api.query(path, body);
    },
  };
}
