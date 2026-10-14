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
 * labels, the time-to-answer format, the hint values, and no hash, number or name in an answer. Since
 * addition 0008j (brief B16) also Calls and Calls per agent, on 63's own dataset so the figures are the
 * ones 63 proves in the database: the four groups and G, the filters as the database checks them, talk
 * time without ringing and a call at exactly the threshold, an uncounted line and a deleted call left
 * out, the overview per market with its computed total and the previous period across the DST change,
 * the previous period like for like (a period that reaches today against the same elapsed dates, the
 * last of them up to the time of day in each call's zone; a period that ended against the whole previous
 * one), days and ISO weeks in each line's zone, the untagged rule, tag use by market, the per-person rows and
 * the not-linked row, tags per person (counted only), the filters narrowing every figure alike; then the
 * screens: the deltas, the colours (series order, never a red), the top twelve tags and Other, the groups
 * by tags, the chart's axis, the per-agent bars and split, the formats, and no hash, number, call id or
 * telephony user id in an answer.
 */
import {
  ANSWERED_CLASS, applyConnections, barShares, cellOf, fillHint, filterMarket, fmtAnswerSeconds, fmtBusinessMinutes, fmtCount, fmtPct, groupDisplay,
  groupInbound, groupSpeedToLead, inboundBar, inboundCalls, inboundFigures, inboundGroupDisplay, intakeMarkets, intakeTotals, isMuted, missedReasonOf,
  nextGroup, nextInboundGroup, openNotCalled, orderChecks, parseGroup, parseInboundGroup, percentileCont, personalDataIn, rangeProblem, REASON_SERIES,
  reasonColumns, recordsOfType, speedFigures, summaryTotals, unansweredPct, WAITING_CLASS,
  barShare, callRecords, callsDelta, callsFigures, callsPerPerson, callsPerPersonTags, callsTagUse, chartGroups, columnMaxima, CONVERSATION_CLASS, countAxis, filterQuery,
  fmtShare, fmtTalk, groupCalls, INBOUND_CLASS, nextCallsGroup, OTHER_TAGS_CLASS, OUTBOUND_CLASS, parseCallsFilter, parseCallsGroup, PER_AGENT_BAR_CLASS,
  personSplit, previousCalls, previousPeriod, TAG_CLASS, TAG_NOT_COUNTED_CLASS, tagTable, topTags, UNTAGGED_CLASS, untaggedPct,
} from "../src/lib/reports.ts";
import { dateKeyInZone } from "../src/lib/time.ts";

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
expect("the reasons in the style's series without Leaf Green, Neutral, Denim last; no red, amber or green",
  [REASON_SERIES, REASON_SERIES.filter((c) => /error|warning|red|green|success/.test(c)), classes.filter((c) => /error|warning|red/.test(c))],
  [["bg-p4a-deepblue", "bg-p4a-lightblue", "bg-p4a-rose", "bg-p4a-inkt", "bg-p4a-muted", "bg-p4a-denim"], [], []],
  [["bg-p4a-deepblue", "bg-p4a-lightblue", "bg-p4a-green", "bg-p4a-denim", "bg-p4a-rose", "bg-p4a-inkt"], ["bg-p4a-green"], ["bg-p4a-error"]]);
// Pulse4all's six seeded reasons (02) in the seed's order; the rows below add a code without a catalog row
const seedCatalog = ["out_of_opening_hours", "short_abandoned", "abandoned_in_ivr", "no_available_agent", "agents_did_not_answer", "unknown"]
  .map((code) => ({ sourceSystem: "aircall", code, label: code, countsInServiceLevel: true, needsCallback: true }));
