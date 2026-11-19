/**
 * Verifier: the Juo adapter for a store's subscriptions end to end (addition 0008zl, brief B20), against a local or dev
 * PostgreSQL with db/00…118 and the fake Juo (verify/juo-fake.mjs). Everything is invented: tenants, stores, keys,
 * subscriptions, customer ids, names (Invented Person …), addresses and emails (example.invalid).
 *
 *   CMA_DB_HOST=/tmp CMA_DB_PORT=5432 CMA_DB_NAME=cma CMA_DB_USER=cma-ingest@local.iam \
 *   INGEST_FLOW_ADMIN_USER=<team login> node verify/juo-flow.mjs [--provoke]
 *
 * Logins as in verify/flow.mjs. It refuses a database without the dev seed (no active agent.two@example.com: exit 2), so
 * it runs in dev or a local database only. Two throwaway tenants per run (juo-<run>-one, juo-<run>-two), each with a
 * commerce store (its handle, its connection, the customers of the first 200 subscriptions) and a Juo connection whose
 * account id is that store's domain; tenant one also holds a Juo connection whose handle has no store and one without a
 * token secret name. The jobs run in this process; at the end this run's connections are set inactive, and the tenants
 * stay (119_verify_subscriptions.sql's Z1 reads their rows for an email pattern).
 *
 * Proves: no route for the adapter (404); the dry runs of both objects read and count (fetched, mapped, the statuses, the
 * event types, reasons dropped, customers without a match) and write nothing; the backfill of the events from a date
 * (stream subscription_event: events_new, the free-text reason dropped and counted, the other types skipped; the poll's
 * cursor at its start) and of the subscriptions (stream subscription: inserted, customers_unmatched, nothing missing);
 * the payment state of every case; the poll (job subscriptions_poll, stream subscriptions): the events since its cursor
 * less five minutes, the subscriptions they touched read again by id, the cursor at the run's start; overlap idempotency
 * (a second poll over the same window stores nothing twice and changes nothing); a poll not due asks nothing; the
 * reconcile marks a subscription Juo no longer returns missing in its final step, an empty full read fails
 * empty_snapshot and marks nothing; a connection whose handle has no store fails store_not_configured before any
 * request; a connection without a token secret name skipped (key_not_set, one log line each, no run) and refused by the
 * backfill; 401 wrong tenant (another store's key: key_rejected); 429 paced (held for its Retry-After and sent again: the
 * run succeeds); tenant two's store loads into tenant two only; no personal fixture text in any row of the run's tenants
 * or in a log line; nothing written to another tenant; the jobs' pool of 2 (the poll under its lock: at most 2 connections
 * at once, its work on one, no wait on its own pool; P1 the same for every poll, reconcile and backfill run). Since
 * addition 0008zq (section H) the backfill with --adapter juo: the two fake stores (two tenants) in one execution, each its
 * own dry-run line and its own run, in id order; the store without a key skipped (key_not_set) and counted, never a usage
 * error; the store-less handle failed store_not_configured; one store answering 503 while the other completes, the job's
 * failed counting it; --connection with --adapter a usage error; the job process exiting 1 when a connection failed and 2
 * on the usage error. Since addition 0009z (brief B39 Part A, section I): the billing family's backfill (billing_event:
 * chargebacks without a subscription, refunds, invoices; a return code out of its form dropped, an unknown instrument
 * counted), the subscriptions' lines as a set (canceled lines and a one-time add-on stored; a removed line marked missing
 * and back when it returns), the catalog (variants, a title with an @ and a SKU with a control character left out),
 * the observed changes (one row per change with its run, none on the first load and none on a rerun), a chargeback
 * linked to its renewal by the store's order, the event types of the subscription family, the history start
 * (subscriptions.history_start_date: empty reads all history; set, an events backfill without --from starts there,
 * before intake.start_date, and a --from before it is refused); G2 reads the new tables too.
 */
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { randomBytes } from "node:crypto";
import pg from "pg";
import { expect, verdict, poolCheck, writesOutside, PROVOKE } from "./lib.mjs";
import { juoStore, startFakeJuo } from "./juo-fake.mjs";

