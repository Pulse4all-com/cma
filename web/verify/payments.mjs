/**
 * Verifier: Customers → Payments (addition 0009zy), without a browser, a server or a database: the page's copy keys, the
 * list's states and sort keys, its file's headers and name, the database's document in the API's words, and the mock's
 * answers on any month.
 *
 *   node --experimental-strip-types --import ./verify/lib/alias.mjs verify/payments.mjs             every check must PASS
 *   node --experimental-strip-types --import ./verify/lib/alias.mjs verify/payments.mjs --provoke   every check must FAIL
 *
 *   C  copy: every word the page and its components read exists in en and nl (paymentsCopy beside subscriptionsCopy for
 *      what the two pages share), the page's words stay out of the shared catalog, and no word the definitions forbid
 *      (payment status, failed payment, dunning, MRR, unpaid, overdue amount, cancelled)
 *   L  the list: its states (at_risk first and the default, the five payment states, all) and sort keys (amount_at_risk
 *      first), what an address may ask
 *   F  files: the list's columns and the months file's columns, ids, codes, times, counts and amounts only (no name, email,
 *      phone, address or link column); the file's name; every file recorded in the audit log before it is sent
 *   D  the database's document in the API's words: the tiles, the cross table, the rates, the list's rows; set up false
 *   M  the mock on four different months (any month: backlog CMA-113): the five states add up to the base, the overdue
 *      are among Awaiting payment, the Amount at risk equals the list's at_risk rows per currency, the list's totals per
 *      state equal the tiles, the cross table sums to the base and per state to its tile, the Failed rate's parts equal
 *      Customers → Subscriptions' mock for the same filters, Paused and Canceled are not on the page; Invest is not set up,
 *      an agent is refused (CMA06)
 */
import { readFileSync } from "node:fs";
import {
  failedRateOf, listStateOf, paymentsFileName, paymentsPageFromDb, paymentsSortOf,
  PAYMENT_STATES, PAYMENTS_FILE_COLUMNS, PAYMENTS_LIST_STATES, PAYMENTS_MONTHS_COLUMNS, PAYMENTS_SORTS,
} from "../src/lib/payments.ts";
import { addMonths, currentMonthIn } from "../src/lib/subscriptions.ts";
import { copy, paymentsCopy, subscriptionsCopy } from "../src/lib/copy.ts";
import { mockPaymentRows, mockPaymentsPage } from "../src/lib/data/mock-payments.ts";
import { mockSubscriptionsPage } from "../src/lib/data/mock-subscriptions.ts";

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
  const files = ["components/PaymentsReport.tsx", "app/(shell)/reports/payments/page.tsx"].map(src).join("\n");
  const usedT = [...new Set([...files.matchAll(/\bt\.([a-zA-Z_]+)\b/g)].map((m) => m[1]))].filter((k) => !["replace", "length"].includes(k));
  const usedS = [...new Set([...files.matchAll(/\bs\.([a-zA-Z_]+)\b/g)].map((m) => m[1]))].filter((k) => !["replace", "length"].includes(k));
  // keys named in the list's column table (words "t" or "s") and keys built from a prefix and a value
  const cols = [...src("components/PaymentsReport.tsx").matchAll(/col: "([a-z_]+)", words: "([ts])"/g)].map((m) => [m[1], m[2]]);
  const builtS = [...PAYMENT_STATES.map((k) => `pay_${k}`), ...["active", "paused", "failed", "canceled", "expired", "merged", "never_subscribed"].map((k) => `status_${k}`)];
  const missing = (lang) => [
    ...usedT.filter((k) => typeof paymentsCopy[lang][k] !== "string"),
    ...[...usedS, ...builtS].filter((k) => typeof subscriptionsCopy[lang][k] !== "string"),
    ...cols.filter(([k, w]) => typeof (w === "t" ? paymentsCopy : subscriptionsCopy)[lang][k] !== "string").map(([k]) => k),
  ];
  expect("C1 every word the page reads exists in en and nl (its own and Subscriptions' shared words)", [missing("en"), missing("nl"), cols.length],
    [[], [], 13], [["x"], ["x"], 0]);
  expect("C2 the page's words stay out of the shared catalog; the placeholder's words stay for the not-set-up state",
    ["payments" in copy.en, typeof copy.en.placeholders.intro_payments, typeof copy.nl.placeholders.fedBy_payments],
    [false, "string", "string"], [true, "undefined", "undefined"]);
  const forbidden = /payment status|failed payment|dunning|\bMRR\b|\bunpaid\b|overdue amount|cancelled|betaalstatus/i;
  expect("C3 no forbidden word in the page's words, the placeholder's or Flash's Payments hint (payment status, failed payment, dunning, MRR, unpaid, overdue amount, cancelled)",
    [...Object.values(paymentsCopy.en), ...Object.values(paymentsCopy.nl), copy.en.placeholders.intro_payments, copy.en.placeholders.fedBy_payments,
      copy.nl.placeholders.intro_payments, copy.nl.placeholders.fedBy_payments, copy.en.flash?.h_payments ?? "", copy.nl.flash?.h_payments ?? ""].filter((w) => forbidden.test(w)),
    [], ["x"]);
  expect("C4 every hint of a state names the state ({state}) in en and nl", [paymentsCopy.en.h_state.includes("{state}"), paymentsCopy.nl.h_state.includes("{state}")],
    [true, true], [false, false]);
}

