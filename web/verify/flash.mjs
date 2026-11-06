/**
 * Verifier (pure: no database, no network): Reports → Flash's own logic (src/lib/flash.ts, addition 0008zn, brief B21).
 *
 *   node --experimental-strip-types verify/flash.mjs             every check must PASS
 *   node --experimental-strip-types verify/flash.mjs --provoke   every check must FAIL
 *
 * Covers: the eleven overviews in their order with the keys 1 to 9, 0 and Q, each as cma.flash_overviews() holds it in
 * its latest definition in db/ (138_flash_totals.sql since addition 0008zu: kind, source, dims, grouping sets, measures,
 * count measures, headline, sort whitelist: read from the script, so the page and the database cannot drift); the address keys (market among them); the sort whitelist and its
 * default direction; the list's filters (the overview's dims and a count measure only); As of (now, a past business date,
 * today and a future date refused); the file names (overview, market or all, the date or the instant in the tenant's
 * zone across the change of summer time); the change arrows; a definition's badge from the catalog's status and every
 * Flash figure in the metric catalog with a status; the sources' line and the states of a source not set up; amounts per
 * currency and sorting within currency; the grouping sets; the average rating; a measure that does not apply (left out
 * by db/122 while its setting is empty: not applicable on screen without a link, an empty cell in a file, its records
 * refused); a flow card's change line, which compares a complete period only (its end passed in the tenant's zone and
 * every set-up source feeding it read after that end; else "so far", en and nl). Invented values only.
 */
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import {
  FLASH_OVERVIEWS, FLASH_ADDRESS, FLASH_PAGE_ROWS, FLASH_FILE_MAX_ROWS, overviewOf, overviewOfShortcut, parseAsOf, parseMarket, parseSort,
  parseFilters, asOfStamp, flashFileName, changeOf, changeArrow, definitionStatus, statusTone, metricKey, sourcesLine, showsFigures, amountsOf,
  sortWithinCurrency, rowsOfSet, breakdownSets, barShare, averageRating, isDate, FLASH_LIST_COLUMNS, FLASH_FROZEN_COLUMNS, breakdownColumns,
  breakdownRows, filtersText, FLASH_LINKS_LEFT_OUT, dataQualityRowShown, FLASH_DEFINITION_STATUS, FLASH_FIX_IN, fixInOf, cellFilters, frozenFilters,
  FLASH_FROZEN_LIST, listUnavailable, FLASH_CONDITIONAL_MEASURES, measureNotApplicable, measureKind, watchedMeasures, FLASH_RATIOS, ratioOf, setMeasures,
  FLASH_SET_MEASURES, FLASH_BAND_DIMS, bandDimOf, bandOrder, bandLowerBound, bandRows, moreThanRows, FLASH_STATUS_HINTS, FLASH_CARD_STATUS_HINTS,
  statusHintPart, measureHint, cardStatusHint, statusSettingsOf, FLASH_SPLITS, splitOf, splitItemsOf, splitLine, definitionChanged,
  FLASH_ORDER_KINDS, splitOrderOf, splitKeyLabel, splitLabelsOf, flashHref,
} from "../src/lib/flash.ts";
import { fmtLastRead } from "../src/lib/time.ts";

