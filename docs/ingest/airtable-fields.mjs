/**
 * The asset register's mapping by Airtable field id (addition 0008zk; PROD_RUNBOOK 14.5): the dry run's list of the
 * table's fields (id, name, type) and a map file of headers (docs/import/devices-map.example.json, the CSV import's
 * configuration of 0008zi) → the Studio statements that map each column, component and named id to its field's id.
 * Generated from the live schema, so a field renamed in Airtable later changes nothing (its id stays).
 *
 *   gcloud logging read '<the dry run's line>' --format=json | node docs/ingest/airtable-fields.mjs \
 *        --connection <assets conn> --map docs/import/devices-map.example.json
 *
 * Reads the log entry from stdin (the first entry holding jsonPayload.tableFieldList: field names, ids and types, never a
 * value). Prints the Studio block (the context lines with the runbook's placeholders, one cma.set_connection_field per
 * mapped header, each with its field's name as a comment, and the read-back) on stdout; on stderr the count mapped. Exits
 * 1, naming the header, when a mapped header is no field of the table or names two fields; the record id (source_id)
 * needs no field. Nothing is read from Airtable or the database: the dry run read the schema with the ingest's token.
 */
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const FIELD_ID = /^fld[A-Za-z0-9]{14}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** A field's name as an SQL line comment: printable characters only */
const commentOf = (name) => [...String(name)].map((c) => (c.charCodeAt(0) < 32 || c.charCodeAt(0) === 127 ? " " : c)).join("").trim();

/**
 * The mapping's statements: { lines, missing, ambiguous, mapped }. map: the map file's object (columns, components,
 * external_refs); fields: the dry run's tableFieldList ([{ id, name, type }]). A header is found by its exact name.
 */
export function mappingBlock({ connection, map, fields }) {
  const byName = new Map();
  for (const f of fields ?? []) {
    if (typeof f?.name !== "string" || !FIELD_ID.test(f?.id ?? "")) continue;
    byName.set(f.name, [...(byName.get(f.name) ?? []), f]);
  }
  const wanted = [];
  for (const [column, header] of Object.entries(map?.columns ?? {})) {
    if (column !== "source_id") wanted.push({ entity: "device", field: column, ref: "", header });
  }
  for (const [kind, spec] of Object.entries(map?.components ?? {})) {
    for (const field of ["serial", "expires_on"]) if (spec?.[field]) wanted.push({ entity: "device_component", field, ref: kind, header: spec[field] });
  }
  for (const [name, header] of Object.entries(map?.external_refs ?? {})) wanted.push({ entity: "device", field: "ref", ref: name, header });
  const missing = wanted.filter((w) => !byName.has(w.header)).map((w) => w.header);
  const ambiguous = wanted.filter((w) => (byName.get(w.header) ?? []).length > 1).map((w) => w.header);
  const lines = wanted.filter((w) => (byName.get(w.header) ?? []).length === 1).map((w) => {
    const f = byName.get(w.header)[0];
    return `select cma.set_connection_field('${connection}', '${w.entity}', '${w.field}', '${w.ref}', '${f.id}');  -- ${commentOf(f.name)} (${commentOf(f.type)})`;
  });
  return { lines, missing, ambiguous, mapped: lines.length };
}

/** The Studio block: the context, the statements, the read-back */
export function studioBlock(connection, lines) {
  return [
    "set role cma_app;",
    "select set_config('app.tenant_id', '<tenant_id>', false),",
    "       set_config('app.user_id', '<user_id>', false),",
    "       set_config('app.actor_label', 'studio:martin', false);",
    ...lines,
    "select entity, field, nullif(ref_system, '') as ref_system, source_property from cma.connection_field",
    `where connection_id = '${connection}' order by entity, field, ref_system;`,
    "reset role;",
  ].join("\n");
}

/** The table's fields from gcloud's JSON (an array of log entries, or one entry) */
export function fieldsOf(logText) {
  const parsed = JSON.parse(logText);
  const entries = Array.isArray(parsed) ? parsed : [parsed];
  const entry = entries.find((e) => Array.isArray(e?.jsonPayload?.tableFieldList));
  return entry ? entry.jsonPayload.tableFieldList : null;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const arg = (name) => {
    const i = process.argv.indexOf(`--${name}`);
    return i > 0 ? process.argv[i + 1] : undefined;
  };
  const connection = arg("connection");
  const mapPath = arg("map");
  if (!UUID.test(connection ?? "") || !mapPath) {
    console.error("usage: gcloud logging read … --format=json | node docs/ingest/airtable-fields.mjs --connection <assets conn> --map <map file>");
    process.exit(2);
  }
  const fields = fieldsOf(readFileSync(0, "utf8"));
  if (!fields) {
    console.error("no dry run's field list on stdin (the log line \"backfill dry run\" with tableFieldList)");
    process.exit(1);
  }
  const block = mappingBlock({ connection, map: JSON.parse(readFileSync(mapPath, "utf8")), fields });
  if (block.missing.length || block.ambiguous.length) {
    if (block.missing.length) console.error(`no field of the table is named ${block.missing.map((h) => `"${h}"`).join(", ")}`);
    if (block.ambiguous.length) console.error(`more than one field of the table is named ${block.ambiguous.map((h) => `"${h}"`).join(", ")}`);
    process.exit(1);
  }
  console.log(studioBlock(connection, block.lines));
  console.error(`${block.mapped} fields mapped by id; the table holds ${fields.length}`);
}
