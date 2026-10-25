/**
 * Verifier: the Trusted Shops adapter end to end (addition 0008ze, brief B18), against a local PostgreSQL with db/00…104
 * and the fake eTrusted API with HubSpot's contact search (verify/etrusted-fake.mjs). Everything is invented: tenants,
 * channels, reviews, orders, contacts, emails (example.com), names, numbers in the +44 20 0000 09xx range.
 *
 *   CMA_DB_HOST=/tmp CMA_DB_PORT=5432 CMA_DB_NAME=cma CMA_DB_USER=cma-ingest@local.iam \
 *   INGEST_FLOW_ADMIN_USER=<team login> node verify/reviews-flow.mjs [--provoke]
 *
 * Logins as in verify/flow.mjs. One throwaway tenant per run (reviews-<run>-one); the jobs run in this process; at the
 * end this run's connections are set inactive.
 *
 * Proves: no route for the adapter (404); the first poll: the channel catalog (new channels unmapped, not counted), the
 * reviews of the last reviews_reconcile_days (statements asked for, an unreadable review skipped), the order link by
 * order name with the order's customer's contact (0008h), a contact found by email (one search per new review without a
 * link; none and two contacts leave none), the run's sync_run row and counts, the cursors; a poll not due writes
 * nothing; the next poll reads from its cursor less two hours, stores only what is new, and alerts on a negative review
 * of a counted channel once the channels are mapped; a 429 fails the run (rate_limited) and the next one carries on;
 * the reconcile reads the window again (a state change, a reply) and looks every unlinked review up again (a contact
 * that exists now is linked); the backfill without a history start reads all history from 2000 across pages and
 * channels, resumes after an interruption from its cursor, logs a summary per channel, a second run reads nothing,
 * --again re-walks and stores nothing new; below the CRM's daily floor the backfill pauses (daily_floor) and resumes;
 * the CRM's privacy deletion clears the reviews' contact links (an email link gone, an order kept); no name, email,
 * phone, title or text in any row of the run's tenant or in the logs; nothing written to another tenant.
 */
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { randomBytes } from "node:crypto";
import pg from "pg";
import { expect, verdict, writesOutside, PROVOKE } from "./lib.mjs";
import { startFakeETrusted, loadReviewsSource } from "./etrusted-fake.mjs";

