/**
 * Verifier: the ingest service end to end, against a local PostgreSQL with db/00…33 and a fake
 * HubSpot API. Everything is invented: tenants, portals, ids, secrets, and numbers in the
 * +44 20 0000 000x range.
 *
 *   CMA_DB_HOST=/tmp CMA_DB_PORT=5432 CMA_DB_NAME=cma CMA_DB_USER=cma-ingest@local.iam \
 *   INGEST_FLOW_ADMIN_USER=martin@pulse4all.com node verify/flow.mjs [--provoke]
 *
 * CMA_DB_USER is the service's login: a member of cma_app with inheritance, as the service account's
 * IAM user is on Cloud SQL (CMA_DB_SET_ROLE=cma_app for a login without inheritance).
 * INGEST_FLOW_ADMIN_USER holds cma_owner and cma_app by SET ROLE (00_roles.sql's team login): it
 * creates two throwaway tenants per run (flow-<run>-one, flow-<run>-two) with their connections, and
 * reads the results as the owner. The tenants stay in the local database; nothing touches dev or prod.
 *
 * Proves: /health; unknown key, wrong route and wrong method 404; unsigned, wrongly signed and stale
 * requests 401 with nothing written; a signed batch recorded, read back and upserted (record with its
 * contact, market from the contact through the alias, amount; contact with two ref slots; call with
 * the keyed hash and no number; associations; pipelines and call outcomes); only configured and
 * structural properties requested; a duplicate delivery written once; HubSpot down, rate limited and
 * slow → 200 with the events failed with backoff; another portal ignored without a read-back; a
 * database error before the commit → 500 and nothing written; 600 events in one request; deletion,
 * association removal and privacy deletion; tenant isolation; no number, token or contact id in the
 * logs and no number in the database.
 */
import http from "node:http";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { createHmac, randomBytes } from "node:crypto";
import pg from "pg";
import { expect, verdict, PROVOKE } from "./lib.mjs";