const colourOf = (rows) => reasonColumns(rows, seedCatalog, "Unknown").map((c) => `${c.code}:${c.className}`).sort();
expect("a colour per code: the catalog by code takes the series, a code without a row follows, cycling",
  [colourOf([{ unansweredByReason: { unknown: 7, short_abandoned: 6, out_of_opening_hours: 5, no_available_agent: 4, agents_did_not_answer: 3, abandoned_in_ivr: 2, brand_new_code: 1 } }]),
    cols.map((c) => `${c.code}:${c.className}`)],
  [["abandoned_in_ivr:bg-p4a-deepblue", "agents_did_not_answer:bg-p4a-lightblue", "brand_new_code:bg-p4a-deepblue", "no_available_agent:bg-p4a-rose",
    "out_of_opening_hours:bg-p4a-inkt", "short_abandoned:bg-p4a-muted", "unknown:bg-p4a-denim"],
    ["unknown:bg-p4a-rose", "brand_new_code:bg-p4a-inkt", "no_available_agent:bg-p4a-muted", "short_abandoned:bg-p4a-lightblue"]],
  [["abandoned_in_ivr:bg-p4a-denim", "agents_did_not_answer:bg-p4a-muted", "brand_new_code:bg-p4a-deepblue", "no_available_agent:bg-p4a-inkt",
    "out_of_opening_hours:bg-p4a-rose", "short_abandoned:bg-p4a-lightblue", "unknown:bg-p4a-deepblue"],
    ["unknown:bg-p4a-deepblue", "brand_new_code:bg-p4a-lightblue", "no_available_agent:bg-p4a-rose", "short_abandoned:bg-p4a-inkt"]]);
const weekOne = reasonColumns([{ unansweredByReason: { out_of_opening_hours: 5, agents_did_not_answer: 2, brand_new_code: 1 } }], seedCatalog, "Unknown");
const weekTwo = reasonColumns([{ unansweredByReason: { agents_did_not_answer: 6, short_abandoned: 3, brand_new_code: 2, out_of_opening_hours: 1 } }], seedCatalog, "Unknown");
expect("the same code keeps its colour when the period's totals change order",
  [weekOne.map((c) => c.code), weekTwo.map((c) => c.code),
    weekOne.every((c) => weekTwo.find((d) => d.code === c.code)?.className === c.className)],
  [["out_of_opening_hours", "agents_did_not_answer", "brand_new_code"], ["agents_did_not_answer", "short_abandoned", "brand_new_code", "out_of_opening_hours"], true],
  [["out_of_opening_hours", "agents_did_not_answer", "brand_new_code"], ["agents_did_not_answer", "short_abandoned", "brand_new_code", "out_of_opening_hours"], false]);
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

// ---- Calls overview and calls per agent (addition 0008j, brief B16) -------------------------------
// The dataset of 63's tenant one, so the figures below are the ones 63 proves in the database: lines NL,
// a second NL line, GB and an NL line that does not count; telephony users 1 (Anna) and 2 (Bram) linked,
// 3 and 4 not; Sale and Info count, Test does not; 26 October to 1 November 2026 and the previous period
// 19 to 25 October across the DST change, in Europe/Amsterdam
expect("the four calls groups parse, anything else is refused",
  ["day", "week", "market", "line", "hour", "", null].map(parseCallsGroup),
  ["day", "week", "market", "line", null, null, null], ["day", "week", "market", "line", "hour", null, null]);
expect("G cycles day, week, market, line and back",
  [nextCallsGroup("day"), nextCallsGroup("week"), nextCallsGroup("market"), nextCallsGroup("line")],
  ["week", "market", "line", "day"], ["week", "market", "line", "line"]);
const CONN = "00000000-0000-7000-8000-0000000000c1";
expect("the filters as cma.calls_filters_check takes them: a code or unknown, a connection:line key, empty for all",
  [parseCallsFilter("NL", `${CONN}:line-nl`), parseCallsFilter("unknown", ""), parseCallsFilter("", undefined),
    parseCallsFilter("nl", null).problem, parseCallsFilter("Netherlands", null).problem, parseCallsFilter(null, "line-nl").problem, filterQuery({ market: "GB", line: null })],
  [{ filter: { market: "NL", line: `${CONN}:line-nl` }, problem: null }, { filter: { market: "unknown", line: null }, problem: null },
    { filter: { market: null, line: null }, problem: null }, "market", "market", "line", { market: "GB" }],
  [{ filter: { market: "NL", line: null }, problem: null }, { filter: { market: null, line: null }, problem: "market" },
    { filter: { market: "", line: "" }, problem: null }, null, null, null, { market: "GB", line: null }]);
