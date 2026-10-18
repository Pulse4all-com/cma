/**
 * Verifier: the email poll end to end (brief B17b), against a PostgreSQL at addition 0008m (dev, or a
 * local database built from db/00…69) and a fake HubSpot on localhost (verify/email-fake.mjs, the
 * fixtures verify/fixtures/hubspot/email-source.json and email-rules.json). Everything is invented:
 * tenants, portals, ids, names, addresses, subjects, texts.
 *
 *   CMA_DB_HOST=127.0.0.1 CMA_DB_PORT=5433 CMA_DB_NAME=cma CMA_DB_USER=<your login> CMA_DB_SET_ROLE=cma_app \
 *   INGEST_FLOW_ADMIN_USER=<team login> node verify/email-flow.mjs [--provoke]
 *
 * In dev (docs/b17b-email-ingest/MORNING_RUNBOOK.md, step 7) through cloud-sql-proxy --auto-iam-authn on
 * port 5433: your own login is both the job's (it holds cma_app; CMA_DB_SET_ROLE=cma_app) and the
 * admin that creates two throwaway tenants per run (email-<run>-one, email-<run>-two) and reads as
 * the owner. Locally CMA_DB_USER may be a login that inherits cma_app (cma-ingest@local.iam). It
 * refuses a database without the dev seed (no active agent.two@example.com: exit 2), so it never runs
 * in prod. Both connections are of kind crm, as a real HubSpot connection is (cma.set_connection_kind;
 * without it 53's A4 lists them). At the end this run's connections are set inactive, so no job serves
 * them again, and the run removes its two tenants with every row they hold (J1), so nothing of it stays
 * in the database. Every job runs with this run's connection: without one it serves every active
 * connection of the database, in dev the real tenant's (B17b.1; I1 proves nothing outside the two
 * tenants was written).
 *
 * Proves: the poll writes engagements (direction, status, actor kinds, the owner, the CRM thread id
 * and the automation origin by configuration, the category), their associations, inbox threads,
 * messages and events, the contacts they point to after them with every country slot (slot 2 through
 * the market alias) and never a contact nothing points to, the catalogs; a second poll writes nothing
 * (no audit row); a new message is added alone; a 429 leaves the engagements' cursor and the
 * conversations still run; the open check stores a close without a message and forgets a thread gone
 * at the source; the reconcile rewrites only a changed email and marks a thread in the trash
 * archived, then forgets it once it is gone; the backfill starts at cma.email_start_date_of, resumes
 * after an interruption, finds what the poll's window does not, and the contact backfill reads every
 * slot again; the shared rule fixtures give the same answers in cma.email_words_match and
 * cma.email_category_of as in the ingest's memory; a connection without email_poll is not served;
 * tenant isolation; no row, audit image, cursor or log line holds a name, address, subject, text or
 * raw actor id, and no log line an email, thread or contact id; no row of another tenant was written
 * by this run (the audit log); no row of the run's own tenants is left.
 */
import { readFileSync } from "node:fs";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { randomBytes } from "node:crypto";
import pg from "pg";
import { expect, verdict, writesOutside, removeTenants, PROVOKE } from "./lib.mjs";
import { loadSource, startFakeHubSpot } from "./email-fake.mjs";

