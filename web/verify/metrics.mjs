/**
 * Verifier: the metric catalog (docs/metrics/catalog.json), without a browser, a server or a
 * database.
 *
 *   node --experimental-strip-types verify/metrics.mjs             every check must PASS
 *   node --experimental-strip-types verify/metrics.mjs --provoke   every check must FAIL
 *
 * Covers, in the order the summary prints them:
 *   - the catalog validates against docs/metrics/schema.json (a small validator of exactly the
 *     schema features that file uses), and every key is unique
 *   - the registry (PAGE_METRIC_KEYS in src/lib/metrics.ts): every registered key has a catalog
 *     entry, and every catalog entry on a page surface (welcome, live, dashboard, report, agent)
 *     is registered under its page, so a figure without a catalog entry fails the build
 *   - every computed_in.sql object is created somewhere in db/*.sql
 *   - every verify_sql that uses a function or view reading the session (app.tenant_id, or the acting user through
 *     app.user_id: cma.current_tenant_id, cma.time_is_kept, cma.user_timezone, cma.has_permission, the faces
 *     cma.time_interval and cma.workday_summary, …, found in db/*.sql's latest definitions, through what they call)
 *     sets them itself for its own transaction, set_config('app.tenant_id', …, true) and, where the acting user is read,
 *     set_config('app.user_id', …, true) (a session-wide false would stay on Martin's Studio session after the query):
 *     without them such a query answers 0 or nothing, without a warning (19 November 2026, live.paid_today_minutes in prod)
 *   - every settings key an entry names is in the settings catalog (the cma.setting inserts in
 *     db/*.sql)
 *   - docs/metrics/METRICS.md and src/lib/metrics-catalog.json equal the generator's output
 *     (scripts/metrics-doc.mjs), so neither is ever hand-edited
 *   - the page's gate (metricsPageStatus, the configuration gate's decision: 200 renders the
 *     catalog, 403 renders the gate's no-permission card with nothing read and no rail item, as on
 *     every configuration page): the admin's permissions answer 200; the manager's, the analyst's,
 *     the agent's and the reader's answer 403 (the default ladder's sets, as verify/preview.mjs
 *     models them; the served page is covered by the theme and layout verifiers)
 */
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { generate, webCopy } from "../scripts/metrics-doc.mjs";
import { metricsPageStatus, PAGE_METRIC_KEYS, registeredKeys } from "../src/lib/metrics.ts";

const PROVOKE = process.argv.includes("--provoke");
const root = new URL("..", import.meta.url).pathname;
const problems = [];
const say = (line) => console.log(`  ${line}`);

const schema = JSON.parse(readFileSync(join(root, "../docs/metrics/schema.json"), "utf8"));
const rawCatalog = readFileSync(join(root, "../docs/metrics/catalog.json"), "utf8");
const catalog = JSON.parse(rawCatalog);
if (PROVOKE) {
  // Break every check at once: a malformed entry, a duplicated key, an unknown sql object and
  // setting, an orphan registry key, a stale document and an open gate
  const broken = { ...catalog.entries[0], key: catalog.entries[0].key, surface: "nowhere", computed_in: { sql: [{ object: "cma.no_such_function", migration: "0001" }], ts: [] }, settings: [{ key: "no.such_setting", default: "", pulse4all: "" }],
    verify_sql: "select count(*) from cma.app_user u where u.tenant_id = :tenant_id and cma.time_is_kept(u.id)" };
  catalog.entries = [...catalog.entries, broken];
}

