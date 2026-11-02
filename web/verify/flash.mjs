/**
 * Verifier (pure: no database, no network): Reports → Flash's own logic (src/lib/flash.ts, addition 0008zn, brief B21).
 *
 *   node --experimental-strip-types verify/flash.mjs             every check must PASS
 *   node --experimental-strip-types verify/flash.mjs --provoke   every check must FAIL
 *
 * Covers: the eleven overviews in their order with the keys 1 to 9, 0 and Q, each as cma.flash_overviews() holds it in
 * db/122_flash.sql (kind, source, dims, grouping sets, measures, count measures, headline, sort whitelist: read from the
 * script, so the page and the database cannot drift); the address keys (market among them); the sort whitelist and its
 * default direction; the list's filters (the overview's dims and a count measure only); As of (now, a past business date,
 * today and a future date refused); the file names (overview, market or all, the date or the instant in the tenant's
 * zone across the change of summer time); the change arrows; a definition's badge from the catalog's status and every
 * Flash figure in the metric catalog with a status; the sources' line and the states of a source not set up; amounts per
 * currency and sorting within currency; the grouping sets; the average rating. Invented values only.
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import {
  FLASH_OVERVIEWS, FLASH_ADDRESS, FLASH_PAGE_ROWS, FLASH_FILE_MAX_ROWS, overviewOf, overviewOfShortcut, parseAsOf, parseMarket, parseSort,
  parseFilters, asOfStamp, flashFileName, changeOf, changeArrow, definitionStatus, statusTone, metricKey, sourcesLine, showsFigures, amountsOf,
  sortWithinCurrency, rowsOfSet, breakdownSets, barShare, averageRating, isDate, FLASH_LIST_COLUMNS, FLASH_FROZEN_COLUMNS, breakdownColumns,
  breakdownRows, filtersText, FLASH_LINKS_LEFT_OUT, dataQualityRowShown, FLASH_DEFINITION_STATUS, FLASH_FIX_IN, fixInOf,
} from "../src/lib/flash.ts";

const PROVOKE = process.argv.includes("--provoke");
const here = path.dirname(new URL(import.meta.url).pathname);
const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(80)} got ${JSON.stringify(actual).slice(0, 90)}${pass ? "" : `, wanted ${JSON.stringify(want).slice(0, 90)}`}`);
}

// ---- The overviews, against db/122_flash.sql's cma.flash_overviews() --------------------------------------------------
const sql = readFileSync(path.join(here, "..", "..", "db", "122_flash.sql"), "utf8");
const body = sql.slice(sql.indexOf("create or replace function cma.flash_overviews()"));
const values = body.slice(body.indexOf("values") + 6, body.indexOf("$$;"));
const arr = (s) => (s.trim() === "array[]::text[]" ? [] : [...s.matchAll(/'([a-z0-9_]+)'/g)].map((m) => m[1]));
// one tuple per overview: ('key', order, 'kind', 'source'|null, array[...], '<sets json>'::jsonb, array[...], array[...], 'headline', array[...])
const tuples = [...values.matchAll(/\(\s*'([a-z_]+)',\s*(\d+),\s*'(stock|flow)',\s*('([a-z]+)'|null),\s*(array\[[^\]]*\]),\s*'([^']*)'::jsonb,\s*(array\[[^\]]*\]),\s*(array\[[^\]]*\]),\s*'([a-z_]+)',\s*(array\[[^\]]*\])\s*\)/g)];
const fromSql = tuples.map((t) => ({ key: t[1], kind: t[3], source: t[5] ?? null, dims: arr(t[6]), sets: JSON.parse(t[7]), measures: arr(t[8]),
  countMeasures: arr(t[9]), headline: t[10], sorts: arr(t[11]) }));
const fromTs = FLASH_OVERVIEWS.map((o) => ({ key: o.key, kind: o.kind, source: o.source, dims: [...o.dims], sets: o.sets.map((s) => [...s]),
  measures: [...o.measures], countMeasures: [...o.countMeasures], headline: o.headline, sorts: [...o.sorts] }));
expect("eleven overviews in db/122_flash.sql, read from cma.flash_overviews()", fromSql.length, 11, 0);
expect("the page's overviews equal the database's: order, kind, source, dims, sets, measures, headline, sorts",
  JSON.stringify(fromTs) === JSON.stringify(fromSql), true, false);
expect("the keys 1 to 9, 0 and Q in the page's order, each once",
  FLASH_OVERVIEWS.map((o) => o.shortcut).join(""), "1234567890Q", "");
expect("a key opens its overview (case-insensitive), another key none",
  [overviewOfShortcut("1")?.key, overviewOfShortcut("0")?.key, overviewOfShortcut("q")?.key, overviewOfShortcut("Z"), overviewOfShortcut("11")],
  ["customers", "reviews", "data_quality", null, null], ["x", "x", "x", "x", "x"]);
expect("every amount measure is a measure; a headline is a measure; Data quality alone without a source",
  [FLASH_OVERVIEWS.every((o) => o.amountMeasures.every((m) => o.measures.includes(m)) && o.measures.includes(o.headline)),
    FLASH_OVERVIEWS.filter((o) => o.source === null).map((o) => o.key)], [true, ["data_quality"]], [false, []]);
expect("the address keys: the overview, market (K), As of, the period, sort, page, measure, check, the filters' prefix",
  [FLASH_ADDRESS.market, FLASH_ADDRESS.asOf, FLASH_ADDRESS.overview, FLASH_ADDRESS.filterPrefix, FLASH_PAGE_ROWS, FLASH_FILE_MAX_ROWS],
  ["market", "asOf", "o", "f_", 500, 50000], ["", "", "", "", 0, 0]);
expect("overviewOf: a key, else null", [overviewOf("orders")?.kind, overviewOf("nope"), overviewOf(3)], ["flow", null, null], [null, "x", "x"]);

// ---- Sorting, filters ----------------------------------------------------------------------------------------------------
const cust = overviewOf("customers");
expect("sort: the whitelist only, the default first with its own direction; asc or desc otherwise",
  [parseSort(cust, undefined, undefined), parseSort(cust, "email", "asc"), parseSort(cust, "total_spent", "desc"), parseSort(cust, "market", undefined)],
  [{ sort: "lifetime_orders", descending: true }, { sort: "lifetime_orders", descending: false }, { sort: "total_spent", descending: true },
    { sort: "market", descending: false }],
  [{ sort: "email", descending: false }, null, null, null]);
const q = { f_market: "GB", f_store: "shop-gb", f_email: "x", measure: "active_customers", f_status: "active" };
const tasksQ = { f_market: "GB", measure: "devices" };
expect("filters: the overview's dims (f_<dim>) and a count measure only; anything else dropped",
  [parseFilters(cust, (k) => q[k]), parseFilters(overviewOf("open_tasks"), (k) => tasksQ[k])],
  [{ market: "GB", store: "shop-gb", measure: "active_customers" }, { market: "GB" }], [{}, { measure: "devices" }]);
expect("market: a two-letter code or unknown", [parseMarket("GB"), parseMarket("unknown"), parseMarket("gb"), parseMarket("GBR"), parseMarket(null)],
  ["GB", "unknown", null, null, null], [null, null, "gb", "GBR", "x"]);

// ---- As of ---------------------------------------------------------------------------------------------------------------
const today = "2026-11-01";
expect("As of: now, a past business date; today, the future and no date read as now with a problem",
  [parseAsOf(undefined, today), parseAsOf("now", today), parseAsOf("2026-10-31", today), parseAsOf(today, today), parseAsOf("2026-11-02", today),
    parseAsOf("2026-02-30", today), parseAsOf("31-10-2026", today)],
  [{ asOf: null, problem: false }, { asOf: null, problem: false }, { asOf: "2026-10-31", problem: false }, { asOf: null, problem: true },
    { asOf: null, problem: true }, { asOf: null, problem: true }, { asOf: null, problem: true }],
  [null, null, null, null, null, null, null]);
expect("isDate: a real calendar date only", [isDate("2026-10-31"), isDate("2026-02-29"), isDate("2028-02-29"), isDate("2026-13-01")],
  [true, false, true, false], [false, true, false, true]);

// ---- File names ----------------------------------------------------------------------------------------------------------
const before = new Date("2026-10-25T00:30:00Z");   // 02:30 summer time in Amsterdam, before the change at 03:00
const after = new Date("2026-10-25T01:30:00Z");    // 02:30 winter time, after it
expect("the stamp: a snapshot's date, or now as YYYY-MM-DDTHHmm in the tenant's zone across the change of summer time",
  [asOfStamp("2026-10-31", after, "Europe/Amsterdam"), asOfStamp(null, before, "Europe/Amsterdam"), asOfStamp(null, after, "Europe/Amsterdam"),
    asOfStamp(null, after, "Europe/London")],
  ["2026-10-31", "2026-10-25T0230", "2026-10-25T0230", "2026-10-25T0130"], ["", "", "", ""]);
expect("file names: overview, market or all, the stamp; the breakdown's ends -breakdown; nothing else enters",
  [flashFileName("customers", "GB", "2026-10-31"), flashFileName("orders", null, "2026-11-01T0930"), flashFileName("orders", "GB", "2026-10-31", "breakdown"),
    flashFileName("customers", "a@b", "2026-10-31"), flashFileName("customers", "GB", "../x")],
  ["flash-customers-GB-2026-10-31.csv", "flash-orders-all-2026-11-01T0930.csv", "flash-orders-GB-2026-10-31-breakdown.csv",
    "flash-customers-all-2026-10-31.csv", "flash-customers-GB-unknown.csv"], ["", "", "", "", ""]);

// ---- Change arrows, badges, catalog --------------------------------------------------------------------------------------
expect("change: up, down, flat, none without a figure to compare",
  [changeOf(12, 10), changeOf(8, 10), changeOf(10, 10), changeOf(10, null), changeOf(null, 3)].map((c) => `${c.direction}:${c.delta}`),
  ["up:2", "down:-2", "flat:0", "none:null", "none:null"], ["", "", "", "", ""]);
expect("arrows: ↑ ↓ →, nothing without a change", ["up", "down", "flat", "none"].map(changeArrow), ["↑", "↓", "→", ""], ["", "", "", "x"]);
expect("a definition's status and tone: Decided success, Proposed info (also when the catalog says nothing), Pending warning",
  [definitionStatus("Decided"), definitionStatus("Proposed (for Kira to confirm)"), definitionStatus(undefined), definitionStatus("Pending: x")]
    .map((s) => `${s}:${statusTone(s)}`),
  ["Decided:success", "Proposed:info", "Proposed:info", "Pending:warning"], ["", "", "", ""]);
const catalog = JSON.parse(readFileSync(path.join(here, "..", "..", "docs", "metrics", "catalog.json"), "utf8"));
const entries = Array.isArray(catalog) ? catalog : catalog.entries ?? catalog.metrics ?? [];
const byKey = new Map(entries.map((e) => [e.key, e]));
const wanted = FLASH_OVERVIEWS.flatMap((o) => o.measures.map((m) => metricKey(o.key, m)));
const missing = wanted.filter((k) => !byKey.has(k));
// the catalog's notes open with the definition status, and it is the one lib/flash.ts shows for the overview
const noStatus = wanted.filter((k) => {
  const m = /^Definition status: (Decided|Proposed|Pending|Retired)/.exec(String(byKey.get(k)?.notes ?? ""));
  return byKey.has(k) && (!m || m[1] !== FLASH_DEFINITION_STATUS[k.split(".")[1]]);
});
expect("every Flash measure has a metric catalog entry whose definition status is the one the page shows",
  [wanted.length, missing, noStatus, wanted.every((k) => byKey.get(k)?.page === "/reports/flash")], [34, [], [], true], [0, ["x"], ["x"], false]);

// ---- Sources, not set up -------------------------------------------------------------------------------------------------
const sources = { commerce: { set_up: true, adapters: ["shopx"], last_read_at: "2026-11-01T13:02:00Z" },
  subscriptions: { set_up: false, adapters: [], last_read_at: null }, assets: { set_up: true, adapters: ["regx"], last_read_at: null },
  crm: { set_up: true, adapters: ["crmx"], last_read_at: "2026-11-01T13:00:00Z" }, reviews: { set_up: false, adapters: [], last_read_at: null } };
expect("the sources' line: the overview's own first (also when not set up), then the set-up others",
  [sourcesLine(sources, "subscriptions").map((s) => `${s.source}:${s.setUp}`), sourcesLine(sources, null).map((s) => s.source)],
  [["subscriptions:false", "commerce:true", "assets:true", "crm:true"], ["commerce", "assets", "crm"]], [[], []]);
expect("not set up: no figures, never zeros; data quality always shows",
  [showsFigures(overviewOf("subscriptions"), false), showsFigures(overviewOf("subscriptions"), true), showsFigures(overviewOf("data_quality"), false)],
  [false, true, true], [true, false, false]);

// ---- Amounts, sorting within currency, sets ------------------------------------------------------------------------------
expect("amounts per currency, sorted by currency; never one sum; nothing but codes and numbers",
  amountsOf({ GBP: 80, EUR: 30, xx: 1, USD: "3" }), [{ currency: "EUR", amount: 30 }, { currency: "GBP", amount: 80 }], []);
const rows = [{ id: "cu-1", c: "GBP", a: 300 }, { id: "cu-2", c: "GBP", a: 20 }, { id: "cu-3", c: null, a: null }, { id: "cu-4", c: "GBP", a: 50 },
  { id: "cu-5", c: "EUR", a: 40 }];
expect("sorting within currency: currency first, then the amount in the direction asked, none last (as the database sorts)",
  [sortWithinCurrency(rows, (r) => r.a, (r) => r.c, (r) => r.id, true).map((r) => r.id).join(","),
    sortWithinCurrency(rows, (r) => r.a, (r) => r.c, (r) => r.id, false).map((r) => r.id).join(",")],
  ["cu-5,cu-1,cu-4,cu-2,cu-3", "cu-5,cu-2,cu-4,cu-1,cu-3"], ["", ""]);
const doc = [{ dims: {} }, { dims: { market: "GB" } }, { dims: { market: "GB", sku: "A" } }, { dims: { kind: "first", market: "GB", store: "s" } }];
expect("grouping sets: the rows of a set by exactly its keys; the breakdowns are the sets beyond the market",
  [rowsOfSet(doc, []).length, rowsOfSet(doc, ["market"]).length, rowsOfSet(doc, ["sku", "market"]).length,
    breakdownSets(overviewOf("orders")).map((s) => s.join("+")), breakdownSets(overviewOf("data_quality")).map((s) => s.join("+"))],
  [1, 1, 1, ["market+store+kind", "market+sku"], ["check", "check+market"]], [0, 0, 0, [], []]);
expect("bars and the average rating (sum over count, two decimals; none without reviews)",
  [barShare(5, 10), barShare(0, 10), barShare(3, 0), averageRating(6, 2), averageRating(10.5, 3), averageRating(0, 0)],
  [0.5, 0, 0, 3, 3.5, null], [1, 1, 1, 0, 0, 0]);

// ---- The lists' columns, against db/122_flash.sql's cma.flash_rows_of (and data quality's links) ------------------------
const rowsBody = sql.slice(sql.indexOf("create or replace function cma.flash_rows_of"), sql.indexOf("end case;", sql.indexOf("create or replace function cma.flash_rows_of")));
const listKeys = {};
for (const part of rowsBody.split(/\n    when '/).slice(1)) {
  const key = part.slice(0, part.indexOf("'"));
  const obj = part.slice(part.indexOf("v_obj := '"));
  // the keys of jsonb_build_object('key', value, …): a quoted key followed by a comma; record_url's own arguments are no keys
  listKeys[key] = [...obj.matchAll(/''([a-z_0-9]+)'', (?!x\.source_id\)|x\.record_source_id\))/g)].map((m) => m[1])
    .filter((k) => !["contact", "deal", "ticket", "task", "review", "device"].includes(k) || k === "check");
}
const linkKeys = ["record_url", "related_type", "related_id", "related_url"];
const listMismatch = FLASH_OVERVIEWS.filter((o) => {
  const want = (listKeys[o.key] ?? []).filter((k) => k !== "connection_id" && !(FLASH_LINKS_LEFT_OUT[o.key] ?? []).includes(k))
    .concat(o.key === "data_quality" ? linkKeys : []);
  const have = FLASH_LIST_COLUMNS[o.key].map((c) => c.key);
  return [...want].sort().join(",") !== [...have].sort().join(",");
}).map((o) => o.key);
expect("every list's columns are the keys cma.flash_rows answers (the connection's id and the links outside the CRM left out; data quality's links added)",
  [Object.keys(listKeys).length, PROVOKE ? ["provoked"] : listMismatch, FLASH_FROZEN_COLUMNS.map((c) => c.key)],
  [11, [], ["source_id", "market", "state"]], [0, [], []]);

expect("links outside the CRM never shown: the register's and the review platform's left out; a finding's link for a CRM record only",
  [FLASH_LIST_COLUMNS.installed_base.some((c) => c.key === "record_url"), FLASH_LIST_COLUMNS.reviews.some((c) => c.key === "review_url"),
    dataQualityRowShown({ object_type: "device", record_url: "https://register.example/r/1", related_type: "subscription", related_url: "https://x.example" }).record_url,
    dataQualityRowShown({ object_type: "contact", record_url: "https://crm.example/c/1", related_type: null }).record_url,
    dataQualityRowShown({ object_type: "commerce_customer", record_url: null, related_type: "contact", related_url: "https://crm.example/c/2" }).related_url],
  [false, false, null, "https://crm.example/c/1", "https://crm.example/c/2"], [true, true, "https://register.example/r/1", null, null]);

// ---- Where a check is fixed, against db/122_flash.sql's cma.data_quality_fix_in ------------------------------------------
const fixBody = sql.slice(sql.indexOf("create or replace function cma.data_quality_fix_in"), sql.indexOf("$$;", sql.indexOf("create or replace function cma.data_quality_fix_in") + 80));
const fixSql = {};
for (const m of fixBody.matchAll(/when p_check_key (?:= '([a-z_]+)'|in \(([^)]*)\)) then (?:case when [^']*'[^']*' then '([a-z]+)' else '([a-z]+)' end|'([a-z]+)')/g)) {
  const keys = m[1] ? [m[1]] : [...m[2].matchAll(/'([a-z_]+)'/g)].map((x) => x[1]);
  const where = m[5] ?? m[4];
  for (const k of keys) (fixSql[where] ??= []).push(k);
}
const fixMismatch = Object.keys(FLASH_FIX_IN).filter((k) => [...FLASH_FIX_IN[k]].sort().join() !== [...(fixSql[k] ?? [])].sort().join());
expect("where a check is fixed: the lists are cma.data_quality_fix_in's (crm, commerce, assets; the Workspace otherwise)",
  [PROVOKE ? ["provoked"] : fixMismatch, Object.keys(fixSql).sort(), fixInOf("device_required_ref_missing"), fixInOf("pipeline_unreviewed")],
  [[], ["assets", "commerce", "crm"], "assets", "cma"], [[], [], "", ""]);

// ---- The breakdown file and the filters column ----------------------------------------------------------------------
const subs = overviewOf("subscriptions");
const docRows = [{ dims: {}, measures: { subscriptions: 7, active_subscriptions: 3, paused_subscriptions: 2, amount_per_cycle: { GBP: 80, EUR: 30 } } },
  { dims: { market: "GB" }, measures: { subscriptions: 7, active_subscriptions: 3, paused_subscriptions: 2, amount_per_cycle: { GBP: 80 } } }];
expect("the breakdown file: the set, every dim, each measure, an amount one column per currency (never summed)",
  [breakdownColumns(subs, docRows).map((c) => c.key), breakdownRows(subs, docRows).map((r) => [r.set, r.market, r.amount_per_cycle_EUR ?? null, r.amount_per_cycle_GBP])],
  [["set", "market", "store", "status", "payment_state", "subscriptions", "active_subscriptions", "paused_subscriptions", "amount_per_cycle_EUR", "amount_per_cycle_GBP"],
    [["totals", null, 30, 80], ["market", "GB", null, 80]]], [[], []]);
expect("a file's filters column: market, period and the list's filters as key=value, sorted; all without any",
  [filtersText("GB", null, null, { market: "GB", measure: "active_customers" }), filtersText(null, "2026-10-01", "2026-10-31", { sku: "AED-1" }), filtersText(null, null, null, {})],
  ["market=GB; measure=active_customers", "from=2026-10-01; to=2026-10-31; sku=AED-1", "all"], ["", "", ""]);

const passed = results.filter(Boolean).length;
const n = results.length;
if (PROVOKE) {
  const ok = passed === 0;
  console.log(`\n${ok ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
  process.exit(ok ? 0 : 1);
}
console.log(`\n${passed === n ? `ALL ${n} PASS` : `${n - passed} of ${n} FAILED`}`);
process.exit(passed === n ? 0 : 1);
