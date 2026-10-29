/**
 * A fake Juo Admin API on localhost, for verify/juo-mapping.mjs and verify/juo-flow.mjs (addition 0008zl). Everything
 * is invented: stores, keys, subscriptions, customer ids, names (Invented Person …), addresses and emails
 * (example.invalid), payment details, messages and reasons. The personal fields are there on purpose: the adapter's
 * whitelist must keep every one of them out of a row and a log.
 *
 *   GET /admin/v1/subscriptions   limit (at most 100), expand=paymentMethod (the payment method as an object; else its
 *                                 id), query (none: every subscription; (id:'<id>' OR …): those ids; anything else 400),
 *                                 after (an endCursor): the store's subscriptions in creation order, a page at a time,
 *                                 { resource: "list", hasNextPage, hasPrevPage, endCursor, startCursor, data }
 *   GET /admin/v1/events          limit, sort (occurredAt:asc,id:asc only), query (category:subscription AND
 *                                 occurredAt:>'<ISO>' or >= [AND occurredAt:<'<ISO>']; anything else 400), after: the
 *                                 store's events of that window, oldest first
 *   GET /admin/v1/event-types     the types the fixture's events use, with their stream, category and severity
 *
 * Every call needs X-Juo-Admin-Api-Key and X-Tenant-ID: a key answers for its own store only (401 for another store's id,
 * as the GB key does for the NL store). Switches on state: fail429 (the next n calls answer 429 with Retry-After:
 * retryAfter seconds, as text), failAfter (after n more pages, every call answers 503 until cleared). state.requests
 * records { path, params, tenant, authorized, at } per call (never the key).
 */
import http from "node:http";

const pad = (n, w = 4) => String(n).padStart(w, "0");

/** The event types of the fixture, as GET event types answers them (the subset the adapter maps, and some others). */
export const FIXTURE_EVENT_TYPES = [
  ["subscription:renewed", "subscription", "info"], ["subscription:renew-failed", "subscription", "problem"],
  ["subscription:cancelled", "subscription", "info"], ["subscription:paused", "subscription", "info"],
  ["subscription:resumed", "subscription", "info"], ["subscription:reactivated", "subscription", "info"],
  ["subscription:updated", "subscription", "info"], ["subscription:discount-added", "subscription", "info"],
  ["subscription:delivery-address-changed", "subscription", "info"],
].map(([type, category, severity]) => ({ type, stream: "activity", category, severity, payloadFormat: "legacy", aliases: [] }));

/**
 * A store's fixture: its domain (<handle>.myshopify.com), its key, 230 subscriptions (three pages of 100) and their
 * events. The cases of the payment state: s-0001 to s-0200 active and renewed (paid), s-0201 active with an open failed
 * renewal (in retry), s-0202 active, its failed cycle renewed later (paid), s-0203 failed (moved there by an update),
 * s-0204 paused (by staff), s-0205 canceled (by its customer, with a free-text reason), s-0206 expired, s-0207 merged,
 * s-0208 never-subscribed, s-0209 resumed, s-0210 reactivated; s-0211 to s-0230 active. Customers c-…: every subscription's
 * id 7100000<n>; the flow's store holds the first 200 of them.
 */
