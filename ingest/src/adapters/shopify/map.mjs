/**
 * Shopify → canonical shapes (DESIGN §2, §2.1, §4.3; addition 0008g). Pure functions: no database,
 * no network.
 *
 * Events: a webhook is one delivery of one topic (shopify.dev, Webhooks, 2026-10): the topic, the shop
 * and the delivery's ids travel in headers, the object (REST-shaped, numeric id) in the body. The
 * seven topics the CMA subscribes to (VENDOR_SETUP §3.4) map to commerce_customer and
 * commerce_order; create → created, update, updated and cancelled → changed, delete → deleted.
 * The event key is sh:<X-Shopify-Webhook-Id>: Shopify's documented duplicate key, the same on every
 * retry of a delivery. X-Shopify-Event-Id is shared by the deliveries one merchant action causes
 * (an order and its customer, two subscriptions of one topic), so it is kept in raw for correlation
 * and not used as the key (a deviation from DESIGN §2, which named it before this was checked). A
 * delivery for another shop than the connection's is recorded as ignored with portal_mismatch;
 * another topic as event_not_handled. Only ids, the topic and times are kept in the event log.
 *
 * Objects: the GraphQL read-back (read.mjs) answers customers and orders; they become items of
 * cma.ingest_upsert_commerce_customers and _orders. The customer's email is never mapped (it is
 * used in memory by the match, match.mjs); phone numbers become the keyed hash of DESIGN §6.3 (the
 * order's phone, else its customer's, the store's market as the default region) and are dropped.
 * Never kept: names, emails, phone numbers, addresses, notes, the landing page's query beyond the
 * five UTM tags, the referrer beyond its host.
 */
import { createHash } from "node:crypto";
import { hashNumber } from "../../core/hash.mjs";
import { parsePage, UTM_KEYS } from "../../core/page.mjs";

/** The webhook topics the CMA subscribes to, with their object type and canonical kind. */
export const TOPICS = {
  "customers/create": ["commerce_customer", "created"],
  "customers/update": ["commerce_customer", "changed"],
  "customers/delete": ["commerce_customer", "deleted"],
  "orders/create": ["commerce_order", "created"],
  "orders/updated": ["commerce_order", "changed"],
  "orders/cancelled": ["commerce_order", "changed"],
  "orders/delete": ["commerce_order", "deleted"],
};
/** The same seven as GraphQL WebhookSubscriptionTopic values (webhookSubscriptionCreate). */
export const SUBSCRIPTION_TOPICS = Object.keys(TOPICS).map((t) => t.toUpperCase().replace("/", "_"));
export const OBJECT_TYPES = ["commerce_customer", "commerce_order"];
export const GID_TYPE = { commerce_customer: "Customer", commerce_order: "Order" };

const ID = /^[1-9]\d{0,19}$/;
const DELIVERY_ID = /^[A-Za-z0-9._-]{1,100}$/;

/** A Shopify id as digits: from a number, a digit string or a GraphQL gid (gid://shopify/Order/123). */
export function idOf(value) {
  if (value === undefined || value === null || typeof value === "object" || typeof value === "boolean") return null;
  const s = String(value).trim();
  const m = /^gid:\/\/shopify\/[A-Za-z]+\/(\d+)(?:\?.*)?$/.exec(s);
  const digits = m ? m[1] : s;
  return ID.test(digits) ? digits : null;
}

export function gid(objectType, id) {
  return `gid://shopify/${GID_TYPE[objectType]}/${id}`;
}

function header(headers, name) {
  const v = headers?.[name];
  const s = Array.isArray(v) ? v[0] : v;
  return typeof s === "string" ? s.trim() : "";
}

function isoOf(value) {
  if (typeof value !== "string" || !value.trim()) return null;
  const t = Date.parse(value);
  return Number.isFinite(t) ? new Date(t).toISOString() : null;
}

/**
 * One webhook delivery (authenticated, body parsed) → one canonical event. shop: the connection's
 * account (<handle>.myshopify.com). Never throws.
 */
