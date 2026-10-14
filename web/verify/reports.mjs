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
 * in both languages. Since addition 0008i (brief B15) also Inbound: the four groups and G, the calls as
 * cma.inbound_calls_of classifies them (outbound, deleted and uncounted out, waiting and a lost call, a
 * missing reason as unknown, a new code with the defaults), the figures as 61 proves them in the database
 * (the service level with and without an excluded reason and a call at exactly N seconds, average and
 * 80th percentile, the total over every call), hours and dates across the DST change of 25 October 2026
 * in each line's zone, a line without a market in the tenant's zone, the unanswered share, the reason
 * columns labelled from the catalog in the neutral series (never a red), the stacked bars, the group
 * labels, the time-to-answer format, the hint values, and no hash, number or name in an answer.
 */
import {
  ANSWERED_CLASS, applyConnections, barShares, cellOf, fillHint, filterMarket, fmtAnswerSeconds, fmtBusinessMinutes, fmtCount, fmtPct, groupDisplay,
  groupInbound, groupSpeedToLead, inboundBar, inboundCalls, inboundFigures, inboundGroupDisplay, intakeMarkets, intakeTotals, isMuted, missedReasonOf,
  nextGroup, nextInboundGroup, openNotCalled, orderChecks, parseGroup, parseInboundGroup, percentileCont, personalDataIn, rangeProblem, REASON_SERIES,
  reasonColumns, recordsOfType, speedFigures, summaryTotals, unansweredPct, WAITING_CLASS,
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

// ---- inbound service (addition 0008i) -----------------------------------------------------------
// The calls of 61 block B (invented ids, no numbers): tenant zone Europe/Helsinki, lines in NL and GB
// and one without a market; short_abandoned out of the service level by the catalog
expect("the four inbound groups parse, anything else is refused",
  ["day", "market", "line", "hour", "agent", "", null].map(parseInboundGroup),
  ["day", "market", "line", "hour", null, null, null], ["day", "market", "line", "hour", "agent", null, null]);
expect("G cycles day, market, line, hour and back",
  [nextInboundGroup("day"), nextInboundGroup("market"), nextInboundGroup("line"), nextInboundGroup("hour")],
  ["market", "line", "hour", "day"], ["market", "line", "hour", "hour"]);
const catalog = [
  { sourceSystem: "tel", code: "short_abandoned", label: "Hung up early", countsInServiceLevel: false, needsCallback: true },
  { sourceSystem: "tel", code: "out_of_opening_hours", label: "Outside hours", countsInServiceLevel: false, needsCallback: false },
];
expect("a reason from the catalog, a new code with the defaults",
  [missedReasonOf("tel", "short_abandoned", catalog), missedReasonOf("tel", "brand_new_code", catalog)].map((r) => [r.label, r.countsInServiceLevel, r.needsCallback]),
  [["Hung up early", false, true], ["brand_new_code", true, true]], [["Hung up early", true, true], ["brand_new_code", false, false]]);
const lines = [
  { connectionId: "c", lineRef: "nl", name: "NL line", market: "NL", zone: "Europe/Amsterdam", isCounted: true },
  { connectionId: "c", lineRef: "gb", name: "GB line", market: "GB", zone: "Europe/London", isCounted: true },
  { connectionId: "c", lineRef: "none", name: "Line without market", market: null, zone: null, isCounted: true },
  { connectionId: "c", lineRef: "off", name: "Another business line", market: "NL", zone: "Europe/Amsterdam", isCounted: false },
];
const D = Date.parse("2026-09-15T10:00:00Z");
const at = (ms) => new Date(ms).toISOString();
let cseq = 0;
const tcall = (start, answerAfter, endAfter, reason, line, extra = {}) => ({
  sourceId: `s-${++cseq}`, connectionId: "c", sourceSystem: "tel", direction: "inbound", startedAt: at(start),
  answeredAt: answerAfter === null ? null : at(start + answerAfter * 1000), endedAt: endAfter === null ? null : at(start + endAfter * 1000),
  missedReason: reason, lineRef: line, ...extra,
});
const NOW = Date.parse("2026-10-14T12:00:00Z");
const sept15 = [
  tcall(D, 10, 100, null, "nl"), tcall(D + 60e3, 20, 100, null, "nl"), tcall(D + 120e3, 21, 100, null, "nl"),
  tcall(D + 180e3, null, 40, "no_available_agent", "nl"), tcall(D + 240e3, null, 5, "short_abandoned", "nl"), tcall(D + 300e3, null, 30, null, "nl"),
  tcall(D + 360e3, 5, 60, null, "nl", { direction: "outbound" }), tcall(D + 420e3, null, 30, "no_available_agent", "nl", { deleted: true }),
  tcall(D + 480e3, null, 30, "no_available_agent", "off"),
];
const sept17 = [tcall(D + 2 * 86400e3, null, 30, "brand_new_code", "gb"), tcall(D + 2 * 86400e3 + 60e3, null, 30, null, "gb"), tcall(D + 2 * 86400e3 + 120e3, null, 30, "", "gb")];
const dst = [
  tcall(Date.parse("2026-10-24T23:30:00Z"), 8, 60, null, "nl"), tcall(Date.parse("2026-10-25T00:30:00Z"), 8, 60, null, "nl"),
  tcall(Date.parse("2026-10-25T01:30:00Z"), 8, 60, null, "nl"), tcall(Date.parse("2026-10-25T00:30:00Z"), 8, 60, null, "gb"),
  tcall(Date.parse("2026-10-25T01:30:00Z"), 8, 60, null, "gb"),
];
const noMarket = [tcall(Date.parse("2026-10-21T21:30:00Z"), null, 30, "no_available_agent", "none")];
const waiting = [tcall(NOW - 5 * 60e3, null, null, null, "nl"), tcall(NOW - 40 * 60e3, null, null, null, "nl")];
const classify = (calls, cat = catalog) => inboundCalls(calls, lines, cat, "Europe/Helsinki", 30, NOW);
const all = classify([...sept15, ...sept17, ...dst, ...noMarket, ...waiting]);
expect("outbound, deleted and uncounted calls are not offered; missing and empty reasons are unknown",
  [all.length, classify(sept17).map((c) => c.reasonCode)],
  [17, ["brand_new_code", "unknown", "unknown"]], [20, ["brand_new_code", null, ""]]);
expect("waiting: a call of 5 minutes; the lost one of 40 minutes is unanswered as unknown",
  classify(waiting).map((c) => [c.isWaiting, c.reasonCode]), [[true, null], [false, "unknown"]], [[true, null], [true, null]]);
const fig = (f) => `${f.offered}/${f.answered}/${f.unanswered}/${f.waiting} within ${f.answeredWithinTarget} of ${f.serviceLevelBase} = ${f.serviceLevelPct}; avg ${f.avgAnswerSeconds} p80 ${f.p80AnswerSeconds}`;
expect("the service level with short_abandoned out and a call at exactly 20 s, as 61 B1 and B2",
  fig(inboundFigures(classify(sept15), 20)), "6/3/3/0 within 2 of 5 = 40; avg 17 p80 20.6", "6/3/3/0 within 1 of 6 = 16.7; avg 17 p80 20.6");
expect("and with short_abandoned counted: 2 of 6",
  fig(inboundFigures(classify(sept15, catalog.map((r) => (r.code === "short_abandoned" ? { ...r, countsInServiceLevel: true } : r))), 20)),
  "6/3/3/0 within 2 of 6 = 33.3; avg 17 p80 20.6", "6/3/3/0 within 2 of 5 = 40; avg 17 p80 20.6");
const inByMarket = groupInbound(all, "2026-09-15", "2026-09-17", "market", 20);
expect("the total is computed over every call, as 61 B2's total row",
  [inByMarket.rows.map((r) => `${r.groupKey}:${r.serviceLevelPct}`), fig(inByMarket.total), inByMarket.total.unansweredByReason],
  [["GB:0", "NL:40"], "9/3/6/0 within 2 of 8 = 25; avg 17 p80 20.6", { no_available_agent: 1, short_abandoned: 1, unknown: 3, brand_new_code: 1 }],
  [["GB:0", "NL:40"], "9/3/6/0 within 2 of 8 = 20; avg 8.5 p80 20.6", {}]);
expect("25 October by hour, each call in its line's zone, as 61 B3",
  [groupInbound(all, "2026-10-25", "2026-10-25", "hour", 20).rows.map((r) => `${r.groupKey}=${r.offered}`),
    groupInbound(all, "2026-10-24", "2026-10-25", "day", 20).rows.map((r) => `${r.groupKey}=${r.offered}`)],
  [["01=3", "02=2"], ["2026-10-25=5"]], [["00=2", "01=2", "02=1"], ["2026-10-24=1", "2026-10-25=4"]]);
expect("a line without a market: the tenant's zone, market unknown, the line's name, as 61 B4",
  ["day", "hour", "market", "line"].map((g) => groupInbound(all, "2026-10-21", "2026-10-22", g, 20).rows.map((r) => `${r.groupLabel}=${r.offered}`)[0]),
  ["2026-10-22=1", "00=1", "unknown=1", "Line without market=1"], ["2026-10-21=1", "23=1", "NL=1", "NL line=1"]);
expect("unanswered as a share of the calls with an outcome, a waiting call left out",
  [unansweredPct(inboundFigures(classify(sept15), 20)), unansweredPct(inboundFigures(classify(waiting), 20)), unansweredPct({ answered: 0, unanswered: 0 })],
  [50, 100, null], [50, 50, 0]);
const cols = reasonColumns([inByMarket.total], [{ sourceSystem: "tel", code: "unknown", label: "Unknown", countsInServiceLevel: true, needsCallback: true }, ...catalog], "Unknown");
expect("one column per reason that occurs, most frequent first, labelled from the catalog",
  cols.map((c) => `${c.code}:${c.label}:${c.total}:${c.countsInServiceLevel}`),
  ["unknown:Unknown:3:true", "brand_new_code:brand_new_code:1:true", "no_available_agent:no_available_agent:1:true", "short_abandoned:Hung up early:1:false"],
  ["brand_new_code:brand_new_code:1:true", "no_available_agent:no_available_agent:1:true", "short_abandoned:short_abandoned:1:true", "unknown:unknown:3:true"]);
const classes = [...REASON_SERIES, ANSWERED_CLASS, WAITING_CLASS];
expect("the reasons in the neutral series, in its order, never a red, rose or amber",
  [cols.map((c) => c.className), classes.filter((c) => /error|rose|warning|red/.test(c))],
  [["bg-p4a-deepblue", "bg-p4a-lightblue", "bg-p4a-inkt", "bg-p4a-grey"], []], [["bg-p4a-error", "bg-p4a-rose", "bg-p4a-warning", "bg-p4a-grey"], ["bg-p4a-error"]]);
const bar = inboundBar(inByMarket.total, cols);
expect("a row's bar: answered first, then the reasons in column order, shares adding up to 1",
  [bar.map((b) => b.key), Math.round(bar.reduce((a, b) => a + b.share, 0) * 1000) / 1000],
  [["answered", "unknown", "brand_new_code", "no_available_agent", "short_abandoned"], 1], [["unknown", "answered"], 0.5]);
expect("group labels: a date, an unknown market, a line without a name, an hour",
  [inboundGroupDisplay({ groupKey: "2026-10-25", groupLabel: "2026-10-25" }, "day"), inboundGroupDisplay({ groupKey: "unknown", groupLabel: "unknown" }, "market"),
    inboundGroupDisplay({ groupKey: "c:", groupLabel: null }, "line"), inboundGroupDisplay({ groupKey: "09", groupLabel: "09" }, "hour")],
  [{ kind: "date", date: "2026-10-25" }, { kind: "unknownMarket" }, { kind: "unknownLine" }, { kind: "hour", hour: "09" }],
  [{ kind: "date", date: "2026-10-25" }, { kind: "text", text: "unknown" }, { kind: "text", text: "c:" }, { kind: "text", text: "09" }]);
expect("time to answer: seconds under a minute, minutes and seconds from a minute, a dash for none",
  [fmtAnswerSeconds(17, "en"), fmtAnswerSeconds(20.6, "nl"), fmtAnswerSeconds(65, "en"), fmtAnswerSeconds(null, "en")],
  ["17 s", "21 s", "1m 05s", "–"], ["17.0 s", "20,6 s", "65 s", "0 s"]);
expect("hint values from the tenant's settings, a dash when unknown",
  fillHint("{seconds} s, {days} days, {minutes} min, {target}", { hours: "", seconds: 20, days: 3, minutes: null }, "en"),
  "20 s, 3 days, – min, –", "{seconds} s, {days} days, {minutes} min, {target}");
const clean = { from: "2026-09-15", to: "2026-09-17", group: "line", telephony: true, serviceLevelSeconds: 20, waitingMaxMinutes: 30, reasons: catalog,
  rows: groupInbound(all, "2026-09-15", "2026-09-17", "line", 20).rows, total: inByMarket.total,
  callbacks: [{ callId: "x", sourceId: "s-1", lineRef: "nl", lineName: "NL line", market: "NL", reasonLabel: "Unknown", recordUrl: null }] };
expect("no hash, number or name in an inbound answer; each kind found when there",
  [personalDataIn(clean), personalDataIn({ a: "a1".repeat(32), b: "+31 20 000 0001", c: { counterpartHash: null, displayName: "x", lineName: "ok" } })],
  [[], ["$.a", "$.b", "$.c.counterpartHash", "$.c.displayName"]], [["$.rows"], []]);

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
