/**
 * Verifier: the Juo adapter's mapping and client (addition 0008zl, brief B20; addition 0009w, brief B39 Part A), without
 * a database: the whitelist of map.mjs on the fixture's payloads (verify/juo-fake.mjs), which carry invented personal
 * data on purpose (names, addresses, emails, phone numbers, card digits, an account, a free-text cancellation reason, an
 * error message, custom attributes with an email, a discount's code, a chargeback's reason message, a refund's note, a
 * catalog title with a name and an @), the event types, the settings, the store's id, the holds after a 429, the queries;
 * since 0009w the lines (E), the catalog (F), the new event types (G), the billing events with their instrument types and
 * return codes (H) and the client's allow-list of method and path (I: a write refused with no request sent); then the
 * client against the fake Juo on localhost: paging, the key in a header only, 401 for another store's id (key_rejected),
 * a 429 paced and sent again, a third 429 failing rate_limited, a missing secret, a store id out of its form. Everything
 * is invented.
 *
 *   node verify/juo-mapping.mjs             every check must PASS
 *   node verify/juo-mapping.mjs --provoke   every check must FAIL
 */
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, verdict, PROVOKE } from "./lib.mjs";
import { juoStore, startFakeJuo, SUBSCRIPTION_FAMILY, BILLING_FAMILY } from "./juo-fake.mjs";