console.log(`verify/juo-flow.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

for (const v of ["CMA_DB_HOST", "CMA_DB_USER"]) {
  if (!process.env[v]) {
    console.error(`${v} is required (a local PostgreSQL with db/00…118; see the header)`);
    process.exit(2);
  }
}
const ADMIN = process.env.INGEST_FLOW_ADMIN_USER;
if (!ADMIN) {
  console.error("INGEST_FLOW_ADMIN_USER is required: a team login that holds cma_owner and cma_app by SET ROLE (locally, for example, auditor@local)");
  process.exit(2);
}
const RUN = randomBytes(4).toString("hex");
const KEY1 = `fixture-juo-key-${RUN}-one`;
const KEY2 = `fixture-juo-key-${RUN}-two`;
const SECRET1 = `ingest-juo-${RUN}-one-key`;
const SECRET2 = `ingest-juo-${RUN}-two-key`;
const SECRET_NOSTORE = `ingest-juo-${RUN}-nostore-key`;

// ---- Secrets as files; the fake Juo with the two stores (and none for the store-less connection's handle) ------------
const secretsDir = mkdtempSync(path.join(tmpdir(), "juo-flow-"));
writeFileSync(path.join(secretsDir, SECRET1), KEY1);
writeFileSync(path.join(secretsDir, SECRET2), KEY2);
writeFileSync(path.join(secretsDir, SECRET_NOSTORE), KEY1);
const one = juoStore({ handle: `juo-${RUN}-one`, key: KEY1, prefix: "s" });
const two = juoStore({ handle: `juo-${RUN}-two`, key: KEY2, prefix: "t" });
const fake = await startFakeJuo({ stores: [one, two] });

process.env.INGEST_SECRETS_DIR = secretsDir;
process.env.INGEST_JUO_API_BASE = fake.url;
process.env.INGEST_PACE_FACTOR = "0.01";
const logs = [];
const { setLogSink } = await import("../src/core/log.mjs");
setLogSink((line) => logs.push(line));
const { createIngestServer } = await import("../src/server.mjs");
const { runPollSubscriptions } = await import("../src/jobs/poll-subscriptions.mjs");
const { runReconcile } = await import("../src/jobs/reconcile.mjs");
const { runBackfill, runAdapterBackfill } = await import("../src/jobs/backfill.mjs");
const { UsageError, withJobLock } = await import("../src/jobs/runner.mjs");
const { clearSecretCache } = await import("../src/core/secrets.mjs");
const { closeDb, measurePool, poolRuns } = await import("../src/core/db.mjs");
const service = createIngestServer();
await new Promise((r) => service.listen(0, "127.0.0.1", r));
const BASE = `http://127.0.0.1:${service.address().port}`;

// ---- Setup as the admin login ------------------------------------------------------------------------------------------
const admin = new pg.Client({ host: process.env.CMA_DB_HOST, port: Number(process.env.CMA_DB_PORT ?? 5432), database: process.env.CMA_DB_NAME ?? "cma",
  user: ADMIN, password: process.env.CMA_DB_PASSWORD || undefined });
await admin.connect();
const q = async (text, values) => (await admin.query(text, values)).rows;
await q("set role cma_owner");
const [{ dev }] = await q("select exists (select 1 from cma.app_user where email = 'agent.two@example.com' and status = 'active') as dev");
if (!dev) {
  console.error("REFUSED: the connected database is not dev (no active agent.two@example.com); juo-flow runs in dev or a local database only");
  await admin.end();
  await new Promise((r) => service.close(r));
  await fake.close();
  rmSync(secretsDir, { recursive: true, force: true });
  process.exit(2);
}
const [{ since }] = await q("select now()::text as since");
const tenantOf = async (slug, name) => {
  const [{ t }] = await q("select cma.create_tenant($1, $2, 'Europe/London') as t", [slug, name]);
  const [{ id }] = await q("insert into cma.app_user (tenant_id, email, display_name) values ($1, $2, 'Flow admin') returning id", [t, `flow-admin-${slug}@example.invalid`]);
  await q("insert into cma.user_role (tenant_id, user_id, role_id) select $1, $2, id from cma.app_role where tenant_id = $1 and key = 'admin'", [t, id]);
  return { t, adminId: id };
};
const T1 = await tenantOf(`juo-${RUN}-one`, "Juo flow one");
const T2 = await tenantOf(`juo-${RUN}-two`, "Juo flow two");
async function asAdmin(tenant, fn) {
  await q("begin");
  await q("set local role cma_app");
  await q("select set_config('app.tenant_id', $1, true), set_config('app.user_id', $2, true), set_config('app.actor_label', 'verify:juo-flow', true)",
    [tenant.t, tenant.adminId]);
  try {
    const r = await fn();
    await q("commit");
    return r;
  } catch (e) {
    await q("rollback");
    throw e;
  }
}
const SETTINGS = (extra = {}) => JSON.stringify({ subscriptions_max_per_second: 10, subscriptions_poll_interval_minutes: 1, ...extra });
async function connection(tenant, account, secret, name) {
  return asAdmin(tenant, async () => {
    const [c] = await q("select * from cma.upsert_connection('juo', $1, $2, null, $3)", [name, account, secret]);
    await q("select cma.set_connection_kind($1, 'subscriptions')", [c.connection_id]);
    await q("select cma.set_connection_settings($1, $2::jsonb)", [c.connection_id, SETTINGS()]);
    return { id: c.connection_id, key: c.key };
  });
}
// Each tenant's store: the commerce connection, its store row of the handle, the customers of the first 200 subscriptions
async function storeOf(tenant, source) {
  const shop = await asAdmin(tenant, async () => {
    await q("select cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', null, null, 10)");
    const [c] = await q("select * from cma.upsert_connection('shopify', $1, $2, $3, null)", [`Shop ${source.handle}`, source.domain, `ingest-shopify-${RUN}-signing`]);
    await q("select cma.set_connection_kind($1, 'commerce')", [c.connection_id]);
    await q("select cma.upsert_commerce_store($1, $2, 'Flow store', 'GB', 'GBP', 'Europe/London')", [c.connection_id, source.handle]);
    return c.connection_id;
  });
  await q(`insert into cma.commerce_customer (tenant_id, connection_id, source_system, source_id)
           select $1, $2, 'shopify', x from unnest($3::text[]) x`, [tenant.t, shop, source.subscriptions.slice(0, 200).map((s) => s.customer)]);
  return shop;
}
await storeOf(T1, one);
await storeOf(T2, two);
const juo1 = await connection(T1, one.domain, SECRET1, "Juo flow one");
const juo2 = await connection(T2, two.domain, SECRET2, "Juo flow two");
const nostore = await connection(T1, `juo-${RUN}-nostore.myshopify.com`, SECRET_NOSTORE, "Juo flow without a store");
const keyless = await connection(T1, `juo-${RUN}-keyless.myshopify.com`, null, "Juo flow without a key");

const runsOf = async (conn, job = null) => q("select job, stream, status, error, counts from cma.sync_run where connection_id = $1 and ($2::text is null or job = $2) order by started_at",
  [conn, job]);
const cursor = async (conn, stream) => (await q("select cursor from cma.sync_cursor where connection_id = $1 and stream = $2", [conn, stream]))[0]?.cursor ?? null;
const counted = async (table, conn) => (await q(`select count(*)::int as n from cma.${table} where connection_id = $1`, [conn]))[0].n;
const states = async (tenant) => Object.fromEntries((await asAdmin(tenant, () => q("select source_id, payment_state from cma.subscription_payment_state_of($1)", [tenant.t])))
  .map((r) => [r.source_id.slice(0, 6), r.payment_state]));
const lastLog = (message) => logs.map((l) => JSON.parse(l)).filter((l) => l.message === message).at(-1);
const asksFor = (domain) => fake.state.requests.filter((r) => r.tenant === domain);
const usageOf = async (fn) => { try { await fn(); return "ran"; } catch (e) { return e instanceof UsageError ? "usage" : e.message; } };
const FROM = new Date(Date.now() - 30 * 24 * 60 * 60_000).toISOString().slice(0, 10);
// The fixture's events by family (verify/juo-fake.mjs): the subscription family's kept ones, its copies of billing
// events (duplicates) and its other types; the billing family
const BILLING = ["chargeback:created", "refund:created", "refund:completed", "refund:failed", "invoice:placed", "invoice:paid", "invoice:overdue",
  "invoice:payment-failed", "order:placement-failed", "order:draft-created"];
// the subscription family as Juo answers its query (category subscription): the renewal notice (category notification) is
// never requested (19 Nov 2026)
const subEvents = one.events.filter((e) => e.category === "subscription");
const notice = one.events.find((e) => e.type === "renewal:notification-sent");
const billingEvents = one.events.filter((e) => BILLING.includes(e.type));
const duplicateEvents = subEvents.filter((e) => e.type === "subscription:chargeback-created");
const otherEvents = subEvents.filter((e) => ["subscription:delivery-address-changed", "subscription:cancellation-flow/started"].includes(e.type)
  || (e.type === "subscription:updated" && !e.data?.input?.status));
const keptEvents = subEvents.filter((e) => !duplicateEvents.includes(e) && !otherEvents.includes(e));
const heldCustomers = new Set(one.subscriptions.slice(0, 200).map((x) => x.customer));
/** An object with its keys in byte order, so a comparison never depends on the order counts were met in */
const sorted = (o) => Object.fromEntries(Object.entries(o ?? {}).sort(([x], [y]) => (x < y ? -1 : x > y ? 1 : 0)));
const eventCustomersUnmatched = new Set(subEvents.map((e) => e.customerId).filter((c) => !heldCustomers.has(c))).size;

// ---- A. No route --------------------------------------------------------------------------------------------------------
const post = async (p) => (await fetch(`${BASE}${p}`, { method: "POST", headers: { "content-type": "application/json" }, body: "{}" })).status;
expect("A1 no route for the polling-only adapter: its own key and an unknown key → 404", [await post(`/juo/${juo1.key}`), await post("/juo/unknownkey00000000000000")],
  [404, 404], [200, 200]);

// ---- B. The dry runs: read and count, write nothing ----------------------------------------------------------------------
let b = await runBackfill({ connectionId: juo1.id, object: "subscription", dryRun: true });
expect("B1 the dry run of subscription: fetched, mapped, the statuses, the instrument types known, customers without a match; no --from",
  [b.fetched, b.mapped, b.unreadable, b.statuses, b.instrumentKnown, b.customersUnmatched, b.withoutCustomer],
  [230, 230, 0, { active: 224, failed: 1, paused: 1, canceled: 1, expired: 1, merged: 1, "never-subscribed": 1 }, 230, 30, 0], [0, 0, 1, {}, 0, 0, 1]);
b = await runBackfill({ connectionId: juo1.id, object: "subscription_event", from: FROM, dryRun: true });
expect("B2 the dry run of subscription_event from a date: the subscription family's event types seen and kept, duplicates, the free-text reason dropped, customers without a match",
  [b.fetched, b.mapped, b.otherType, b.duplicates, b.unreadable, b.eventTypes["subscription:renewed"], b.eventTypes["subscription:updated"],
    Object.fromEntries(Object.entries(b.kept ?? {}).sort(([x], [y]) => x.localeCompare(y))), b.reasonDropped,
    b.customersUnmatched, Math.abs(Date.parse(b.from) - Date.parse(`${FROM}T00:00:00Z`)) <= 86_400_000, Boolean(b.firstEventAt)],
  [subEvents.length, keptEvents.length, otherEvents.length, duplicateEvents.length, 0, 201, 2,
    { billing_date_moved: 1, canceled: 1, created: 1, discount_changed: 2, interval_changed: 1, lines_changed: 2, merged_to: 1, migrated: 1, paused: 2,
      payment_method_changed: 1, purchased: 1, reactivated: 1, renew_failed: 3, renewed: 201, resumed: 1, skipped: 1, status_changed: 1,
      update_failed: 1 }, 1, eventCustomersUnmatched, true, true],
  [0, 0, 0, 0, 1, 0, 0, {}, 0, 0, false, false]);
b = await runBackfill({ connectionId: juo1.id, object: "billing_event", from: FROM, dryRun: true });
expect("B2b the dry run of billing_event: the kinds, the return codes, one dropped, the instrument types (an unknown one by its name), those naming a subscription",
  [b.fetched, b.mapped, b.unreadable, sorted(b.billingKinds), sorted(b.returnCodes), b.returnCodeDropped, sorted(b.instrumentTypes), b.instrumentUnknown, b.withSubscription],
  [billingEvents.length, billingEvents.length, 0, sorted({ chargeback: 3, refund_created: 1, refund_completed: 1, refund_failed: 1, invoice_placed: 2, invoice_paid: 1,
    invoice_payment_failed: 1, invoice_overdue: 1, order_placement_failed: 1, order_draft_created: 1 }), sorted({ MD06: 1, fraudulent: 1 }), 1,
  sorted({ sepa_direct_debit: 1, card: 1, Klarna: 1 }), 1, 7], [0, 0, 1, {}, {}, 0, {}, 0, 0]);
expect("B3 …and both wrote nothing: no run, no subscription, no event, no cursor",
  [(await runsOf(juo1.id)).length, await counted("subscription", juo1.id), await counted("subscription_event", juo1.id), await cursor(juo1.id, "juo:events")],
  [0, 0, 0, null], [1, 230, 1, {}]);

// ---- C. The backfills: the events from a date, then the subscriptions -----------------------------------------------------
const t0 = Date.now();
b = await runBackfill({ connectionId: juo1.id, object: "subscription_event", from: FROM });
let run = (await runsOf(juo1.id, "backfill")).at(-1);
expect("C1 the backfill of the events: stream subscription_event, the kept ones stored, the other types and the duplicate skipped, the free-text reason dropped and counted",
  [b.failed, run.stream, run.status, run.counts.fetched, run.counts.events_new, run.counts.skipped, run.counts.duplicate_skipped, run.counts.reason_dropped,
    await counted("subscription_event", juo1.id), await counted("billing_event", juo1.id)],
  [0, "subscription_event", "succeeded", subEvents.length, keptEvents.length, otherEvents.length + duplicateEvents.length, duplicateEvents.length, 1,
    keptEvents.length, 0],
  [1, null, "failed", 0, 0, 0, 0, 0, 0, 1]);
expect("C2 …its cursor done; the poll's cursor at the backfill's start",
  [(await cursor(juo1.id, "backfill:subscription_event"))?.done, (await cursor(juo1.id, "juo:events"))?.at >= t0],
  [true, true], [false, false]);
b = await runBackfill({ connectionId: juo1.id, object: "subscription" });
run = (await runsOf(juo1.id, "backfill")).at(-1);
expect("C3 the backfill of the subscriptions: stream subscription, 230 inserted, 30 customers without a match among the store's, nothing missing; their lines (canceled ones and add-ons included) inserted, no change observed on a first load",
  [b.failed, run.stream, run.status, run.counts.fetched, run.counts.inserted, run.counts.upserted, run.counts.customers_unmatched, run.counts.missing_now,
    Number.isInteger(run.counts.slice_max_ms), run.counts.lines_new, run.counts.lines_missing, run.counts.changes_observed, run.counts.instrument_unknown,
    await counted("subscription_line", juo1.id), await counted("subscription_change", juo1.id)],
  [0, "subscription", "succeeded", 230, 230, 230, 30, 0, true, 464, 0, 0, 0, 464, 0], [1, null, "failed", 0, 0, 0, 0, 1, false, 0, 1, 1, 1, 0, 1]);
let st = await states(T1);
expect("C4 the payment state of each case: in_retry, paid after a renewal of the failed cycle, failed, paused, canceled (canceled and expired); merged and never-subscribed left out",
  [st["s-0201"], st["s-0202"], st["s-0203"], st["s-0204"], st["s-0205"], st["s-0206"], st["s-0207"], st["s-0208"], st["s-0001"], st["s-0209"], st["s-0210"],
    Object.values(st).filter((v) => v === "paid").length, Object.keys(st).length],
  ["in_retry", "paid", "failed", "paused", "canceled", "canceled", undefined, undefined, "paid", "paid", "paid", 223, 228],
  ["paid", "in_retry", "paid", "paid", "paid", "paid", "paid", "paid", "in_retry", null, null, 0, 230]);
const sub204 = (await q("select paused_at, status, payment_instrument_type, amount_per_cycle::text as amount, billing_interval, currency from cma.subscription where connection_id = $1 and source_id = $2",
  [juo1.id, one.subscriptions[203].id]))[0];
const pausedEvent = one.events.find((e) => e.type === "subscription:paused" && e.subscriptionId === one.subscriptions[203].id);
expect("C5 a paused subscription's pause from its event; its instrument's type, amount per cycle, interval and currency",
  [sub204?.paused_at?.toISOString(), sub204?.status, sub204?.payment_instrument_type, sub204?.amount, sub204?.billing_interval, sub204?.currency],
  [pausedEvent.occurredAt, "paused", "paypal", "24.95", "month", "GBP"], [null, "active", null, null, null, null]);

// ---- D. The poll: the events since its cursor less five minutes, the subscriptions they touched ------------------------------
const s1 = one.subscriptions[0];
one.events.push({ id: "se-900001-0000-4000-8000-000000000000", stream: "activity", category: "subscription", severity: "problem",
  occurredAt: new Date().toISOString(), owner: { entity: "Subscription", id: s1.id }, actor: { type: "system", id: null, name: null, source: null },
  subscriptionId: s1.id, customerId: s1.customer, type: "subscription:renew-failed", payloadFormat: "legacy",
  data: { reason: "billing-attempt-failed", attempt: 1, errorCode: "CARD_DECLINED", cycleIndex: 7, errorMessage: "Invented Person 0001 card declined" } });
Object.assign(s1, { updatedAt: new Date().toISOString(), currentCycle: 7 });
fake.state.requests.length = 0;
const pollStart = Date.now();
let total = await runPollSubscriptions({ connectionId: juo1.id });
run = (await runsOf(juo1.id, "subscriptions_poll")).at(-1);
const evAsk = asksFor(one.domain).find((r) => r.path === "/admin/v1/events");
const subAsk = asksFor(one.domain).find((r) => r.path === "/admin/v1/subscriptions");
expect("D1 the poll: one run (subscriptions_poll, stream subscriptions) succeeded; the new failed renewal stored, its subscription read again by id and updated",
  [total.failed, run.stream, run.status, run.counts.events_new, run.counts.updated, run.counts.inserted, subAsk?.params?.query?.includes(s1.id),
    (await states(T1))["s-0001"]],
  [0, "subscriptions", "succeeded", 1, 1, 0, true, "in_retry"], [1, null, "failed", 0, 0, 1, false, "paid"]);
const backfillStart = (await q("select started_at from cma.sync_run where connection_id = $1 and job = 'backfill' and stream = 'subscription_event'", [juo1.id]))[0].started_at;
expect("D2 …it asked for the events after its cursor less five minutes (category subscription, oldest first); the cursor moved to the run's start",
  [evAsk?.params?.sort, Math.abs(Date.parse(/occurredAt:>'([^']+)'/.exec(evAsk?.params?.query ?? "")?.[1]) - (backfillStart.getTime() - 5 * 60_000)) < 60_000,
    (await cursor(juo1.id, "juo:events"))?.at >= pollStart, (await cursor(juo1.id, "juo:cadence"))?.at >= pollStart],
  ["occurredAt:asc,id:asc", true, true, true], [null, false, false, false]);
const rowsBefore = [await counted("subscription", juo1.id), await counted("subscription_event", juo1.id)];
total = await runPollSubscriptions({ connectionId: juo1.id });
run = (await runsOf(juo1.id, "subscriptions_poll")).at(-1);
expect("D3 overlap idempotency: a second poll reads the same failed renewal again (five minutes' overlap), stores nothing twice and changes nothing",
  [total.failed, run.counts.fetched >= 2, run.counts.events_new, run.counts.updated, run.counts.inserted, run.counts.unchanged,
    [await counted("subscription", juo1.id), await counted("subscription_event", juo1.id)]],
  [0, true, 0, 0, 0, 1, rowsBefore], [1, false, 1, 1, 1, 0, [0, 0]]);
await asAdmin(T1, () => q("select cma.set_connection_settings($1, $2::jsonb)", [juo1.id, SETTINGS({ subscriptions_poll_interval_minutes: 60 })]));
fake.state.requests.length = 0;
total = await runPollSubscriptions({ connectionId: juo1.id });
expect("D4 a poll not due (60 minutes): no request, no run", [total.notDue, fake.state.requests.length, (await runsOf(juo1.id, "subscriptions_poll")).length],
  [1, 0, 2], [0, 2, 3]);
await asAdmin(T1, () => q("select cma.set_connection_settings($1, $2::jsonb)", [juo1.id, SETTINGS()]));
// The jobs' pool of 2 (docs/ingest/deploy.sh; Gemini audit of 28 October 2026, FIND-01): the poll measured as main measures
// it, under its advisory lock (a verify-… lock name, so a dev job of the same name is never held up), reads the overlap again
const locked = await measurePool("poll-subscriptions", () => withJobLock("verify-poll-subscriptions", () => runPollSubscriptions({ connectionId: juo1.id })));
const polled = poolRuns().at(-1);
run = (await runsOf(juo1.id, "subscriptions_poll")).at(-1);
expect(`D5 the poll under its lock keeps to the jobs' pool of 2: at most 2 connections at once, its work on one, no wait on its own pool (peak ${polled.peak}, work ${polled.work})`,
  [locked.ran, locked.result?.failed, (await runsOf(juo1.id, "subscriptions_poll")).length, run.status, run.counts.fetched >= 1, polled.job,
    polled.peak >= 1 && polled.peak <= 2, polled.work <= 1, polled.selfWaits],
  [true, 0, 3, "succeeded", true, "poll-subscriptions", true, true, 0], [false, 1, 2, "failed", false, "poll-subscriptions", false, false, 1]);

// ---- E. The reconcile: missing marked; an empty read fails ----------------------------------------------------------------------
const gone = one.subscriptions.pop();
total = await runReconcile({ connectionId: juo1.id, object: "subscription" });
run = (await runsOf(juo1.id, "reconcile")).at(-1);
const goneRow = (await q("select source_deleted_at is not null as missing from cma.subscription where connection_id = $1 and source_id = $2", [juo1.id, gone.id]))[0];
expect("E1 reconcile marks missing: the subscription Juo no longer returns gets source_deleted_at in the final step; the rest unchanged",
  [total.failed, run.stream, run.status, run.counts.fetched, run.counts.missing_now, run.counts.unchanged, goneRow?.missing, lastLog("reconcile: subscription full read")?.slices],
  [0, "subscription", "succeeded", 229, 1, 229, true, 1], [1, null, "failed", 230, 0, 0, false, 0]);
const kept = one.subscriptions.splice(0, one.subscriptions.length);
total = await runReconcile({ connectionId: juo1.id, object: "subscription" });
run = (await runsOf(juo1.id, "reconcile")).at(-1);
expect("E2 empty_snapshot: a full read that returns no subscription fails, nothing marked missing",
  [total.failed, run.status, run.error, (await q("select count(*)::int as n from cma.subscription where connection_id = $1 and source_deleted_at is not null", [juo1.id]))[0].n,
    lastLog("juo full read returned no subscription: nothing marked missing")?.code],
  [1, "failed", "empty_snapshot", 1, "empty_snapshot"], [0, "succeeded", null, 230, undefined]);
one.subscriptions.push(...kept, gone);
total = await runReconcile({ connectionId: juo1.id, object: "subscription" });
run = (await runsOf(juo1.id, "reconcile")).at(-1);
expect("E3 the next full read brings the missing subscription back", [total.failed, run.counts.updated, run.counts.missing_now,
  (await q("select count(*)::int as n from cma.subscription where connection_id = $1 and source_deleted_at is not null", [juo1.id]))[0].n], [0, 1, 0, 0], [1, 0, 1, 1]);

// ---- F. The refusals: no store, no key, another store's key; a 429 -------------------------------------------------------------
fake.state.requests.length = 0;
total = await runPollSubscriptions({ connectionId: nostore.id });
run = (await runsOf(nostore.id)).at(-1);
expect("F1 store_not_configured: a connection whose handle has no store fails before any request, logged",
  [total.failed, run?.status, run?.error, fake.state.requests.length, await counted("subscription", nostore.id),
    lastLog("juo store not configured: no commerce store of the tenant has the handle of the connection's account id")?.code],
  [1, "failed", "store_not_configured", 0, 0, "store_not_configured"], [0, "succeeded", null, 1, 1, undefined]);
const pollSkip = await runPollSubscriptions({ connectionId: keyless.id });
const recSkip = await runReconcile({ connectionId: keyless.id });
expect("F2 a connection without a token secret name: the poll and the reconcile skip it (key_not_set, one line each), no run; the backfill refuses",
  [pollSkip.notServed, recSkip.notServed, logs.filter((l) => JSON.parse(l).connection === keyless.id && JSON.parse(l).code === "key_not_set").length,
    (await runsOf(keyless.id)).length, await usageOf(() => runBackfill({ connectionId: keyless.id, object: "subscription" }))],
  [1, 1, 2, 0, "usage"], [0, 0, 0, 1, "ran"]);
writeFileSync(path.join(secretsDir, SECRET2), KEY1);
clearSecretCache();
total = await runPollSubscriptions({ connectionId: juo2.id });
run = (await runsOf(juo2.id)).at(-1);
expect("F3 401 wrong tenant: tenant two's connection with the other store's key fails key_rejected; nothing written",
  [total.failed, run?.status, run?.error, await counted("subscription", juo2.id)], [1, "failed", "key_rejected", 0], [0, "succeeded", null, 1]);
writeFileSync(path.join(secretsDir, SECRET2), KEY2);
clearSecretCache();
fake.state.requests.length = 0;
fake.state.fail429 = 1;
fake.state.retryAfter = "3";
total = await runPollSubscriptions({ connectionId: juo1.id });
run = (await runsOf(juo1.id, "subscriptions_poll")).at(-1);
const asks = fake.state.requests;
expect("F4 429 paced: the request held for its Retry-After (3 s × the pace factor) and sent again; the run succeeds, the hold logged",
  [total.failed, run.status, asks.length >= 2, asks.length >= 2 && asks[1].at - asks[0].at >= 30 - 2, asks[0]?.params?.query === asks[1]?.params?.query,
    lastLog("juo rate limited")?.retried],
  [0, "succeeded", true, true, true, true], [1, "failed", false, false, false, false]);

// ---- I. Addition 0009z: billing events, lines, the catalog, observed changes, the history start ------------------------------------
b = await runBackfill({ connectionId: juo1.id, object: "billing_event", from: FROM });
run = (await runsOf(juo1.id, "backfill")).at(-1);
expect("I1 the billing family's backfill: stream billing_event, every billing event stored (append-only), a return code out of its form dropped, an unknown instrument counted; its cursor done",
  [b.failed, run.stream, run.status, run.counts.fetched, run.counts.billing_events_new, run.counts.events_new, run.counts.return_code_dropped,
    run.counts.instrument_unknown, await counted("billing_event", juo1.id), (await cursor(juo1.id, "backfill:billing_event"))?.done],
  [0, "billing_event", "succeeded", billingEvents.length, billingEvents.length, 0, 1, 1, billingEvents.length, true],
  [1, null, "failed", 0, 0, 1, 0, 0, 0, false]);
const cb = (await q(`select b.kind, b.subscription_source_id, b.order_source_id, b.return_code, b.instrument_type, b.amount::text as amount, b.currency,
    e.subscription_source_id as renewal_subscription
  from cma.billing_event b
  left join cma.subscription_event e on e.tenant_id = b.tenant_id and e.connection_id = b.connection_id and e.event_type = 'renewed'
                                    and e.order_source_id = b.order_source_id
  where b.connection_id = $1 and b.kind = 'chargeback' and b.return_code = 'MD06'`, [juo1.id]))[0];
expect("I2 a chargeback without a subscription linked to its renewal by the store's order (subscription_event.order_source_id); code, instrument, amount",
  [cb?.subscription_source_id, cb?.renewal_subscription, cb?.return_code, cb?.instrument_type, cb?.amount, cb?.currency],
  [null, one.subscriptions[4].id, "MD06", "sepa_direct_debit", "24.95", "GBP"], ["x", null, null, null, null, null]);
const inv = await q(`select kind, subscription_source_id, renewal_source_id is not null as renewal, owner_source_id, attempt, error_code
  from cma.billing_event where connection_id = $1 and kind like 'invoice%' order by occurred_at, kind`, [juo1.id]);
expect("I3 invoice renewals: placed and paid pair by their order (owner), the subscription named, a failed payment's attempt and code",
  [inv.length, inv.filter((x) => x.subscription_source_id === one.subscriptions[8].id).map((x) => x.kind).sort(),
    new Set(inv.filter((x) => x.subscription_source_id === one.subscriptions[8].id).map((x) => x.owner_source_id)).size,
    inv.find((x) => x.kind === "invoice_payment_failed")?.attempt, inv.find((x) => x.kind === "invoice_payment_failed")?.error_code,
    inv.filter((x) => x.kind === "invoice_placed").every((x) => x.renewal)],
  [5, ["invoice_paid", "invoice_placed"], 1, 2, "INSUFFICIENT_FUNDS", true], [0, [], 2, null, null, false]);
const s50 = await q(`select l.source_id, l.quantity, l.amount_per_cycle::text as amount, l.recurring_cycle_limit, l.canceled_at is not null as canceled,
    l.variant_source_id, l.source_deleted_at is null as present
  from cma.subscription_line l where l.connection_id = $1 and l.subscription_source_id = $2 order by l.source_id collate "C"`, [juo1.id, one.subscriptions[49].id]);
const row50 = (await q("select source_number, line_count, discount_count, min_cycles, amount_per_cycle::text as amount from cma.subscription where connection_id = $1 and source_id = $2",
  [juo1.id, one.subscriptions[49].id]))[0];
const row213 = (await q("select min_cycles, discount_count from cma.subscription where connection_id = $1 and source_id = $2", [juo1.id, one.subscriptions[212].id]))[0];
const row214 = (await q("select discount_count from cma.subscription where connection_id = $1 and source_id = $2", [juo1.id, one.subscriptions[213].id]))[0];
expect("I4 the lines as stored: a recurring line, a canceled one, a one-time add-on; the subscription's number, current lines, discounts and cycle bound",
  [s50.map((l) => [l.source_id, l.quantity, l.amount, l.recurring_cycle_limit, l.canceled, l.variant_source_id, l.present]), row50, row213, row214],
  [[["item-0050", 1, "24.95", null, false, "41000000001", true], ["item-0050-b", 1, "5.00", null, true, "41000000002", true],
    ["item-0050-c", 1, "49.00", 1, false, "41000000003", true]],
  { source_number: "#1050", line_count: 2, discount_count: 0, min_cycles: null, amount: "73.95" }, { min_cycles: 12, discount_count: 0 }, { discount_count: 1 }],
  [[], {}, {}, {}]);
b = await runBackfill({ connectionId: juo1.id, object: "subscription_product" });
run = (await runsOf(juo1.id, "backfill")).at(-1);
const v2 = (await q("select product_title, variant_title, sku, product_status from cma.subscription_product_variant where connection_id = $1 and variant_source_id = '41000000002'",
  [juo1.id]))[0];
expect("I5 the catalog: stream subscription_product, 153 variants inserted in one set; a title with an @ and a SKU with a control character left out and counted; the status in lower case",
  [b.failed, run.stream, run.status, run.counts.fetched, run.counts.variants_new, run.counts.catalog_text_dropped, await counted("subscription_product_variant", juo1.id), v2],
  [0, "subscription_product", "succeeded", 153, 153, 2, 153, { product_title: "Accessory (catalog fixture)", variant_title: null, sku: null, product_status: "active" }],
  [1, null, "failed", 0, 0, 0, 0, {}]);
// The observed changes: three subscriptions change at Juo, the reconcile reads them
const later = new Date(Date.now() + 1000).toISOString();
const s3 = one.subscriptions[2];
const s4 = one.subscriptions[3];
const s5 = one.subscriptions[4];
const s5b = s5.items.find((it) => it.id.endsWith("-b"));
s3.items[0] = { ...s3.items[0], totalPrice: 34.95 };
s4.items[0] = { ...s4.items[0], quantity: 2 };
s5.items = s5.items.filter((it) => it !== s5b);
for (const x of [s3, s4, s5]) x.updatedAt = later;
total = await runReconcile({ connectionId: juo1.id, object: "subscription" });
run = (await runsOf(juo1.id, "reconcile")).at(-1);
const runRow = (await q("select id from cma.sync_run where connection_id = $1 and job = 'reconcile' order by started_at desc limit 1", [juo1.id]))[0];
const changes = await q(`select subscription_source_id, field, old_value, new_value, run_id from cma.subscription_change where connection_id = $1
  order by subscription_source_id collate "C", field collate "C"`, [juo1.id]);
expect("I6 observed changes: an amount, a recurring quantity, and a removed line (line count, amount, recurring quantity), one row each with the reconcile's run; the line marked missing",
  [total.failed, run.counts.changes_observed, run.counts.lines_missing, changes.map((c) => [c.subscription_source_id.slice(0, 6), c.field, c.old_value, c.new_value]),
    changes.every((c) => c.run_id === runRow.id),
    (await q("select source_deleted_at is not null as missing from cma.subscription_line where connection_id = $1 and source_id = $2", [juo1.id, s5b.id]))[0]?.missing],
  [0, 5, 1, [["s-0003", "amount_per_cycle", "29.95", "39.95"], ["s-0004", "recurring_quantity", "1", "2"], ["s-0005", "amount_per_cycle", "29.95", "24.95"],
    ["s-0005", "line_count", "2", "1"], ["s-0005", "recurring_quantity", "2", "1"]], true, true],
  [1, 0, 0, [], false, false]);
total = await runReconcile({ connectionId: juo1.id, object: "subscription" });
run = (await runsOf(juo1.id, "reconcile")).at(-1);
expect("I7 a rerun observes nothing: no change, no line missing, every subscription unchanged",
  [total.failed, run.counts.changes_observed, run.counts.lines_missing, run.counts.lines_new, run.counts.unchanged, await counted("subscription_change", juo1.id)],
  [0, 0, 0, 0, 230, 5], [1, 1, 1, 1, 0, 0]);
s5.items.push(s5b);
s5.updatedAt = new Date(Date.now() + 2000).toISOString();
total = await runReconcile({ connectionId: juo1.id, object: "subscription" });
run = (await runsOf(juo1.id, "reconcile")).at(-1);
expect("I8 the removed line back when it returns: present again, its three changes observed back",
  [total.failed, run.counts.changes_observed,
    (await q("select source_deleted_at is null as present from cma.subscription_line where connection_id = $1 and source_id = $2", [juo1.id, s5b.id]))[0]?.present,
    await counted("subscription_change", juo1.id)],
  [0, 3, true, 8], [1, 0, false, 5]);
// The history start: empty reads all history; set, it is the start without --from and a --from before it is refused
const errOf = async (fn) => { try { const r = await fn(); return r?.error ?? (r?.failed ? "failed" : "ok"); } catch (e) { return e.code ?? e.message; } };
fake.state.requests.length = 0;
b = await runBackfill({ connectionId: juo1.id, object: "subscription_event" });
run = (await runsOf(juo1.id, "backfill")).at(-1);
const allAsk = fake.state.requests.find((r) => r.path === "/admin/v1/events");
expect("I9 subscriptions.history_start_date empty: the events backfill without --from reads all of the app's history (from 1 January 2000), no start on the run, nothing stored twice",
  [b.failed, run.status, run.counts.fetched, run.counts.events_new, /occurredAt:>='2000-01-01T00:00:00.000Z'/.test(allAsk?.params?.query ?? ""),
    (await q("select from_at from cma.sync_run where connection_id = $1 and job = 'backfill' order by started_at desc limit 1", [juo1.id]))[0].from_at],
  [0, "succeeded", one.events.filter((e) => e.category === "subscription").length, 0, true, null], [1, "failed", 0, 1, false, "x"]);
await asAdmin(T1, () => q("select cma.set_tenant_setting('subscriptions.history_start_date', ' 2020-01-01 ')"));
const intake = (await asAdmin(T1, () => q("select cma.setting_of($1, 'intake.start_date') as v", [T1.t])))[0].v;
fake.state.requests.length = 0;
b = await runBackfill({ connectionId: juo1.id, object: "billing_event" });
run = (await runsOf(juo1.id, "backfill")).at(-1);
const setAsk = fake.state.requests.find((r) => r.path === "/admin/v1/events");
expect("I10 subscriptions.history_start_date set (2020-01-01, before intake.start_date): the backfill without --from starts there (the tenant's midnight), before intake.start_date",
  [b.failed, run.status, (await q("select from_at from cma.sync_run where connection_id = $1 and job = 'backfill' order by started_at desc limit 1", [juo1.id]))[0].from_at?.toISOString(),
    /occurredAt:>='2020-01-01T00:00:00.000Z'/.test(setAsk?.params?.query ?? ""), "2020-01-01" < intake, run.counts.billing_events_new],
  [0, "succeeded", "2020-01-01T00:00:00.000Z", true, true, 0], [1, "failed", null, false, false, 1]);
const before = await errOf(() => runBackfill({ connectionId: juo1.id, object: "subscription_event", from: "2019-06-01" }));
run = (await runsOf(juo1.id, "backfill")).at(-1);
const dryBefore = await errOf(() => runBackfill({ connectionId: juo1.id, object: "billing_event", from: "2019-06-01", dryRun: true }));
const after = await errOf(() => runBackfill({ connectionId: juo1.id, object: "subscription_event", from: "2020-02-01" }));
expect("I11 a --from before the history start refused (from_before_history_start: the run fails, the dry run too); one after it, still before intake.start_date, runs",
  [before, run.status, run.error, dryBefore, after], ["from_before_history_start", "failed", "from_before_history_start", "from_before_history_start", "ok"],
  ["ok", "succeeded", null, "ok", "failed"]);
await asAdmin(T1, () => q("select cma.set_tenant_setting('subscriptions.history_start_date', '')"));

// ---- G. Tenant two; nothing personal; nothing elsewhere -----------------------------------------------------------------------
b = await runBackfill({ connectionId: juo2.id, object: "subscription" });
expect("G1 tenant two's store loads into tenant two only; tenant one's subscriptions as they were",
  [b.failed, await counted("subscription", juo2.id), (await q("select count(*)::int as n from cma.subscription where tenant_id = $1", [T2.t]))[0].n,
    (await q("select count(*)::int as n from cma.subscription where tenant_id = $1", [T1.t]))[0].n,
    (await q("select count(*)::int as n from cma.subscription where tenant_id = $1 and source_id like 't-%'", [T1.t]))[0].n],
  [0, 230, 230, 230, 0], [1, 0, 0, 0, 1]);
// (the card's digits are looked for by their field and brand: four digits alone can occur in any uuid)
const PERSONAL = ["Invented", "example.invalid", "Fixture Street", "Testtown", "FX1 1XX", "+44 20", "lastDigits", "visa", "****", "asked for a call", "Too expensive",
  "insufficient funds", "card declined", "consumerName", "deliveryAddress", "billingAddress", "Service plan", "FIXTURE10", "Ten off", "Return received", "disputed",
  "No stock", "Variant missing", "wants to leave", "Accessory for", "Accessory (fixture)", "Installation (fixture)", "_ordered_by", "customAttributes"];
const dbText = JSON.stringify(await q(`select row_to_json(x)::text as r from cma.subscription x where tenant_id = any($1::uuid[])
  union all select row_to_json(x)::text from cma.subscription_event x where tenant_id = any($1::uuid[])
  union all select row_to_json(x)::text from cma.subscription_line x where tenant_id = any($1::uuid[])
  union all select row_to_json(x)::text from cma.subscription_product_variant x where tenant_id = any($1::uuid[])
  union all select row_to_json(x)::text from cma.billing_event x where tenant_id = any($1::uuid[])
  union all select row_to_json(x)::text from cma.subscription_change x where tenant_id = any($1::uuid[])
  union all select row_to_json(x)::text from cma.sync_run x where tenant_id = any($1::uuid[])
  union all select row_to_json(x)::text from cma.sync_cursor x where tenant_id = any($1::uuid[])
  union all select row_to_json(x)::text from cma.audit_log x where tenant_id = any($1::uuid[]) and table_name in ('subscription', 'subscription_event', 'sync_run', 'sync_cursor',
    'subscription_line', 'subscription_product_variant', 'billing_event', 'subscription_change')`,
  [[T1.t, T2.t]]));
expect("G2 no name, address, email, phone, payment detail, message or free-text reason in any row of the run's tenants (audit log included)",
  PERSONAL.filter((p) => dbText.includes(p)), [], PERSONAL);
const logText = logs.join("\n");
expect("G2b Juo's renewal notice never read (19 Nov 2026): the fake saw this run's queries, and none asked for it or its category; no event row holds it, no log line names its type",
  [fake.state.queriesSeen.length > 0, fake.state.queriesSeen.some((x) => /notification/.test(x)),
    (await q("select count(*)::int as n from cma.subscription_event where tenant_id = any($1::uuid[]) and (source_id = $2 or event_type = 'renewal_notice')",
      [[T1.t, T2.t], notice.id]))[0].n, logText.includes("renewal:notification-sent")],
  [true, false, 0, false], [false, true, 1, true]);
expect("G3 the logs hold no key and no value: connection ids, counts, codes and Juo's type names",
  [...PERSONAL, KEY1, KEY2, one.subscriptions[0].customer, "7100000"].filter((v) => logText.includes(v)), [], ["x"]);
expect("G4 every request carried its store's id and a key, in headers; none for the store-less handle",
  [fake.state.requests.every((r) => r.tenant && !r.keyInUrl), asksFor(`juo-${RUN}-nostore.myshopify.com`).length], [true, 0], [false, 1]);
expect("G5 nothing written to another tenant by this run's logins", await writesOutside(q, { tenants: [T1.t, T2.t], since, logins: [ADMIN, process.env.CMA_DB_USER] }), [], ["x"]);

// ---- H. --adapter juo: every served store in one execution (addition 0008zq) --------------------------------------------------
// The walk serves every active Juo connection of the database, so the checks read only this run's four
const mine = new Set([juo1.id, juo2.id, nostore.id, keyless.id]);
const ownResults = (r) => r.results.filter((x) => mine.has(x.connection));
const byId = (ids) => [...ids].sort();
logs.length = 0;
const runsBefore = [(await runsOf(juo1.id, "backfill")).length, (await runsOf(juo2.id, "backfill")).length];
let walk = await runAdapterBackfill({ adapter: "juo", objects: "subscription", dryRun: true });
let own = ownResults(walk);
const dryLines = logs.map((l) => JSON.parse(l)).filter((l) => l.message === "backfill dry run" && mine.has(l.connection));
expect("H1 the dry run with --adapter juo: one `backfill dry run` line per store with its counts, in id order, nothing written",
  [dryLines.map((l) => l.connection), dryLines.map((l) => [l.object, l.fetched, l.mapped]), own.map((x) => x.connection),
    (await runsOf(juo1.id, "backfill")).length, (await runsOf(juo2.id, "backfill")).length],
  [byId([juo1.id, juo2.id]), [["subscription", 230, 230], ["subscription", 230, 230]], byId(mine), ...runsBefore],
  [[], [], [], runsBefore[0] + 1, runsBefore[1] + 1]);
expect("H2 the store without a key is skipped (key_not_set, one log line) and counted, never a usage error; the store-less handle fails store_not_configured",
  [own.find((x) => x.connection === keyless.id), own.find((x) => x.connection === nostore.id)?.error, own.find((x) => x.connection === nostore.id)?.failed,
    logs.filter((l) => JSON.parse(l).message === "backfill: connection skipped" && JSON.parse(l).connection === keyless.id && JSON.parse(l).code === "key_not_set").length,
    walk.skipped >= 1, walk.failed >= 1],
  [{ connection: keyless.id, skipped: "key_not_set", failed: 0 }, "store_not_configured", 1, 1, true, true],
  [null, null, 0, 0, false, false]);
// One store answers 503 while the other completes: each its own run, the failure counted, the walk goes on in id order
fake.state.failTenant = two.domain;
logs.length = 0;
walk = await runAdapterBackfill({ adapter: "juo", objects: "subscription" });
own = ownResults(walk);
fake.state.failTenant = null;
const run1 = (await runsOf(juo1.id, "backfill")).at(-1);
const run2 = (await runsOf(juo2.id, "backfill")).at(-1);
expect("H3 one store answering 503 while the other completes: store one's run succeeded with its counts, store two's failed http_503, both in the walk's results in id order",
  [run1.stream, run1.status, run1.counts.fetched, run2.stream, run2.status, run2.error,
    own.filter((x) => x.object === "subscription").map((x) => [x.connection, x.error ?? null, x.failed]).sort((a, b) => (a[0] < b[0] ? -1 : 1))],
  ["subscription", "succeeded", 230, "subscription", "failed", "http_503",
    [[juo1.id, null, 0], [juo2.id, "http_503", 1], [nostore.id, "store_not_configured", 1]].sort((a, b) => (a[0] < b[0] ? -1 : 1))],
  [null, "failed", 0, null, "succeeded", null, []]);
expect("H4 the walk's totals: the connections of the adapter, the served ones, the skipped and the failed (store two and the store-less handle)",
  [walk.adapter, walk.connections >= 4, walk.served === walk.connections - walk.skipped, walk.skipped >= 1, walk.failed >= 2, walk.results.length >= 4],
  ["juo", true, true, true, true, true], ["x", false, false, false, false, false]);
expect("H5 the refusals before any walk: an unknown adapter, --dry-run with two objects, an object the adapter has not",
  [await usageOf(() => runAdapterBackfill({ adapter: "nosuch", objects: "subscription" })),
    await usageOf(() => runAdapterBackfill({ adapter: "juo", objects: "subscription,subscription_event", dryRun: true })),
    await usageOf(() => runAdapterBackfill({ adapter: "juo", objects: "device" })),
    await usageOf(() => runAdapterBackfill({ adapter: "juo", objects: "subscription", from: FROM }))],
  ["usage", "usage", "usage", "usage"], ["ran", "ran", "ran", "ran"]);
// The job as a process: the exit code is 1 when any connection failed (the store-less handle) and 2 on a usage error
const job = async (...args) => {
  const r = await promisify(execFile)(process.execPath, ["jobs/backfill.mjs", ...args], { cwd: path.join(path.dirname(new URL(import.meta.url).pathname), ".."),
    env: { ...process.env, CMA_DB_POOL_MAX: process.env.CMA_DB_POOL_MAX ?? "2" } }).then(() => ({ code: 0, out: "" }), (e) => ({ code: e.code, out: String(e.stdout ?? "") + String(e.stderr ?? "") }));
  return r;
};
const exit1 = await job("--adapter", "juo", "--object", "subscription", "--dry-run");
const exit2 = await job("--adapter", "juo", "--connection", juo1.id, "--object", "subscription", "--dry-run");
expect("H6 the job process: exit 1 when a connection of the walk failed (the store-less handle), its finished line with the per-connection results",
  [exit1.code, /"message":"backfill finished"/.test(exit1.out), /"results":\[/.test(exit1.out), /store_not_configured/.test(exit1.out)], [1, true, true, true], [0, false, false, false]);
expect("H7 the job process: --connection with --adapter is a usage error (exit 2, nothing run)",
  [exit2.code, /"code":"usage"/.test(exit2.out), /exclude each other/.test(exit2.out)], [2, true, true], [0, false, false]);
expect("H8 the logs of the walk hold no key and no value", [KEY1, KEY2, one.subscriptions[0].customer].filter((v) => logs.join("\n").includes(v) || exit1.out.includes(v)), [], ["x"]);

// This run's connections stop being served (a later run's unfiltered jobs leave them alone); the tenants stay
for (const [tenant, c] of [[T1, juo1.id], [T1, nostore.id], [T1, keyless.id], [T2, juo2.id]]) await asAdmin(tenant, () => q("select cma.set_connection_status($1, 'inactive')", [c]));
await admin.end();
await new Promise((r) => service.close(r));
await fake.close();
await closeDb();
rmSync(secretsDir, { recursive: true, force: true });
await poolCheck();
verdict();
