/**
 * A fake Juo Admin API on localhost, for verify/juo-mapping.mjs and verify/juo-flow.mjs (additions 0008zl, 0009z).
 * Everything is invented: stores, keys, subscriptions, customer ids, names (Invented Person …), addresses and emails
 * (example.invalid), payment details, messages, notes and reasons. The personal fields are there on purpose: the
 * adapter's whitelist must keep every one of them out of a row and a log (since 0009z also a line's custom attribute with
 * an email, a subscription's custom attribute with an email, a discount's code, a chargeback's reasonMessage, a refund's
 * note, an invoice's and an update's errorMessage, and a catalog variant title holding a name and an @).
 *
 *   GET /admin/v1/subscriptions   limit (at most 100), expand=paymentMethod (the payment method as an object; else its
 *                                 id), includeCanceledItems (true: every line; else the lines Juo has not canceled),
 *                                 query (none: every subscription; (id:'<id>' OR …): those ids; anything else 400),
 *                                 after (an endCursor): the store's subscriptions in creation order, a page at a time,
 *                                 { resource: "list", hasNextPage, hasPrevPage, endCursor, startCursor, data }
 *   GET /admin/v1/events          limit, sort (occurredAt:asc,id:asc only), query (one of the two families, SUBSCRIPTION_FAMILY
 *                                 or BILLING_FAMILY, AND occurredAt:>'<ISO>' or >= [AND occurredAt:<'<ISO>']; anything
 *                                 else 400), after: the store's events of that family and window, oldest first
 *   GET /admin/v1/products        limit, after: the store's catalog (153 products: two pages), each with its variants
 *   GET /admin/v1/event-types     the types the fixture's events use, with their stream, category and severity
 * Any other method answers 405 (the adapter never sends one: its allow-list refuses it before a request).
 *
 * Every call needs X-Juo-Admin-Api-Key and X-Tenant-ID: a key answers for its own store only (401 for another store's id,
 * as the GB key does for the NL store). Switches on state: fail429 (the next n calls answer 429 with Retry-After:
 * retryAfter seconds, as text), failAfter (after n more pages, every call answers 503 until cleared), failTenant (one
 * store's domain: every call for that store answers 503 while the others answer as before). state.requests
 * records { path, params, tenant, authorized, at } per call (never the key); state.queriesSeen every query a call carried,
 * never cleared (the flow proves no call ever asked for Juo's renewal notice).
 */
import http from "node:http";

const pad = (n, w = 4) => String(n).padStart(w, "0");

