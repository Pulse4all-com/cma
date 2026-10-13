/**
 * Verifier: the Aircall adapter end to end (brief B9), against a local PostgreSQL with db/00…55 and a
 * fake Aircall API. Everything is invented: tenants, companies, ids, tokens, emails (example.com) and
 * numbers in the +44 20 0000 0xxx range.
 *
 *   CMA_DB_HOST=/tmp CMA_DB_PORT=5432 CMA_DB_NAME=cma CMA_DB_USER=cma-ingest@local.iam \
 *   INGEST_FLOW_ADMIN_USER=martin@pulse4all.com node verify/aircall-flow.mjs [--provoke]
 *
 * Logins as in verify/flow.mjs: CMA_DB_USER is the service's (a member of cma_app), the admin login
 * creates two throwaway tenants per run (aircall-<run>-one, aircall-<run>-two) with their connections
 * and reads as the owner. The service and the jobs run in this process, the jobs with their
 * connection filter; at the end this run's connections are set inactive, so a later run's unfiltered
 * sweep leaves them alone.
 *
 * Proves: the route (unknown key, another adapter's key, a wrong token, a token of another length, no
 * token, a body that is not JSON: 404 or 401, nothing written, nothing asked of Aircall); the six
 * events recorded and read back into telephony_call with its tags opened and closed, the catalogs on
 * the first event, an unhandled event ignored without a read, a duplicate written once; out-of-order
 * events ending in the right state (read-back and, in replay, the stale guard); replay honoured only
 * with INGEST_ALLOW_REPLAY=1; five events of one call read once by the sweep; a 429 leaving the events
 * failed with backoff and holding further calls, no retry in a loop; the hash's default region from
 * the line's market, else the tenant's first active market; a line switched off losing its call, a
 * later call on it not stored (0008f; a backfill counts it skipped); the catalogs kept configured and
 * refreshed at most hourly; link_calls pairing with a seeded CRM call; the reconcile picking up a
 * missed call from the listing alone (no second read), reading an unchanged call once, splitting a
 * window over the 10,000 cap, and its webhook check (not set, missing, another token, inactive and
 * re-activated, re-activation refused, active); the account check of the jobs; the backfill resuming
 * after a failure and paced by aircall_max_per_minute; tenant isolation; no number, name, email,
 * comment, link or token in the database or the logs.
 */
import http from "node:http";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { createHmac, randomBytes } from "node:crypto";
import pg from "pg";
import { expect, verdict, PROVOKE } from "./lib.mjs";

