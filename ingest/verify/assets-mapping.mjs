/**
 * Verifier: the Airtable adapter for an asset register without a database (addition 0008zj), against the fake Airtable
 * (verify/airtable-fake.mjs) and an in-memory store. Everything is invented. Pure: localhost only.
 *
 *   node verify/assets-mapping.mjs             every check must PASS
 *   node verify/assets-mapping.mjs --provoke   every check must FAIL
 *
 * Proves: the mapping from connection fields (device columns, components by kind, named ids; slot 1 only; none: no
 * mapping); the fields asked for (the mapped ones only, each once, never a personal one); cells as text (a number, a
 * yes/no, a lookup's list; an object or an error cell unreadable); the dates (an ISO date, a formula's timestamp, a text
 * date in the connection's format, read as tools/devices-to-staging.mjs reads it; without a format date_format_not_set
 * naming the field; one that does not read left empty and counted); a value with an @ a bare @, counted; the settings'
 * ranges and fallbacks (the part size assets_load_chunk among them); the endpoints; the skip of a connection without a
 * token secret name; the client (the bearer token from the secret, token_unavailable without one, a 429 holding the
 * connection for the lockout, the pace, the requests per endpoint); offset paging, cellFormat json, the view; the poll
 * (no cursor: every record, in parts, nothing marked missing; the cursor less five minutes in the formula; not due within
 * the interval); the full snapshot (in parts of the setting's size, in line order, then one final call over the run's
 * record ids; the counts and phase times summed; a part that fails: no final call, the counts so far; an empty one
 * refused); the dry run (counts, nothing loaded, no cursor); a renamed field (unknown_field, the field named, nothing
 * read); no token and no value in any log line (addition 0008zj; the parts 0008zk).
 */
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, verdict, PROVOKE } from "./lib.mjs";
import { startFakeAirtable, assetsSource, basesOf } from "./airtable-fake.mjs";

