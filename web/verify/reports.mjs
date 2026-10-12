/**
 * Verifier: the intake reports' logic (src/lib/reports.ts, B11), without a browser or a database.
 *
 *   node --experimental-strip-types verify/reports.mjs             every check must PASS
 *   node --experimental-strip-types verify/reports.mjs --provoke   every check must FAIL
 *
 * Covers the grouping (the four groups, G cycling, a group outside them refused), the 92-day bound,
 * percentile_cont and the summary figures as cma.speed_to_lead_summary computes them (business minutes
 * over called deals, shares over known outcomes, open not called), an agent who is not mapped shown as
 * Not mapped and never as an owner id, unknown markets and pipelines, the open deals in waiting order,
 * the not-connected states (telephony and commerce figures null, never 0, totals too), market order and
 * filter, the inline bars, the data-quality order with owners first and the muted rows, and the formats
 * in both languages.
 */
import {
  applyConnections, barShares, cellOf, filterMarket, fmtBusinessMinutes, fmtCount, fmtPct, groupDisplay, groupSpeedToLead,
  intakeMarkets, intakeTotals, isMuted, nextGroup, openNotCalled, orderChecks, parseGroup, percentileCont, rangeProblem,
  recordsOfType, speedFigures, summaryTotals,
} from "../src/lib/reports.ts";