export function juoStore({ handle, key, nowMs = Date.now(), prefix = "s" }) {
  const ago = (minutes) => new Date(nowMs - minutes * 60_000).toISOString();
  const subscriptions = [];
  for (let n = 1; n <= 230; n += 1) {
    const status = { 203: "failed", 204: "paused", 205: "canceled", 206: "expired", 207: "merged", 208: "never-subscribed" }[n] ?? "active";
    subscriptions.push({
      id: `${prefix}-${pad(n)}-0000-4000-8000-000000000000`.slice(0, 36), resource: "subscription", serial: `#${1000 + n}`, status,
      createdAt: ago(60 * 24 * 300 - n), updatedAt: ago(60 * 24 * 2 + n), canceledAt: n === 205 || n === 203 ? ago(60 * 24 * 3) : null,
      nextBillingDate: status === "active" ? ago(-60 * 24 * 20) : null, currentCycle: 6, currencyCode: "GBP",
      billingPolicy: { interval: "MONTH", intervalCount: 1 }, deliveryPolicy: { interval: "MONTH", intervalCount: 1 },
      deliveryMethod: { type: "shipping", title: "Free", description: null },
      customAttributes: [{ key: "__juo_source_id", value: `${7000 + n}` }, { key: "note", value: `Invented Person ${pad(n)} asked for a call` }],
      customer: `7100000${pad(n)}`,
      items: [
        { id: `item-${pad(n)}`, resource: "subscription-item", title: "Service plan, monthly (fixture)", quantity: 1, totalPrice: 24.95, canceledAt: null,
          customAttributes: [{ key: "_source_sku", value: "FIXTURE-SKU" }], variant: "41000000001", product: "71000000001" },
        { id: `item-${pad(n)}-b`, resource: "subscription-item", title: "Accessory (fixture)", quantity: 1, totalPrice: 5, canceledAt: n % 2 ? null : ago(60) },
      ],
      discounts: [],
      paymentMethod: { id: `pm-${pad(n)}`, customer: `7100000${pad(n)}`,
        instrument: n % 3 === 0 ? { type: "paypal", email: `payer-${pad(n)}@example.invalid` }
          : n % 3 === 1 ? { type: "credit-card", brand: "visa", lastDigits: "4242", name: `Invented Person ${pad(n)}`, expiryMonth: 12, expiryYear: 2030 }
            : { type: "sepa-direct-debit", consumerName: `Invented Person ${pad(n)}`, maskedConsumerAccount: "****4100" },
        billingAddress: { firstName: "Invented", lastName: `Person ${pad(n)}`, address1: "1 Fixture Street", city: "Testtown", zip: "FX1 1XX",
          countryCode: "GB", phone: "+44 20 0000 0000", email: `person-${pad(n)}@example.invalid` } },
      deliveryAddress: { firstName: "Invented", lastName: `Person ${pad(n)}`, address1: "1 Fixture Street", address2: null, zip: "FX1 1XX",
        city: "Testtown", country: "United Kingdom", countryCode: "GB", phone: "+44 20 0000 0000", company: null },
      deliveryPrice: 0,
    });
  }
  const sub = (n) => subscriptions[n - 1].id;
  const cust = (n) => subscriptions[n - 1].customer;
  const events = [];
  let k = 0;
  const event = (n, type, minutesAgo, data, actor = { type: "system", id: null, name: null, source: null }) => {
    k += 1;
    events.push({ id: `${prefix}e-${pad(k, 6)}-0000-4000-8000-000000000000`.slice(0, 36), stream: "activity", category: "subscription",
      severity: type === "subscription:renew-failed" ? "problem" : "info", occurredAt: ago(minutesAgo), owner: { entity: "Subscription", id: sub(n) },
      actor, operationId: null, subscriptionId: sub(n), customerId: cust(n), summary: "fixture", type, payloadFormat: "legacy", data });
  };
  for (let n = 1; n <= 200; n += 1) event(n, "subscription:renewed", 60 * 24 * 10 + n, { orderId: `61000${pad(n)}`, cycleIndex: 5, orderValue: { amount: "24.95", currencyCode: "GBP" } });
  event(201, "subscription:renew-failed", 60 * 24, { reason: "billing-attempt-failed", attempt: 1, errorCode: "CARD_DECLINED", cycleIndex: 6,
    errorMessage: "Card declined: contact person-0201@example.invalid" });
  event(201, "subscription:renew-failed", 60 * 12, { reason: "billing-attempt-failed", attempt: 2, errorCode: "INSUFFICIENT_FUNDS", cycleIndex: 6,
    errorMessage: "Your card has insufficient funds." });
  event(202, "subscription:renew-failed", 60 * 30, { reason: "billing-attempt-failed", attempt: 1, errorCode: "processing_error", cycleIndex: 6,
    errorMessage: "UNPROCESSABLE_ENTITY" });
  event(202, "subscription:renewed", 60 * 20, { orderId: "6100000202", cycleIndex: 6 });
  event(203, "subscription:updated", 60 * 24 * 3, { input: { status: "FAILED" }, status: "ACTIVE" });
  event(203, "subscription:updated", 60 * 24 * 3 - 1, { nextBillingDate: ago(60) });
  event(204, "subscription:paused", 60 * 24 * 4, { previousStatus: "ACTIVE" }, { type: "staff", id: "81100000001", name: "Invented Staff", source: null });
  event(205, "subscription:cancelled", 60 * 24 * 3, { previousStatus: "ACTIVE", reason: "Too expensive, mail me at person-0205@example.invalid" },
    { type: "customer", id: cust(205), name: "Invented Person 0205", source: "portal" });
  event(209, "subscription:paused", 60 * 24 * 6, { previousStatus: "ACTIVE" }, { type: "bulk-action", id: "bulk-1", name: null, source: null });
  event(209, "subscription:resumed", 60 * 24 * 5, { previousStatus: "PAUSED" }, { type: "api", id: "key-1", name: "Invented Integration", source: null });
  event(210, "subscription:reactivated", 60 * 24 * 2, { previousStatus: "CANCELLED" });
  event(211, "subscription:discount-added", 60 * 24, { code: "FIXTURE10" });
  event(212, "subscription:delivery-address-changed", 60 * 24, { changedFields: ["address.address1"] });
  return { handle, domain: `${handle}.myshopify.com`, key, subscriptions, events };
}

