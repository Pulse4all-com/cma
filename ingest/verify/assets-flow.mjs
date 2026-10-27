/**
 * Verifier: the Airtable adapter for an asset register end to end (addition 0008zj; the load in parts, 0008zk), against a
 * local PostgreSQL with db/00…116 and the fake Airtable (verify/airtable-fake.mjs). Everything is invented: tenants, bases, records, serials,
 * customer ids, names (Invented Person …) and addresses (example.invalid).
 *
 *   CMA_DB_HOST=/tmp CMA_DB_PORT=5432 CMA_DB_NAME=cma CMA_DB_USER=cma-ingest@local.iam \
 *   INGEST_FLOW_ADMIN_USER=<team login> node verify/assets-flow.mjs [--provoke]
 *
 * Logins as in verify/flow.mjs. Two throwaway tenants per run (assets-<run>-one, assets-<run>-two); the jobs run in this
 * process; at the end this run's connections are set inactive.
 *
 * Proves: no route for the adapter (404); the first poll (no cursor: every record, in parts of the setting
 * assets_load_chunk, 100 here, so three, through cma.ingest_load_device_part into the devices: nothing missing; its
 * sync_run assets_poll, stream devices, with the load's counts, its phase times and fetched; no staged row, no run of
 * job assets_import; an address as a customer id never stored); a poll not due
 * writes nothing and asks nothing; the next poll asks for the records changed since its cursor less five minutes and
 * loads only those (a pads serial changed: a replacement), never marking the record the register dropped; the nightly
 * reconcile's full snapshot marks it missing (sync_run reconcile, stream device); a connection without a token secret
 * name skipped by the poll and the reconcile (one log line, no run) and refused by the backfill; a 429 fails the run
 * (rate_limited) without moving the cursor, and the next run carries on; a renamed field fails the run unknown_field and
 * the log names the field; a text date without date_format fails date_format_not_set; the backfill's dry run reads and
 * counts and writes nothing (no run, no staging, no cursor); the backfill loads a full snapshot and takes no --from;
 * tenant two's register loads into tenant two only; the fields asked for are the mapped ones only; no token, value or
 * personal fixture text in any row of the run's tenants or in a log line; nothing written to another tenant.
 */
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { randomBytes } from "node:crypto";
import pg from "pg";
import { expect, verdict, writesOutside, PROVOKE } from "./lib.mjs";
import { startFakeAirtable, assetsSource, basesOf } from "./airtable-fake.mjs";

