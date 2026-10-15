/**
 * Verifier: the CMA data map (docs/datamap/README.md) describes every table and view in the schema
 * snapshot, and index.html is a fresh build. Runs tools/datamap/build.mjs's check; no database.
 *
 *   node tools/datamap/verify.mjs             expect PASS, exit 0
 *   node tools/datamap/verify.mjs --provoke   drops one catalog table, adds an unknown view to the
 *                                             schema and an unknown domain to a flow, in memory;
 *                                             expect FAIL naming all three, exit 1
 * (from web/: npm run verify:datamap)
 */
import { check, counts, load } from "./build.mjs";

const PROVOKE = process.argv.includes("--provoke");
const UNKNOWN = "provoked_unknown_view";
const UNKNOWN_DOMAIN = "provoked_unknown_domain";
const input = load();
let named = [];
if (PROVOKE) {
  const group = input.catalog.groups.find((g) => g.tables.length);
  const dropped = group.tables[0].name;
  group.tables = group.tables.slice(1);
  input.schema.columns = [...input.schema.columns, ["cma_read", UNKNOWN, "VIEW", "id", "uuid"]];
  const [flow, f] = Object.entries(input.catalog.flows)[0];
  f.doms = [...f.doms, UNKNOWN_DOMAIN];
  named = [`cma.${dropped}:`, `cma_read.${UNKNOWN}:`, `flow ${flow}: domain ${UNKNOWN_DOMAIN} `];
  console.log(`datamap: provoked, catalog table ${dropped} dropped, view cma_read.${UNKNOWN} added and flow ${flow} given domain ${UNKNOWN_DOMAIN}`);
}

const problems = check(input);
for (const p of problems) console.log(`  ${p}`);
const missed = named.filter((n) => !problems.some((p) => p.startsWith(n)));
if (missed.length) {
  // A provocation the check does not name is one it cannot fail on.
  console.log(`datamap: provoked, but not caught: ${missed.map((n) => n.slice(0, -1)).join(", ")}`);
  process.exit(0);
}
const { tables, views } = counts(input.schema);
console.log(problems.length === 0 ? `datamap: PASS (${tables} tables, ${views} views, all described; index.html current)`
  : `datamap: FAIL (${problems.length} problems)`);
process.exit(problems.length === 0 ? 0 : 1);