// ---------------------------------------------------------------------------------------------
// 1. Schema (the subset docs/metrics/schema.json uses) and unique keys
// ---------------------------------------------------------------------------------------------
function validate(value, spec, path) {
  if (spec.$ref) {
    const name = spec.$ref.split("/").pop();
    return validate(value, schema.$defs[name], path);
  }
  if (spec.enum) {
    if (!spec.enum.includes(value)) problems.push(`${path}: ${JSON.stringify(value)} not in ${JSON.stringify(spec.enum.slice(0, 6))}…`);
    return;
  }
  const types = Array.isArray(spec.type) ? spec.type : spec.type ? [spec.type] : [];
  const kind = value === null ? "null" : Array.isArray(value) ? "array" : typeof value === "number" ? (Number.isInteger(value) ? "integer" : "number") : typeof value;
  if (types.length > 0 && !types.includes(kind) && !(kind === "integer" && types.includes("number"))) {
    problems.push(`${path}: is ${kind}, schema wants ${types.join(" or ")}`);
    return;
  }
  if (kind === "string") {
    if (spec.minLength !== undefined && value.length < spec.minLength) problems.push(`${path}: shorter than ${spec.minLength}`);
    if (spec.pattern && !new RegExp(spec.pattern).test(value)) problems.push(`${path}: does not match ${spec.pattern}`);
  }
  if (kind === "array") {
    if (spec.minItems !== undefined && value.length < spec.minItems) problems.push(`${path}: fewer than ${spec.minItems} items`);
    if (spec.items) value.forEach((v, i) => validate(v, spec.items, `${path}[${i}]`));
  }
  if (kind === "object" && (spec.properties || spec.required || spec.additionalProperties === false)) {
    for (const req of spec.required ?? []) if (!(req in value)) problems.push(`${path}: missing ${req}`);
    for (const [k, v] of Object.entries(value)) {
      const sub = spec.properties?.[k];
      if (!sub) {
        if (spec.additionalProperties === false) problems.push(`${path}: unknown field ${k}`);
        continue;
      }
      validate(v, sub, `${path}.${k}`);
    }
  }
}
validate(catalog, schema, "catalog");
const keys = catalog.entries.map((e) => e.key);
const dupes = keys.filter((k, i) => keys.indexOf(k) !== i);
for (const d of [...new Set(dupes)]) problems.push(`catalog: key ${d} appears twice`);
const schemaProblems = problems.length;
console.log("verify:metrics");
say(`schema ${schemaProblems === 0 ? "valid" : `INVALID (${schemaProblems} problems)`}, ${catalog.entries.length} entries, ${new Set(keys).size} unique keys`);

// ---------------------------------------------------------------------------------------------
// 2. The registry against the catalog, both ways
// ---------------------------------------------------------------------------------------------
const registered = PROVOKE ? [...registeredKeys(), "provoked.missing_key"] : registeredKeys();
const keySet = new Set(keys);
const missing = registered.filter((k) => !keySet.has(k));
const PAGE_SURFACES = new Set(["welcome", "live", "dashboard", "report", "configuration", "agent"]);
const orphans = catalog.entries.filter((e) => {
  if (!PAGE_SURFACES.has(e.surface)) return false;
  return !(PAGE_METRIC_KEYS[e.page] ?? []).includes(e.key);
});
for (const k of missing) problems.push(`registry: ${k} is registered on a page but has no catalog entry`);
for (const e of orphans) problems.push(`registry: ${e.key} (${e.page}) is in the catalog but not registered by its page`);
const regDupes = registered.filter((k, i) => registered.indexOf(k) !== i);
for (const d of [...new Set(regDupes)]) problems.push(`registry: ${d} is registered twice`);
say(`pages: ${registered.length} registered keys, ${missing.length} missing in catalog, ${orphans.length} orphan entries`);

// ---------------------------------------------------------------------------------------------
// 3. Every computed_in.sql object exists in the migrations
// ---------------------------------------------------------------------------------------------
const dbDir = join(root, "../db");
let dbSql = "";
for (const f of readdirSync(dbDir)) if (f.endsWith(".sql")) dbSql += readFileSync(join(dbDir, f), "utf8");
const defined = new Set();
for (const m of dbSql.matchAll(/create\s+(?:or\s+replace\s+)?(?:function|view|materialized\s+view|table)\s+(?:if\s+not\s+exists\s+)?((?:cma|cma_read)\.[a-z0-9_]+)/gi)) {
  defined.add(m[1].toLowerCase());
}
const sqlRefs = catalog.entries.flatMap((e) => e.computed_in.sql.map((s) => s.object));
const unknownSql = [...new Set(sqlRefs.filter((o) => !defined.has(o.toLowerCase())))];
for (const o of unknownSql) problems.push(`sql: ${o} is not created in any db/*.sql`);
say(`sql objects: ${new Set(sqlRefs).size} referenced, ${unknownSql.length} unknown`);