export function mapDelivery(payload, headers, shop) {
  const topic = header(headers, "x-shopify-topic").toLowerCase().slice(0, 60) || "unknown";
  const webhookId = header(headers, "x-shopify-webhook-id");
  const eventId = header(headers, "x-shopify-event-id");
  const domain = header(headers, "x-shopify-shop-domain").toLowerCase();
  const handled = Object.hasOwn(TOPICS, topic);
  const [objectType, kind] = handled ? TOPICS[topic] : ["other", "changed"];
  const objectId = idOf(payload?.id) ?? idOf(payload?.admin_graphql_api_id);
  const occurredAt = isoOf(header(headers, "x-shopify-triggered-at")) ?? isoOf(payload?.updated_at) ?? new Date().toISOString();
  // The documented duplicate key; without it, the event id with the topic, else the body's own digest
  const key = DELIVERY_ID.test(webhookId) ? `sh:${webhookId}`
    : DELIVERY_ID.test(eventId) ? `sh:${topic}:${eventId}`
      : `sh:body:${createHash("sha256").update(JSON.stringify(payload ?? null)).digest("hex").slice(0, 32)}`;
  const raw = { topic };
  if (DELIVERY_ID.test(eventId)) raw.eventId = eventId;
  if (DELIVERY_ID.test(webhookId)) raw.webhookId = webhookId;
  const triggeredAt = isoOf(header(headers, "x-shopify-triggered-at"));
  if (triggeredAt) raw.triggeredAt = triggeredAt;
  const apiVersion = header(headers, "x-shopify-api-version");
  if (/^\d{4}-\d{2}$|^unstable$/.test(apiVersion)) raw.apiVersion = apiVersion;
  const out = { key: key.slice(0, 200), sourceType: topic, kind, objectType, objectId: objectId ?? "unknown", occurredAt, raw };
  if (!domain || domain !== String(shop ?? "").trim().toLowerCase()) out.ignore = "portal_mismatch";
  else if (!handled) out.ignore = "event_not_handled";
  else if (!objectId) out.ignore = "malformed";
  return out;
}

/** The authenticated body → canonical events (Shopify sends one object per delivery); throws SyntaxError on non-JSON. */
export function mapEvents(body, headers, shop) {
  const parsed = JSON.parse(Buffer.isBuffer(body) ? body.toString("utf8") : String(body));
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new SyntaxError("not one object");
  return [mapDelivery(parsed, headers, shop)];
}

// ---- Objects -------------------------------------------------------------------------------------

function text(value, max) {
  if (value === undefined || value === null || typeof value === "object") return null;
  const s = String(value).trim();
  return s ? s.slice(0, max) : null;
}

function amountOf(set) {
  const a = set?.shopMoney?.amount ?? set?.amount;
  if (a === undefined || a === null || a === "") return null;
  const n = Number(a);
  return Number.isFinite(n) ? String(a) : null;
}

function currencyOf(value) {
  return typeof value === "string" && /^[A-Z]{3}$/.test(value) ? value : null;
}

function countOf(value) {
  if (value === undefined || value === null || value === "") return null;
  const s = String(value);
  return /^\d{1,9}$/.test(s) ? Number(s) : null;
}

/**
 * The language of a Shopify locale as ISO 639-1 lower case (en-GB → en). Norwegian Bokmål and
 * Nynorsk (nb, nn) become no, the code the CRM's language property uses (VENDOR_SETUP §1.1).
 */
export function languageOf(locale) {
  const m = /^([a-z]{2})(?:[-_][A-Za-z0-9]+)*$/.exec(String(locale ?? "").trim().toLowerCase());
  if (!m) return null;
  return m[1] === "nb" || m[1] === "nn" ? "no" : m[1];
}

/** The keyed hash of the first number that normalises, in the given order; null when none does or no pepper. */
export function phoneHashOf(pepper, numbers, region) {
  for (const n of numbers) {
    if (typeof n !== "string" || !n.trim()) continue;
    const h = hashNumber(pepper, n, region);
    if (h) return h;
  }
  return null;
}

/**
 * A GraphQL Customer → an ingest_upsert_commerce_customers item, or null without an id. The email is
 * not read here; the phone (defaultPhoneNumber, the protected field Phone: null when withheld)
 * becomes phoneHash with the store's market as the default region.
 */
export function customerFromNode(node, { pepper, region }) {
  const sourceId = idOf(node?.id);
  if (!sourceId) return null;
  return {
    sourceId,
    state: text(node.state, 30),
    locale: text(node.locale, 20),
    ordersCount: countOf(node.numberOfOrders),
    amountSpent: amountOf(node.amountSpent),
    currency: currencyOf(node.amountSpent?.currencyCode),
    createdAt: isoOf(node.createdAt),
    updatedAt: isoOf(node.updatedAt),
    phoneHash: phoneHashOf(pepper, [node.defaultPhoneNumber?.phoneNumber], region),
    raw: {},
  };
}

/**
 * The customer's orders created before this one: the customer's lifetime count (numberOfOrders)
 * minus the orders created at or after this one's creation (this one included), from
 * ordersCount(query: "customer_id:<id> AND created_at:>='<createdAt>'"). Exact when both are exact
 * (the count's precision EXACT); otherwise the best value with exact false. Null without a customer
 * or a lifetime count, and null when the count does not hold the order itself yet (Shopify's search
 * can lag a new order by seconds): the order is then written with order_kind unknown, and its next
 * read (an orders/updated event, the nightly reconcile) counts again.
 */
