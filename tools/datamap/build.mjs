#!/usr/bin/env node
/**
 * CMA data map (docs/datamap/README.md): builds docs/datamap/index.html from template.html, the
 * hand-written catalog.json and the schema snapshot schema.json (tools/datamap/schema.sql).
 *
 *   node tools/datamap/build.mjs           writes index.html; refuses, nothing written, while the
 *                                          catalog and the snapshot disagree
 *   node tools/datamap/build.mjs --check   builds in memory; exit 1 listing every problem
 * (from web/: npm run verify:datamap, which runs the check through verify.mjs)
 *
 * The check fails when
 *   (a) a table in schema cma (BASE TABLE) has no catalog entry
 *   (b) a catalog table is not a table in cma, or a derived entry not a view in cma_read, in schema.json
 *   (c) a relation in cma_read is none of: a view over a catalog table, a derived entry, a dq_ view
 *   (d) a name appears twice in the catalog
 *   (e) index.html differs from a fresh build
 * and when a catalog entry has no what (a table also no how), or the template has no single
 * `const DATA = __DATA__;`.
 *
 * The page's stamp is the snapshot's generated_at (meta.built_at), never the clock, so the same
 * three files always build the same page. Plain Node, no dependencies.
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export const DIR = fileURLToPath(new URL("../../docs/datamap/", import.meta.url));
const PLACEHOLDER = "const DATA = __DATA__;";

export function load(dir = DIR) {
  const read = (f) => readFileSync(dir + f, "utf8");
  return {
    catalog: JSON.parse(read("catalog.json")),
    schema: JSON.parse(read("schema.json")),
    template: read("template.html"),
    current: existsSync(dir + "index.html") ? read("index.html") : null,
  };
}

// schema.json's columns, in schema order, as relations: "cma.workday" → { type, columns: [{ n, t }] }
export function relations(schema) {
  const rel = new Map();
  for (const [s, table, type, n, t] of schema.columns) {
    const key = `${s}.${table}`;
    if (!rel.has(key)) rel.set(key, { schema: s, name: table, type, columns: [] });
    rel.get(key).columns.push({ n, t });
  }
  return rel;
}

const catalogTables = (catalog) => catalog.groups.flatMap((g) => g.tables.map((t) => ({ ...t, domain: g.key })));

export function buildData(catalog, schema) {
  const rel = relations(schema);
  const all = [...rel.values()];
  const readViews = all.filter((r) => r.schema === "cma_read" && r.type === "VIEW");
  const readCols = (name) => new Set(rel.get(`cma_read.${name}`)?.columns.map((c) => c.n) ?? []);
  const base = (name) => { const r = rel.get(`cma.${name}`); return r?.type === "BASE TABLE" ? r.columns : []; };
  return {
    meta: { built_at: schema.generated_at, generated_at: schema.generated_at, latest_migration: schema.latest_migration },
    domains: catalog.groups.map((g) => ({ key: g.key, label: g.label, sources: g.sources })),
    tables: catalogTables(catalog).map((t) => {
      const r = readCols(t.name);
      return { name: t.name, domain: t.domain, what: t.what, how: t.how, inRead: rel.get(`cma_read.${t.name}`)?.type === "VIEW",
               columns: base(t.name).map((c) => ({ n: c.n, t: c.t, r: r.has(c.n) })) };
    }),
    derived: catalog.derived.map((d) => ({ name: d.name, what: d.what,
      columns: (rel.get(`cma_read.${d.name}`)?.columns ?? []).map((c) => ({ n: c.n, t: c.t, r: true })) })),
    dq: readViews.map((r) => r.name).filter((n) => n.startsWith("dq_")).sort(),
    readCount: readViews.length,
  };
}

// One domain, table or derived view per line, so a new column changes one line of index.html.
// "<" is escaped so no text in the catalog can close the script element.
export function serialise(data) {
  const list = (a) => (a.length ? `[\n${a.map((x) => JSON.stringify(x)).join(",\n")}\n]` : "[]");
  const text = `{\n"meta": ${JSON.stringify(data.meta)},\n"domains": ${list(data.domains)},\n"tables": ${list(data.tables)},` +
    `\n"derived": ${list(data.derived)},\n"dq": ${JSON.stringify(data.dq)},\n"readCount": ${data.readCount}\n}`;
  return text.replace(/</g, "\\u003c");
}

export function render(template, data) {
  if (template.split(PLACEHOLDER).length !== 2) return null;
  return template.replace(PLACEHOLDER, () => `const DATA = ${serialise(data)};`);
}

// Every problem, the catalog against the snapshot; with current (index.html, or null when missing)
// also the page against a fresh build.
export function check({ catalog, schema, template, current }, { page = true } = {}) {
  const problems = [];
  const rel = relations(schema);
  const tables = catalogTables(catalog);
  const derived = catalog.derived;

  const seen = new Set();
  for (const e of [...tables, ...derived]) {
    if (seen.has(e.name)) problems.push(`catalog ${e.name}: appears twice in the catalog`);
    seen.add(e.name);
  }
  for (const t of tables) {
    if (!String(t.what ?? "").trim()) problems.push(`catalog ${t.name}: no what`);
    if (!String(t.how ?? "").trim()) problems.push(`catalog ${t.name}: no how`);
  }
  for (const d of derived) if (!String(d.what ?? "").trim()) problems.push(`catalog ${d.name}: no what`);

  const tableNames = new Set(tables.map((t) => t.name));
  const derivedNames = new Set(derived.map((d) => d.name));
  for (const r of rel.values()) {
    if (r.schema === "cma" && r.type === "BASE TABLE" && !tableNames.has(r.name))
      problems.push(`cma.${r.name}: table has no catalog entry`);
    if (r.schema === "cma_read" && r.type !== "VIEW")
      problems.push(`cma_read.${r.name}: a ${r.type}, where cma_read holds views only`);
    else if (r.schema === "cma_read" && !tableNames.has(r.name) && !derivedNames.has(r.name) && !r.name.startsWith("dq_"))
      problems.push(`cma_read.${r.name}: view is not over a catalog table, not a derived entry and not a dq_ view`);
  }
  for (const name of tableNames)
    if (rel.get(`cma.${name}`)?.type !== "BASE TABLE") problems.push(`catalog ${name}: not a table in cma in schema.json`);
  for (const name of derivedNames)
    if (rel.get(`cma_read.${name}`)?.type !== "VIEW") problems.push(`catalog ${name}: derived, not a view in cma_read in schema.json`);

  const html = render(template, buildData(catalog, schema));
  if (html === null) problems.push(`template.html: needs exactly one ${PLACEHOLDER}`);
  else if (page && current === null) problems.push("index.html: missing; run node tools/datamap/build.mjs");
  else if (page && current !== html) problems.push("index.html: differs from a fresh build; run node tools/datamap/build.mjs");
  return problems;
}

export function counts(schema) {
  const all = [...relations(schema).values()];
  return { tables: all.filter((r) => r.schema === "cma" && r.type === "BASE TABLE").length,
           views: all.filter((r) => r.schema === "cma_read" && r.type === "VIEW").length };
}

export function main(argv) {
  const input = load();
  const { tables, views } = counts(input.schema);
  if (argv.includes("--check")) {
    const problems = check(input);
    for (const p of problems) console.log(`  ${p}`);
    console.log(problems.length ? `datamap: ${problems.length} problem(s)` : `datamap: ${tables} tables, ${views} views, all described; index.html current`);
    return problems.length ? 1 : 0;
  }
  const problems = check(input, { page: false });
  if (problems.length) {
    console.log(`datamap: refused, nothing written: ${problems.length} problem(s)`);
    for (const p of problems) console.log(`  ${p}`);
    return 1;
  }
  writeFileSync(DIR + "index.html", render(input.template, buildData(input.catalog, input.schema)));
  console.log(`datamap: wrote docs/datamap/index.html (${tables} tables, ${views} views)`);
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  process.exit(main(process.argv.slice(2)));
}
