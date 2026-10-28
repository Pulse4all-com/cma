/**
 * A fake Airtable Web API on localhost, for verify/assets-mapping.mjs and verify/assets-flow.mjs (addition 0008zj).
 * Everything is invented: bases, tables, fields, records, serials, customer ids, names (Invented Person …) and
 * addresses (example.invalid).
 *
 *   GET /v0/meta/bases/{base}/tables   the base's tables with their fields (id, name, type), with the right bearer token
 *   GET /v0/{base}/{table}             pageSize (at most 100), cellFormat (json only), fields[] (a field's id or name; an
 *                                      unknown one: 422 UNKNOWN_FIELD_NAME), returnFieldsByFieldId (true: a record's
 *                                      fields keyed by id, else by name), view (a view the table defines: its records;
 *                                      another: 404 VIEW_NAME_NOT_FOUND), filterByFormula (IS_AFTER(LAST_MODIFIED_TIME(),
 *                                      DATETIME_PARSE("<ISO>")) only: the records modified after it; another: 422
 *                                      INVALID_FILTER_BY_FORMULA), offset (opaque, itr<n>/<record id>): the records in id
 *                                      order, a page at a time, { records: [{ id, createdTime, fields }], offset? }, a
 *                                      record holding the asked fields that have a value only (Airtable leaves empty
 *                                      fields out)
 *
 * Switches on state: fail429 (the next n calls answer 429 and lock the base for lockoutMs, during which every call
 * answers 429, as Airtable locks a base for 30 seconds), failAfter (after n more record pages, every one answers 503
 * until cleared), expireOffsets (the next n requests that carry an offset answer 422 LIST_RECORDS_ITERATOR_NOT_AVAILABLE,
 * as Airtable does when a list's paging has expired), rename(base, table, from, to) (a field renamed: its id stays),
 * retype(base, table, name, type) (a field's type changed), drop(base, table, name) (a field deleted from the schema and
 * the records). state.requests records { path, endpoint, fields, byId, view, formula, offset, authorized } per call
 * (never the token).
 */
import http from "node:http";

const FORMULA = /^IS_AFTER\(LAST_MODIFIED_TIME\(\), DATETIME_PARSE\("([^"]+)"\)\)$/;

