/**
 * Verifier: the Juo adapter's mapping and client (addition 0008zl, brief B20), without a database: the whitelist of
 * map.mjs on the fixture's payloads (verify/juo-fake.mjs), which carry invented personal data on purpose (names,
 * addresses, emails, phone numbers, card digits, an account, a free-text cancellation reason, an error message), the
 * event types, the settings, the store's id, the holds after a 429, the queries; then the client against the fake Juo on
 * localhost: paging, the key in a header only, 401 for another store's id (key_rejected), a 429 paced and sent again, a
 * third 429 failing rate_limited, a missing secret, a store id out of its form. Everything is invented.
 *
 *   node verify/juo-mapping.mjs             every check must PASS
 *   node verify/juo-mapping.mjs --provoke   every check must FAIL
 */
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, verdict, PROVOKE } from "./lib.mjs";
import { juoStore, startFakeJuo } from "./juo-fake.mjs";

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

// The keys cma.subscription and cma.subscription_event take in raw (db/118's checks)
const SUB_RAW = ["id", "status", "customer", "currentCycle", "nextBillingDate", "billingInterval", "billingIntervalCount", "amountPerCycle",
  "currencyCode", "instrumentType", "createdAt", "updatedAt", "canceledAt", "pausedAt"];
const EVENT_RAW = ["id", "type", "occurredAt", "subscriptionId", "customerId", "actorType", "actorId", "cycleIndex", "attempt", "errorCode",
  "reason", "previousStatus", "status", "orderId"];
// Every personal or free-text value the fixture holds, and the personal field names
const PERSONAL = ["Invented", "example.invalid", "@", "Fixture Street", "Testtown", "FX1 1XX", "+44 20", "4242", "****", "asked for a call",
  "Too expensive", "insufficient funds", "UNPROCESSABLE", "visa", "FIXTURE10", "Free", "Service plan"];
const PERSONAL_FIELDS = ["deliveryAddress", "billingAddress", "consumerName", "maskedConsumerAccount", "lastDigits", "firstName", "lastName",
  "phone", "email", "customAttributes", "title", "errorMessage", "name", "items", "discounts", "input", "brand"];

// ---- A. The subscription ------------------------------------------------------------------------------------------
const s1 = map.subscriptionItem(sub(1));
expect("A1 a subscription → its item: ids, status, cycle, billing, amount per cycle, currency, the instrument's type, times",
  s1, {
    sourceId: sub(1).id, customerSourceId: "71000000001", status: "active", currentCycle: 6, nextBillingAt: sub(1).nextBillingDate,
    billingInterval: "month", billingIntervalCount: 1, amountPerCycle: 29.95, currency: "GBP", paymentInstrumentType: "card",
    sourceCreatedAt: sub(1).createdAt, sourceUpdatedAt: sub(1).updatedAt,
    raw: { id: sub(1).id, status: "active", customer: "71000000001", currentCycle: 6, nextBillingDate: sub(1).nextBillingDate, billingInterval: "month",
      billingIntervalCount: 1, amountPerCycle: 29.95, currencyCode: "GBP", instrumentType: "card", createdAt: sub(1).createdAt, updatedAt: sub(1).updatedAt },
  }, null);
const allSubs = one.subscriptions.map(map.subscriptionItem);
const subText = JSON.stringify(allSubs);
expect("A2 PII fields dropped: no name, address, email, phone, card digits, account, note or title of the 230 payloads in any item",
  [PERSONAL.filter((p) => subText.includes(p)), PERSONAL_FIELDS.filter((f) => subText.includes(`"${f}"`)), allSubs.filter(Boolean).length],
  [[], [], 230], [["Invented"], ["deliveryAddress"], 0]);
expect("A3 raw holds the keys cma.subscription takes only, every value a scalar",
  allSubs.every((i) => Object.keys(i.raw).every((k) => SUB_RAW.includes(k)) && Object.values(i.raw).every((v) => v === null || typeof v !== "object")),
  true, false);
expect("A4 the statuses in the CMA's spelling: the seven, cancelled as canceled, an unknown one none",
  ["ACTIVE", "paused", "CANCELLED", "canceled", "expired", "FAILED", "merged", "NEVER_SUBSCRIBED", "never-subscribed", "pending", "", null].map(map.statusOf),
  ["active", "paused", "canceled", "canceled", "expired", "failed", "merged", "never-subscribed", "never-subscribed", null, null, null], []);
expect("A5 a subscription of an unknown status, or without an id, is unreadable (none)",
  [map.subscriptionItem({ ...sub(1), status: "pending" }), map.subscriptionItem({ ...sub(1), id: "has space" }), map.subscriptionItem({ ...sub(1), id: undefined })],
  [null, null, null], [{}, {}, {}]);
expect("A6 the instrument's type: a card, paypal, anything else other; an unexpanded payment method none",
  [sub(1), sub(2), sub(3)].map((s) => map.instrumentOf(s.paymentMethod)).concat([map.instrumentOf("pm-0001"), map.instrumentOf({ instrument: { type: "shop-pay-card" } }),
    map.instrumentOf({ instrument: {} })]),
  ["card", "other", "paypal", null, "card", null], []);
