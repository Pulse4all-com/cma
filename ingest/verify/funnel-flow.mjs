/**
 * Verifier: stage times (addition 0008za) and reasons (addition 0008zb) end to end, against a local PostgreSQL with
 * db/00…98 and a fake HubSpot API. Everything is invented: the tenant, the portal, ids, secrets, stage ids (one with a
 * hyphen), reason options and a free text that must never be stored.
 *
 *   CMA_DB_HOST=/tmp CMA_DB_PORT=5432 CMA_DB_NAME=cma CMA_DB_USER=cma-ingest@local.iam \
 *   INGEST_FLOW_ADMIN_USER=<team login> node verify/funnel-flow.mjs [--provoke]
 *
 * Logins as in verify/flow.mjs. One throwaway tenant per run (funnel-<run>-one) with a HubSpot connection; the webhook
 * route and the jobs run in this process with this run's connection; at the end the connection is set inactive.
 *
 * Proves: before the pipelines are known no stage time is asked for; the sweep reads the mapped reason properties (an
 * enumeration with its options, a text property refused) and nothing more while they are fresh; a deal's read-back
 * then asks for the stage times of its pipeline's stages (hs_v2_date_entered_quote_sent for the stage quote-sent) and
 * the enumeration reason in the same batch read, and writes them; a later read without a time keeps the stored one; a
 * webhook whose budget cannot hold the stage read writes the record, leaves an event of the record for the sweep with
 * the reason and logs why, and the sweep reads the stage times; a ticket is read without its text reason property and
 * stores none; the backfill of deal,ticket runs both objects with one run row and one log line of requests per endpoint
 * each, reads nothing again without --again, and with --again reads the stored records again and fills their stage
 * times; no stage property in a record's raw, no free text in the database; nothing outside this run's tenant written.
 */
import http from "node:http";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { createHmac, randomBytes } from "node:crypto";
import pg from "pg";
import { expect, verdict, poolCheck, writesOutside, PROVOKE } from "./lib.mjs";