const callLines = [
  { connectionId: CONN, lineRef: "line-nl", name: "Verify NL line", market: "NL", zone: "Europe/Amsterdam", isCounted: true },
  { connectionId: CONN, lineRef: "line-nl2", name: "Verify NL line two", market: "NL", zone: "Europe/Amsterdam", isCounted: true },
  { connectionId: CONN, lineRef: "line-gb", name: "Verify GB line", market: "GB", zone: "Europe/London", isCounted: true },
  { connectionId: CONN, lineRef: "line-off", name: "Verify line not counted", market: "NL", zone: "Europe/Amsterdam", isCounted: false },
];
const callTags = [
  { connectionId: CONN, tagRef: "tg-sale", name: "Sale", isCounted: true }, { connectionId: CONN, tagRef: "tg-info", name: "Info", isCounted: true },
  { connectionId: CONN, tagRef: "tg-test", name: "Test", isCounted: false },
];
const V = Date.parse("2026-10-26T00:00:00Z");
const H = 3600e3;
const ccall = (src, direction, start, answer, end, line, user, tags = [], extra = {}) => ({
  sourceId: src, connectionId: CONN, sourceSystem: "verifytel", direction, startedAt: at(start),
  answeredAt: answer === null ? null : at(start + answer * 1000), endedAt: at(start + end * 1000), missedReason: null, lineRef: line,
  userRef: user, tagRefs: tags, ...extra,
});
const calls63 = [
  ccall("c0", "inbound", V - 0.5 * H, 6, 66, "line-nl", "tel-user-1"),
  ccall("o1", "outbound", V + 8 * H, 15, 25, "line-nl", "tel-user-1", ["tg-sale"]),
  ccall("o2", "outbound", V + 8 * H + 600e3, 20, 29, "line-nl", "tel-user-1", ["tg-sale"]),
  ccall("i1", "inbound", V + 39 * H, 12, 312, "line-nl", "tel-user-1", ["tg-test"]),
  ccall("o3", "outbound", V + 33 * H, null, 30, "line-nl", "tel-user-2"),
  ccall("i2", "inbound", V + 58 * H, 8, 68, "line-gb", "tel-user-2"),
  ccall("o4", "outbound", V + 64.5 * H, 5, 125, "line-gb", "tel-user-2", ["tg-info", "tg-test"]),
  ccall("i3", "inbound", V + 80 * H, null, 30, "line-nl", null),
  ccall("i5", "inbound", V + 82 * H, 4, 34, "line-nl2", "tel-user-2", ["tg-sale", "tg-info"]),
  ccall("i4", "inbound", V + 108 * H, 5, 95, "line-nl", "tel-user-3", ["tg-sale"]),
  ccall("o5", "outbound", V + 167.5 * H, 3, 43, "line-gb", "tel-user-4"),
  ccall("o6", "outbound", V + 130 * H, null, 25, "line-gb", "tel-user-4"),
  ccall("x1", "inbound", V + 167.5 * H, 5, 65, "line-nl", "tel-user-1"),
  ccall("p1", "inbound", Date.parse("2026-10-25T00:30:00Z"), 5, 65, "line-nl", "tel-user-1"),
  ccall("p2", "inbound", Date.parse("2026-10-25T01:30:00Z"), 5, 35, "line-nl", "tel-user-1"),
  ccall("p3", "outbound", Date.parse("2026-10-25T22:30:00Z"), 4, 24, "line-nl", "tel-user-2"),
  ccall("p6", "inbound", Date.parse("2026-10-25T23:30:00Z"), 5, 15, "line-gb", "tel-user-2"),
  ccall("p4", "outbound", Date.parse("2026-10-18T22:30:00Z"), null, 20, "line-nl", "tel-user-2"),
  ccall("p5", "inbound", Date.parse("2026-10-18T21:30:00Z"), 5, 65, "line-nl", "tel-user-1"),
  ccall("q1", "inbound", Date.parse("2026-10-21T12:00:00Z"), 5, 105, "line-nl", null),
  ccall("q2", "inbound", Date.parse("2026-10-21T12:00:01Z"), 5, 205, "line-nl", null),
  ccall("q3", "inbound", Date.parse("2026-10-21T11:30:00Z"), 5, 405, "line-gb", null),
  ccall("q4", "inbound", Date.parse("2026-10-21T12:30:00Z"), 5, 805, "line-gb", null),
  ccall("q5", "inbound", Date.parse("2026-10-20T21:00:00Z"), 5, 1605, "line-nl", null),
  ccall("d1", "inbound", V + 37 * H, 5, 65, "line-nl", "tel-user-1", ["tg-sale"], { deleted: true }),
  ccall("off2", "outbound", V + 35 * H, 5, 55, "line-off", "tel-user-1"),
];
const records = (min = 10, filter) => callRecords(calls63, callLines, "Europe/Amsterdam", min, filter);
const people = { "tel-user-1": { userId: "u-anna", name: "Anna Verify" }, "tel-user-2": { userId: "u-bram", name: "Bram Verify" } };
const personOf = (system, ref) => (system === "verifytel" && ref ? people[ref] ?? null : null);
const figs = (f) => `${f.calls}/${f.inbound}/${f.outbound} ${f.answeredInbound}/${f.connectedOutbound} ${f.connectedPct} ${f.conversations} ${f.talkSeconds} ${f.talkAvgSeconds} out ${f.outboundTalkSeconds} ${f.outboundTalkAvgSeconds} ${f.untaggedConversations}`;
const week = groupCalls(records(), "2026-10-26", "2026-11-01", "market");
expect("talk time from the answer to the end, no ringing; a call at exactly the threshold connected, as 63 B1",
  [week.total.talkSeconds, records().find((c) => c.talkSeconds === 300)?.isConversation,
    [10, 9, 11].map((m) => groupCalls(records(m), "2026-10-26", "2026-11-01", "day").total.connectedOutbound)],
  [710, true, [3, 4, 2]], [768, true, [3, 3, 3]]);