console.log(`verify/email-flow.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

for (const v of ["CMA_DB_HOST", "CMA_DB_USER"]) {
  if (!process.env[v]) {
    console.error(`${v} is required (a database at 0008m; see the header)`);
    process.exit(2);
  }
}
const ADMIN = process.env.INGEST_FLOW_ADMIN_USER;
if (!ADMIN) {
  console.error("INGEST_FLOW_ADMIN_USER is required: a team login that holds cma_owner and cma_app by SET ROLE (locally, for example, auditor@local)");
  process.exit(2);
}
const RUN = randomBytes(4).toString("hex");
const SLUG1 = `email-${RUN}-one`;
const SLUG2 = `email-${RUN}-two`;
const NOW = Date.now();
const DAY = 24 * 60 * 60_000;
const source = loadSource(NOW);
const RULES = JSON.parse(readFileSync(new URL("./fixtures/hubspot/email-rules.json", import.meta.url), "utf8"));
const ago = (min) => new Date(NOW - min * 60_000).toISOString();
// Older than the poll's first window (26 hours): only the backfill finds these two
source.engagements["4500000007"] = { hs_timestamp: ago(2880), hs_createdate: ago(2880), hs_lastmodifieddate: ago(2880), hs_email_direction: "EMAIL",
  hs_email_status: "SENT", hubspot_owner_id: "7100000001", hs_email_subject: "Your invoice INV-INVENTED-77" };
source.emailAssociations.contacts["4500000007"] = ["4300000104"];
source.threads["8800000006"] = { inboxId: "1500000001", originalChannelId: "1002", status: "CLOSED", closedAt: ago(2870), spam: false, archived: false,
  createdAt: ago(2880), latestMessageTimestamp: ago(2880), latestMessageReceivedTimestamp: ago(2880) };
source.messages["8800000006"] = [{ type: "MESSAGE", id: "m6a0000000000000000000000000001", conversationsThreadId: "8800000006", createdAt: ago(2880),
  createdBy: "E-customer.invented@example.net", direction: "INCOMING", channelId: "1002", channelAccountId: "1600000001", subject: "Partnership",
  text: "secret body text", status: { statusType: "RECEIVED" } }];

const fake = await startFakeHubSpot(source);
const secretsDir = mkdtempSync(path.join(tmpdir(), "ingest-email-"));
writeFileSync(path.join(secretsDir, `ingest-hubspot-email${RUN}-signing`), "fixture-email-client-secret");
writeFileSync(path.join(secretsDir, `ingest-hubspot-email${RUN}-token1`), "fixture-email-token-one");
writeFileSync(path.join(secretsDir, `ingest-hubspot-email${RUN}-token2`), "fixture-email-token-two");
process.env.INGEST_SECRETS_DIR = secretsDir;
process.env.INGEST_HUBSPOT_API_BASE = fake.url;
process.env.INGEST_PACE_FACTOR = "0";
const logs = [];
const { setLogSink } = await import("../src/core/log.mjs");
setLogSink((line) => logs.push(line));
const { runPollEmail } = await import("../src/jobs/poll-email.mjs");
const { runReconcile } = await import("../src/jobs/reconcile.mjs");
const { runBackfill } = await import("../src/jobs/backfill.mjs");
const { closeDb } = await import("../src/core/db.mjs");
const { wordsMatch, classify, activeRules } = await import("../src/adapters/hubspot/rules.mjs");

// ---- Setup as the admin login --------------------------------------------------------------------
const admin = new pg.Client({ host: process.env.CMA_DB_HOST, port: Number(process.env.CMA_DB_PORT ?? 5432), database: process.env.CMA_DB_NAME ?? "cma",
  user: ADMIN, password: process.env.CMA_DB_PASSWORD || undefined });
await admin.connect();
const q = async (text, values) => (await admin.query(text, values)).rows;
await q("set role cma_owner");
const [{ dev }] = await q("select exists (select 1 from cma.app_user where email = 'agent.two@example.com' and status = 'active') as dev");
if (!dev) {
  console.error("REFUSED: the connected database is not dev (no active agent.two@example.com); email-flow runs in dev or a local database only");
  await admin.end();
  await fake.close();
  process.exit(2);
}
// The run's start on the database's clock, for the guard (I1)
const [{ since: STARTED }] = await q("select clock_timestamp()::text as since");
const [{ t1 }] = await q("select cma.create_tenant($1, $2, 'Europe/Amsterdam') as t1", [SLUG1, "Email one"]);
const [{ t2 }] = await q("select cma.create_tenant($1, $2, 'Europe/Amsterdam') as t2", [SLUG2, "Email two"]);
const adminOf = {};
for (const t of [t1, t2]) {
  const [{ id }] = await q("insert into cma.app_user (tenant_id, email, display_name) values ($1, 'email-admin@example.invalid', 'Email admin') returning id", [t]);
  await q("insert into cma.user_role (tenant_id, user_id, role_id) select $1, $2, id from cma.app_role where tenant_id = $1 and key = 'admin'", [t, id]);
  adminOf[t] = id;
}
async function asAdmin(tenant, fn) {
  await q("begin");
  await q("set local role cma_app");
  await q("select set_config('app.tenant_id', $1, true), set_config('app.user_id', $2, true), set_config('app.actor_label', 'verify:email', true)", [tenant, adminOf[tenant]]);
  try {
    const r = await fn();
    await q("commit");
    return r;
  } catch (e) {
    await q("rollback");
    throw e;
  }
}
const START = new Date(NOW - 3 * DAY).toISOString().slice(0, 10);
const conn1 = await asAdmin(t1, async () => {
  const [c] = await q("select * from cma.upsert_connection('hubspot', 'HubSpot email one', '9000201', $1, $2)", [`ingest-hubspot-email${RUN}-signing`, `ingest-hubspot-email${RUN}-token1`]);
  await q("select cma.set_connection_kind($1, 'crm')", [c.connection_id]);
  await q("select cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP')");
  await q("select cma.set_market_alias('united kingdom', 'GB')");
  await q("select cma.set_connection_field($1, 'contact', 'country', '', 'contact_country', 1::smallint)", [c.connection_id]);
  await q("select cma.set_connection_field($1, 'contact', 'country', '', 'country_dropdown', 2::smallint)", [c.connection_id]);
  await q("select cma.set_connection_settings($1, $2::jsonb)", [c.connection_id, JSON.stringify({ email_poll: true, email_thread_property: "fixture_thread_id",
    email_origin_property: "fixture_origin", email_automated_origins: "automation_fixture" })]);
  for (const r of RULES.rules) {
    const [{ id }] = await q("select cma.set_email_rule($1, null, $2, $3, $4, $5, $6) as id", [c.connection_id, r.appliesTo, r.words, r.excludeWords, r.category, r.order]);
    if (r.status !== "active") await q("select cma.set_email_rule_status($1, $2)", [id, r.status]);
  }
  await q("select cma.set_tenant_setting('email.start_date', $1)", [START]);
  return c.connection_id;
});
const conn2 = await asAdmin(t2, async () => {
  const [c] = await q("select * from cma.upsert_connection('hubspot', 'HubSpot email two', '9000202', $1, $2)",
    [`ingest-hubspot-email${RUN}-signing`, `ingest-hubspot-email${RUN}-token2`]);
  await q("select cma.set_connection_kind($1, 'crm')", [c.connection_id]);
  return c.connection_id;
});

// ---- Helpers -------------------------------------------------------------------------------------
const mark = () => fake.state.requests.length;
const since = (n) => fake.state.requests.slice(n);
const emails = (kind) => q(`select source_id, thread_source_id, inbox_source_id, channel_source_id, direction, status, actor_kind, owner_ref, category, contact_source_id, raw
  from cma.email_message where connection_id = $1 and source_kind = $2 order by source_id`, [conn1, kind]);
const threads = () => q(`select source_id, inbox_source_id, channel_source_id, status, closed_at is not null as closed, owner_ref, contact_source_id, ticket_source_id,
  is_spam, is_archived, category, forgotten_at is not null as forgotten from cma.email_thread where connection_id = $1 order by source_id`, [conn1]);
const threadOf = async (id) => (await threads()).find((t) => t.source_id === id);
const runs = () => q("select status, counts, error, from_at, to_at, stream from cma.sync_run where connection_id = $1 and job = $2 order by started_at", [conn1, "email_poll"]);
const auditCount = async () => Number((await q(`select count(*) as n from cma.audit_log where tenant_id = $1
  and table_name in ('email_message', 'email_thread', 'email_thread_event', 'crm_contact', 'crm_association', 'connection_inbox', 'connection_inbox_channel')`, [t1]))[0].n);
const cursorOf = async (stream) => (await q("select cursor from cma.sync_cursor where connection_id = $1 and stream = $2", [conn1, stream]))[0]?.cursor ?? null;
const poll = (now = NOW) => runPollEmail({ connectionId: conn1, now });

// ---- A. The first poll ------------------------------------------------------------------------------
let n0 = mark();
const p1 = await poll();
const r1 = await runs();
expect("A1 one email_poll run, succeeded, with counts", [r1.length, r1[0]?.status, r1[0]?.stream, r1[0]?.counts.upserted > 0], [1, "succeeded", "email", true], [0, "failed", null, false]);
const e1 = await emails("crm_email");
expect("A2 five engagements (an unknown direction skipped): direction, status, actor, owner, category, thread",
  e1.map((e) => [e.source_id, e.direction, e.status, e.actor_kind, e.owner_ref, e.category, e.thread_source_id]),
  [["4500000001", "out", "sent", "agent", "7100000001", "billing", "th-9000001"], ["4500000002", "in", "other", "customer", null, "partner", "th-9000001"],
    ["4500000003", "forwarded", "bounced", "agent", "7100000002", null, null], ["4500000004", "out", "sent", "system", null, "reminder", null],
    ["4500000006", "out", "scheduled", "unknown", null, "partner", null]], []);
expect("A3 each engagement's contact, and associations to contact, deal and ticket",
  [e1.map((e) => e.contact_source_id), (await q(`select from_id || '>' || to_type || ':' || to_id as a from cma.crm_association
    where connection_id = $1 and from_type = 'crm_email' and removed_at is null order by 1`, [conn1])).map((r) => r.a)],
  [["4300000101", "4300000102", "4300000101", "4300000101", null], ["4500000001>contact:4300000101", "4500000001>deal:4100000101", "4500000002>contact:4300000102",
    "4500000002>ticket:4200000101", "4500000003>contact:4300000101", "4500000004>contact:4300000101"]], [[], []]);
const th1 = await threads();
expect("A4 four threads: status, agent's owner id, contact, ticket, spam, the first message's category",
  th1.map((t) => [t.source_id, t.status, t.closed, t.owner_ref, t.contact_source_id, t.ticket_source_id, t.is_spam, t.category]),
  [["8800000001", "open", false, "7100000001", "4300000103", "4200000101", false, "billing"], ["8800000002", "closed", true, "7100000003", "4300000102", null, false, "partner"],
    ["8800000003", "open", false, null, null, null, true, "partner"], ["8800000004", "open", false, null, "4300000104", null, false, null]], []);
const m1 = await emails("inbox_message");
expect("A5 six inbox messages: direction, actor kind, owner, status, inbox from the channel account",
  m1.map((e) => [e.source_id.slice(0, 3), e.direction, e.actor_kind, e.owner_ref, e.status, e.inbox_source_id]),
  [["m1a", "in", "customer", null, "other", "1500000001"], ["m1d", "out", "agent", "7100000001", "sent", "1500000001"], ["m2a", "in", "customer", null, "other", "1500000002"],
    ["m3a", "in", "unknown", null, "other", "1500000001"], ["m4a", "in", "integration", null, "other", "1500000001"], ["m4d", "out", "agent", null, "failed", "1500000001"]], []);
expect("A6 seven events: assigned, moved, closed, reopened, with kinds and owner ids only",
  (await q(`select left(source_id, 3) as s, kind, actor_kind, owner_ref, to_actor_kind, to_owner_ref, from_inbox_source_id, to_inbox_source_id
    from cma.email_thread_event where connection_id = $1 order by source_id`, [conn1])).map((e) => Object.values(e)),
  [["m1b", "assigned", "system", null, "agent", "7100000001", null, null], ["m2b", "moved_inbox", "agent", "7100000002", null, null, "1500000001", "1500000002"],
    ["m2c", "assigned", "agent", "7100000002", "agent", "7100000003", null, null], ["m2e", "closed", "agent", "7100000003", null, null, null, null],
    ["m3b", "assigned", "bot", null, null, null, null, null], ["m4b", "closed", "agent", null, null, null, null, null], ["m4c", "reopened", "agent", null, null, null, null, null]], []);
expect("A7 contacts held after their emails and threads, every slot read: slot 2 through the alias, a value no market as written",
  (await q("select source_id, country, country_source from cma.crm_contact where connection_id = $1 order by source_id", [conn1])).map((c) => Object.values(c)),
  [["4300000101", "GB", 2], ["4300000102", "GB", 1], ["4300000103", "Atlantis", 2], ["4300000104", "GB", 1]], [["4300000199", "GB", 1]]);
expect("A8 the contact nothing points to was never read", since(n0).some((r) => r.path === "/crm/v3/objects/contacts/batch/read" && JSON.stringify(r.body).includes("4300000199")), false, true);
expect("A9 catalogs: inboxes (a name with an address replaced by its id), channels with kind and counted",
  [(await q("select source_inbox_id, name, status from cma.connection_inbox where connection_id = $1 order by 1", [conn1])).map((r) => Object.values(r)),
    (await q("select source_channel_id, kind, is_counted from cma.connection_inbox_channel where connection_id = $1 order by 1", [conn1])).map((r) => Object.values(r))],
  [[["1500000001", "Support inbox (test)", "active"], ["1500000002", "1500000002", "active"]], [["1000", "chat", false], ["1002", "email", true], ["1007", "whatsapp", false]]], [[], []]);
expect("A10 raw: codes only (direction, status, origin; type, status, client, truncation)", [...new Set((await q(`select jsonb_object_keys(raw) as k from cma.email_message
  where connection_id = $1`, [conn1])).map((r) => r.k))].sort(), ["clientType", "direction", "origin", "status", "statusType", "truncationStatus", "type"], ["subject"]);
expect("A11 the job's log line: counts and outcomes per kind, contacts inserted (none not_held: written after the emails)",
  (() => {
    const l = logs.map((x) => JSON.parse(x)).find((x) => x.message === "poll-email: connection");
    return [Boolean(l), l?.outcomes?.contacts?.inserted, l?.outcomes?.contacts?.not_held ?? 0, p1.connections];
  })(), [true, 4, 0, 1], [false, 0, 4, 0]);

// ---- B. Nothing changed, then one new message, then a 429 --------------------------------------------
let audit = await auditCount();
n0 = mark();
await poll(NOW + 60_000);
expect("B1 a second poll: no message read, no row written (no audit row)", [since(n0).filter((r) => r.path.endsWith("/messages")).length, (await auditCount()) - audit],
  [0, 0], [4, 10]);
const newAt = new Date(NOW + 90_000).toISOString();
source.messages["8800000001"].push({ type: "MESSAGE", id: "m1e0000000000000000000000000005", conversationsThreadId: "8800000001", createdAt: newAt,
  createdBy: "A-7000000002", direction: "OUTGOING", channelId: "1002", channelAccountId: "1600000001", subject: "Re: Invoice question INVENTED",
  text: "secret body text", status: { statusType: "SENT" } });
source.threads["8800000001"].latestMessageTimestamp = newAt;
source.threads["8800000001"].latestMessageSentTimestamp = newAt;
audit = await auditCount();
await poll(NOW + 120_000);
expect("B2 a new message: that message and the thread written, nothing else", [(await emails("inbox_message")).length, (await auditCount()) - audit,
  (await emails("inbox_message")).find((e) => e.source_id.startsWith("m1e"))?.owner_ref], [7, 2, "7100000002"], [6, 0, null]);
source.engagements["4500000003"] = { ...source.engagements["4500000003"], hs_email_status: "SENT", hs_lastmodifieddate: new Date(NOW + 150_000).toISOString() };
fake.state.failSearch = { status: 429 };
const engCursor = JSON.stringify(await cursorOf("email:engagements"));
const newAt2 = new Date(NOW + 160_000).toISOString();
source.messages["8800000004"].push({ type: "ASSIGNMENT", id: "m4e0000000000000000000000000005", conversationsThreadId: "8800000004", createdAt: newAt2,
  createdBy: "A-7000000001", assignedTo: "A-7000000001" });
source.threads["8800000004"].assignedTo = "A-7000000001";
source.threads["8800000004"].latestMessageTimestamp = newAt2;
await poll(NOW + 180_000);
const r3 = (await runs()).at(-1);
expect("B3 a 429 on the search: the run failed rate_limited, the engagements' cursor unchanged", [r3.status, r3.error, JSON.stringify(await cursorOf("email:engagements")) === engCursor],
  ["failed", "rate_limited", true], ["succeeded", null, false]);
expect("B4 …the conversations still ran: the new assignment and the thread's agent stored", [(await threadOf("8800000004")).owner_ref,
  Number((await q("select count(*) as n from cma.email_thread_event where connection_id = $1 and source_id like 'm4e%'", [conn1]))[0].n)], ["7100000001", 1], [null, 0]);
await poll(NOW + 200_000);
expect("B5 the next run reads the engagements from the kept cursor: the changed email updated", (await emails("crm_email")).find((e) => e.source_id === "4500000003").status, "sent", "bounced");

// ---- C. The open check -------------------------------------------------------------------------------
source.threads["8800000004"].status = "CLOSED";
source.threads["8800000004"].closedAt = new Date(NOW + 210_000).toISOString();
fake.state.gone.add("8800000001");
await poll(NOW + 11 * 60_000);
expect("C1 a thread closed at the source without a new message is stored closed", [(await threadOf("8800000004")).status, (await threadOf("8800000004")).closed], ["closed", true], ["open", false]);
const gone = await threadOf("8800000001");
expect("C2 a thread gone at the source is forgotten: no contact, no ticket; its messages lose their contact",
  [gone.forgotten, gone.contact_source_id, gone.ticket_source_id, (await emails("inbox_message")).filter((e) => e.source_id.startsWith("m1")).map((e) => e.contact_source_id)],
  [true, null, null, [null, null, null]], [false, "4300000103", "4200000101", ["4300000103", "4300000103", "4300000103"]]);

// ---- D. Reconcile --------------------------------------------------------------------------------------
// Modified now, inside the reconcile's look-back (which ends at the real clock)
source.engagements["4500000002"] = { ...source.engagements["4500000002"], hs_lastmodifieddate: new Date(Date.now() - 1000).toISOString(), hubspot_owner_id: "7100000002" };
audit = await auditCount();
await runReconcile({ connectionId: conn1, object: "crm_email", lookbackMinutes: 26 * 60 });
expect("D1 reconcile crm_email: only the email changed since is written again", [(await auditCount()) - audit,
  (await q("select status from cma.sync_run where connection_id = $1 and job = 'reconcile' and stream = 'crm_email'", [conn1]))[0]?.status], [1, "succeeded"], [6, "failed"]);
fake.state.archived.add("8800000002");
await runReconcile({ connectionId: conn1, object: "inbox_thread", lookbackMinutes: 26 * 60 });
expect("D2 reconcile inbox_thread: a held thread in the source's trash marked archived", (await threadOf("8800000002")).is_archived, true, false);
fake.state.archived.delete("8800000002");
fake.state.gone.add("8800000002");
await runReconcile({ connectionId: conn1, object: "inbox_thread", lookbackMinutes: 26 * 60 });
expect("D3 …and forgotten once it is gone from the trash too", [(await threadOf("8800000002")).forgotten, (await threadOf("8800000002")).contact_source_id], [true, null], [false, "4300000102"]);

// ---- E. Backfill ---------------------------------------------------------------------------------------
fake.state.failSearch = { status: 503, skip: 1 };
n0 = mark();
const b1 = await runBackfill({ connectionId: conn1, object: "crm_email" });
const bRun = (await q("select status, error, from_at from cma.sync_run where connection_id = $1 and job = 'backfill' and stream = 'crm_email' order by started_at", [conn1]));
const [{ startAt }] = await q("select ($1::date::timestamp at time zone 'Europe/Amsterdam') as \"startAt\"", [START]);
expect("E1 backfill crm_email from cma.email_start_date_of; interrupted on its second page", [b1.from, bRun[0]?.status, bRun[0]?.error, new Date(bRun[0]?.from_at).getTime() === new Date(startAt).getTime()],
  [START, "failed", "http_503", true], [null, "succeeded", null, false]);
const kept = await cursorOf("backfill:crm_email:hs_timestamp");
n0 = mark();
const b2 = await runBackfill({ connectionId: conn1, object: "crm_email" });
const firstGte = Number(since(n0).find((r) => r.path.endsWith("/emails/search"))?.body.filterGroups[0].filters[0].value);
expect("E2 the rerun resumes at the kept value, not the start, and finds the email older than the poll's window",
  [b2.error, firstGte === kept?.value && firstGte > new Date(startAt).getTime(), (await emails("crm_email")).some((e) => e.source_id === "4500000007")], [null, true, true], ["x", false, false]);
await runBackfill({ connectionId: conn1, object: "inbox_thread" });
expect("E3 backfill inbox_thread: the thread older than the poll's window with its message", [(await threadOf("8800000006"))?.status, (await emails("inbox_message")).some((e) => e.source_id.startsWith("m6a"))],
  ["closed", true], [undefined, false]);
source.contacts["4300000101"] = { ...source.contacts["4300000101"], contact_country: "GB", lastmodifieddate: new Date(NOW + 13 * 60_000).toISOString() };
await runBackfill({ connectionId: conn1, object: "contact" });
expect("E4 backfill contact: held contacts read again with every slot (slot 1 now filled)", (await q("select country, country_source from cma.crm_contact where connection_id = $1 and source_id = '4300000101'", [conn1]))[0],
  { country: "GB", country_source: 1 }, { country: "GB", country_source: 2 });

// ---- F. The shared rule fixtures in the database ----------------------------------------------------------
const dbWords = [];
for (const c of RULES.words) dbWords.push((await q("select cma.email_words_match($1, $2, $3) as m", [c.value, c.words, c.exclude]))[0].m);
expect(`F1 cma.email_words_match on the ${RULES.words.length} shared cases: the expected answers, as the ingest's`, [dbWords, RULES.words.map((c) => wordsMatch(c.value, c.words, c.exclude))],
  [RULES.words.map((c) => c.match), RULES.words.map((c) => c.match)], [RULES.words.map((c) => !c.match), RULES.words.map((c) => !c.match)]);
