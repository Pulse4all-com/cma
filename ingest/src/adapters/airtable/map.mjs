/**
 * Airtable records → the device import's staging rows (addition 0008zj), by the mapping the connection's fields hold
 * (cma.set_connection_field on the asset register connection; the import's map file of 0008zi as configuration). Each
 * property is an Airtable field id (fld…, since 0008zk: a field renamed in Airtable keeps it), generated from the dry
 * run's list of the table's fields (docs/ingest/airtable-fields.mjs):
 *
 *   entity device             field = a staging column (serial, model, status, country, warehouse_ref, customer_ref,
 *                             subscription_ref, order_ref, first_shipped_on, stock_received_on, last_shipped_on,
 *                             warranty_until, end_of_life_on) → the Airtable field that feeds it
 *   entity device_component   field serial or expires_on, ref_system the component kind → its field
 *   entity device, field ref  ref_system the id's name (ns_internal_id) → the field holding the named id
 *
 * An allow list: only the mapped fields are asked for and read, so nothing else a record holds reaches a row, a log or
 * the database. The record id is the API's record.id. No mapping means no read (mapping_not_set). A mapped field the
 * API leaves out of a record (Airtable leaves empty fields out) is empty: its column is null in the row, never left
 * out, so the load writes it empty rather than keeping the device's earlier value.
 *
 * Values as the CSV import's tool writes them (tools/devices-to-staging.mjs), so the database applies 0008zi's rules
 * unchanged (ids, unmapped labels, dropped references): text trimmed, a number or a yes/no as its text, a lookup's list
 * of values joined with ", ", anything else (an error cell, an object such as a collaborator or an attachment) left out
 * and counted as unreadable; a value holding an @ goes no further than a bare @ and is counted (valuesWithAt), never
 * logged. A date: an ISO date as it arrives from a date field (an ISO timestamp, such as a formula's date, by its date
 * as written); a date that arrives as text is read in the connection's date_format (dmy, mdy or iso; without one the
 * read fails date_format_not_set, naming the field), and one that does not read is left empty and counted
 * (dateFailures). The adapter adds no rule of its own: what an id is, and what is dropped, the load decides.
 */
import { SourceError } from "../../core/http.mjs";

export const OBJECT_TYPE = "device";
export const DEVICE_COLUMNS = ["serial", "model", "status", "country", "warehouse_ref", "customer_ref", "subscription_ref", "order_ref",
  "first_shipped_on", "stock_received_on", "last_shipped_on", "warranty_until", "end_of_life_on"];
export const DATE_COLUMNS = ["first_shipped_on", "stock_received_on", "last_shipped_on", "warranty_until", "end_of_life_on"];
const KIND = /^[a-z0-9]+(_[a-z0-9]+)*$/;
const NAME = /^[a-z][a-z0-9_]{0,39}$/;
const ISO = /^(\d{4})-(\d{2})-(\d{2})(T[0-9:.]+(Z|[+-]\d{2}:?\d{2})?)?$/;

/**
 * The mapping from the connection's configuration (cma.connection_config's fields): { columns: { column: field },
 * components: { kind: { serial?, expires_on? } }, refs: { name: field } }, or null when nothing is mapped. Slot 1 only.
 */
export function mappingOf(config) {
  const columns = {};
  const components = {};
  const refs = {};
  for (const f of config?.fields ?? []) {
    if ((f.slot ?? 1) !== 1 || typeof f.property !== "string" || !f.property.trim()) continue;
    const property = f.property.trim();
    if (f.entity === "device" && f.field === "ref" && NAME.test(f.refSystem ?? "")) refs[f.refSystem] = property;
    else if (f.entity === "device" && DEVICE_COLUMNS.includes(f.field)) columns[f.field] = property;
    else if (f.entity === "device_component" && KIND.test(f.refSystem ?? "") && (f.field === "serial" || f.field === "expires_on")) {
      components[f.refSystem] = { ...(components[f.refSystem] ?? {}), [f.field]: property };
    }
  }
  const any = Object.keys(columns).length + Object.keys(components).length + Object.keys(refs).length;
  return any ? { columns, components, refs } : null;
}