expect("a line that does not count and a deleted call are never counted, as 63 B2 and B12",
  [records().some((c) => c.lineKey === `${CONN}:line-off`), records().length, groupCalls(records(10, { market: null, line: `${CONN}:line-off` }), "2026-10-26", "2026-11-01", "day").total.calls],
  [false, 24, 0], [true, 26, 1]);
// the previous period's figures measured at an instant, as cma.calls_overview_of picks them (today in Amsterdam)
const WEEK63 = { from: "2026-10-26", to: "2026-11-01" };
const prevAt = (now, filter) => callsFigures(previousCalls(records(10, filter), previousPeriod(WEEK63, dateKeyInZone(now, "Europe/Amsterdam")), now));
expect("the overview per market, the computed total and the previous period measured after it, as 63 B12",
  [...week.rows.map((r) => `${r.groupKey}:${figs(r)}`), `current:${figs(week.total)}`, `previous:${figs(prevAt("2026-11-02T09:00:00Z"))}`],
  ["GB:4/1/3 1/2 66.7 3 220 73.3 out 160 80 2", "NL:8/5/3 4/1 33.3 5 490 98 out 10 10 1", "current:12/6/6 5/3 50 8 710 88.8 out 170 56.7 3",
    "previous:10/8/2 8/1 50 9 3220 357.8 out 20 20 9"],
  ["GB:4/1/3 1/2 66.7 3 220 73.3 out 160 80 2", "NL:8/5/3 4/1 33.3 5 490 98 out 10 10 1", "current:12/6/6 5/3 50 8 710 88.75 out 170 56.7 3",
    "previous:5/3/2 3/1 50 4 120 30 out 20 20 4"]);