// ---------------------------------------------------------------------------------------------
// 3b. A verify_sql that reads the session sets it itself
// ---------------------------------------------------------------------------------------------
// The latest definition of each cma function and view in run order (db/*.sql, verify scripts left out: they define
// pg_temp objects), comments taken out; a function's body is its dollar-quoted text, a view's runs to its semicolon
const noComments = (sql) => sql.replace(/--[^\n]*/g, "");
const runOrder = (a, b) => a.localeCompare(b, "en", { numeric: true });
const latest = new Map();
for (const f of readdirSync(dbDir).filter((x) => x.endsWith(".sql") && !x.includes("verify")).sort(runOrder)) {
  const text = noComments(readFileSync(join(dbDir, f), "utf8"));
  for (const m of text.matchAll(/create\s+(?:or\s+replace\s+)?(function|view)\s+cma\.([a-z0-9_]+)\b/gi)) {
    const rest = text.slice(m.index + m[0].length);
    let body;
    if (m[1].toLowerCase() === "function") {
      const q = rest.match(/\bas\s+(\$[a-z_]*\$)([\s\S]*?)\1/i);
      body = q ? q[2] : "";
    } else {
      body = rest.slice(0, rest.indexOf(";") < 0 ? undefined : rest.indexOf(";"));
    }
    latest.set(`${m[1].toLowerCase() === "function" ? "f" : "v"}:${m[2].toLowerCase()}`, body);
  }
}
// Limits, none of which db/ or the catalog meets today: only cma objects are followed (not cma_read), an overloaded name is its
// last definition in run order, a body not dollar-quoted reads as empty, and a set_config anywhere in the query counts
const READS_TENANT = /current_setting\(\s*'app\.tenant_id'/i;
const READS_USER = /current_setting\(\s*'app\.user_id'/i;
/** The cma objects a text names: a call is a function (f:), a name without a call a view or table (v:; a table is never in latest) */
const named = (text) => [...new Set([...text.matchAll(/cma\.([a-z0-9_]+)(\s*\()?/gi)].map((r) => `${r[2] ? "f" : "v"}:${r[1].toLowerCase()}`))];
/** Whether an object reads the tenant (or the acting user) from the session, itself or through the cma objects it names */
function readsSession(name, which, seen = new Set()) {
  if (seen.has(name) || !latest.has(name)) return false;
  seen.add(name);
  const body = latest.get(name);
  if ((which === "tenant" ? READS_TENANT : READS_USER).test(body)) return true;
  for (const n of named(body)) if (readsSession(n, which, seen)) return true;
  return false;
}
let sessionChecked = 0;
for (const e of catalog.entries) {
  if (!e.verify_sql) continue;
  const sql = noComments(e.verify_sql);
  const used = named(sql);
  const tenantVia = used.filter((n) => readsSession(n, "tenant"));
  const userVia = used.filter((n) => readsSession(n, "user"));
  if (tenantVia.length === 0 && userVia.length === 0) continue;
  sessionChecked++;
  if (tenantVia.length > 0 && !/set_config\(\s*'app\.tenant_id'[^;]*?,\s*true\s*\)/i.test(sql)) {
    problems.push(`verify_sql: ${e.key} uses ${tenantVia.map((n) => "cma." + n.slice(2)).join(", ")}, which read app.tenant_id, without setting it for its own transaction (set_config('app.tenant_id', …, true)); it answers 0 or nothing without it`);
  }
  if (userVia.length > 0 && !/set_config\(\s*'app\.user_id'[^;]*?,\s*true\s*\)/i.test(sql)) {
    problems.push(`verify_sql: ${e.key} uses ${userVia.map((n) => "cma." + n.slice(2)).join(", ")}, which read the acting user (app.user_id), without setting it for its own transaction (set_config('app.user_id', …, true))`);
  }
}
say(`verify_sql and the session: ${latest.size} cma functions and views read, ${sessionChecked} queries use one that reads the session`);

// ---------------------------------------------------------------------------------------------
// 4. Every settings key exists in the settings catalog (the cma.setting inserts)
// ---------------------------------------------------------------------------------------------
// A settings catalog row is "( 'the.key', '<value type>', ..." wherever its insert statement sits
// (a description may hold a semicolon, so the rows are matched, not the statements)
const settingKeys = new Set();
for (const row of dbSql.matchAll(/\(\s*'([a-z0-9_.]+)'\s*,\s*'(?:text|integer|boolean|date|time|number)'/g)) {
  settingKeys.add(row[1]);
}
const settingRefs = catalog.entries.flatMap((e) => e.settings.map((s) => s.key));
const unknownSettings = [...new Set(settingRefs.filter((k) => !settingKeys.has(k)))];
for (const k of unknownSettings) problems.push(`settings: ${k} is not in the settings catalog`);
say(`settings: ${new Set(settingRefs).size} referenced, ${unknownSettings.length} unknown`);

// ---------------------------------------------------------------------------------------------
// 5. METRICS.md and the web copy equal the generator's output
// ---------------------------------------------------------------------------------------------
const doc = readFileSync(join(root, "../docs/metrics/METRICS.md"), "utf8");
const copyFile = readFileSync(join(root, "src/lib/metrics-catalog.json"), "utf8");
const wantDoc = PROVOKE ? `${generate(rawCatalog)}provoked\n` : generate(rawCatalog);
const docFresh = doc === wantDoc;
const copyFresh = copyFile === (PROVOKE ? `${webCopy(rawCatalog)}provoked\n` : webCopy(rawCatalog));
if (!docFresh) problems.push("METRICS.md: stale; run node scripts/metrics-doc.mjs");
if (!copyFresh) problems.push("src/lib/metrics-catalog.json: stale; run node scripts/metrics-doc.mjs");
say(`METRICS.md: ${docFresh && copyFresh ? "up to date" : "STALE"}`);

// ---------------------------------------------------------------------------------------------
// 6. The page's gate, with the default ladder's permission sets (as verify/preview.mjs models them)
// ---------------------------------------------------------------------------------------------
const LADDER = {
  admin: ["workday.own", "workday.team", "workday.export", "performance.team", "monitoring.live", "reports.view",
    "users.manage_agents", "users.manage_all", "tenant.configure", "skills.manage", "roster.manage", "roster.view", "messages.send"],
  manager: ["workday.own", "workday.team", "workday.export", "performance.team", "monitoring.live",
    "users.manage_agents", "skills.manage", "roster.manage", "roster.view", "messages.send"],
  analyst: ["reports.view", "performance.team", "monitoring.live"],
  agent: ["workday.own", "roster.view", "leads.accept", "performance.own"],
  reader: ["reports.view"],
};
const gate = Object.fromEntries(Object.entries(LADDER).map(([who, perms]) => [who, metricsPageStatus(PROVOKE ? [...perms, "tenant.configure"] : perms)]));
const gateWant = { admin: 200, manager: 403, analyst: 403, agent: 403, reader: 403 };
for (const [who, want] of Object.entries(gateWant)) {
  if (gate[who] !== want) problems.push(`gate: ${who} answers ${gate[who]}, expected ${want}`);
}
// 403 is the gate's decision (the no-permission card, nothing read, no rail item); the response's
// own status line is 200 on every configuration page, so the summary says "refused", not a status
say(`page /configuration/metrics: ${Object.entries(gate).map(([w, s]) => `${w} ${s === 403 ? "refused" : s}`).join(", ")}`);

// ---------------------------------------------------------------------------------------------
if (PROVOKE) {
  const broke = problems.length > 0;
  console.log(broke ? `PROVOKED: ${problems.length} problems found, as intended` : "PROVOKE FAILED: nothing failed");
  process.exit(broke ? 0 : 1);
}
if (problems.length > 0) {
  for (const p of problems) console.error(`FAIL  ${p}`);
  console.log(`${problems.length} FAILED`);
  process.exit(1);
}
console.log("ok");