expect("A7 the customer's id as digits: a number, a text, a gid, an expanded customer; an email or a name none",
  [map.customerIdOf(7100000001), map.customerIdOf("7100000001"), map.customerIdOf("gid://shopify/Customer/7100000001"), map.customerIdOf({ id: "7100000001", email: "x@example.invalid" }),
    map.customerIdOf("person@example.invalid"), map.customerIdOf("Invented Person")],
  ["7100000001", "7100000001", "7100000001", "7100000001", null, null], []);
expect("A8 the amount per cycle: the current items' total prices only (an item Juo canceled left out), two decimals; none without a price",
  [map.subscriptionItem(sub(1)).amountPerCycle, map.subscriptionItem(sub(2)).amountPerCycle, map.subscriptionItem({ ...sub(1), items: [] }).amountPerCycle],
  [29.95, 24.95, undefined], [24.95, 29.95, 0]);

// ---- B. The events --------------------------------------------------------------------------------------------------
const mapped = one.events.map((e) => [e.type, map.eventItem(e)]);
expect("B1 the event types: renewed, renew-failed, cancelled, paused, resumed, reactivated and an update with a status kept; the rest skipped",
  [...new Set(mapped.map(([t, m]) => `${t}→${m?.skip ? "skip" : m?.item?.eventType}`))].sort(),
  ["subscription:cancelled→canceled", "subscription:delivery-address-changed→skip", "subscription:discount-added→skip", "subscription:paused→paused",
    "subscription:reactivated→reactivated", "subscription:renew-failed→renew_failed", "subscription:renewed→renewed", "subscription:resumed→resumed",
    "subscription:updated→skip", "subscription:updated→status_changed"], []);
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
  mapped.every(([, m]) => !m?.item || (Object.keys(m.item.raw).every((k) => EVENT_RAW.includes(k)) && Object.values(m.item.raw).every((v) => typeof v !== "object"))),
  true, false);

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
expect("C5 the queries: the events of a window (after, from, before), subscriptions by id (an id out of its form left out)",
  [read.eventsQuery(NOW), read.eventsQuery(NOW, NOW + 60_000, { inclusive: true }), read.idsQuery(["a-1", "b 2", "c-3"]), read.idsQuery(["x y"])],
  ["category:subscription AND occurredAt:>'2026-10-28T12:00:00.000Z'",
    "category:subscription AND occurredAt:>='2026-10-28T12:00:00.000Z' AND occurredAt:<'2026-10-28T12:01:00.000Z'", "(id:'a-1' OR id:'c-3')", null], []);
expect("C6 the adapter registered as juo, polling only (no route), subscription read whole, both objects backfilled, a connection without a key skipped",
  [ADAPTERS.juo === juo, juo.kind, juo.wholeObjects, juo.backfillObjects, juo.reconcileObjects, juo.skipReason({ tokenSecretName: null }),
    juo.skipReason({ tokenSecretName: "ingest-juo-fixture-one-key" })],
  [true, "poll", ["subscription"], ["subscription", "subscription_event"], ["subscription"], "key_not_set", null], []);

// ---- D. The client against the fake Juo ---------------------------------------------------------------------------------
const two = juoStore({ handle: "fixture-two", key: KEY2, nowMs: NOW, prefix: "t" });
const fake = await startFakeJuo({ stores: [one, two] });
process.env.INGEST_JUO_API_BASE = fake.url;
const conn = (account = one.domain, secret = "ingest-juo-fixture-one-key") => ({ connectionId: `conn-${account}`, externalAccountId: account, tokenSecretName: secret });
const settings = { subscriptions_max_per_second: 10 };
const collect = async (iter) => { const out = []; for await (const p of iter) out.push(p); return out; };
const codeOfRun = async (fn) => { try { await fn(); return "ok"; } catch (e) { return e.code ?? e.message; } };

let budget = new JobBudget({});
let pages = await collect(read.clientFor(conn(), settings, budget).subscriptions());
expect("D1 paging: the 230 subscriptions in three pages of at most 100, the payment method expanded, the key in a header and never in the address",
  [pages.map((p) => p.length), fake.state.requests.every((r) => r.authorized && !r.keyInUrl && r.tenant === one.domain), fake.state.requests[0].params.expand,
    budget.usage().api],
  [[100, 100, 30], true, "paymentMethod", { "GET /subscriptions": 3 }], [[230], false, undefined, {}]);
const byId = await collect(read.clientFor(conn(), settings, new JobBudget({})).subscriptionsById(one.subscriptions.slice(0, 30).map((s) => s.id)));
expect("D2 subscriptions read again by id, 25 a query: 30 ids in two batches", byId.map((b) => b.length), [25, 5], [30]);
const evPages = await collect(read.clientFor(conn(), settings, new JobBudget({})).events(read.eventsQuery(NOW - 60 * 24 * 60_000 * 30)));
const evList = evPages.flat();
expect("D3 the events of a window, oldest first, in pages", [evList.length, evList.every((e, i) => i === 0 || Date.parse(evList[i - 1].occurredAt) <= Date.parse(e.occurredAt))],
  [one.events.length, true], [0, false]);
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
