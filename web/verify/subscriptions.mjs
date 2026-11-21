/**
 * Verifier: Customers → Subscriptions (addition 0009zh, brief B39 continued, Part B39d), without a browser, a server or a
 * database: the page's copy keys, its address keys, its file's headers, and the mock's answers on any month.
 *
 *   node --experimental-strip-types --import ./verify/lib/alias.mjs verify/subscriptions.mjs             every check must PASS
 *   node --experimental-strip-types --import ./verify/lib/alias.mjs verify/subscriptions.mjs --provoke   every check must FAIL
 *
 *   C  copy: every word the page, its components and its filters read exists in en and nl (subscriptionsCopy), and the
 *      words stay out of the shared catalog (they ride to no client component but the filters' own handful)
 *   A  address: the keys market, store, proposition, interval, from, to, view, measure, sort, dir, page; the default range
 *      (the last twelve complete months and the current one) on any month, January and December included; what is ignored
 *      and why; a range capped at 60 months and to at most the current month; the filters' part of an address
 *   F  files: the list's columns and the months file's columns, ids, codes, dates, counts and amounts only (no name,
 *      email, phone, address or link column); the file's name
 *   M  the mock on four different months (any month: backlog CMA-113): the tiles add up (the split per status to the
 *      Total subscriptions), each month's end is the next month's start, the rates' rows equal the months' complete
 *      parts, the list's totals per measure equal the tiles, every mix breakdown sums to the Total subscriptions,
 *      the proposition and interval filters leave the months as they are, survival's cells never exceed their cohort,
 *      the source counts' place is null (never a zero), Invest is not set up, an agent is refused (CMA06)
 *   R  rates: a share of a base, null without one
 */
import { readFileSync } from "node:fs";
import {
  addMonths, monthsBetween, parseSubscriptionsFilter, rateOf, ratesOf, subscriptionsFileName, subscriptionsQuery, survivalShare, currentMonthIn,
  SUBSCRIPTIONS_ADDRESS, SUBSCRIPTIONS_FILE_COLUMNS, SUBSCRIPTIONS_MONTHS_COLUMNS, SUBSCRIPTIONS_MEASURES, SUBSCRIPTIONS_DEFAULT_MONTHS,
} from "../src/lib/subscriptions.ts";
import { copy, subscriptionsCopy } from "../src/lib/copy.ts";
import { mockSubscriptionRows, mockSubscriptionsPage } from "../src/lib/data/mock-subscriptions.ts";