export function priorCountOf(numberOfOrders, atOrAfter) {
  const lifetime = countOf(numberOfOrders);
  const n = Number(atOrAfter?.count);
  if (lifetime === null || !Number.isInteger(n) || n < 1) return { prior: null, exact: false };
  const prior = lifetime - n;
  if (prior < 0) return { prior: 0, exact: false };
  return { prior, exact: atOrAfter?.precision === "EXACT" };
}

/** The visit that brought the order: the first visit of the attribution window, else the last one. */
function visitOf(order) {
  const j = order?.customerJourneySummary;
  return j?.firstVisit ?? j?.lastVisit ?? null;
}

function hostOf(url) {
  return parsePage(url).host;
}

/** UTM tags of the visit (Shopify's own utmParameters, else the landing page's query), five keys, each at most 200. */
export function utmOf(visit) {
  const out = {};
  const own = visit?.utmParameters ?? {};
  const fromUrl = parsePage(visit?.landingPage).utm;
  for (const k of UTM_KEYS) {
    const v = typeof own[k] === "string" && own[k].trim() ? own[k].trim().slice(0, 200) : fromUrl[k];
    if (v) out[k] = v;
  }
  return out;
}

/** A GraphQL line item → an order line, or null without an id. */
export function lineFromNode(line) {
  const lineId = idOf(line?.id);
  if (!lineId) return null;
  const q = Number(line.quantity);
  return {
    lineId,
    sku: text(line.sku, 100),
    productRef: idOf(line.product?.id),
    variantRef: idOf(line.variant?.id),
    quantity: Number.isInteger(q) && q >= 0 ? q : 0,
    unitPrice: amountOf(line.originalUnitPriceSet),
    currency: currencyOf(line.originalUnitPriceSet?.shopMoney?.currencyCode),
  };
}

/**
 * A GraphQL Order → an ingest_upsert_commerce_orders item, or null without an id. prior: the result
 * of priorCountOf; lines: every line read (the first page and the pages after it), or null when they
 * could not all be read (the order's stored lines then stay). phoneHash: the order's phone, else its
 * customer's (the protected field Phone: null when withheld), with the store's market as default region.
 */
export function orderFromNode(node, { pepper, region, prior = { prior: null, exact: false }, lines = null }) {
  const sourceId = idOf(node?.id);
  if (!sourceId) return null;
  const visit = visitOf(node);
  const landing = parsePage(visit?.landingPage);
  const item = {
    sourceId,
    orderName: text(node.name, 40),
    customerId: idOf(node.customer?.id),
    createdAt: isoOf(node.createdAt),
    processedAt: isoOf(node.processedAt),
    updatedAt: isoOf(node.updatedAt),
    cancelledAt: isoOf(node.cancelledAt),
    cancelReason: text(node.cancelReason, 40),
    isTest: node.test === true,
    currency: currencyOf(node.currencyCode),
    totalAmount: amountOf(node.totalPriceSet),
    subtotalAmount: amountOf(node.subtotalPriceSet),
    taxAmount: amountOf(node.totalTaxSet),
    discountAmount: amountOf(node.totalDiscountsSet),
    refundedAmount: amountOf(node.totalRefundedSet),
    financialStatus: text(node.displayFinancialStatus, 40),
    fulfillmentStatus: text(node.displayFulfillmentStatus, 40),
    sourceName: text(node.sourceName, 60),
    appRef: idOf(node.app?.id) ?? text(node.app?.id, 100),
    landingHost: landing.host,
    landingPath: landing.path,
    utm: utmOf(visit),
    referringHost: hostOf(visit?.referrerUrl),
    tags: Array.isArray(node.tags) ? node.tags.filter((t) => typeof t === "string").slice(0, 30) : [],
    priorOrdersCount: prior.prior,
    priorCountExact: prior.exact === true,
    phoneHash: phoneHashOf(pepper, [node.phone, node.customer?.defaultPhoneNumber?.phoneNumber], region),
    raw: {},
  };
  if (Array.isArray(lines)) item.lines = lines.map(lineFromNode).filter(Boolean).slice(0, 500);
  return item;
}

/** The values the CRM write-back carries for one customer (DESIGN §4.3a), from the customer and the store. */
export function writebackValues(customer, store) {
  return {
    commerce_ref: idOf(customer?.id),
    commerce_store: store?.handle ?? null,
    commerce_orders: countOf(customer?.numberOfOrders),
    commerce_spent: amountOf(customer?.amountSpent),
    country: store?.market ?? null,
    currency: store?.currency ?? null,
    language: languageOf(customer?.locale),
  };
}