expect("a period that ended: the whole previous equal period, across the DST change, a day and a month",
  [previousPeriod(WEEK63, "2026-11-02"), previousPeriod({ from: "2026-10-14", to: "2026-10-14" }, "2026-10-15"), previousPeriod({ from: "2026-10-01", to: "2026-10-31" }, "2027-01-01")],
  [{ from: "2026-10-19", to: "2026-10-25", partial: false }, { from: "2026-10-13", to: "2026-10-13", partial: false }, { from: "2026-08-31", to: "2026-09-30", partial: false }],
  [{ from: "2026-10-19", to: "2026-10-26", partial: false }, { from: "2026-10-14", to: "2026-10-14", partial: false }, { from: "2026-09-01", to: "2026-09-30", partial: false }]);
expect("a period that reaches today: the same elapsed dates, cut; from its first day; before it starts nothing",
  [previousPeriod(WEEK63, "2026-10-28"), previousPeriod(WEEK63, "2026-11-01"), previousPeriod(WEEK63, "2026-10-26"), previousPeriod(WEEK63, "2026-10-25"),
    previousPeriod({ from: "2026-10-01", to: "2026-10-31" }, "2026-10-14")],
  [{ from: "2026-10-19", to: "2026-10-21", partial: true }, { from: "2026-10-19", to: "2026-10-25", partial: true }, { from: "2026-10-19", to: "2026-10-19", partial: true },
    { from: "2026-10-19", to: "2026-10-18", partial: true }, { from: "2026-08-31", to: "2026-09-13", partial: true }],
  [{ from: "2026-10-19", to: "2026-10-25", partial: false }, { from: "2026-10-19", to: "2026-10-25", partial: true }, { from: "2026-10-19", to: "2026-10-25", partial: false },
    { from: "2026-10-19", to: "2026-10-25", partial: false }, { from: "2026-08-31", to: "2026-09-30", partial: false }]);
expect("a period that reaches today compares with the same elapsed dates, as 63 B13",
  ["2026-10-28T22:59:00Z", "2026-10-26T10:00:00Z", "2026-10-25T12:00:00Z"].map((now) => `${prevAt(now).calls} calls ${prevAt(now).talkSeconds}`),
  ["6 calls 3100", "1 calls 0", "0 calls 0"], ["10 calls 3220", "10 calls 3220", "10 calls 3220"]);
expect("on the previous span's last date only the calls up to the time of day in their own zone, as 63 B14",
  [figs(prevAt("2026-10-28T13:00:00Z")), ...["NL", "GB"].map((m) => `${m} ${prevAt("2026-10-28T13:00:00Z", { market: m, line: null }).calls}/${prevAt("2026-10-28T13:00:00Z", { market: m, line: null }).talkSeconds}`)],
  ["4/3/1 3/0 0 3 2100 700 out 0 null 3", "NL 3/1700", "GB 1/400"], ["6/5/1 5/0 0 5 3100 620 out 0 null 5", "NL 4/1900", "GB 2/1200"]);
expect("a period that ended compares with the whole previous one, whatever the time of day, as 63 B15",
  [figs(prevAt("2026-11-01T23:30:00Z")), figs(prevAt("2027-11-02T12:00:00Z"))],
  ["10/8/2 8/1 50 9 3220 357.8 out 20 20 9", "10/8/2 8/1 50 9 3220 357.8 out 20 20 9"],
  ["2/1/1 1/1 100 2 1620 810 out 20 20 2", "10/8/2 8/1 50 9 3220 357.8 out 20 20 9"]);
expect("days and ISO weeks across the DST change, each call in its line's zone, as 63 B7",
  [groupCalls(records(), "2026-10-19", "2026-11-01", "day").rows.map((r) => `${r.groupKey}=${r.calls}`),
    groupCalls(records(), "2026-10-19", "2026-11-01", "week").rows.map((r) => `${r.groupKey}=${r.calls}`)],
  [["2026-10-19=1", "2026-10-20=1", "2026-10-21=4", "2026-10-25=4", "2026-10-26=3", "2026-10-27=2", "2026-10-28=2", "2026-10-29=2", "2026-10-30=1", "2026-10-31=1", "2026-11-01=1"],
    ["2026-10-19=10", "2026-10-26=12"]],
  [["2026-10-18=1", "2026-10-20=1", "2026-10-21=4", "2026-10-25=3", "2026-10-26=4", "2026-10-27=2", "2026-10-28=2", "2026-10-29=2", "2026-10-30=1", "2026-10-31=1", "2026-11-01=1"],
    ["2026-10-19=10", "2026-10-26=12"]]);