const dbCats = [];
for (const c of RULES.categories) dbCats.push((await q("select cma.email_category_of($1, $2, $3, $4) as c", [t1, conn1, c.senderDomain, c.subject]))[0].c);
const config = await asAdmin(t1, async () => (await q("select cma.connection_config($1) as c", [conn1]))[0].c);
expect(`F2 cma.email_category_of on the ${RULES.categories.length} shared cases: the expected categories, as the ingest's`,
  [dbCats, RULES.categories.map((c) => classify({ subject: c.subject, senderDomain: c.senderDomain }, activeRules(config)))],
  [RULES.categories.map((c) => c.category), RULES.categories.map((c) => c.category)], [RULES.categories.map(() => "x"), RULES.categories.map(() => "x")]);

// ---- G. Opt-in and isolation -------------------------------------------------------------------------------
// Each poll names its connection: one without would serve every connection of the database with email_poll on (B17b.1)
const off = await runPollEmail({ connectionId: conn2, now: NOW + 14 * 60_000 });
const on = await runPollEmail({ connectionId: conn1, now: NOW + 14 * 60_000 });
expect("G1 a connection without email_poll is never served (no run, no row); one with it is", [off.connections,
  Number((await q("select count(*) as n from cma.sync_run where connection_id = $1 and job = 'email_poll'", [conn2]))[0].n),
  Number((await q("select count(*) as n from cma.email_message where connection_id = $1", [conn2]))[0].n), on.connections], [0, 0, 0, 1], [1, 1, 1, 0]);