console.log(`verify/funnel-flow.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

for (const v of ["CMA_DB_HOST", "CMA_DB_USER"]) {
  if (!process.env[v]) {
    console.error(`${v} is required (a local PostgreSQL with db/00…98; see the header)`);
    process.exit(2);
  }
}
const ADMIN = process.env.INGEST_FLOW_ADMIN_USER;
if (!ADMIN) {
  console.error("INGEST_FLOW_ADMIN_USER is required: a team login that holds cma_owner and cma_app by SET ROLE (locally, for example, auditor@local)");
  process.exit(2);
}
const RUN = randomBytes(4).toString("hex");
const SLUG = `funnel-${RUN}-one`;
const SIGN = "fixture-client-secret-funnel";
const TOKEN = "fixture-token-funnel";
const FREE_TEXT = "free text a person typed, never stored";

const secretsDir = mkdtempSync(path.join(tmpdir(), "ingest-funnel-"));
const putSecret = (name, value) => writeFileSync(path.join(secretsDir, name), value);
putSecret("ingest-hubspot-funnel-signing", SIGN);
putSecret("ingest-hubspot-funnel-token", TOKEN);
putSecret(`ingest-hash-pepper-${SLUG}`, "fixture-pepper-funnel-000000000000");

// ---- The fake HubSpot API ----------------------------------------------------------------------
const T1 = "2026-10-12T08:00:00.000Z";
const at = (iso) => Date.parse(iso);
const fake = {
  requests: [],
  objects: {
    deals: {
      4150000001: { createdate: T1, pipeline: "p-sales", dealstage: "s-new", hs_lastmodifieddate: T1, lost_dropdown: "too_expensive",
        hs_v2_date_entered_s_new: T1 },
    },
    tickets: {
      4160000001: { createdate: T1, hs_pipeline: "p-support", hs_pipeline_stage: "t-new", hs_lastmodifieddate: T1, cancel_text: FREE_TEXT,
        hs_v2_date_entered_t_new: T1 },
    },
  },
  properties: {
    "deals/lost_dropdown": { name: "lost_dropdown", type: "enumeration", fieldType: "select", options: [
      { value: "too_expensive", label: "Too Expensive", displayOrder: 0 }, { value: "garbage", label: "Garbage", displayOrder: 1 },
      { value: "duplicate", label: "Duplicate", displayOrder: 2, hidden: true }] },
    "tickets/cancel_text": { name: "cancel_text", type: "string", fieldType: "textarea", options: [] },
  },
};
function json(res, status, body) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}
const fakeServer = http.createServer((req, res) => {
  let data = "";
  req.on("data", (c) => { data += c; });
  req.on("end", () => {
    const body = data ? JSON.parse(data) : null;
    const url = new URL(req.url, "http://x");
    const r = { method: req.method, path: url.pathname, properties: body?.properties ?? null, auth: req.headers.authorization };
    fake.requests.push(r);
    let m;
    if ((m = /^\/crm\/v3\/objects\/(\w+)\/batch\/read$/.exec(url.pathname))) {
      const store = fake.objects[m[1]] ?? {};
      const results = body.inputs.filter((i) => store[i.id]).map((i) => ({
        id: String(i.id), createdAt: T1, updatedAt: store[i.id].hs_lastmodifieddate ?? T1, archived: false,
        properties: Object.fromEntries(body.properties.filter((p) => store[i.id][p] !== undefined).map((p) => [p, store[i.id][p]])),
      }));
      return json(res, results.length === body.inputs.length ? 200 : 207, { status: "COMPLETE", results });
    }
    if ((m = /^\/crm\/v3\/objects\/(\w+)\/search$/.exec(url.pathname))) {
      const filters = body.filterGroups?.[0]?.filters ?? [];
      const prop = filters[0].propertyName;
      const gte = Number(filters[0].value);
      const lte = filters[1] ? Number(filters[1].value) : Infinity;
      const all = Object.entries(fake.objects[m[1]] ?? {}).filter(([, o]) => o[prop] && at(o[prop]) >= gte && at(o[prop]) <= lte);
      return json(res, 200, { total: all.length, results: all.map(([id, o]) => ({ id, updatedAt: o.hs_lastmodifieddate,
        properties: Object.fromEntries(body.properties.filter((p) => o[p] !== undefined).map((p) => [p, o[p]])) })) });
    }
    if (/^\/crm\/v4\/associations\//.test(url.pathname)) return json(res, 200, { status: "COMPLETE", results: [] });
    if (url.pathname === "/crm/v3/pipelines/deals") {
      return json(res, 200, { results: [{ id: "p-sales", label: "Sales funnel", stages: [
        { id: "s-new", label: "New", displayOrder: 0, metadata: { isClosed: "false", probability: "0.1" } },
        { id: "quote-sent", label: "Quote sent", displayOrder: 1, metadata: { isClosed: "false", probability: "0.5" } },
        { id: "s-lost", label: "Lost", displayOrder: 2, metadata: { isClosed: "true", probability: "0.0" } }] }] });
    }
    if (url.pathname === "/crm/v3/pipelines/tickets") {
      return json(res, 200, { results: [{ id: "p-support", label: "Support funnel", stages: [
        { id: "t-new", label: "New", displayOrder: 0, metadata: { ticketState: "OPEN" } }, { id: "t-closed", label: "Closed", displayOrder: 1, metadata: { ticketState: "CLOSED" } }] }] });
    }
    if (url.pathname === "/calling/v1/dispositions") return json(res, 200, []);
    if ((m = /^\/crm\/v3\/properties\/(\w+)\/([\w-]+)$/.exec(url.pathname))) {
      const def = fake.properties[`${m[1]}/${m[2]}`];
      return def ? json(res, 200, def) : json(res, 404, { status: "error" });
    }
    json(res, 404, { status: "error" });
  });
});
await new Promise((r) => fakeServer.listen(0, "127.0.0.1", r));

// ---- The service and the jobs, in this process -----------------------------------------------------
process.env.INGEST_SECRETS_DIR = secretsDir;
process.env.INGEST_HUBSPOT_API_BASE = `http://127.0.0.1:${fakeServer.address().port}`;
process.env.INGEST_PACE_FACTOR = "0.1";
const logs = [];
const { setLogSink } = await import("../src/core/log.mjs");
setLogSink((line) => logs.push(line));
const { createIngestServer } = await import("../src/server.mjs");
const { runSweep } = await import("../src/jobs/sweep.mjs");
const { runBackfills } = await import("../src/jobs/backfill.mjs");
const { closeDb } = await import("../src/core/db.mjs");
const service = createIngestServer();
await new Promise((r) => service.listen(0, "127.0.0.1", r));
const BASE = `http://127.0.0.1:${service.address().port}`;
process.env.INGEST_PUBLIC_URLS = `https://ingest.example.com,${BASE}`;

// ---- Setup as the admin login ------------------------------------------------------------------------
const admin = new pg.Client({ host: process.env.CMA_DB_HOST, port: Number(process.env.CMA_DB_PORT ?? 5432), database: process.env.CMA_DB_NAME ?? "cma",
  user: ADMIN, password: process.env.CMA_DB_PASSWORD || undefined });
await admin.connect();
const q = async (text, values) => (await admin.query(text, values)).rows;
await q("set role cma_owner");
const [{ since: STARTED }] = await q("select clock_timestamp()::text as since");
const [{ t1 }] = await q("select cma.create_tenant($1, $2, 'Europe/Amsterdam') as t1", [SLUG, "Funnel one"]);
const [{ id: adminId }] = await q("insert into cma.app_user (tenant_id, email, display_name) values ($1, 'funnel-admin@example.invalid', 'Funnel admin') returning id", [t1]);
await q("insert into cma.user_role (tenant_id, user_id, role_id) select $1, $2, id from cma.app_role where tenant_id = $1 and key = 'admin'", [t1, adminId]);
async function asAdmin(fn) {
  await q("begin");
  await q("set local role cma_app");
  await q("select set_config('app.tenant_id', $1, true), set_config('app.user_id', $2, true), set_config('app.actor_label', 'verify:funnel', true)", [t1, adminId]);
  try {
    const r = await fn();
    await q("commit");
    return r;
  } catch (e) {
    await q("rollback");
    throw e;
  }
}
const conn = await asAdmin(async () => {
  const [c] = await q("select * from cma.upsert_connection('hubspot', 'HubSpot funnel one', '9000031', 'ingest-hubspot-funnel-signing', 'ingest-hubspot-funnel-token')");
  await q("select cma.set_tenant_setting('intake.start_date', '2026-10-01')");
  await q("select cma.set_connection_field($1, 'deal', 'reason', '', 'lost_dropdown', 1::smallint)", [c.connection_id]);
  await q("select cma.set_connection_field($1, 'ticket', 'reason', '', 'cancel_text', 1::smallint)", [c.connection_id]);
  return { id: c.connection_id, key: c.key };
});

let eventSeq = 3200000000 + Math.floor(Math.random() * 1e6) * 100;
const ev = (o) => ({ eventId: ++eventSeq, subscriptionId: 5000031, portalId: 9000031, appId: 8000031, occurredAt: Date.now(), attemptNumber: 0, ...o });
async function post(events) {
  const body = JSON.stringify(events);
  const ts = Date.now();
  const uri = `https://ingest.example.com/hubspot/${conn.key}`;
  const res = await fetch(`${BASE}/hubspot/${conn.key}`, { method: "POST", body, headers: { "content-type": "application/json",
    "x-hubspot-request-timestamp": String(ts), "x-hubspot-signature-v3": createHmac("sha256", SIGN).update(`POST${uri}${body}${ts}`).digest("base64") } });
  await res.text();
  return res.status;
}
const mark = () => fake.requests.length;
const since = (n) => fake.requests.slice(n);
const reads = (n, object) => since(n).filter((r) => r.path === `/crm/v3/objects/${object}/batch/read`);
const stageRows = async (id) => (await q(`select source_stage_id || ':' || coalesce(to_char(entered_at at time zone 'UTC', 'DD HH24:MI'), '-') || '/'
    || coalesce(to_char(exited_at at time zone 'UTC', 'DD HH24:MI'), '-') as s from cma.crm_record_stage where connection_id = $1 and source_id = $2 order by 1`, [conn.id, id])).map((r) => r.s);
const config = async () => asAdmin(async () => (await q("select cma.connection_config($1) as c", [conn.id]))[0].c);
const sweep = () => runSweep({ connectionId: conn.id, maxMs: 10_000 });

// ---- Checks ----------------------------------------------------------------------------------------
// 1. The first read-back: the pipelines are not known yet, the reason properties not read: neither is asked for
let n0 = mark();
expect("a deal created → 200", await post([ev({ subscriptionType: "object.creation", objectTypeId: "0-3", objectId: 4150000001 })]), 200, 500);
expect("…before the pipelines are known, no stage time and no unread reason property is asked for",
  reads(n0, "deals").flatMap((r) => r.properties).filter((p) => p.startsWith("hs_v2_") || p === "lost_dropdown"), [], ["hs_v2_date_entered_s_new"]);
expect("…the pipelines and stages refreshed after it", (await q("select count(*)::int as n from cma.connection_stage where connection_id = $1", [conn.id]))[0].n, 5, 0);

// 2. The sweep reads the reason properties: the enumeration with its options, the text property refused; then nothing
//    while they are fresh
n0 = mark();
await sweep();
const propReads = since(n0).filter((r) => r.path.startsWith("/crm/v3/properties/")).map((r) => r.path).sort();
let cfg = await config();
const state = (entity) => cfg.fields.find((f) => f.field === "reason" && f.entity === entity);
expect("the sweep reads the two reason properties", propReads, ["/crm/v3/properties/deals/lost_dropdown", "/crm/v3/properties/tickets/cancel_text"], []);
expect("…the deal's an enumeration with its three options (a hidden one too), the ticket's text property refused",
  [state("deal")?.state, state("ticket")?.state, state("ticket")?.sourceType, cfg.reasons.map((x) => x.value).sort()],
  ["enumeration", "refused", "string", ["duplicate", "garbage", "too_expensive"]], ["unchecked", "unchecked", null, []]);
n0 = mark();
await sweep();
expect("…a second sweep within the hour reads no property", since(n0).filter((r) => r.path.startsWith("/crm/v3/properties/")).length, 0, 2);

// 3. The deal moves on: its read-back asks for the stage times of its pipeline's stages and the enumeration reason in the
//    same batch read, and writes them
const T2 = "2026-10-13T09:00:00.000Z";
Object.assign(fake.objects.deals[4150000001], { dealstage: "quote-sent", hs_lastmodifieddate: T2, hs_v2_date_exited_s_new: T2, hs_v2_date_entered_quote_sent: T2 });
n0 = mark();
expect("the deal's stage changed → 200", await post([ev({ subscriptionType: "object.propertyChange", objectTypeId: "0-3", objectId: 4150000001, propertyName: "dealstage" })]), 200, 500);
const dealRead = reads(n0, "deals")[0]?.properties ?? [];
expect("…one batch read asks for every stage's two times (the hyphenated id with an underscore) and the reason",
  [reads(n0, "deals").length, dealRead.filter((p) => p.startsWith("hs_v2_")).sort(), dealRead.includes("lost_dropdown")],
  [1, ["hs_v2_date_entered_quote_sent", "hs_v2_date_entered_s_lost", "hs_v2_date_entered_s_new", "hs_v2_date_exited_quote_sent", "hs_v2_date_exited_s_lost", "hs_v2_date_exited_s_new"], true],
  [2, [], false]);
expect("…the stage times written", await stageRows("4150000001"), ["quote-sent:13 09:00/-", "s-new:12 08:00/13 09:00"], []);
const [dealRow] = await q("select reason, raw from cma.crm_record where connection_id = $1 and source_id = '4150000001'", [conn.id]);
expect("…the reason's option value stored; no stage time in the record's raw", [dealRow?.reason, Object.keys(dealRow?.raw ?? {}).some((k) => k.startsWith("hs_v2_"))],
  ["too_expensive", false], [null, true]);

// 4. A later read without a time keeps the stored one
const T3 = "2026-10-13T10:00:00.000Z";
fake.objects.deals[4150000001].hs_lastmodifieddate = T3;
delete fake.objects.deals[4150000001].hs_v2_date_exited_s_new;
expect("a read without s-new's exit → 200", await post([ev({ subscriptionType: "object.propertyChange", objectTypeId: "0-3", objectId: 4150000001, propertyName: "amount" })]), 200, 500);
expect("…the stored exit kept (a read never clears a time)", await stageRows("4150000001"), ["quote-sent:13 09:00/-", "s-new:12 08:00/13 09:00"], ["quote-sent:13 09:00/-", "s-new:12 08:00/-"]);

// 5. A webhook whose budget cannot hold the stage read: the record written, an event of the record left for the sweep
//    with the reason, a log line; the sweep reads the stage times
const T4 = "2026-10-13T11:00:00.000Z";
Object.assign(fake.objects.deals[4150000001], { dealstage: "s-lost", hs_lastmodifieddate: T4, hs_v2_date_exited_quote_sent: T4, hs_v2_date_entered_s_lost: T4 });
process.env.INGEST_STAGE_READ_MIN_MS = "10000";
n0 = mark();
expect("the deal lost, the stage read deferred → 200", await post([ev({ subscriptionType: "object.propertyChange", objectTypeId: "0-3", objectId: 4150000001, propertyName: "dealstage" })]), 200, 500);
delete process.env.INGEST_STAGE_READ_MIN_MS;
const deferred = (await q("select status, source_type, raw from cma.ingest_event where connection_id = $1 and event_key = $2", [conn.id, `stages:deal:4150000001:${T4}`]))[0];
const deferLine = logs.map((l) => JSON.parse(l)).find((l) => l.message === "stage times deferred to the sweep");
expect("…the record written without the stage times, an event left for the sweep with the reason",
  [reads(n0, "deals")[0]?.properties.some((p) => p.startsWith("hs_v2_")), (await q("select stage_id from cma.crm_record where connection_id = $1 and source_id = '4150000001'", [conn.id]))[0]?.stage_id,
    deferred?.status, deferred?.source_type, deferred?.raw?.deferred],
  [false, "s-lost", "received", "cma.stage_times", "budget"], [true, "s-lost", "processed", "cma.stage_times", null]);
expect("…logged with the reason and the record count, never an id", [deferLine?.reason, deferLine?.records, JSON.stringify(deferLine ?? {}).includes("4150000001")], ["budget", 1, false], [null, 0, true]);
n0 = mark();
await sweep();
expect("the sweep reads the deferred stage times and finishes the event",
  [reads(n0, "deals")[0]?.properties.includes("hs_v2_date_entered_s_lost"), (await q("select status from cma.ingest_event where connection_id = $1 and event_key = $2", [conn.id, `stages:deal:4150000001:${T4}`]))[0]?.status,
    await stageRows("4150000001")],
  [true, "processed", ["quote-sent:13 09:00/13 11:00", "s-lost:13 11:00/-", "s-new:12 08:00/13 09:00"]], [false, "received", []]);

// 6. A ticket: read without its text reason property, its stage times read
n0 = mark();
expect("a ticket created → 200", await post([ev({ subscriptionType: "object.creation", objectTypeId: "0-5", objectId: 4160000001 })]), 200, 500);
const ticketRead = reads(n0, "tickets")[0]?.properties ?? [];
const [ticketRow] = await q("select reason, raw from cma.crm_record where connection_id = $1 and source_id = '4160000001'", [conn.id]);
expect("…the text reason property never asked for and no reason stored; its stage times read",
  [ticketRead.includes("cancel_text"), ticketRow?.reason, await stageRows("4160000001")], [false, null, ["t-new:12 08:00/-"]], [true, FREE_TEXT, []]);

// 7. The backfill of deal,ticket: both objects, one run row and one log line of requests each; nothing read again
//    without --again; with --again the stored records read again and their stage times filled
await q("delete from cma.crm_record_stage where connection_id = $1", [conn.id]);
n0 = mark();
const b1 = await runBackfills({ connectionId: conn.id, objects: "deal,ticket" });
const runRows = async () => (await q("select stream, status, counts from cma.sync_run where connection_id = $1 and job = 'backfill' order by started_at", [conn.id]));
const lines = () => logs.map((l) => JSON.parse(l)).filter((l) => l.message === "backfill");
expect("backfill deal,ticket: both objects, a run row each, succeeded", [b1.objects.map((o) => o.object), b1.failed, (await runRows()).map((r) => `${r.stream}:${r.status}`)],
  [["deal", "ticket"], 0, ["deal:succeeded", "ticket:succeeded"]], [["deal,ticket"], 1, []]);
expect("…a log line per object with its requests per endpoint",
  lines().slice(-2).map((l) => [l.object, Object.keys(l.api ?? {}).filter((k) => /search|batch\/read/.test(k)).sort()]),
  [["deal", ["POST /crm/v3/objects/deals/batch/read", "POST /crm/v3/objects/deals/search", "POST /crm/v4/associations/deals/contacts/batch/read"]],
    ["ticket", ["POST /crm/v3/objects/tickets/batch/read", "POST /crm/v3/objects/tickets/search", "POST /crm/v4/associations/tickets/contacts/batch/read"]]], []);
// (s-new's exit is the one step 4 took out of HubSpot's answer: with the rows gone, the read stores what HubSpot answers now)
expect("…the stage times filled again by the first backfill", [await stageRows("4150000001"), await stageRows("4160000001")],
  [["quote-sent:13 09:00/13 11:00", "s-lost:13 11:00/-", "s-new:12 08:00/-"], ["t-new:12 08:00/-"]], [[], []]);
await q("delete from cma.crm_record_stage where connection_id = $1", [conn.id]);
n0 = mark();
await runBackfills({ connectionId: conn.id, objects: "deal,ticket" });
expect("a finished backfill again reads nothing", [since(n0).length, await stageRows("4150000001")], [0, []], [2, ["s-new:12 08:00/13 09:00"]]);
n0 = mark();
const b3 = await runBackfills({ connectionId: conn.id, objects: "deal,ticket", again: true });
expect("…with --again the stored deal and ticket are read again and their stage times filled",
  [b3.failed, reads(n0, "deals").length, reads(n0, "tickets").length, (await stageRows("4150000001")).length, await stageRows("4160000001")],
  [0, 1, 1, 3, ["t-new:12 08:00/-"]], [1, 0, 0, 0, []]);
expect("--object naming an object twice is refused", await runBackfills({ connectionId: conn.id, objects: "deal,deal" }).then(() => "ran", (e) => e.constructor.name), "UsageError", "ran");

// What was written and logged
const dbText = JSON.stringify(await q("select raw::text as r from cma.crm_record where connection_id = $1 union all select raw::text from cma.ingest_event where connection_id = $1", [conn.id]));
expect("no free text anywhere in the records or events", dbText.includes("never stored"), false, true);
expect("the logs hold no token and no record id", [logs.join("\n").includes("fixture-token"), logs.join("\n").includes("4150000001")], [false, false], [true, true]);
await asAdmin(() => q("select cma.set_connection_status($1, 'inactive')", [conn.id]));
expect("no row of another tenant written by this run (any audited table)",
  await writesOutside(q, { tenants: [t1], since: STARTED, logins: [process.env.CMA_DB_USER, ADMIN] }), [], ["ingest_event:1"]);

await admin.end();
await new Promise((r) => service.close(r));
await new Promise((r) => fakeServer.close(r));
await closeDb();
rmSync(secretsDir, { recursive: true, force: true });
await poolCheck();
verdict();