expect("untagged: any current tag counts, counted or not, as 63 B3",
  groupCalls(records(), "2026-10-26", "2026-11-01", "day").rows.map((r) => `${r.groupKey}=${r.untaggedConversations}`),
  ["2026-10-26=1", "2026-10-27=0", "2026-10-28=1", "2026-10-29=0", "2026-10-30=0", "2026-10-31=0", "2026-11-01=1"],
  ["2026-10-26=1", "2026-10-27=1", "2026-10-28=1", "2026-10-29=0", "2026-10-30=0", "2026-10-31=0", "2026-11-01=1"]);
const tagUse = callsTagUse(records(), "2026-10-26", "2026-11-01", "market", callTags);
expect("tag use by market, the most used first, untagged last, then the whole period, as 63 B6",
  tagUse.map((r) => `${r.groupKey ?? "all"}:${r.tagName ?? "-"}=${r.conversations}${r.isCounted === false ? "(not counted)" : ""}`),
  ["GB:Info=1", "GB:Test=1(not counted)", "GB:-=2", "NL:Sale=3", "NL:Info=1", "NL:Test=1(not counted)", "NL:-=1", "all:Sale=3", "all:Info=2", "all:Test=2(not counted)", "all:-=3"],
  ["GB:Info=1", "GB:-=2", "NL:Sale=3", "NL:Info=1", "NL:-=1", "all:Sale=3", "all:Info=2", "all:-=3"]);
const perPerson = callsPerPerson(records(), "2026-10-26", "2026-11-01", personOf);
const pp = (p) => `${p.kind}:${p.name ?? "-"}${p.unlinkedUsers === null ? "" : `(${p.unlinkedUsers})`} in ${p.answeredInbound} ${p.inboundTalkSeconds} ${p.inboundTalkAvgSeconds} out ${p.outboundCalls}/${p.connectedOutbound} ${p.outboundTalkSeconds} ${p.outboundTalkAvgSeconds} conv ${p.conversations} untagged ${p.untaggedConversations} ${p.firstCallTime}-${p.lastCallTime}`;
expect("per person by name, the users without a person as one counted row, then the total, as 63 B8",
  [...perPerson.rows.map(pp), pp(perPerson.total)],
  ["person:Anna Verify in 2 360 180 out 2/1 10 10 conv 3 untagged 1 00:30-16:00", "person:Bram Verify in 2 90 45 out 2/1 120 120 conv 3 untagged 1 10:00-16:30",
    "notLinked:-(2) in 1 90 90 out 2/1 40 40 conv 2 untagged 1 10:00-23:30", "total:- in 5 540 108 out 6/3 170 56.7 conv 8 untagged 3 00:30-23:30"],
  ["person:Bram Verify in 2 90 45 out 2/1 120 120 conv 3 untagged 1 10:00-16:30", "person:Anna Verify in 2 360 180 out 2/1 10 10 conv 3 untagged 1 00:30-16:00",
    "notLinked:-(3) in 1 90 90 out 2/1 40 40 conv 2 untagged 1 10:00-23:30", "total:- in 5 540 108 out 6/3 170 56.7 conv 8 untagged 3 00:30-23:30"]);