// ---- L. The list's states and sort keys ---------------------------------------------------------------------------------------
expect("L1 the list's states: at_risk first (the default), the five payment states, all; Paused and Canceled are none of them",
  [PAYMENTS_LIST_STATES, listStateOf("paused"), listStateOf("canceled"), listStateOf("at_risk"), listStateOf(undefined)],
  [["at_risk", "in_retry", "charged_back", "awaiting_payment", "failed", "paid", "all"], null, null, "at_risk", null], [[], "paused", "canceled", null, "x"]);
expect("L2 the sort keys: amount_at_risk first (the default); a key outside the list is none",
  [PAYMENTS_SORTS, paymentsSortOf("monthly_amount"), paymentsSortOf("state_since")],
  [["amount_at_risk", "state_since", "subscription", "market", "payment_state"], null, "state_since"], [[], "monthly_amount", null]);
expect("L3 the Failed rate of a month's parts: a share of the base, null without one",
  [failedRateOf({ base: 200, movedToFailed: 3 }), failedRateOf({ base: 0, movedToFailed: 1 }), failedRateOf({ base: null, movedToFailed: 1 }), failedRateOf(null)],
  [0.015, null, null, null], [0, 0, 0, 0]);

// ---- F. Files ---------------------------------------------------------------------------------------------------------------
{
  const personal = /name|email|phone|address|street|postcode|url|link/i;
  expect("F1 the list's columns: ids, codes, times and amounts only, the contact's id and never its link",
    [PAYMENTS_FILE_COLUMNS.filter((c) => personal.test(c)), PAYMENTS_FILE_COLUMNS.includes("contact_id"), PAYMENTS_FILE_COLUMNS.length],
    [[], true, 14], [["x"], false, 0]);
  expect("F2 the months file's columns", [...PAYMENTS_MONTHS_COLUMNS], ["month", "rate_base", "rate_moved_to_failed"], []);
  expect("F3 the file's name", [paymentsFileName("records", { market: "GB", store: null, proposition: "hs1", interval: "monthly" }, "2026-11-25T0900"),
    paymentsFileName("months", { market: null, store: null, proposition: null, interval: null }, "2026-11-25T0900")],
  ["payments-records-gb-monthly-hs1-2026-11-25T0900.csv", "payments-months-all-2026-11-25T0900.csv"], []);
  const route = src("app/api/v1/reports/payments/file/route.ts");
  const api = src("app/api/v1/reports/payments/route.ts") + src("app/api/v1/reports/payments/rows/route.ts");
  expect("F4 every file and every API read of rows is recorded in the audit log before it is sent",
    [(route.match(/recordPaymentFile/g) ?? []).length,
      route.indexOf("recordPaymentFile(me, \"months\"") < route.indexOf("return csvFile(text, paymentsFileName(\"months\""),
      route.indexOf("recordPaymentFile(me, \"records\"") < route.indexOf("return csvFile(text, paymentsFileName(\"records\""),
      (api.match(/recordPaymentFile\(me, "rows"/g) ?? []).length],
    [2, true, true, 2], [0, false, false, 0]);
}

// ---- D. The database's document -------------------------------------------------------------------------------------------
{
  const q = { from: "2026-01-01", to: "2026-11-01", filter: { market: null, store: null, proposition: null, interval: null } };
  const doc = paymentsPageFromDb({
    set_up: true, history: true, take: { computed_at: "2026-11-25T08:00:00Z", business_date: "2026-11-25" }, time_zone: "Europe/Amsterdam",
    today: "2026-11-25", month: "2026-11-01", from: "2026-01-01", to: "2026-11-01",
    settings: { states: ["paid", "in_retry", "charged_back", "awaiting_payment", "failed"], fx: null, propositions: ["hs1"], history_months: 60 },
    filters: { markets: ["GB"], stores: [], propositions: ["hs1", "none"], intervals: ["monthly"] },
    tiles: { total: 10, by_state: [{ key: "paid", subscriptions: 6 }, { key: "in_retry", subscriptions: 2 }, { key: "charged_back", subscriptions: 1 },
      { key: "awaiting_payment", subscriptions: 1 }, { key: "failed", subscriptions: 0 }], overdue: 1,
      at_risk: { subscriptions: 4, amounts: [{ currency: "EUR", amount: "40.50", subscriptions: 4 }], eur: null },
      rates: { month: "2026-10-01", base: 200, moved_to_failed: 3 } },
    months: [{ month: "2026-10-01", complete: { base: 200, moved_to_failed: 3 } }, { month: "2026-11-01", complete: null }],
    rates: [{ market: "GB", month: "2026-10-01", base: 200, moved_to_failed: 3 }], store_starts: [], rates_start_month: "2026-06-01",
    cross: [{ state: "paid", instrument: "card", subscriptions: 6 }],
    list: { page: 1, page_size: 50, total: 1, state: "at_risk", sort: "amount_at_risk", descending: true, rows: [{ subscription_id: "u1", source_id: "s1",
      number: null, store: "gb", market: "GB", status: "active", payment_state: "in_retry", state_since: "2026-11-20T10:00:00Z", overdue: null,
      return_code: null, instrument: "card", currency: "EUR", amount_at_risk: 10.5, monthly_amount: 10.5, contact_id: "c1", contact_url: "https://x.invalid/c1" }] },
  }, q);
  expect("D1 the document in the API's words: the tiles, the amount as a number, the rate, the floor, the cross table and a row",
    [doc.tiles.total, doc.tiles.byState.map((b) => b.key), doc.tiles.atRisk.amounts[0].amount, failedRateOf(doc.tiles.rates), doc.ratesStartMonth,
      doc.months[1].complete, doc.cross.length, doc.list.rows[0].paymentState, doc.list.rows[0].overdue],
    [10, ["paid", "in_retry", "charged_back", "awaiting_payment", "failed"], 40.5, 0.015, "2026-06-01", null, 1, "in_retry", null], []);
  const off = paymentsPageFromDb({ set_up: false }, q);
  expect("D2 a tenant without a subscriptions connection: set up false and nothing more", [off.setUp, off.tiles, off.list, off.cross],
    [false, null, null, null], [true, {}, {}, []]);
}

// ---- M. The mock on any month -------------------------------------------------------------------------------------------------
{
  const realNow = Date.now;
  const me = { tenantId: "00000000-0000-7000-8000-000000000001", permissions: ["reports.view"], timeZone: "Europe/Amsterdam", locale: "en" };
  const out = [];
  for (const at of ["2026-11-25T10:00:00Z", "2027-01-03T08:00:00Z", "2026-12-31T22:30:00Z", "2028-03-01T12:00:00Z"]) {
    Date.now = () => Date.parse(at);
    const month = currentMonthIn(me.timeZone, new Date(Date.now()));
    const q = { market: null, store: null, proposition: null, interval: null, from: addMonths(month, -12), to: month, state: "at_risk", sort: "amount_at_risk", descending: true };
    const p = mockPaymentsPage(me, q);
    const t = p.tiles;
    const rows = (state) => mockPaymentRows(me, { ...q, state, page: 1, file: true });
    const atRisk = rows("at_risk").rows;
    const perCurrency = Object.fromEntries([...new Set(atRisk.map((r) => r.currency))].sort().map((c) =>
      [c, Math.round(atRisk.filter((r) => r.currency === c).reduce((n, r) => n + r.amountAtRisk, 0) * 100) / 100]));
    const s = mockSubscriptionsPage(me, { ...q, measure: "total", sort: "monthly_amount" });
    out.push([
      t.byState.reduce((n, b) => n + b.subscriptions, 0) === t.total && t.byState.map((b) => b.key).join() === PAYMENT_STATES.join(),
      t.overdue <= (t.byState.find((b) => b.key === "awaiting_payment")?.subscriptions ?? 0),
      JSON.stringify(Object.fromEntries(t.atRisk.amounts.map((a) => [a.currency, a.amount]))) === JSON.stringify(perCurrency) && t.atRisk.subscriptions === atRisk.length,
      t.byState.every((b) => rows(b.key).total === b.subscriptions) && rows("all").total === t.total && p.list.total === t.atRisk.subscriptions,
      p.cross.reduce((n, c) => n + c.subscriptions, 0) === t.total
        && t.byState.every((b) => p.cross.filter((c) => c.state === b.key).reduce((n, c) => n + c.subscriptions, 0) === b.subscriptions),
      JSON.stringify(t.rates) === JSON.stringify(s.tiles.rates ? { month: s.tiles.rates.month, base: s.tiles.rates.base, movedToFailed: s.tiles.rates.movedToFailed } : null)
        && p.rates.length === s.rates.length && p.months.length === s.months.length,
      rows("all").rows.every((r) => PAYMENT_STATES.includes(r.paymentState)) && rows("all").rows.every((r) => r.contactUrl === null),
      t.total > 0 && t.atRisk.subscriptions > 0,
    ]);
  }
  Date.now = realNow;
  const ok = [true, true, true, true, true, true, true, true];
  expect("M1 on four months: the states add up, overdue among Awaiting payment, Amount at risk = the at-risk rows per currency, list totals = tiles, the cross table sums, the Failed rate = Subscriptions', the five states alone, no link in a file row",
    out, Array(4).fill(ok), Array(4).fill([false, false, false, false, false, false, false, false]));
  const q0 = { market: null, store: null, proposition: null, interval: null, from: "2026-01-01", to: currentMonthIn(me.timeZone), state: "at_risk", sort: "amount_at_risk", descending: true };
  const inv = mockPaymentsPage({ ...me, tenantId: "00000000-0000-7000-8000-000000000002" }, q0);
  let agent = "ok";
  try { mockPaymentsPage({ ...me, permissions: ["workday.own"] }, q0); } catch (e) { agent = e.sqlState ?? String(e); }
  let badState = "ok";
  try { mockPaymentRows(me, { ...q0, state: "paused", page: 1 }); } catch (e) { badState = e.sqlState ?? String(e); }
  expect("M2 Invest is not set up (nothing more); an agent is refused (CMA06); a state outside the list is refused (CMA04)",
    [inv.setUp, inv.tiles, inv.list, agent, badState], [false, null, null, "CMA06", "CMA04"], [true, {}, {}, "ok", "ok"]);
}

const n = results.length;
const passed = results.filter(Boolean).length;
if (PROVOKE) {
  const ok = passed === 0;
  console.log(`\n${ok ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
  process.exit(ok ? 0 : 1);
}
console.log(`\n${passed === n ? `ALL ${n} PASS` : `${n - passed} of ${n} FAILED`}`);
process.exit(passed === n ? 0 : 1);
