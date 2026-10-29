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
 * at once, its work on one, no wait on its own pool; P1 the same for every poll, reconcile and backfill run).
 */
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
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
const { runBackfill } = await import("../src/jobs/backfill.mjs");
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
const keptEvents = one.events.filter((e) => ["subscription:renewed", "subscription:renew-failed", "subscription:cancelled", "subscription:paused",
  "subscription:resumed", "subscription:reactivated"].includes(e.type) || (e.type === "subscription:updated" && e.data?.input?.status));

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
expect("B2 the dry run of subscription_event from a date: the event types seen and kept, the free-text reason dropped, customers without a match",
  [b.fetched, b.mapped, b.otherType, b.unreadable, b.eventTypes["subscription:renewed"], b.eventTypes["subscription:updated"],
    Object.fromEntries(Object.entries(b.kept ?? {}).sort(([x], [y]) => x.localeCompare(y))), b.reasonDropped,
    b.customersUnmatched, Math.abs(Date.parse(b.from) - Date.parse(`${FROM}T00:00:00Z`)) <= 86_400_000],
  [one.events.length, keptEvents.length, one.events.length - keptEvents.length, 0, 201, 2,
    { canceled: 1, paused: 2, reactivated: 1, renew_failed: 3, renewed: 201, resumed: 1, status_changed: 1 }, 1, 9, true],
  [0, 0, 0, 1, 0, 0, {}, 0, 0, false]);
expect("B3 …and both wrote nothing: no run, no subscription, no event, no cursor",
  [(await runsOf(juo1.id)).length, await counted("subscription", juo1.id), await counted("subscription_event", juo1.id), await cursor(juo1.id, "juo:events")],
  [0, 0, 0, null], [1, 230, 1, {}]);

// ---- C. The backfills: the events from a date, then the subscriptions -----------------------------------------------------
const t0 = Date.now();
b = await runBackfill({ connectionId: juo1.id, object: "subscription_event", from: FROM });
let run = (await runsOf(juo1.id, "backfill")).at(-1);
expect("C1 the backfill of the events: stream subscription_event, the kept ones stored, the other types skipped, the free-text reason dropped and counted",
  [b.failed, run.stream, run.status, run.counts.fetched, run.counts.events_new, run.counts.skipped, run.counts.reason_dropped, await counted("subscription_event", juo1.id)],
  [0, "subscription_event", "succeeded", one.events.length, keptEvents.length, one.events.length - keptEvents.length, 1, keptEvents.length],
  [1, null, "failed", 0, 0, 0, 0, 0]);
expect("C2 …its cursor done; the poll's cursor at the backfill's start",
  [(await cursor(juo1.id, "backfill:subscription_event"))?.done, (await cursor(juo1.id, "juo:events"))?.at >= t0],
  [true, true], [false, false]);
b = await runBackfill({ connectionId: juo1.id, object: "subscription" });
run = (await runsOf(juo1.id, "backfill")).at(-1);
expect("C3 the backfill of the subscriptions: stream subscription, 230 inserted, 30 customers without a match among the store's, nothing missing",
  [b.failed, run.stream, run.status, run.counts.fetched, run.counts.inserted, run.counts.upserted, run.counts.customers_unmatched, run.counts.missing_now,
    Number.isInteger(run.counts.slice_max_ms)],
  [0, "subscription", "succeeded", 230, 230, 230, 30, 0, true], [1, null, "failed", 0, 0, 0, 0, 1, false]);
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

// ---- G. Tenant two; nothing personal; nothing elsewhere -----------------------------------------------------------------------
b = await runBackfill({ connectionId: juo2.id, object: "subscription" });
expect("G1 tenant two's store loads into tenant two only; tenant one's subscriptions as they were",
  [b.failed, await counted("subscription", juo2.id), (await q("select count(*)::int as n from cma.subscription where tenant_id = $1", [T2.t]))[0].n,
    (await q("select count(*)::int as n from cma.subscription where tenant_id = $1", [T1.t]))[0].n,
    (await q("select count(*)::int as n from cma.subscription where tenant_id = $1 and source_id like 't-%'", [T1.t]))[0].n],
  [0, 230, 230, 230, 0], [1, 0, 0, 0, 1]);
// (the card's digits are looked for by their field and brand: four digits alone can occur in any uuid)
const PERSONAL = ["Invented", "example.invalid", "Fixture Street", "Testtown", "FX1 1XX", "+44 20", "lastDigits", "visa", "****", "asked for a call", "Too expensive",
  "insufficient funds", "card declined", "consumerName", "deliveryAddress", "billingAddress", "Service plan", "FIXTURE10"];
const dbText = JSON.stringify(await q(`select row_to_json(x)::text as r from cma.subscription x where tenant_id = any($1::uuid[])
  union all select row_to_json(x)::text from cma.subscription_event x where tenant_id = any($1::uuid[])
  union all select row_to_json(x)::text from cma.sync_run x where tenant_id = any($1::uuid[])
  union all select row_to_json(x)::text from cma.sync_cursor x where tenant_id = any($1::uuid[])
  union all select row_to_json(x)::text from cma.audit_log x where tenant_id = any($1::uuid[]) and table_name in ('subscription', 'subscription_event', 'sync_run', 'sync_cursor')`,
  [[T1.t, T2.t]]));
expect("G2 no name, address, email, phone, payment detail, message or free-text reason in any row of the run's tenants (audit log included)",
  PERSONAL.filter((p) => dbText.includes(p)), [], PERSONAL);
const logText = logs.join("\n");
expect("G3 the logs hold no key and no value: connection ids, counts, codes and Juo's type names",
  [...PERSONAL, KEY1, KEY2, one.subscriptions[0].customer, "7100000"].filter((v) => logText.includes(v)), [], ["x"]);
expect("G4 every request carried its store's id and a key, in headers; none for the store-less handle",
  [fake.state.requests.every((r) => r.tenant && !r.keyInUrl), asksFor(`juo-${RUN}-nostore.myshopify.com`).length], [true, 0], [false, 1]);
expect("G5 nothing written to another tenant by this run's logins", await writesOutside(q, { tenants: [T1.t, T2.t], since, logins: [ADMIN, process.env.CMA_DB_USER] }), [], ["x"]);

// This run's connections stop being served (a later run's unfiltered jobs leave them alone); the tenants stay
for (const [tenant, c] of [[T1, juo1.id], [T1, nostore.id], [T1, keyless.id], [T2, juo2.id]]) await asAdmin(tenant, () => q("select cma.set_connection_status($1, 'inactive')", [c]));
await admin.end();
await new Promise((r) => service.close(r));
await fake.close();
await closeDb();
rmSync(secretsDir, { recursive: true, force: true });
await poolCheck();
verdict();
