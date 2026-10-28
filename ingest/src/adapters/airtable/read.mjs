/**
 * The Airtable reads (addition 0008zj; by field id since 0008zk): the base's schema and one table's records, page by page.
 *
 *   tables    GET /meta/bases/{baseId}/tables: the base's tables with their fields (id, name, type). Before a read the
 *             mapped fields (field ids, fld…) are checked against the table: one the table lacks (deleted) fails the
 *             read with unknown_field and names the field's id; one whose type differs from the type the connection
 *             recorded when it first read it fails with field_type_changed and names the field (its id and name,
 *             never a value). A field renamed in Airtable keeps its id, so a rename changes nothing
 *   records   GET /{baseId}/{tableId}?pageSize=100&cellFormat=json&returnFieldsByFieldId=true&fields[]=<each mapped field
 *             id>[&filterByFormula=<formula>][&offset=<offset>]: offset paging until a page carries no offset. fields[]
 *             lists the mapped fields only, so a field the mapping does not name (a person's name, an email, a note)
 *             never leaves Airtable, whatever a view of the table hides or shows; the record's fields come back keyed
 *             by id. No view: an asset register is read whole (a view's filter would make the devices outside it look
 *             missing at night). A field the API leaves out of a record is empty. A record's id is the API's record.id,
 *             the RECORD_ID() the CSV export carried. An expired offset fails the read paging_expired (client.mjs)
 *
 * The changed records: filterByFormula IS_AFTER(LAST_MODIFIED_TIME(), DATETIME_PARSE("<ISO>")), the instant being the
 * cursor less five minutes (index.mjs, OVERLAP_MS). LAST_MODIFIED_TIME() moves when any field of the record is edited; a value
 * a lookup draws from another table does not move it, which the nightly full snapshot catches.
 */
import { SourceError } from "../../core/http.mjs";
import { airtableClient } from "./client.mjs";

export const PAGE_SIZE = 100;
const MAX_PAGES = 5000;
const OFFSET = /^[A-Za-z0-9/_.-]{1,200}$/;
/** An Airtable field id: fld and fourteen letters or digits */
export const FIELD_ID = /^fld[A-Za-z0-9]{14}$/;

/** The formula that keeps the records modified after an instant (ms). */
export const modifiedAfter = (ms) => `IS_AFTER(LAST_MODIFIED_TIME(), DATETIME_PARSE("${new Date(ms).toISOString()}"))`;

/** An error naming a field (code, and the field's id and name beside it, for the log only). */
export function fieldError(code, id, name = null) {
  const err = new SourceError(code);
  err.field = id;
  if (name) err.fieldName = name;
  return err;
}

/** The API of a connection with its settings (cma.connection_config); full: a full read's pace. */
export function clientFor(connection, settings, budget, { full = false } = {}) {
  const api = airtableClient(connection, settings, budget, { full });
  return {
    /** The base's tables: [{ id, name, fields: [{ id, name, type }] }]. */
    async tables(baseId) {
      const r = await api.get(`/meta/bases/${encodeURIComponent(baseId)}/tables`);
      const tables = Array.isArray(r?.tables) ? r.tables : [];
      return tables.filter((t) => typeof t?.id === "string").map((t) => ({
        id: t.id, name: typeof t.name === "string" ? t.name : "",
        fields: (Array.isArray(t.fields) ? t.fields : []).filter((f) => typeof f?.id === "string")
          .map((f) => ({ id: f.id, name: typeof f.name === "string" ? f.name : "", type: typeof f.type === "string" ? f.type : "unknown" })),
      }));
    },
    /**
     * The table's records, page by page: yields each page's records ({ id, fields }, fields keyed by field id).
     * fields: the field ids to ask for; formula optional.
     */
    async *records(baseId, tableId, { fields, formula = null }) {
      let offset = null;
      for (let page = 0; page < MAX_PAGES; page += 1) {
        const q = new URLSearchParams({ pageSize: String(PAGE_SIZE), cellFormat: "json", returnFieldsByFieldId: "true" });
        for (const f of fields) q.append("fields[]", f);
        if (formula) q.set("filterByFormula", formula);
        if (offset) q.set("offset", offset);
        const r = await api.get(`/${encodeURIComponent(baseId)}/${encodeURIComponent(tableId)}?${q.toString()}`);
        const records = Array.isArray(r?.records) ? r.records : [];
        if (records.length) yield records;
        const next = typeof r?.offset === "string" && OFFSET.test(r.offset) ? r.offset : null;
        if (!next || next === offset) return;
        offset = next;
      }
      throw new SourceError("too_many_pages");
    },
  };
}

/**
 * The mapped fields (ids) checked against the base's schema and the types the connection recorded:
 * { list, names, types, tableFields, unknown, changed, unrecorded }. list: the table's fields ({ id, name, type }, the
 * dry run's); names and types: each mapped field's name and type (lower case) by id; unknown: the mapped ids the table
 * lacks; changed: the mapped fields whose type differs from the recorded one ({ id, name, was, now }); unrecorded: the
 * mapped fields without a recorded type ({ property, type }, for cma.ingest_record_field_types). SourceError
 * unknown_table when no table has the setting's id. recorded: a Map of property → recorded type (null for none).
 */
export function checkFields(tables, tableId, ids, recorded = new Map()) {
  const table = tables.find((t) => t.id === tableId);
  if (!table) throw new SourceError("unknown_table");
  const byId = new Map(table.fields.map((f) => [f.id, f]));
  const known = ids.filter((id) => byId.has(id));
  const typeOf = (id) => byId.get(id).type.toLowerCase();
  return {
    list: table.fields.map((f) => ({ id: f.id, name: f.name, type: f.type })),
    names: new Map(known.map((id) => [id, byId.get(id).name])),
    types: new Map(known.map((id) => [id, typeOf(id)])),
    tableFields: table.fields.length,
    unknown: ids.filter((id) => !byId.has(id)),
    changed: known.filter((id) => recorded.get(id) && recorded.get(id) !== typeOf(id))
      .map((id) => ({ id, name: byId.get(id).name, was: recorded.get(id), now: typeOf(id) })),
    unrecorded: known.filter((id) => !recorded.get(id)).map((id) => ({ property: id, type: typeOf(id) })),
  };
}
