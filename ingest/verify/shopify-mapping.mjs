/**
 * Verifier: Shopify deliveries and objects → canonical shapes (src/adapters/shopify/map.mjs, the
 * queries of read.mjs and reconcile.mjs), pure: no network, no database. Fixture values only
 * (example.com, invented ids, +44 20 0000 0xxx numbers).
 *
 *   node verify/shopify-mapping.mjs             every check must PASS
 *   node verify/shopify-mapping.mjs --provoke   every check must FAIL
 */
import {
  TOPICS, SUBSCRIPTION_TOPICS, mapDelivery, mapEvents, idOf, gid, priorCountOf, customerFromNode, orderFromNode, lineFromNode, utmOf,
} from "../src/adapters/shopify/map.mjs";
import { countsQuery, atOrAfterSearch, ORDER_FIELDS, CUSTOMER_FIELDS } from "../src/adapters/shopify/read.mjs";
import { listQuery, SUBSCRIPTION_CREATE } from "../src/adapters/shopify/reconcile.mjs";
import { apiVersionOf, DEFAULT_API_VERSION } from "../src/adapters/shopify/client.mjs";
import { shopifyReadbackBudgetMs } from "../src/adapters/shopify/index.mjs";
import { expect, verdict, PROVOKE } from "./lib.mjs";