console.log(`verify/juo-mapping.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

const KEY = "fixture-juo-key-one-0001";
const KEY2 = "fixture-juo-key-two-0002";
const secretsDir = mkdtempSync(path.join(tmpdir(), "juo-mapping-"));
writeFileSync(path.join(secretsDir, "ingest-juo-fixture-one-key"), KEY);
process.env.INGEST_SECRETS_DIR = secretsDir;
process.env.INGEST_PACE_FACTOR = "0.01";
const logs = [];
const { setLogSink } = await import("../src/core/log.mjs");
setLogSink((line) => logs.push(line));
const map = await import("../src/adapters/juo/map.mjs");
const client = await import("../src/adapters/juo/client.mjs");
const read = await import("../src/adapters/juo/read.mjs");
const { juo } = await import("../src/adapters/juo/index.mjs");
const { ADAPTERS } = await import("../src/adapters/index.mjs");
const { JobBudget } = await import("../src/core/budget.mjs");
const { paceFactor } = await import("../src/core/pace.mjs");

const NOW = Date.parse("2026-10-28T12:00:00.000Z");
const one = juoStore({ handle: "fixture-one", key: KEY, nowMs: NOW });
const sub = (n) => one.subscriptions[n - 1];
const eventsOf = (n) => one.events.filter((e) => e.subscriptionId === sub(n).id);

// The keys cma.subscription, cma.subscription_event, cma.subscription_line and cma.billing_event take in raw (db/118's and
// db/194's checks)
const SUB_RAW = ["id", "status", "customer", "currentCycle", "nextBillingDate", "billingInterval", "billingIntervalCount", "amountPerCycle",
  "currencyCode", "instrumentType", "createdAt", "updatedAt", "canceledAt", "pausedAt", "serial", "minCycles", "maxCycles", "discountCount", "lineCount"];
const EVENT_RAW = ["id", "type", "occurredAt", "subscriptionId", "customerId", "actorType", "actorId", "cycleIndex", "attempt", "errorCode",
  "reason", "previousStatus", "status", "orderId", "billingFrom", "billingTo", "cause", "intervalFrom", "intervalCountFrom", "intervalTo",
  "intervalCountTo", "linesAdded", "linesRemoved", "linesUpdated", "relatedSubscriptionId", "operationId"];
const LINE_RAW = ["id", "subscriptionId", "product", "variant", "quantity", "totalPrice", "currencyCode", "interval", "intervalCount", "minCycles",
  "maxCycles", "recurringCycleLimit", "canceledAt"];
const BILLING_RAW = ["id", "type", "occurredAt", "subscriptionId", "customerId", "orderId", "renewalId", "ownerId", "amount", "currencyCode",
  "reasonCode", "instrumentType", "attempt", "errorCode", "partial"];
const rawOk = (raw, keys) => Object.keys(raw).every((k) => keys.includes(k)) && Object.values(raw).every((v) => v === null || typeof v !== "object")
  && !JSON.stringify(raw).includes("@") && JSON.stringify(raw).length <= 2048;
// Every personal or free-text value the fixture holds, and the personal field names
const PERSONAL = ["Invented", "example.invalid", "@", "Fixture Street", "Testtown", "FX1 1XX", "+44 20", "4242", "****", "asked for a call",
  "Too expensive", "insufficient funds", "UNPROCESSABLE", "visa", "FIXTURE10", "Free", "Service plan", "Ten off", "Return received", "disputed",
  "No stock", "Variant missing", "wants to leave", "Installation (fixture)", "Accessory (fixture)", "Accessory for"];
const PERSONAL_FIELDS = ["deliveryAddress", "billingAddress", "consumerName", "maskedConsumerAccount", "lastDigits", "firstName", "lastName",
  "phone", "email", "customAttributes", "title", "errorMessage", "name", "items", "discounts", "input", "brand"];

// ---- A. The subscription ------------------------------------------------------------------------------------------
const s1 = map.subscriptionItem(sub(1));
expect("A1 a subscription → its item: ids, status, cycle, billing, amount per cycle, currency, the instrument's type, times",
  s1, {
    sourceId: sub(1).id, sourceNumber: "#1001", customerSourceId: "71000000001", status: "active", currentCycle: 6, nextBillingAt: sub(1).nextBillingDate,
    billingInterval: "month", billingIntervalCount: 1, amountPerCycle: 29.95, currency: "GBP", paymentInstrumentType: "card", discountCount: 0,
    lineCount: 2, sourceCreatedAt: sub(1).createdAt, sourceUpdatedAt: sub(1).updatedAt,
    raw: { id: sub(1).id, status: "active", customer: "71000000001", currentCycle: 6, nextBillingDate: sub(1).nextBillingDate, billingInterval: "month",
      billingIntervalCount: 1, amountPerCycle: 29.95, currencyCode: "GBP", instrumentType: "card", createdAt: sub(1).createdAt, updatedAt: sub(1).updatedAt,
      serial: "#1001", discountCount: 0, lineCount: 2 },
  }, null);
const allSubs = one.subscriptions.map(map.subscriptionItem);
const subText = JSON.stringify(allSubs);
expect("A2 PII fields dropped: no name, address, email, phone, card digits, account, note or title of the 230 payloads in any item",
  [PERSONAL.filter((p) => subText.includes(p)), PERSONAL_FIELDS.filter((f) => subText.includes(`"${f}"`)), allSubs.filter(Boolean).length],
  [[], [], 230], [["Invented"], ["deliveryAddress"], 0]);
expect("A3 raw holds the keys cma.subscription takes only, every value a scalar",
  allSubs.every((i) => rawOk(i.raw, SUB_RAW)), true, false);
expect("A4 the statuses in the CMA's spelling: the seven, cancelled as canceled, an unknown one none",
  ["ACTIVE", "paused", "CANCELLED", "canceled", "expired", "FAILED", "merged", "NEVER_SUBSCRIBED", "never-subscribed", "pending", "", null].map(map.statusOf),
  ["active", "paused", "canceled", "canceled", "expired", "failed", "merged", "never-subscribed", "never-subscribed", null, null, null], []);
expect("A5 a subscription of an unknown status, or without an id, is unreadable (none)",
  [map.subscriptionItem({ ...sub(1), status: "pending" }), map.subscriptionItem({ ...sub(1), id: "has space" }), map.subscriptionItem({ ...sub(1), id: undefined })],
  [null, null, null], [{}, {}, {}]);
expect("A6 the instrument's type in the seven codes: a card, SEPA direct debit, paypal; an unexpanded payment method none",
  [sub(1), sub(2), sub(3)].map((s) => map.instrumentOf(s.paymentMethod)).concat([map.instrumentOf("pm-0001"), map.instrumentOf({ instrument: { type: "shop-pay-card" } }),
    map.instrumentOf({ instrument: {} })]),
  ["card", "sepa_direct_debit", "paypal", null, "card", null], []);
expect("A6b Juo's instrument type names → the seven codes (credit-card, CreditCard, SepaDirectDebit, PayPal, iDEAL, Bancontact, Invoice); an unknown one other and named, never a value",
  ["credit-card", "CreditCard", "SepaDirectDebit", "sepa-direct-debit", "PayPal", "paypal", "iDEAL", "bancontact", "Invoice", "Klarna", "person@example.invalid", "", null]
    .map((t) => { const i = map.instrumentInfoOf(t); return i ? `${i.code}${i.unknown ? `:${i.unknown}` : ""}` : null; }),
  ["card", "card", "sepa_direct_debit", "sepa_direct_debit", "paypal", "paypal", "ideal", "bancontact", "invoice", "other:Klarna", "other:unnamed", null, null],
  []);
expect("A9 the app's number, the cycle bounds (billing policy's, else the lines'), the count of discounts (never a code) and of current lines",
  [map.subscriptionItem(sub(213)).minCycles, map.subscriptionItem(sub(213)).maxCycles, map.subscriptionItem({ ...sub(1), billingPolicy: { interval: "MONTH", intervalCount: 1, minCycles: 6, maxCycles: 24 } }).minCycles,
    map.subscriptionItem(sub(214)).discountCount, JSON.stringify(map.subscriptionItem(sub(214))).includes("FIXTURE10"), map.subscriptionItem(sub(50)).lineCount,
    map.subscriptionItem(sub(2)).lineCount, map.subscriptionItem({ ...sub(1), serial: "Invented Person" }).sourceNumber],
  [12, undefined, 6, 1, false, 2, 1, undefined], [null, 0, 12, 0, true, 3, 2, "Invented Person"]);
expect("A7 the customer's id as digits: a number, a text, a gid, an expanded customer; an email or a name none",
  [map.customerIdOf(7100000001), map.customerIdOf("7100000001"), map.customerIdOf("gid://shopify/Customer/7100000001"), map.customerIdOf({ id: "7100000001", email: "x@example.invalid" }),
    map.customerIdOf("person@example.invalid"), map.customerIdOf("Invented Person")],
  ["7100000001", "7100000001", "7100000001", "7100000001", null, null], []);
expect("A8 the amount per cycle: the current items' total prices only (an item Juo canceled left out), two decimals; none without a price",
  [map.subscriptionItem(sub(1)).amountPerCycle, map.subscriptionItem(sub(2)).amountPerCycle, map.subscriptionItem({ ...sub(1), items: [] }).amountPerCycle],
  [29.95, 24.95, undefined], [24.95, 29.95, 0]);

// ---- B. The events --------------------------------------------------------------------------------------------------
const subEvents = one.events.filter((e) => !map.isBillingEvent(e));
const mapped = subEvents.map((e) => [e.type, map.eventItem(e)]);
expect("B1 the event types of the subscription family: the seven and since 0009w fifteen more kept; the copies of billing events duplicates; the rest skipped",
  [...new Set(mapped.map(([t, m]) => `${t}→${m?.skip ? `skip:${m.skip}` : m?.item?.eventType}`))].sort(),
  ["renewal:notification-sent→renewal_notice", "subscription:cancellation-flow/started→skip:type", "subscription:cancelled→canceled",
    "subscription:chargeback-created→skip:duplicate", "subscription:created→created", "subscription:delivery-address-changed→skip:type",
    "subscription:discount-added→discount_changed", "subscription:discount-code-applied→discount_changed", "subscription:frequency-changed→interval_changed",
    "subscription:line-added→lines_changed", "subscription:lines-changed→lines_changed", "subscription:merged-to→merged_to",
    "subscription:migrated→migrated", "subscription:next-billing-date-changed→billing_date_moved", "subscription:paused→paused",
    "subscription:payment-method-changed→payment_method_changed", "subscription:purchased→purchased", "subscription:reactivated→reactivated",
    "subscription:renew-failed→renew_failed", "subscription:renewed→renewed", "subscription:resumed→resumed", "subscription:skipped→skipped",
    "subscription:update-failed→update_failed", "subscription:updated→skip:type", "subscription:updated→status_changed"], []);
const failed1 = map.eventItem(eventsOf(201)[0]);
expect("B2 a failed renewal: its cycle, attempt, error code and reason code; the error message never read",
  failed1, { item: { sourceId: eventsOf(201)[0].id, subscriptionSourceId: sub(201).id, eventType: "renew_failed", occurredAt: eventsOf(201)[0].occurredAt,
    actorType: "system", cycleIndex: 6, attempt: 1, errorCode: "CARD_DECLINED", reasonCode: "billing-attempt-failed",
    raw: { id: eventsOf(201)[0].id, type: "subscription:renew-failed", occurredAt: eventsOf(201)[0].occurredAt, subscriptionId: sub(201).id,
      customerId: "71000000201", actorType: "system", cycleIndex: 6, attempt: 1, errorCode: "CARD_DECLINED", reason: "billing-attempt-failed" } },
  reasonDropped: false }, null);
const cancel = map.eventItem(eventsOf(205)[0]);
expect("B3 free-text reason dropped: a cancellation's reason left out of the item and raw, the event says reasonDropped; the customer's id as actor not kept",
  [cancel.item.reasonCode, cancel.item.raw.reason, cancel.reasonDropped, cancel.item.eventType, cancel.item.statusFrom, cancel.item.statusTo, cancel.item.actorType,
    cancel.item.actorSourceId],
  [undefined, undefined, true, "canceled", "active", "canceled", "customer", undefined], ["Too expensive", "Too expensive", false, null, null, null, null, "x"]);
expect("B4 a reason outside the fixed list dropped, whatever its form; one on the list kept",
  [map.eventItem({ ...eventsOf(201)[0], data: { ...eventsOf(201)[0].data, reason: "some-new-code" } }).reasonDropped,
    map.eventItem({ ...eventsOf(201)[0], data: { ...eventsOf(201)[0].data, reason: "billing-attempt-failed" } }).reasonDropped, map.REASON_CODES],
  [true, false, ["billing-attempt-failed"]], [false, true, []]);
const changed = map.eventItem(eventsOf(203)[0]);
expect("B5 an update with a status: status_changed from ACTIVE to FAILED; an update without one, or with the same status, skipped",
  [changed.item.eventType, changed.item.statusFrom, changed.item.statusTo, map.eventItem(eventsOf(203)[1]).skip,
    map.eventItem({ ...eventsOf(203)[0], data: { input: { status: "ACTIVE" }, status: "ACTIVE" } }).skip, JSON.stringify(changed.item).includes("input")],
  ["status_changed", "active", "failed", "type", "type", false], ["changed", null, null, undefined, undefined, true]);
const paused = map.eventItem(eventsOf(204)[0]);
expect("B6 the actor: a staff actor's id kept (its name never), bulk-action as bulk, api, system; a customer's id not kept",
  [paused.item.actorType, paused.item.actorSourceId, map.eventItem(eventsOf(209)[0]).item.actorType, map.eventItem(eventsOf(209)[1]).item.actorType,
    map.eventItem(eventsOf(209)[1]).item.actorSourceId, map.eventItem({ ...eventsOf(201)[0], actor: "system" }).item.actorType,
    map.eventItem({ ...eventsOf(201)[0], actor: { type: "unknown" } }).item.actorType],
  ["staff", "81100000001", "bulk", "api", undefined, "system", undefined], ["system", undefined, "bulk-action", null, "key-1", null, "unknown"]);
expect("B7 the transitions: paused from active, resumed from paused to active, reactivated from canceled to active",
  [[paused.item.statusFrom, paused.item.statusTo], [map.eventItem(eventsOf(209)[1]).item.statusFrom, map.eventItem(eventsOf(209)[1]).item.statusTo],
    [map.eventItem(eventsOf(210)[0]).item.statusFrom, map.eventItem(eventsOf(210)[0]).item.statusTo]],
  [["active", "paused"], ["paused", "active"], ["canceled", "active"]], []);
expect("B8 an error code upper case; one that is no code (spaces) dropped; a renewal keeps its order id",
  [map.eventItem(eventsOf(202)[0]).item.errorCode, map.eventItem({ ...eventsOf(201)[0], data: { errorCode: "Card was declined" } }).item.errorCode,
    map.eventItem(eventsOf(202)[1]).item.raw.orderId],
  ["PROCESSING_ERROR", undefined, "6100000202"], ["processing_error", "Card was declined", undefined]);
expect("B9 an event without an id, a subscription or a time is unreadable (none); one owned by a subscription without subscriptionId is read",
  [map.eventItem({ ...eventsOf(201)[0], id: undefined }), map.eventItem({ ...eventsOf(201)[0], subscriptionId: undefined, owner: { entity: "Customer", id: "c" } }),
    map.eventItem({ ...eventsOf(201)[0], occurredAt: "yesterday" }), map.eventItem({ ...eventsOf(201)[0], subscriptionId: undefined }).item.subscriptionSourceId],
  [null, null, null, sub(201).id], [{}, {}, {}, null]);
const evText = JSON.stringify(mapped.map(([, m]) => m));
expect("B10 PII fields dropped from every event: no name, email, message, free-text reason or update input in any item",
  [PERSONAL.filter((p) => evText.includes(p)), PERSONAL_FIELDS.filter((f) => evText.includes(`"${f}"`))], [[], []], [["x"], ["x"]]);
expect("B11 raw holds the keys cma.subscription_event takes only, every value a scalar",
  mapped.every(([, m]) => !m?.item || rawOk(m.item.raw, EVENT_RAW)), true, false);

expect("B12 the event types the logs and the dry run count: a type name as it is, anything else unknown (never a value)",
  [map.eventTypeOf(eventsOf(201)[0]), map.eventTypeOf({ type: "subscription:cancellation-flow/started" }), map.eventTypeOf({ type: "person@example.invalid" }),
    map.eventTypeOf({ type: "Too expensive" }), map.eventTypeOf({}), map.eventTypeOf({ type: `subscription:${"x".repeat(60)}` })],
  ["subscription:renew-failed", "subscription:cancellation-flow/started", "unknown", "unknown", "unknown", "unknown"], []);

// ---- C. Settings, the store's id, holds, queries ------------------------------------------------------------------------
expect("C1 the settings: the defaults (5 minutes, 2 a second), values in range kept, out of range the default and named",
  [client.juoSettings({}), client.juoSettings({ subscriptions_poll_interval_minutes: "60", subscriptions_max_per_second: 10 }),
    client.juoSettings({ subscriptions_poll_interval_minutes: 61, subscriptions_max_per_second: 0 })],
  [{ perSecond: 2, intervalMinutes: 5, fallbacks: [] }, { perSecond: 10, intervalMinutes: 60, fallbacks: [] },
    { perSecond: 2, intervalMinutes: 5, fallbacks: ["subscriptions_max_per_second", "subscriptions_poll_interval_minutes"] }], []);
const idOrCode = (account) => { try { return client.tenantIdOf({ externalAccountId: account }); } catch (e) { return e.code; } };
expect("C2 the store's id: <handle>.myshopify.com in lower case; anything else tenant_id_invalid; the handle before the first dot",
  [idOrCode(" Fixture-One.myshopify.com "), idOrCode("fixture-one"), idOrCode("fixture-one.example.com"), idOrCode("evil.myshopify.com.example.com"),
    client.handleOf({ externalAccountId: "fixture-one.myshopify.com" })],
  ["fixture-one.myshopify.com", "tenant_id_invalid", "tenant_id_invalid", "tenant_id_invalid", "fixture-one"], []);
const f = paceFactor();
expect("C3 the hold after a 429: Retry-After in seconds or as a date, at most a minute, five seconds without one (scaled by the pace factor)",
  [client.holdMsOf({ "retry-after": "2" }), client.holdMsOf({ "retry-after": new Date(NOW + 3000).toUTCString() }, NOW), client.holdMsOf({}),
    client.holdMsOf({ "retry-after": "600" })].map((ms) => Math.round(ms / f)),
  [2000, 3000, 5000, 60000], [0, 0, 0, 600000]);
expect("C4 the endpoint for the counts: the path, no query, ids replaced",
  [client.endpointOf("GET", "/subscriptions?limit=100&query=id%3A'x'"), client.endpointOf("GET", "/subscriptions/14cd8995-56ae-4b43-bd9c-a568c95e5833")],
  ["GET /subscriptions", "GET /subscriptions/{id}"], []);
const familyOrCode = (f) => { try { return read.eventsQuery(NOW, null, { family: f }); } catch (e) { return e.code; } };
expect("C5 the queries: each family's events of a window (after, from, before), subscriptions by id (an id out of its form left out), an unknown family refused",
  [read.eventsQuery(NOW), read.eventsQuery(NOW, NOW + 60_000, { inclusive: true }), read.eventsQuery(NOW, null, { family: "billing" }),
    read.idsQuery(["a-1", "b 2", "c-3"]), read.idsQuery(["x y"]), familyOrCode("customer")],
  [`${SUBSCRIPTION_FAMILY} AND occurredAt:>'2026-10-28T12:00:00.000Z'`,
    `${SUBSCRIPTION_FAMILY} AND occurredAt:>='2026-10-28T12:00:00.000Z' AND occurredAt:<'2026-10-28T12:01:00.000Z'`,
    `${BILLING_FAMILY} AND occurredAt:>'2026-10-28T12:00:00.000Z'`, "(id:'a-1' OR id:'c-3')", null, "family_unknown"], []);
expect("C6 the adapter registered as juo, polling only (no route), subscriptions and the catalog read whole, four objects backfilled, two reconciled, a connection without a key skipped",
  [ADAPTERS.juo === juo, juo.kind, juo.wholeObjects, juo.backfillObjects, juo.reconcileObjects, juo.skipReason({ tokenSecretName: null }),
    juo.skipReason({ tokenSecretName: "ingest-juo-fixture-one-key" })],
  [true, "poll", ["subscription", "subscription_product"], ["subscription", "subscription_product", "subscription_event", "billing_event"],
    ["subscription", "subscription_product"], "key_not_set", null], []);
const startOf = async (setting) => juo.backfillFrom("subscription_event", { settings: async () => ({ "subscriptions.history_start_date": setting }) });
expect("C7 an events backfill's start without --from: subscriptions.history_start_date, else all history; subscriptions and the catalog all history",
  [await startOf("2025-05-01"), await startOf(""), await startOf(" "), await juo.backfillFrom("billing_event", { settings: async () => ({}) }),
    await juo.backfillFrom("subscription", { settings: async () => ({ "subscriptions.history_start_date": "2025-05-01" }) })],
  ["2025-05-01", { allHistory: true }, { allHistory: true }, { allHistory: true }, { allHistory: true }], []);

// ---- E. Lines --------------------------------------------------------------------------------------------------------
const l50 = map.lineItems(sub(50));
expect("E1 a subscription's lines, canceled ones included: a recurring line, a canceled one, a one-time add-on (cycle limit 1); ids, quantity, amount, currency, interval",
  l50.lines.map((l) => [l.sourceId, l.subscriptionSourceId === sub(50).id, l.productSourceId, l.variantSourceId, l.quantity, l.amountPerCycle, l.currency,
    l.billingInterval, l.billingIntervalCount, l.recurringCycleLimit ?? null, Boolean(l.canceledAt)]),
  [["item-0050", true, "71000000001", "41000000001", 1, 24.95, "GBP", "month", 1, null, false],
    ["item-0050-b", true, "71000000002", "41000000002", 1, 5, "GBP", "month", 1, null, true],
    ["item-0050-c", true, "71000000003", "41000000003", 1, 49, "GBP", "month", 1, 1, false]], []);
const allLines = one.subscriptions.flatMap((x) => map.lineItems(x).lines);
const lineText = JSON.stringify(allLines);
expect("E2 a line's title, subtitle and custom attributes never read; raw holds the keys cma.subscription_line takes only",
  [PERSONAL.filter((x) => lineText.includes(x)), ["title", "subtitle", "customAttributes", "_ordered_by"].filter((f) => lineText.includes(f)),
    allLines.every((l) => rawOk(l.raw, LINE_RAW)), allLines.length],
  [[], [], true, 230 * 2 + 4], [["x"], ["x"], false, 0]);
expect("E3 a line's own cycle bounds (213's minimum of 12); a line without an id unreadable; a subscription without lines none",
  [map.lineItems(sub(213)).lines[0].minCycles, map.lineItems({ ...sub(1), items: [{ quantity: 1 }, ...sub(1).items] }).unreadable,
    map.lineItems({ ...sub(1), items: undefined }).lines.length],
  [12, 1, 0], [null, 0, 2]);

// ---- F. The catalog ---------------------------------------------------------------------------------------------------
const cat = one.products.map(map.productItems);
expect("F1 the catalog: per variant the product and variant ids, titles, SKU and the product's status in lower case",
  cat.slice(0, 3).map((c) => c.variants), [
    [{ productSourceId: "71000000001", variantSourceId: "41000000001", productTitle: "Plan A (catalog fixture)", variantTitle: "Monthly", sku: "PLAN-A-M", productStatus: "active" }],
    [{ productSourceId: "71000000002", variantSourceId: "41000000002", productTitle: "Accessory (catalog fixture)", productStatus: "active" }],
    [{ productSourceId: "71000000003", variantSourceId: "41000000003", productTitle: "Installation (catalog fixture)", variantTitle: "One-time", sku: "INSTALL-1", productStatus: "draft" }]], []);
expect("F2 a title with an @ and a SKU with a control character left out and counted; images, plan groups and prices never read",
  [cat[1].textDropped, cat.reduce((n, c) => n + c.textDropped, 0), JSON.stringify(cat).includes("Invented"), JSON.stringify(cat).includes("@"),
    ["image", "planGroups", "price", "collections"].filter((k) => JSON.stringify(cat).includes(`"${k}"`))],
  [2, 2, false, false, []], [0, 0, true, true, ["image"]]);
expect("F3 catalog text: trimmed, at most 100 characters; an @ or a control character dropped; none for no text",
  [map.catalogTextOf(` ${"x".repeat(120)} `).value.length, map.catalogTextOf("a@b").dropped, map.catalogTextOf("tab\there").dropped, map.catalogTextOf("").value,
    map.catalogTextOf(42).value], [100, true, true, null, null], [120, false, false, "", 42]);
expect("F4 a product without an id unreadable with its variants; a variant without an id unreadable",
  [map.productItems({ title: "x", variants: [{ id: "1" }, { id: "2" }] }).unreadable, map.productItems({ id: "9", variants: [{ title: "x" }, { id: "3" }] }).unreadable],
  [2, 1], [0, 0]);

// ---- G. The new event types ----------------------------------------------------------------------------------------------
const ev = (n, type) => map.eventItem(one.events.find((e) => e.subscriptionId === sub(n).id && e.type === type)).item;
expect("G1 a migration: its current cycle as cycle, its next billing date; a billing-date move: from, to and cause, with its operation",
  [ev(213, "subscription:migrated").cycleIndex, ev(213, "subscription:migrated").billingFromAt ?? null,
    Boolean(ev(213, "subscription:migrated").billingToAt), ev(213, "subscription:next-billing-date-changed").causeCode,
    Boolean(ev(213, "subscription:next-billing-date-changed").billingFromAt && ev(213, "subscription:next-billing-date-changed").billingToAt),
    ev(213, "subscription:next-billing-date-changed").operationSourceId],
  [3, null, true, "requested", true, "op-0213"], [null, "x", false, null, false, null]);
expect("G2 a skip (skipped date, next billing date); an interval change (month 1 → year 1); a discount's cause, never its code",
  [Boolean(ev(214, "subscription:skipped").billingFromAt && ev(214, "subscription:skipped").billingToAt), ev(215, "subscription:frequency-changed").intervalFrom,
    ev(215, "subscription:frequency-changed").intervalCountFrom, ev(215, "subscription:frequency-changed").intervalTo, ev(215, "subscription:frequency-changed").intervalCountTo,
    ev(214, "subscription:discount-code-applied").causeCode, ev(211, "subscription:discount-added").causeCode,
    JSON.stringify(ev(214, "subscription:discount-code-applied")).includes("FIXTURE10")],
  [true, "month", 1, "year", 1, "code_applied", "added", false], [false, null, null, null, null, null, null, true]);
expect("G3 a line change: the counts of lines added, removed, updated (ids not kept); a single line added counts one, with the same operation id",
  [[ev(216, "subscription:lines-changed").linesAdded, ev(216, "subscription:lines-changed").linesRemoved, ev(216, "subscription:lines-changed").linesUpdated],
    [ev(216, "subscription:line-added").linesAdded, ev(216, "subscription:line-added").linesRemoved],
    ev(216, "subscription:lines-changed").operationSourceId === ev(216, "subscription:line-added").operationSourceId,
    JSON.stringify(ev(216, "subscription:lines-changed")).includes("item-x1"), ev(216, "subscription:lines-changed").actorSourceId],
  [[2, 1, 0], [1, undefined], true, false, "81100000002"], [[0, 0, 0], [0, 1], false, true, null]);
expect("G4 a merge names the other subscription; a payment method change, a renewal notice, a purchase and a creation kept; an update failure keeps its code, never its message",
  [ev(218, "subscription:merged-to").relatedSubscriptionSourceId, ev(217, "subscription:payment-method-changed").eventType,
    JSON.stringify(ev(217, "subscription:payment-method-changed")).includes("pm-0217"), ev(220, "renewal:notification-sent").eventType,
    ev(221, "subscription:purchased").eventType, ev(222, "subscription:created").eventType, ev(219, "subscription:update-failed").errorCode,
    JSON.stringify(ev(219, "subscription:update-failed")).includes("Variant missing")],
  [sub(219).id, "payment_method_changed", false, "renewal_notice", "purchased", "created", "INVALID_VARIANT", false],
  [null, null, true, null, null, null, null, true]);
expect("G5 a renewal keeps its store order as orderSourceId (what a chargeback's order joins); no other type does",
  [map.eventItem(eventsOf(1)[0]).item.orderSourceId, map.eventItem(eventsOf(201)[0]).item.orderSourceId, ev(221, "subscription:purchased").orderSourceId],
  ["610000001", undefined, undefined], [undefined, "x", "6100000221"]);

// ---- H. Billing events -------------------------------------------------------------------------------------------------
const billingEvents = one.events.filter(map.isBillingEvent);
const bm = billingEvents.map(map.billingEventItem);
const bOf = (n, type) => map.billingEventItem(billingEvents.find((e) => e.customerId === sub(n).customer && e.type === type));
expect("H1 the ten billing types → their kinds; a subscription event is no billing event",
  [...new Set(bm.map((m) => m.item.kind))].sort(), ["chargeback", "invoice_overdue", "invoice_paid", "invoice_payment_failed", "invoice_placed",
    "order_draft_created", "order_placement_failed", "refund_completed", "refund_created", "refund_failed"], []);
const cb5 = bOf(5, "chargeback:created");
expect("H2 a SEPA chargeback: no subscription, the customer, the store's order, amount and currency, return code MD06, instrument sepa_direct_debit, its own id as owner; the message never read",
  [cb5.item.subscriptionSourceId, cb5.item.customerSourceId, cb5.item.orderSourceId, cb5.item.amount, cb5.item.currency, cb5.item.returnCode, cb5.item.instrumentType,
    Boolean(cb5.item.ownerSourceId), cb5.returnCodeDropped, JSON.stringify(cb5).includes("disputed")],
  [undefined, "71000000005", "610000005", 24.95, "GBP", "MD06", "sepa_direct_debit", true, false, false], ["x", null, null, 0, null, null, null, false, true, true]);
expect("H3 a card dispute reason kept as a code (fraudulent); a reason out of the code form dropped and flagged; an unknown instrument other and named",
  [bOf(6, "chargeback:created").item.returnCode, bOf(6, "chargeback:created").item.instrumentType, bOf(7, "chargeback:created").item.returnCode,
    bOf(7, "chargeback:created").returnCodeDropped, bOf(7, "chargeback:created").item.instrumentType, bOf(7, "chargeback:created").instrumentUnknown],
  ["fraudulent", "card", undefined, true, "other", "Klarna"], [null, null, "No Mandate given", false, null, null]);
const codeOf = (c) => { const m = map.billingEventItem({ ...billingEvents.find((e) => e.type === "chargeback:created"), data: { reasonCode: c } }); return m.item.returnCode ?? (m.returnCodeDropped ? "dropped" : null); };
expect("H3b the return code's form: a scheme's four characters or a lower-case reason; an account number's shape, a mixed word or a sentence dropped; an instrument name with a space unnamed",
  [codeOf("MD01"), codeOf("AM04"), codeOf("fraudulent"), codeOf("product_not_received"), codeOf("NL91ABNA0417164300"), codeOf("Fraudulent"), codeOf("md01x"),
    map.instrumentInfoOf("Invented Person").unknown],
  ["MD01", "AM04", "fraudulent", "product_not_received", "dropped", "dropped", "dropped", "unnamed"], []);
expect("H4 refunds: amount, order, partial; the note never read; only a refund says partial",
  [bOf(8, "refund:completed").item.amount, bOf(8, "refund:completed").item.orderSourceId, bOf(8, "refund:completed").item.partial, bOf(8, "refund:failed").item.partial,
    JSON.stringify(bm).includes("Return received"), cb5.item.partial],
  [24.95, "610000008", false, true, false, undefined], [0, null, null, null, true, false]);
const inv9 = bOf(9, "invoice:placed");
expect("H5 an invoice renewal: the subscription, the renewal, its order as owner (paid pairs with placed by it), the total; a failed payment's attempt and code, never its message",
  [inv9.item.subscriptionSourceId, Boolean(inv9.item.renewalSourceId), inv9.item.ownerSourceId === bOf(9, "invoice:paid").item.ownerSourceId, inv9.item.amount,
    bOf(10, "invoice:payment-failed").item.attempt, bOf(10, "invoice:payment-failed").item.errorCode, JSON.stringify(bm).includes("insufficient funds")],
  [sub(9).id, true, true, 24.95, 2, "INSUFFICIENT_FUNDS", false], [null, false, false, 0, null, null, true]);
expect("H6 raw holds the keys cma.billing_event takes only; no name, email, note or message in any item; a non-billing type skipped; one without an id or a time none",
  [bm.every((m) => rawOk(m.item.raw, BILLING_RAW)), PERSONAL.filter((x) => JSON.stringify(bm).includes(x)), map.billingEventItem(eventsOf(1)[0]).skip,
    map.billingEventItem({ ...billingEvents[0], id: undefined }), map.billingEventItem({ ...billingEvents[0], occurredAt: null })],
  [true, [], "type", null, null], [false, ["x"], undefined, {}, {}]);

// ---- I. The client's allow-list -------------------------------------------------------------------------------------------
const allowed = (m, pth) => { try { client.assertAllowed(m, pth); return "allowed"; } catch (e) { return e.code; } };
expect("I1 the allow-list: GET /subscriptions, /events, /products, /analytics/metrics and POST /analytics/query only (a query string read over); everything else method_not_allowed",
  [allowed("GET", "/subscriptions?limit=1"), allowed("GET", "/events"), allowed("GET", "/products"), allowed("GET", "/analytics/metrics"),
    allowed("POST", "/analytics/query"), allowed("DELETE", "/subscriptions/x"), allowed("POST", "/subscriptions"), allowed("PUT", "/subscriptions/x"),
    allowed("PATCH", "/subscriptions"), allowed("GET", "/customers"), allowed("GET", "/subscriptions/x"), allowed("POST", "/analytics/metrics"),
    allowed("GET", "/analytics/query"), allowed("POST", "/subscriptions/x/cancel"), allowed("GET", "/subscriptions/../customers"),
    allowed("GET", "/subscriptions%2F..%2Fcustomers"), allowed("GET", "//subscriptions"), allowed("GET", "/Subscriptions"), allowed("get", "/subscriptions"),
    allowed("GET", "/subscriptions#x"), allowed("GET", null), (() => { try { client.ALLOWED[0][0] = "DELETE"; } catch { /* frozen */ } return client.ALLOWED[0][0]; })()],
  ["allowed", "allowed", "allowed", "allowed", "allowed", "method_not_allowed", "method_not_allowed", "method_not_allowed", "method_not_allowed",
    "method_not_allowed", "method_not_allowed", "method_not_allowed", "method_not_allowed", "method_not_allowed", "method_not_allowed", "method_not_allowed",
    "method_not_allowed", "method_not_allowed", "method_not_allowed", "method_not_allowed", "method_not_allowed", "GET"], []);

// ---- D. The client against the fake Juo ---------------------------------------------------------------------------------
const two = juoStore({ handle: "fixture-two", key: KEY2, nowMs: NOW, prefix: "t" });
const fake = await startFakeJuo({ stores: [one, two] });
process.env.INGEST_JUO_API_BASE = fake.url;
const conn = (account = one.domain, secret = "ingest-juo-fixture-one-key") => ({ connectionId: `conn-${account}`, externalAccountId: account, tokenSecretName: secret });
const settings = { subscriptions_max_per_second: 10 };
fake.state.requests.length = 0;
const api = client.juoClient(conn(), settings, new JobBudget({}));
const refused = [];
for (const [m, pth] of [["DELETE", "/subscriptions/x"], ["POST", "/subscriptions"], ["PUT", "/subscriptions/x"], ["GET", "/customers"]]) {
  try { await api.request(m, pth, {}); refused.push("sent"); } catch (e) { refused.push(e.code); }
}
expect("I2 the client refuses a write before any request: DELETE /subscriptions/x, POST /subscriptions, PUT, GET /customers → method_not_allowed, no request reached the fake",
  [refused, fake.state.requests.length], [["method_not_allowed", "method_not_allowed", "method_not_allowed", "method_not_allowed"], 0], [["sent"], 4]);
const collect = async (iter) => { const out = []; for await (const p of iter) out.push(p); return out; };
const codeOfRun = async (fn) => { try { await fn(); return "ok"; } catch (e) { return e.code ?? e.message; } };

let budget = new JobBudget({});
let pages = await collect(read.clientFor(conn(), settings, budget).subscriptions());
expect("D1 paging: the 230 subscriptions in three pages of at most 100, the payment method expanded, the key in a header and never in the address",
  [pages.map((p) => p.length), fake.state.requests.every((r) => r.authorized && !r.keyInUrl && r.tenant === one.domain), fake.state.requests[0].params.expand,
    fake.state.requests[0].params.includeCanceledItems, pages.flat().find((x) => x.id === sub(2).id).items.length, budget.usage().api],
  [[100, 100, 30], true, "paymentMethod", "true", 2, { "GET /subscriptions": 3 }], [[230], false, undefined, undefined, 1, {}]);
const byId = await collect(read.clientFor(conn(), settings, new JobBudget({})).subscriptionsById(one.subscriptions.slice(0, 30).map((s) => s.id)));
expect("D2 subscriptions read again by id, 25 a query: 30 ids in two batches", byId.map((b) => b.length), [25, 5], [30]);
const evPages = await collect(read.clientFor(conn(), settings, new JobBudget({})).events(read.eventsQuery(NOW - 60 * 24 * 60_000 * 30)));
const evList = evPages.flat();
const blList = (await collect(read.clientFor(conn(), settings, new JobBudget({})).events(read.eventsQuery(NOW - 60 * 24 * 60_000 * 30, null, { family: "billing" })))).flat();
expect("D3 each family's events of a window, oldest first, in pages: the subscription family and the billing family, together every event",
  [evList.length, evList.every((e, i) => i === 0 || Date.parse(evList[i - 1].occurredAt) <= Date.parse(e.occurredAt)), blList.length, evList.length + blList.length,
    blList.every(map.isBillingEvent)],
  [subEvents.length, true, billingEvents.length, one.events.length, true], [0, false, 0, 0, false]);
const prodPages = await collect(read.clientFor(conn(), settings, new JobBudget({})).products());
expect("D3b the catalog in pages: 153 products in two pages", prodPages.map((x) => x.length), [100, 53], [153]);
fake.state.requests.length = 0;
expect("D4 401 wrong tenant: the store's key with another store's id → key_rejected, one request",
  [await codeOfRun(() => collect(read.clientFor(conn(two.domain), settings, new JobBudget({})).subscriptions())), fake.state.requests.length],
  ["key_rejected", 1], ["ok", 2]);
fake.state.requests.length = 0;
fake.state.fail429 = 1;
fake.state.retryAfter = "2";
client.resetClients();
pages = await collect(read.clientFor(conn(), settings, new JobBudget({})).subscriptions({ query: read.idsQuery([sub(1).id]) }));
const gap = fake.state.requests.length === 2 ? fake.state.requests[1].at - fake.state.requests[0].at : -1;
expect("D5 429 paced: held until its Retry-After (2 s × the pace factor), the same request sent again and answered; logged",
  [pages.flat().length, fake.state.requests.length, gap >= 2000 * f - 2, fake.state.requests[0].params.query === fake.state.requests[1]?.params.query,
    logs.some((l) => JSON.parse(l).message === "juo rate limited" && JSON.parse(l).retried === true)],
  [1, 2, true, true, true], [0, 1, false, false, false]);
fake.state.requests.length = 0;
fake.state.fail429 = 3;
fake.state.retryAfter = null;
expect("D6 a third 429 fails the read rate_limited (three requests, five seconds × the pace factor apart without Retry-After)",
  [await codeOfRun(() => collect(read.clientFor(conn(), settings, new JobBudget({})).subscriptions())), fake.state.requests.length,
    fake.state.requests[2].at - fake.state.requests[1].at >= 5000 * f - 2],
  ["rate_limited", 3, true], ["ok", 1, false]);
fake.state.fail429 = 0;
fake.state.requests.length = 0;
expect("D7 no secret → token_unavailable; a store id out of its form → tenant_id_invalid; neither sends a request",
  [await codeOfRun(() => collect(read.clientFor(conn(one.domain, "ingest-juo-missing-key"), settings, new JobBudget({})).subscriptions())),
    await codeOfRun(() => collect(read.clientFor(conn("fixture-one"), settings, new JobBudget({})).subscriptions())), fake.state.requests.length],
  ["token_unavailable", "tenant_id_invalid", 0], ["ok", "ok", 1]);
const logText = logs.join("\n");
expect("D8 the log holds no key, no value: codes and counts only", [KEY, KEY2, "Invented", "example.invalid"].filter((v) => logText.includes(v)), [], ["x"]);

await fake.close();
rmSync(secretsDir, { recursive: true, force: true });
verdict();