/** The fixture base: one table of the register with its mapped and personal fields, and a view of the field devices. */
export function assetsSource(nowMs = Date.now()) {
  const fields = [
    ["aed_sn", "singleLineText"], ["model_aed", "singleSelect"], ["aed_operational_status", "singleSelect"], ["country_located", "singleSelect"],
    ["warehouse_location", "singleLineText"], ["customer_id", "singleLineText"], ["subscription_id", "singleLineText"], ["order_number", "singleLineText"],
    ["first_shipment_date_to_customer", "date"], ["warehouse_received_date", "date"], ["last_shipment_date", "date"],
    ["aed_warranty_date_calculated", "formula"], ["aed_expected_end_of_life_date_calculated", "singleLineText"],
    ["pads_sn", "singleLineText"], ["pads_expiry_date_calculated", "date"], ["battery_sn", "singleLineText"], ["battery_expiry_date_calculated", "date"],
    ["ns_internal_id", "number"], ["ns_fam_id", "singleLineText"], ["sales_order_id", "singleLineText"],
    // never mapped: a person's names, an email, who changed the row last, a note
    ["customer_first_name", "singleLineText"], ["customer_last_name", "singleLineText"], ["email", "email"], ["last_modified_by", "lastModifiedBy"],
    ["match_note", "multilineText"],
  ].map(([name, type], i) => ({ id: `fldFixture${String(i).padStart(7, "0")}`, name, type }));
  const ago = (minutes) => new Date(nowMs - minutes * 60_000).toISOString();
  const pad = (n) => String(n).padStart(4, "0");
  const records = [];
  for (let n = 1; n <= 200; n += 1) {
    records.push({
      id: `recFixture${pad(n)}aaa`, modifiedAt: ago(60 * 24 * 3), fields: {
        aed_sn: `FX-TEST-${pad(n)}`, model_aed: n % 2 ? "HS1" : "FRx", aed_operational_status: n % 10 ? "Active/Customer" : "In Storage",
        country_located: n % 3 ? "Netherlands" : "United Kingdom", warehouse_location: n % 10 ? undefined : "WH-FIXTURE",
        customer_id: n % 10 ? `cu-fixture-${pad(n)}` : undefined, subscription_id: n % 10 ? `sub-fixture-${pad(n)}` : undefined,
        order_number: n % 10 ? `#FX${pad(n)}` : undefined, first_shipment_date_to_customer: "2024-11-15",
        last_shipment_date: n % 4 ? undefined : "2025-03-01", aed_warranty_date_calculated: "2029-11-15T00:00:00.000Z",
        aed_expected_end_of_life_date_calculated: "15/11/2034", pads_sn: `PX-${pad(n)}`, pads_expiry_date_calculated: "2026-12-10",
        battery_sn: `BX-${pad(n)}`, battery_expiry_date_calculated: "2027-01-20", ns_internal_id: 9000 + n, ns_fam_id: `FAM-${pad(n)}`,
        sales_order_id: n % 5 ? undefined : `SO-${pad(n)}`,
        customer_first_name: `Invented Person ${pad(n)}`, customer_last_name: "Fixture", email: `person-${pad(n)}@example.invalid`,
        last_modified_by: { id: "usrFixture000001", email: "editor@example.invalid", name: "Invented Editor" }, match_note: "Fixture note text",
      },
    });
  }
  // the special ones: an address as a customer id, a formula error, a lookup's list, a text date that does not read
  records.push({ id: "recFixtureX001aaa", modifiedAt: ago(60 * 24 * 2), fields: { aed_sn: "FX-TEST-X001", model_aed: "HS1", aed_operational_status: "Active/Customer",
    country_located: ["Netherlands"], customer_id: "person-x001@example.invalid", first_shipment_date_to_customer: "2025-01-10",
    aed_warranty_date_calculated: { error: "#ERROR!" }, aed_expected_end_of_life_date_calculated: "31/02/2035", ns_internal_id: 9901,
    customer_first_name: "Invented Person X001", email: "person-x001@example.invalid" } });
  return {
    baseId: "appFixtureAssets1", tableId: "tblFixtureAssets1", tableName: "Installed base (fixture)", fields, records,
    views: { viwFixtureField01: (r) => r.fields.aed_operational_status === "Active/Customer" },
  };
}