const PROVOKE = process.argv.includes("--provoke");
const here = path.dirname(new URL(import.meta.url).pathname);
const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(80)} got ${JSON.stringify(actual).slice(0, 90)}${pass ? "" : `, wanted ${JSON.stringify(want).slice(0, 90)}`}`);
}

// ---- The overviews, against their latest definition in db/ (122's, 136's since 0008zt, 138_flash_totals.sql's since 0008zu)
// A function's latest definition: the db/ script with the highest number that creates it (a later addition makes a
// function again; the page follows the one the database runs)
const dbDir = path.join(here, "..", "..", "db");
const dbFiles = readdirSync(dbDir).filter((f) => /^\d+_.*\.sql$/.test(f) && !f.includes("verify")).sort((a, b) => parseInt(b, 10) - parseInt(a, 10));
function defOf(fn) {
  for (const f of dbFiles) {
    const text = readFileSync(path.join(dbDir, f), "utf8");
    const at = text.indexOf(`create or replace function cma.${fn}(`);
    if (at >= 0) return { file: f, text: text.slice(at) };
  }
  throw new Error(`no definition of cma.${fn} in db/`);
}
const overviewsDef = defOf("flash_overviews");
const body = overviewsDef.text;
const values = body.slice(body.indexOf("values") + 6, body.indexOf("$$;"));
const arr = (s) => (s.trim() === "array[]::text[]" ? [] : [...s.matchAll(/'([a-z0-9_]+)'/g)].map((m) => m[1]));
// one tuple per overview: ('key', order, 'kind', 'source'|null, array[...], '<sets json>'::jsonb, array[...], array[...], 'headline', array[...])
const tuples = [...values.matchAll(/\(\s*'([a-z_]+)',\s*(\d+),\s*'(stock|flow)',\s*('([a-z]+)'|null),\s*(array\[[^\]]*\]),\s*'([^']*)'::jsonb,\s*(array\[[^\]]*\]),\s*(array\[[^\]]*\]),\s*'([a-z_]+)',\s*(array\[[^\]]*\])\s*\)/g)];
const fromSql = tuples.map((t) => ({ key: t[1], kind: t[3], source: t[5] ?? null, dims: arr(t[6]), sets: JSON.parse(t[7]), measures: arr(t[8]),
  countMeasures: arr(t[9]), headline: t[10], sorts: arr(t[11]) }));
const fromTs = FLASH_OVERVIEWS.map((o) => ({ key: o.key, kind: o.kind, source: o.source, dims: [...o.dims], sets: o.sets.map((s) => [...s]),
  measures: [...o.measures], countMeasures: [...o.countMeasures], headline: o.headline, sorts: [...o.sorts] }));
expect(`eleven overviews in db/${overviewsDef.file}, read from cma.flash_overviews()`, [fromSql.length, overviewsDef.file], [11, "138_flash_totals.sql"], [0, ""]);
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

// ---- A flow's change line compares completed periods only (Decision log, 4 Nov 2026) ------------------------------------
// Complete: (a) the period's end has passed in the tenant's zone and (b) every set-up source feeding the overview was last
// read after that end. Prod, 4 November 2026: Orders 40 "↓ 221 since Tue 3 November", six hours against a whole day
const { periodComplete, changeLineOf, FLASH_FLOW_SOURCES } = await import("../src/lib/flash.ts");
const { copy: periodCopy } = await import("../src/lib/copy.ts");
const zone = "Europe/Amsterdam";
const tenantToday = "2026-11-04";
const readAllAt = (at) => ({ commerce: { setUp: true, lastReadAt: at }, subscriptions: { setUp: true, lastReadAt: at }, reviews: { setUp: true, lastReadAt: at },
  assets: { setUp: true, lastReadAt: at }, crm: { setUp: true, lastReadAt: at } });
const readAfterMidnight = readAllAt("2026-11-04T05:10:00Z");
expect("the sources feeding each flow: churn the subscription app, orders the stores, payments both, reviews the platforms; stocks none",
  [FLASH_FLOW_SOURCES, FLASH_OVERVIEWS.filter((o) => o.kind === "flow").map((o) => o.key).sort()],
  [{ churn: ["subscriptions"], orders: ["commerce"], payments: ["commerce", "subscriptions"], reviews: ["reviews"] }, ["churn", "orders", "payments", "reviews"]],
  [{}, []]);
expect("(a) open: Today, and This week or This month while running (they end today); complete: Yesterday and a custom range that has ended",
  [periodComplete("orders", tenantToday, tenantToday, zone, readAfterMidnight), periodComplete("payments", tenantToday, tenantToday, zone, readAfterMidnight),
    periodComplete("orders", "2026-11-03", tenantToday, zone, readAfterMidnight), periodComplete("churn", "2026-10-31", tenantToday, zone, readAfterMidnight),
    periodComplete("reviews", "2026-11-05", tenantToday, zone, readAfterMidnight)],
  [false, false, true, true, false], [true, true, false, false, true]);
expect("(b) Yesterday with a source last read before midnight (the tenant's zone) is open; read after it, complete",
  [periodComplete("orders", "2026-11-03", tenantToday, zone, { ...readAfterMidnight, commerce: { setUp: true, lastReadAt: "2026-11-03T02:30:00Z" } }),
    periodComplete("orders", "2026-11-03", tenantToday, zone, { ...readAfterMidnight, commerce: { setUp: true, lastReadAt: "2026-11-03T22:59:00Z" } }),
    periodComplete("orders", "2026-11-03", tenantToday, zone, { ...readAfterMidnight, commerce: { setUp: true, lastReadAt: "2026-11-03T23:00:00Z" } }),
    periodComplete("orders", "2026-11-03", tenantToday, "Europe/London", { ...readAfterMidnight, commerce: { setUp: true, lastReadAt: "2026-11-03T23:30:00Z" } }),
    periodComplete("orders", "2026-11-03", tenantToday, zone, { ...readAfterMidnight, commerce: { setUp: true, lastReadAt: null } })],
  [false, false, true, false, false], [true, true, false, true, true]);
expect("(b) every source feeding it: payments waits for the subscription app too; a source not set up feeds nothing; a stock is always compared",
  [periodComplete("payments", "2026-11-03", tenantToday, zone, { ...readAfterMidnight, subscriptions: { setUp: true, lastReadAt: "2026-11-03T20:00:00Z" } }),
    periodComplete("payments", "2026-11-03", tenantToday, zone, { ...readAfterMidnight, subscriptions: { setUp: false, lastReadAt: null } }),
    periodComplete("orders", "2026-11-03", tenantToday, zone, { ...readAfterMidnight, subscriptions: { setUp: true, lastReadAt: "2026-11-03T20:00:00Z" } }),
    periodComplete("installed_base", null, tenantToday, zone, readAllAt(null)), periodComplete("open_deals", tenantToday, tenantToday, zone, readAllAt(null))],
  [false, true, true, true, true], [true, false, false, false, false]);
const lineEn = periodCopy.en.flash;
const lineNl = periodCopy.nl.flash;
const fmtEn = (x) => new Intl.NumberFormat("en-GB", { maximumFractionDigits: 1 }).format(x);
const fmtNl = (x) => new Intl.NumberFormat("nl-NL", { maximumFractionDigits: 1 }).format(x);
expect("an open period (Today, prod's Orders 40 against 261) says so far, en and nl, never a change",
  [changeLineOf(40, 261, "Tue 3 November", !periodComplete("orders", tenantToday, tenantToday, zone, readAfterMidnight), lineEn, fmtEn),
    changeLineOf(40, 261, "di 3 november", !periodComplete("orders", tenantToday, tenantToday, zone, readAfterMidnight), lineNl, fmtNl)],
  ["So far; compared once the period is complete", "Tot nu toe; vergeleken zodra de periode compleet is"],
  ["↓ 221 since Tue 3 November", "↓ 221 sinds di 3 november"]);
expect("a completed period (Yesterday, every source read after midnight) shows its change, en and nl",
  [changeLineOf(261, 250, "Mon 2 November", !periodComplete("orders", "2026-11-03", tenantToday, zone, readAfterMidnight), lineEn, fmtEn),
    changeLineOf(261, 250, "ma 2 november", !periodComplete("orders", "2026-11-03", tenantToday, zone, readAfterMidnight), lineNl, fmtNl),
    changeLineOf(5, 5, "Mon 2 November", false, lineEn, fmtEn), changeLineOf(5, null, null, false, lineEn, fmtEn)],
  ["↑ 11 since Mon 2 November", "↑ 11 sinds ma 2 november", "→ unchanged since Mon 2 November", "Nothing to compare with yet"],
  ["So far; compared once the period is complete", "Tot nu toe; vergeleken zodra de periode compleet is", "", ""]);
expect("Yesterday with a source last read before midnight shows the open-period line (case b), en and nl",
  [changeLineOf(261, 250, "Mon 2 November",
    !periodComplete("orders", "2026-11-03", tenantToday, zone, { ...readAfterMidnight, commerce: { setUp: true, lastReadAt: "2026-11-03T22:45:00Z" } }), lineEn, fmtEn),
  changeLineOf(261, 250, "ma 2 november",
    !periodComplete("orders", "2026-11-03", tenantToday, zone, { ...readAfterMidnight, commerce: { setUp: true, lastReadAt: "2026-11-03T22:45:00Z" } }), lineNl, fmtNl)],
  ["So far; compared once the period is complete", "Tot nu toe; vergeleken zodra de periode compleet is"],
  ["↑ 11 since Mon 2 November", "↑ 11 sinds ma 2 november"]);
const periodPageSrc = readFileSync(path.join(here, "..", "src", "app", "reports", "flash", "page.tsx"), "utf8");
const periodControlsSrc = readFileSync(path.join(here, "..", "src", "components", "FlashControls.tsx"), "utf8");
const periodPartsSrc = readFileSync(path.join(here, "..", "src", "components", "FlashParts.tsx"), "utf8");
expect("the landing reads it: a live card's open flag from the tenant's today, zone and sources; the live and the stored line through changeLineOf",
  [/const open = asOf === null && !periodComplete\(o\.key, o\.kind === "flow" \? to : null, page\.today \|\| today, page\.timeZone \|\| me\.timeZone, page\.sources\);/.test(periodPageSrc),
    /open=\{open\}/.test(periodPageSrc) && /openPeriod: t\.openPeriod/.test(periodPageSrc),
    /changeLineOf\(shown, previous, labels\.previousOnText, open, labels, n\)/.test(periodControlsSrc), /return changeLineOf\(/.test(periodPartsSrc)],
  [true, true, true, true], [false, false, false, false]);
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
  [wanted.length, missing, noStatus, wanted.every((k) => byKey.get(k)?.page === "/reports/flash")], [38, [], [], true], [0, ["x"], ["x"], false]);

// ---- Sources, not set up -------------------------------------------------------------------------------------------------
const sources = { commerce: { set_up: true, adapters: ["shopx"], last_read_at: "2026-11-01T13:02:00Z" },
  subscriptions: { set_up: false, adapters: [], last_read_at: null }, assets: { set_up: true, adapters: ["regx"], last_read_at: null },
  crm: { set_up: true, adapters: ["crmx"], last_read_at: "2026-11-01T13:00:00Z" }, reviews: { set_up: false, adapters: [], last_read_at: null } };
expect("the sources' line: the overview's own first (also when not set up), then the set-up others",
  [sourcesLine(sources, "subscriptions").map((s) => `${s.source}:${s.setUp}`), sourcesLine(sources, null).map((s) => s.source)],
  [["subscriptions:false", "commerce:true", "assets:true", "crm:true"], ["commerce", "assets", "crm"]], [[], []]);
// The "Last read" stamp: time alone on the tenant's today, else weekday, date and time (4 November 2026, 14:00 UTC = 15:00 Amsterdam)
const readNow = "2026-11-04T14:00:00Z";
expect("last read: today in the tenant's zone shows the time alone",
  [fmtLastRead("2026-11-04T10:59:00Z", readNow, "Europe/Amsterdam", "en"), fmtLastRead("2026-11-03T23:30:00Z", readNow, "Europe/Amsterdam", "en")],
  ["11:59", "00:30"], ["Wed 4 Nov 11:59", "Tue 3 Nov 00:30"]);
expect("last read: an earlier day shows the short weekday and date with the time (en)",
  [fmtLastRead("2026-11-02T10:59:00Z", readNow, "Europe/Amsterdam", "en"), fmtLastRead("2026-11-03T22:30:00Z", readNow, "Europe/London", "en")],
  ["Mon 2 Nov 11:59", "Tue 3 Nov 22:30"], ["11:59", "22:30"]);
expect("last read: the user's locale (nl)",
  fmtLastRead("2026-11-02T10:59:00Z", readNow, "Europe/Amsterdam", "nl"), "ma 2 nov 11:59", "11:59");
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

// ---- The lists' columns, against cma.flash_rows_of's latest definition (and data quality's links) ----------------------
const rowsDef = defOf("flash_rows_of").text;
const rowsBody = rowsDef.slice(0, rowsDef.indexOf("end case;"));
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

// ---- Where a check is fixed, against cma.data_quality_fix_in's latest definition -----------------------------------------
const fixDef = defOf("data_quality_fix_in").text;
const fixBody = fixDef.slice(0, fixDef.indexOf("$$;", 80));
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
  [["set", "market", "store", "status", "payment_state", "device_band", "age_band", "subscriptions", "active_subscriptions", "paused_subscriptions",
    "amount_per_cycle_EUR", "amount_per_cycle_GBP", "holding_subscriptions", "devices_on_holding", "devices_per_holding_subscription"],
    [["totals", null, 30, 80], ["market", "GB", null, 80]]], [[], []]);
expect("a file's filters column: market, period and the list's filters as key=value, sorted; all without any",
  [filtersText("GB", null, null, { market: "GB", measure: "active_customers" }), filtersText(null, "2026-10-01", "2026-10-31", { sku: "AED-1" }), filtersText(null, null, null, {})],
  ["market=GB; measure=active_customers", "from=2026-10-01; to=2026-10-31; sku=AED-1", "all"], ["", "", ""]);

// ---- A month end's breakdown cells, every one clicked (review of #214, Major 1) ---------------------------------------
// The frozen list's own rule, read from cma.flash_id_rows_of's latest definition: the keys it takes, the kind without a
// status, the one measure per kind. Every cell of every breakdown set of the three overviews that keep a list is opened
// as the page opens it (its link's address, parsed as the page parses it, the page's market, frozenFilters): what the
// page sends must be what the database takes, and the mock (which refuses as the database does) must answer it
const idDef = defOf("flash_id_rows_of").text;
const idBody = idDef.slice(0, idDef.indexOf("$$;", 80));
const sqlKeys = [...(idBody.match(/where k not in \(([^)]*)\)/)?.[1] ?? "").matchAll(/'([a-z_]+)'/g)].map((m) => m[1]);
const noStatusKind = idBody.match(/k = 'status' and v_kind = '([a-z]+)'/)?.[1] ?? null;
const mc = idBody.match(/case v_kind when 'customer' then '([a-z_]+)'\s*when 'subscription' then '([a-z_]+)' else '([a-z_]+)' end/);
const sqlMeasure = mc ? { customer: mc[1], subscription: mc[2], device: mc[3] } : {};
const sqlTakes = (kind, f) => Object.entries(f).every(([k, v]) => sqlKeys.includes(k) && !(k === "status" && kind === noStatusKind)
  && (k !== "measure" || v === sqlMeasure[kind]));
const { mockFlashRows, mockRecordFlashFile } = await import("../src/lib/data/mock-flash.ts");
const { CmaDbError } = await import("../src/lib/data/errors.ts");
const reader = { tenantId: "00000000-0000-7000-8000-000000000001", userId: "00000000-0000-7000-8000-0000000000aa", permissions: ["reports.view"],
  timeZone: "Europe/Amsterdam", locale: "en" };
const lastMonthEnd = (() => { const d = new Date(); d.setUTCDate(0); return d.toISOString().slice(0, 10); })();
const codeOfCall = (fn) => { try { fn(); return "ok"; } catch (e) { return e instanceof CmaDbError ? e.sqlState : String(e?.message ?? e); } };
let clicked = 0;
const notTaken = [];
const mockRefusedKept = [];
const mockTookDropped = [];
for (const key of Object.keys(FLASH_FROZEN_LIST)) {
  const def = overviewOf(key);
  const kind = FLASH_FROZEN_LIST[key].kind;
  for (const set of [["market"], ...breakdownSets(def)]) {
    const dims = Object.fromEntries(set.map((d) => [d, d === "market" ? "GB" : `${d}-1`]));
    for (const m of [null, ...def.countMeasures]) {
      clicked += 1;
      // the cell's link (FlashParts' cellLink) as an address, read back as the page reads it, with its market (K)
      const address = Object.fromEntries(Object.entries(cellFilters(dims, m)).map(([k, v]) => [k === "measure" ? k : `f_${k}`, v]));
      const filters = parseFilters(def, (k) => address[k]);
      filters.market = "GB";
      const { kept, dropped } = frozenFilters(def, filters);
      if (!sqlTakes(kind, kept) || (dropped.length === 0) !== sqlTakes(kind, filters)) notTaken.push(`${key}:${set.join("+")}:${m ?? "row"}`);
      const req = (f) => ({ overview: key, filters: f, asOf: lastMonthEnd, from: null, to: null, sort: null, descending: false, limit: 500, offset: 0 });
      // the mock answers what the page sends (rows, or CMA02 when its fixture holds no list for that date), never CMA04
      if (codeOfCall(() => mockFlashRows(reader, req(kept))) === "CMA04") mockRefusedKept.push(`${key}:${set.join("+")}:${m ?? "row"}`);
      if (dropped.length > 0 && codeOfCall(() => mockFlashRows(reader, req(filters))) !== "CMA04") mockTookDropped.push(`${key}:${set.join("+")}:${m ?? "row"}`);
    }
  }
}
expect("db/122's frozen list takes market, status (not a customer's) and its own measure (read from cma.flash_id_rows_of)",
  [sqlKeys, noStatusKind, sqlMeasure], [["market", "status", "measure"], "customer", { customer: "active_customers", subscription: "active_subscriptions", device: "devices" }],
  [[], null, {}]);
expect(`a month end: every breakdown cell of customers, subscriptions and the installed base (${clicked}) sends only what the frozen list takes`,
  [clicked > 30, PROVOKE ? ["provoked"] : notTaken], [true, []], [false, []]);
expect("the mock refuses as the database does: never what the page sends, always a filter the list cannot apply (CMA04)",
  [PROVOKE ? ["provoked"] : mockRefusedKept, PROVOKE ? ["provoked"] : mockTookDropped], [[], []], [["x"], ["x"]]);
expect("a list's refusal is the page's not-available state (CMA02, CMA04), any other an error",
  [listUnavailable("CMA02"), listUnavailable("CMA04"), listUnavailable("CMA06"), listUnavailable(null)], [true, true, false, false], [false, false, true, true]);
// since addition 0008zw an overview renders through components/FlashOverview (Reports → Flash and Assets → Installed base):
// the page's checks read the page and that module together
const overviewSrc = readFileSync(path.join(here, "..", "src", "components", "FlashOverview.tsx"), "utf8");
const pageSrc = readFileSync(path.join(here, "..", "src", "app", "reports", "flash", "page.tsx"), "utf8") + overviewSrc;
expect("the page reads a frozen list with frozenFilters' kept filters, names the dropped ones, and its file asks the same",
  [/frozenFilters\(def, filters\)/.test(pageSrc), /filters: got\.plan\.rowFilters/.test(pageSrc), /Object\.entries\(rowFilters\)/.test(pageSrc),
    /listUnavailable\(e\.sqlState\)/.test(pageSrc), pageSrc.includes("flash-rows-unavailable") && pageSrc.includes("flash-frozen-filters"),
    // a refused As of or period (a reader ahead of the tenant's zone): the tenant's today from the database, then read again
    /today = \(await data\(\)\.getFlashSnapshots\(me, null, null\)\)\.to;/.test(pageSrc) && (pageSrc.match(/adoptTenantToday\(\)/g) ?? []).length >= 2],
  [true, true, true, true, true, true], [false, false, false, false, false, false]);
expect("a market filter that is no market code is dropped from the address, as the database would refuse it",
  [parseFilters(overviewOf("customers"), (k) => ({ f_market: "gb" })[k]), parseFilters(overviewOf("customers"), (k) => ({ f_market: "NL" })[k])],
  [{}, { market: "NL" }], [{ market: "gb" }, {}]);

// ---- Every bulk read of records is in the audit log (review of #214, Major 2; decision 7) -----------------------------
const routeSrc = (p) => readFileSync(path.join(here, "..", "src", "app", "api", "v1", "reports", ...p, "route.ts"), "utf8");
const recordsBeforeOk = (src) => src.indexOf("recordFlashFile(") > 0 && src.indexOf("recordFlashFile(") < src.lastIndexOf("return ok(");
const dqAdmin = { ...reader, permissions: ["tenant.configure"] };
const fileRead = (o) => ({ overview: "customers", part: "rows", filters: {}, market: null, asOf: null, from: null, to: null, rows: 1, ...o });
expect("the JSON rows routes write the file route's audit record before they answer: /flash/rows, /data-quality/rows",
  [recordsBeforeOk(routeSrc(["flash", "rows"])), recordsBeforeOk(routeSrc(["data-quality", "rows"])), routeSrc(["flash", "file"]).includes("recordFlashFile(")],
  [true, true, true], [false, false, false]);
expect("the record is checked as cma.flash_file_record checks it: data quality's with tenant.configure; no @, no other key, no date not ended",
  [codeOfCall(() => mockRecordFlashFile(dqAdmin, fileRead({ overview: "data_quality", filters: { check: "device_serial_missing" } }))),
    codeOfCall(() => mockRecordFlashFile(dqAdmin, fileRead({}))),
    codeOfCall(() => mockRecordFlashFile(reader, fileRead({ filters: { store: "a@b" } }))),
    codeOfCall(() => mockRecordFlashFile(reader, fileRead({ filters: { email: "x" } }))),
    codeOfCall(() => mockRecordFlashFile(reader, fileRead({ asOf: "2999-12-31" })))],
  ["ok", "CMA06", "CMA04", "CMA04", "CMA04"], ["CMA06", "ok", "ok", "ok", "ok"]);

// ---- The routes' and files' own checks (review of #214, Minors 3 to 6) ------------------------------------------------
const apiSrc = readFileSync(path.join(here, "..", "src", "lib", "api", "flash.ts"), "utf8");
const fileSrc = routeSrc(["flash", "file"]);
expect("market wins over f_market; an unknown part is a 400; a file names its market, says when it is cut, refuses a source not set up",
  [/if \(q\.market\) filters\.market = q\.market;/.test(apiSrc), /invalid_part/.test(routeSrc(["flash"])),
    /const market = part === "breakdown" \? q\.market : q\.market \?\? q\.filters\.market/.test(fileSrc), /rows \$\{list\.rows\.length\} of \$\{list\.total\}/.test(fileSrc),
    (fileSrc.match(/not_set_up/g) ?? []).length >= 2, /zone = list\.timeZone/.test(fileSrc)],
  [true, true, true, true, true, true], [false, false, false, false, false, false]);

// ---- The labels against docs/definitions.md (review of #214, Major 3 and Minor 8) -------------------------------------
const { copy: copyAll } = await import("../src/lib/copy.ts");
const en = copyAll.en.flash;
const nl = copyAll.nl.flash;
expect("Dutch: past-due maintenance items are achterstallig, never te laat (a task's overdue alone is Te laat)",
  [/achterstallig/i.test(nl.h_installed_base), /te laat/i.test(nl.h_installed_base), nl.m_overdue, /te laat/i.test(nl.m_components_past_due ?? "")],
  [true, false, "Te laat", false], [false, true, "", true]);
expect("labels: Financial status, Link level (Koppelniveau), Dag, Assetregister, cyclus and Volgende verlenging; no invoice word in Flash's Dutch",
  [en.c_financial_status, en.c_link_level, nl.c_link_level, nl.c_business_date, nl.source_assets, nl.m_amount_per_cycle, nl.c_next_billing_at,
    Object.values(nl).filter((v) => typeof v === "string" && /factu/i.test(v)).length],
  ["Financial status", "Link level", "Koppelniveau", "Dag", "Assetregister", "Bedrag per cyclus", "Volgende verlenging", 0],
  ["", "", "", "", "", "", "", 1]);

// ---- A measure that does not apply (Decision log, 3 Nov 2026): left out by the database, never 0 or all ---------------
const leftOut = {};
// the computation's and the list read's latest definitions (cma.flash_compute_of since 0008zt is 136's)
const computeSql = defOf("flash_compute_of").text.slice(0, defOf("flash_compute_of").text.indexOf("\n$$;")) + "\n" + defOf("flash_rows").text;
for (const m of computeSql.matchAll(/(v_[a-z_]+) boolean := cardinality\(cma\.flash_list_of\(cma\.setting_of\(p_tenant_id, '([a-z_.]+)'\)\)\) > 0;/g)) {
  const flag = m[1];
  const om = computeSql.match(new RegExp(`when ${flag}\\s+then jsonb_build_object\\('([a-z_]+)'`));
  const ov = computeSql.slice(0, computeSql.indexOf(om?.[0] ?? "\u0000")).match(/p_overview = '([a-z_]+)' then\s*$|elsif p_overview = '([a-z_]+)'|if p_overview = '([a-z_]+)'/g)?.pop()?.match(/'([a-z_]+)'/)?.[1];
  if (om && ov) (leftOut[ov] ??= {})[om[1]] = m[2];
}
const refused = [...computeSql.matchAll(/p_overview = '([a-z_]+)' and \(v_filters ->> 'measure'\) = '([a-z_]+)'\s+and cardinality\(cma\.flash_list_of\(cma\.setting_of\(v_tenant, '([a-z_.]+)'\)\)\) = 0/g)]
  .map((m) => `${m[1]}.${m[2]}:${m[3]}`);
expect("db/122 leaves a measure out while its setting is empty and refuses its records; the page's conditional measures are those",
  [leftOut, refused, FLASH_CONDITIONAL_MEASURES],
  [{ customers: { with_required_refs: "commerce.required_contact_refs" } }, ["customers.with_required_refs:commerce.required_contact_refs"],
    { customers: { with_required_refs: "commerce.required_contact_refs" } }],
  [{}, [], {}]);
const flashPartsSrc = readFileSync(path.join(here, "..", "src", "components", "FlashParts.tsx"), "utf8");
expect("a measure a row leaves out reads not applicable (Niet van toepassing) in the totals, the total row and every cell, without a link; present, never",
  [measureNotApplicable("customers", { customers_held: 5, linked_to_contact: 2 }, "with_required_refs"),
    measureNotApplicable("customers", { with_required_refs: 0 }, "with_required_refs"), measureNotApplicable("customers", {}, "customers_held"),
    measureNotApplicable("customers", null, "with_required_refs"), measureNotApplicable("orders", {}, "orders"),
    (flashPartsSrc.match(/measureNotApplicable\(def\.key, /g) ?? []).length,
    /measureNotApplicable\(def\.key, r\.measures, m\)\s*\?\s*<NotApplicable measure=\{m\} t=\{t\} \/>\s*:\s*def\.countMeasures\.includes\(m\)/.test(flashPartsSrc),
    en.notApplicable, nl.notApplicable, typeof en.na_with_required_refs === "string" && typeof nl.na_with_required_refs === "string"],
  [true, false, false, false, false, 3, true, "Not applicable", "Niet van toepassing", true],
  [false, true, true, true, true, 0, false, "", "", false]);
const { mockCustomersFigures } = await import("../src/lib/data/mock-flash.ts");
const someCustomers = [{ contact_id: "c1", contact_held: true, missing_refs: [], active_subscriptions: 1, paused_subscriptions: 0 },
  { contact_id: null, contact_held: false, missing_refs: [], active_subscriptions: 0, paused_subscriptions: 1 }];
const customersDef = overviewOf("customers");
expect("a file leaves a measure that does not apply empty, never 0; the mock leaves it out as the database does, and keeps it when required",
  [breakdownRows(customersDef, [{ dims: {}, measures: { customers_held: 2, active_customers: 1, paused_customers: 1, linked_to_contact: 1 } }])[0].with_required_refs,
    "with_required_refs" in mockCustomersFigures(someCustomers, false), mockCustomersFigures(someCustomers, true).with_required_refs],
  [null, false, 1], [0, true, 2]);

// ---- A pipeline's and a stage's label (Decision log, 4 Nov 2026): on screen and in the files, the id kept ---------------
// cma.flash_labels_of keys a stage '<pipeline id>:<stage id>' and a pipeline (a ticket's queue) by its own id; the screen
// and the files look a stage up with its row's own pipeline. HubSpot's default pipeline's stage ids are ids like any other
const {
  FLASH_LABELLED_DIMS, dimLabelOf, dimText, withLabels, withLabelColumns, filtersShown, labelColumnOf,
} = await import("../src/lib/flash.ts");
const labelsDef = defOf("flash_labels_of").text;
const labelsSql = labelsDef.slice(0, labelsDef.indexOf("$$;", 80));
expect("db/122's labels: a stage keyed '<pipeline id>:<stage id>', a pipeline and a queue by the pipeline's id; the labelled dims are dims of their overview",
  [/'stage', case when p_overview in \('open_deals', 'open_tickets'\)\s+then \(select jsonb_object_agg\(cs\.source_pipeline_id \|\| ':' \|\| cs\.source_stage_id, cs\.label\)/.test(labelsSql),
    /'pipeline', case when p_overview = 'open_deals'\s+then \(select jsonb_object_agg\(p\.source_pipeline_id, p\.label\)/.test(labelsSql),
    /'queue', case when p_overview = 'open_tickets'\s+then \(select jsonb_object_agg\(p\.source_pipeline_id, p\.label\)/.test(labelsSql),
    Object.entries(FLASH_LABELLED_DIMS).every(([o, dims]) => Object.entries(dims).every(([d, parts]) => overviewOf(o).dims.includes(d) && parts.every((x) => overviewOf(o).dims.includes(x)))),
    Object.keys(FLASH_LABELLED_DIMS).sort()],
  [true, true, true, true, ["open_deals", "open_tickets"]], [false, false, false, false, []]);
const crmLabels = {
  pipeline: { default: "Sales", "7000000001": "Invest" }, queue: { "7000000002": "Service" },
  stage: { "default:appointmentscheduled": "Appointment made", "default:1000000001": "Quote asked", "7000000001:1000000001": "Intake",
    "7000000002:2000000001": "Waiting on us" },
};
const deal = { record_id: "5100001", pipeline: "default", stage: "1000000001", market: "GB" };
expect("a stage's label by its row's pipeline and its own id; the same stage id in another pipeline its own; a pipeline's by its id",
  [dimLabelOf("open_deals", crmLabels, "stage", deal), dimLabelOf("open_deals", crmLabels, "stage", { ...deal, pipeline: "7000000001" }),
    dimLabelOf("open_deals", crmLabels, "stage", { pipeline: "default", stage: "appointmentscheduled" }), dimLabelOf("open_deals", crmLabels, "pipeline", deal),
    dimLabelOf("open_tickets", crmLabels, "stage", { queue: "7000000002", stage: "2000000001" }), dimLabelOf("open_tickets", crmLabels, "queue", { queue: "7000000002" })],
  ["Quote asked", "Intake", "Appointment made", "Sales", "Waiting on us", "Service"], [null, null, null, null, null, null]);
expect("a stage is never looked up by its id alone (the key of #214's breakdown), nor without its pipeline",
  [dimLabelOf("open_deals", { stage: { "1000000001": "By id alone" } }, "stage", deal), dimLabelOf("open_deals", crmLabels, "stage", { stage: "1000000001" })],
  [null, null], ["By id alone", "Quote asked"]);
expect("a missing label shows the id, on screen and in the file's label column; other dims by their own labels as before",
  [dimText("open_deals", crmLabels, "stage", { pipeline: "default", stage: "qualifiedtobuy" }), dimText("open_deals", null, "pipeline", deal),
    withLabels("open_deals", [{ pipeline: "default", stage: "qualifiedtobuy" }], crmLabels)[0].stage_label,
    dimText("customers", { market: { GB: "United Kingdom" } }, "market", { market: "GB" }), dimText("open_deals", crmLabels, "market", { market: "NL" })],
  ["qualifiedtobuy", "default", "qualifiedtobuy", "United Kingdom", "NL"], ["", "", null, "GB", ""]);
expect("the records: <dim>_label beside each id, the id kept; empty where a row has none; other overviews' rows unchanged",
  [withLabels("open_deals", [deal], crmLabels)[0], withLabels("open_tickets", [{ queue: "7000000002", stage: "2000000001" }], crmLabels)[0],
    withLabels("open_deals", [{ pipeline: null, stage: "" }], crmLabels)[0], withLabels("orders", [{ store: "s" }], crmLabels)[0]],
  [{ ...deal, pipeline_label: "Sales", stage_label: "Quote asked" }, { queue: "7000000002", stage: "2000000001", queue_label: "Service", stage_label: "Waiting on us" },
    { pipeline: null, stage: "", pipeline_label: null, stage_label: null }, { store: "s" }],
  [deal, {}, {}, { store: "s", store_label: "s" }]);
expect("the records file: each label column right after its id's; every other overview's columns unchanged",
  [withLabelColumns("open_deals", FLASH_LIST_COLUMNS.open_deals).map((c) => c.key).slice(0, 7),
    withLabelColumns("open_tickets", FLASH_LIST_COLUMNS.open_tickets).map((c) => c.key).slice(2, 6),
    FLASH_OVERVIEWS.filter((o) => !FLASH_LABELLED_DIMS[o.key]).every((o) => JSON.stringify(withLabelColumns(o.key, FLASH_LIST_COLUMNS[o.key])) === JSON.stringify(FLASH_LIST_COLUMNS[o.key])),
    labelColumnOf("stage")],
  [["record_id", "record_url", "pipeline", "pipeline_label", "stage", "stage_label", "market"], ["queue", "queue_label", "stage", "stage_label"], true, "stage_label"],
  [["record_id", "record_url", "pipeline", "stage", "market"], ["queue", "stage"], false, "stage"]);
const dealsDef = overviewOf("open_deals");
const dealDoc = [{ dims: {}, measures: { open_deals: 3, median_age_days: 4, oldest_age_days: 9 } },
  { dims: { market: "GB" }, measures: { open_deals: 3, median_age_days: 4, oldest_age_days: 9 } },
  { dims: { market: "GB", pipeline: "default", stage: "1000000001" }, measures: { open_deals: 2, median_age_days: 4, oldest_age_days: 9 } },
  { dims: { market: "GB", pipeline: "default", stage: "qualifiedtobuy" }, measures: { open_deals: 1, median_age_days: 2, oldest_age_days: 2 } }];
expect("the breakdown file: pipeline_label and stage_label beside the ids; the label per line, the id without one, empty on the totals and market lines",
  [breakdownColumns(dealsDef, dealDoc).map((c) => c.key).slice(0, 7),
    breakdownRows(dealsDef, dealDoc, crmLabels).map((r) => [r.set, r.pipeline, r.pipeline_label, r.stage, r.stage_label])],
  [["set", "market", "pipeline", "pipeline_label", "stage", "stage_label", "open_deals"],
    [["totals", null, null, null, null], ["market", null, null, null, null], ["market+pipeline+stage", "default", "Sales", "1000000001", "Quote asked"],
      ["market+pipeline+stage", "default", "Sales", "qualifiedtobuy", "qualifiedtobuy"]]],
  [["set", "market", "pipeline", "stage", "open_deals"], []]);
expect("the overview's heading names a filter by its label; the file's filters cell keeps the ids",
  [filtersText(null, null, null, filtersShown("open_deals", { pipeline: "default", stage: "1000000001", measure: "open_deals" }, crmLabels)),
    filtersText(null, null, null, { pipeline: "default", stage: "1000000001" })],
  ["measure=open_deals; pipeline=Sales; stage=Quote asked", "pipeline=default; stage=1000000001"],
  ["measure=open_deals; pipeline=default; stage=1000000001", ""]);
const pgSrc = readFileSync(path.join(here, "..", "src", "lib", "data", "postgres.ts"), "utf8");
expect("the screen and the files use them: breakdown and records (FlashParts), the heading (page), both file parts, the records read (one statement with the list)",
  [/dimText\(def\.key, doc\.labels, dim, dims\)/.test(flashPartsSrc), /row\[labelColumnOf\(key\)\]/.test(flashPartsSrc),
    /filtersShown\(def\.key, /.test(pageSrc), /breakdownRows\(def, all, doc\.labels\)/.test(fileSrc), /withLabelColumns\(def\.key, FLASH_LIST_COLUMNS\[def\.key\]\)/.test(fileSrc),
    /cma\.flash_rows\(\$1[^`]*as j,\s*case when \$10 then cma\.flash_labels_of\(cma\.current_tenant_id\(\), \$1\) end as l`/.test(pgSrc),
    /toFlashRows\(r\.r, r\.d\.labels\)/.test(pgSrc)],
  [true, true, true, true, true, true, true], [false, false, false, false, false, false, false]);
const mockDeals = mockFlashRows(reader, { overview: "open_deals", filters: {}, asOf: null, from: null, to: null, sort: null, descending: true, limit: 500, offset: 0 });
const mockTickets = mockFlashRows(reader, { overview: "open_tickets", filters: {}, asOf: null, from: null, to: null, sort: null, descending: true, limit: 500, offset: 0 });
expect("the mock answers as the database: labels beside the ids, a stage by its pipeline, a stage without a label as its id",
  [mockDeals.rows.length > 0 && mockDeals.rows.every((r) => typeof r.pipeline_label === "string" && typeof r.stage_label === "string"),
    mockDeals.rows.some((r) => r.pipeline === "pl-invest" && r.stage === "st-negotiation" && r.stage_label === "st-negotiation"),
    mockDeals.rows.some((r) => r.pipeline === "pl-sales" && r.stage === "st-quote" && r.stage_label === "Quote sent"),
    mockTickets.rows.some((r) => r.queue === "tp-support" && r.stage === "ts-waiting" && r.stage_label === "Waiting on contact" && r.queue_label === "Support")],
  [true, true, true, true], [false, false, false, false]);

// ---- Addition 0008zt (brief B29 and its amendment): the ratio kind, the bands, the status hints ------------------------
const subsDef = overviewOf("subscriptions");
const baseDef = overviewOf("installed_base");
const sqlCounts = Object.fromEntries(fromSql.map((o) => [o.key, o.countMeasures]));
expect("a ratio is its own kind: devices per holding subscription neither a count nor an amount; the watch compares counts only, never it",
  [measureKind(subsDef, "devices_per_holding_subscription"), measureKind(subsDef, "holding_subscriptions"), measureKind(subsDef, "amount_per_cycle"),
    measureKind(overviewOf("open_deals"), "median_age_days"), watchedMeasures(subsDef).includes("devices_per_holding_subscription"),
    sqlCounts.subscriptions.includes("devices_per_holding_subscription"), FLASH_OVERVIEWS.every((o) => o.ratioMeasures.every((m) => o.measures.includes(m) && !o.countMeasures.includes(m)))],
  ["ratio", "count", "amount", "number", false, false, true], ["count", "ratio", "count", "count", true, true, false]);
expect("each ratio divides two count measures of its overview; to two decimals, none without a denominator",
  [Object.entries(FLASH_RATIOS).every(([m, [a, b]]) => FLASH_OVERVIEWS.some((o) => o.ratioMeasures.includes(m) && o.countMeasures.includes(a) && o.countMeasures.includes(b))),
    ratioOf(8, 6), ratioOf(1, 3), ratioOf(4, 0), ratioOf(0, 4)],
  [true, 1.33, 0.33, null, 0], [false, 1.3, 0.3, 0, null]);
expect("the device-holding figures: holding_subscriptions and devices_on_holding counts, in_field_on_holding the installed base's; the old active names gone",
  [subsDef.countMeasures.filter((m) => m.includes("holding")), baseDef.countMeasures.includes("in_field_on_holding"),
    FLASH_OVERVIEWS.some((o) => o.measures.some((m) => /on_active|per_active/.test(m)))],
  [["holding_subscriptions", "devices_on_holding"], true, false], [[], false, true]);
expect("each set's measures: a SKU's orders and units, a device band's holding figures, an age band's active subscriptions; every other set every measure",
  [setMeasures(subsDef, ["market", "device_band"]), setMeasures(subsDef, ["market", "age_band"]), setMeasures(overviewOf("orders"), ["market", "sku"]),
    setMeasures(subsDef, ["market"]).length === subsDef.measures.length,
    Object.entries(FLASH_SET_MEASURES).every(([k, sets]) => Object.entries(sets).every(([set, ms]) => overviewOf(k).sets.some((x) => x.join("+") === set)
      && ms.every((m) => overviewOf(k).measures.includes(m))))],
  [["holding_subscriptions", "devices_on_holding", "devices_per_holding_subscription"], ["active_subscriptions"], ["orders", "units"], true, true],
  [[], [], [], false, false]);
expect("the band sets: [market, device_band] and [market, age_band] of the subscriptions only; the bands are dims and sets of their overview",
  [bandDimOf(subsDef, ["market", "device_band"]), bandDimOf(subsDef, ["market", "age_band"]), bandDimOf(subsDef, ["market", "store", "status", "payment_state"]),
    bandDimOf(baseDef, ["market", "subscription_status"]),
    Object.entries(FLASH_BAND_DIMS).every(([k, dims]) => Object.keys(dims).every((d) => overviewOf(k).dims.includes(d) && overviewOf(k).sets.some((x) => x.join("+") === `market+${d}`)))],
  ["device_band", "age_band", null, null, true], [null, null, "x", "x", false]);
expect("band order: below the first bound, then by lower bound, the open-ended after its bound, unknown last",
  [["unknown", "60+", "<12", "12-24", "48-60", "24-36"].sort((a, b) => bandOrder(a) - bandOrder(b)), ["3+", "0", "2", "1-2", "1"].sort((a, b) => bandOrder(a) - bandOrder(b) || a.localeCompare(b)),
    [bandLowerBound("12-24"), bandLowerBound("60+"), bandLowerBound("<12"), bandLowerBound("unknown"), bandLowerBound("0")]],
  [["<12", "12-24", "24-36", "48-60", "60+", "unknown"], ["0", "1", "1-2", "2", "3+"], [12, 60, null, null, 0]],
  [[], [], [null, null, 12, 0, null]]);
const bandDoc = [
  { dims: { market: "GB", device_band: "0" }, measures: { holding_subscriptions: 1, devices_on_holding: 0, devices_per_holding_subscription: 0 } },
  { dims: { market: "GB", device_band: "1" }, measures: { holding_subscriptions: 2, devices_on_holding: 2, devices_per_holding_subscription: 1 } },
  { dims: { market: "GB", device_band: "3+" }, measures: { holding_subscriptions: 1, devices_on_holding: 3, devices_per_holding_subscription: 3 } },
  { dims: { market: "NL", device_band: "1" }, measures: { holding_subscriptions: 1, devices_on_holding: 1, devices_per_holding_subscription: 1 } },
  { dims: { market: "NL", device_band: "3+" }, measures: { holding_subscriptions: 0, devices_on_holding: 0 } },
  { dims: { market: "GB", age_band: "<12" }, measures: { active_subscriptions: 1 } }, { dims: { market: "GB", age_band: "12-24" }, measures: { active_subscriptions: 1 } },
  { dims: { market: "GB", age_band: "60+" }, measures: { active_subscriptions: 1 } }, { dims: { market: "GB", age_band: "24-36" }, measures: { active_subscriptions: 0 } },
  { dims: { market: "GB", age_band: "unknown" }, measures: { active_subscriptions: 1 } }, { dims: { market: "NL", age_band: "24-36" }, measures: { active_subscriptions: 2 } },
  { dims: { market: "GB" }, measures: { holding_subscriptions: 4 } },
];
const devBands = bandRows(bandDoc, "device_band", null, setMeasures(subsDef, ["market", "device_band"]));
const ageBands = bandRows(bandDoc, "age_band", null, ["active_subscriptions"]);
expect("a band table over every market: counts added per band, the ratio worked out again (never added), a band without holders no ratio; one market its own",
  [devBands.map((r) => `${r.dims.device_band}:${r.measures.holding_subscriptions}/${r.measures.devices_on_holding}/${r.measures.devices_per_holding_subscription ?? "-"}`),
    bandRows(bandDoc, "device_band", "NL", setMeasures(subsDef, ["market", "device_band"])).map((r) => `${r.dims.device_band}:${r.measures.holding_subscriptions}/${r.measures.devices_per_holding_subscription ?? "-"}`)],
  [["0:1/0/0", "1:3/3/1", "3+:1/3/3"], ["1:1/1", "3+:0/-"]], [[], []]);
expect("the age bands over every market, in order, and More than N months for each bound above 0: the sum of every band from N up (12 months exactly in 12-24)",
  [ageBands.map((r) => `${r.dims.age_band}:${r.measures.active_subscriptions}`), moreThanRows(ageBands, "age_band", "active_subscriptions")],
  [["<12:1", "12-24:1", "24-36:2", "60+:1", "unknown:1"], [{ months: 12, value: 4 }, { months: 24, value: 3 }, { months: 60, value: 1 }]],
  [[], []]);

// The status hints: the statuses of the tenant's settings, each with the tenant's meaning in the reader's language, or the
// word alone; another tenant's settings give its own words only; nothing of a tenant is written in the code or the copy
const words = { en: { hintCounts: "Counts:", hintHolds: "Holds devices:", hintEnded: "Ended:" } };
const { copy: hintCopy } = await import("../src/lib/copy.ts");
const tenantA = statusSettingsOf({ active_subscription_statuses: ["active"], device_holding_statuses: ["active", "failed"], ended_subscription_statuses: ["canceled", "expired"],
  status_meanings: { active: { en: "Devices at the customer.", nl: "Apparaten bij de klant." }, failed: { en: "Unpaid; devices stay." }, canceled: { en: "Back in the warehouse." } } });
const tenantB = statusSettingsOf({ active_subscription_statuses: ["active"], device_holding_statuses: ["active"], ended_subscription_statuses: ["canceled"], status_meanings: {} });
expect("a hint lists exactly the statuses of the tenant's settings, each with its meaning in the reader's language, the word alone without one",
  [statusHintPart("active", tenantA, "en", hintCopy.en.flash), statusHintPart("holding", tenantA, "en", hintCopy.en.flash), statusHintPart("holding", tenantA, "nl", hintCopy.nl.flash),
    statusHintPart("ended", tenantA, "en", hintCopy.en.flash), statusHintPart("paused", tenantA, "en", hintCopy.en.flash)],
  ["Counts: active: Devices at the customer.", "Holds devices:\nactive: Devices at the customer.\nfailed: Unpaid; devices stay.",
    "Houdt apparaten:\nactive: Apparaten bij de klant.\nfailed.", "Ended:\ncanceled: Back in the warehouse.\nexpired.", "Counts: paused."],
  ["", "", "", "", ""]);
expect("a tenant without meanings: the statuses alone; another tenant's words never; no settings, no generated part",
  [statusHintPart("holding", tenantB, "en", hintCopy.en.flash), statusHintPart("ended", tenantB, "nl", hintCopy.nl.flash),
    [statusHintPart("active", tenantB, "en", words.en), statusHintPart("holding", tenantB, "en", words.en)].some((x) => /customer|warehouse|Unpaid/.test(x ?? "")),
    statusHintPart("active", null, "en", words.en)],
  ["Holds devices: active.", "Beëindigd: canceled.", false, null], ["", "", true, "x"]);
expect("the settings as the database answers them: a meaning only as a text per language; anything else (a number, a list, another language) left out",
  [statusSettingsOf({ status_meanings: { active: { en: 5, nl: "Ja, bij de klant." }, paused: "x", failed: ["x"], expired: { de: "x" } } }).statusMeanings,
    statusSettingsOf(null).deviceHoldingStatuses, statusSettingsOf({ device_holding_statuses: ["active", 3] }).deviceHoldingStatuses],
  [{ active: { nl: "Ja, bij de klant." }, expired: {} }, [], ["active"]], [{}, ["x"], []]);
const allHinted = [...new Set(FLASH_OVERVIEWS.flatMap((o) => o.measures)), ...Object.values(FLASH_BAND_DIMS).flatMap((d) => Object.keys(d)), "segment"];
expect("every Flash measure, band and the segment has its hint in en and nl; the statuses' measures and cards are the brief's; each a measure or a dim",
  [allHinted.filter((m) => typeof hintCopy.en.flash[`mh_${m}`] !== "string" || typeof hintCopy.nl.flash[`mh_${m}`] !== "string"),
    Object.keys(FLASH_STATUS_HINTS).sort(), FLASH_CARD_STATUS_HINTS,
    Object.keys(FLASH_STATUS_HINTS).every((m) => FLASH_OVERVIEWS.some((o) => o.measures.includes(m) || o.dims.includes(m)))],
  // since 0008zu: the amounts name the active statuses; the active customers and Total subscriptions (and their cards) the holding ones they count
  [[], ["active_customers", "active_subscriptions", "amount_per_cycle", "churned", "device_band", "devices_on_holding", "devices_per_holding_subscription",
    "holding_subscriptions", "in_field_on_holding", "paused_customers", "paused_subscriptions"], { customers: ["total"], subscriptions: ["total"], installed_base: ["holding"] }, true],
  [["x"], [], {}, false]);
expect("devices per holding subscription's hint: its own words, the exchange's note (en, nl), then the holding statuses; a card's hint its parts",
  [measureHint("devices_per_holding_subscription", hintCopy.en.flash.mh_devices_per_holding_subscription, tenantB, "en", hintCopy.en.flash),
    /exchange/i.test(hintCopy.en.flash.mh_devices_per_holding_subscription) && /wissel/i.test(hintCopy.nl.flash.mh_devices_per_holding_subscription),
    cardStatusHint("subscriptions", "Base.", tenantB, "en", hintCopy.en.flash), cardStatusHint("orders", "Base.", tenantA, "en", hintCopy.en.flash),
    measureHint("orders", "Orders.", tenantA, "en", hintCopy.en.flash)],
  [`${hintCopy.en.flash.mh_devices_per_holding_subscription}\nHolds devices: active.`, true, "Base.\nCounts: active.", "Base.", "Orders."],
  ["", false, "Base.", "x", ""]);
// no tenant's meaning is written anywhere in the web's code or copy: seed 02's texts are configuration only
const seed = readFileSync(path.join(dbDir, "02_seed_pulse4all.sql"), "utf8");
const seedMeanings = [...(seed.slice(seed.indexOf("'subscription.status_meanings'")).slice(0, 1500).matchAll(/"(?:en|nl)": "([^"]{8,})"/g))].map((m) => m[1].replace(/''/g, "'"));
const srcDir = path.join(here, "..", "src");
const srcTexts = [];
const walk = (d) => { for (const e of readdirSync(d, { withFileTypes: true })) { const f = path.join(d, e.name); if (e.isDirectory()) walk(f); else if (/\.(ts|tsx)$/.test(e.name)) srcTexts.push(readFileSync(f, "utf8")); } };
walk(srcDir);
expect("no tenant's meaning in the web's code or copy: seed 02's ten texts appear in no file of src/",
  [seedMeanings.length, seedMeanings.filter((m) => srcTexts.some((t) => t.includes(m)))], [10, []], [0, ["x"]]);
const partsSrc0008zt = readFileSync(path.join(here, "..", "src", "components", "FlashParts.tsx"), "utf8");
const pageSrc0008zt = readFileSync(path.join(here, "..", "src", "app", "reports", "flash", "page.tsx"), "utf8") + overviewSrc;
const hintSrc = readFileSync(path.join(here, "..", "src", "components", "HeaderHint.tsx"), "utf8");
expect("the page uses them: the tiles' and the headers' hints (MeasureLabel), the cards' and the heading's (cardStatusHint), the band tables, the hint on its lines",
  [(partsSrc0008zt.match(/<MeasureLabel measure=/g) ?? []).length >= 5, /title=\{cardStatusHint\(def\.key, /.test(partsSrc0008zt), /text=\{cardStatusHint\(def\.key, /.test(partsSrc0008zt),
    /statusSettings=\{page\.statusSettings\}/.test(pageSrc0008zt), /statusSettings=\{doc\.statusSettings\}/.test(pageSrc0008zt), /<BandTable def=\{def\}/.test(pageSrc0008zt),
    /moreThanRows\(rows, dim, cumulativeMeasure\)/.test(partsSrc0008zt), /whitespace-pre-line/.test(hintSrc), /FLASH_RATIOS\[measure\] \? 2/.test(partsSrc0008zt)],
  [true, true, true, true, true, true, true, true, true], [false, false, false, false, false, false, false, false, false]);
const { mockFlashOverview, mockFlashPage, mockFlashHeadline } = await import("../src/lib/data/mock-flash.ts");
const mockSubs = mockFlashOverview(reader, "subscriptions", null, null, null, null);
const mockBase = mockFlashOverview(reader, "installed_base", null, null, null, null);
const mockGbBands = mockSubs.rows.filter((r) => r.dims.market === "GB" && "device_band" in r.dims).map((r) => r.dims.device_band);
const sumOf = (rows, measure) => rows.reduce((n, r) => n + Number(r.measures[measure] ?? 0), 0);
expect("the mock answers as the database: every device band's row per market, the holding sums, the ratio, the base's statuses; the hints' settings",
  [mockGbBands, sumOf(mockSubs.rows.filter((r) => "device_band" in r.dims), "holding_subscriptions") === mockSubs.totals.holding_subscriptions,
    sumOf(mockSubs.rows.filter((r) => "age_band" in r.dims), "active_subscriptions") === mockSubs.totals.active_subscriptions,
    mockSubs.totals.devices_per_holding_subscription === ratioOf(mockSubs.totals.devices_on_holding, mockSubs.totals.holding_subscriptions),
    sumOf(mockBase.rows.filter((r) => "subscription_status" in r.dims), "in_field") === mockBase.totals.in_field,
    mockFlashPage(reader, null, null, null, null).statusSettings.deviceHoldingStatuses, mockSubs.statusSettings.deviceHoldingStatuses],
  [["0", "1", "2", "3+"], true, true, true, true, ["active", "failed"], ["active", "failed"]], [[], false, false, false, false, [], []]);

// ---- Since addition 0008zu (brief B30): Total subscriptions and the active customers on the device-holding statuses ----
const subs0008zu = overviewOf("subscriptions");
const cust0008zu = overviewOf("customers");
const splitSrc = defOf("flash_split_dim_of").text;
expect("Total subscriptions is the subscriptions' headline, split per status by the set [market, status] (its rows carry it alone); the database's split dim the page's",
  [subs0008zu.headline, subs0008zu.sets.some((x) => x.join("+") === "market+status"), setMeasures(subs0008zu, ["market", "status"]), FLASH_SPLITS,
    /when p_overview = 'subscriptions' then 'status'/.test(splitSrc), cust0008zu.headline, FLASH_SPLITS.customers ?? null],
  ["holding_subscriptions", true, ["holding_subscriptions"], { subscriptions: { set: ["market", "status"], dim: "status", measure: "holding_subscriptions" },
    orders: { set: ["market", "store", "kind"], dim: "kind", measure: "orders" } }, true, "active_customers", null],
  ["active_subscriptions", false, [], {}, false, "", "x"]);
const splitRows = [
  { dims: {}, measures: { holding_subscriptions: 9 } }, { dims: { market: "GB" }, measures: { holding_subscriptions: 7 } },
  { dims: { market: "GB", status: "active" }, measures: { holding_subscriptions: 3 } }, { dims: { market: "GB", status: "failed" }, measures: { holding_subscriptions: 1 } },
  { dims: { market: "NL", status: "active" }, measures: { holding_subscriptions: 2 } }, { dims: { market: "NL", status: "zz-other" }, measures: { holding_subscriptions: 1 } },
  { dims: { market: "GB", store: "x", status: "active", payment_state: "paid" }, measures: { holding_subscriptions: 50 } },
];
const line = (x) => splitLine(x, (n) => String(n));
expect("a split as the database gives it (139 A4): the setting's order, a status without rows 0, another key after by name, one market; other sets never counted",
  [line(splitOf(subs0008zu, splitRows, null, ["failed", "active", "never-subscribed"])), line(splitOf(subs0008zu, splitRows, "GB", ["active", "failed"])),
    line(splitOf(subs0008zu, splitRows, "FR", ["active", "failed"]))],
  ["failed 1 · active 5 · never-subscribed 0 · zz-other 1", "active 3 · failed 1", "active 0 · failed 0"], ["", "", ""]);
expect("no split for another overview, nor for rows that hold none (a snapshot before 0008zu): zeros never stand in for a split not stored",
  [splitOf(cust0008zu, splitRows, null, ["active"]), splitOf(subs0008zu, splitRows.slice(0, 2), null, ["active", "failed"]), line(null), line([])],
  [null, null, null, null], [[], [], "", ""]);
expect("a split from the database's JSON: a key and a number (or a numeric text) each, anything else left out; not a list, none",
  [splitItemsOf([{ key: "active", value: 7 }, { key: "failed", value: "2" }, { key: "x" }, { value: 1 }, null, { key: "y", value: "two" }]), splitItemsOf(null), splitItemsOf({ key: "a" })],
  [[{ key: "active", value: 7 }, { key: "failed", value: 2 }], null, null], [[], [], []]);
expect("a change of definition is marked where a figure is compared with one counted by an earlier one; never without a figure or a version",
  [definitionChanged("0008zu", "0008zt", 5), definitionChanged("0008zu", "0008zu", 5), definitionChanged("0008zu", "0008zt", null), definitionChanged("0008zu", null, 5),
    definitionChanged(null, "0008zt", 5)],
  [true, false, false, false, false], [false, true, true, true, true]);
expect("the hints since 0008zu: the active customers and Total subscriptions count the holding statuses (Counts:), the amounts the active ones",
  [statusHintPart("total", tenantA, "en", hintCopy.en.flash), measureHint("amount_per_cycle", "Amounts.", tenantA, "en", hintCopy.en.flash),
    measureHint("active_customers", "Customers.", tenantB, "nl", hintCopy.nl.flash), cardStatusHint("customers", "Base.", tenantA, "en", hintCopy.en.flash)],
  ["Counts:\nactive: Devices at the customer.\nfailed: Unpaid; devices stay.", "Amounts.\nCounts: active: Devices at the customer.", "Customers.\nTelt: active.",
    "Base.\nCounts:\nactive: Devices at the customer.\nfailed: Unpaid; devices stay."],
  ["", "", "", ""]);
expect("the copy: Total subscriptions (Totaal abonnementen), the overview Subscriptions, the earlier definition's line with its date, en and nl",
  [hintCopy.en.flash.m_holding_subscriptions, hintCopy.nl.flash.m_holding_subscriptions, hintCopy.en.flash.o_subscriptions, hintCopy.nl.flash.o_subscriptions,
    [hintCopy.en.flash.definitionEarlier, hintCopy.nl.flash.definitionEarlier].every((x) => typeof x === "string" && x.includes("{date}")),
    /device-holding/.test(hintCopy.en.flash.mh_active_customers) && /apparaathoudende/.test(hintCopy.nl.flash.mh_active_customers)],
  ["Total subscriptions", "Totaal abonnementen", "Subscriptions", "Abonnementen", true, true], ["", "", "", "", false, false]);
const controlsSrc0008zu = readFileSync(path.join(here, "..", "src", "components", "FlashControls.tsx"), "utf8");
const partsSrc0008zu = readFileSync(path.join(here, "..", "src", "components", "FlashParts.tsx"), "utf8");
const pageSrc0008zu = readFileSync(path.join(here, "..", "src", "app", "reports", "flash", "page.tsx"), "utf8") + overviewSrc;
expect("the page uses them: a live card's split and its definition's line, a stored card's split and note, the totals' split under the headline",
  [/splitLine\(read\.split, n, /.test(controlsSrc0008zu), /definitionChanged\(read\.version, previousDefinitionVersion, previous\)/.test(controlsSrc0008zu),
    /previousDefinitionVersion=\{card\?\.previousDefinitionVersion \?\? null\}/.test(pageSrc0008zu), /splitLine\(card\?\.split \?\? null/.test(pageSrc0008zu),
    /note=\{asOf && card && definitionChanged\(card\.definitionVersion, card\.previousDefinitionVersion, card\.previous\)/.test(pageSrc0008zu),
    /splitOf\(def, doc\.rows, null, splitOrderOf\(def, doc\.statusSettings\)\)/.test(partsSrc0008zu)],
  [true, true, true, true, true, true], [false, false, false, false, false, false]);
const mockCust0008zu = mockFlashOverview(reader, "customers", null, null, null, null);
const mockRowsCust = (await import("../src/lib/data/mock-flash.ts")).mockFlashRows(reader, { overview: "customers", market: null, asOf: null, from: null, to: null,
  filters: { measure: "active_customers" }, sort: "customer_id", descending: false, limit: 500, offset: 0 });
const mockSplitSum = (m) => sumOf(mockSubs.rows.filter((r) => Object.keys(r.dims).length === 2 && "status" in r.dims && (m === null || r.dims.market === m)), "holding_subscriptions");
const mockToday = mockFlashPage(reader, null, null, null, null);
const mockCut = mockToday.lastSnapshotDate ? new Date(Date.parse(`${mockToday.today}T00:00:00Z`) - 3 * 86_400_000).toISOString().slice(0, 10) : null;
const mockAsOf = mockCut ? mockFlashPage(reader, null, mockCut, null, null).overviews.find((c) => c.key === "subscriptions") : null;
expect("the mock answers as the database: the active customers on the holding statuses (their list the same), the split adding up, the cards' split and versions",
  [mockCust0008zu.totals.active_customers === mockRowsCust.total, mockRowsCust.rows.every((r) => Number(r.holding_subscriptions) > 0),
    mockSplitSum(null) === mockSubs.totals.holding_subscriptions, mockFlashHeadline(reader, "subscriptions", null, null, null).split?.map((x) => x.key),
    mockFlashHeadline(reader, "subscriptions", null, null, null).definitionVersion,
    mockAsOf ? [mockAsOf.definitionVersion, mockAsOf.previousDefinitionVersion, Array.isArray(mockAsOf.split)] : null],
  [true, true, true, ["active", "failed"], "0008zu", ["0008zu", "0008zt", true]], [false, false, false, [], "", null]);

// ---- Since addition 0008zw: the Orders headline per order kind; Flash's Installed base on Assets → Installed base -----------
const orders0008zw = overviewOf("orders");
const kindRows = [
  { dims: {}, measures: { orders: 9 } }, { dims: { market: "GB" }, measures: { orders: 6 } },
  { dims: { market: "GB", store: "gb-1", kind: "first" }, measures: { orders: 2 } }, { dims: { market: "GB", store: "gb-2", kind: "first" }, measures: { orders: 1 } },
  { dims: { market: "GB", store: "gb-1", kind: "renewal" }, measures: { orders: 2 } }, { dims: { market: "GB", store: "gb-2", kind: "repeat" }, measures: { orders: 1 } },
  { dims: { market: "NL", store: "nl-1", kind: "first" }, measures: { orders: 1 } }, { dims: { market: "NL", store: "nl-1", kind: "unknown" }, measures: { orders: 2 } },
  { dims: { market: "GB", sku: "A" }, measures: { orders: 50 } }, { dims: { market: "GB", kind: "first" }, measures: { orders: 60 } },
  { dims: { market: "GB", store: "gb-1", kind: "first", status: "PAID" }, measures: { orders: 70 } },
];
const kindLine = (x, locale = "en") => splitLine(x, (n) => String(n), (k) => splitKeyLabel("orders", k, hintCopy[locale].flash));
const kindOrder = splitOrderOf(orders0008zw, null);
expect("the orders per kind as the database gives them (143 A1): summed over the stores, three kinds with zeros, Unknown only above 0, one market; other sets never counted",
  [kindLine(splitOf(orders0008zw, kindRows, null, kindOrder)), kindLine(splitOf(orders0008zw, kindRows, "GB", kindOrder)), kindLine(splitOf(orders0008zw, kindRows, "FR", kindOrder)),
    kindLine(splitOf(orders0008zw, kindRows, "NL", kindOrder), "nl"), splitOf(orders0008zw, kindRows.slice(0, 2), null, kindOrder),
    kindLine(splitOf(orders0008zw, [...kindRows, { dims: { market: "DE", store: "de-1", kind: "unknown" }, measures: { orders: 0 } }], "DE", kindOrder))],
  ["First 4 · Renewal 2 · Repeat 1 · Unknown 2", "First 3 · Renewal 2 · Repeat 1", "First 0 · Renewal 0 · Repeat 0", "Eerste 1 · Verlenging 0 · Herhaal 0 · Onbekend 2",
    null, "First 0 · Renewal 0 · Repeat 0"],
  ["", "", "", "", [], "First 0 · Renewal 0 · Repeat 0 · Unknown 0"]);
expect("the parts add up to the Orders figure, in all and per market",
  [["*", "GB", "NL"].map((m) => (splitOf(orders0008zw, kindRows, m === "*" ? null : m, kindOrder) ?? []).reduce((n, x) => n + x.value, 0)).join(" ")],
  ["9 6 3"], ["9 6 2"]);
const splitDimSrc = defOf("flash_split_dim_of");
const splitSetSrc = defOf("flash_split_set_of").text.slice(0, 400);
const splitOrderSrc = defOf("flash_split_order_of").text.slice(0, 500);
expect("the database's split catalog is the page's (142): the orders by kind over [market, store, kind], first, renewal, repeat in that order",
  [splitDimSrc.file, /when p_overview = 'orders' then 'kind'/.test(splitDimSrc.text.slice(0, 400)), /when p_overview = 'orders' then array\['market', 'store', 'kind'\]/.test(splitSetSrc),
    /when p_overview = 'orders' then array\['first', 'renewal', 'repeat'\]/.test(splitOrderSrc), FLASH_ORDER_KINDS, splitOrderOf(overviewOf("subscriptions"), { deviceHoldingStatuses: ["active", "failed"] }),
    splitOrderOf(overviewOf("customers"), { deviceHoldingStatuses: ["active"] })],
  ["142_reviews_all_order_kinds.sql", true, true, true, ["first", "renewal", "repeat"], ["active", "failed"], []],
  ["138_flash_totals.sql", false, false, false, ["first", "repeat", "renewal"], [], ["active"]]);
expect("the kinds' words, en and nl, for a client too; a subscription status stays the app's word",
  [splitLabelsOf("orders", hintCopy.en.flash), splitLabelsOf("orders", hintCopy.nl.flash), splitLabelsOf("subscriptions", hintCopy.en.flash), splitKeyLabel("subscriptions", "active", hintCopy.en.flash)],
  [{ first: "First", renewal: "Renewal", repeat: "Repeat", unknown: "Unknown" }, { first: "Eerste", renewal: "Verlenging", repeat: "Herhaal", unknown: "Onbekend" }, {}, "active"],
  [{}, {}, { active: "active" }, "Active"]);
const mockOrders = mockFlashHeadline(reader, "orders", null, null, null);
expect("the mock answers as the database: the Orders headline split per kind, adding up to the figure",
  [mockOrders.split?.slice(0, 3).map((x) => x.key), (mockOrders.split ?? []).reduce((n, x) => n + x.value, 0) === mockOrders.value],
  [["first", "renewal", "repeat"], true], [["first", "repeat", "renewal"], false]);
const ibPageSrc = readFileSync(path.join(here, "..", "src", "app", "reports", "installed-base", "page.tsx"), "utf8");
const flashOnlySrc = readFileSync(path.join(here, "..", "src", "app", "reports", "flash", "page.tsx"), "utf8");
expect("both pages render an overview through components/FlashOverview; Installed base its own overview on its own path, without Flash's strip and o",
  [/<FlashOverview me=\{me\} copy=\{copy\} st=\{st\} def=\{def\} path="\/reports\/flash" active="flash"/.test(flashOnlySrc),
    /flashState\(me, await searchParams, "installed_base"\)/.test(ibPageSrc) && /path="\/reports\/installed-base" active="installed-base"/.test(ibPageSrc),
    /holdsAny\(me, REPORT_PERMISSIONS\)/.test(ibPageSrc), /\{own \? <FlashStrip /.test(overviewSrc), /path === "\/reports\/flash" && def \? \{ o: def\.key \} : \{\}/.test(overviewSrc),
    flashHref("/reports/installed-base", { market: "GB", f_status: "field" }), flashHref("/reports/flash", {})],
  [true, true, true, true, true, "/reports/installed-base?market=GB&f_status=field", "/reports/flash"],
  [false, false, false, false, false, "/reports/flash?market=GB&f_status=field", "/reports/flash?"]);
expect("every link and control of an overview keeps its page: the cells, the bands, the sort, the As of and the market",
  [(partsSrc0008zu.match(/, path\)/g) ?? []).length >= 3, /router\.push\(flashHref\(path, q\) as Route\)/.test(controlsSrc0008zu),
    (overviewSrc.match(/path=\{path\}/g) ?? []).length >= 5, /\/reports\/flash/.test(overviewSrc.replace(/"\/reports\/flash"/g, "").replace(/\/api\/v1\/reports\/flash/g, ""))],
  [true, true, true, false], [false, false, false, true]);
expect("the orders' kind is the split's word in the breakdown and the records too; the code stays in the files and on hover",
  [/if \(def\.key === "orders" && dim === "kind"\) return splitKeyLabel\(def\.key, dims\[dim\] \?\? "", t\);/.test(partsSrc0008zu),
    /def\.key === "orders" && c\.key === "kind"[\s\S]{0,120}<span title=\{String\(r\[c\.key\]\)\}>\{splitKeyLabel\(def\.key, String\(r\[c\.key\]\), t\)\}/.test(partsSrc0008zu)],
  [true, true], [false, false]);
expect("the landing labels the split: a stored card's kinds in the reader's language, a live card's as data",
  [/splitLine\(card\?\.split \?\? null, \(x\) => fmtNumber\(x, locale, 0\), \(k\) => splitKeyLabel\(o\.key, k, t\)\)/.test(flashOnlySrc),
    /splitLabels: splitLabelsOf\(o\.key, t\)/.test(flashOnlySrc), /labels\.splitLabels\?\.\[k\] \?\? k/.test(controlsSrc0008zu)],
  [true, true, true], [false, false, false]);

const passed = results.filter(Boolean).length;
const n = results.length;
if (PROVOKE) {
  const ok = passed === 0;
  console.log(`\n${ok ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
  process.exit(ok ? 0 : 1);
}
console.log(`\n${passed === n ? `ALL ${n} PASS` : `${n - passed} of ${n} FAILED`}`);
process.exit(passed === n ? 0 : 1);