/** Every field the mapping reads, each once, in a fixed order: the fields[] of the read and the schema check. */
export function fieldNames(mapping) {
  return [...new Set([
    ...DEVICE_COLUMNS.map((c) => mapping.columns[c]).filter(Boolean),
    ...Object.keys(mapping.components).sort().flatMap((k) => [mapping.components[k].serial, mapping.components[k].expires_on]).filter(Boolean),
    ...Object.keys(mapping.refs).sort().map((n) => mapping.refs[n]),
  ])];
}

/** A date as text in a format → YYYY-MM-DD, or null when it does not read (as tools/devices-to-staging.mjs parseDate). */
export function parseDate(value, format) {
  const v = value.trim();
  const m = format === "iso" ? /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(v) : /^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})$/.exec(v);
  if (!m) return null;
  const [y, mo, d] = format === "iso" ? [m[1], m[2], m[3]] : format === "dmy" ? [m[3], m[2], m[1]] : [m[3], m[1], m[2]];
  return validDate(Number(y), Number(mo), Number(d));
}

function validDate(year, month, day) {
  const t = new Date(Date.UTC(year, month - 1, day));
  if (month < 1 || month > 12 || t.getUTCFullYear() !== year || t.getUTCMonth() !== month - 1 || t.getUTCDate() !== day) return null;
  return `${String(year).padStart(4, "0")}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
}

/** One cell as text: "" when empty, null when it cannot be read (an object, an error cell). */
export function cellText(value) {
  if (value === undefined || value === null) return "";
  if (typeof value === "string") return value.trim();
  if (typeof value === "number") return Number.isFinite(value) ? String(value) : null;
  if (typeof value === "boolean") return String(value);
  if (Array.isArray(value)) {
    const parts = value.map(cellText);
    return parts.some((p) => p === null) ? null : parts.filter((p) => p !== "").join(", ");
  }
  return null;
}

/**
 * A staging row from one record: { row, valuesWithAt, dateFailures, unreadable }. row holds the record id and every
 * mapped column as text (null when empty), the components and named ids as JSON text (null when none). A date that
 * arrives as text without the connection's date_format fails with date_format_not_set (the field on the error).
 */
export function rowOf(record, mapping, { dateFormat = null } = {}) {
  const fields = record?.fields && typeof record.fields === "object" ? record.fields : {};
  const tally = { valuesWithAt: 0, dateFailures: 0, unreadable: 0 };
  const text = (name) => {
    const v = cellText(fields[name]);
    if (v === null) {
      tally.unreadable += 1;
      return "";
    }
    if (!v.includes("@")) return v;
    tally.valuesWithAt += 1;
    return "@";
  };
  const date = (name) => {
    const v = text(name);
    if (v === "") return "";
    const iso = ISO.exec(v);
    if (iso) {
      const d = validDate(Number(iso[1]), Number(iso[2]), Number(iso[3]));
      if (d) return d;
    }
    if (!iso && v !== "@" && !dateFormat) {
      const err = new SourceError("date_format_not_set");
      err.field = name;
      throw err;
    }
    const d = iso || v === "@" ? null : parseDate(v, dateFormat);
    if (d === null) tally.dateFailures += 1;
    return d ?? "";
  };
  const row = { source_id: typeof record?.id === "string" ? record.id : null };
  for (const col of DEVICE_COLUMNS) {
    const name = mapping.columns[col];
    const v = name ? (DATE_COLUMNS.includes(col) ? date(name) : text(name)) : "";
    row[col] = v === "" ? null : v;
  }
  const components = {};
  for (const kind of Object.keys(mapping.components).sort()) {
    const spec = mapping.components[kind];
    const c = {};
    const serial = spec.serial ? text(spec.serial) : "";
    const expires = spec.expires_on ? date(spec.expires_on) : "";
    if (serial !== "") c.serial = serial;
    if (expires !== "") c.expires_on = expires;
    if (Object.keys(c).length) components[kind] = c;
  }
  const refs = {};
  for (const name of Object.keys(mapping.refs).sort()) {
    const v = text(mapping.refs[name]);
    if (v !== "") refs[name] = v;
  }
  row.components = Object.keys(components).length ? JSON.stringify(components) : null;
  row.external_refs = Object.keys(refs).length ? JSON.stringify(refs) : null;
  return { row, ...tally };
}