export async function startFakeAirtable({ token, bases }) {
  const state = { requests: [], fail429: 0, lockoutMs: 300, lockedUntil: 0, failAfter: null, expireOffsets: 0, pagesAnswered: 0, bases };
  state.table = (baseId, tableId) => state.bases[baseId]?.tables.find((t) => t.id === tableId) ?? null;
  state.rename = (baseId, tableId, from, to) => {
    const t = state.table(baseId, tableId);
    for (const f of t.fields) if (f.name === from) f.name = to;
    for (const r of t.records) if (Object.hasOwn(r.fields, from)) { r.fields[to] = r.fields[from]; delete r.fields[from]; }
  };
  state.retype = (baseId, tableId, name, type) => {
    for (const f of state.table(baseId, tableId).fields) if (f.name === name) f.type = type;
  };
  state.drop = (baseId, tableId, name) => {
    const t = state.table(baseId, tableId);
    const i = t.fields.findIndex((f) => f.name === name);
    const [field] = t.fields.splice(i, 1);
    for (const r of t.records) delete r.fields[name];
    return field;
  };
  const json = (res, status, body) => {
    res.writeHead(status, { "content-type": "application/json" });
    res.end(JSON.stringify(body));
  };
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, "http://x");
    const authorized = req.headers.authorization === `Bearer ${token}`;
    const fields = url.searchParams.getAll("fields[]");
    const byId = url.searchParams.get("returnFieldsByFieldId") === "true";
    const entry = { method: req.method, path: url.pathname, fields, byId, view: url.searchParams.get("view"), formula: url.searchParams.get("filterByFormula"),
      offset: url.searchParams.get("offset"), cellFormat: url.searchParams.get("cellFormat"), pageSize: url.searchParams.get("pageSize"), authorized };
    state.requests.push(entry);
    req.resume();
    if (req.method !== "GET") return json(res, 405, { error: { type: "METHOD_NOT_ALLOWED" } });
    if (!authorized) return json(res, 401, { error: { type: "AUTHENTICATION_REQUIRED" } });
    if (state.fail429 > 0 || Date.now() < state.lockedUntil) {
      if (state.fail429 > 0) {
        state.fail429 -= 1;
        state.lockedUntil = Date.now() + state.lockoutMs;
      }
      return json(res, 429, { errors: [{ error: "RATE_LIMIT_REACHED" }] });
    }
    const meta = /^\/v0\/meta\/bases\/([A-Za-z0-9]+)\/tables$/.exec(url.pathname);
    if (meta) {
      const base = state.bases[meta[1]];
      if (!base) return json(res, 404, { error: { type: "NOT_FOUND" } });
      return json(res, 200, { tables: base.tables.map((t) => ({ id: t.id, name: t.name, primaryFieldId: t.fields[0].id,
        fields: t.fields.map((f) => ({ id: f.id, name: f.name, type: f.type })), views: Object.keys(t.views ?? {}).map((id) => ({ id, name: id, type: "grid" })) })) });
    }
    const list = /^\/v0\/([A-Za-z0-9]+)\/([A-Za-z0-9]+)$/.exec(url.pathname);
    if (!list) return json(res, 404, { error: { type: "NOT_FOUND" } });
    const table = state.table(list[1], list[2]);
    if (!table) return json(res, 404, { error: { type: "TABLE_NOT_FOUND" } });
    if (state.failAfter !== null && state.pagesAnswered >= state.failAfter) return json(res, 503, { error: { type: "SERVICE_UNAVAILABLE" } });
    if (url.searchParams.get("cellFormat") !== "json") return json(res, 422, { error: { type: "INVALID_REQUEST_UNKNOWN" } });
    // fields[] by id or by name, as Airtable takes either; the answer keyed by id with returnFieldsByFieldId
    const asked = fields.map((f) => table.fields.find((x) => x.id === f || x.name === f) ?? f);
    const unknown = asked.find((f) => typeof f === "string");
    if (unknown) return json(res, 422, { error: { type: "UNKNOWN_FIELD_NAME", message: `Unknown field name: "${unknown}"` } });
    if (state.expireOffsets > 0 && url.searchParams.get("offset")) {
      state.expireOffsets -= 1;
      return json(res, 422, { error: { type: "LIST_RECORDS_ITERATOR_NOT_AVAILABLE", message: "The iterator is no longer available" } });
    }
    let records = [...table.records].sort((a, b) => (a.id < b.id ? -1 : 1));
    const view = url.searchParams.get("view");
    if (view) {
      if (!table.views?.[view]) return json(res, 404, { error: { type: "VIEW_NAME_NOT_FOUND" } });
      records = records.filter(table.views[view]);
    }
    const formula = url.searchParams.get("filterByFormula");
    if (formula) {
      const m = FORMULA.exec(formula);
      if (!m || !Number.isFinite(Date.parse(m[1]))) return json(res, 422, { error: { type: "INVALID_FILTER_BY_FORMULA" } });
      records = records.filter((r) => Date.parse(r.modifiedAt) > Date.parse(m[1]));
    }
    const size = Math.min(100, Math.max(1, Number(url.searchParams.get("pageSize") ?? 100)));
    const offset = url.searchParams.get("offset");
    const start = offset ? Number(/^itr(\d+)\//.exec(offset)?.[1] ?? NaN) : 0;
    if (!Number.isInteger(start)) return json(res, 422, { error: { type: "LIST_RECORDS_ITERATOR_NOT_AVAILABLE" } });
    const page = records.slice(start, start + size);
    state.pagesAnswered += 1;
    const out = page.map((r) => ({ id: r.id, createdTime: "2024-01-01T00:00:00.000Z",
      fields: Object.fromEntries(asked.filter((f) => r.fields[f.name] !== undefined && r.fields[f.name] !== null && r.fields[f.name] !== "")
        .map((f) => [byId ? f.id : f.name, r.fields[f.name]])) }));
    const next = start + size < records.length ? `itr${start + size}/${records[start + size - 1].id}` : undefined;
    return json(res, 200, next ? { records: out, offset: next } : { records: out });
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  return {
    url: `http://127.0.0.1:${server.address().port}`,
    state,
    close: () => new Promise((r) => server.close(r)),
  };
}

/** The base map the fake serves, from one or more sources (assetsSource). */
export function basesOf(...sources) {
  return Object.fromEntries(sources.map((s) => [s.baseId, { tables: [{ id: s.tableId, name: s.tableName, fields: s.fields, records: s.records, views: s.views }] }]));
}