expect("G2 tenant two sees none of tenant one's email rows", await asAdmin(t2, async () => [
  Number((await q("select count(*) as n from cma.email_message"))[0].n), Number((await q("select count(*) as n from cma.email_thread"))[0].n)]), [0, 0], [6, 4]);
expect("G3 every email row of the run lives in tenant one", [...new Set((await q("select tenant_id from cma.email_message where connection_id = $1 union select tenant_id from cma.email_thread where connection_id = $1", [conn1])).map((r) => r.tenant_id))],
  [t1], [t2]);

// ---- H. What was written and logged -----------------------------------------------------------------------
const dbText = JSON.stringify(await q(`select row_to_json(x)::text as r from cma.email_message x where connection_id = $1
  union all select row_to_json(x)::text from cma.email_thread x where connection_id = $1
  union all select row_to_json(x)::text from cma.email_thread_event x where connection_id = $1
  union all select row_to_json(x)::text from cma.connection_inbox x where connection_id = $1
  union all select row_to_json(x)::text from cma.connection_inbox_channel x where connection_id = $1
  union all select row_to_json(x)::text from cma.crm_contact x where connection_id = $1
  union all select row_to_json(x)::text from cma.crm_association x where connection_id = $1
  union all select row_to_json(x)::text from cma.sync_cursor x where connection_id = $1
  union all select row_to_json(x)::text from cma.sync_run x where connection_id = $1
  union all select coalesce(old_row::text, '') || coalesce(new_row::text, '') from cma.audit_log x where tenant_id = $2
    and table_name in ('email_message', 'email_thread', 'email_thread_event', 'connection_inbox', 'connection_inbox_channel', 'crm_contact', 'crm_association')`, [conn1, t1]));