const ppTags = callsPerPersonTags(records(), "2026-10-26", "2026-11-01", personOf, callTags);
expect("tags per person: counted tags only, untagged last; a tag that does not count still makes a call tagged, as 63 B4",
  ppTags.map((t) => `${t.kind === "person" ? people[Object.keys(people).find((k) => people[k].userId === t.userId)].name : t.kind}:${t.tagName ?? "-"}=${t.conversations}`),
  ["Anna Verify:Sale=1", "Anna Verify:-=1", "Bram Verify:Info=2", "Bram Verify:Sale=1", "Bram Verify:-=1", "notLinked:Sale=1", "notLinked:-=1"],
  ["Anna Verify:Sale=1", "Anna Verify:Test=1", "Anna Verify:-=1", "Bram Verify:Info=2", "Bram Verify:Sale=1", "Bram Verify:Test=1", "Bram Verify:-=1", "notLinked:Sale=1", "notLinked:-=1"]);
const alike = (filter) => {
  const r = records(10, filter);
  const o = groupCalls(r, "2026-10-26", "2026-11-01", "market").total;
  const p = callsPerPerson(r, "2026-10-26", "2026-11-01", personOf);
  const tu = callsTagUse(r, "2026-10-26", "2026-11-01", "line", callTags).filter((x) => x.groupKey === null && x.tagKey === null).reduce((a, x) => a + x.conversations, 0);
  const pt = callsPerPersonTags(r, "2026-10-26", "2026-11-01", personOf, callTags).filter((x) => x.tagKey === null).reduce((a, x) => a + x.conversations, 0);
  return `${o.calls}/${o.conversations}/${o.untaggedConversations} ${p.total.conversations}/${p.total.untaggedConversations}/${p.rows.reduce((a, x) => a + x.conversations, 0)} ${tu} ${pt}`;
};
expect("the market and line filters narrow every figure alike, as 63 B5",
  [alike({ market: null, line: null }), alike({ market: "GB", line: null }), alike({ market: "NL", line: null }), alike({ market: "NL", line: `${CONN}:line-nl` }),
    alike({ market: null, line: `${CONN}:line-nl2` }), alike({ market: "NL", line: `${CONN}:line-gb` })],
  ["12/8/3 8/3/8 3 3", "4/3/2 3/2/3 2 2", "8/5/1 5/1/5 1 1", "7/4/1 4/1/4 1 1", "1/1/0 1/0/1 0 0", "0/0/0 0/0/0 0 0"],
  ["12/8/3 8/3/8 3 3", "12/8/3 8/3/8 3 3", "12/8/3 8/3/8 3 3", "12/8/3 8/3/8 3 3", "12/8/3 8/3/8 3 3", "12/8/3 8/3/8 3 3"]);
expect("the change against the previous period: up, down, the same, new from none, nothing to compare",
  [callsDelta(395, 335), callsDelta(179, 181), callsDelta(5, 5), callsDelta(4, 0), callsDelta(null, 12)],
  [{ direction: "up", pct: 17.9 }, { direction: "down", pct: 1.1 }, { direction: "same", pct: 0 }, { direction: "up", pct: null }, { direction: "none", pct: null }],
  [{ direction: "up", pct: 17.9 }, { direction: "up", pct: 1.1 }, { direction: "same", pct: 0 }, { direction: "up", pct: Infinity }, { direction: "down", pct: null }]);
expect("the volume colours in the style's series order, never a red or an amber; Light Blue bars carry no text",
  [INBOUND_CLASS, OUTBOUND_CLASS, [TAG_CLASS, TAG_NOT_COUNTED_CLASS, OTHER_TAGS_CLASS, UNTAGGED_CLASS, CONVERSATION_CLASS, ...Object.values(PER_AGENT_BAR_CLASS)].filter((c) => /error|warning|red/.test(c))],
  ["bg-p4a-deepblue", "bg-p4a-green", []], ["bg-p4a-green", "bg-p4a-deepblue", ["bg-p4a-error"]]);
const many = Array.from({ length: 14 }, (_, i) => ({ groupKey: null, groupLabel: null, tagKey: `${CONN}:t${i}`, tagName: `Tag ${String(i).padStart(2, "0")}`, isCounted: i !== 2, conversations: 20 - i }))
  .concat([{ groupKey: null, groupLabel: null, tagKey: null, tagName: null, isCounted: null, conversations: 9 }]);