/** The event types of the fixture, as GET event types answers them (the subset the adapter maps, and some others). */
export const FIXTURE_EVENT_TYPES = [
  ["subscription:renewed", "subscription", "info"], ["subscription:renew-failed", "subscription", "problem"],
  ["subscription:cancelled", "subscription", "info"], ["subscription:paused", "subscription", "info"],
  ["subscription:resumed", "subscription", "info"], ["subscription:reactivated", "subscription", "info"],
  ["subscription:updated", "subscription", "info"], ["subscription:discount-added", "subscription", "info"],
  ["subscription:delivery-address-changed", "subscription", "info"], ["chargeback:created", "billing", "problem"],
  ["invoice:placed", "order", "info"], ["subscription:migrated", "subscription", "info"], ["renewal:notification-sent", "notification", "info"],
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
      customAttributes: [{ key: "__juo_source_id", value: `${7000 + n}` }, { key: "note", value: `Invented Person ${pad(n)} asked for a call` },
        { key: "contact", value: `person-${pad(n)}@example.invalid` }],
      customer: `7100000${pad(n)}`,
      items: [
        { id: `item-${pad(n)}`, resource: "subscription-item", title: "Service plan, monthly (fixture)", subtitle: null, quantity: n === 215 ? 2 : 1,
          totalPrice: 24.95, recurringCycleLimit: null, canceledAt: null,
          billingPolicy: { interval: "MONTH", intervalCount: 1, anchors: [], minCycles: n === 213 ? 12 : null, maxCycles: null },
          deliveryPolicy: { interval: "MONTH", intervalCount: 1, anchors: [] },
          customAttributes: [{ key: "_source_sku", value: "FIXTURE-SKU" }, { key: "_ordered_by", value: `person-${pad(n)}@example.invalid` }],
          variant: "41000000001", product: "71000000001" },
        { id: `item-${pad(n)}-b`, resource: "subscription-item", title: "Accessory (fixture)", quantity: 1, totalPrice: 5, recurringCycleLimit: null,
          canceledAt: n % 2 ? null : ago(60), variant: "41000000002", product: "71000000002" },
        ...(n % 50 === 0 ? [{ id: `item-${pad(n)}-c`, resource: "subscription-item", title: "Installation (fixture)", quantity: 1, totalPrice: 49,
          recurringCycleLimit: 1, canceledAt: null, variant: "41000000003", product: "71000000003" }] : []),
      ],
      discounts: n === 214 ? [{ id: "disc-0214", code: "FIXTURE10", title: "Ten off for Invented Person", value: 10 }] : [],
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
  const event = (n, type, minutesAgo, data, actor = { type: "system", id: null, name: null, source: null }, operationId = null) => {
    k += 1;
    events.push({ id: `${prefix}e-${pad(k, 6)}-0000-4000-8000-000000000000`.slice(0, 36), stream: "activity",
      category: type.startsWith("renewal:") ? "notification" : "subscription",
      severity: type === "subscription:renew-failed" ? "problem" : "info", occurredAt: ago(minutesAgo), owner: { entity: "Subscription", id: sub(n) },
      actor, operationId, subscriptionId: sub(n), customerId: cust(n), summary: "fixture", type, payloadFormat: "legacy", data });
  };
  // a billing event: a chargeback's or refund's owner is its own record and it names no subscription; an invoice's owner is
  // its order (a Juo id) and it names the subscription
  const billing = (n, type, minutesAgo, data, { owner, withSub = false } = {}) => {
    k += 1;
    const category = type.startsWith("invoice:") || type.startsWith("order:") ? "order" : "billing";
    events.push({ id: `${prefix}e-${pad(k, 6)}-0000-4000-8000-000000000000`.slice(0, 36), stream: "activity", category,
      severity: "info", occurredAt: ago(minutesAgo), owner: owner ?? { entity: "SubscriptionBillingChargeback", id: `${prefix}o-${pad(k, 6)}-0000-4000-8000-0000000000`.slice(0, 36) },
      actor: { type: "system", id: null, name: null, source: null }, operationId: null, subscriptionId: withSub ? sub(n) : null, customerId: cust(n),
      summary: `fixture for Invented Person ${pad(n)}`, type, payloadFormat: "legacy", data });
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
  // the types of addition 0009z
  event(213, "subscription:migrated", 60 * 24 * 20, { id: sub(213), status: "ACTIVE", source: "Shopify", currentCycle: 3, nextBillingDate: ago(-60 * 24 * 9),
    currencyCode: "GBP", billingPolicy: { interval: "MONTH", intervalCount: 1, minCycles: null, maxCycles: null }, customer: { id: cust(213) },
    customerPaymentMethod: { id: "pm-0213" } });
  event(213, "subscription:next-billing-date-changed", 60 * 24 * 8, { from: ago(-60 * 24 * 9), to: ago(-60 * 24 * 16), cause: "requested" },
    { type: "customer", id: cust(213), name: null, source: null }, "op-0213");
  event(214, "subscription:skipped", 60 * 24 * 7, { skippedDate: ago(-60 * 24 * 2), nextBillingDate: ago(-60 * 24 * 32) });
  event(214, "subscription:discount-code-applied", 60 * 24 * 7, { code: "FIXTURE10", title: "Ten off for Invented Person" });
  event(215, "subscription:frequency-changed", 60 * 24 * 6, { from: { interval: "MONTH", intervalCount: 1 }, to: { interval: "YEAR", intervalCount: 1 } });
  event(216, "subscription:lines-changed", 60 * 24 * 5, { added: ["item-x1", "item-x2"], removed: [`item-${pad(216)}-b`], updated: [] },
    { type: "staff", id: "81100000002", name: "Invented Staff", source: null }, "op-0216");
  event(216, "subscription:line-added", 60 * 24 * 5, { item: { id: "item-x1", title: "Accessory for Invented Person" } },
    { type: "staff", id: "81100000002", name: "Invented Staff", source: null }, "op-0216");
  event(217, "subscription:payment-method-changed", 60 * 24 * 4, { from: "pm-0217-old", to: "pm-0217-new" });
  event(218, "subscription:merged-to", 60 * 24 * 4, { targetSubscriptionId: sub(219) });
  event(219, "subscription:update-failed", 60 * 24 * 3, { errorCode: "INVALID_VARIANT", errorMessage: "Variant missing for Invented Person 0219" });
  // a renewal notice (category notification): never requested by the adapter, so its recipient never reaches it (19 Nov 2026)
  event(220, "renewal:notification-sent", 60 * 24 * 2, { channel: "email", to: `person-${pad(220)}@example.invalid` });
  event(221, "subscription:purchased", 60 * 24 * 25, { orderId: "6100000221" });
  event(222, "subscription:created", 60 * 24 * 25, {});
  event(223, "subscription:cancellation-flow/started", 60 * 24, { answer: "Invented Person 0223 wants to leave" });
  event(205, "subscription:chargeback-created", 60 * 24 * 2, { orderId: `61000${pad(5)}` });
  billing(5, "chargeback:created", 60 * 24 * 2, { value: { amount: "24.95", currencyCode: "GBP" }, orderId: `61000${pad(5)}`, reasonCode: "MD06",
    reasonMessage: "Invented Person 0005 disputed, mail person-0005@example.invalid", instrumentType: "SepaDirectDebit", billingAttemptId: "ba-0005" });
  billing(6, "chargeback:created", 60 * 24 * 2, { value: { amount: "24.95", currencyCode: "GBP" }, orderId: `61000${pad(6)}`, reasonCode: "fraudulent",
    instrumentType: "CreditCard", billingAttemptId: "ba-0006" });
  billing(7, "chargeback:created", 60 * 24 * 2, { value: { amount: "24.95", currencyCode: "GBP" }, orderId: `61000${pad(7)}`, reasonCode: "No Mandate given",
    instrumentType: "Klarna", billingAttemptId: "ba-0007" });
  billing(8, "refund:created", 60 * 24 * 3, { note: "Return received. Call Invented Person 0008", value: { amount: "24.95", currencyCode: "GBP" },
    orderId: `61000${pad(8)}`, partial: false }, { owner: { entity: "SubscriptionBillingRefund", id: `${prefix}r-000008-0000-4000-8000-000000000000`.slice(0, 36) } });
  billing(8, "refund:completed", 60 * 24 * 3 - 5, { note: "Return received. Call Invented Person 0008", value: { amount: "24.95", currencyCode: "GBP" },
    orderId: `61000${pad(8)}`, partial: false }, { owner: { entity: "SubscriptionBillingRefund", id: `${prefix}r-000008-0000-4000-8000-000000000000`.slice(0, 36) } });
  billing(8, "refund:failed", 60 * 24 * 3 - 10, { value: { amount: "5.00", currencyCode: "GBP" }, orderId: `61000${pad(8)}`, partial: true });
  const invoice = (n) => ({ entity: "Order", id: `${prefix}i-${pad(n, 6)}-0000-4000-8000-000000000000`.slice(0, 36) });
  billing(9, "invoice:placed", 60 * 24 * 6, { total: { amount: "24.95", currencyCode: "GBP" }, placedAt: ago(60 * 24 * 6), renewalId: `${prefix}n-000009-0000-4000-8000-000000000000`.slice(0, 36) },
    { owner: invoice(9), withSub: true });
  billing(9, "invoice:paid", 60 * 24 * 5, { total: { amount: "24.95", currencyCode: "GBP" } }, { owner: invoice(9), withSub: true });
  billing(10, "invoice:placed", 60 * 24 * 6, { total: { amount: "24.95", currencyCode: "GBP" }, placedAt: ago(60 * 24 * 6), renewalId: `${prefix}n-000010-0000-4000-8000-000000000000`.slice(0, 36) },
    { owner: invoice(10), withSub: true });
  billing(10, "invoice:payment-failed", 60 * 24 * 4, { total: { amount: "24.95", currencyCode: "GBP" }, attempt: 2, errorCode: "INSUFFICIENT_FUNDS",
    errorMessage: "Your card has insufficient funds, Invented Person 0010." }, { owner: invoice(10), withSub: true });
  billing(10, "invoice:overdue", 60 * 24, { total: { amount: "24.95", currencyCode: "GBP" } }, { owner: invoice(10), withSub: true });
  billing(11, "order:placement-failed", 60 * 24, { errorCode: "INVENTORY", errorMessage: "No stock for Invented Person 0011" }, { owner: invoice(11), withSub: true });
  billing(12, "order:draft-created", 60 * 24, { draftOrderId: "9900000012" }, { owner: invoice(12), withSub: true });
  // the catalog: three products of the fixture's lines (a variant title with a name and an @, a SKU with a control character:
  // both left out) and 150 more, so the read takes two pages
  const products = [
    { id: "71000000001", title: "Plan A (catalog fixture)", status: "ACTIVE", image: { url: "https://cdn.example.invalid/a.png" }, collections: [], planGroups: ["77000000001"],
      variants: [{ id: "41000000001", title: "Monthly", sku: "PLAN-A-M", price: 24.95 }] },
    { id: "71000000002", title: "Accessory (catalog fixture)", status: "ACTIVE", collections: [], planGroups: [],
      variants: [{ id: "41000000002", title: "Ask Invented Person at person-0001@example.invalid", sku: "ACC\u0007-1", price: 5 }] },
    { id: "71000000003", title: "Installation (catalog fixture)", status: "DRAFT", collections: [], planGroups: [],
      variants: [{ id: "41000000003", title: "One-time", sku: "INSTALL-1", price: 49 }] },
  ];
  for (let n = 1; n <= 150; n += 1) {
    products.push({ id: `720000${pad(n)}`, title: `Filler ${pad(n)} (catalog fixture)`, status: "ACTIVE", collections: [], planGroups: [],
      variants: [{ id: `420000${pad(n)}`, title: "Default Title", sku: `FILL-${pad(n)}`, price: 1 }] });
  }
  return { handle, domain: `${handle}.myshopify.com`, key, subscriptions, events, products };
}

const QUOTED = "'([^']+)'";
/** The two families' queries exactly as Juo's documentation spells them (written here, not taken from the adapter) */
export const BILLING_FIXTURE_TYPES = ["chargeback:created", "refund:created", "refund:completed", "refund:failed", "invoice:placed", "invoice:paid",
  "invoice:overdue", "invoice:payment-failed", "order:placement-failed", "order:draft-created"];
export const SUBSCRIPTION_FAMILY = "category:subscription";
export const BILLING_FAMILY = `(${BILLING_FIXTURE_TYPES.map((t) => `type:'${t}'`).join(" OR ")})`;
const escape = (x) => x.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const IDS = new RegExp(`^\\((id:${QUOTED})( OR id:${QUOTED})*\\)$`);
const EVENTS = new RegExp(`^(${escape(SUBSCRIPTION_FAMILY)}|${escape(BILLING_FAMILY)}) AND occurredAt:(>=|>)${QUOTED}( AND occurredAt:<${QUOTED})?$`);

/** Starts the fake for some stores (juoStore); answers { url, state, close }. */
export async function startFakeJuo({ stores }) {
  const state = { requests: [], queriesSeen: [], fail429: 0, retryAfter: "1", failAfter: null, failTenant: null, pagesAnswered: 0, stores: Object.fromEntries(stores.map((s) => [s.domain, s])) };
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
    if (url.searchParams.has("query")) state.queriesSeen.push(url.searchParams.get("query"));
    req.resume();
    if (req.method !== "GET") return json(res, 405, { error: "method_not_allowed" });
    if (!authorized) return json(res, 401, { error: "unauthorized", message: "The API key is not valid for this tenant" });
    if (state.fail429 > 0) {
      state.fail429 -= 1;
      return json(res, 429, { error: "too_many_requests" }, state.retryAfter === null ? {} : { "retry-after": state.retryAfter });
    }
    if (state.failAfter !== null && state.pagesAnswered >= state.failAfter) return json(res, 503, { error: "unavailable" });
    if (state.failTenant !== null && tenant === state.failTenant) return json(res, 503, { error: "unavailable" });
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
      const canceledItems = params.get("includeCanceledItems") === "true";
      state.pagesAnswered += 1;
      return json(res, 200, page(list, params, (s) => ({ ...s, paymentMethod: expand ? s.paymentMethod : s.paymentMethod?.id ?? null,
        items: canceledItems ? s.items : s.items.filter((it) => !it.canceledAt) })));
    }
    if (url.pathname === "/admin/v1/products") {
      state.pagesAnswered += 1;
      return json(res, 200, page(store.products, params));
    }
    if (url.pathname === "/admin/v1/events") {
      const m = EVENTS.exec(params.get("query") ?? "");
      if (!m || params.get("sort") !== "occurredAt:asc,id:asc") return json(res, 400, { error: "invalid_query" });
      const inFamily = m[1] === BILLING_FAMILY ? (e) => BILLING_FIXTURE_TYPES.includes(e.type)
        : (e) => e.category === "subscription";
      const from = Date.parse(m[3]);
      const until = m[5] ? Date.parse(m[5]) : Infinity;
      const list = store.events.filter((e) => inFamily(e) && (m[2] === ">=" ? Date.parse(e.occurredAt) >= from : Date.parse(e.occurredAt) > from)
        && Date.parse(e.occurredAt) < until)
        .sort((a, b) => Date.parse(a.occurredAt) - Date.parse(b.occurredAt) || (a.id < b.id ? -1 : 1));
      state.pagesAnswered += 1;
      return json(res, 200, page(list, params));
    }
    return json(res, 404, { error: "not_found" });
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  return { url: `http://127.0.0.1:${server.address().port}`, state, close: () => new Promise((r) => server.close(r)) };
}