console.log(`verify/shopify-mapping.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

const SHOP = "flow-a.myshopify.com";
const headers = (o = {}) => ({ "x-shopify-topic": "orders/create", "x-shopify-shop-domain": SHOP, "x-shopify-webhook-id": "b54557e4-bdd9-4b37-8a5f-bf7d70bcd043",
  "x-shopify-event-id": "98880550-7158-44d4-b7cd-2c97c8a091b5", "x-shopify-triggered-at": "2026-10-13T08:00:01.123Z", "x-shopify-api-version": "2026-10", ...o });
const body = { id: 7300000001, admin_graphql_api_id: "gid://shopify/Order/7300000001", email: "order@example.com", phone: "+44 20 0000 0201", updated_at: "2026-10-13T08:00:00Z",
  customer: { id: 7100000001, email: "test1@example.com", first_name: "Invented" }, shipping_address: { address1: "1 Invented Street" } };

// ---- Deliveries -----------------------------------------------------------------------------------
const e = mapDelivery(body, headers(), SHOP);
expect("orders/create → commerce_order, created, the order id", [e.objectType, e.kind, e.objectId], ["commerce_order", "created", "7300000001"], ["commerce_order", "changed", "7300000001"]);
expect("the key is sh:<X-Shopify-Webhook-Id> (Shopify's duplicate key)", e.key, "sh:b54557e4-bdd9-4b37-8a5f-bf7d70bcd043", "sh:98880550-7158-44d4-b7cd-2c97c8a091b5");
expect("occurred at X-Shopify-Triggered-At", e.occurredAt, "2026-10-13T08:00:01.123Z", "2026-10-13T08:00:00.000Z");
expect("raw holds the topic, the delivery's ids, its time and version only", e.raw, { topic: "orders/create", eventId: "98880550-7158-44d4-b7cd-2c97c8a091b5", webhookId: "b54557e4-bdd9-4b37-8a5f-bf7d70bcd043", triggeredAt: "2026-10-13T08:00:01.123Z", apiVersion: "2026-10" }, {});
expect("nothing of the body beyond the id reaches the event", /example\.com|Invented|0000 0201/.test(JSON.stringify(e)), false, true);
const kinds = Object.fromEntries(Object.keys(TOPICS).map((t) => [t, mapDelivery(body, headers({ "x-shopify-topic": t }), SHOP)]).map(([t, x]) => [t, `${x.objectType}:${x.kind}`]));
expect("the seven topics and their kinds", kinds, {
  "customers/create": "commerce_customer:created", "customers/update": "commerce_customer:changed", "customers/delete": "commerce_customer:deleted",
  "orders/create": "commerce_order:created", "orders/updated": "commerce_order:changed", "orders/cancelled": "commerce_order:changed", "orders/delete": "commerce_order:deleted" }, {});
expect("the same seven as subscription topics", SUBSCRIPTION_TOPICS, ["CUSTOMERS_CREATE", "CUSTOMERS_UPDATE", "CUSTOMERS_DELETE", "ORDERS_CREATE", "ORDERS_UPDATED", "ORDERS_CANCELLED", "ORDERS_DELETE"], []);
expect("another shop's domain → ignored portal_mismatch", mapDelivery(body, headers({ "x-shopify-shop-domain": "someone-else.myshopify.com" }), SHOP).ignore, "portal_mismatch", undefined);
expect("the shop domain compared without case", mapDelivery(body, headers({ "x-shopify-shop-domain": "FLOW-A.myshopify.com" }), SHOP).ignore, undefined, "portal_mismatch");
expect("no shop domain → ignored portal_mismatch", mapDelivery(body, headers({ "x-shopify-shop-domain": undefined }), SHOP).ignore, "portal_mismatch", undefined);
expect("another topic → ignored event_not_handled", mapDelivery(body, headers({ "x-shopify-topic": "products/update" }), SHOP).ignore, "event_not_handled", undefined);
expect("no id → ignored malformed", mapDelivery({ updated_at: "2026-10-13T08:00:00Z" }, headers(), SHOP).ignore, "malformed", undefined);
expect("the id from admin_graphql_api_id when id is missing", mapDelivery({ admin_graphql_api_id: "gid://shopify/Customer/7100000009" }, headers({ "x-shopify-topic": "customers/update" }), SHOP).objectId, "7100000009", "unknown");
expect("no webhook id → the event id with the topic", mapDelivery(body, headers({ "x-shopify-webhook-id": undefined }), SHOP).key, "sh:orders/create:98880550-7158-44d4-b7cd-2c97c8a091b5", "sh:undefined");
expect("neither → a digest of the body (a retry of the same body keys the same)", [/^sh:body:[0-9a-f]{32}$/.test(mapDelivery(body, headers({ "x-shopify-webhook-id": undefined, "x-shopify-event-id": undefined }), SHOP).key),
  mapDelivery(body, headers({ "x-shopify-webhook-id": "", "x-shopify-event-id": "" }), SHOP).key === mapDelivery(body, headers({ "x-shopify-webhook-id": "", "x-shopify-event-id": "" }), SHOP).key], [true, true], [false, false]);
expect("no Triggered-At → the body's updated_at", mapDelivery(body, headers({ "x-shopify-triggered-at": undefined }), SHOP).occurredAt, "2026-10-13T08:00:00.000Z", "x");
expect("a body that is not one JSON object → SyntaxError", [() => mapEvents(Buffer.from("[1,2]"), headers(), SHOP), () => mapEvents(Buffer.from("x"), headers(), SHOP)]
  .map((f) => { try { f(); return "ok"; } catch (err) { return err.constructor.name; } }), ["SyntaxError", "SyntaxError"], ["ok", "ok"]);

// ---- Ids ----------------------------------------------------------------------------------------------
expect("ids: a number, a digit string and a gid", [idOf(7300000001), idOf("7300000001"), idOf("gid://shopify/Order/7300000001")], ["7300000001", "7300000001", "7300000001"], []);
expect("ids: nothing else", [idOf("abc"), idOf(""), idOf(null), idOf({ id: 1 }), idOf("gid://shopify/Order/x"), idOf("0")], [null, null, null, null, null, null], []);
expect("gid of an order and a customer", [gid("commerce_order", "1"), gid("commerce_customer", "2")], ["gid://shopify/Order/1", "gid://shopify/Customer/2"], []);

// ---- The prior order count ------------------------------------------------------------------------------
expect("a first order: lifetime 1, one at or after → 0, exact", priorCountOf("1", { count: 1, precision: "EXACT" }), { prior: 0, exact: true }, { prior: 1, exact: true });
expect("a customer with three older orders: lifetime 4, one at or after → 3", priorCountOf("4", { count: 1, precision: "EXACT" }), { prior: 3, exact: true }, { prior: 0, exact: true });
expect("an older order read later: lifetime 5, three at or after → 2", priorCountOf("5", { count: 3, precision: "EXACT" }), { prior: 2, exact: true }, { prior: 5, exact: true });
expect("a count that is a lower bound (AT_LEAST) → not exact", priorCountOf("5", { count: 3, precision: "AT_LEAST" }), { prior: 2, exact: false }, { prior: 2, exact: true });
expect("the search does not hold the order yet (0) → unknown", priorCountOf("1", { count: 0, precision: "EXACT" }), { prior: null, exact: false }, { prior: 1, exact: true });
expect("more at or after than the lifetime → 0, not exact", priorCountOf("1", { count: 2, precision: "EXACT" }), { prior: 0, exact: false }, { prior: 0, exact: true });
expect("no lifetime count → unknown", priorCountOf(null, { count: 1, precision: "EXACT" }), { prior: null, exact: false }, { prior: 0, exact: true });
expect("the count's search: customer and creation at or after", atOrAfterSearch("7100000001", "2026-10-12T10:00:00Z"), "customer_id:7100000001 AND created_at:>='2026-10-12T10:00:00Z'", "customer_id:7100000001");
expect("one count query, one alias per order", countsQuery(2), "query CmaPriorCounts($q0: String!, $q1: String!) { c0: ordersCount(query: $q0) { count precision } c1: ordersCount(query: $q1) { count precision } }", "");

// ---- Objects ------------------------------------------------------------------------------------------------
const customerNode = { id: "gid://shopify/Customer/7100000001", state: "ENABLED", locale: "nb-NO", numberOfOrders: "4", amountSpent: { amount: "480.5", currencyCode: "NOK" },
  createdAt: "2026-01-02T03:04:05Z", updatedAt: "2026-10-12T10:00:00Z", defaultEmailAddress: { emailAddress: "test1@example.com" }, defaultPhoneNumber: { phoneNumber: "+44 20 0000 0101" },
  firstName: "Invented", defaultAddress: { address1: "1 Invented Street" } };
const cu = customerFromNode(customerNode, { pepper: "fixture-pepper", region: "GB" });
expect("a customer: id, state, locale, count, amount, currency, times", [cu.sourceId, cu.state, cu.locale, cu.ordersCount, cu.amountSpent, cu.currency, cu.createdAt, cu.updatedAt],
  ["7100000001", "ENABLED", "nb-NO", 4, "480.5", "NOK", "2026-01-02T03:04:05.000Z", "2026-10-12T10:00:00.000Z"], []);
expect("…its keys: no email, name or address, the phone as a hash", Object.keys(cu).sort(), ["amountSpent", "createdAt", "currency", "locale", "ordersCount", "phoneHash", "raw", "sourceId", "state", "updatedAt"], ["email"]);
expect("…no email, number, name or address anywhere in it", /example\.com|0000 0101|442000000101|Invented/.test(JSON.stringify(cu)), false, true);
const visit = { landingPage: "https://Shop.Example.com/products/aed?utm_source=news&utm_medium=email&gclid=abc&email=someone%40example.com#top", referrerUrl: "https://www.google.com/search?q=aed", utmParameters: { source: null, medium: null, campaign: "autumn", term: null, content: null } };
const node = { id: "gid://shopify/Order/7300000001", name: "#1001", createdAt: "2026-10-12T10:00:00Z", processedAt: "2026-10-12T10:00:01Z", updatedAt: "2026-10-12T10:05:00Z",
  cancelledAt: null, cancelReason: null, test: false, currencyCode: "GBP", phone: null, sourceName: "subscription_contract", app: { id: "gid://shopify/App/580111" },
  tags: ["aed", "pads", 7], displayFinancialStatus: "PAID", displayFulfillmentStatus: "UNFULFILLED",
  totalPriceSet: { shopMoney: { amount: "120.0", currencyCode: "GBP" } }, subtotalPriceSet: { shopMoney: { amount: "100.0", currencyCode: "GBP" } }, totalTaxSet: null,
  totalDiscountsSet: { shopMoney: { amount: "0.0", currencyCode: "GBP" } }, totalRefundedSet: { shopMoney: { amount: "0.0", currencyCode: "GBP" } },
  customerJourneySummary: { firstVisit: visit, lastVisit: null }, customer: customerNode, note: "free text that must not be stored" };
const lines = [{ id: "gid://shopify/LineItem/1", sku: "AED-1", quantity: 2, product: { id: "gid://shopify/Product/8000000001" }, variant: { id: "gid://shopify/ProductVariant/8100000001" },
  originalUnitPriceSet: { shopMoney: { amount: "60.0", currencyCode: "GBP" } }, name: "Invented product" }];
const or = orderFromNode(node, { pepper: "fixture-pepper", region: "GB", prior: { prior: 3, exact: true }, lines });
expect("an order: ids, name, times, test, currency, amounts (a missing tax amount is null)", [or.sourceId, or.orderName, or.customerId, or.createdAt, or.isTest, or.currency, or.totalAmount, or.subtotalAmount, or.taxAmount],
  ["7300000001", "#1001", "7100000001", "2026-10-12T10:00:00.000Z", false, "GBP", "120.0", "100.0", null], []);
expect("…the source name and the app id (the renewal lists' values)", [or.sourceName, or.appRef], ["subscription_contract", "580111"], ["web", null]);
expect("…the landing page as host (lower case) and path, never its query or fragment", [or.landingHost, or.landingPath], ["shop.example.com", "/products/aed"], ["Shop.Example.com", "/products/aed?utm_source=news"]);
expect("…UTM from the visit's own tags, else the landing page's", or.utm, { source: "news", medium: "email", campaign: "autumn" }, { campaign: "autumn" });
expect("…the referrer's host only", or.referringHost, "www.google.com", "https://www.google.com/search?q=aed");
expect("…tags as text only, the prior count and its exactness", [or.tags, or.priorOrdersCount, or.priorCountExact], [["aed", "pads"], 3, true], [["aed", "pads", 7], null, false]);
expect("…its lines: id, sku, product and variant ids, quantity, unit price, currency", or.lines, [{ lineId: "1", sku: "AED-1", productRef: "8000000001", variantRef: "8100000001", quantity: 2, unitPrice: "60.0", currency: "GBP" }], []);
expect("…no email, number, name, address or note anywhere in it", /@example\.com|someone|0000 0101|442000000101|Invented|must not be stored|gclid/.test(JSON.stringify(or)), false, true);
expect("…lines that could not all be read → no lines key (the stored lines stay)", Object.hasOwn(orderFromNode(node, { pepper: "p", region: "GB" }), "lines"), false, true);
expect("…the last visit when there is no first one", orderFromNode({ ...node, customerJourneySummary: { firstVisit: null, lastVisit: { landingPage: "https://shop.example.com/b" } } }, { pepper: "p", region: "GB" }).landingPath, "/b", "/products/aed");
expect("…a guest order: no customer id", orderFromNode({ ...node, customer: null }, { pepper: "p", region: "GB" }).customerId, null, "7100000001");
expect("a line without an id is left out", lineFromNode({ sku: "x" }), null, {});
expect("UTM: empty without a visit", utmOf(null), {}, { source: "x" });

// ---- The queries ask for no more than they need ---------------------------------------------------------------
expect("the order query asks for no name, email, address or note (the order phone and the customer's phone and email are read, hashed or used in memory)",
  /\b(email|firstName|lastName|displayName|addresses|defaultAddress|shippingAddress|billingAddress|note)\b/.test(ORDER_FIELDS.replace(CUSTOMER_FIELDS, "")), false, true);
expect("the customer query reads the email and the phone only through their default fields", [/\bdefaultEmailAddress\b/.test(CUSTOMER_FIELDS), /\bdefaultPhoneNumber\b/.test(CUSTOMER_FIELDS), /\b(email|phone|firstName|lastName|addresses)\b(?!Address|Number)/.test(CUSTOMER_FIELDS)], [true, true, false], [false, false, true]);
expect("listings ask for ids and times only", /nodes \{ id createdAt updatedAt \}/.test(listQuery("commerce_order", "UPDATED_AT")), true, false);
expect("subscriptions are created with uri (callbackUrl is deprecated in 2026-10)", /webhookSubscription: \{ uri: \$uri \}/.test(SUBSCRIPTION_CREATE), true, false);
expect("the API version: the setting, else 2026-10", [apiVersionOf({ api_version: "2027-01" }), apiVersionOf({ api_version: "2026-13" }), apiVersionOf({}), DEFAULT_API_VERSION], ["2027-01", "2026-10", "2026-10", "2026-10"], []);
const saved = process.env.INGEST_SHOPIFY_READBACK_BUDGET_MS;
const budgets = ["", "800", "99", "5000", "x"].map((v) => { process.env.INGEST_SHOPIFY_READBACK_BUDGET_MS = v; if (!v) delete process.env.INGEST_SHOPIFY_READBACK_BUDGET_MS; return shopifyReadbackBudgetMs(); });
if (saved === undefined) delete process.env.INGEST_SHOPIFY_READBACK_BUDGET_MS; else process.env.INGEST_SHOPIFY_READBACK_BUDGET_MS = saved;
expect("the route's budget: default 1500, the setting from 100 to 4000", budgets, [1500, 800, 1500, 1500, 1500], [3000, 800, 99, 5000, 3000]);

verdict();