const top = topTags(many, 200);
expect("tags as bars: the top twelve, largest first, the rest as Other with its count; shares of the conversations",
  [top.bars.length, top.bars[0].name, top.bars[0].share, top.bars[2].isCounted, top.other && [top.other.count, top.other.tags, top.other.share]],
  [12, "Tag 00", 0.1, false, [15, 2, 0.075]], [14, "Tag 00", 0.1, true, null]);
const groupedMany = [...many.map((r) => ({ ...r, groupKey: "NL", groupLabel: "NL" })), ...many];
const table = tagTable(groupedMany, [{ groupKey: "NL", groupLabel: "NL", ...week.total, conversations: 100 }]);
expect("the groups by tags: twelve columns and Other, counts and shares of the row's conversations, untagged last",
  [table.columns.length, table.hasOther, table.lines[0].cells[0], table.lines[0].other, table.lines[0].untagged],
  [12, true, { count: 20, share: 0.2 }, { count: 15, share: 0.15 }, { count: 9, share: 0.09 }],
  [14, false, { count: 20, share: 0.2 }, { count: 0, share: 0 }, { count: 9, share: 0.09 }]);
expect("the untagged share, the chart's axis without gaps up to today, a count axis",
  [untaggedPct(week.total), untaggedPct({ conversations: 0, untaggedConversations: 0 }),
    chartGroups(groupCalls(records(10, { market: "GB", line: null }), "2026-10-26", "2026-11-01", "day").rows, "day", "2026-10-26", "2026-11-01", "2026-10-31")
      .map((r) => `${r.groupKey.slice(8)}=${r.calls}`),
    chartGroups(groupCalls(records(), "2026-10-19", "2026-11-01", "week").rows, "week", "2026-10-21", "2026-11-01", "2026-11-01").length,
    [countAxis(0), countAxis(47), countAxis(395)]],
  [37.5, null, ["26=0", "27=0", "28=2", "29=0", "30=0", "31=1", "01=1"], 2, [{ top: 4, step: 1 }, { top: 50, step: 10 }, { top: 400, step: 100 }]],
  [37.5, 0, ["28=2", "31=1", "01=1"], 1, [{ top: 0, step: 1 }, { top: 47, step: 10 }, { top: 395, step: 100 }]]);
const maxima = columnMaxima([...perPerson.rows, perPerson.total]);
expect("the per-agent bars scaled to each column's largest person (the total row is not one); a person's split by tag",
  [maxima.answeredInbound, maxima.inboundTalkSeconds, barShare(90, maxima.inboundTalkSeconds), barShare(null, 10),
    personSplit(ppTags, perPerson.rows[1]).map((s) => `${s.name ?? "-"}:${s.count}:${Math.round(s.share * 100)}`)],
  [2, 360, 0.25, 0, ["Info:2:67", "Sale:1:33", "-:1:33"]],
  [5, 540, 0.17, 0, ["Info:2:67", "Sale:1:33"]]);
expect("talk time: seconds under a minute, minutes and seconds under an hour, hours and minutes from an hour",
  [fmtTalk(45, "en"), fmtTalk(88.75, "en"), fmtTalk(3725, "nl"), fmtTalk(null, "en"), fmtShare(0.375, "en"), fmtShare(null, "en")],
  ["45 s", "1m 29s", "1h 02m", "–", "38%", "–"], ["45.0 s", "88 s", "62m 05s", "0 s", "37.5%", "0%"]);
const answer = { rows: week.rows, total: week.total, people: perPerson.rows.map((p) => ({ ...p })), tags: tagUse };
expect("no hash, number, call id or telephony user id in a calls answer; an agent's own name is allowed",
  [personalDataIn(answer, "$", true), personalDataIn({ a: "c1".repeat(32), name: "Anna", callId: "x", userRef: "tel-user-1", tagName: "Sale" }, "$", true)],
  [[], ["$.a", "$.callId", "$.userRef"]], [["$.people"], []]);

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
