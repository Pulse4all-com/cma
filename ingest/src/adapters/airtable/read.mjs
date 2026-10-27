/**
 * The Airtable reads (addition 0008zj): the base's schema and one table's records, page by page.
 *
 *   tables    GET /meta/bases/{baseId}/tables: the base's tables with their fields (id, name, type). Before a read the
 *             mapped fields are checked against the table: one the table lacks fails the read with unknown_field and
 *             names the field (a name, never a value)
 *   records   GET /{baseId}/{tableId}?pageSize=100&cellFormat=json&fields[]=<each mapped field>[&view=<view id>]
 *             [&filterByFormula=<formula>][&offset=<offset>]: offset paging until a page carries no offset. fields[]
 *             lists the mapped fields only, so a field the mapping does not name (a person's name, an email, a note)
 *             never leaves Airtable. A record's id is the API's record.id, the RECORD_ID() the CSV export carried
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

/** The formula that keeps the records modified after an instant (ms). */
export const modifiedAfter = (ms) => `IS_AFTER(LAST_MODIFIED_TIME(), DATETIME_PARSE("${new Date(ms).toISOString()}"))`;

/** An error for a mapped field the table lacks: code unknown_field, the field's name beside it (for the log only). */
export function unknownField(name) {
  const err = new SourceError("unknown_field");
  err.field = name;
  return err;
}

/** The API of a connection with its settings (cma.connection_config). */
export function clientFor(connection, settings, budget) {
  const api = airtableClient(connection, settings, budget);
  return {
    /** The base's tables: [{ id, name, fields: [{ name, type }] }]. */
    async tables(baseId) {
      const r = await api.get(`/meta/bases/${encodeURIComponent(baseId)}/tables`);
      const tables = Array.isArray(r?.tables) ? r.tables : [];
      return tables.filter((t) => typeof t?.id === "string").map((t) => ({
        id: t.id, name: typeof t.name === "string" ? t.name : "",
        fields: (Array.isArray(t.fields) ? t.fields : []).filter((f) => typeof f?.name === "string")
          .map((f) => ({ name: f.name, type: typeof f.type === "string" ? f.type : "unknown" })),
      }));
    },
    /**
     * The table's records, page by page: yields each page's records ({ id, fields }). fields: the field names to ask for;
     * viewId and formula optional.
     */
    async *records(baseId, tableId, { fields, viewId = null, formula = null }) {
      let offset = null;
      for (let page = 0; page < MAX_PAGES; page += 1) {
        const q = new URLSearchParams({ pageSize: String(PAGE_SIZE), cellFormat: "json" });
        for (const f of fields) q.append("fields[]", f);
        if (viewId) q.set("view", viewId);
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
 * The mapped fields checked against the base's schema: { fieldTypes, tableFields } (the type of each mapped field, and
 * how many fields the table holds), or SourceError unknown_table (no table with the setting's id) and unknown_field
 * (the first mapped field the table lacks, its name on the error). unknown lists every one the table lacks (the dry run's
 * count).
 */
export function checkFields(tables, tableId, names) {
  const table = tables.find((t) => t.id === tableId);
  if (!table) throw new SourceError("unknown_table");
  const types = new Map(table.fields.map((f) => [f.name, f.type]));
  const unknown = names.filter((n) => !types.has(n));
  return { fieldTypes: new Map(names.filter((n) => types.has(n)).map((n) => [n, types.get(n)])), tableFields: table.fields.length, unknown };
}