expect("H1 no row, audit image, cursor or run holds a name, address, subject, text or raw actor id", source.forbidden.filter((f) => dbText.includes(f)), [], ["x"]);
const logText = logs.join("\n");
expect("H2 no log line holds them, a token, or an email, thread or contact id",
  [source.forbidden.filter((f) => logText.includes(f)), /fixture-email-token/.test(logText), /45000000\d\d|88000000\d\d|43000001\d\d/.test(logText)], [[], false, false], [["x"], true, true]);

// This run's connections stop being served
await asAdmin(t1, () => q("select cma.set_connection_status($1, 'inactive')", [conn1]));
await asAdmin(t2, () => q("select cma.set_connection_status($1, 'inactive')", [conn2]));

// ---- I. Nothing outside this run's tenants -----------------------------------------------------------------
expect("I1 no row of another tenant written by this run (sync_run, email_*, crm_contact, sync_cursor, any audited table)",
  await writesOutside(q, { tenants: [t1, t2], since: STARTED, logins: [process.env.CMA_DB_USER, ADMIN] }), [], ["sync_run:2"]);

// ---- J. The run's own tenants removed -------------------------------------------------------------------
expect("J1 the run's two tenants removed with every row they held (no table holds their ids)",
  await removeTenants(q, [t1, t2]).catch((e) => [`refused: ${e.message}`]), [], ["tenant:2"]);
await admin.end();
await fake.close();
await closeDb();
rmSync(secretsDir, { recursive: true, force: true });
verdict();