console.log(`verify/assets-mapping.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

const TOKEN = "fixture-airtable-token-0001";
const secretsDir = mkdtempSync(path.join(tmpdir(), "assets-mapping-"));
writeFileSync(path.join(secretsDir, "airtable-assets-fixture"), TOKEN);
const source = assetsSource();
const fake = await startFakeAirtable({ token: TOKEN, bases: basesOf(source) });
process.env.INGEST_SECRETS_DIR = secretsDir;
process.env.INGEST_AIRTABLE_API_BASE = fake.url;
process.env.INGEST_PACE_FACTOR = "0.05";
const logs = [];
const { setLogSink } = await import("../src/core/log.mjs");
setLogSink((line) => logs.push(line));
const { JobBudget } = await import("../src/core/budget.mjs");
const { SourceError } = await import("../src/core/http.mjs");
const { assetSettings, endpointOf, resetClients } = await import("../src/adapters/airtable/client.mjs");
const { clientFor, checkFields, modifiedAfter } = await import("../src/adapters/airtable/read.mjs");
const { mappingOf, fieldNames, cellText, rowOf, parseDate } = await import("../src/adapters/airtable/map.mjs");
const airtableModule = await import("../src/adapters/airtable/index.mjs");
const { airtable, skipReason, MODIFIED_STREAM, CADENCE_STREAM, PHASE_COUNTS } = airtableModule;
const { ADAPTERS } = await import("../src/adapters/index.mjs");
const { parseDate: toolParseDate } = await import("../../tools/devices-to-staging.mjs");

// ---- The fixture's configuration, as cma.connection_config answers it -----------------------------------------
const field = (entity, f, refSystem, property, slot = 1) => ({ entity, field: f, refSystem, slot, property, sourceType: null, checkedAt: null });
const FIELDS = [
  field("device", "serial", null, "aed_sn"), field("device", "model", null, "model_aed"), field("device", "status", null, "aed_operational_status"),
  field("device", "country", null, "country_located"), field("device", "warehouse_ref", null, "warehouse_location"),
  field("device", "customer_ref", null, "customer_id"), field("device", "subscription_ref", null, "subscription_id"),
  field("device", "order_ref", null, "order_number"), field("device", "first_shipped_on", null, "first_shipment_date_to_customer"),
  field("device", "stock_received_on", null, "warehouse_received_date"), field("device", "last_shipped_on", null, "last_shipment_date"),
  field("device", "warranty_until", null, "aed_warranty_date_calculated"), field("device", "end_of_life_on", null, "aed_expected_end_of_life_date_calculated"),
  field("device_component", "serial", "pads", "pads_sn"), field("device_component", "expires_on", "pads", "pads_expiry_date_calculated"),
  field("device_component", "serial", "battery", "battery_sn"), field("device_component", "expires_on", "battery", "battery_expiry_date_calculated"),
  field("device", "ref", "ns_internal_id", "ns_internal_id"), field("device", "ref", "ns_fam_id", "ns_fam_id"), field("device", "ref", "ns_sales_order_id", "sales_order_id"),
];
const SETTINGS = { table_id: source.tableId, date_format: "dmy", airtable_max_per_second: 5 };
const configOf = (extra = {}, fields = FIELDS) => ({ fields, settings: { ...SETTINGS, ...extra } });
const CONN = { connectionId: "00000000-0000-4000-8000-00000000a001", adapter: "airtable", externalAccountId: source.baseId, tokenSecretName: "airtable-assets-fixture" };
const ZERO = { rows: 0, inserted: 0, updated: 0, unchanged: 0, missing_now: 0, components_replaced: 0, unmapped_model: 0, unmapped_status: 0, unmapped_market: 0,
  customer_ref_invalid: 0, refs_dropped: 0 };
// The store's load as cma.ingest_load_device_part and cma.ingest_mark_devices_missing answer it: each part's counts
// (every row inserted) and phase times; failPart: the part (from 1) that fails
function memStore(config, { failPart = 0 } = {}) {
  const cursors = new Map();
  const loads = [];
  const marks = [];
  return {
    cursors, loads, marks,
    async config() { return config; },
    async cursor(s) { return cursors.get(s) ?? null; },
    async setCursor(s, v) { cursors.set(s, v); },
    async loadDevicePart(rows) {
      if (loads.length + 1 === failPart) throw Object.assign(new Error("part refused"), { code: "CMA04" });
      loads.push({ rows: rows.map((r) => ({ ...r })) });
      return { ...ZERO, rows: rows.length, inserted: rows.length, stage_ms: 1, map_ms: 2, upsert_ms: 3, components_ms: 4, missing_ms: 0 };
    },
    async markDevicesMissing(sourceIds) {
      marks.push([...sourceIds]);
      return { missing_now: 3, missing_ms: 5 };
    },
  };
}
const counts0 = () => ({ fetched: 0, upserted: 0, stale: 0, skipped: 0, failed: 0 });
const codeOf = async (p) => { try { await p; return "ok"; } catch (e) { return e instanceof SourceError ? e.code : `other:${e?.message}`; } };

// ---- A. The mapping and the fields asked for ----------------------------------------------------------------------
const mapping = mappingOf(configOf());
expect("A1 the mapping: 13 device columns, components pads and battery, three named ids",
  [Object.keys(mapping.columns).length, Object.keys(mapping.components).sort(), Object.keys(mapping.refs).sort(), mapping.components.pads],
  [13, ["battery", "pads"], ["ns_fam_id", "ns_internal_id", "ns_sales_order_id"], { serial: "pads_sn", expires_on: "pads_expiry_date_calculated" }],
  [14, [], [], {}]);
expect("A2 slot 1 only, other entities ignored; nothing mapped is no mapping",
  [Object.keys(mappingOf(configOf({}, [...FIELDS, field("device", "ref", "ns_extra", "extra", 2), field("contact", "country", null, "country")])).refs).length,
    mappingOf(configOf({}, [field("contact", "country", null, "country")]))],
  [3, null], [4, {}]);
const names = fieldNames(mapping);
expect("A3 the fields asked for: the 20 mapped ones, each once, none a personal one",
  [names.length, new Set(names).size, names.filter((n) => ["customer_first_name", "customer_last_name", "email", "last_modified_by", "match_note"].includes(n))],
  [20, 20, []], [21, 19, ["email"]]);

// ---- B. Cells and dates --------------------------------------------------------------------------------------------
expect("B1 cells as text: trimmed, a number, a yes/no, a lookup's list; an object or an error cell unreadable",
  [cellText("  HS1 "), cellText(9001), cellText(true), cellText(["Netherlands"]), cellText(["a", "b"]), cellText(null), cellText({ error: "#ERROR!" }),
    cellText([{ id: "x" }]), cellText(Number.NaN)],
  ["HS1", "9001", "true", "Netherlands", "a, b", "", null, null, null], ["HS1 ", 9001, true, null, "a", null, "", "", "NaN"]);
const DATES = ["15/11/2024", "15-11-2024", "15.11.2024", "1/2/2025", "11/15/2024", "2024-11-15", "2024-2-3", "31/02/2025", "29/02/2024", "2024/11/15", "", "15/11/24", "@"];
const parity = [];
for (const f of ["dmy", "mdy", "iso"]) for (const d of DATES) parity.push(String(parseDate(d, f) ?? null) === String(toolParseDate(d, f) === "" ? null : toolParseDate(d, f)));
expect("B2 a text date reads as tools/devices-to-staging.mjs reads it, in each of the three formats", parity.every(Boolean), true, false);
const recordOf = (id) => ({ id: source.records.find((r) => r.id === id).id, fields: Object.fromEntries(names.map((n) => [n, source.records.find((r) => r.id === id).fields[n]])) });
const r1 = rowOf(recordOf("recFixture0001aaa"), mapping, { dateFormat: "dmy" });
expect("B3 a record's row: the record id, every column as text, ISO dates, a formula's timestamp by its date, a text date in dmy, components and ids as JSON",
  [r1.row, r1.valuesWithAt, r1.dateFailures, r1.unreadable],
  [{ source_id: "recFixture0001aaa", serial: "FX-TEST-0001", model: "HS1", status: "Active/Customer", country: "Netherlands", warehouse_ref: null,
    customer_ref: "cu-fixture-0001", subscription_ref: "sub-fixture-0001", order_ref: "#FX0001", first_shipped_on: "2024-11-15", stock_received_on: null,
    last_shipped_on: null, warranty_until: "2029-11-15", end_of_life_on: "2034-11-15",
    components: '{"battery":{"serial":"BX-0001","expires_on":"2027-01-20"},"pads":{"serial":"PX-0001","expires_on":"2026-12-10"}}',
    external_refs: '{"ns_fam_id":"FAM-0001","ns_internal_id":"9001"}' }, 0, 0, 0], [{}, 1, 1, 1]);
const rx = rowOf(recordOf("recFixtureX001aaa"), mapping, { dateFormat: "dmy" });
expect("B4 an address as a customer id a bare @ (counted); an error cell unreadable; a lookup's list; a text date that does not read empty and counted",
  [rx.row.customer_ref, rx.valuesWithAt, rx.row.warranty_until, rx.unreadable, rx.row.country, rx.row.end_of_life_on, rx.dateFailures, JSON.stringify(rx.row).includes("example.invalid")],
  ["@", 1, null, 1, "Netherlands", null, 1, false], ["person-x001@example.invalid", 0, "#ERROR!", 0, null, "2035-02-31", 0, true]);
let err = null;
try { rowOf(recordOf("recFixture0001aaa"), mapping, { dateFormat: null }); } catch (e) { err = e; }
expect("B5 a date that arrives as text without date_format: date_format_not_set, naming the field (never its value)",
  [err?.code, err?.field, String(err?.message).includes("15/11/2034")], ["date_format_not_set", "aed_expected_end_of_life_date_calculated", false], [undefined, undefined, true]);
const isoOnly = rowOf({ id: "recIso", fields: { first_shipment_date_to_customer: "2024-11-15", aed_warranty_date_calculated: "2029-11-15T00:00:00.000Z" } }, mapping, { dateFormat: null });
expect("B6 ISO dates need no date_format", [isoOnly.row.first_shipped_on, isoOnly.row.warranty_until], ["2024-11-15", "2029-11-15"], [null, null]);

// ---- C. Settings, endpoints, the skip -----------------------------------------------------------------------------------
expect("C1 the settings' defaults: 2 per second, 15 minutes, parts of 1,000, no table, view or date format, nothing out of range",
  assetSettings({}), { perSecond: 2, intervalMinutes: 15, loadChunk: 1000, tableId: null, viewId: null, dateFormat: null, fallbacks: [] }, {});
const odd = assetSettings({ airtable_max_per_second: 9, assets_poll_interval_minutes: "0", assets_load_chunk: 50, table_id: "tbl x", view_id: "viwOk1", date_format: "ymd" });
expect("C2 values out of range give the default and are named; digits as text are taken",
  [odd.perSecond, odd.intervalMinutes, odd.loadChunk, odd.tableId, odd.viewId, odd.dateFormat, odd.fallbacks,
    assetSettings({ assets_poll_interval_minutes: "30" }).intervalMinutes, assetSettings({ assets_load_chunk: "5000" }).loadChunk,
    assetSettings({ assets_load_chunk: 5001 }).loadChunk],
  [2, 15, 1000, null, "viwOk1", null, ["date_format", "airtable_max_per_second", "assets_poll_interval_minutes", "assets_load_chunk", "table_id"], 30, 5000, 1000],
  [9, 0, 50, "tbl x", null, "ymd", [], 15, 1000, 5001]);
expect("C3 the endpoints with their ids replaced and no query",
  [endpointOf("GET", `/meta/bases/${source.baseId}/tables`), endpointOf("GET", `/${source.baseId}/${source.tableId}?pageSize=100&offset=itr1/recX`)],
  ["GET /meta/bases/{id}/tables", "GET /{id}/{id}"], ["GET /meta/bases/appFixtureAssets1/tables", "GET /appFixtureAssets1/tblFixtureAssets1"]);
expect("C4 a connection without a token secret name is skipped (csv_only)",
  [skipReason(CONN), skipReason({ ...CONN, tokenSecretName: null })], [null, "csv_only"], ["csv_only", null]);
expect("C5 the adapter is registered, polling only (no route), its object device", [ADAPTERS.airtable === airtable, airtable.kind, airtable.reconcileObjects, airtable.backfillObjects],
  [true, "poll", ["device"], ["device"]], [false, "webhook", [], []]);

// ---- D. The client and the reads -----------------------------------------------------------------------------------
let budget = new JobBudget({});
const api = clientFor(CONN, SETTINGS, budget);
const tables = await api.tables(source.baseId);
const check = checkFields(tables, source.tableId, names);
expect("D1 the schema: the table, its 25 fields, every mapped field known; the bearer token sent",
  [tables.length, check.tableFields, check.unknown, fake.state.requests.at(-1).authorized], [1, 25, [], true], [0, 0, ["x"], false]);
expect("D2 an unknown table, an unknown field", [await codeOf((async () => checkFields(tables, "tblNope0000000", names))()), checkFields(tables, source.tableId, [...names, "gone"]).unknown],
  ["unknown_table", ["gone"]], ["ok", []]);
const before = fake.state.requests.length;
const pages = [];
for await (const page of api.records(source.baseId, source.tableId, { fields: names })) pages.push(page.length);
const asked = fake.state.requests.slice(before);
expect("D3 offset paging: 201 records in pages of 100, 100 and 1; every page asks the mapped fields only, cellFormat json, pageSize 100",
  [pages, asked.every((r) => r.fields.length === 20 && r.cellFormat === "json" && r.pageSize === "100"), asked.map((r) => Boolean(r.offset))],
  [[100, 100, 1], true, [false, true, true]], [[201], false, []]);
const recs = [];
for await (const page of api.records(source.baseId, source.tableId, { fields: names })) recs.push(...page);
expect("D4 no personal field leaves the fake: no name, email, editor or note; the one address is the mapped customer id that holds one", JSON.stringify(recs).match(/Invented|example\.invalid|Fixture note/g), ["example.invalid"], null);
let n = 0;
for await (const page of api.records(source.baseId, source.tableId, { fields: names, viewId: "viwFixtureField01" })) n += page.length;
expect("D5 the view setting reads the view's records", [n, fake.state.requests.at(-1).view], [181, "viwFixtureField01"], [201, null]);
expect("D6 the requests per endpoint in the run's usage", budget.usage().api, { "GET /{id}/{id}": 8, "GET /meta/bases/{id}/tables": 1 }, {});
const noSecret = clientFor({ ...CONN, tokenSecretName: "airtable-assets-missing" }, SETTINGS, new JobBudget({}));
const before2 = fake.state.requests.length;
expect("D7 a token secret that cannot be read: token_unavailable, nothing sent", [await codeOf(noSecret.tables(source.baseId)), fake.state.requests.length - before2],
  ["token_unavailable", 0], ["ok", 1]);
resetClients();
const slow = clientFor(CONN, { ...SETTINGS, airtable_max_per_second: 2 }, new JobBudget({}));
let t0 = Date.now();
for (let i = 0; i < 5; i += 1) await slow.tables(source.baseId);
expect("D8 the pace: 2 a second (scaled by INGEST_PACE_FACTOR 0.05), five calls take at least four intervals", Date.now() - t0 >= 4 * 25, true, false);
fake.state.fail429 = 1;
fake.state.lockoutMs = 300;
const first = await codeOf(slow.tables(source.baseId));
t0 = Date.now();
const second = await codeOf(slow.tables(source.baseId));
expect("D9 a 429 is rate_limited, logged with its code; the connection held for the lockout (30 s, scaled), then the call goes through",
  [first, second, Date.now() - t0 >= 1500 * 0.9, logs.some((l) => JSON.parse(l).message === "airtable rate limited" && JSON.parse(l).code === "rate_limited")],
  ["rate_limited", "ok", true, true], ["ok", "rate_limited", false, false]);

// ---- E. The poll, the full snapshot, the dry run ------------------------------------------------------------------------
resetClients();
let store = memStore(configOf());
let counts = counts0();
budget = new JobBudget({});
const now1 = Date.now();
await airtable.pollAssets({ connection: CONN, store, budget, now: now1, counts });
expect("E1 the first poll (no cursor): every record, no formula, one part of 201 rows (parts of 1,000), nothing marked missing",
  [fake.state.requests.at(-1).formula, store.loads.length, store.marks.length, store.loads[0]?.rows.length, counts.fetched, counts.inserted, counts.upserted],
  [null, 1, 0, 201, 201, 201, 201], ["x", 0, 1, 0, 0, 0, 0]);
expect("E2 the rows numbered from 2 in record id order; no personal value in any row",
  [store.loads[0].rows[0].source_row, store.loads[0].rows[0].source_id, store.loads[0].rows.at(-1).source_row, JSON.stringify(store.loads[0].rows).match(/Invented|example\.invalid|Fixture note/g)],
  [2, "recFixture0001aaa", 202, null], [1, "recFixtureX001aaa", 201, ["x"]]);
expect("E3 the cursors at the poll's start: assets:modified and assets:cadence", [store.cursors.get(MODIFIED_STREAM)?.at, store.cursors.get(CADENCE_STREAM)?.at], [now1, now1], [null, null]);
expect("E4 not due within the interval (15 minutes, two of slack); due after it",
  [await airtable.pollDue({ store, now: now1 + 60_000 }), await airtable.pollDue({ store, now: now1 + 13 * 60_000 })], [false, true], [true, false]);
source.records[4].modifiedAt = new Date(now1 - 60_000).toISOString();
counts = counts0();
await airtable.pollAssets({ connection: CONN, store, budget, now: now1 + 15 * 60_000, counts });
expect("E5 the next poll asks for the records modified after its cursor less five minutes: the one changed record, one part, nothing marked missing",
  [fake.state.requests.at(-1).formula, store.loads.at(-1).rows.map((r) => r.source_id), store.marks.length],
  [modifiedAfter(now1 - 5 * 60_000), ["recFixture0005aaa"], 0], [null, [], 1]);
counts = counts0();
const loads0 = store.loads.length;
await airtable.pollAssets({ connection: CONN, store, budget, now: now1 + 30 * 60_000, counts });
expect("E6 a poll with nothing changed loads nothing and moves its cursor", [store.loads.length - loads0, counts.fetched, counts.rows, store.cursors.get(MODIFIED_STREAM).at],
  [0, 0, 0, now1 + 30 * 60_000], [1, 1, 1, now1]);
counts = counts0();
const t1 = Date.now();
await airtable.reconcile({ connection: CONN, store, budget, object: "device", counts });
expect("E7 the full snapshot (reconcile): every record, no formula, one part, then one final call over the 201 record ids; the cursor at its start",
  [fake.state.requests.at(-1).formula, store.loads.at(-1).rows.length, store.marks.length, store.marks[0]?.length, counts.missing_now,
    store.cursors.get(MODIFIED_STREAM).at >= t1], [null, 201, 1, 201, 3, true], ["x", 0, 0, 0, 0, false]);
store = memStore(configOf({ assets_load_chunk: 100 }));
counts = counts0();
await airtable.reconcile({ connection: CONN, store, budget, object: "device", counts });
const lines = store.loads.flatMap((l) => l.rows.map((r) => r.source_row));
expect("E7b parts of the setting assets_load_chunk (100): three parts of 100, 100 and 1 in line order, then the final call over every record id read",
  [store.loads.map((l) => l.rows.length), lines.every((v, i) => v === i + 2), store.marks.length,
    JSON.stringify([...store.marks[0]].sort()) === JSON.stringify(store.loads.flatMap((l) => l.rows.map((r) => r.source_id)).sort())],
  [[100, 100, 1], true, 1, true], [[201], false, 0, false]);
expect("E7c the run's counts summed over the parts: the load's, upserted, missing_now from the final call, the phase times",
  [counts.rows, counts.inserted, counts.upserted, counts.missing_now, Object.fromEntries(PHASE_COUNTS.map((k) => [k, counts[k]]))],
  [201, 201, 201, 3, { stage_ms: 3, map_ms: 6, upsert_ms: 9, components_ms: 12, missing_ms: 5, cleanup_ms: 0 }], [0, 0, 0, 0, {}]);
store = memStore(configOf({ assets_load_chunk: 100 }), { failPart: 2 });
counts = counts0();
const failed = await codeOf(airtable.reconcile({ connection: CONN, store, budget, object: "device", counts }));
expect("E7d a part that fails ends the run before the final call: nothing marked missing, the counts of the part loaded, the cursor not moved",
  [failed, store.marks.length, counts.rows, counts.missing_now, store.cursors.has(MODIFIED_STREAM)], ["other:part refused", 0, 100, 0, false], ["ok", 1, 201, 3, true]);
const emptySource = { ...assetsSource(), baseId: "appFixtureEmpty01", records: [] };
fake.state.bases[emptySource.baseId] = basesOf(emptySource)[emptySource.baseId];
const emptyStore = memStore(configOf());
expect("E8 a full read that finds no record fails empty_snapshot and loads nothing",
  [await codeOf(airtable.reconcile({ connection: { ...CONN, externalAccountId: emptySource.baseId }, store: emptyStore, budget, object: "device", counts: counts0() })),
    emptyStore.loads.length, emptyStore.marks.length],
  ["empty_snapshot", 0, 0], ["ok", 1, 1]);
store = memStore(configOf());
const dry = await airtable.dryRun({ connection: CONN, store, budget, object: "device" });
expect("E9 the dry run: the counts; nothing loaded, nothing marked, no cursor",
  [dry.fetched, dry.mapped, dry.fields, dry.tableFields, dry.dateFailures, dry.valuesWithAt, dry.unreadable, dry.unknownFields, store.loads.length, store.marks.length,
    store.cursors.size],
  [201, 201, 20, 25, 1, 1, 1, 0, 0, 0, 0], [0, 0, 21, 0, 0, 0, 0, 1, 1, 1, 1]);
expect("E10 no mapping, no table: mapping_not_set and table_id_not_set before any read",
  [await codeOf(airtable.pollAssets({ connection: CONN, store: memStore(configOf({}, [])), budget, counts: counts0() })),
    await codeOf(airtable.pollAssets({ connection: CONN, store: memStore({ fields: FIELDS, settings: {} }), budget, counts: counts0() }))],
  ["mapping_not_set", "table_id_not_set"], ["ok", "ok"]);
let dateErr = await codeOf(airtable.pollAssets({ connection: CONN, store: memStore(configOf({ date_format: undefined })), budget, counts: counts0() }));
expect("E11 a text date without date_format fails the run date_format_not_set; the log names the field",
  [dateErr, logs.some((l) => JSON.parse(l).code === "date_format_not_set" && JSON.parse(l).field === "aed_expected_end_of_life_date_calculated")], ["date_format_not_set", true], ["ok", false]);

// ---- F. A renamed field --------------------------------------------------------------------------------------------
fake.state.rename(source.baseId, source.tableId, "aed_sn", "aed_serial");
store = memStore(configOf());
const pagesBefore = fake.state.pagesAnswered;
const renamed = await codeOf(airtable.pollAssets({ connection: CONN, store, budget, counts: counts0() }));
const dryRenamed = await airtable.dryRun({ connection: CONN, store, budget, object: "device" });
expect("F1 a renamed field: unknown_field before any record is read, the log naming the field; the dry run counts it and reads nothing",
  [renamed, logs.some((l) => JSON.parse(l).code === "unknown_field" && JSON.parse(l).field === "aed_sn"), fake.state.pagesAnswered - pagesBefore, dryRenamed.unknownFields,
    dryRenamed.unknownFieldNames, dryRenamed.fetched, store.loads.length], ["unknown_field", true, 0, 1, ["aed_sn"], 0, 0], ["ok", false, 3, 0, [], 201, 1]);
fake.state.rename(source.baseId, source.tableId, "aed_serial", "aed_sn");

// ---- G. The logs -------------------------------------------------------------------------------------------------------
const logText = logs.join("\n");
const VALUES = [TOKEN, "FX-TEST-", "cu-fixture-", "sub-fixture-", "#FX0", "PX-0", "BX-0", "FAM-0", "Invented", "example.invalid", "Fixture note", "15/11/2034", "31/02/2035"];
expect("G1 no log line holds the token or a value: field names, codes and counts only", VALUES.filter((v) => logText.includes(v)), [], VALUES);

await fake.close();
rmSync(secretsDir, { recursive: true, force: true });
verdict();