console.log(`verify/flow.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

for (const v of ["CMA_DB_HOST", "CMA_DB_USER"]) {
  if (!process.env[v]) {
    console.error(`${v} is required (a local PostgreSQL with db/00…33; see the header)`);
    process.exit(2);
  }
}
const ADMIN = process.env.INGEST_FLOW_ADMIN_USER ?? "martin@pulse4all.com";
const RUN = randomBytes(4).toString("hex");
const SLUG1 = `flow-${RUN}-one`;
const SLUG2 = `flow-${RUN}-two`;
const SIGN1 = "fixture-client-secret-one";
const SIGN2 = "fixture-client-secret-two";
const TOKEN1 = "fixture-token-one";
const TOKEN2 = "fixture-token-two";
const PEPPER1 = "fixture-pepper-one-000000000000";
const NUMBER = "020 0000 0001";       // the customer's number as HubSpot logged it (national, GB)
const OWN_LINE = "+44 20 0000 0009";  // the company's own line

// ---- Secrets, as files (INGEST_SECRETS_DIR) ------------------------------------------------------
const secretsDir = mkdtempSync(path.join(tmpdir(), "ingest-flow-"));
const putSecret = (name, value) => writeFileSync(path.join(secretsDir, name), value);
putSecret("ingest-hubspot-flow1-signing", SIGN1);
putSecret("ingest-hubspot-flow1-token", TOKEN1);
putSecret("ingest-hubspot-flow2-signing", SIGN2);
putSecret("ingest-hubspot-flow2-token", TOKEN2);
putSecret(`ingest-hash-pepper-${SLUG1}`, PEPPER1);
putSecret(`ingest-hash-pepper-${SLUG2}`, "fixture-pepper-two-000000000000");

// ---- The fake HubSpot API ----------------------------------------------------------------------
const T0 = "2026-10-10T09:00:00.000Z";
const fake = {
  mode: "ok", delayMs: 0, requests: [],
  objects: {
    deals: {
      4100000001: { createdate: T0, pipeline: "p-sales", dealstage: "s-new", hubspot_owner_id: "7100000001", amount: "1200.50", deal_currency_code: "eur", dealname: "a name that must not be read", hs_lastmodifieddate: T0 },
      4100000002: { createdate: T0, pipeline: "p-sales", dealstage: "s-new" },
      4100000003: { createdate: T0, pipeline: "p-sales", dealstage: "s-new" },
      4100000004: { createdate: T0, pipeline: "p-sales", dealstage: "s-new" },
    },
    contacts: {
      4300000001: { contact_country: "uk", contact_language: "en", contact_currency: "gbp", contact_shopify_id_1: "6000000001", contact_shopify_id_2: "6000000002", email: "a.person@example.com" },
    },
    calls: {
      4200000001: { hs_timestamp: "2026-10-10T09:05:00.000Z", hs_call_direction: "OUTBOUND", hs_call_status: "COMPLETED", hs_call_disposition: "f240bbac-0000-0000-0000-000000000001",
        hs_call_duration: "61000", hubspot_owner_id: "7100000001", hs_call_source: "INTEGRATIONS_PLATFORM", hs_call_to_number: NUMBER, hs_call_from_number: OWN_LINE, hs_call_body: "free text that must not be read" },
    },
  },
  assoc: { "deals>contacts": { 4100000001: [4300000001] }, "calls>contacts": { 4200000001: [4300000001] }, "calls>deals": { 4200000001: [4100000001] } },
};

function json(res, status, body) {
  const text = JSON.stringify(body);
  res.writeHead(status, { "content-type": "application/json" });
  res.end(text);
}

const fakeServer = http.createServer((req, res) => {
  let data = "";
  req.on("data", (c) => { data += c; });
  req.on("end", async () => {
    const body = data ? JSON.parse(data) : null;
    const url = new URL(req.url, "http://x");
    fake.requests.push({ method: req.method, path: url.pathname, auth: req.headers.authorization, properties: body?.properties ?? null });
    if (fake.delayMs) await new Promise((r) => setTimeout(r, fake.delayMs));
    if (fake.mode === "down") return json(res, 503, { status: "error" });
    if (fake.mode === "429") return json(res, 429, { status: "error", category: "RATE_LIMITS" });
    let m;
    if ((m = /^\/crm\/v3\/objects\/(\w+)\/batch\/read$/.exec(url.pathname))) {
      const store = fake.objects[m[1]] ?? {};
      const results = body.inputs.filter((i) => store[i.id]).map((i) => ({
        id: String(i.id), createdAt: T0, updatedAt: store[i.id].hs_lastmodifieddate ?? T0, archived: false,
        properties: Object.fromEntries(body.properties.filter((p) => store[i.id][p] !== undefined).map((p) => [p, store[i.id][p]])),
      }));
      return json(res, results.length === body.inputs.length ? 200 : 207, { status: "COMPLETE", results });
    }
    if ((m = /^\/crm\/v4\/associations\/(\w+)\/(\w+)\/batch\/read$/.exec(url.pathname))) {
      const map = fake.assoc[`${m[1]}>${m[2]}`] ?? {};
      const results = body.inputs.filter((i) => map[i.id]?.length).map((i) => ({
        from: { id: String(i.id) }, to: map[i.id].map((t) => ({ toObjectId: t, associationTypes: [{ category: "HUBSPOT_DEFINED", typeId: 1, label: null }] })),
      }));
      return json(res, 200, { status: "COMPLETE", results });
    }
    if (url.pathname === "/crm/v3/pipelines/deals") {
      return json(res, 200, { results: [{ id: "p-sales", label: "Sales test", stages: [
        { id: "s-new", label: "New", displayOrder: 0, metadata: { isClosed: "false" } },
        { id: "s-won", label: "Won", displayOrder: 1, metadata: { isClosed: "true" } }] }] });
    }
    if (url.pathname === "/crm/v3/pipelines/tickets") {
      return json(res, 200, { results: [{ id: "p-support", label: "Support test", stages: [{ id: "t-closed", label: "Closed", displayOrder: 0, metadata: { ticketState: "CLOSED" } }] }] });
    }
    if (url.pathname === "/calling/v1/dispositions") {
      return json(res, 200, [{ id: "f240bbac-0000-0000-0000-000000000001", label: "Connected", deleted: false }, { id: "f240bbac-0000-0000-0000-000000000002", label: "No answer", deleted: false }]);
    }
    json(res, 404, { status: "error" });
  });
});
await new Promise((r) => fakeServer.listen(0, "127.0.0.1", r));

// ---- The service, in this process ----------------------------------------------------------------
process.env.INGEST_SECRETS_DIR = secretsDir;
process.env.INGEST_HUBSPOT_API_BASE = `http://127.0.0.1:${fakeServer.address().port}`;
process.env.INGEST_LOG_HEADER_NAMES = "1";
const logs = [];
const { setLogSink } = await import("../src/core/log.mjs");
setLogSink((line) => logs.push(line));
const { createIngestServer } = await import("../src/server.mjs");
const { closeDb } = await import("../src/core/db.mjs");
const { clearSecretCache } = await import("../src/core/secrets.mjs");
const service = createIngestServer();
await new Promise((r) => service.listen(0, "127.0.0.1", r));
const BASE = `http://127.0.0.1:${service.address().port}`;
process.env.INGEST_PUBLIC_URLS = `https://ingest.example.com,${BASE}`;

// ---- Setup as the admin login --------------------------------------------------------------------
const admin = new pg.Client({ host: process.env.CMA_DB_HOST, port: Number(process.env.CMA_DB_PORT ?? 5432), database: process.env.CMA_DB_NAME ?? "cma",
  user: ADMIN, password: process.env.CMA_DB_PASSWORD || undefined });
await admin.connect();
const q = async (text, values) => (await admin.query(text, values)).rows;
await q("set role cma_owner");
const [{ t1 }] = await q("select cma.create_tenant($1, $2, 'Europe/Amsterdam') as t1", [SLUG1, "Flow one"]);
const [{ t2 }] = await q("select cma.create_tenant($1, $2, 'Europe/Amsterdam') as t2", [SLUG2, "Flow two"]);
const adminOf = {};
for (const t of [t1, t2]) {
  const [{ id }] = await q("insert into cma.app_user (tenant_id, email, display_name) values ($1, 'flow-admin@example.invalid', 'Flow admin') returning id", [t]);
  await q("insert into cma.user_role (tenant_id, user_id, role_id) select $1, $2, id from cma.app_role where tenant_id = $1 and key = 'admin'", [t, id]);
  adminOf[t] = id;
}
async function asAdmin(tenant, fn) {
  await q("begin");
  await q("set local role cma_app");
  await q("select set_config('app.tenant_id', $1, true), set_config('app.user_id', $2, true), set_config('app.actor_label', 'verify:flow', true)", [tenant, adminOf[tenant]]);
  try {
    const r = await fn();
    await q("commit");
    return r;
  } catch (e) {
    await q("rollback");
    throw e;
  }
}
const conn1 = await asAdmin(t1, async () => {
  const [c] = await q("select * from cma.upsert_connection('hubspot', 'HubSpot flow one', '9000001', 'ingest-hubspot-flow1-signing', 'ingest-hubspot-flow1-token')");
  await q("select cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP')");
  await q("select cma.set_market_alias('uk', 'GB')");
  await q("select cma.set_connection_settings($1, '{\"phone_default_region\":\"GB\"}'::jsonb)", [c.connection_id]);
  for (const [entity, field, sys, prop, slot] of [["contact", "country", "", "contact_country", 1], ["contact", "language", "", "contact_language", 1],
    ["contact", "currency", "", "contact_currency", 1], ["contact", "ref", "shopify", "contact_shopify_id_1", 1], ["contact", "ref", "shopify", "contact_shopify_id_2", 2],
    ["deal", "amount", "", "amount", 1], ["deal", "currency", "", "deal_currency_code", 1]]) {
    await q("select cma.set_connection_field($1, $2, $3, $4, $5, $6::smallint)", [c.connection_id, entity, field, sys, prop, slot]);
  }
  const [a] = await q("select * from cma.upsert_connection('aircall', 'Aircall flow one', 'flow-aircall', 'ingest-hubspot-flow1-signing', null)");
  return { id: c.connection_id, key: c.key, aircallKey: a.key };
});
const conn2 = await asAdmin(t2, async () => {
  const [c] = await q("select * from cma.upsert_connection('hubspot', 'HubSpot flow two', '9000002', 'ingest-hubspot-flow2-signing', 'ingest-hubspot-flow2-token')");
  return { id: c.connection_id, key: c.key };
});

// ---- Helpers -------------------------------------------------------------------------------------
let eventSeq = 3100000000 + Math.floor(Math.random() * 1e6) * 100;
const ev = (o) => ({ eventId: ++eventSeq, subscriptionId: 5000001, portalId: 9000001, appId: 8000001, occurredAt: Date.parse("2026-10-10T09:00:00Z"), attemptNumber: 0, ...o });
const sentSignatures = [];
function sign(secret, uri, body, ts) {
  return createHmac("sha256", secret).update(`POST${uri}${body}${ts}`).digest("base64");
}
async function post(key, events, { secret = SIGN1, ts = Date.now(), unsigned = false, uriBase = "https://ingest.example.com", route = "hubspot" } = {}) {
  const body = JSON.stringify(events);
  const pathPart = `/${route}/${key}`;
  const headers = { "content-type": "application/json" };
  if (!unsigned) {
    headers["x-hubspot-request-timestamp"] = String(ts);
    headers["x-hubspot-signature-v3"] = sign(secret, `${uriBase}${pathPart}`, body, ts);
    sentSignatures.push(headers["x-hubspot-signature-v3"]);
  }
  const started = Date.now();
  const res = await fetch(`${BASE}${pathPart}`, { method: "POST", headers, body });
  await res.text();
  return { status: res.status, ms: Date.now() - started };
}
const count = async (table, conn = conn1.id) => Number((await q(`select count(*) as n from cma.${table} where connection_id = $1`, [conn]))[0].n);
const eventOf = async (eventId, conn = conn1.id) => (await q("select status, error, attempts, next_attempt_at > now() as later, raw from cma.ingest_event where connection_id = $1 and event_key = $2", [conn, `hs:${eventId}`]))[0] ?? null;

// ---- Checks --------------------------------------------------------------------------------------
const health = await fetch(`${BASE}/health`);
expect("GET /health answers ok and the version", await health.json(), { ok: true, version: "dev" }, { ok: false });
expect("an unknown key → 404", (await post("k".repeat(32), [ev({})])).status, 404, 401);
expect("a malformed key → 404", (await post("not-a-key", [ev({})])).status, 404, 401);
expect("a connection of another adapter on /hubspot → 404", (await post(conn1.aircallKey, [ev({})])).status, 404, 401);
expect("a route without an adapter → 404", (await post(conn1.key, [ev({})], { route: "aircall" })).status, 404, 200);
expect("GET on a webhook route → 404", (await fetch(`${BASE}/hubspot/${conn1.key}`)).status, 404, 405);

const dealEvents = [
  ev({ subscriptionType: "object.creation", objectTypeId: "0-3", objectId: 4100000001 }),
  ev({ subscriptionType: "object.propertyChange", objectTypeId: "0-3", objectId: 4100000001, propertyName: "amount", propertyValue: "1200.50" }),
  ev({ subscriptionType: "object.creation", objectTypeId: "0-48", objectId: 4200000001 }),
  ev({ subscriptionType: "object.associationChange", associationType: "CONTACT_TO_CALL", fromObjectTypeId: "0-1", toObjectTypeId: "0-48", fromObjectId: 4300000001, toObjectId: 4200000001, associationRemoved: false }),
];
expect("unsigned → 401", (await post(conn1.key, dealEvents, { unsigned: true })).status, 401, 200);
expect("signed with another secret → 401", (await post(conn1.key, dealEvents, { secret: SIGN2 })).status, 401, 200);
expect("a timestamp 6 minutes old → 401", (await post(conn1.key, dealEvents, { ts: Date.now() - 6 * 60_000 })).status, 401, 200);
expect("a signature for another URI → 401", (await post(conn1.key, dealEvents, { uriBase: "https://elsewhere.example.com" })).status, 401, 200);
expect("refused requests wrote nothing", await count("ingest_event"), 0, 4);
expect("refused requests read nothing from HubSpot", fake.requests.length, 0, 1);

const ok = await post(conn1.key, dealEvents);
expect("a signed batch → 200", ok.status, 200, 401);
const events1 = await q("select status, count(*)::int as n from cma.ingest_event where connection_id = $1 group by 1", [conn1.id]);
expect("four events recorded, all processed", events1, [{ status: "processed", n: 4 }], [{ status: "received", n: 4 }]);
const [deal] = await q("select contact_source_id, market, language, amount::text, currency, pipeline_id, stage_id, owner_ref, is_closed, raw from cma.crm_record where connection_id = $1 and source_id = '4100000001'", [conn1.id]);
expect("the deal with its contact, market GB through the alias uk", [deal?.contact_source_id, deal?.market, deal?.language], ["4300000001", "GB", "en"], ["4300000001", "uk", "en"]);
expect("the deal's amount, currency, pipeline, stage, owner", [deal?.amount, deal?.currency, deal?.pipeline_id, deal?.stage_id, deal?.owner_ref], ["1200.50", "EUR", "p-sales", "s-new", "7100000001"], []);
expect("the deal is open by its stage (pipelines refreshed)", deal?.is_closed, false, null);
expect("the deal's raw holds no deal name", JSON.stringify(deal?.raw ?? {}).includes("must not be read"), false, true);
const [contact] = await q("select c.country, c.language, c.currency, c.raw, (select json_agg(json_build_array(r.slot, r.external_id) order by r.slot) from cma.crm_contact_ref r where r.contact_id = c.id and r.system = 'shopify') as refs from cma.crm_contact c where c.connection_id = $1 and c.source_id = '4300000001'", [conn1.id]);
expect("the contact with country, language, currency", [contact?.country, contact?.language, contact?.currency], ["GB", "en", "GBP"], ["uk", "en", "gbp"]);
expect("the contact's two Shopify ref slots", contact?.refs, [[1, "6000000001"], [2, "6000000002"]], [[1, "6000000001"]]);
expect("the contact's email was never read", JSON.stringify(contact?.raw ?? {}).includes("example.com"), false, true);
const [call] = await q("select direction, duration_seconds, outcome_ref, owner_ref, source_app, counterpart_hash, raw from cma.crm_call where connection_id = $1 and source_id = '4200000001'", [conn1.id]);
const expectedHash = createHmac("sha256", PEPPER1).update("+442000000001").digest("hex");
expect("the call: outbound, 61 s, outcome, owner, source app", [call?.direction, call?.duration_seconds, call?.outcome_ref, call?.owner_ref, call?.source_app],
  ["outbound", 61, "f240bbac-0000-0000-0000-000000000001", "7100000001", "integrations_platform"], []);
expect("the call's counterpart hash is HMAC(pepper, E.164)", call?.counterpart_hash, expectedHash, null);
const NUMBERS = /020 0000 000|\+?44 ?20 ?0000|442000000/;
expect("the call's raw holds no number and no body", /number|hs_call_body/.test(JSON.stringify(call?.raw ?? {})) || NUMBERS.test(JSON.stringify(call?.raw ?? {})), false, true);
const assoc = await q("select from_type || '>' || to_type || ':' || to_id as a from cma.crm_association where connection_id = $1 and removed_at is null order by 1", [conn1.id]);
expect("associations deal→contact, call→contact, call→deal", assoc.map((r) => r.a), ["crm_call>contact:4300000001", "crm_call>deal:4100000001", "deal>contact:4300000001"], []);
expect("the call outcome catalog", (await q("select outcome_ref from cma.connection_call_outcome where connection_id = $1 order by 1", [conn1.id])).length, 2, 0);
expect("the pipelines and stages", (await q("select source_stage_id from cma.connection_stage where connection_id = $1 order by 1", [conn1.id])).map((r) => r.source_stage_id), ["s-new", "s-won", "t-closed"], []);
const dealReads = fake.requests.filter((r) => r.path === "/crm/v3/objects/deals/batch/read");
const allowed = new Set(["pipeline", "dealstage", "hubspot_owner_id", "createdate", "closedate", "hs_lastmodifieddate", "amount", "deal_currency_code"]);
expect("deals were read with structural and configured properties only", dealReads.length > 0 && dealReads.every((r) => r.properties.every((p) => allowed.has(p))), true, false);
expect("contacts were read with configured properties only", fake.requests.filter((r) => r.path === "/crm/v3/objects/contacts/batch/read").every((r) => !r.properties.includes("email")), true, false);
expect("every HubSpot call carried the connection's token", fake.requests.every((r) => r.auth === `Bearer ${TOKEN1}`), true, false);

const before = fake.requests.length;
expect("the same delivery again → 200", (await post(conn1.key, dealEvents)).status, 200, 500);
expect("…written once: still four events", await count("ingest_event"), 4, 8);
expect("…and no second read-back", fake.requests.length, before, before + 1);
expect("…one deal row", await count("crm_record"), 1, 2);

fake.mode = "down";
const down = ev({ subscriptionType: "object.creation", objectTypeId: "0-3", objectId: 4100000002 });
expect("HubSpot down → still 200", (await post(conn1.key, [down])).status, 200, 500);
const downRow = await eventOf(down.eventId);
expect("…the event failed with http_503, one attempt, retried later", [downRow?.status, downRow?.error, downRow?.attempts, downRow?.later], ["failed", "http_503", 1, true], ["processed", null, 1, false]);
fake.mode = "429";
const limited = ev({ subscriptionType: "object.creation", objectTypeId: "0-3", objectId: 4100000003 });
expect("HubSpot rate limit → still 200", (await post(conn1.key, [limited])).status, 200, 500);
expect("…the event failed with rate_limited", (await eventOf(limited.eventId))?.error, "rate_limited", null);
fake.mode = "ok";
fake.delayMs = 2500;
process.env.INGEST_READBACK_BUDGET_MS = "800";
const slow = ev({ subscriptionType: "object.creation", objectTypeId: "0-3", objectId: 4100000004 });
const slowRes = await post(conn1.key, [slow]);
expect("HubSpot slower than the budget → 200 within about the budget", [slowRes.status, slowRes.ms < 2000], [200, true], [200, false]);
expect("…the event failed with timeout", (await eventOf(slow.eventId))?.error, "timeout", null);
fake.delayMs = 0;
delete process.env.INGEST_READBACK_BUDGET_MS;

const reqsBefore = fake.requests.length;
const foreign = ev({ portalId: 9999999, subscriptionType: "object.creation", objectTypeId: "0-3", objectId: 4100000009 });
expect("an event of another portal → 200", (await post(conn1.key, [foreign])).status, 200, 401);
const foreignRow = await eventOf(foreign.eventId);
expect("…recorded as ignored portal_mismatch", [foreignRow?.status, foreignRow?.raw?.ignored], ["ignored", "portal_mismatch"], ["processed", undefined]);
expect("…and never read back", fake.requests.length, reqsBefore, reqsBefore + 1);

// A database that refuses the second event of a request (a test trigger in the local database,
// on this run's connection only, dropped right after)
const FAIL_FN = `cma.flow_fail_${RUN}`;
await q(`create function ${FAIL_FN}() returns trigger language plpgsql as $f$ begin
  if new.connection_id = '${conn1.id}' and new.object_id = '4100000666' then raise exception 'flow: refused'; end if; return new; end $f$`);
await q(`create trigger flow_fail_${RUN} before insert on cma.ingest_event for each row execute function ${FAIL_FN}()`);
const good = ev({ subscriptionType: "object.creation", objectTypeId: "0-3", objectId: 4100000005 });
const bad = ev({ subscriptionType: "object.creation", objectTypeId: "0-3", objectId: 4100000666 });
const evBefore = await count("ingest_event");
const dbErr = await post(conn1.key, [good, bad]);
await q(`drop trigger flow_fail_${RUN} on cma.ingest_event`);
await q(`drop function ${FAIL_FN}()`);
expect("a database error before the commit → 500", dbErr.status, 500, 200);
expect("…and nothing of the request was written", await count("ingest_event"), evBefore, evBefore + 1);

const many = Array.from({ length: 600 }, (_, i) => ev({ subscriptionType: "object.propertyChange", objectTypeId: "0-1", objectId: 4390000000 + i, propertyName: "contact_country" }));
const reqsMany = fake.requests.length;
expect("600 events in one request → 200", (await post(conn1.key, many)).status, 200, 500);
expect("…all 600 recorded (two batches of at most 500)", await count("ingest_event") - evBefore, 600, 500);
expect("…contacts the CMA does not hold are ignored without a read", [(await q("select count(*)::int as n from cma.ingest_event where connection_id = $1 and object_id like '439%' and status = 'ignored'", [conn1.id]))[0].n, fake.requests.length - reqsMany], [600, 0], [0, 0]);

fake.assoc["deals>contacts"][4100000001] = [];
const removal = ev({ subscriptionType: "object.associationChange", associationType: "DEAL_TO_CONTACT", fromObjectTypeId: "0-3", toObjectTypeId: "0-1", fromObjectId: 4100000001, toObjectId: 4300000001, associationRemoved: true, occurredAt: Date.now() });
await post(conn1.key, [removal]);
expect("an association removal: deal→contact removed", (await q("select removed_at is not null as gone from cma.crm_association where connection_id = $1 and from_type = 'deal' and to_id = '4300000001'", [conn1.id]))[0]?.gone, true, false);

const privacy = ev({ subscriptionType: "contact.privacyDeletion", objectId: 4300000001 });
await post(conn1.key, [privacy]);
const [forgotten] = await q("select c.country, c.source_deleted_at is not null as deleted, (select count(*)::int from cma.crm_contact_ref r where r.contact_id = c.id) as refs from cma.crm_contact c where c.connection_id = $1 and c.source_id = '4300000001'", [conn1.id]);
expect("privacy deletion: the contact cleared, refs gone", [forgotten?.country, forgotten?.deleted, forgotten?.refs], [null, true, 0], ["GB", false, 2]);
expect("privacy deletion: the call's hash cleared", (await q("select counterpart_hash from cma.crm_call where connection_id = $1", [conn1.id]))[0]?.counterpart_hash, null, expectedHash);

const deletion = ev({ subscriptionType: "object.deletion", objectTypeId: "0-3", objectId: 4100000001, occurredAt: Date.now() });
await post(conn1.key, [deletion]);
expect("a deal deletion marks the record deleted", (await q("select source_deleted_at is not null as d from cma.crm_record where connection_id = $1 and source_id = '4100000001'", [conn1.id]))[0]?.d, true, false);

// Tenant isolation
clearSecretCache();
const t2event = ev({ portalId: 9000002, subscriptionType: "object.creation", objectTypeId: "0-3", objectId: 4100000001 });
expect("tenant one's secret on tenant two's key → 401", (await post(conn2.key, [t2event], { secret: SIGN1 })).status, 401, 200);
expect("tenant two's own signed event → 200", (await post(conn2.key, [t2event], { secret: SIGN2 })).status, 200, 401);
const t2rows = await q("select tenant_id from cma.crm_record where connection_id = $1", [conn2.id]);
expect("tenant two's record lives in tenant two", t2rows.map((r) => r.tenant_id), [t2], [t1]);
expect("tenant two's read-back used tenant two's token", fake.requests.at(-1)?.auth, `Bearer ${TOKEN2}`, `Bearer ${TOKEN1}`);
const seen = await asAdmin(t1, async () => (await q("select count(*)::int as n from cma.crm_record where connection_id = $1", [conn2.id]))[0].n);
expect("tenant one cannot see tenant two's records", seen, 0, 1);
expect("tenant one's records unchanged by tenant two", await count("crm_record"), 1, 2);

// What was written and logged
const dbText = JSON.stringify(await q("select raw from cma.ingest_event where connection_id = any ($1) union all select raw from cma.crm_call where connection_id = any ($1) union all select raw from cma.crm_record where connection_id = any ($1)", [[conn1.id, conn2.id]]));
expect("no phone number anywhere in the event, call or record rows", NUMBERS.test(dbText), false, true);
const logText = logs.join("\n");
expect("the logs hold no number, token, secret or contact id", [NUMBERS.test(logText), logText.includes("fixture-token"), logText.includes("fixture-client-secret"), logText.includes("4300000001")], [false, false, false, false], [true, true, true, true]);
const headerLine = logs.map((l) => JSON.parse(l)).find((l) => l.message === "webhook headers" && l.headerNames.includes("x-hubspot-signature-v3"));
expect("header names are logged (INGEST_LOG_HEADER_NAMES=1), values are not", [Boolean(headerLine), sentSignatures.some((x) => logText.includes(x))], [true, false], [false, true]);

await admin.end();
await new Promise((r) => service.close(r));
await new Promise((r) => fakeServer.close(r));
await closeDb();
rmSync(secretsDir, { recursive: true, force: true });
verdict();