const QUOTED = "'([^']+)'";
const IDS = new RegExp(`^\\((id:${QUOTED})( OR id:${QUOTED})*\\)$`);
const EVENTS = new RegExp(`^category:subscription AND occurredAt:(>=|>)${QUOTED}( AND occurredAt:<${QUOTED})?$`);

/** Starts the fake for some stores (juoStore); answers { url, state, close }. */
export async function startFakeJuo({ stores }) {
  const state = { requests: [], fail429: 0, retryAfter: "1", failAfter: null, pagesAnswered: 0, stores: Object.fromEntries(stores.map((s) => [s.domain, s])) };
  const json = (res, status, body, headers = {}) => {
    res.writeHead(status, { "content-type": "application/json", ...headers });
    res.end(JSON.stringify(body));
  };
  const page = (list, params, map = (x) => x) => {
    const limit = Math.min(100, Math.max(1, Number(params.get("limit") ?? 20)));
    const after = params.get("after");
    const start = after ? Number(Buffer.from(after, "base64url").toString("utf8").replace(/^i:/, "")) : 0;
    const slice = list.slice(start, start + limit);
    const more = start + limit < list.length;
    return { resource: "list", hasNextPage: more, hasPrevPage: start > 0, endCursor: more ? Buffer.from(`i:${start + limit}`).toString("base64url") : null,
      startCursor: start > 0 ? Buffer.from(`i:${start}`).toString("base64url") : null, data: slice.map(map) };
  };
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, "http://x");
    const tenant = req.headers["x-tenant-id"] ?? null;
    const store = tenant ? state.stores[tenant] : null;
    const authorized = Boolean(store) && req.headers["x-juo-admin-api-key"] === store.key;
    state.requests.push({ path: url.pathname, params: Object.fromEntries(url.searchParams), tenant, authorized, at: Date.now(),
      keyInUrl: Object.values(state.stores).some((s) => req.url.includes(s.key)) });
    req.resume();
    if (req.method !== "GET") return json(res, 405, { error: "method_not_allowed" });
    if (!authorized) return json(res, 401, { error: "unauthorized", message: "The API key is not valid for this tenant" });
    if (state.fail429 > 0) {
      state.fail429 -= 1;
      return json(res, 429, { error: "too_many_requests" }, state.retryAfter === null ? {} : { "retry-after": state.retryAfter });
    }
    if (state.failAfter !== null && state.pagesAnswered >= state.failAfter) return json(res, 503, { error: "unavailable" });
    const params = url.searchParams;
    if (url.pathname === "/admin/v1/event-types") return json(res, 200, { resource: "list", data: FIXTURE_EVENT_TYPES });
    if (url.pathname === "/admin/v1/subscriptions") {
      const q = params.get("query");
      let list = [...store.subscriptions];
      if (q) {
        if (!IDS.test(q)) return json(res, 400, { error: "invalid_query" });
        const ids = new Set([...q.matchAll(/id:'([^']+)'/g)].map((m) => m[1]));
        list = list.filter((s) => ids.has(s.id));
      }
      const expand = params.getAll("expand").includes("paymentMethod");
      state.pagesAnswered += 1;
      return json(res, 200, page(list, params, (s) => (expand ? s : { ...s, paymentMethod: s.paymentMethod?.id ?? null })));
    }
    if (url.pathname === "/admin/v1/events") {
      const m = EVENTS.exec(params.get("query") ?? "");
      if (!m || params.get("sort") !== "occurredAt:asc,id:asc") return json(res, 400, { error: "invalid_query" });
      const from = Date.parse(m[2]);
      const until = m[4] ? Date.parse(m[4]) : Infinity;
      const list = store.events.filter((e) => (m[1] === ">=" ? Date.parse(e.occurredAt) >= from : Date.parse(e.occurredAt) > from) && Date.parse(e.occurredAt) < until)
        .sort((a, b) => Date.parse(a.occurredAt) - Date.parse(b.occurredAt) || (a.id < b.id ? -1 : 1));
      state.pagesAnswered += 1;
      return json(res, 200, page(list, params));
    }
    return json(res, 404, { error: "not_found" });
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  return { url: `http://127.0.0.1:${server.address().port}`, state, close: () => new Promise((r) => server.close(r)) };
}