const PROVOKE = process.argv.includes("--provoke");
const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(58)} got ${JSON.stringify(actual).slice(0, 70)}${pass ? "" : `, wanted ${JSON.stringify(want).slice(0, 70)}`}`);
}

// ---- grouping and range ------------------------------------------------------------------------
expect("the four groups parse, anything else is refused",
  ["day", "market", "agent", "pipeline", "owner", "", null, "Day"].map(parseGroup),
  ["day", "market", "agent", "pipeline", null, null, null, null],
  ["day", "market", "agent", "pipeline", "owner", null, null, "day"]);
expect("G cycles day, market, agent, pipeline and back",
  [nextGroup("day"), nextGroup("market"), nextGroup("agent"), nextGroup("pipeline")],
  ["market", "agent", "pipeline", "day"], ["market", "agent", "pipeline", "pipeline"]);
expect("92 days pass, 93 and a backwards range do not",
  [rangeProblem("2026-08-01", "2026-10-31"), rangeProblem("2026-08-01", "2026-11-01"), rangeProblem("2026-10-02", "2026-10-01"), rangeProblem("2026-10-01", "2026-10-01")],
  [null, "length", "order", null], [null, null, "order", null]);

// ---- speed to lead -----------------------------------------------------------------------------
// Fixture rows: invented ids; owner refs never appear in a row, the agent is a person id or null
const base = { connectionId: "c1", pipelineId: "p1", pipelineLabel: "Sales", marketSource: "record", isClosed: false, firstCallSourceId: null,
  firstCallLinked: null, firstAnyCallAt: null, firstAnyDirection: null, inboundFirst: false, firstConnectedAt: null, agentFrom: null,
  elapsedSeconds: null, targetSeconds: 3600, nextBusinessNoon: null, waitingBusinessSeconds: null, recordUrl: null };
let seq = 0;
const deal = (date, market, status, businessSeconds, withinTarget, beforeNextNoon, agentUserId, extra = {}) => ({
  ...base, dealId: `d${++seq}`, dealSourceId: String(1000 + seq), date, createdAt: `${date}T09:0${seq % 10}:00Z`, market, status,
  businessSeconds, withinTarget, beforeNextNoon, agentUserId, ...extra,
});
const rows = [
  deal("2026-10-05", "NL", "called", 420, true, true, "u-ana"),            // 7 business minutes
  deal("2026-10-05", "NL", "called", 900, true, true, "u-ana"),            // 15
  deal("2026-10-05", "GB", "called", 7200, false, true, null),             // 120, owner not mapped
  deal("2026-10-06", "GB", "not_called_open", null, null, null, null, { waitingBusinessSeconds: 1800 }),
  deal("2026-10-06", "unknown", "called", null, null, null, "u-bo"),      // no business hours: measures empty
  deal("2026-10-06", "NL", "not_called_closed", null, false, false, "u-bo", { pipelineId: null, pipelineLabel: null }),
  deal("2026-10-06", "NL", "not_called_open", null, false, null, "u-bo", { waitingBusinessSeconds: 5400 }),
  deal("2026-10-06", "unknown", "not_called_open", null, null, null, null),
];
expect("percentile_cont: median and 80th percentile interpolate",
  [percentileCont([420, 900, 7200], 0.5), percentileCont([420, 900, 7200], 0.8), percentileCont([10, 20, 30, 40], 0.5), percentileCont([], 0.5)],
  [900, 4680, 25, null], [900, 7200, 20, null]);
expect("period figures as the summary computes them", speedFigures(rows),
  { deals: 8, called: 4, medianBusinessMinutes: 15, p80BusinessMinutes: 78, withinTargetPct: 40, beforeNextNoonPct: 75, openNotCalled: 3 },
  { deals: 8, called: 4, medianBusinessMinutes: 7, p80BusinessMinutes: 78, withinTargetPct: 37.5, beforeNextNoonPct: 75, openNotCalled: 3 });
expect("nothing known yet: shares and minutes are empty, not 0",
  speedFigures([rows[3]]), { deals: 1, called: 0, medianBusinessMinutes: null, p80BusinessMinutes: null, withinTargetPct: null, beforeNextNoonPct: null, openNotCalled: 1 },
  { deals: 1, called: 0, medianBusinessMinutes: 0, p80BusinessMinutes: 0, withinTargetPct: 0, beforeNextNoonPct: 0, openNotCalled: 1 });

const names = { "u-ana": "Ana", "u-bo": "Bo" };
const byDay = groupSpeedToLead(rows, "day", (id) => names[id] ?? null);
expect("by day: one group per business date, in order",
  byDay.map((g) => [g.groupKey, g.deals, g.called, g.openNotCalled]), [["2026-10-05", 3, 3, 0], ["2026-10-06", 5, 1, 3]],
  [["2026-10-06", 5, 1, 3], ["2026-10-05", 3, 3, 0]]);
const byAgent = groupSpeedToLead(rows, "agent", (id) => names[id] ?? null);
expect("by agent: the person's id as key, not mapped under unknown",
  byAgent.map((g) => [g.groupKey, g.groupLabel, g.deals]), [["u-ana", "Ana", 2], ["u-bo", "Bo", 3], ["unknown", null, 3]],
  [["u-ana", "Ana", 2], ["u-bo", "Bo", 3], ["unknown", "unknown", 3]]);
expect("an agent who is not mapped shows as Not mapped",
  byAgent.map((g) => groupDisplay(g, "agent").kind), ["text", "text", "notMapped"], ["text", "text", "text"]);
const byMarket = groupSpeedToLead(rows, "market", () => null);
expect("by market: codes, and unknown said in words",
  byMarket.map((g) => [g.groupKey, groupDisplay(g, "market").kind]), [["GB", "text"], ["NL", "text"], ["unknown", "unknownMarket"]],
  [["GB", "text"], ["NL", "text"], ["unknown", "text"]]);
const byPipeline = groupSpeedToLead(rows, "pipeline", () => null);
expect("by pipeline: connection and pipeline as key, a missing label unknown",
  byPipeline.map((g) => [g.groupKey, groupDisplay(g, "pipeline").kind]), [["c1:", "unknownPipeline"], ["c1:p1", "text"]],
  [["c1:p1", "text"], ["c1:", "unknownPipeline"]]);
expect("totals add counts only", summaryTotals(byDay), { deals: 8, called: 4, openNotCalled: 3 }, { deals: 8, called: 4, openNotCalled: 0 });
expect("open deals not called: longest waiting first, no business time last",
  openNotCalled(rows).map((r) => r.dealSourceId), ["1007", "1004", "1008"], ["1004", "1007", "1008"]);
expect("no row carries an owner id or a personal field",
  [...new Set(rows.flatMap((r) => Object.keys(r)))].filter((k) => /^(email|phone|name|firstname|ownerRef|agentRef)$/i.test(k)), [], ["agentRef"]);

// ---- intake and the not-connected states -------------------------------------------------------
const counts = (date, market, n) => ({ date, market, formSubmissions: n, dealsCreated: n, dealsClosed: 0, ticketsCreated: 1, ticketsClosed: 0,
  callsIn: 0, callsOut: 0, taggedCalls: 0, newCustomers: 0, firstOrders: 0, repeatOrders: 0, renewals: 0 });
const raw = [counts("2026-10-05", "NL", 4), counts("2026-10-05", "unknown", 1), counts("2026-10-06", "GB", 2), counts("2026-10-06", "BE", 0)];
const none = applyConnections(raw, { telephony: false, commerce: false });
const both = applyConnections(raw, { telephony: true, commerce: true });
expect("without telephony and a shop their figures are null, never 0",
  [none[0].callsIn, none[0].taggedCalls, none[0].newCustomers, none[0].renewals, none[0].formSubmissions],
  [null, null, null, null, 4], [0, 0, 0, 0, 4]);
expect("connected sources keep their zeros",
  [both[0].callsIn, both[0].renewals], [0, 0], [null, null]);
const half = applyConnections(raw, { telephony: true, commerce: false });
expect("each source on its own: telephony counted, shop not connected",
  [half[0].callsOut, half[0].firstOrders], [0, null], [0, 0]);
expect("totals stay null for a source that is not connected",
  [intakeTotals(none, { telephony: false, commerce: false }).callsIn, intakeTotals(none, { telephony: false, commerce: false }).formSubmissions,
   intakeTotals(both, { telephony: true, commerce: true }).callsIn],
  [null, 7, 0], [0, 7, 0]);
expect("a missing figure says which source is not there",
  [cellOf("callsIn", null).kind, cellOf("renewals", null).kind, cellOf("callsIn", 0).kind],
  ["noTelephony", "noShop", "count"], ["count", "count", "count"]);
expect("markets in order, unknown last", intakeMarkets(raw), ["BE", "GB", "NL", "unknown"], ["BE", "GB", "NL"]);
expect("the market filter keeps one market, none keeps all",
  [filterMarket(both, "GB").length, filterMarket(both, "").length], [1, 4], [4, 4]);
expect("bars against the busiest row (leads, deals and tickets)",
  barShares(both).map((x) => Math.round(x * 100)), [100, 33, 56, 11], [100, 25, 50, 0]);
expect("records of a type from crm_records_per_day",
  recordsOfType([{ recordType: "deal", records: 3 }, { recordType: "ticket", records: 2 }, { recordType: "deal", records: 4 }], "deal"), 7, 9);

// ---- data quality ------------------------------------------------------------------------------
const checks = [
  { key: "deal_without_contact", description: "", total: 0 },
  { key: "market_not_in_catalog", description: "", total: 3 },
  { key: "owner_without_person", description: "", total: 2 },
  { key: "writeback_parked", description: "", total: null },
];
expect("owners without a person first, the rest in the database's order",
  orderChecks(checks).map((c) => c.key), ["owner_without_person", "deal_without_contact", "market_not_in_catalog", "writeback_parked"],
  ["deal_without_contact", "market_not_in_catalog", "owner_without_person", "writeback_parked"]);
expect("zero and not-available rows are muted, counts are not",
  checks.map(isMuted), [true, false, false, true], [false, false, false, false]);

// ---- formats -----------------------------------------------------------------------------------
expect("business minutes: decimals under an hour, hours from an hour, a dash for none",
  [fmtBusinessMinutes(7.5, "en"), fmtBusinessMinutes(7.5, "nl"), fmtBusinessMinutes(74.8, "en"), fmtBusinessMinutes(null, "en")],
  ["7.5 min", "7,5 min", "1h 15m", "–"], ["7.5 min", "7.5 min", "74.8 min", "0"]);
expect("percentages whole, small shares not zero, a dash for none",
  [fmtPct(40, "en"), fmtPct(66.7, "nl"), fmtPct(0.3, "en"), fmtPct(0, "en"), fmtPct(null, "en")],
  ["40%", "67%", "< 1%", "0%", "–"], ["40%", "66,7%", "0%", "0%", "0%"]);
expect("counts with the locale's grouping", [fmtCount(1234, "en"), fmtCount(1234, "nl")], ["1,234", "1.234"], ["1234", "1234"]);

const passed = results.filter(Boolean).length;
const n = results.length;
if (PROVOKE) {
  const ok = passed === 0;
  console.log(`\n${ok ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
  process.exit(ok ? 0 : 1);
} else {
  const ok = passed === n;
  console.log(`\n${ok ? `ALL ${n} PASS` : `${n - passed} of ${n} FAILED`}`);
  process.exit(ok ? 0 : 1);
}