console.log(`verify/aircall-flow.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

for (const v of ["CMA_DB_HOST", "CMA_DB_USER"]) {
  if (!process.env[v]) {
    console.error(`${v} is required (a local PostgreSQL with db/00…55; see the header)`);
    process.exit(2);
  }
}
const ADMIN = process.env.INGEST_FLOW_ADMIN_USER ?? "martin@pulse4all.com";
const RUN = randomBytes(4).toString("hex");
const SLUG1 = `aircall-${RUN}-one`;
const SLUG2 = `aircall-${RUN}-two`;
const PEPPER1 = "fixture-pepper-aircall-one-0000000";
const PEPPER2 = "fixture-pepper-aircall-two-0000000";
const TOKEN_A = "fixture-aircall-webhook-token-a-0001";
const TOKEN_B = "fixture-aircall-webhook-token-b-0002";
const TOKEN_R = "fixture-aircall-webhook-token-r-0003";
const CRED_A = { api_id: `flow-a-${RUN}`, api_token: "fixture-aircall-api-token-a" };
const CRED_R = { api_id: `flow-r-${RUN}`, api_token: "fixture-aircall-api-token-r" };
const CRED_B = { api_id: `flow-b-${RUN}`, api_token: "fixture-aircall-api-token-b" };
const COMPANY = "Flow Company";
const COMPANY_TWO = "Flow Company Two";
// The other parties' numbers (never stored) and the company's own lines (stored as lines)
const CUSTOMER = ["+44 20 0000 0001", "020 0000 0002", "020 0000 0003", "+44 20 0000 0004", "+44 20 0000 0005"];
const LINE_GB = "+44 20 0000 0900";
const LINE_X = "+44 20 0000 0901";

// ---- Secrets, as files (INGEST_SECRETS_DIR) ------------------------------------------------------
const secretsDir = mkdtempSync(path.join(tmpdir(), "aircall-flow-"));
const putSecret = (name, value) => writeFileSync(path.join(secretsDir, name), value);
putSecret(`ingest-aircall-${RUN}-a-signing`, TOKEN_A);
putSecret(`ingest-aircall-${RUN}-a-token`, JSON.stringify(CRED_A));
putSecret(`ingest-aircall-${RUN}-r-signing`, TOKEN_R);
putSecret(`ingest-aircall-${RUN}-r-token`, JSON.stringify(CRED_R));
putSecret(`ingest-aircall-${RUN}-b-signing`, TOKEN_B);
putSecret(`ingest-aircall-${RUN}-b-token`, JSON.stringify(CRED_B));
putSecret(`ingest-hash-pepper-${SLUG1}`, PEPPER1);
putSecret(`ingest-hash-pepper-${SLUG2}`, PEPPER2);
const basic = (c) => `Basic ${Buffer.from(`${c.api_id}:${c.api_token}`).toString("base64")}`;
const AUTH_A = basic(CRED_A);
const AUTH_R = basic(CRED_R);
const AUTH_B = basic(CRED_B);

// ---- The fake Aircall API ---------------------------------------------------------------------------
const nowS = () => Math.floor(Date.now() / 1000);
const S0 = nowS() - 600; // the lifecycle call started ten minutes ago (link_calls looks two hours back)
const userOf = (id) => ({ id, direct_link: `https://api.example.com/v1/users/${id}`, name: "Invented Agent", email: "agent.one@example.com", available: true });
const lineOf = (id, digits, name) => ({ id, direct_link: `https://api.example.com/v1/numbers/${id}`, name, digits, country: "GB", time_zone: "Europe/London" });
function makeCall(id, o = {}) {
  return {
    id, direct_link: `https://api.example.com/v1/calls/${id}`, sid: `CAfixture${id}`, direction: "outbound", status: "initial",
    started_at: S0, answered_at: null, ended_at: null, duration: 0, raw_digits: CUSTOMER[4], missed_call_reason: null, archived: false,
    cost: "0.0", asset: null, recording: null, recording_short_url: null, voicemail: null, voicemail_short_url: null,
    user: userOf(9200000001), number: lineOf(9300000001, LINE_GB, "Test line GB"),
    contact: { id: 9500000001, first_name: "Invented", last_name: "Customer", phone_numbers: [{ label: "Mobile", value: o.raw_digits ?? CUSTOMER[4] }], emails: [{ label: "Work", value: "customer@example.com" }] },
    assigned_to: null, teams: [], comments: [], tags: [], participants: [{ id: 1, name: "Invented Customer", type: "external" }],
    ...o,
  };
}
const TAG_A = { id: 9400000001, name: "Interested", color: "#00B388", tagged_by: userOf(9200000001) };
const TAG_B = { id: 9400000002, name: "Call back", color: "#FFAA00", tagged_by: userOf(9200000001) };
const fake = {
  mode: "ok", resetIn: 5, putFails: false, bigWindow: false, listFailFromS: null, requests: [],
  calls: {},
  numbers: [lineOf(9300000001, LINE_GB, "Test line GB"), lineOf(9300000002, LINE_X, "Test line two")],
  tags: [TAG_A, TAG_B].map(({ id, name, color }) => ({ id, name, color, description: "invented" })),
  webhooks: [],
  companies: { [AUTH_A]: COMPANY, [AUTH_R]: COMPANY, [AUTH_B]: COMPANY_TWO },
};
const json = (res, status, body, headers = {}) => {
  res.writeHead(status, { "content-type": "application/json", ...headers });
  res.end(body === null ? "" : JSON.stringify(body));
};
const paged = (list, url, key) => {
  const per = Number(url.searchParams.get("per_page") ?? 20);
  const page = Number(url.searchParams.get("page") ?? 1);
  const part = list.slice((page - 1) * per, page * per);
  const next = page * per < list.length ? `https://api.example.com${url.pathname}?page=${page + 1}&per_page=${per}` : null;
  return { [key]: part, meta: { count: part.length, total: list.length, current_page: page, per_page: per, next_page_link: next, previous_page_link: null } };
};
const fakeServer = http.createServer((req, res) => {
  let data = "";
  req.on("data", (c) => { data += c; });
  req.on("end", () => {
    const url = new URL(req.url, "http://x");
    const r = { method: req.method, path: url.pathname, query: Object.fromEntries(url.searchParams), auth: req.headers.authorization, body: data ? JSON.parse(data) : null, t: Date.now() };
    fake.requests.push(r);
    if (!fake.companies[r.auth]) return json(res, 401, { error: "Unauthorized" });
    if (fake.mode === "down") return json(res, 503, { error: "Service unavailable" });
    if (fake.mode === "429") {
      return json(res, 429, { error: "Too Many Requests" }, { "x-aircallapi-limit": "120", "x-aircallapi-remaining": "0", "x-aircallapi-reset": String(nowS() + fake.resetIn) });
    }
    let m;
    if (url.pathname === "/v1/company") return json(res, 200, { company: { name: fake.companies[r.auth], id: null, users_count: 3, numbers_count: 2 } });
    if ((m = /^\/v1\/calls\/(\d+)$/.exec(url.pathname)) && req.method === "GET") {
      const c = fake.calls[m[1]];
      return c ? json(res, 200, { call: c }) : json(res, 404, { error: "Not found" });
    }
    if (url.pathname === "/v1/calls" && req.method === "GET") {
      const from = Number(url.searchParams.get("from"));
      const to = Number(url.searchParams.get("to"));
      if (fake.listFailFromS !== null && from >= fake.listFailFromS) return json(res, 503, { error: "Service unavailable" });
      const list = Object.values(fake.calls).filter((c) => c.started_at >= from && c.started_at <= to).sort((a, b) => a.started_at - b.started_at || a.id - b.id);
      const body = paged(list, url, "calls");
      if (fake.bigWindow && to - from > 13 * 3600) body.meta.total = 10_001;
      return json(res, 200, body);
    }
    if (url.pathname === "/v1/numbers") return json(res, 200, paged(fake.numbers, url, "numbers"));
    if (url.pathname === "/v1/tags") return json(res, 200, paged(fake.tags, url, "tags"));
    if (url.pathname === "/v1/webhooks" && req.method === "GET") return json(res, 200, paged(fake.webhooks, url, "webhooks"));
    if ((m = /^\/v1\/webhooks\/([\w-]+)$/.exec(url.pathname)) && req.method === "PUT") {
      const w = fake.webhooks.find((x) => x.webhook_id === m[1]);
      if (!w) return json(res, 404, { error: "Not found" });
      if (fake.putFails) return json(res, 500, { error: "Internal" });
      Object.assign(w, r.body.active === undefined ? {} : { active: r.body.active }, r.body.events ? { events: r.body.events } : { events: ["all"] });
      return json(res, 200, { webhook: w });
    }
    json(res, 404, { error: "Not found" });
  });
});
await new Promise((r) => fakeServer.listen(0, "127.0.0.1", r));

// ---- The service and the jobs, in this process ------------------------------------------------------
process.env.INGEST_SECRETS_DIR = secretsDir;
process.env.INGEST_AIRCALL_API_BASE = `http://127.0.0.1:${fakeServer.address().port}`;
process.env.INGEST_PACE_FACTOR = "0.01";
delete process.env.INGEST_ALLOW_REPLAY;
const logs = [];
const { setLogSink } = await import("../src/core/log.mjs");
setLogSink((line) => logs.push(line));
const { createIngestServer } = await import("../src/server.mjs");
const { runSweep } = await import("../src/jobs/sweep.mjs");
const { runReconcile } = await import("../src/jobs/reconcile.mjs");
const { runBackfill } = await import("../src/jobs/backfill.mjs");
const { hashNumber } = await import("../src/core/hash.mjs");
const { closeDb } = await import("../src/core/db.mjs");
const service = createIngestServer();
await new Promise((r) => service.listen(0, "127.0.0.1", r));
const BASE = `http://127.0.0.1:${service.address().port}`;

// ---- Setup as the admin login --------------------------------------------------------------------
const admin = new pg.Client({ host: process.env.CMA_DB_HOST, port: Number(process.env.CMA_DB_PORT ?? 5432), database: process.env.CMA_DB_NAME ?? "cma",
  user: ADMIN, password: process.env.CMA_DB_PASSWORD || undefined });
await admin.connect();
const q = async (text, values) => (await admin.query(text, values)).rows;
await q("set role cma_owner");
const [{ t1 }] = await q("select cma.create_tenant($1, 'Aircall flow one', 'Europe/Amsterdam') as t1", [SLUG1]);
const [{ t2 }] = await q("select cma.create_tenant($1, 'Aircall flow two', 'Europe/Amsterdam') as t2", [SLUG2]);
const adminOf = {};
const ingestOf = {};
for (const t of [t1, t2]) {
  const [{ id }] = await q("insert into cma.app_user (tenant_id, email, display_name) values ($1, 'flow-admin@example.invalid', 'Flow admin') returning id", [t]);
  await q("insert into cma.user_role (tenant_id, user_id, role_id) select $1, $2, id from cma.app_role where tenant_id = $1 and key = 'admin'", [t, id]);
  adminOf[t] = id;
  ingestOf[t] = (await q("select user_id from cma.app_user_external_id where tenant_id = $1 and system = 'ingest' and external_id = 'ingest'", [t]))[0].user_id;
}
async function as(tenant, userId, fn) {
  await q("begin");
  await q("set local role cma_app");
  await q("select set_config('app.tenant_id', $1, true), set_config('app.user_id', $2, true), set_config('app.actor_label', 'verify:aircall-flow', true)", [tenant, userId]);
  try {
    const r = await fn();
    await q("commit");
    return r;
  } catch (e) {
    await q("rollback");
    throw e;
  }
}
const asAdmin = (tenant, fn) => as(tenant, adminOf[tenant], fn);
const conn = await asAdmin(t1, async () => {
  await q("select cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', null, null, 10)");
  await q("select cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', null, null, 20)");
  const up = async (name, account, slot) => (await q("select * from cma.upsert_connection('aircall', $1, $2, $3, $4)",
    [name, account, `ingest-aircall-${RUN}-${slot}-signing`, `ingest-aircall-${RUN}-${slot}-token`]))[0];
  const a = await up("Aircall flow A", COMPANY, "a");
  const r = await up("Aircall flow replay", "Replay Company", "r");
  const m = await up("Aircall flow mismatch", "Another Company", "a");
  await q("select cma.set_connection_settings($1, '{\"replay\": true}'::jsonb)", [r.connection_id]);
  const [h] = await q("select * from cma.upsert_connection('hubspot', 'HubSpot flow', $1, null, null)", [`9${RUN.replace(/\D/g, "1").slice(0, 6)}`]);
  return { a: a.connection_id, aKey: a.key, r: r.connection_id, rKey: r.key, m: m.connection_id, h: h.connection_id, hKey: h.key };
});
const connB = await asAdmin(t2, async () => {
  const [b] = await q("select * from cma.upsert_connection('aircall', 'Aircall flow B', $1, $2, $3)", [COMPANY_TWO, `ingest-aircall-${RUN}-b-signing`, `ingest-aircall-${RUN}-b-token`]);
  return { b: b.connection_id, bKey: b.key };
});
const setSettings = (connectionId, settings, tenant = t1) => asAdmin(tenant, () => q("select cma.set_connection_settings($1, $2::jsonb)", [connectionId, JSON.stringify(settings)]));

// ---- Helpers -------------------------------------------------------------------------------------
async function post(key, payload, { token = TOKEN_A, raw = null, route = "aircall" } = {}) {
  const body = raw ?? JSON.stringify(token === null ? payload : { ...payload, token });
  const res = await fetch(`${BASE}/${route}/${key}`, { method: "POST", headers: { "content-type": "application/json" }, body });
  const text = await res.text();
  return { status: res.status, body: text };
}
const event = (name, call, ts) => ({ resource: "call", event: name, timestamp: ts, data: call });
const count = async (table, c = conn.a) => Number((await q(`select count(*) as n from cma.${table} where connection_id = $1`, [c]))[0].n);
const eventOf = async (key, c = conn.a) => (await q("select status, error, attempts, next_attempt_at > now() as later, raw from cma.ingest_event where connection_id = $1 and event_key = $2", [c, key]))[0] ?? null;
const callRow = async (id, c = conn.a) => (await q(`select status, direction, missed_reason, started_at, answered_at, ended_at, duration_seconds, talk_seconds, user_ref, number_ref,
  counterpart_hash, is_archived, source_version_at, raw from cma.telephony_call where connection_id = $1 and source_id = $2`, [c, String(id)]))[0] ?? null;
const openTags = async (id, c = conn.a) => (await q("select tag_ref from cma.telephony_call_tag where connection_id = $1 and call_source_id = $2 and untagged_at is null order by tag_ref", [c, String(id)])).map((r) => r.tag_ref);
const closedTags = async (id, c = conn.a) => (await q("select tag_ref from cma.telephony_call_tag where connection_id = $1 and call_source_id = $2 and untagged_at is not null order by tag_ref", [c, String(id)])).map((r) => r.tag_ref);
const reads = (id, since = 0, auth = null) => fake.requests.filter((r) => r.path === `/v1/calls/${id}` && r.t >= since && (!auth || r.auth === auth)).length;
const mark = () => Date.now();
const H = (pepper, e164) => createHmac("sha256", pepper).update(e164).digest("hex");
const iso = (s) => new Date(s * 1000).toISOString();
const forceDue = (c, objectId) => q("update cma.ingest_event set next_attempt_at = now() where connection_id = $1 and object_id = $2 and status = 'failed'", [c, String(objectId)]);
const runs = async (c, job) => q("select stream, status, error, counts from cma.sync_run where connection_id = $1 and job = $2 order by started_at", [c, job]);

// ---- A. The route and its authentication ----------------------------------------------------------
const C1 = 9100000001;
const c1 = (o = {}) => makeCall(C1, { raw_digits: CUSTOMER[0], ...o }); // the one call on this number: the link below pairs it
fake.calls[C1] = c1();
const created = event("call.created", fake.calls[C1], S0 + 1);
expect("an unknown key → 404", (await post("k".repeat(32), created)).status, 404, 200);
expect("the HubSpot connection's key on /aircall → 404", (await post(conn.hKey, created)).status, 404, 200);
expect("the Aircall connection's key on /hubspot → 404", (await post(conn.aKey, created, { route: "hubspot" })).status, 404, 200);
expect("no token → 401", (await post(conn.aKey, created, { token: null })).status, 401, 200);
expect("a wrong token of the same length → 401", (await post(conn.aKey, created, { token: TOKEN_A.replace(/1$/, "9") })).status, 401, 200);
expect("a token of another length → 401", (await post(conn.aKey, created, { token: `${TOKEN_A}0` })).status, 401, 200);
expect("another connection's token (replay) → 401", (await post(conn.aKey, created, { token: TOKEN_R })).status, 401, 200);
expect("a body that is not JSON → 401", (await post(conn.aKey, null, { raw: `token=${TOKEN_A}` })).status, 401, 200);
expect("refused requests wrote nothing", await count("ingest_event"), 0, 1);
expect("…and asked Aircall nothing", fake.requests.length, 0, 1);
expect("…and answered with an empty body", (await post(conn.aKey, created, { token: "x" })).body, "", "unauthorized");

// ---- B. The six events of one call, read back ------------------------------------------------------
let t0 = mark();
expect("call.created → 200", (await post(conn.aKey, created)).status, 200, 401);
let row = await callRow(C1);
expect("…recorded and processed", (await eventOf(`ac:call.created:${C1}:${S0 + 1}`))?.status, "processed", "received");
expect("…the call: outbound, initial, started, user and line as ids", [row?.direction, row?.status, row?.started_at?.toISOString(), row?.user_ref, row?.number_ref], ["outbound", "initial", iso(S0), "9200000001", "9300000001"], []);
expect("…its counterpart as HMAC(pepper, E.164)", row?.counterpart_hash, H(PEPPER1, "+442000000001"), null);
expect("…one read of /v1/calls/{id} with the connection's Basic auth", [reads(C1, t0), fake.requests.filter((r) => r.t >= t0).every((r) => r.auth === AUTH_A)], [1, true], [2, true]);
expect("the first event of a connection without lines read the catalogs", [await count("telephony_number"), await count("telephony_tag")], [2, 2], [0, 0]);
const lines = await q("select number_ref, name, digits, market, is_counted, status from cma.telephony_number where connection_id = $1 order by number_ref", [conn.a]);
expect("…lines with name and the company's own digits, no market yet, counted", lines.map((l) => [l.number_ref, l.digits, l.market, l.is_counted]), [["9300000001", "+442000000900", null, true], ["9300000002", "+442000000901", null, true]], []);

fake.calls[C1] = c1({ status: "answered", answered_at: S0 + 8 });
await post(conn.aKey, event("call.answered", fake.calls[C1], S0 + 9));
expect("call.answered → answered at", (await callRow(C1))?.answered_at?.toISOString(), iso(S0 + 8), null);
fake.calls[C1] = c1({ status: "answered", answered_at: S0 + 8, tags: [TAG_A, TAG_B] });
await post(conn.aKey, event("call.tagged", fake.calls[C1], S0 + 40));
expect("call.tagged → both tags open", await openTags(C1), ["9400000001", "9400000002"], []);
fake.calls[C1] = c1({ status: "answered", answered_at: S0 + 8, tags: [TAG_A] });
await post(conn.aKey, event("call.untagged", fake.calls[C1], S0 + 50));
expect("call.untagged → the removed tag closed, the other open", [await openTags(C1), await closedTags(C1)], [["9400000001"], ["9400000002"]], [["9400000001", "9400000002"], []]);
const ENDED = { status: "done", answered_at: S0 + 8, ended_at: S0 + 71, duration: 71, tags: [TAG_A], recording: "https://recordings.example.com/0001.mp3",
  asset: "https://assets.example.com/0001", voicemail: "https://voicemail.example.com/0001", comments: [{ id: 1, content: "free text that must not be stored", posted_at: S0 + 90 }] };
fake.calls[C1] = c1(ENDED);
await post(conn.aKey, event("call.ended", fake.calls[C1], S0 + 101));
row = await callRow(C1);
expect("call.ended → done, ended at, duration 71, talk 63 seconds", [row?.status, row?.ended_at?.toISOString(), row?.duration_seconds, row?.talk_seconds], ["done", iso(S0 + 71), 71, 63], ["answered", null, 0, null]);
fake.calls[C1] = c1({ ...ENDED, archived: true });
await post(conn.aKey, event("call.archived", fake.calls[C1], S0 + 120));
expect("call.archived → archived", (await callRow(C1))?.is_archived, true, false);
expect("the six events: six rows, all processed", (await q("select status, count(*)::int as n from cma.ingest_event where connection_id = $1 group by 1", [conn.a])), [{ status: "processed", n: 6 }], [{ status: "processed", n: 5 }]);
expect("raw holds the allowlisted keys only", Object.keys((await callRow(C1))?.raw ?? {}).sort(), ["answered_at", "archived", "direction", "duration", "ended_at", "started_at", "status"], ["recording"]);
t0 = mark();
expect("the same delivery again (Aircall retries) → 200", (await post(conn.aKey, event("call.archived", fake.calls[C1], S0 + 120))).status, 200, 500);
expect("…still six events, no second read", [await count("ingest_event"), reads(C1, t0)], [6, 0], [7, 1]);

// ---- C. Events the CMA does not handle ----------------------------------------------------------------
t0 = mark();
const hungup = await post(conn.aKey, event("call.hungup", fake.calls[C1], S0 + 70));
const userEvent = await post(conn.aKey, { resource: "user", event: "user.created", timestamp: S0 + 200, data: { id: 9200000009, name: "Invented New Agent", email: "agent.nine@example.com" } });
const contactEvent = await post(conn.aKey, { resource: "contact", event: "contact.created", timestamp: S0 + 201, data: { id: 9500000002, first_name: "Invented", phone_numbers: [{ value: CUSTOMER[4] }], emails: [{ value: "c2@example.com" }] } });
expect("call.hungup, user.created, contact.created → 200", [hungup.status, userEvent.status, contactEvent.status], [200, 200, 200], [401, 401, 401]);
const ignored = await q("select event_key, status, raw ->> 'ignored' as why from cma.ingest_event where connection_id = $1 and status = 'ignored' order by event_key", [conn.a]);
expect("…recorded as ignored, event_not_handled", ignored.map((r) => `${r.event_key.split(":")[1]}:${r.why}`), ["call.hungup:event_not_handled", "contact.created:event_not_handled", "user.created:event_not_handled"], []);
expect("…and nothing asked of Aircall", fake.requests.filter((r) => r.t >= t0).length, 0, 1);

// ---- D. Out of order ------------------------------------------------------------------------------------
const C2 = 9100000002;
fake.calls[C2] = makeCall(C2, { ...ENDED, started_at: S0 + 5 });
await post(conn.aKey, event("call.ended", fake.calls[C2], S0 + 106));
await post(conn.aKey, event("call.answered", fake.calls[C2], S0 + 14));
row = await callRow(C2);
expect("read-back: call.ended before call.answered still ends done with both times", [row?.status, row?.answered_at?.toISOString(), row?.ended_at?.toISOString()], ["done", iso(S0 + 8), iso(S0 + 71)], ["answered", iso(S0 + 8), null]);

// Replay (dev): the event's own object, the stale guard on the event's time
process.env.INGEST_ALLOW_REPLAY = "1";
const C3 = 9100000003;
t0 = mark();
const replayEnded = makeCall(C3, { ...ENDED, started_at: S0 + 10 });
const replayAnswered = makeCall(C3, { status: "answered", started_at: S0 + 10, answered_at: S0 + 18 });
expect("replay: call.ended on the replay connection → 200", (await post(conn.rKey, event("call.ended", replayEnded, S0 + 111), { token: TOKEN_R })).status, 200, 401);
expect("replay: call.answered arriving after it → 200", (await post(conn.rKey, event("call.answered", replayAnswered, S0 + 19), { token: TOKEN_R })).status, 200, 401);
row = await callRow(C3, conn.r);
expect("…the older event is stale: the call stays done, versioned at the ended event", [row?.status, row?.ended_at?.toISOString(), row?.source_version_at?.toISOString()], ["done", iso(S0 + 71), iso(S0 + 111)], ["answered", null, iso(S0 + 19)]);
expect("…both events processed", (await q("select count(*)::int as n from cma.ingest_event where connection_id = $1 and status = 'processed'", [conn.r]))[0].n, 2, 1);
expect("…and nothing asked of Aircall (no read, no catalog)", fake.requests.filter((r) => r.t >= t0).length, 0, 1);
expect("…the hash made from the event's own number", row?.counterpart_hash, H(PEPPER1, "+442000000005"), null);

// ---- E. Replay ignored without INGEST_ALLOW_REPLAY (a prod-configured service) -----------------------
delete process.env.INGEST_ALLOW_REPLAY;
const C4 = 9100000004;
fake.calls[C4] = makeCall(C4, { ...ENDED, started_at: S0 + 20 });
t0 = mark();
await post(conn.rKey, event("call.ended", makeCall(C4, { status: "answered", started_at: S0 + 20, answered_at: S0 + 28 }), S0 + 121), { token: TOKEN_R });
expect("without the variable the replay setting is ignored: the call read from the API", [reads(C4, t0, AUTH_R), (await callRow(C4, conn.r))?.status], [1, "done"], [0, "answered"]);

// ---- F. Five events of one call → one read in the sweep --------------------------------------------------
const C5 = 9100000005;
fake.calls[C5] = makeCall(C5, { ...ENDED, started_at: S0 + 30 });
fake.mode = "down";
for (const [name, ts] of [["call.created", 31], ["call.answered", 39], ["call.tagged", 60], ["call.untagged", 61], ["call.ended", 131]]) {
  await post(conn.aKey, event(name, fake.calls[C5], S0 + ts));
}
const failedC5 = await q("select status, error, later from (select status, error, next_attempt_at > now() as later from cma.ingest_event where connection_id = $1 and object_id = $2) x", [conn.a, String(C5)]);
expect("Aircall down: the five events failed with http_503, retried later", [failedC5.length, failedC5.every((e) => e.status === "failed" && e.error === "http_503" && e.later)], [5, true], [5, false]);
fake.mode = "ok";
await forceDue(conn.a, C5);
t0 = mark();
const sweep1 = await runSweep({ connectionId: conn.a });
expect("the sweep claims the five and reads the call once", [sweep1.processed, reads(C5, t0)], [5, 1], [5, 5]);
expect("…the call is done with its tag", [(await callRow(C5))?.status, await openTags(C5)], ["done", ["9400000001"]], ["initial", []]);

// ---- G. A 429: the events fail, further calls wait for Aircall's reset, nothing retries in a loop ----
const C6 = 9100000006;
const C7 = 9100000007;
fake.calls[C6] = makeCall(C6, { ...ENDED, started_at: S0 + 40 });
fake.calls[C7] = makeCall(C7, { ...ENDED, started_at: S0 + 50 });
fake.mode = "429";
fake.resetIn = 5;
t0 = mark();
const limited = await post(conn.aKey, event("call.ended", fake.calls[C6], S0 + 141));
const e6 = await eventOf(`ac:call.ended:${C6}:${S0 + 141}`);
expect("a 429 → 200, the event failed rate_limited, retried later", [limited.status, e6?.status, e6?.error, e6?.later], [200, "failed", "rate_limited", true], [200, "processed", null, false]);
const held = await post(conn.aKey, event("call.ended", fake.calls[C7], S0 + 151));
const e7 = await eventOf(`ac:call.ended:${C7}:${S0 + 151}`);
expect("…the next event is not tried before Aircall's reset: failed rate_limited, no request", [held.status, e7?.error, reads(C7, t0)], [200, "rate_limited", 0], [200, null, 1]);
expect("…one request in all: no retry in a loop", fake.requests.filter((r) => r.t >= t0).length, 1, 2);
expect("…the log names the limit and when calls resume, never a token", logs.some((l) => { const x = JSON.parse(l); return x.message === "aircall rate limited" && x.limit === 120 && x.resumeInSeconds >= 3; }), true, false);
fake.mode = "ok";
await forceDue(conn.a, C6);
await forceDue(conn.a, C7);
t0 = mark();
await runSweep({ connectionId: conn.a });
const firstRead = fake.requests.find((r) => r.t >= t0 && r.path.startsWith("/v1/calls/"));
expect("the sweep reads them once the reset has passed", [(await callRow(C6))?.status, (await callRow(C7))?.status, Boolean(firstRead) && firstRead.t >= t0 + 2500], ["done", "done", true], [null, null, false]);

// ---- H. The default region of the hash, and the catalogs kept and refreshed hourly ----------------------
await asAdmin(t1, () => q("select cma.set_telephony_number($1, '9300000001', 'GB', true)", [conn.a]));
await asAdmin(t1, () => q("select cma.set_telephony_tag($1, '9400000002', false)", [conn.a]));
const C8 = 9100000008;
const C9 = 9100000009;
fake.calls[C8] = makeCall(C8, { ...ENDED, started_at: S0 + 60, raw_digits: CUSTOMER[1] });
fake.calls[C9] = makeCall(C9, { ...ENDED, started_at: S0 + 61, raw_digits: CUSTOMER[2], number: lineOf(9300000002, LINE_X, "Test line two") });
await post(conn.aKey, event("call.ended", fake.calls[C8], S0 + 161));
await post(conn.aKey, event("call.ended", fake.calls[C9], S0 + 162));
expect("a national number on a GB line hashes as GB", (await callRow(C8))?.counterpart_hash, H(PEPPER1, "+442000000002"), hashNumber(PEPPER1, CUSTOMER[1], "NL"));
expect("…on a line without a market as the tenant's first active market (NL)", (await callRow(C9))?.counterpart_hash, hashNumber(PEPPER1, CUSTOMER[2], "NL"), H(PEPPER1, "+442000000003"));
// 0008f: a connection stores calls on its counted lines only. Switching line two off removes its call;
// a call on it afterwards is read but not stored, and counted as skipped_uncounted_line
await asAdmin(t1, () => q("select cma.set_telephony_number($1, '9300000002', null, false)", [conn.a]));
expect("switching line two off removes its stored call (0008f)", Boolean(await callRow(C9)), false, true);
const C13 = 9100000013;
fake.calls[C13] = makeCall(C13, { ...ENDED, started_at: S0 + 62, raw_digits: CUSTOMER[2], number: lineOf(9300000002, LINE_X, "Test line two") });
const logsBefore = logs.length;
t0 = mark();
await post(conn.aKey, event("call.ended", fake.calls[C13], S0 + 163));
expect("…a call on it afterwards is read, not stored, and counted as skipped_uncounted_line", [reads(C13, t0), Boolean(await callRow(C13)),
  logs.slice(logsBefore).some((l) => JSON.parse(l).upserts?.skipped_uncounted_line === 1)], [1, false, true], [1, true, false]);
await q("update cma.sync_cursor set cursor = '{\"refreshedAt\": 0}'::jsonb where connection_id = $1 and stream = 'catalogs'", [conn.a]);
fake.numbers[1] = lineOf(9300000002, LINE_X, "Test line two renamed");
t0 = mark();
const sweep2 = await runSweep({ connectionId: conn.a });
const after = await q("select number_ref, name, market, is_counted from cma.telephony_number where connection_id = $1 order by number_ref", [conn.a]);
expect("the sweep refreshes a catalog an hour old: names from Aircall, market and counted kept", [sweep2.catalogs, after.map((l) => [l.name, l.market, l.is_counted])],
  [1, [["Test line GB", "GB", true], ["Test line two renamed", null, false]]], [0, [["Test line GB", null, true], ["Test line two", null, true]]]);
expect("…the tag's counted flag kept", (await q("select is_counted from cma.telephony_tag where connection_id = $1 and tag_ref = '9400000002'", [conn.a]))[0]?.is_counted, false, true);
t0 = mark();
await runSweep({ connectionId: conn.a });
expect("…and not again within the hour", fake.requests.filter((r) => r.t >= t0 && (r.path === "/v1/numbers" || r.path === "/v1/tags")).length, 0, 2);

// ---- I. link_calls pairs the Aircall call with the CRM call that logged it --------------------------------
await as(t1, ingestOf[t1], () => q("select * from cma.ingest_upsert_calls($1, $2::jsonb)", [conn.h, JSON.stringify([{
  sourceId: "4200000001", occurredAt: iso(S0 + 30), direction: "outbound", status: "COMPLETED", counterpartHash: H(PEPPER1, "+442000000001"),
  createdAt: iso(S0 + 30), updatedAt: iso(S0 + 120), raw: {} }])]));
await runSweep({ connectionId: conn.h });
const link = await q(`select l.delta_seconds, k.source_id as crm from cma.call_link l join cma.telephony_call t on t.tenant_id = l.tenant_id and t.id = l.telephony_call_id
  join cma.crm_call k on k.tenant_id = l.tenant_id and k.id = l.crm_call_id where t.connection_id = $1 and t.source_id = $2 and l.unlinked_at is null`, [conn.a, String(C1)]);
expect("link_calls pairs the call with the seeded CRM call, 30 seconds apart", link.map((l) => [l.crm, l.delta_seconds]), [["4200000001", -30]], []);
expect("…recorded as a link_calls run on the CRM connection", (await runs(conn.h, "link_calls")).map((r) => r.status), ["succeeded"], []);

// ---- J. Reconcile -----------------------------------------------------------------------------------------
const C10 = 9100000010;
fake.calls[C10] = makeCall(C10, { ...ENDED, started_at: nowS() - 5 * 3600, tags: [TAG_B] }); // never sent by a webhook
t0 = mark();
const rec1 = await runReconcile({ connectionId: conn.a });
let recRuns = await runs(conn.a, "reconcile");
expect("reconcile without the webhook_id setting: the run fails with webhook_id_not_set", [recRuns.at(-1)?.status, recRuns.at(-1)?.error], ["failed", "webhook_id_not_set"], ["succeeded", null]);
expect("…after listing: the call the webhook missed is in, with its tag", [(await callRow(C10))?.status, await openTags(C10)], ["done", ["9400000002"]], [null, []]);
expect("…from the listing alone: no call read a second time", fake.requests.filter((r) => r.t >= t0 && /^\/v1\/calls\/\d+$/.test(r.path)).length, 0, 1);
const listReqs = fake.requests.filter((r) => r.t >= t0 && r.path === "/v1/calls");
expect("…two day windows over 26 hours, 50 per page, ascending", [listReqs.length, listReqs.every((r) => r.query.per_page === "50" && r.query.order === "asc"), listReqs.every((r) => Number(r.query.to) - Number(r.query.from) <= 86400)],
  [2, true, true], [1, true, false]);
expect("…the account checked first (GET /v1/company)", fake.requests.filter((r) => r.t >= t0)[0]?.path, "/v1/company", "/v1/calls");
expect("…counts: every listed call fetched", recRuns.at(-1)?.counts?.fetched, Object.values(fake.calls).filter((c) => c.started_at >= nowS() - 26 * 3600).length, 0);
expect("…the job reports the failed run", rec1.failed, 1, 0);
t0 = mark();
fake.bigWindow = true;
await setSettings(conn.a, { webhook_id: "aaaaaaaa-0000-4000-8000-000000000001" });
await runReconcile({ connectionId: conn.a });
fake.bigWindow = false;
recRuns = await runs(conn.a, "reconcile");
expect("reconcile with a webhook_id Aircall does not have: webhook_missing", recRuns.at(-1)?.error, "webhook_missing", "webhook_id_not_set");
expect("…unchanged calls listed again are read once: nothing upserted", [recRuns.at(-1)?.counts?.upserted, recRuns.at(-1)?.counts?.skipped > 0], [0, true], [5, false]);
const halves = fake.requests.filter((r) => r.t >= t0 && r.path === "/v1/calls").map((r) => Number(r.query.to) - Number(r.query.from));
expect("…a day over the 10,000 cap is split into halves", halves.filter((d) => d === 43200).length, 2, 0);
const HOOK = "aaaaaaaa-0000-4000-8000-000000000002";
fake.webhooks.push({ webhook_id: HOOK, direct_link: "https://api.example.com/v1/webhooks/x", created_at: "2026-10-13T08:00:00Z", custom_name: "CMA ingest",
  url: `https://ingest.example.com/aircall/${conn.aKey}`, active: true, token: "another-webhooks-token", events: ["call.created", "call.answered", "call.ended", "call.tagged", "call.untagged", "call.archived"] });
await setSettings(conn.a, { webhook_id: HOOK });
await runReconcile({ connectionId: conn.a });
expect("a webhook holding another token than the signing secret: webhook_token_mismatch", (await runs(conn.a, "reconcile")).at(-1)?.error, "webhook_token_mismatch", null);
fake.webhooks[0].token = TOKEN_A;
fake.webhooks[0].active = false;
fake.putFails = true;
await runReconcile({ connectionId: conn.a });
expect("an inactive webhook that cannot be re-activated: webhook_inactive", (await runs(conn.a, "reconcile")).at(-1)?.error, "webhook_inactive", null);
fake.putFails = false;
t0 = mark();
await runReconcile({ connectionId: conn.a });
const put = fake.requests.find((r) => r.t >= t0 && r.method === "PUT");
expect("an inactive webhook is re-activated (PUT active true with its six events) and recorded: webhook_reactivated", [(await runs(conn.a, "reconcile")).at(-1)?.error, fake.webhooks[0].active, put?.body?.active, put?.body?.events?.length],
  ["webhook_reactivated", true, true, 6], [null, false, undefined, undefined]);
expect("…no webhook is ever created by a job", fake.requests.some((r) => r.method === "POST"), false, true);
await runReconcile({ connectionId: conn.a });
expect("an active webhook with this connection's token: the run succeeds", [(await runs(conn.a, "reconcile")).at(-1)?.status, (await runs(conn.a, "reconcile")).at(-1)?.error], ["succeeded", null], ["failed", "webhook_missing"]);
t0 = mark();
await runReconcile({ connectionId: conn.m });
expect("a connection whose account is not the key's company: account_mismatch, nothing listed", [(await runs(conn.m, "reconcile")).at(-1)?.error, fake.requests.filter((r) => r.t >= t0 && r.path === "/v1/calls").length],
  ["account_mismatch", 0], [null, 2]);
process.env.INGEST_ALLOW_REPLAY = "1";
t0 = mark();
await runReconcile({ connectionId: conn.r });
expect("the replay connection (dev): nothing to reconcile, nothing asked of Aircall", [(await runs(conn.r, "reconcile")).map((r) => `${r.status}:${r.counts.fetched}`), fake.requests.filter((r) => r.t >= t0).length], [["succeeded:0"], 0], [["failed:0"], 1]);
delete process.env.INGEST_ALLOW_REPLAY;

// ---- K. Backfill: resumable after a failure, paced by aircall_max_per_minute ----------------------------
const day = 86400;
const fromDate = new Date(Date.now() - 3 * day * 1000).toISOString().slice(0, 10);
const [{ fromAt }] = await q("select ($1::date::timestamp at time zone 'Europe/Amsterdam') as \"fromAt\"", [fromDate]);
const F = Math.floor(fromAt.getTime() / 1000);
const C11 = 9100000011;
const C12 = 9100000012;
fake.calls[C11] = makeCall(C11, { ...ENDED, started_at: F + day + 3600, tags: [] });
const C14 = 9100000014; // on line two, which does not count (0008f)
fake.calls[C12] = makeCall(C12, { ...ENDED, started_at: F + 2 * day + 3600, tags: [] });
fake.calls[C14] = makeCall(C14, { ...ENDED, started_at: F + day + 7200, tags: [], number: lineOf(9300000002, LINE_X, "Test line two") });
fake.listFailFromS = F + 2 * day;
const bf1 = await runBackfill({ connectionId: conn.a, object: "telephony_call", from: fromDate });
const cursor1 = (await q("select cursor from cma.sync_cursor where connection_id = $1 and stream = 'backfill:telephony_call'", [conn.a]))[0]?.cursor;
expect("backfill: Aircall failing on the third day → the run fails, the first two days kept", [bf1.error, Boolean(await callRow(C11)), Boolean(await callRow(C12)), cursor1?.value, cursor1?.done],
  ["http_503", true, false, (F + 2 * day) * 1000, false], [null, true, true, null, true]);
const bfCounts = (await runs(conn.a, "backfill")).at(-1)?.counts;
expect("…the call on line two (not counted) not stored, counted as skipped, not upserted", [Boolean(await callRow(C14)), bfCounts?.fetched, bfCounts?.upserted, bfCounts?.skipped],
  [false, 2, 1, 1], [true, 2, 2, 0]);
fake.listFailFromS = null;
await setSettings(conn.a, { webhook_id: HOOK, aircall_max_per_minute: "6" });
t0 = mark();
const bf2 = await runBackfill({ connectionId: conn.a, object: "telephony_call", from: fromDate });
const resumed = fake.requests.filter((r) => r.t >= t0 && r.path === "/v1/calls");
expect("…a second run continues at the third day and finishes", [bf2.error, Number(resumed[0]?.query.from), Boolean(await callRow(C12))], [null, F + 2 * day, true], ["http_503", F, false]);
const gaps = fake.requests.filter((r) => r.t >= t0).map((r) => r.t).slice(1).map((t, i, a) => t - (i === 0 ? fake.requests.filter((r) => r.t >= t0)[0].t : a[i - 1]));
expect("…paced at aircall_max_per_minute 6 (10 s, scaled 0.01 here: 100 ms between calls)", gaps.length > 0 && gaps.every((g) => g >= 80), true, false);
t0 = mark();
const bf3 = await runBackfill({ connectionId: conn.a, object: "telephony_call", from: fromDate });
expect("…a third run with the same start does nothing", [bf3.error, fake.requests.filter((r) => r.t >= t0).length], [null, 0], [null, 4]);
expect("…backfill of another object is refused", await runBackfill({ connectionId: conn.a, object: "deal" }).then(() => "ran", (e) => e.constructor.name), "UsageError", "ran");
process.env.INGEST_ALLOW_REPLAY = "1";
expect("…the replay connection (dev) refuses a backfill", (await runBackfill({ connectionId: conn.r, object: "telephony_call", from: fromDate })).error, "replay_connection", null);
delete process.env.INGEST_ALLOW_REPLAY;

// ---- L. Tenant isolation -----------------------------------------------------------------------------------
const CB = 9100000020;
fake.calls[CB] = makeCall(CB, { ...ENDED, started_at: S0 + 70, raw_digits: CUSTOMER[3] });
expect("tenant one's token on tenant two's key → 401", (await post(connB.bKey, event("call.ended", fake.calls[CB], S0 + 171), { token: TOKEN_A })).status, 401, 200);
t0 = mark();
expect("tenant two's own token → 200", (await post(connB.bKey, event("call.ended", fake.calls[CB], S0 + 171), { token: TOKEN_B })).status, 200, 401);
expect("…read with tenant two's key, the row in tenant two, hashed with its pepper", [fake.requests.filter((r) => r.t >= t0).every((r) => r.auth === AUTH_B),
  (await q("select tenant_id from cma.telephony_call where connection_id = $1", [connB.b])).map((r) => r.tenant_id), (await callRow(CB, connB.b))?.counterpart_hash],
  [true, [t2], H(PEPPER2, "+442000000004")], [false, [t1], H(PEPPER1, "+442000000004")]);
expect("tenant one sees none of tenant two's calls, lines or events", await asAdmin(t1, async () => [
  Number((await q("select count(*) as n from cma.telephony_call where connection_id = $1", [connB.b]))[0].n),
  Number((await q("select count(*) as n from cma.telephony_number where connection_id = $1", [connB.b]))[0].n),
  Number((await q("select count(*) as n from cma.ingest_event where connection_id = $1", [connB.b]))[0].n)]), [0, 0, 0], [1, 2, 1]);

// ---- M. What was written and logged -------------------------------------------------------------------------
const ids = [conn.a, conn.r, conn.m, connB.b];
const dbText = JSON.stringify(await q(`select row_to_json(x)::text as r from cma.telephony_call x where connection_id = any ($1)
  union all select row_to_json(x)::text from cma.telephony_call_tag x where connection_id = any ($1)
  union all select row_to_json(x)::text from cma.telephony_tag x where connection_id = any ($1)
  union all select row_to_json(x)::text from cma.telephony_number x where connection_id = any ($1)
  union all select row_to_json(x)::text from cma.ingest_event x where connection_id = any ($1)
  union all select row_to_json(x)::text from cma.sync_cursor x where connection_id = any ($1)
  union all select row_to_json(x)::text from cma.sync_run x where connection_id = any ($1)`, [ids]));
const numberForms = CUSTOMER.flatMap((n) => [n, n.replace(/\D/g, ""), n.replace(/\D/g, "").replace(/^(44|0)/, "")]);
expect("no customer number in any form in the telephony rows, events, cursors or runs", numberForms.filter((n) => dbText.includes(n)), [], numberForms);
expect("no name, email, comment, recording, voicemail, asset or contact", /Invented|example\.com|must not be stored|recordings\.|voicemail\.|assets\.|Customer|CAfixture/.test(dbText), false, true);
expect("no token or API key in the database", [TOKEN_A, TOKEN_B, TOKEN_R, CRED_A.api_token, CRED_B.api_token, "another-webhooks-token"].some((t) => dbText.includes(t)), false, true);
const logText = logs.join("\n");
expect("the logs hold no number, name, email or token", [numberForms.some((n) => logText.includes(n)), /Invented|example\.com/.test(logText), [TOKEN_A, TOKEN_B, TOKEN_R, CRED_A.api_token, CRED_A.api_id, AUTH_A].some((t) => logText.includes(t))],
  [false, false, false], [true, true, true]);
expect("the logs hold the webhook and job lines", ["webhook", "processed", "sweep", "reconcile", "backfill"].every((m) => logs.some((l) => JSON.parse(l).message === m)), true, false);

// This run's connections stop being served (a later run's unfiltered sweep leaves them alone)
for (const c of [conn.a, conn.r, conn.m, conn.h]) await asAdmin(t1, () => q("select cma.set_connection_status($1, 'inactive')", [c]));
await asAdmin(t2, () => q("select cma.set_connection_status($1, 'inactive')", [connB.b]));
await admin.end();
await new Promise((r) => service.close(r));
await new Promise((r) => fakeServer.close(r));
await closeDb();
rmSync(secretsDir, { recursive: true, force: true });
verdict();