const PROVOKE = process.argv.includes("--provoke");
const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(86)} got ${JSON.stringify(actual).slice(0, 90)}${pass ? "" : `, wanted ${JSON.stringify(want).slice(0, 90)}`}`);
}
const src = (p) => readFileSync(new URL(`../src/${p}`, import.meta.url), "utf8");

// ---- C. Copy --------------------------------------------------------------------------------------------------------------
{
  const files = ["components/SubscriptionsReport.tsx", "app/reports/subscriptions/page.tsx", "components/SubscriptionsFilters.tsx"].map(src).join("\n");
  const used = [...new Set([...files.matchAll(/\bt\.([a-zA-Z_]+)\b/g)].map((m) => m[1]))].filter((k) => !["replace", "length"].includes(k));
  // keys built from a prefix and a value: every value of the prefix's list must exist
  const built = [
    ...["start", "new", "migrated", "reactivated", "resumed", "paused", "churned", "moved_to_failed", "end", "expansion", "contraction"].map((k) => `kind_${k}`),
    ...["monthly", "quarterly", "yearly", "other", "unknown"].map((k) => `interval_${k}`),
    ...SUBSCRIPTIONS_MEASURES.map((k) => `measure_${k}`), "view_counts", "view_amounts",
    ...["proposition", "model", "interval", "deviceBand", "ageBand", "instrument", "paymentState"].map((k) => `mix_${k}`),
    ...["paid", "in_retry", "charged_back", "awaiting_payment", "failed", "paused", "canceled", "unknown"].map((k) => `pay_${k}`),
    ...["active", "paused", "failed", "canceled", "expired", "merged", "never_subscribed"].map((k) => `status_${k}`),
    "basis_first_order", "basis_created",
  ];
  const missing = (lang) => [...used, ...built].filter((k) => typeof subscriptionsCopy[lang][k] !== "string");
  expect("C1 every word the page reads exists in en and nl", [missing("en"), missing("nl")], [[], []], [["x"], ["x"]]);
  expect("C2 the page's words stay out of the shared catalog; the placeholder's words stay for the not-set-up state",
    ["subscriptions" in copy.en, typeof copy.en.placeholders.intro_subscriptions, typeof copy.nl.placeholders.fedBy_subscriptions],
    [false, "string", "string"], [true, "undefined", "undefined"]);
  expect("C3 no forbidden word in the page's words (MRR, dunning, failed payment, cancelled)",
    Object.values(subscriptionsCopy.en).concat(Object.values(subscriptionsCopy.nl)).filter((w) => /\bMRR\b|dunning|failed payment|cancelled/i.test(w)),
    [], ["x"]);
}

// ---- A. The address ---------------------------------------------------------------------------------------------------------
{
  const get = (q) => (k) => q[k];
  const nov = "2026-11-01";
  const d = parseSubscriptionsFilter(get({}), nov);
  expect("A1 the address keys", Object.values(SUBSCRIPTIONS_ADDRESS),
    ["market", "store", "proposition", "interval", "from", "to", "view", "measure", "sort", "dir", "page"], []);
  expect("A2 the default range: the last twelve complete months and the current one, on any month",
    [[d.from, d.to, d.problem], parseSubscriptionsFilter(get({}), "2027-01-01").from, parseSubscriptionsFilter(get({}), "2026-12-01").from,
      monthsBetween(d.from, d.to).length, SUBSCRIPTIONS_DEFAULT_MONTHS],
    [["2025-11-01", "2026-11-01", null], "2026-01-01", "2025-12-01", 13, 13], [[], "", "", 0, 0]);
  const s = parseSubscriptionsFilter(get({ market: "GB", store: "00000000-0000-7000-8000-00000005b001", proposition: "none", interval: "yearly", from: "2026-01", to: "2026-06" }), nov);
  expect("A3 the filters and the range kept; their address again", [s.filter, s.from, s.to, s.problem, subscriptionsQuery(s.filter)],
    [{ market: "GB", store: "00000000-0000-7000-8000-00000005b001", proposition: "none", interval: "yearly" }, "2026-01-01", "2026-06-01", null,
      { market: "GB", store: "00000000-0000-7000-8000-00000005b001", proposition: "none", interval: "yearly" }], []);
  const bad = (q) => { const r = parseSubscriptionsFilter(get(q), nov); return [r.problem, r.from, r.to]; };
  expect("A4 what is ignored and why: a market, store, proposition or interval out of form, a month out of form, to after this month, from after to, more than 60 months",
    [bad({ market: "gb" })[0], bad({ store: "x" })[0], bad({ proposition: "Hs1" })[0], bad({ interval: "weekly" })[0], bad({ from: "2026-13" })[0],
      bad({ to: "2027-01" }), bad({ from: "2026-10", to: "2026-05" }), bad({ from: "2018-01" })],
    ["market", "store", "proposition", "interval", "from", ["to", "2025-11-01", "2026-11-01"], ["range", "2025-05-01", "2026-05-01"], ["range", "2021-12-01", "2026-11-01"]],
    []);
  expect("A5 months move across years; the current month in a zone", [addMonths("2026-01-01", -1), addMonths("2026-12-01", 1), addMonths("2026-05-01", -17),
    currentMonthIn("Europe/Amsterdam", new Date("2026-11-30T23:30:00Z")), currentMonthIn("Europe/London", new Date("2026-11-30T23:30:00Z"))],
    ["2025-12-01", "2027-01-01", "2024-12-01", "2026-12-01", "2026-11-01"], []);
}

// ---- F. Files ---------------------------------------------------------------------------------------------------------------
{
  const personal = /name|email|phone|address|url|link/;
  expect("F1 the list's file: ids, codes, dates, counts and amounts only; the contact's id, never its link", [
    [...SUBSCRIPTIONS_FILE_COLUMNS].filter((c) => personal.test(c)), SUBSCRIPTIONS_FILE_COLUMNS.includes("contact_id"), SUBSCRIPTIONS_FILE_COLUMNS.length],
  [[], true, 16], [["x"], false, 0]);
  expect("F2 the months file: the month, every movement kind and the rates' parts", [...SUBSCRIPTIONS_MONTHS_COLUMNS],
    ["month", "start", "new", "migrated", "reactivated", "resumed", "paused", "churned", "moved_to_failed", "end", "expansion", "contraction", "rate_base",
      "rate_churned", "rate_moved_to_failed"], []);
  expect("F3 the file's name", [subscriptionsFileName("records", { market: "GB", store: null, proposition: "hs1", interval: "monthly" }, "2026-11-21T0900"),
    subscriptionsFileName("months", { market: null, store: null, proposition: null, interval: null }, "2026-11-21T0900")],
  ["subscriptions-records-gb-monthly-hs1-2026-11-21T0900.csv", "subscriptions-months-all-2026-11-21T0900.csv"], []);
  const route = src("app/api/v1/reports/subscriptions/file/route.ts");
  expect("F4 the file is recorded in the audit log before it is sent, both parts", [(route.match(/recordSubscriptionFile/g) ?? []).length,
    route.indexOf("recordSubscriptionFile(me, \"months\"") < route.indexOf("return csvFile(text, subscriptionsFileName(\"months\""),
    route.indexOf("recordSubscriptionFile(me, \"records\"") < route.indexOf("return csvFile(text, subscriptionsFileName(\"records\"")],
  [2, true, true], [0, false, false]);
}

// ---- M. The mock on any month -------------------------------------------------------------------------------------------------
{
  const realNow = Date.now;
  const me = { tenantId: "00000000-0000-7000-8000-000000000001", permissions: ["reports.view"], timeZone: "Europe/Amsterdam", locale: "en" };
  const out = [];
  for (const at of ["2026-11-21T10:00:00Z", "2027-01-03T08:00:00Z", "2026-12-31T22:30:00Z", "2028-03-01T12:00:00Z"]) {
    Date.now = () => Date.parse(at);
    const month = currentMonthIn(me.timeZone, new Date(Date.now()));
    const q = { market: null, store: null, proposition: null, interval: null, from: addMonths(month, -12), to: month, measure: "total", sort: "monthly_amount", descending: true };
    const p = mockSubscriptionsPage(me, q);
    const t = p.tiles;
    const ms = p.months;
    const chain = ms.slice(1).filter((m, i) => m.counts && ms[i].counts && (m.counts.start ?? 0) !== (ms[i].counts.end ?? 0)).length;
    const rateParts = p.rates.reduce((n, r) => n + r.churned, 0) === ms.reduce((n, m) => n + (m.complete?.churned ?? 0), 0);
    const rows = (measure) => mockSubscriptionRows(me, { ...q, measure, page: 1 }).total;
    const mixOk = ["interval", "deviceBand", "ageBand", "instrument", "paymentState"].every((k) => p.mix[k].reduce((n, r) => n + r.subscriptions, 0) === t.total.value);
    const narrowed = mockSubscriptionsPage(me, { ...q, proposition: "hs1", interval: "monthly" });
    const survOk = p.survival.groups.every((g) => g.cohorts.every((c) => c.cells.every((x) => x.survived <= c.started && x.eligible <= c.started)));
    out.push([
      Object.values(t.total.byStatus).reduce((a, b) => a + b, 0) === t.total.value, chain, rateParts,
      rows("total") === t.total.value && rows("paused") === t.paused && rows("unmapped") === t.devices.unmapped, mixOk,
      JSON.stringify(narrowed.months) === JSON.stringify(ms) && narrowed.tiles.total.value < t.total.value, survOk, t.sourceCounts,
      ms.length === 13 && ms[12].month === month && ms.every((m) => m.counts !== null), t.rates !== null,
    ]);
  }
  Date.now = realNow;
  const ok = [true, 0, true, true, true, true, true, null, true, true];
  expect("M1 on four months: tiles add up, end = next start, rates = months' complete parts, list totals = tiles, mix sums, P and I leave the months, survival bounded, no source counts, a whole range",
    out, Array(4).fill(ok), Array(4).fill([false, 1, false, false, false, false, false, 0, false, false]));
  const inv = mockSubscriptionsPage({ ...me, tenantId: "00000000-0000-7000-8000-000000000002" },
    { market: null, store: null, proposition: null, interval: null, from: "2026-01-01", to: currentMonthIn(me.timeZone), measure: "total", sort: "monthly_amount", descending: true });
  let agent = "ok";
  try { mockSubscriptionsPage({ ...me, permissions: ["workday.own"] }, { market: null, store: null, proposition: null, interval: null, from: "2026-01-01", to: currentMonthIn(me.timeZone), measure: "total", sort: "monthly_amount", descending: true }); }
  catch (e) { agent = e.sqlState ?? String(e); }
  expect("M2 Invest is not set up (nothing more); an agent is refused (CMA06)", [inv.setUp, inv.tiles, inv.list, agent], [false, null, null, "CMA06"], [true, {}, {}, "ok"]);
}

// ---- R. Rates -------------------------------------------------------------------------------------------------------------
expect("R1 a share of a base, null without one; the two rates of a month's parts; a survival cell only when mature",
  [rateOf(3, 120), rateOf(1, 0), rateOf(1, null), ratesOf({ base: 200, churned: 5, movedToFailed: 2 }), ratesOf(null),
    survivalShare(10, { eligible: 10, survived: 7 }), survivalShare(10, { eligible: 9, survived: 7 }), survivalShare(0, { eligible: 0, survived: 0 })],
  [0.025, null, null, { churn: 0.025, failed: 0.01 }, { churn: null, failed: null }, 0.7, null, null], []);

const n = results.length;
const passed = results.filter(Boolean).length;
if (PROVOKE) {
  const ok = passed === 0;
  console.log(`\n${ok ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
  process.exit(ok ? 0 : 1);
}
console.log(`\n${passed === n ? `ALL ${n} PASS` : `${n - passed} of ${n} FAILED`}`);
process.exit(passed === n ? 0 : 1);
