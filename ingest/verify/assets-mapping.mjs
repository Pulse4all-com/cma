/**
 * Verifier: the Airtable adapter for an asset register without a database (addition 0008zj; field ids, the final step in
 * slices, the two paces and the paging expiry since 0008zk), against the fake Airtable (verify/airtable-fake.mjs) and an
 * in-memory store. Everything is invented. Pure: localhost only.
 *
 *   node verify/assets-mapping.mjs             every check must PASS
 *   node verify/assets-mapping.mjs --provoke   every check must FAIL
 *
 * Proves: the mapping from connection fields by field id (device columns, components by kind, named ids; slot 1 only;
 * none: no mapping); the fields asked for (the mapped ids only, each once, never a personal field's); cells as text (a
 * number, a yes/no, a lookup's list; an object or an error cell unreadable); the dates (an ISO date, a formula's
 * timestamp, a text date in the connection's format, read as tools/devices-to-staging.mjs reads it; without a format
 * date_format_not_set naming the field; one that does not read left empty and counted); a value with an @ a bare @,
 * counted; a field the API leaves out empty (null in the row, never left out); the settings' ranges and fallbacks (the
 * two paces and the chunk size among them; a view_id never used); the endpoints; the skip of a connection without a
 * token secret name; the client (the bearer token from the secret, token_unavailable without one, a 429 holding the
 * connection for the lockout, the poll's pace and a full read's quicker one, the requests per endpoint, an expired
 * paging paging_expired); offset paging by field id, cellFormat json, no view; the poll (no cursor: every record, in
 * chunks, nothing marked missing; the cursor less five minutes in the formula; not due within the interval); the full
 * snapshot (in chunks of the setting's size, in line order, then the final step in slices of the same size over the run's
 * record ids sorted by their bytes, each with its range; the counts and phase times summed; a chunk that fails: no slice,
 * the counts so far; an empty one refused; an expired paging fails it before it loads anything, and the next run reads
 * from the first page); the types recorded on the first read; the dry run (the table's fields with ids, names and types,
 * counts, nothing loaded, no cursor, no type; without a mapping the fields only); a renamed field changes nothing; a
 * deleted field (unknown_field), a changed type (field_type_changed) and a mapping by name (field_not_an_id) fail the read
 * before a record is read, naming the field; the mapping step generated from the dry run's list
 * (docs/ingest/airtable-fields.mjs); no token and no value in any log line.
 */
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { expect, verdict, PROVOKE } from "./lib.mjs";
import { startFakeAirtable, assetsSource, basesOf } from "./airtable-fake.mjs";