console.log(`verify/assets-flow.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

for (const v of ["CMA_DB_HOST", "CMA_DB_USER"]) {
  if (!process.env[v]) {
    console.error(`${v} is required (a local PostgreSQL with db/00…116; see the header)`);
    process.exit(2);
  }
}
const ADMIN = process.env.INGEST_FLOW_ADMIN_USER;
if (!ADMIN) {
  console.error("INGEST_FLOW_ADMIN_USER is required: a team login that holds cma_owner and cma_app by SET ROLE (locally, for example, auditor@local)");
  process.exit(2);
}
const RUN = randomBytes(4).toString("hex");
const TOKEN = "fixture-airtable-token-flow-0001";
const SECRET1 = `airtable-assets-${RUN}-one`;
const SECRET2 = `airtable-assets-${RUN}-two`;

// ---- Secrets as files; the fake source (tenant one's base of 201 records, tenant two's of 30) ----------------------
const secretsDir = mkdtempSync(path.join(tmpdir(), "assets-flow-"));
writeFileSync(path.join(secretsDir, SECRET1), TOKEN);
writeFileSync(path.join(secretsDir, SECRET2), TOKEN);
const one = assetsSource();
const two = { ...assetsSource(), baseId: "appFixtureAssets2", tableId: "tblFixtureAssets2" };
two.records = two.records.slice(0, 30).map((r) => ({ ...r, id: r.id.replace("recFixture", "recFixtTwo"), fields: { ...r.fields } }));
const fake = await startFakeAirtable({ token: TOKEN, bases: basesOf(one, two) });
const recordAsks = () => fake.state.requests.filter((r) => /^\/v0\/app[A-Za-z0-9]+\/tbl/.test(r.path));

process.env.INGEST_SECRETS_DIR = secretsDir;
process.env.INGEST_AIRTABLE_API_BASE = fake.url;
process.env.INGEST_PACE_FACTOR = "0.01";
const logs = [];
const { setLogSink } = await import("../src/core/log.mjs");
setLogSink((line) => logs.push(line));
const { createIngestServer } = await import("../src/server.mjs");
const { runPollAssets } = await import("../src/jobs/poll-assets.mjs");
const { runReconcile } = await import("../src/jobs/reconcile.mjs");
const { runBackfill } = await import("../src/jobs/backfill.mjs");
const { UsageError } = await import("../src/jobs/runner.mjs");
const { closeDb } = await import("../src/core/db.mjs");
const service = createIngestServer();
await new Promise((r) => service.listen(0, "127.0.0.1", r));
const BASE = `http://127.0.0.1:${service.address().port}`;

// ---- Setup as the admin login ------------------------------------------------------------------------------------
const admin = new pg.Client({ host: process.env.CMA_DB_HOST, port: Number(process.env.CMA_DB_PORT ?? 5432), database: process.env.CMA_DB_NAME ?? "cma",
  user: ADMIN, password: process.env.CMA_DB_PASSWORD || undefined });
await admin.connect();
const q = async (text, values) => (await admin.query(text, values)).rows;
await q("set role cma_owner");
const [{ since }] = await q("select now()::text as since");
const tenantOf = async (slug, name) => {
  const [{ t }] = await q("select cma.create_tenant($1, $2, 'Europe/Amsterdam') as t", [slug, name]);
  const [{ id }] = await q("insert into cma.app_user (tenant_id, email, display_name) values ($1, $2, 'Flow admin') returning id", [t, `flow-admin-${slug}@example.invalid`]);
  await q("insert into cma.user_role (tenant_id, user_id, role_id) select $1, $2, id from cma.app_role where tenant_id = $1 and key = 'admin'", [t, id]);
  return { t, adminId: id };
};
const T1 = await tenantOf(`assets-${RUN}-one`, "Assets flow one");
const T2 = await tenantOf(`assets-${RUN}-two`, "Assets flow two");
async function asAdmin(tenant, fn) {
  await q("begin");
  await q("set local role cma_app");
  await q("select set_config('app.tenant_id', $1, true), set_config('app.user_id', $2, true), set_config('app.actor_label', 'verify:assets-flow', true)",
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
const MAP = [
  ["device", "serial", "", "aed_sn"], ["device", "model", "", "model_aed"], ["device", "status", "", "aed_operational_status"], ["device", "country", "", "country_located"],
  ["device", "warehouse_ref", "", "warehouse_location"], ["device", "customer_ref", "", "customer_id"], ["device", "subscription_ref", "", "subscription_id"],
  ["device", "order_ref", "", "order_number"], ["device", "first_shipped_on", "", "first_shipment_date_to_customer"],
  ["device", "stock_received_on", "", "warehouse_received_date"], ["device", "last_shipped_on", "", "last_shipment_date"],
  ["device", "warranty_until", "", "aed_warranty_date_calculated"], ["device", "end_of_life_on", "", "aed_expected_end_of_life_date_calculated"],
  ["device_component", "serial", "pads", "pads_sn"], ["device_component", "expires_on", "pads", "pads_expiry_date_calculated"],
  ["device_component", "serial", "battery", "battery_sn"], ["device_component", "expires_on", "battery", "battery_expiry_date_calculated"],
  ["device", "ref", "ns_internal_id", "ns_internal_id"], ["device", "ref", "ns_fam_id", "ns_fam_id"], ["device", "ref", "ns_sales_order_id", "sales_order_id"],
];
const SETTINGS = (source, extra = {}) => JSON.stringify({ table_id: source.tableId, date_format: "dmy", airtable_max_per_second: 5, ...extra });
async function setUp(tenant, source, secret) {
  return asAdmin(tenant, async () => {
    await q("select cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', null, null, 10)");
    await q("select cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', null, null, 20)");
    await q("select cma.set_market_alias('netherlands', 'NL')");
    await q("select cma.set_market_alias('united kingdom', 'GB')");
    await q("insert into cma.device_model (key, name, aliases) values ('hs1', 'HS1', array['hs1']), ('frx', 'FRx', array['frx'])");
    await q("insert into cma.device_component_kind (key, name, sort_order) values ('pads', 'Pads', 10), ('battery', 'Battery', 20)");
    await q(`insert into cma.device_status (key, name, is_in_field, is_in_stock, is_tracked, aliases, sort_order) values
               ('active_customer', 'Active/Customer', true, false, true, array['active/customer'], 10),
               ('in_storage', 'In Storage', false, true, true, array['in storage'], 20)`);
    const [c] = await q("select * from cma.upsert_connection('airtable', 'Register flow', $1, null, $2)", [source.baseId, secret]);
    await q("select cma.set_connection_kind($1, 'assets')", [c.connection_id]);
    await q("select cma.set_connection_settings($1, $2::jsonb)", [c.connection_id, SETTINGS(source)]);
    for (const [entity, f, ref, property] of MAP) await q("select cma.set_connection_field($1, $2, $3, $4, $5)", [c.connection_id, entity, f, ref, property]);
    return { id: c.connection_id, key: c.key };
  });
}
const reg1 = await setUp(T1, one, SECRET1);
const reg2 = await setUp(T2, two, SECRET2);
await asAdmin(T1, () => q("select cma.set_connection_settings($1, $2::jsonb)", [reg1.id, SETTINGS(one, { assets_load_chunk: 100 })]));
const files = await asAdmin(T1, async () => {
  const [c] = await q("select * from cma.upsert_connection('airtable', 'Register from files', 'appFixtureFiles01', null, null)");
  await q("select cma.set_connection_kind($1, 'assets')", [c.connection_id]);
  return { id: c.connection_id };
});
const runsOf = async (conn, job) => q("select job, stream, status, error, counts from cma.sync_run where connection_id = $1 and ($2::text is null or job = $2) order by started_at",
  [conn, job]);
const cursor = async (conn, stream) => (await q("select cursor from cma.sync_cursor where connection_id = $1 and stream = $2", [conn, stream]))[0]?.cursor ?? null;
const devicesOf = async (conn) => q(`select d.source_id, d.serial, d.model_key, d.market, d.device_status_key, d.customer_ref, d.customer_ref_invalid,
    d.first_shipped_on::text, d.warranty_until::text, d.end_of_life_on::text, d.external_refs, d.source_deleted_at is not null as missing,
    (select count(*)::int from cma.device_component c where c.device_id = d.id and c.replaced_at is null) as components
  from cma.device d where d.connection_id = $1 order by d.source_id`, [conn]);
const by = (rows, id) => rows.find((r) => r.source_id === id);
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const lastLog = (message) => logs.map((l) => JSON.parse(l)).filter((l) => l.message === message).at(-1);

// ---- A. No route ----------------------------------------------------------------------------------------------------
const post = async (p) => (await fetch(`${BASE}${p}`, { method: "POST", headers: { "content-type": "application/json" }, body: "{}" })).status;
expect("A1 no route for the polling-only adapter: its own key and an unknown key → 404", [await post(`/airtable/${reg1.key}`), await post("/airtable/unknownkey00000000000000")],
  [404, 404], [200, 200]);

// ---- B. The first poll ------------------------------------------------------------------------------------------------
let total = await runPollAssets({ connectionId: reg1.id });
let runs = await runsOf(reg1.id, null);
expect("B1 the first poll: one run assets_poll, stream devices, succeeded; fetched 201, the load's counts (one address as a customer id)",
  [total.connections, total.failed, runs.map((r) => [r.job, r.stream, r.status, r.counts.fetched, r.counts.rows, r.counts.inserted, r.counts.upserted,
    r.counts.missing_now, r.counts.customer_ref_invalid, r.counts.unmapped_market])],
  [1, 0, [["assets_poll", "devices", "succeeded", 201, 201, 201, 201, 0, 1, 0]]], [0, 1, []]);
let devices = await devicesOf(reg1.id);
expect("B2 the devices: model, market and status through the catalogs, the customer reference, dates (ISO, a formula's, a text one in dmy), components, ids",
  [devices.length, by(devices, "recFixture0001aaa"), by(devices, "recFixture0003aaa").market],
  [201, { source_id: "recFixture0001aaa", serial: "FX-TEST-0001", model_key: "hs1", market: "NL", device_status_key: "active_customer", customer_ref: "cu-fixture-0001",
    customer_ref_invalid: false, first_shipped_on: "2024-11-15", warranty_until: "2029-11-15", end_of_life_on: "2034-11-15",
    external_refs: { ns_fam_id: "FAM-0001", ns_internal_id: "9001" }, missing: false, components: 2 }, "GB"], [0, {}, "NL"]);
const x = by(devices, "recFixtureX001aaa");
expect("B3 the address as a customer id: no reference, flagged invalid; the lookup's list read; nothing missing (a partial batch)",
  [x?.customer_ref, x?.customer_ref_invalid, x?.market, devices.filter((d) => d.missing).length], [null, true, "NL", 0], ["person-x001@example.invalid", false, null, 1]);
expect("B4 no staged row left, no run of the file import's job",
  [(await q("select count(*)::int as n from cma.device_import_row where tenant_id = $1", [T1.t]))[0].n, (await runsOf(reg1.id, "assets_import")).length], [0, 0], [201, 1]);
const pollLine = lastLog("poll-assets: connection");
expect("B5 the run's log line: counts, the parts (three of at most 100), the details and the requests per endpoint; the cursors at the run's start",
  [pollLine?.fetched, pollLine?.parts, pollLine?.fields, pollLine?.valuesWithAt, pollLine?.dateFailures, pollLine?.api,
    Number.isFinite((await cursor(reg1.id, "assets:modified"))?.at), Number.isFinite((await cursor(reg1.id, "assets:cadence"))?.at)],
  [201, 3, 20, 1, 1, { "GET /{id}/{id}": 3, "GET /meta/bases/{id}/tables": 1 }, true, true], [0, 1, 0, 0, 0, {}, false, false]);
const PHASES = ["stage_ms", "map_ms", "upsert_ms", "components_ms", "missing_ms", "cleanup_ms"];
expect("B6 the run's counts carry the load's phase times, whole milliseconds summed over the parts (no staging to clean up)",
  [PHASES.every((k) => Number.isInteger(runs[0]?.counts?.[k]) && runs[0].counts[k] >= 0), runs[0]?.counts?.cleanup_ms, runs[0]?.counts?.missing_ms],
  [true, 0, 0], [false, 1, 1]);

// ---- C. Not due; the next poll from its cursor ----------------------------------------------------------------------
const asked0 = fake.state.requests.length;
total = await runPollAssets({ connectionId: reg1.id });
expect("C1 a second poll within the interval (15 minutes): not due, no request, no run", [total.notDue, fake.state.requests.length - asked0, (await runsOf(reg1.id, null)).length],
  [1, 0, 1], [0, 3, 2]);
await asAdmin(T1, () => q("select cma.set_connection_settings($1, $2::jsonb)", [reg1.id, SETTINGS(one, { assets_poll_interval_minutes: 1 })]));
const mod1 = (await cursor(reg1.id, "assets:modified")).at;
const changed = one.records.find((r) => r.id === "recFixture0002aaa");
Object.assign(changed, { modifiedAt: new Date().toISOString(), fields: { ...changed.fields, pads_sn: "PX-0002-NEW", pads_expiry_date_calculated: "2028-12-10" } });
const dropped = one.records.findIndex((r) => r.id === "recFixture0007aaa");
one.records.splice(dropped, 1);
await settle(20);
total = await runPollAssets({ connectionId: reg1.id });
runs = await runsOf(reg1.id, "assets_poll");
devices = await devicesOf(reg1.id);
expect("C2 the next poll asks for the records modified after its cursor less five minutes",
  recordAsks().at(-1).formula, `IS_AFTER(LAST_MODIFIED_TIME(), DATETIME_PARSE("${new Date(mod1 - 5 * 60_000).toISOString()}"))`, null);
expect("C3 only the changed record loaded: updated 1, its pads replaced; the record the register dropped not marked missing",
  [runs.at(-1).counts.fetched, runs.at(-1).counts.updated, runs.at(-1).counts.components_replaced, by(devices, "recFixture0007aaa")?.missing,
    (await q(`select count(*)::int as n from cma.device_component c join cma.device d on d.id = c.device_id
              where d.connection_id = $1 and d.source_id = 'recFixture0002aaa' and c.component_key = 'pads'`, [reg1.id]))[0].n],
  [1, 1, 1, false, 2], [201, 0, 0, true, 1]);

// ---- D. The nightly reconcile: the full snapshot ------------------------------------------------------------------------
total = await runReconcile({ connectionId: reg1.id, object: "device" });
const rec = await runsOf(reg1.id, "reconcile");
devices = await devicesOf(reg1.id);
expect("D1 the reconcile: one run (stream device) succeeded, every record read, the dropped one marked missing, the rest unchanged",
  [total.failed, rec.map((r) => [r.stream, r.status, r.counts.fetched, r.counts.rows, r.counts.missing_now, r.counts.unchanged, r.counts.updated]),
    devices.filter((d) => d.missing).map((d) => d.source_id)],
  [0, [["device", "succeeded", 200, 200, 1, 200, 0]], ["recFixture0007aaa"]], [1, [], []]);
expect("D2 the run's two pages asked the 20 mapped fields only, no filter, authorized",
  recordAsks().slice(-2).map((r) => [r.fields.length, r.formula, r.authorized]), [[20, null, true], [20, null, true]], []);

// ---- E. The connection without a token secret name ---------------------------------------------------------------------
const filesTotal = await runPollAssets({ connectionId: files.id });
const filesRec = await runReconcile({ connectionId: files.id });
let usage = null;
try { await runBackfill({ connectionId: files.id, object: "device" }); } catch (e) { usage = e instanceof UsageError ? "usage" : e.message; }
expect("E1 a connection without a token secret name: the poll and the reconcile skip it (csv_only, one line each), no run; the backfill refuses",
  [filesTotal.notServed, filesRec.notServed, logs.filter((l) => JSON.parse(l).connection === files.id && JSON.parse(l).code === "csv_only").length,
    (await runsOf(files.id, null)).length, usage],
  [1, 1, 2, 0, "usage"], [0, 0, 0, 1, null]);

// ---- F. A 429; a renamed field; a text date without its format --------------------------------------------------------
const modBefore = (await cursor(reg1.id, "assets:modified")).at;
fake.state.fail429 = 1;
total = await runPollAssets({ connectionId: reg1.id });
runs = await runsOf(reg1.id, "assets_poll");
expect("F1 a 429 fails the run (rate_limited), logged; the cursor stays",
  [total.failed, runs.at(-1).status, runs.at(-1).error, Boolean(lastLog("airtable rate limited")), (await cursor(reg1.id, "assets:modified")).at],
  [1, "failed", "rate_limited", true, modBefore], [0, "succeeded", null, false, 0]);
await settle(400);
total = await runPollAssets({ connectionId: reg1.id });
expect("F2 the next run carries on", [total.failed, (await runsOf(reg1.id, "assets_poll")).at(-1).status], [0, "succeeded"], [1, "failed"]);
fake.state.rename(one.baseId, one.tableId, "aed_sn", "aed_serial");
const pages0 = fake.state.pagesAnswered;
total = await runPollAssets({ connectionId: reg1.id });
runs = await runsOf(reg1.id, "assets_poll");
const unknownLine = lastLog("airtable unknown field");
expect("F3 a renamed field: the run fails unknown_field before a record is read; the log names the field",
  [runs.at(-1).status, runs.at(-1).error, unknownLine?.field, fake.state.pagesAnswered - pages0], ["failed", "unknown_field", "aed_sn", 0], ["succeeded", null, undefined, 1]);
fake.state.rename(one.baseId, one.tableId, "aed_serial", "aed_sn");
await asAdmin(T1, () => q("select cma.set_connection_settings($1, $2::jsonb)", [reg1.id, JSON.stringify({ table_id: one.tableId, airtable_max_per_second: 5 })]));
let b = await runBackfill({ connectionId: reg1.id, object: "device" });
const dfLine = lastLog("airtable read refused");
expect("F4 a text date without date_format: the backfill fails date_format_not_set, the log names the field; nothing written",
  [b.failed, b.error, dfLine?.field, (await runsOf(reg1.id, "backfill")).at(-1)?.status, (await q("select count(*)::int as n from cma.device_import_row where tenant_id = $1", [T1.t]))[0].n],
  [1, "date_format_not_set", "aed_expected_end_of_life_date_calculated", "failed", 0], [0, null, undefined, "succeeded", 1]);
await asAdmin(T1, () => q("select cma.set_connection_settings($1, $2::jsonb)", [reg1.id, SETTINGS(one, { assets_poll_interval_minutes: 1 })]));

// ---- G. The backfill: the dry run, then the full read -------------------------------------------------------------------
const runs0 = (await runsOf(reg1.id, null)).length;
const cursor0 = await cursor(reg1.id, "assets:modified");
b = await runBackfill({ connectionId: reg1.id, object: "device", dryRun: true });
expect("G1 the dry run reads and counts: fetched, mapped, the fields, date failures, values with an @, unknown fields",
  [b.fetched, b.mapped, b.fields, b.tableFields, b.dateFailures, b.valuesWithAt, b.unknownFields, Boolean(lastLog("backfill dry run"))],
  [200, 200, 20, 25, 1, 1, 0, true], [0, 0, 0, 0, 0, 0, 1, false]);
expect("G2 …and writes nothing: no run, no staged row, the cursor as it was",
  [(await runsOf(reg1.id, null)).length - runs0, (await q("select count(*)::int as n from cma.device_import_row where tenant_id = $1", [T1.t]))[0].n,
    (await cursor(reg1.id, "assets:modified")).at === cursor0.at], [0, 0, true], [1, 1, false]);
b = await runBackfill({ connectionId: reg1.id, object: "device" });
const bf = (await runsOf(reg1.id, "backfill")).at(-1);
expect("G3 the backfill: a full snapshot on demand (stream device), every record unchanged, nothing new missing",
  [b.failed, bf.stream, bf.status, bf.counts.rows, bf.counts.unchanged, bf.counts.missing_now], [0, "device", "succeeded", 200, 200, 0], [1, null, "failed", 0, 0, 1]);
let fromErr = null;
try { await runBackfill({ connectionId: reg1.id, object: "device", from: "2026-01-01" }); } catch (e) { fromErr = e instanceof UsageError ? "usage" : e.message; }
expect("G4 a backfill of device takes no --from", fromErr, "usage", null);

// ---- H. Tenant two; nothing personal; nothing elsewhere -------------------------------------------------------------------
total = await runPollAssets({ connectionId: reg2.id });
const d2 = await devicesOf(reg2.id);
expect("H1 tenant two's register loads into tenant two only; tenant one's devices as they were",
  [total.failed, d2.length, d2.every((d) => d.source_id.startsWith("recFixtTwo")), (await q("select count(*)::int as n from cma.device where tenant_id = $1", [T1.t]))[0].n,
    (await q("select count(*)::int as n from cma.device where tenant_id = $1", [T2.t]))[0].n],
  [0, 30, true, 201, 30], [1, 0, false, 0, 0]);
expect("H2 no request asked for a field outside the mapping; every one carried the token",
  [fake.state.requests.filter((r) => r.fields.some((f) => !MAP.some((m) => m[3] === f))).length, fake.state.requests.every((r) => r.authorized)], [0, true], [1, false]);
const PERSONAL = ["Invented", "example.invalid", "Fixture note", "editor@", "usrFixture"];
const dbText = JSON.stringify(await q(`select row_to_json(x)::text as r from cma.device x where tenant_id = any($1::uuid[])
  union all select row_to_json(x)::text from cma.device_component x where tenant_id = any($1::uuid[])
  union all select row_to_json(x)::text from cma.sync_run x where tenant_id = any($1::uuid[])
  union all select row_to_json(x)::text from cma.sync_cursor x where tenant_id = any($1::uuid[])
  union all select row_to_json(x)::text from cma.audit_log x where tenant_id = any($1::uuid[]) and table_name in ('device', 'device_component', 'device_import_row', 'sync_run', 'sync_cursor')`,
  [[T1.t, T2.t]]));
expect("H3 no name, address, editor or note in any row of the run's tenants (audit log included)", PERSONAL.filter((p) => dbText.includes(p)), [], PERSONAL);
const logText = logs.join("\n");
const VALUES = [...PERSONAL, TOKEN, "FX-TEST-", "cu-fixture-", "PX-0", "BX-0", "FAM-0", "15/11/2034"];
expect("H4 the logs hold no token and no value: connection ids, counts, codes and field names", VALUES.filter((v) => logText.includes(v)), [], ["x"]);
expect("H5 nothing written to another tenant by this run's logins", await writesOutside(q, { tenants: [T1.t, T2.t], since, logins: [ADMIN, process.env.CMA_DB_USER] }), [], ["x"]);

// This run's connections stop being served (a later run's unfiltered jobs leave them alone)
for (const [tenant, c] of [[T1, reg1.id], [T1, files.id], [T2, reg2.id]]) await asAdmin(tenant, () => q("select cma.set_connection_status($1, 'inactive')", [c]));
await admin.end();
await new Promise((r) => service.close(r));
await fake.close();
await closeDb();
rmSync(secretsDir, { recursive: true, force: true });
verdict();