console.log(`verify/reviews-flow.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

for (const v of ["CMA_DB_HOST", "CMA_DB_USER"]) {
  if (!process.env[v]) {
    console.error(`${v} is required (a local PostgreSQL with db/00…104; see the header)`);
    process.exit(2);
  }
}
const ADMIN = process.env.INGEST_FLOW_ADMIN_USER;
if (!ADMIN) {
  console.error("INGEST_FLOW_ADMIN_USER is required: a team login that holds cma_owner and cma_app by SET ROLE (locally, for example, auditor@local)");
  process.exit(2);
}
const RUN = randomBytes(4).toString("hex");
const SLUG = `reviews-${RUN}-one`;
const CLIENT = "fixture-etrusted-client";
const SECRET = "fixture-etrusted-client-secret-0001";
const HS_TOKEN = "fixture-hubspot-token-0001";
const DAY = 86_400_000;

// ---- Secrets as files; the fake source ---------------------------------------------------------------------
const secretsDir = mkdtempSync(path.join(tmpdir(), "reviews-flow-"));
writeFileSync(path.join(secretsDir, `ingest-trustedshops-${RUN}-secret`), SECRET);
writeFileSync(path.join(secretsDir, `ingest-hubspot-${RUN}-token`), HS_TOKEN);
const START = Date.now();
const source = loadReviewsSource(START);
const fake = await startFakeETrusted({ clients: { [CLIENT]: SECRET }, channels: source.channels, reviews: source.reviews, contacts: { ...source.contacts } });
const reviewsAsked = () => fake.state.requests.filter((r) => r.path === "/reviews");

process.env.INGEST_SECRETS_DIR = secretsDir;
process.env.INGEST_ETRUSTED_LOGIN_BASE = fake.url;
process.env.INGEST_ETRUSTED_API_BASE = fake.url;
process.env.INGEST_HUBSPOT_API_BASE = fake.url;
process.env.INGEST_PACE_FACTOR = "0.01";
const logs = [];
const { setLogSink } = await import("../src/core/log.mjs");
setLogSink((line) => logs.push(line));
const { createIngestServer } = await import("../src/server.mjs");
const { runPollReviews } = await import("../src/jobs/poll-reviews.mjs");
const { runReconcile } = await import("../src/jobs/reconcile.mjs");
const { runBackfill } = await import("../src/jobs/backfill.mjs");
const { servedConnections, contextOf } = await import("../src/core/connection.mjs");
const { applyUnits } = await import("../src/core/store.mjs");
const { closeDb } = await import("../src/core/db.mjs");
const service = createIngestServer();
await new Promise((r) => service.listen(0, "127.0.0.1", r));
const BASE = `http://127.0.0.1:${service.address().port}`;

// ---- Setup as the admin login ------------------------------------------------------------------------------
const admin = new pg.Client({ host: process.env.CMA_DB_HOST, port: Number(process.env.CMA_DB_PORT ?? 5432), database: process.env.CMA_DB_NAME ?? "cma",
  user: ADMIN, password: process.env.CMA_DB_PASSWORD || undefined });
await admin.connect();
const q = async (text, values) => (await admin.query(text, values)).rows;
await q("set role cma_owner");
const [{ since }] = await q("select now()::text as since");
const [{ t1 }] = await q("select cma.create_tenant($1, 'Reviews flow one', 'Europe/Amsterdam') as t1", [SLUG]);
const [{ id: adminId }] = await q("insert into cma.app_user (tenant_id, email, display_name) values ($1, 'flow-admin@example.invalid', 'Flow admin') returning id", [t1]);
await q("insert into cma.user_role (tenant_id, user_id, role_id) select $1, $2, id from cma.app_role where tenant_id = $1 and key = 'admin'", [t1, adminId]);
async function asAdmin(fn) {
  await q("begin");
  await q("set local role cma_app");
  await q("select set_config('app.tenant_id', $1, true), set_config('app.user_id', $2, true), set_config('app.actor_label', 'verify:reviews-flow', true)", [t1, adminId]);
  try {
    const r = await fn();
    await q("commit");
    return r;
  } catch (e) {
    await q("rollback");
    throw e;
  }
}
const SETTINGS = (conn, extra = {}) => JSON.stringify({ client_id: CLIENT, crm_connection_id: conn.h, etrusted_max_per_minute: 600,
  record_url_review: "https://reviews.example.invalid/{account}/reviews/{id}", ...extra });
const conn = await asAdmin(async () => {
  await q("select cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', null, null, 10)");
  await q("select cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', null, null, 20)");
  const [h] = await q("select * from cma.upsert_connection('hubspot', 'HubSpot flow', $1, null, $2)", [`9${RUN.replace(/\D/g, "1").slice(0, 6)}`, `ingest-hubspot-${RUN}-token`]);
  await q("select cma.set_connection_kind($1, 'crm')", [h.connection_id]);
  const [s] = await q("select * from cma.upsert_connection('shopify', 'Shop flow', $1, $2, null)", [`flow-${RUN}.myshopify.com`, `ingest-shopify-${RUN}-signing`]);
  await q("select cma.set_connection_kind($1, 'commerce')", [s.connection_id]);
  const [t] = await q("select * from cma.upsert_connection('trustedshops', 'Trusted Shops flow', $1, null, $2)", [`acc-fixture-${RUN}`, `ingest-trustedshops-${RUN}-secret`]);
  await q("select cma.set_connection_kind($1, 'reviews')", [t.connection_id]);
  await q("select cma.upsert_review_rule('Negative review', 'performance.team', false, false, null, 'normal', 2, 1440)");
  return { h: h.connection_id, s: s.connection_id, t: t.connection_id, tKey: t.key, account: `acc-fixture-${RUN}` };
});
await asAdmin(() => q("select cma.set_connection_settings($1, $2::jsonb)", [conn.t, SETTINGS(conn)]));
// The store's customer linked to contact 5100000071 (0008h) and its order TESTNL-71001 (as the owner: 0007b's upserts are not under test)
await q(`insert into cma.commerce_customer (tenant_id, connection_id, source_system, source_id, crm_connection_id, crm_contact_source_id, matched_at)
         values ($1, $2, 'shopify', 'cu-flow-1', $3, '5100000071', now())`, [t1, conn.s, conn.h]);
await q(`insert into cma.commerce_order (tenant_id, connection_id, source_system, source_id, order_name, customer_source_id, source_created_at)
         values ($1, $2, 'shopify', 'so-flow-1', 'TESTNL-71001', 'cu-flow-1', now() - interval '20 days')`, [t1, conn.s]);

const reviewsOf = async () => q(`select r.source_id, r.link_level, r.crm_contact_source_id as contact, r.commerce_order_id is not null as has_order, r.state,
    r.is_published, r.has_reply, r.rating::text, ch.source_id as channel
  from cma.review r join cma.review_channel ch on ch.id = r.review_channel_id where r.tenant_id = $1 order by r.source_id`, [t1]);
const runsOf = async (job) => q("select status, error, counts, from_at from cma.sync_run where tenant_id = $1 and connection_id = $2 and job = $3 order by started_at",
  [t1, conn.t, job]);
const cursor = async (stream) => (await q("select cursor from cma.sync_cursor where tenant_id = $1 and connection_id = $2 and stream = $3", [t1, conn.t, stream]))[0]?.cursor ?? null;
const link = (rows, id) => rows.find((r) => r.source_id === id);

// ---- A. No route --------------------------------------------------------------------------------------------
const post = async (p) => (await fetch(`${BASE}${p}`, { method: "POST", headers: { "content-type": "application/json" }, body: "{}" })).status;
expect("A1 no route for the polling-only adapter: its own key and an unknown key → 404", [await post(`/trustedshops/${conn.tKey}`), await post("/trustedshops/unknownkey00000000000000")], [404, 404], [200, 200]);

// ---- B. The first poll --------------------------------------------------------------------------------------
let total = await runPollReviews({ connectionId: conn.t });
let rows = await reviewsOf();
const channels = await q("select source_id, market, is_counted from cma.review_channel where tenant_id = $1 order by source_id", [t1]);
expect("B1 the poll ran for the connection; the channel catalog: three channels without a market, not counted",
  [total.connections, total.failed, channels.map((c) => `${c.source_id}:${c.market ?? "-"}:${c.is_counted}`)],
  [1, 0, ["chl-fixture-gb:-:false", "chl-fixture-nl:-:false", "chl-fixture-x:-:false"]], [0, 1, []]);
expect("B2 the reviews of the last 30 days, the statement among them; the unreadable one and the old one not stored",
  rows.map((r) => r.source_id), ["rev-fixture-contact-1", "rev-fixture-none-1", "rev-fixture-order-1", "rev-fixture-rejected-1", "rev-fixture-statement-1",
    "rev-fixture-twice-1", "rev-fixture-x-1"], []);
expect("B3 the links: order by name with its customer's contact; a contact by email; none for no contact and for two",
  [link(rows, "rev-fixture-order-1"), link(rows, "rev-fixture-contact-1"), link(rows, "rev-fixture-none-1").link_level, link(rows, "rev-fixture-twice-1").link_level]
    .map((x) => (typeof x === "object" ? `${x.link_level}:${x.contact}:${x.has_order}` : x)),
  ["order:5100000071:true", "contact:5100000072:false", "none", "none"], []);
expect("B4 one search per new review without a link that holds an email (six), none for the order's", fake.state.searches, 6, 7);
let runs = await runsOf("reviews_poll");
expect("B5 one sync_run row: reviews_poll succeeded, fetched 8, upserted 7, skipped 1 (the unreadable one)",
  runs.map((r) => [r.status, r.error, r.counts.fetched, r.counts.upserted, r.counts.skipped]), [["succeeded", null, 8, 7, 1]], [["failed", null, 0, 0, 0]]);
const firstAfter = Date.parse(reviewsAsked()[0].query.submittedAfter);
expect("B6 without a cursor the poll read the last 30 days (less the two hours' overlap), statements asked for",
  [Math.abs(firstAfter - (START - 30 * DAY - 2 * 3_600_000)) < 120_000, reviewsAsked()[0].query.ignoreStatements], [true, "false"], [false, undefined]);
const nlCursor = await cursor("reviews:chl-fixture-nl");
expect("B7 a cursor per channel at the poll's start, and the cadence", [Number.isFinite(nlCursor?.at) && nlCursor.at >= START - 5_000, Number.isFinite((await cursor("reviews:cadence"))?.at)],
  [true, true], [false, false]);
expect("B8 no alert: no channel counts yet", (await q("select count(*)::int as n from cma.message where tenant_id = $1 and ref_type = 'review'", [t1]))[0].n, 0, 1);

// ---- C. Not due; the next poll from its cursor; an alert --------------------------------------------------------
const asked0 = reviewsAsked().length;
total = await runPollReviews({ connectionId: conn.t });
expect("C1 a second poll within the interval: not due, no request, no run", [total.notDue, reviewsAsked().length - asked0, (await runsOf("reviews_poll")).length], [1, 0, 1], [0, 3, 2]);
await asAdmin(async () => {
  await q("select cma.set_review_channel($1, 'chl-fixture-nl', 'NL', true)", [conn.t]);
  await q("select cma.set_review_channel($1, 'chl-fixture-gb', 'GB', true)", [conn.t]);
  await q("select cma.set_connection_settings($1, $2::jsonb)", [conn.t, SETTINGS(conn, { reviews_poll_interval_minutes: 1 })]);
});
fake.state.reviews.push({ id: "rev-fixture-new-1", channelRef: "chl-fixture-nl", rating: 1, type: "SERVICE_REVIEW", state: "APPROVED",
  submittedAt: new Date(Date.now() - 60_000).toISOString(), updatedAt: new Date(Date.now() - 60_000).toISOString(),
  customer: { fullName: "Invented Reviewer Nine", email: "new@example.com", mobile: "+44 20 0000 0909" }, comment: "Fixture text nine" });
const searches0 = fake.state.searches;
const asked1 = reviewsAsked().length;
total = await runPollReviews({ connectionId: conn.t });
const nlAsk = reviewsAsked().slice(asked1).find((r) => r.query.channels === "chl-fixture-nl");
runs = await runsOf("reviews_poll");
expect("C2 the next poll reads each channel from its cursor less two hours", nlAsk?.query.submittedAfter, new Date(nlCursor.at - 2 * 3_600_000).toISOString(), "x");
expect("C3 only the new review is written; the two of the overlap read again unchanged; one search, for the new one",
  [runs.at(-1).counts.upserted, runs.at(-1).counts.skipped, fake.state.searches - searches0], [1, 2, 1], [8, 0, 7]);
const msgs = await q(`select m.title, m.body, m.ref_url, m.ref_system from cma.message m join cma.message_rule r on r.id = m.rule_id
  where m.tenant_id = $1 and m.ref_type = 'review' order by m.created_at`, [t1]);
expect("C4 the negative review of a counted channel raised one alert: market, channel, rating, time and the link only",
  msgs.map((m) => [m.title, /^NL · shop-nl\.example · rating 1 of 5 · submitted \d{4}-\d\d-\d\d \d\d:\d\d$/.test(m.body), m.ref_url, m.ref_system]),
  [["New review", true, `https://reviews.example.invalid/${conn.account}/reviews/rev-fixture-new-1`, "trustedshops"]], []);

// ---- D. A 429; the reconcile ----------------------------------------------------------------------------------------
fake.state.fail429 = 1;
total = await runPollReviews({ connectionId: conn.t });
runs = await runsOf("reviews_poll");
expect("D1 a 429 fails the run (rate_limited), logged, nothing retried", [total.failed, runs.at(-1).status, runs.at(-1).error, logs.some((l) => JSON.parse(l).message === "etrusted rate limited")],
  [1, "failed", "rate_limited", true], [0, "succeeded", null, false]);
await new Promise((r) => setTimeout(r, 1100));
total = await runPollReviews({ connectionId: conn.t });
expect("D2 the next poll carries on", [total.failed, (await runsOf("reviews_poll")).at(-1).status], [0, "succeeded"], [1, "failed"]);
const none1 = fake.state.reviews.find((r) => r.id === "rev-fixture-none-1");
Object.assign(none1, { state: "REJECTED", updatedAt: new Date().toISOString(), reply: { comment: "Fixture reply text", createdAt: new Date().toISOString() } });
fake.state.contacts["5100000073"] = { email: "nobody@example.com" };
const searches1 = fake.state.searches;
total = await runReconcile({ connectionId: conn.t, object: "review" });
rows = await reviewsOf();
const rec = (await q("select status, counts from cma.sync_run where tenant_id = $1 and connection_id = $2 and job = 'reconcile' order by started_at", [t1, conn.t])).at(-1);
expect("D3 the reconcile: one run succeeded; the state change and the reply read; the contact that exists now linked",
  [rec?.status, link(rows, "rev-fixture-none-1").state, link(rows, "rev-fixture-none-1").is_published, link(rows, "rev-fixture-none-1").has_reply,
    `${link(rows, "rev-fixture-none-1").link_level}:${link(rows, "rev-fixture-none-1").contact}`],
  ["succeeded", "REJECTED", false, true, "contact:5100000073"], ["failed", "APPROVED", true, false, "none:null"]);
expect("D4 the reconcile looked every review without a link up again (six with an email)", fake.state.searches - searches1, 6, 0);

// ---- E. The backfill: all history, an interruption, a resume, nothing twice -----------------------------------------
const history = Array.from({ length: 250 }, (_, i) => ({ id: `rev-fixture-h-${String(i).padStart(3, "0")}`, channelRef: "chl-fixture-gb", rating: 1 + (i % 5),
  type: "SERVICE_REVIEW", state: "APPROVED", submittedAt: new Date(START - (400 + i * 4) * DAY).toISOString(), updatedAt: new Date(START - (400 + i * 4) * DAY).toISOString(),
  customer: { email: `history-${i}@example.com` } }));
fake.state.reviews.push(...history);
fake.state.failReviewsAfter = 5;
let b = await runBackfill({ connectionId: conn.t, object: "review" });
const cur1 = await cursor("backfill:review");
expect("E1 the backfill without a history start: all history (from null); interrupted, failed with the source's code, its cursor kept",
  [b.from, b.failed, b.error, cur1?.from, cur1?.done, typeof cur1?.channel],
  ["all history", 1, "http_503", null, false, "string"], ["2026-01-01", 0, null, 0, true, "undefined"]);
const firstBackfillAsk = reviewsAsked().filter((r) => r.query.submittedBefore).find((r) => r.query.submittedAfter?.startsWith("1999"));
expect("E2 it started at the floor, 1 January 2000 (submittedAfter its last millisecond before)", firstBackfillAsk?.query.submittedAfter, "1999-12-31T23:59:59.999Z", "2000-01-01T00:00:00.000Z");
fake.state.failReviewsAfter = null;
const asked2 = reviewsAsked().length;
b = await runBackfill({ connectionId: conn.t, object: "review" });
const total2 = (await q("select count(*)::int as n from cma.review where tenant_id = $1", [t1]))[0].n;
expect("E3 the same command resumes from its cursor and finishes; every readable review held (8 + the old one + 250)",
  [b.failed, (await cursor("backfill:review"))?.done, total2, reviewsAsked().slice(asked2).some((r) => r.query.submittedAfter?.startsWith("1999") && r.query.channels === "chl-fixture-gb" && !r.query.after && r.query.submittedBefore?.startsWith("2000"))],
  [0, true, 259, false], [1, false, 0, true]);
const summaries = logs.map((l) => JSON.parse(l)).filter((l) => l.message === "backfill: review channel");
const gbSummary = summaries.filter((s) => s.channel === "chl-fixture-gb").at(-1);
expect("E4 a summary per channel: reviews held (GB: 3 + 250), link levels, oldest and newest submission",
  [gbSummary?.held, typeof gbSummary?.linkedOrder, gbSummary?.oldestSubmittedAt?.slice(0, 4) <= "2023", Boolean(gbSummary?.newestSubmittedAt)], [253, "number", true, true], [0, "undefined", false, false]);
const asked3 = reviewsAsked().length;
b = await runBackfill({ connectionId: conn.t, object: "review" });
expect("E5 a second run reads nothing and stores nothing new", [reviewsAsked().length - asked3, b.upserted, b.fetched], [0, 0, 0], [3, 1, 1]);
b = await runBackfill({ connectionId: conn.t, object: "review", again: true });
expect("E6 --again walks all history again and stores nothing new", [b.fetched >= 258, b.upserted, (await q("select count(*)::int as n from cma.review where tenant_id = $1", [t1]))[0].n],
  [true, 0, 259], [false, 1, 0]);

// ---- F. The CRM's daily floor ----------------------------------------------------------------------------------------
fake.state.daily = { limit: 1000, remaining: 100 };
b = await runBackfill({ connectionId: conn.t, object: "review", again: true });
const paused = (await q("select status, error from cma.sync_run where tenant_id = $1 and connection_id = $2 and job = 'backfill' order by started_at", [t1, conn.t])).at(-1);
expect("F1 below the CRM's floor (10 % left, floor 25 %) the backfill pauses: succeeded with daily_floor, its cursor not done",
  [b.paused, paused.status, paused.error, (await cursor("backfill:review"))?.done], [true, "succeeded", "daily_floor", false], [undefined, "failed", null, true]);
fake.state.daily = { limit: 1000, remaining: 900 };
b = await runBackfill({ connectionId: conn.t, object: "review", again: true });
expect("F2 above it the same command resumes and finishes", [b.paused, b.failed, (await cursor("backfill:review"))?.done], [undefined, 0, true], [true, 1, false]);

// ---- G. The CRM's privacy deletion ------------------------------------------------------------------------------------
const [hc] = await servedConnections({ connectionId: conn.h, actorLabel: "ingest:verify" });
const forgot = await applyUnits(contextOf(hc), conn.h, [{ eventIds: [], status: "processed", writes: { forgets: ["5100000072", "5100000071"] } }]);
rows = await reviewsOf();
expect("G1 the privacy deletion: the email link gone (none), the order kept without its contact; counted",
  [`${link(rows, "rev-fixture-contact-1").link_level}:${link(rows, "rev-fixture-contact-1").contact}`, `${link(rows, "rev-fixture-order-1").link_level}:${link(rows, "rev-fixture-order-1").contact}`,
    forgot.counts.reviewLinksForgotten], ["none:null", "order:null", 2], ["contact:5100000072", "order:5100000071", 0]);

// ---- H. Nothing personal kept; nothing written elsewhere -----------------------------------------------------------
const dbText = JSON.stringify(await q(`select row_to_json(x)::text as r from cma.review x where tenant_id = $1
  union all select row_to_json(x)::text from cma.review_channel x where tenant_id = $1
  union all select row_to_json(x)::text from cma.sync_cursor x where tenant_id = $1
  union all select row_to_json(x)::text from cma.sync_run x where tenant_id = $1
  union all select row_to_json(x)::text from cma.message x where tenant_id = $1
  union all select row_to_json(x)::text from cma.audit_log x where tenant_id = $1`, [t1]));
const PERSONAL = ["@example.com", "Invented Reviewer", "+44 20 0000 09", "Fixture title", "Fixture text", "Fixture reply", "fullName", "mobile", "comment"];
expect("H1 no email, name, phone, title, text or reply in any row of the tenant (audit log included)", PERSONAL.filter((p) => dbText.includes(p)), [], PERSONAL);
const logText = logs.join("\n");
expect("H2 the logs hold no email, name, phone, text, token or secret", [...PERSONAL, "fixture-etrusted-token", SECRET, HS_TOKEN].filter((p) => logText.includes(p)), [], ["x"]);
expect("H3 the logs hold the poll, reconcile and backfill lines", ["poll-reviews: connection", "reconcile: reviews", "backfill: reviews", "backfill paused"].every((m) => logs.some((l) => JSON.parse(l).message === m)),
  true, false);
expect("H4 nothing written to another tenant by this run's logins", await writesOutside(q, { tenants: [t1], since, logins: [ADMIN, process.env.CMA_DB_USER] }), [], ["x"]);

// This run's connections stop being served (a later run's unfiltered jobs leave them alone)
for (const c of [conn.t, conn.s, conn.h]) await asAdmin(() => q("select cma.set_connection_status($1, 'inactive')", [c]));
await admin.end();
await new Promise((r) => service.close(r));
await fake.close();
await closeDb();
rmSync(secretsDir, { recursive: true, force: true });
verdict();