console.log(`verify/assets-mapping.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

const here = path.dirname(fileURLToPath(import.meta.url));
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
const { mappingOf, fieldNames, cellText, rowOf, parseDate, DEVICE_COLUMNS } = await import("../src/adapters/airtable/map.mjs");
const airtableModule = await import("../src/adapters/airtable/index.mjs");
const { airtable, skipReason, slicesOf, MODIFIED_STREAM, CADENCE_STREAM, PHASE_COUNTS } = airtableModule;
const { ADAPTERS } = await import("../src/adapters/index.mjs");
const { parseDate: toolParseDate } = await import("../../tools/devices-to-staging.mjs");
const { mappingBlock, studioBlock, fieldsOf } = await import("../../docs/ingest/airtable-fields.mjs");

// ---- The fixture's configuration, as cma.connection_config answers it: each property the field's id -------------------
const idOf = (name) => source.fields.find((f) => f.name === name).id;
const field = (entity, f, refSystem, name, slot = 1) => ({ entity, field: f, refSystem, slot, property: idOf(name), sourceType: null, checkedAt: null });
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
// the types as the first read recorded them (the fixture's, before any switch changes the schema)
const TYPES = new Map(source.fields.map((f) => [f.id, f.type.toLowerCase()]));
const typed = (fields) => fields.map((f) => ({ ...f, sourceType: TYPES.get(f.property), checkedAt: "2026-10-28T00:00:00Z" }));
const SETTINGS = { table_id: source.tableId, date_format: "dmy", airtable_max_per_second: 5, airtable_full_max_per_second: 5 };
const configOf = (extra = {}, fields = FIELDS) => ({ fields, settings: { ...SETTINGS, ...extra } });
const CONN = { connectionId: "00000000-0000-4000-8000-00000000a001", adapter: "airtable", externalAccountId: source.baseId, tokenSecretName: "airtable-assets-fixture" };
const ZERO = { rows: 0, inserted: 0, updated: 0, unchanged: 0, missing_now: 0, components_replaced: 0, unmapped_model: 0, unmapped_status: 0, unmapped_market: 0,
  customer_ref_invalid: 0, refs_dropped: 0 };
// The store as cma.ingest_load_device_chunk, cma.ingest_mark_devices_missing and cma.ingest_record_field_types answer:
// each chunk's counts (every row inserted) and phase times, each slice's (3 missing); failChunk: the chunk (from 1) that fails
function memStore(config, { failChunk = 0 } = {}) {
  const cursors = new Map();
  const loads = [];
  const marks = [];
  const types = [];
  return {
    cursors, loads, marks, types,
    async config() { return config; },
    async cursor(s) { return cursors.get(s) ?? null; },
    async setCursor(s, v) { cursors.set(s, v); },
    async loadDeviceChunk(rows) {
      if (loads.length + 1 === failChunk) throw Object.assign(new Error("chunk refused"), { code: "CMA04" });
      loads.push({ rows: rows.map((r) => ({ ...r })) });
      return { ...ZERO, rows: rows.length, inserted: rows.length, stage_ms: 1, map_ms: 2, upsert_ms: 3, components_ms: 4, missing_ms: 0 };
    },
    async markDevicesMissing(ids, from, before) {
      marks.push({ ids: [...ids], from, before });
      return { missing_now: 3, missing_ms: 5 };
    },
    async recordFieldTypes(items) {
      types.push(items.map((i) => ({ ...i })));
      return items.length;
    },
  };
}
const counts0 = () => ({ fetched: 0, upserted: 0, stale: 0, skipped: 0, failed: 0 });
const codeOf = async (p) => { try { await p; return "ok"; } catch (e) { return e instanceof SourceError ? e.code : `other:${e?.message}`; } };
const recordAsks = () => fake.state.requests.filter((r) => /^\/v0\/app[A-Za-z0-9]+\/tbl/.test(r.path));
const logOf = (message) => logs.map((l) => JSON.parse(l)).filter((l) => l.message === message).at(-1);
const PERSONAL = ["customer_first_name", "customer_last_name", "email", "last_modified_by", "match_note"];

// ---- A. The mapping and the fields asked for ----------------------------------------------------------------------
const mapping = mappingOf(configOf());
expect("A1 the mapping by field id: 13 device columns, components pads and battery, three named ids",
  [Object.keys(mapping.columns).length, Object.keys(mapping.components).sort(), Object.keys(mapping.refs).sort(), mapping.components.pads],
  [13, ["battery", "pads"], ["ns_fam_id", "ns_internal_id", "ns_sales_order_id"], { serial: idOf("pads_sn"), expires_on: idOf("pads_expiry_date_calculated") }],
  [14, [], [], {}]);
expect("A2 slot 1 only, other entities ignored; nothing mapped is no mapping",
  [Object.keys(mappingOf(configOf({}, [...FIELDS, field("device", "ref", "ns_extra", "ns_fam_id", 2), { ...field("device", "country", null, "email"), entity: "contact" }])).refs).length,
    mappingOf(configOf({}, [{ ...field("device", "country", null, "email"), entity: "contact" }]))],
  [3, null], [4, {}]);
const names = fieldNames(mapping);
expect("A3 the fields asked for: the 20 mapped ids, each once, every one a field id, none a personal field's",
  [names.length, new Set(names).size, names.every((n) => /^fld[A-Za-z0-9]{14}$/.test(n)), names.filter((n) => PERSONAL.map(idOf).includes(n))],
  [20, 20, true, []], [21, 19, false, [idOf("email")]]);

// ---- B. Cells and dates --------------------------------------------------------------------------------------------
expect("B1 cells as text: trimmed, a number, a yes/no, a lookup's list; an object or an error cell unreadable",
  [cellText("  HS1 "), cellText(9001), cellText(true), cellText(["Netherlands"]), cellText(["a", "b"]), cellText(null), cellText({ error: "#ERROR!" }),
    cellText([{ id: "x" }]), cellText(Number.NaN)],
  ["HS1", "9001", "true", "Netherlands", "a, b", "", null, null, null], ["HS1 ", 9001, true, null, "a", null, "", "", "NaN"]);
const DATES = ["15/11/2024", "15-11-2024", "15.11.2024", "1/2/2025", "11/15/2024", "2024-11-15", "2024-2-3", "31/02/2025", "29/02/2024", "2024/11/15", "", "15/11/24", "@"];
const parity = [];
for (const f of ["dmy", "mdy", "iso"]) for (const d of DATES) parity.push(String(parseDate(d, f) ?? null) === String(toolParseDate(d, f) === "" ? null : toolParseDate(d, f)));
expect("B2 a text date reads as tools/devices-to-staging.mjs reads it, in each of the three formats", parity.every(Boolean), true, false);
// a record as the API answers it with returnFieldsByFieldId: its fields keyed by id, the empty ones left out
const recordOf = (id) => {
  const r = source.records.find((x) => x.id === id);
  return { id: r.id, fields: Object.fromEntries(source.fields.filter((f) => r.fields[f.name] !== undefined).map((f) => [f.id, r.fields[f.name]])) };
};
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
expect("B5 a date that arrives as text without date_format: date_format_not_set, naming the field by its id (never its value)",
  [err?.code, err?.field, String(err?.message).includes("15/11/2034")], ["date_format_not_set", idOf("aed_expected_end_of_life_date_calculated"), false], [undefined, undefined, true]);
const isoOnly = rowOf({ id: "recIso", fields: { [idOf("first_shipment_date_to_customer")]: "2024-11-15", [idOf("aed_warranty_date_calculated")]: "2029-11-15T00:00:00.000Z" } },
  mapping, { dateFormat: null });
expect("B6 ISO dates need no date_format", [isoOnly.row.first_shipped_on, isoOnly.row.warranty_until], ["2024-11-15", "2029-11-15"], [null, null]);
const sparse = rowOf({ id: "recSparse", fields: { [idOf("aed_sn")]: "FX-SPARSE", [idOf("pads_sn")]: "PX-SPARSE" } }, mapping, { dateFormat: "dmy" });
expect("B7 a field the API leaves out is empty: every column in the row, null (never left out, so the load writes it empty); a kind with a value kept, the rest out",
  [Object.keys(sparse.row).sort(), DEVICE_COLUMNS.filter((c) => c !== "serial").every((c) => Object.hasOwn(sparse.row, c) && sparse.row[c] === null),
    sparse.row.serial, sparse.row.components, sparse.row.external_refs, JSON.stringify(sparse.row).includes("undefined")],
  [["components", "country", "customer_ref", "end_of_life_on", "external_refs", "first_shipped_on", "last_shipped_on", "model", "order_ref", "serial", "source_id",
    "status", "stock_received_on", "subscription_ref", "warehouse_ref", "warranty_until"].sort(), true, "FX-SPARSE", '{"pads":{"serial":"PX-SPARSE"}}', null, false],
  [["serial", "source_id"], false, null, null, "{}", true]);

// ---- C. Settings, endpoints, the skip -----------------------------------------------------------------------------------
expect("C1 the settings' defaults: the poll at 2 a second, a full read at 4, 15 minutes, chunks of 1,000, no table or date format, no view",
  assetSettings({}), { perSecond: 2, fullPerSecond: 4, intervalMinutes: 15, loadChunk: 1000, tableId: null, viewIgnored: false, dateFormat: null, fallbacks: [] }, {});
const odd = assetSettings({ airtable_max_per_second: 9, airtable_full_max_per_second: 6, assets_poll_interval_minutes: "0", assets_load_chunk: 50, table_id: "tbl x",
  view_id: "viwOk1", date_format: "ymd" });
expect("C2 values out of range give the default and are named; digits as text are taken; a view_id is never used, only reported",
  [odd.perSecond, odd.fullPerSecond, odd.intervalMinutes, odd.loadChunk, odd.tableId, odd.viewIgnored, odd.dateFormat, odd.fallbacks,
    assetSettings({ assets_poll_interval_minutes: "30" }).intervalMinutes, assetSettings({ assets_load_chunk: "5000" }).loadChunk,
    assetSettings({ assets_load_chunk: 5001 }).loadChunk, assetSettings({ airtable_full_max_per_second: 5 }).fullPerSecond, "viewId" in odd],
  [2, 4, 15, 1000, null, true, null, ["date_format", "airtable_max_per_second", "airtable_full_max_per_second", "assets_poll_interval_minutes", "assets_load_chunk", "table_id"],
    30, 5000, 1000, 5, false],
  [9, 6, 0, 50, "tbl x", false, "ymd", [], 15, 1000, 5001, 4, true]);
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
expect("D1 the schema: the table, its 25 fields with ids, names and types, every mapped field known, none recorded yet; the bearer token sent",
  [tables.length, check.tableFields, check.list[0], check.unknown, check.changed, check.unrecorded.length, check.unrecorded[0], fake.state.requests.at(-1).authorized],
  [1, 25, { id: idOf("aed_sn"), name: "aed_sn", type: "singleLineText" }, [], [], 20, { property: idOf("aed_sn"), type: "singlelinetext" }, true],
  [0, 0, {}, ["x"], ["x"], 0, {}, false]);
const recorded = new Map(names.map((n) => [n, check.types.get(n)]));
recorded.set(idOf("pads_expiry_date_calculated"), "singlelinetext");
const check2 = checkFields(tables, source.tableId, [...names, "fldGone0000000001"], recorded);
expect("D2 an unknown table; a field the table lacks (by id); a type that differs from the recorded one",
  [await codeOf((async () => checkFields(tables, "tblNope0000000", names))()), check2.unknown, check2.changed, check2.unrecorded],
  ["unknown_table", ["fldGone0000000001"], [{ id: idOf("pads_expiry_date_calculated"), name: "pads_expiry_date_calculated", was: "singlelinetext", now: "date" }], []],
  ["ok", [], [], [{}]]);
const before = fake.state.requests.length;
const pages = [];
for await (const page of api.records(source.baseId, source.tableId, { fields: names })) pages.push(page.length);
const asked = fake.state.requests.slice(before);
expect("D3 offset paging: 201 records in pages of 100, 100 and 1; every page asks the mapped ids only, by field id, cellFormat json, pageSize 100, no view",
  [pages, asked.every((r) => r.fields.length === 20 && r.fields.every((f) => names.includes(f)) && r.byId && r.cellFormat === "json" && r.pageSize === "100" && !r.view),
    asked.map((r) => Boolean(r.offset))],
  [[100, 100, 1], true, [false, true, true]], [[201], false, []]);
const recs = [];
for await (const page of api.records(source.baseId, source.tableId, { fields: names })) recs.push(...page);
expect("D4 the records keyed by field id; no personal field leaves the fake: no name, email, editor or note; the one address is the mapped customer id that holds one",
  [Object.keys(recs[0].fields).every((k) => names.includes(k)), JSON.stringify(recs).match(/Invented|example\.invalid|Fixture note/g)], [true, ["example.invalid"]], [false, null]);
expect("D5 the requests per endpoint in the run's usage", budget.usage().api, { "GET /{id}/{id}": 6, "GET /meta/bases/{id}/tables": 1 }, {});
const noSecret = clientFor({ ...CONN, tokenSecretName: "airtable-assets-missing" }, SETTINGS, new JobBudget({}));
const before2 = fake.state.requests.length;
expect("D6 a token secret that cannot be read: token_unavailable, nothing sent", [await codeOf(noSecret.tables(source.baseId)), fake.state.requests.length - before2],
  ["token_unavailable", 0], ["ok", 1]);
resetClients();
const slow = clientFor(CONN, { ...SETTINGS, airtable_max_per_second: 2, airtable_full_max_per_second: 4 }, new JobBudget({}));
let t0 = Date.now();
for (let i = 0; i < 5; i += 1) await slow.tables(source.baseId);
const pollMs = Date.now() - t0;
resetClients();
const quick = clientFor(CONN, { ...SETTINGS, airtable_max_per_second: 2, airtable_full_max_per_second: 4 }, new JobBudget({}), { full: true });
t0 = Date.now();
for (let i = 0; i < 5; i += 1) await quick.tables(source.baseId);
const fullMs = Date.now() - t0;
expect("D7 the paces (scaled by INGEST_PACE_FACTOR 0.05): the poll's 2 a second, five calls at least four intervals; a full read's 4, quicker",
  [pollMs >= 4 * 25, fullMs >= 4 * 12.5, fullMs < pollMs], [true, true, true], [false, false, false]);
resetClients();
fake.state.fail429 = 1;
fake.state.lockoutMs = 300;
const first = await codeOf(slow.tables(source.baseId));
t0 = Date.now();
const second = await codeOf(slow.tables(source.baseId));
expect("D8 a 429 is rate_limited, logged with its code; the connection held for the lockout (30 s, scaled), then the call goes through",
  [first, second, Date.now() - t0 >= 1500 * 0.9, logs.some((l) => JSON.parse(l).message === "airtable rate limited" && JSON.parse(l).code === "rate_limited")],
  ["rate_limited", "ok", true, true], ["ok", "rate_limited", false, false]);
fake.state.expireOffsets = 1;
let expired = null;
try { for await (const page of api.records(source.baseId, source.tableId, { fields: names })) void page; } catch (e) { expired = e; }
expect("D9 an expired paging (422 LIST_RECORDS_ITERATOR_NOT_AVAILABLE) is paging_expired, a code only (no body)",
  [expired?.code, expired?.status, expired?.message, fake.state.expireOffsets], ["paging_expired", 422, "paging_expired", 0], ["http_422", null, "", 1]);

// ---- E. The poll, the full snapshot, the dry run ------------------------------------------------------------------------
resetClients();
let store = memStore(configOf());
let counts = counts0();
budget = new JobBudget({});
const now1 = Date.now();
await airtable.pollAssets({ connection: CONN, store, budget, now: now1, counts });
expect("E1 the first poll (no cursor): every record, no formula, one chunk of 201 rows (chunks of 1,000), nothing marked missing",
  [recordAsks().at(-1).formula, store.loads.length, store.marks.length, store.loads[0]?.rows.length, counts.fetched, counts.inserted, counts.upserted],
  [null, 1, 0, 201, 201, 201, 201], ["x", 0, 1, 0, 0, 0, 0]);
expect("E2 the rows numbered from 2 in record id order; no personal value in any row",
  [store.loads[0].rows[0].source_row, store.loads[0].rows[0].source_id, store.loads[0].rows.at(-1).source_row, JSON.stringify(store.loads[0].rows).match(/Invented|example\.invalid|Fixture note/g)],
  [2, "recFixture0001aaa", 202, null], [1, "recFixtureX001aaa", 201, ["x"]]);
expect("E3 the cursors at the poll's start: assets:modified and assets:cadence", [store.cursors.get(MODIFIED_STREAM)?.at, store.cursors.get(CADENCE_STREAM)?.at], [now1, now1], [null, null]);
expect("E4 not due within the interval (15 minutes, two of slack); due after it",
  [await airtable.pollDue({ store, now: now1 + 60_000 }), await airtable.pollDue({ store, now: now1 + 13 * 60_000 })], [false, true], [true, false]);
expect("E5 the first read records the 20 mapped fields' types, in lower case, once",
  [store.types.length, store.types[0]?.length, store.types[0]?.find((t) => t.property === idOf("pads_expiry_date_calculated"))?.type,
    store.types[0]?.find((t) => t.property === idOf("model_aed"))?.type],
  [1, 20, "date", "singleselect"], [0, 0, null, null]);
source.records[4].modifiedAt = new Date(now1 - 60_000).toISOString();
store = memStore(configOf({}, typed(FIELDS)));
store.cursors.set(MODIFIED_STREAM, { at: now1 });
counts = counts0();
await airtable.pollAssets({ connection: CONN, store, budget, now: now1 + 15 * 60_000, counts });
expect("E6 the next poll asks for the records modified after its cursor less five minutes: the one changed record, one chunk, nothing marked missing, no type recorded again",
  [recordAsks().at(-1).formula, store.loads.at(-1).rows.map((r) => r.source_id), store.marks.length, store.types.length],
  [modifiedAfter(now1 - 5 * 60_000), ["recFixture0005aaa"], 0, 0], [null, [], 1, 1]);
counts = counts0();
const t1 = Date.now();
store = memStore(configOf({}, typed(FIELDS)));
await airtable.reconcile({ connection: CONN, store, budget, object: "device", counts });
const sortedIds = store.loads.flatMap((l) => l.rows.map((r) => r.source_id)).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
expect("E7 the full snapshot (reconcile): every record, no formula, one chunk, then the final step's one slice of the 201 record ids (no range); the cursor at its start",
  [recordAsks().at(-1).formula, store.loads.at(-1).rows.length, store.marks.length, store.marks[0]?.ids.length, store.marks[0]?.from, store.marks[0]?.before,
    counts.missing_now, store.cursors.get(MODIFIED_STREAM).at >= t1], [null, 201, 1, 201, null, null, 3, true], ["x", 0, 0, 0, "x", "x", 0, false]);
store = memStore(configOf({ assets_load_chunk: 100 }, typed(FIELDS)));
counts = counts0();
await airtable.reconcile({ connection: CONN, store, budget, object: "device", counts });
const lines = store.loads.flatMap((l) => l.rows.map((r) => r.source_row));
expect("E7b chunks of the setting assets_load_chunk (100): three chunks of 100, 100 and 1 in line order, then three slices of the same sizes, the ids sorted by their bytes, each with its range",
  [store.loads.map((l) => l.rows.length), lines.every((v, i) => v === i + 2), store.marks.map((m) => m.ids.length),
    JSON.stringify(store.marks.flatMap((m) => m.ids)) === JSON.stringify(sortedIds),
    store.marks.map((m) => [m.from, m.before]), store.marks.every((m) => m.ids.every((id) => (m.from === null || id >= m.from) && (m.before === null || id < m.before)))],
  [[100, 100, 1], true, [100, 100, 1], true, [[null, sortedIds[100]], [sortedIds[100], sortedIds[200]], [sortedIds[200], null]], true],
  [[201], false, [201], false, [], false]);
expect("E7c the run's counts summed over the chunks and slices: the load's, upserted, missing_now from the slices, the phase times",
  [counts.rows, counts.inserted, counts.upserted, counts.missing_now, Object.fromEntries(PHASE_COUNTS.map((k) => [k, counts[k]]))],
  [201, 201, 201, 9, { stage_ms: 3, map_ms: 6, upsert_ms: 9, components_ms: 12, missing_ms: 15, cleanup_ms: 0 }], [0, 0, 0, 0, {}]);
store = memStore(configOf({ assets_load_chunk: 100 }, typed(FIELDS)), { failChunk: 2 });
counts = counts0();
const failed = await codeOf(airtable.reconcile({ connection: CONN, store, budget, object: "device", counts }));
expect("E7d a chunk that fails ends the run before the final step: no slice, nothing marked missing, the counts of the chunk loaded, the cursor not moved",
  [failed, store.marks.length, counts.rows, counts.missing_now, store.cursors.has(MODIFIED_STREAM)], ["other:chunk refused", 0, 100, 0, false], ["ok", 1, 201, 3, true]);
const odds = ["recB", "rec～", "rec\u{1F600}", "recA", "recä", "recz"];
expect("E7e the slices sort by UTF-8 bytes, the database's collation C (not JavaScript's UTF-16 order), and cut at the size",
  [slicesOf(odds, 4).map((s) => [s.ids, s.from, s.before]), [...odds].sort()[4]],
  [[[["recA", "recB", "recz", "recä"], null, "rec～"], [["rec～", "rec\u{1F600}"], "rec～", null]], "rec\u{1F600}"],
  [[], "rec～"]);
const emptySource = { ...assetsSource(), baseId: "appFixtureEmpty01", records: [] };
fake.state.bases[emptySource.baseId] = basesOf(emptySource)[emptySource.baseId];
const emptyStore = memStore(configOf());
expect("E8 a full read that finds no record fails empty_snapshot and loads nothing",
  [await codeOf(airtable.reconcile({ connection: { ...CONN, externalAccountId: emptySource.baseId }, store: emptyStore, budget, object: "device", counts: counts0() })),
    emptyStore.loads.length, emptyStore.marks.length],
  ["empty_snapshot", 0, 0], ["ok", 1, 1]);
store = memStore(configOf());
const dry = await airtable.dryRun({ connection: CONN, store, budget, object: "device" });
expect("E9 the dry run: the table's fields (id, name, type) and the counts; nothing loaded, nothing marked, no cursor, no type recorded",
  [dry.fetched, dry.mapped, dry.fields, dry.tableFields, dry.tableFieldList.length, dry.tableFieldList.find((f) => f.name === "pads_sn"), dry.dateFailures, dry.valuesWithAt,
    dry.unreadable, dry.unknownFields, dry.typeChangedFields, dry.notFieldIds, store.loads.length, store.marks.length, store.cursors.size, store.types.length],
  [201, 201, 20, 25, 25, { id: idOf("pads_sn"), name: "pads_sn", type: "singleLineText" }, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0],
  [0, 0, 21, 0, 0, null, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1]);
const pagesBeforeDry = fake.state.pagesAnswered;
const dryBare = await airtable.dryRun({ connection: CONN, store: memStore(configOf({}, [])), budget, object: "device" });
expect("E9b the dry run without a mapping: the table's fields only, no record read",
  [dryBare.mappingSet, dryBare.tableFieldList.length, dryBare.fetched, fake.state.pagesAnswered - pagesBeforeDry], [false, 25, 0, 0], [true, 0, 201, 3]);
expect("E10 no mapping, no table: mapping_not_set and table_id_not_set before any read",
  [await codeOf(airtable.pollAssets({ connection: CONN, store: memStore(configOf({}, [])), budget, counts: counts0() })),
    await codeOf(airtable.pollAssets({ connection: CONN, store: memStore({ fields: FIELDS, settings: {} }), budget, counts: counts0() }))],
  ["mapping_not_set", "table_id_not_set"], ["ok", "ok"]);
const dateErr = await codeOf(airtable.pollAssets({ connection: CONN, store: memStore(configOf({ date_format: undefined })), budget, counts: counts0() }));
const dfLine = logOf("airtable read refused");
expect("E11 a text date without date_format fails the run date_format_not_set; the log names the field (its id and name)",
  [dateErr, dfLine?.code, dfLine?.field, dfLine?.fieldName],
  ["date_format_not_set", "date_format_not_set", idOf("aed_expected_end_of_life_date_calculated"), "aed_expected_end_of_life_date_calculated"], ["ok", null, null, null]);
store = memStore(configOf({ assets_load_chunk: 100 }, typed(FIELDS)));
fake.state.expireOffsets = 1;
const cursorAt = Date.now() - 3_600_000;
store.cursors.set(MODIFIED_STREAM, { at: cursorAt });
const expiredRun = await codeOf(airtable.reconcile({ connection: CONN, store, budget, object: "device", counts: counts0() }));
const expiredLine = logOf("airtable paging expired");
const asks0 = recordAsks().length;
const againRun = await codeOf(airtable.reconcile({ connection: CONN, store, budget, object: "device", counts: counts0() }));
expect("E12 an expired paging fails the full read paging_expired before it loads anything (no chunk, no slice, the cursor kept), logged; the next run reads from the first page",
  [expiredRun, store.loads.length - 3, store.marks.length - 3, expiredLine?.code, expiredLine?.fetched, againRun, recordAsks()[asks0]?.offset, store.cursors.get(MODIFIED_STREAM).at > cursorAt],
  ["paging_expired", 0, 0, "paging_expired", 100, "ok", null, true], ["ok", 3, 3, null, 0, "paging_expired", "x", false]);

// ---- F. Field changes in Airtable ---------------------------------------------------------------------------------------
fake.state.rename(source.baseId, source.tableId, "aed_sn", "aed_serial");
store = memStore(configOf({}, typed(FIELDS)));
counts = counts0();
const renamed = await codeOf(airtable.pollAssets({ connection: CONN, store, budget, counts }));
expect("F1 a field renamed in Airtable changes nothing: its id stays, the poll reads every record with its serial",
  [renamed, counts.fetched, store.loads[0]?.rows.find((r) => r.source_id === "recFixture0001aaa")?.serial], ["ok", 201, "FX-TEST-0001"], ["unknown_field", 0, null]);
fake.state.rename(source.baseId, source.tableId, "aed_serial", "aed_sn");
const dropped = fake.state.drop(source.baseId, source.tableId, "order_number");
store = memStore(configOf({}, typed(FIELDS)));
let pages0 = fake.state.pagesAnswered;
const gone = await codeOf(airtable.pollAssets({ connection: CONN, store, budget, counts: counts0() }));
const dryGone = await airtable.dryRun({ connection: CONN, store, budget, object: "device" });
expect("F2 a deleted field: unknown_field before any record is read, the log naming the field's id; the dry run counts it and reads nothing",
  [gone, logOf("airtable unknown field")?.field, fake.state.pagesAnswered - pages0, dryGone.unknownFields, dryGone.unknownFieldNames, dryGone.fetched, store.loads.length],
  ["unknown_field", dropped.id, 0, 1, [dropped.id], 0, 0], ["ok", null, 3, 0, [], 201, 1]);
source.fields.splice(7, 0, dropped);
fake.state.retype(source.baseId, source.tableId, "pads_expiry_date_calculated", "singleLineText");
store = memStore(configOf({}, typed(FIELDS).map((f) => (f.property === idOf("pads_expiry_date_calculated") ? { ...f, sourceType: "date" } : f))));
pages0 = fake.state.pagesAnswered;
const retyped = await codeOf(airtable.pollAssets({ connection: CONN, store, budget, counts: counts0() }));
const typeLine = logOf("airtable field type changed");
const dryRetyped = await airtable.dryRun({ connection: CONN, store, budget, object: "device" });
expect("F3 a changed type: field_type_changed before any record is read, the log naming the field (id, name) and both types; the dry run counts it",
  [retyped, typeLine?.field, typeLine?.fieldName, typeLine?.was, typeLine?.now, fake.state.pagesAnswered - pages0, dryRetyped.typeChangedFields, store.types.length],
  ["field_type_changed", idOf("pads_expiry_date_calculated"), "pads_expiry_date_calculated", "date", "singlelinetext", 0, 1, 0],
  ["ok", null, null, null, null, 3, 0, 1]);
fake.state.retype(source.baseId, source.tableId, "pads_expiry_date_calculated", "date");
const byName = FIELDS.map((f) => (f.field === "serial" && f.entity === "device" ? { ...f, property: "aed_sn" } : f));
const asks1 = fake.state.requests.length;
const named = await codeOf(airtable.pollAssets({ connection: CONN, store: memStore(configOf({}, byName)), budget, counts: counts0() }));
expect("F4 a mapping by field name, not id: field_not_an_id before any request, the log naming it",
  [named, logOf("airtable mapping not by field id")?.field, fake.state.requests.length - asks1], ["field_not_an_id", "aed_sn", 0], ["ok", null, 1]);
const exampleMap = JSON.parse(readFileSync(path.join(here, "../../docs/import/devices-map.example.json"), "utf8"));
const gcloudJson = JSON.stringify([{ jsonPayload: { message: "backfill dry run", tableFieldList: dry.tableFieldList } }]);
const block = mappingBlock({ connection: CONN.connectionId, map: exampleMap, fields: fieldsOf(gcloudJson) });
const generated = block.lines.map((l) => /cma\.set_connection_field\('[^']+', '([a-z_]+)', '([a-z_]+)', '([a-z_]*)', '(fld[A-Za-z0-9]{14})'\)/.exec(l)?.slice(1).join("/")).sort();
const wanted = FIELDS.map((f) => [f.entity, f.field, f.refSystem ?? "", f.property].join("/")).sort();
const renamedMap = { ...exampleMap, columns: { ...exampleMap.columns, serial: "aed_serial_number" } };
expect("F5 the mapping step generated from the dry run's list and the map file: the 20 fields by id, as the adapter maps them; a header the table lacks named",
  [block.mapped, JSON.stringify(generated) === JSON.stringify(wanted), block.missing, mappingBlock({ connection: CONN.connectionId, map: renamedMap, fields: dry.tableFieldList }).missing,
    studioBlock(CONN.connectionId, block.lines).split("\n").length, block.lines[0].endsWith("-- aed_sn (singleLineText)")],
  [20, true, [], ["aed_serial_number"], 27, true], [19, false, ["x"], [], 0, false]);

// ---- G. The logs -------------------------------------------------------------------------------------------------------
const logText = logs.join("\n");
const VALUES = [TOKEN, "FX-TEST-", "cu-fixture-", "sub-fixture-", "#FX0", "PX-0", "BX-0", "FAM-0", "Invented", "example.invalid", "Fixture note", "15/11/2034", "31/02/2035"];
expect("G1 no log line holds the token or a value: field ids and names, codes and counts only", VALUES.filter((v) => logText.includes(v)), [], VALUES);

await fake.close();
rmSync(secretsDir, { recursive: true, force: true });
verdict();
