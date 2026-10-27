#!/usr/bin/env node
/**
 * The asset register's CSV export to the CMA's staging shape (addition 0008zi, docs/import/devices.md).
 *
 *   node tools/devices-to-staging.mjs <export.csv> --map <map.json> --date-format dmy|mdy|iso --batch <key>
 *        --out <staging.csv> [--delimiter auto|;|,|tab]
 *
 * Reads the register's export and writes the file that is copied into cma.device_import_staging: batch_key,
 * source_row, source_id, serial, model, status, country, warehouse_ref, customer_ref, subscription_ref, order_ref,
 * first_shipped_on, stock_received_on, last_shipped_on, warranty_until, end_of_life_on, components (a JSON object of
 * component kinds, each with serial and expires_on) and external_refs (a JSON object of named ids), every date as
 * YYYY-MM-DD. Plain Node, no dependencies.
 *
 * The map (JSON; the export's headers are configuration, never code; docs/import/devices-map.example.json):
 *   columns        staging column -> export header, for source_id (required), serial, model, status, country,
 *                  warehouse_ref, customer_ref, subscription_ref, order_ref and the five dates
 *   components     component kind (the tenant's catalog key) -> { serial: header, expires_on: header }, either or both
 *   external_refs  name of the id (lower-case letters, digits and _) -> header
 *   ignore         the export's other headers, read by name and never used: every header the export holds must be
 *                  mapped or ignored, so a column added to the register (a name, an email) is refused, not staged
 *
 * --date-format is required and never guessed: dmy (31-12-2026, 31/12/2026, 31.12.2026), mdy (12/31/2026) or iso
 * (2026-12-31); a day or month with one digit reads too. A date cell that does not read in that format is written
 * empty and counted (date_parse_failures, with its line and column, never its value); a wrong format shows as many.
 * Line ends CRLF or LF, an optional UTF-8 byte order mark, quoted fields as in RFC 4180.
 *
 * Refuses (exit 1, nothing written) an export header that is neither mapped nor ignored, a mapped header the export
 * lacks, a header both mapped and ignored, a map that names an unknown staging column or a malformed kind or name, a
 * row without a record id, a record id that appears twice (the lines named), and a cell longer than 500 characters.
 * Prints counts and the output path only, never a value.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { detectDelimiter, parseCsv } from "./legacy-sessions-to-staging.mjs";

export const DEVICE_COLUMNS = ["source_id", "serial", "model", "status", "country", "warehouse_ref", "customer_ref", "subscription_ref",
  "order_ref", "first_shipped_on", "stock_received_on", "last_shipped_on", "warranty_until", "end_of_life_on"];
export const DATE_COLUMNS = ["first_shipped_on", "stock_received_on", "last_shipped_on", "warranty_until", "end_of_life_on"];
export const STAGING_HEADER = ["batch_key", "source_row", ...DEVICE_COLUMNS, "components", "external_refs"];
export const DATE_FORMATS = ["dmy", "mdy", "iso"];
const KEY_RE = /^[a-z0-9]+(_[a-z0-9]+)*$/;
const NAME_RE = /^[a-z][a-z0-9_]{0,39}$/;
const MAX_CELL = 500;

const csvCell = (v) => (/[",\r\n]/.test(v) ? `"${v.replaceAll('"', '""')}"` : v);

/** A date cell as YYYY-MM-DD in the given format, "" for an empty cell, null when it does not read */
export function parseDate(value, format) {
  const v = value.trim();
  if (v === "") return "";
  const m = format === "iso" ? /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(v) : /^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})$/.exec(v);
  if (!m) return null;
  const [y, mo, d] = format === "iso" ? [m[1], m[2], m[3]] : format === "dmy" ? [m[3], m[2], m[1]] : [m[3], m[1], m[2]];
  const year = Number(y);
  const month = Number(mo);
  const day = Number(d);
  const t = new Date(Date.UTC(year, month - 1, day));
  if (month < 1 || month > 12 || t.getUTCFullYear() !== year || t.getUTCMonth() !== month - 1 || t.getUTCDate() !== day) return null;
  return `${String(year).padStart(4, "0")}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
}

/** The map's problems, or an empty list: unknown staging columns, malformed kinds or names, a header mapped and ignored */
export function mapProblems(map) {
  const problems = [];
  if (!map || typeof map !== "object" || Array.isArray(map)) return ["the map is a JSON object with columns, components, external_refs and ignore"];
  for (const k of Object.keys(map)) if (!["columns", "components", "external_refs", "ignore", "_about"].includes(k)) problems.push(`the map has an unknown key ${k}`);
  const columns = map.columns ?? {};
  for (const [col, header] of Object.entries(columns)) {
    if (!DEVICE_COLUMNS.includes(col)) problems.push(`columns: ${col} is no staging column`);
    if (typeof header !== "string" || header === "") problems.push(`columns: ${col} needs an export header`);
  }
  if (!columns.source_id) problems.push("columns: source_id (the register's record id) is required");
  for (const [kind, spec] of Object.entries(map.components ?? {})) {
    if (!KEY_RE.test(kind) || kind === "device") problems.push(`components: ${kind} is no component kind key`);
    if (!spec || typeof spec !== "object" || (!spec.serial && !spec.expires_on)
        || Object.keys(spec).some((k) => !["serial", "expires_on"].includes(k) || typeof spec[k] !== "string")) {
      problems.push(`components: ${kind} takes serial and expires_on headers`);
    }
  }
  for (const [name, header] of Object.entries(map.external_refs ?? {})) {
    if (!NAME_RE.test(name)) problems.push(`external_refs: ${name} is no name (lower-case letters, digits and _)`);
    if (typeof header !== "string" || header === "") problems.push(`external_refs: ${name} needs an export header`);
  }
  if (!Array.isArray(map.ignore ?? []) || (map.ignore ?? []).some((h) => typeof h !== "string")) problems.push("ignore is a list of headers");
  const mapped = mappedHeaders(map);
  for (const h of map.ignore ?? []) if (mapped.includes(h)) problems.push(`the header "${h}" is both mapped and ignored`);
  return problems;
}

/** Every export header the map reads */
export function mappedHeaders(map) {
  return [...new Set([
    ...Object.values(map.columns ?? {}),
    ...Object.values(map.components ?? {}).flatMap((s) => [s?.serial, s?.expires_on].filter(Boolean)),
    ...Object.values(map.external_refs ?? {}),
  ])];
}

/**
 * The export as staging rows: { rows, counts, problems, failures }. Pure: text in, rows out. A problem refuses the file;
 * a date that does not read is a failure, written empty and counted
 */
export function convert(text, map, { batch, dateFormat, delimiter }) {
  const problems = mapProblems(map);
  if (problems.length) return { rows: [], counts: {}, problems, failures: [] };
  const all = parseCsv(text, delimiter && delimiter !== "auto" ? delimiter : detectDelimiter(text));
  if (all.length === 0) return { rows: [], counts: {}, problems: ["the export is empty"], failures: [] };
  const header = all[0].map((h) => h.trim());
  const ignore = new Set(map.ignore ?? []);
  const mapped = mappedHeaders(map);
  const unknown = header.filter((h) => h !== "" && !mapped.includes(h) && !ignore.has(h));
  if (unknown.length) problems.push(`headers neither mapped nor ignored: ${unknown.map((h) => `"${h}"`).join(", ")}`);
  const missing = mapped.filter((h) => !header.includes(h));
  if (missing.length) problems.push(`mapped headers the export lacks: ${missing.map((h) => `"${h}"`).join(", ")}`);
  if (problems.length) return { rows: [], counts: {}, problems, failures: [] };

  const index = (h) => header.indexOf(h);
  const cell = (r, h) => (h ? (r[index(h)] ?? "").trim() : "");
  const rows = [];
  const failures = [];
  const seen = new Map();
  for (let i = 1; i < all.length; i++) {
    const r = all[i];
    const line = i + 1;
    if (r.every((c) => c.trim() === "")) continue;
    const long = mapped.find((h) => cell(r, h).length > MAX_CELL);
    if (long) { problems.push(`line ${line}: "${long}" is longer than ${MAX_CELL} characters`); continue; }
    const id = cell(r, map.columns.source_id);
    if (id === "") { problems.push(`line ${line}: no record id`); continue; }
    seen.set(id, [...(seen.get(id) ?? []), line]);
    const values = DEVICE_COLUMNS.map((col) => {
      const v = cell(r, map.columns[col]);
      if (!DATE_COLUMNS.includes(col)) return v;
      const d = parseDate(v, dateFormat);
      if (d === null) { failures.push(`line ${line}: ${col}`); return ""; }
      return d;
    });
    const components = {};
    for (const [kind, spec] of Object.entries(map.components ?? {})) {
      const serial = cell(r, spec.serial);
      let expires = cell(r, spec.expires_on);
      if (expires !== "") {
        const d = parseDate(expires, dateFormat);
        if (d === null) { failures.push(`line ${line}: ${kind}.expires_on`); expires = ""; } else expires = d;
      }
      const c = {};
      if (serial !== "") c.serial = serial;
      if (expires !== "") c.expires_on = expires;
      if (Object.keys(c).length) components[kind] = c;
    }
    const refs = {};
    for (const [name, h] of Object.entries(map.external_refs ?? {})) {
      const v = cell(r, h);
      if (v !== "") refs[name] = v;
    }
    rows.push([batch, String(line), ...values, Object.keys(components).length ? JSON.stringify(components) : "",
      Object.keys(refs).length ? JSON.stringify(refs) : ""]);
  }
  for (const [id, lines] of seen) if (lines.length > 1) problems.push(`lines ${lines.join(", ")}: one record id appears ${lines.length} times`);
  const counts = {
    rows: rows.length,
    mapped_columns: mapped.length,
    ignored_columns: header.filter((h) => ignore.has(h)).length,
    date_parse_failures: failures.length,
  };
  return { rows, counts, problems, failures };
}

/** The staging file: a header, LF line ends, cells quoted where needed */
export function stagingCsv(rows) {
  return [STAGING_HEADER, ...rows].map((r) => r.map(csvCell).join(",")).join("\n") + "\n";
}

// ---- the command ----------------------------------------------------------------------------

function args(argv) {
  const o = { files: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) o[a.slice(2)] = argv[++i];
    else o.files.push(a);
  }
  return o;
}

export function main(argv) {
  const o = args(argv);
  const [exportPath] = o.files;
  if (!exportPath || !o.map || !o["date-format"] || !o.batch || !o.out) {
    console.error("usage: devices-to-staging.mjs <export.csv> --map <map.json> --date-format dmy|mdy|iso --batch <key> --out <staging.csv> [--delimiter auto|;|,|tab]");
    return 2;
  }
  if (!DATE_FORMATS.includes(o["date-format"])) {
    console.error("--date-format is dmy, mdy or iso; the tool never guesses it");
    return 2;
  }
  if (!/^[a-z0-9_-]+$/.test(o.batch) || o.batch.length > 64) {
    console.error("the batch key is lowercase letters, digits, - and _, at most 64");
    return 2;
  }
  let map;
  try { map = JSON.parse(readFileSync(o.map, "utf8")); } catch { console.error(`the map ${o.map} is no JSON file`); return 2; }
  const delimiter = o.delimiter === "tab" ? "\t" : o.delimiter;
  const result = convert(readFileSync(exportPath, "utf8"), map, { batch: o.batch, dateFormat: o["date-format"], delimiter });
  if (result.problems.length) {
    console.error(`refused, nothing written: ${result.problems.length} problem(s)`);
    for (const p of result.problems.slice(0, 20)) console.error(`  ${p}`);
    if (result.problems.length > 20) console.error(`  … and ${result.problems.length - 20} more`);
    return 1;
  }
  writeFileSync(o.out, stagingCsv(result.rows));
  for (const [k, v] of Object.entries(result.counts)) console.log(`${k.padEnd(28)} ${v}`);
  for (const f of result.failures.slice(0, 10)) console.log(`  date not read: ${f}`);
  if (result.failures.length > 10) console.log(`  … and ${result.failures.length - 10} more`);
  console.log(`staging file                 ${o.out}`);
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  process.exit(main(process.argv.slice(2)));
}
