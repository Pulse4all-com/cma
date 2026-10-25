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
 * 80th percentile, which the API returns and the screens no longer show since 15 October 2026, the total over every call), hours and dates across the DST change of 25 October 2026
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
 * telephony user id in an answer. Since addition 0008zc the calls follow docs/definitions.md (63 amended to match, and 101's
 * own calls: connected at any talk time, Conversation at the threshold without a tag meaning not reached, inbound alike,
 * the settings moving the edges, talk time over the answered calls, untagged over every call, no untagged tag row).
 * Since addition 0008zd also 103's own calls: a tag meaning incorrect data keeps a call out of Conversation like not reached
 * (on a tag that does not count, next to another tag, inbound alike), Connected unchanged, and again once the tag is removed.
 * Since addition 0008k (brief B16.1) also the telephony history start on
 * 65's own dataset (the earliest business date in its line's zone; deleted calls, calls without a start
 * and calls on a line that does not count left out; a later call on an earlier date) and what a tile
 * says: no change against a previous span that starts before it, the change as before from it on. Since
 * addition 0008p (brief B17d) also Forms, on 75's own dataset (its tenant one's submissions as
 * cma.form_submissions_of gives them, written down from a run of 75) so the figures are the ones 75 proves
 * in the database: business dates in each submission's market zone, days and ISO weeks, the resolution
 * split, the previous period like for like (running, ended, not started), the answers per field and value
 * with a multiple-checkboxes answer under each value and the field and value filters, the filters by
 * market, category, none and form and the malformed ones refused, the history start; then the screen's
 * arrangement: the lines per form and market, the forms with their markets, the totals per category (the
 * catalog's order, none last) and per market (unknown last), the chart's columns without gaps, the
 * answers per form, the share of contacts found, and no submission, contact or email in an answer. Since
 * addition 0008t (brief N19-A part 1) also Email and Email per agent (src/lib/email.ts), on a fixture with the
 * edges 83 proves in the database: an uncounted inbox and channel, a spam conversation, an inbox copy and an
 * automated send by origin, a deleted email, a reopen at creation (no opening) and one after a close (an
 * opening), a first reply in and out of office hours in the market's zone, an unknown market ("No business
 * hours"), a mailbox's market before its inbox's, an owner without a person (one not-linked row with how many,
 * never which), the figures and medians, the groups with none last, the received series and its Other, waiting
 * now, the filters and groups as the database checks them, the per-person switch, and nothing personal in an answer.
 * Since addition 0008u (brief N19-A part 2) also First orders and Orders per person (src/lib/first-orders.ts), on
 * 85's own scenario, so the definitions are the ones 85 proves in the database: the kinds (no contact, renewal,
 * repeat, not first, first), every flag at the window's edges, a known contact at exactly the minutes, the level and
 * the attribution with the level order and the assisted set changed, the credited person (the latest assisted touch,
 * through a telephony user, not linked), days from the first touch, the figures per level and market, amounts per
 * currency never summed across, the list, per person by name with the not-linked row, the filters and groups, and
 * no name, address or phone number in an answer.
 * Since addition 0008w (brief N19-A part 4) also Callbacks kept (src/lib/callbacks.ts), on 89's own scenario: the states
 * and the call's minutes from the due time, the window's edges, an inbound call, the setting moving it, pending while the window is
 * open, the figures per ISO week and in total, the previous period like for like, per person with the not-linked row.
 * Since addition 0008y also Attempts per deal and Attempts per agent (src/lib/attempts.ts), since 0008z on 95's own
 * scenario, so the definitions are the ones 95 proves in the database: the groups and G, the filters (market, pipeline,
 * attempted, outcome) and the problems the routes answer with a 400, the sales population (no order pipeline, no other
 * pipeline), the attempts by source (telephony, crm) with a conversation by the linked call's talk time alone (0008zc) and the
 * setting moving the edge, the window ending at the close or the first order, the ordered deal out of the open figures, one deal's
 * attempts with the agent only when names are allowed, won against lost, the win rate by attempts and by speed to lead,
 * the figures and the previous period, the list's order and cap, per person by name with the not-linked row, and nothing
 * personal in an answer; and, from their source, the routes: the scope and the lists refused with a 400, one deal's
 * attempts for the report permissions, a message's withdrawal for messages.withdraw only.
 * Since addition 0008zb also Funnel, lost reasons, Cancellations and deals per person (src/lib/funnel.ts), on 99's own
 * scenario, so the definitions are the ones 99 proves in the database: the groups and the filters with the problems the
 * routes answer with a 400, the sales population, per pipeline and in total with the win rate by close date and the
 * median days, per stage (entered, still there, moved on, days in stage, reached won; a stage off without figures), the
 * filters narrowing every figure, the previous span like for like, the real reasons and their shares, the data-quality
 * block, no reason, per market and source with the top 3, per week and day, the list without a reason, the reason states
 * (enumeration only), the kinds' rules by pipeline and category, the cancellation requests per market and week with the
 * kind unset and archived, deals per person with the amounts per currency never summed, nothing personal in an answer;
 * and, from their source, the routes and the Sources writes.
 */
import {
  ANSWERED_CLASS, applyConnections, barShares, cellOf, fillHint, filterMarket, fmtAnswerSeconds, fmtBusinessMinutes, fmtCount, fmtPct, groupDisplay,
  groupInbound, groupSpeedToLead, inboundBar, inboundCalls, inboundFigures, inboundGroupDisplay, intakeMarkets, intakeTotals, isMuted, missedReasonOf,
  nextGroup, nextInboundGroup, openNotCalled, orderChecks, parseGroup, parseInboundGroup, percentileCont, personalDataIn, rangeProblem, REASON_SERIES,
  reasonColumns, recordsOfType, speedFigures, summaryTotals, unansweredPct, WAITING_CLASS,
  barShare, callRecords, callsChange, callsDelta, callsFigures, callsPerPerson, callsPerPersonTags, callsTagUse, chartGroups, columnMaxima, CONVERSATION_CLASS, countAxis, filterQuery,
  fmtShare, fmtTalk, groupCalls, INBOUND_CLASS, nextCallsGroup, OTHER_TAGS_CLASS, OUTBOUND_CLASS, parseCallsFilter, parseCallsGroup, PER_AGENT_BAR_CLASS,
  historyStartOf, personSplit, previousBeforeHistory, previousCalls, previousPeriod, TAG_CLASS, TAG_NOT_COUNTED_CLASS, tagTable, topTags, untaggedPct, callRules,
  CONVERSATION_EXCLUDING_MEANINGS,
  answerGroups, formsAnswersOf, formsByCategory, formsByMarket, formsFigures, formsFilterQuery, formsHistoryStart, formsLines, formsSeries, formsSum,
  formsTableGroups, nextFormsGroup, parseAnswerFilter, parseFormsFilter, parseFormsGroup, previousForms, resolvedShare,
} from "../src/lib/reports.ts";
import { fmtRating, marketsWithoutChannel, reviewMarketStates, reviewRecords, reviewShare, reviewsReport, starsOf } from "../src/lib/reviews.ts";
import { readFileSync } from "node:fs";
import { addDays, dateKeyInZone } from "../src/lib/time.ts";
import { WITHDRAW_PERMISSION } from "../src/lib/messages.ts";
import {
  businessSeconds, emailCloses, emailFigures, emailFilterQuery, emailGroups, emailInPeriod, emailOpenings, emailPerPerson, emailPrevious, emailRecords,
  emailSeries, emailWaiting, nextEmailGroup, parseEmailFilter, parseEmailGroup, perPersonOpen, seriesColumns, withinShare, zonedInstant,
} from "../src/lib/email.ts";
import {
  firstOrderAmounts, firstOrderFigures, firstOrderFilterQuery, firstOrderGroups, firstOrderList, firstOrderRecords, firstOrdersInPeriod, levelsInOrder,
  nextFirstOrderGroup, ordersPerPerson, parseFirstOrderFilter, parseFirstOrderGroup, callCenterShare,
} from "../src/lib/first-orders.ts";
import { callbackFigures, callbackRecords, callbacksInPeriod, callbacksPerOwner, callbackWeeksRange, keptShare } from "../src/lib/callbacks.ts";
import {
  ageBucket, attemptBuckets, attemptedShare, attemptFigures, attemptFilterQuery, attemptGroups, attemptList, attemptOutcomes, attemptRecords, ATTEMPTS_BAR_CLASS,
  ATTEMPTS_PER_AGENT_KEY, ATTEMPTS_PER_AGENT_PERMISSION, attemptSpeedBuckets, attemptsInPeriod, attemptsPerPerson, bucketText, businessDays, dealAttempts,
  conversationShare, firstConversationOnShare, firstConversationShare, fmtAttempts, nextAttemptGroup, noonShare, parseAttemptFilter, parseAttemptGroup,
  SINCE_LAST_CLASS, sinceLastBuckets,
  speedMinutes, withoutOutcomeShare, wonRate,
} from "../src/lib/attempts.ts";
import {
  cancellationPivot, cancellationRecords, cancellationsReport, DEALS_PER_PERSON_KEY, DEALS_PER_PERSON_PERMISSION, dealsPerPerson, FUNNEL_BAR_CLASS,
  FUNNEL_NEUTRAL_CLASS, funnelDeals, funnelFilter, funnelFilterQuery, funnelPrevious, funnelReport, inPeriod, kindRuleMatches, lostReasonsReport,
  nextFunnelGroup, parseFunnelFilter, parseFunnelGroup, periodKeys, periodReasonColumns, readTimesOf, reasonStateOf, recordKindsOf, stagesByPipeline,
} from "../src/lib/funnel.ts";

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
// 63 as amended for 0008zc: the tenants keep 0008j's thresholds as their own (connected at 10 seconds, a conversation at any talk time)
const records = (min = 10, filter) => callRecords(calls63, callLines, "Europe/Amsterdam", callRules(min, 0, callTags), filter);
const people = { "tel-user-1": { userId: "u-anna", name: "Anna Verify" }, "tel-user-2": { userId: "u-bram", name: "Bram Verify" } };
const personOf = (system, ref) => (system === "verifytel" && ref ? people[ref] ?? null : null);
const figs = (f) => `${f.calls}/${f.inbound}/${f.outbound} ${f.answeredInbound}/${f.connected} ${f.connectedRate} ${f.conversations} ${f.talkSeconds} ${f.talkAvgSeconds} out ${f.outboundTalkSeconds} ${f.outboundTalkAvgSeconds} ${f.untagged}`;
const week = groupCalls(records(), "2026-10-26", "2026-11-01", "market");
expect("talk time from the answer to the end over the answered calls, no ringing; a call at exactly the threshold connected, as 63 B1",
  [week.total.talkSeconds, records().find((c) => c.talkSeconds === 300)?.isConversation,
    [10, 9, 11].map((m) => groupCalls(records(m), "2026-10-26", "2026-11-01", "day").total.connected)],
  [719, true, [3, 4, 2]], [768, true, [3, 3, 3]]);
expect("a line that does not count and a deleted call are never counted, as 63 B2 and B12",
  [records().some((c) => c.lineKey === `${CONN}:line-off`), records().length, groupCalls(records(10, { market: null, line: `${CONN}:line-off` }), "2026-10-26", "2026-11-01", "day").total.calls],
  [false, 24, 0], [true, 26, 1]);
// the previous period's figures measured at an instant, as cma.calls_overview_of picks them (today in Amsterdam)
const WEEK63 = { from: "2026-10-26", to: "2026-11-01" };
const prevAt = (now, filter) => callsFigures(previousCalls(records(10, filter), previousPeriod(WEEK63, dateKeyInZone(now, "Europe/Amsterdam")), now));
expect("the overview per market, the computed total and the previous period measured after it, as 63 B12",
  [...week.rows.map((r) => `${r.groupKey}:${figs(r)}`), `current:${figs(week.total)}`, `previous:${figs(prevAt("2026-11-02T09:00:00Z"))}`],
  ["GB:4/1/3 1/2 66.7 3 220 73.3 out 160 80 3", "NL:8/5/3 4/1 33.3 5 499 83.2 out 10 10 3", "current:12/6/6 5/3 50 8 719 79.9 out 170 56.7 6",
    "previous:10/8/2 8/1 50 9 3220 357.8 out 20 20 10"],
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
  ["4/3/1 3/0 0 3 2100 700 out 0 null 4", "NL 3/1700", "GB 1/400"], ["6/5/1 5/0 0 5 3100 620 out 0 null 5", "NL 4/1900", "GB 2/1200"]);
expect("a period that ended compares with the whole previous one, whatever the time of day, as 63 B15",
  [figs(prevAt("2026-11-01T23:30:00Z")), figs(prevAt("2027-11-02T12:00:00Z"))],
  ["10/8/2 8/1 50 9 3220 357.8 out 20 20 10", "10/8/2 8/1 50 9 3220 357.8 out 20 20 10"],
  ["2/1/1 1/1 100 2 1620 810 out 20 20 2", "10/8/2 8/1 50 9 3220 357.8 out 20 20 9"]);
// The start of the telephony history (addition 0008k) on 65's own dataset: an NL line, a US line in Los
// Angeles, an NL line that does not count, and lines in Kiritimati (UTC+14) and at UTC-12
const histLines = [
  { connectionId: CONN, lineRef: "h-nl", name: "NL", market: "NL", zone: "Europe/Amsterdam", isCounted: true },
  { connectionId: CONN, lineRef: "h-us", name: "US", market: "US", zone: "America/Los_Angeles", isCounted: true },
  { connectionId: CONN, lineRef: "h-off", name: "Off", market: "NL", zone: "Europe/Amsterdam", isCounted: false },
  { connectionId: CONN, lineRef: "h-ki", name: "KI", market: "KI", zone: "Pacific/Kiritimati", isCounted: true },
  { connectionId: CONN, lineRef: "h-um", name: "UM", market: "UM", zone: "Etc/GMT+12", isCounted: true },
];
const hcall = (src, start, line, extra = {}) => ccall(src, "inbound", Date.parse(start), 5, 65, line, null, [], extra);
const hist = [
  hcall("h-nl", "2026-10-01T22:30:00Z", "h-nl"),                     // 2 October in Amsterdam, the earliest by its start
  hcall("h-us", "2026-10-02T03:00:00Z", "h-us"),                     // 1 October, 20:00 in Los Angeles
  hcall("h-del", "2026-09-25T10:00:00Z", "h-nl", { deleted: true }),
  hcall("h-off", "2026-09-20T10:00:00Z", "h-off"),
  { ...hcall("h-nostart", "2026-09-01T10:00:00Z", "h-nl"), startedAt: null },
];
const startOf = (calls, lines = histLines) => historyStartOf(callRecords(calls, lines, "Europe/Amsterdam", callRules(10, 0, [])));
expect("the history start: the earliest business date in its line's zone; deleted, unstarted and uncounted calls left out, as 65 B2 to B5 and B9",
  [startOf(hist), startOf(hist, histLines.map((l) => (l.lineRef === "h-us" ? { ...l, market: "NL", zone: "Europe/Amsterdam" } : l))),
    startOf(hist.map((c) => ({ ...c, deleted: false }))), startOf(hist, histLines.map((l) => ({ ...l, isCounted: true }))),
    startOf([]), startOf(hist.slice(2)),
    startOf([hcall("h-ki", "2026-09-26T10:30:00Z", "h-ki"), hcall("h-um", "2026-09-27T11:00:00Z", "h-um")])],
  ["2026-10-01", "2026-10-02", "2026-09-25", "2026-09-20", null, null, "2026-09-26"],
  ["2026-10-02", "2026-10-02", "2026-09-25", "2026-09-20", null, "2026-09-20", "2026-09-27"]);
// prod on 14 October 2026, its history from 1 October: This month compares with 31 August to 13 September
// (before the history: no change), This week with 5 to 7 October (the change as before); a span from the
// history's first date compares, a day earlier does not; without a history start everything compares
const HS = "2026-10-01";
const monthPrev = previousPeriod({ from: "2026-10-01", to: "2026-10-31" }, "2026-10-14");
const weekPrev = previousPeriod({ from: "2026-10-12", to: "2026-10-18" }, "2026-10-14");
expect("a previous span before the history start shows no change; from it on, the change as before",
  [previousBeforeHistory(monthPrev.from, HS), previousBeforeHistory(weekPrev.from, HS),
    previousBeforeHistory(previousPeriod({ from: "2026-10-08", to: "2026-10-14" }, "2026-10-15").from, HS),
    previousBeforeHistory(previousPeriod({ from: "2026-10-07", to: "2026-10-13" }, "2026-10-15").from, HS),
    previousBeforeHistory(monthPrev.from, null),
    callsChange(3590, 1, monthPrev.from, HS), callsChange(395, 335, weekPrev.from, HS), callsChange(4, 0, weekPrev.from, HS),
    callsChange(3590, 1, monthPrev.from, null)],
  [true, false, false, true, false, { direction: "noHistory", pct: null }, { direction: "up", pct: 17.9 }, { direction: "up", pct: null },
    { direction: "up", pct: 358900 }],
  [false, false, false, false, false, { direction: "up", pct: 358900 }, { direction: "noHistory", pct: null }, { direction: "up", pct: null },
    { direction: "noHistory", pct: null }]);
expect("days and ISO weeks across the DST change, each call in its line's zone, as 63 B7",
  [groupCalls(records(), "2026-10-19", "2026-11-01", "day").rows.map((r) => `${r.groupKey}=${r.calls}`),
    groupCalls(records(), "2026-10-19", "2026-11-01", "week").rows.map((r) => `${r.groupKey}=${r.calls}`)],
  [["2026-10-19=1", "2026-10-20=1", "2026-10-21=4", "2026-10-25=4", "2026-10-26=3", "2026-10-27=2", "2026-10-28=2", "2026-10-29=2", "2026-10-30=1", "2026-10-31=1", "2026-11-01=1"],
    ["2026-10-19=10", "2026-10-26=12"]],
  [["2026-10-18=1", "2026-10-20=1", "2026-10-21=4", "2026-10-25=3", "2026-10-26=4", "2026-10-27=2", "2026-10-28=2", "2026-10-29=2", "2026-10-30=1", "2026-10-31=1", "2026-11-01=1"],
    ["2026-10-19=10", "2026-10-26=12"]]);
expect("untagged: every call without a current tag, missed ones included; any tag counts, counted or not, as 63 B3",
  [`${week.total.untagged} of ${week.total.calls} calls`, ...groupCalls(records(), "2026-10-26", "2026-11-01", "day").rows.map((r) => `${r.groupKey}=${r.untagged}`)],
  ["6 of 12 calls", "2026-10-26=1", "2026-10-27=1", "2026-10-28=1", "2026-10-29=1", "2026-10-30=0", "2026-10-31=1", "2026-11-01=1"],
  ["3 of 8 calls", "2026-10-26=1", "2026-10-27=0", "2026-10-28=1", "2026-10-29=0", "2026-10-30=0", "2026-10-31=0", "2026-11-01=1"]);
const tagUse = callsTagUse(records(), "2026-10-26", "2026-11-01", "market", callTags);
expect("tag use by market, the most used first, no untagged row, then the whole period, as 63 B6",
  tagUse.map((r) => `${r.groupKey ?? "all"}:${r.tagName ?? "-"}=${r.conversations}${r.isCounted === false ? "(not counted)" : ""}`),
  ["GB:Info=1", "GB:Test=1(not counted)", "NL:Sale=3", "NL:Info=1", "NL:Test=1(not counted)", "all:Sale=3", "all:Info=2", "all:Test=2(not counted)"],
  ["GB:Info=1", "GB:-=2", "NL:Sale=3", "NL:Info=1", "NL:-=1", "all:Sale=3", "all:Info=2", "all:-=3"]);
const perPerson = callsPerPerson(records(), "2026-10-26", "2026-11-01", personOf);
const pp = (p) => `${p.kind}:${p.name ?? "-"}${p.unlinkedUsers === null ? "" : `(${p.unlinkedUsers})`} in ${p.answeredInbound} ${p.inboundTalkSeconds} ${p.inboundTalkAvgSeconds} out ${p.outboundCalls}/${p.connected} ${p.outboundTalkSeconds} ${p.outboundTalkAvgSeconds} conv ${p.conversations} untagged ${p.untagged} ${p.firstCallTime}-${p.lastCallTime}`;
expect("per person by name, the users without a person as one counted row, then the total; untagged over their own calls, as 63 B8",
  [...perPerson.rows.map(pp), pp(perPerson.total)],
  ["person:Anna Verify in 2 360 180 out 2/1 10 10 conv 3 untagged 1 00:30-16:00", "person:Bram Verify in 2 90 45 out 2/1 120 120 conv 3 untagged 2 10:00-16:30",
    "notLinked:-(2) in 1 90 90 out 2/1 40 40 conv 2 untagged 2 10:00-23:30", "total:- in 5 540 108 out 6/3 170 56.7 conv 8 untagged 5 00:30-23:30"],
  ["person:Bram Verify in 2 90 45 out 2/1 120 120 conv 3 untagged 1 10:00-16:30", "person:Anna Verify in 2 360 180 out 2/1 10 10 conv 3 untagged 1 00:30-16:00",
    "notLinked:-(3) in 1 90 90 out 2/1 40 40 conv 2 untagged 1 10:00-23:30", "total:- in 5 540 108 out 6/3 170 56.7 conv 8 untagged 3 00:30-23:30"]);
const ppTags = callsPerPersonTags(records(), "2026-10-26", "2026-11-01", personOf, callTags);
expect("tags per person: counted tags only, no untagged row, as 63 B4",
  ppTags.map((t) => `${t.kind === "person" ? people[Object.keys(people).find((k) => people[k].userId === t.userId)].name : t.kind}:${t.tagName ?? "-"}=${t.conversations}`),
  ["Anna Verify:Sale=1", "Bram Verify:Info=2", "Bram Verify:Sale=1", "notLinked:Sale=1"],
  ["Anna Verify:Sale=1", "Anna Verify:Test=1", "Anna Verify:-=1", "Bram Verify:Info=2", "Bram Verify:Sale=1", "Bram Verify:Test=1", "Bram Verify:-=1", "notLinked:Sale=1", "notLinked:-=1"]);
const alike = (filter) => {
  const r = records(10, filter);
  const o = groupCalls(r, "2026-10-26", "2026-11-01", "market").total;
  const p = callsPerPerson(r, "2026-10-26", "2026-11-01", personOf);
  const tu = callsTagUse(r, "2026-10-26", "2026-11-01", "line", callTags).filter((x) => x.groupKey === null).reduce((a, x) => a + x.conversations, 0);
  const pt = callsPerPersonTags(r, "2026-10-26", "2026-11-01", personOf, callTags).reduce((a, x) => a + x.conversations, 0);
  return `${o.calls}/${o.conversations}/${o.untagged} ${p.total.conversations}/${p.total.untagged}/${p.rows.reduce((a, x) => a + x.conversations, 0)} ${tu} ${pt}`;
};
expect("the market and line filters narrow every figure alike, as 63 B5",
  [alike({ market: null, line: null }), alike({ market: "GB", line: null }), alike({ market: "NL", line: null }), alike({ market: "NL", line: `${CONN}:line-nl` }),
    alike({ market: null, line: `${CONN}:line-nl2` }), alike({ market: "NL", line: `${CONN}:line-gb` })],
  ["12/8/6 8/5/8 7 5", "4/3/3 3/3/3 2 1", "8/5/3 5/2/5 5 4", "7/4/3 4/2/4 3 2", "1/1/0 1/0/1 2 2", "0/0/0 0/0/0 0 0"],
  ["12/8/3 8/3/8 3 3", "12/8/3 8/3/8 3 3", "12/8/3 8/3/8 3 3", "12/8/3 8/3/8 3 3", "12/8/3 8/3/8 3 3", "12/8/3 8/3/8 3 3"]);
expect("the change against the previous period: up, down, the same, new from none, nothing to compare",
  [callsDelta(395, 335), callsDelta(179, 181), callsDelta(5, 5), callsDelta(4, 0), callsDelta(null, 12)],
  [{ direction: "up", pct: 17.9 }, { direction: "down", pct: 1.1 }, { direction: "same", pct: 0 }, { direction: "up", pct: null }, { direction: "none", pct: null }],
  [{ direction: "up", pct: 17.9 }, { direction: "up", pct: 1.1 }, { direction: "same", pct: 0 }, { direction: "up", pct: Infinity }, { direction: "down", pct: null }]);
expect("the volume colours in the style's series order, never a red or an amber; Light Blue bars carry no text",
  [INBOUND_CLASS, OUTBOUND_CLASS, [TAG_CLASS, TAG_NOT_COUNTED_CLASS, OTHER_TAGS_CLASS, CONVERSATION_CLASS, ...Object.values(PER_AGENT_BAR_CLASS)].filter((c) => /error|warning|red/.test(c))],
  ["bg-p4a-deepblue", "bg-p4a-green", []], ["bg-p4a-green", "bg-p4a-deepblue", ["bg-p4a-error"]]);
const many = Array.from({ length: 14 }, (_, i) => ({ groupKey: null, groupLabel: null, tagKey: `${CONN}:t${i}`, tagName: `Tag ${String(i).padStart(2, "0")}`, isCounted: i !== 2, conversations: 20 - i }));
const top = topTags(many, 200);
expect("tags as bars: the top twelve, largest first, the rest as Other with its count; shares of the conversations",
  [top.bars.length, top.bars[0].name, top.bars[0].share, top.bars[2].isCounted, top.other && [top.other.count, top.other.tags, top.other.share]],
  [12, "Tag 00", 0.1, false, [15, 2, 0.075]], [14, "Tag 00", 0.1, true, null]);
const groupedMany = [...many.map((r) => ({ ...r, groupKey: "NL", groupLabel: "NL" })), ...many];
const table = tagTable(groupedMany, [{ groupKey: "NL", groupLabel: "NL", ...week.total, conversations: 100 }]);
expect("the groups by tags: twelve columns and Other, shares of the row's conversations; untagged last, a share of the row's calls",
  [table.columns.length, table.hasOther, table.lines[0].cells[0], table.lines[0].other, table.lines[0].untagged],
  [12, true, { count: 20, share: 0.2 }, { count: 15, share: 0.15 }, { count: 6, share: 0.5 }],
  [14, false, { count: 20, share: 0.2 }, { count: 0, share: 0 }, { count: 6, share: 0.06 }]);
expect("the untagged share, the chart's axis without gaps up to today, a count axis",
  [untaggedPct(week.total), untaggedPct({ calls: 0, untagged: 0 }),
    chartGroups(groupCalls(records(10, { market: "GB", line: null }), "2026-10-26", "2026-11-01", "day").rows, "day", "2026-10-26", "2026-11-01", "2026-10-31")
      .map((r) => `${r.groupKey.slice(8)}=${r.calls}`),
    chartGroups(groupCalls(records(), "2026-10-19", "2026-11-01", "week").rows, "week", "2026-10-21", "2026-11-01", "2026-11-01").length,
    [countAxis(0), countAxis(47), countAxis(395)]],
  [50, null, ["26=0", "27=0", "28=2", "29=0", "30=0", "31=1", "01=1"], 2, [{ top: 4, step: 1 }, { top: 50, step: 10 }, { top: 400, step: 100 }]],
  [37.5, 0, ["28=2", "31=1", "01=1"], 1, [{ top: 0, step: 1 }, { top: 47, step: 10 }, { top: 395, step: 100 }]]);
const maxima = columnMaxima([...perPerson.rows, perPerson.total]);
expect("the per-agent bars scaled to each column's largest person (the total row is not one); a person's split by tag",
  [maxima.answeredInbound, maxima.inboundTalkSeconds, barShare(90, maxima.inboundTalkSeconds), barShare(null, 10),
    personSplit(ppTags, perPerson.rows[1]).map((s) => `${s.name ?? "-"}:${s.count}:${Math.round(s.share * 100)}`)],
  [2, 360, 0.25, 0, ["Info:2:67", "Sale:1:33"]],
  [5, 540, 0.17, 0, ["Info:2:67", "Sale:1:33", "-:1:33"]]);
// Connected and Conversation as docs/definitions.md defines them (addition 0008zc) on 101's own calls of 6 October 2026: one NL
// line; tags Not Reached (meaning not_reached), Not Reached off (not_reached, not counted) and Type (call_type); five seconds
// of ringing, then the talk; o2 still in progress, o6's Not Reached since removed (its current tags are none), o8 and i4
// nobody answered; Anna behind the outbound calls, Bram behind the inbound ones
const tagsZc = [
  { connectionId: CONN, tagRef: "tg-nr", name: "Not Reached", isCounted: true, meaning: "not_reached" },
  { connectionId: CONN, tagRef: "tg-nr-off", name: "Not Reached off", isCounted: false, meaning: "not_reached" },
  { connectionId: CONN, tagRef: "tg-type", name: "Type", isCounted: true, meaning: "call_type" },
];
const D6 = Date.parse("2026-10-06T08:00:00Z");
const zcall = (src, direction, min, talk, user, tags = []) =>
  ccall(src, direction, D6 + min * 60e3, talk === undefined ? null : 5, talk === undefined ? 30 : 5 + (talk ?? 0), "line-nl", user, tags,
    talk === null ? { endedAt: null } : {});
const calls101 = [
  zcall("o1", "outbound", 0, 1, "tu-1"), zcall("o2", "outbound", 10, null, "tu-1"), zcall("o3", "outbound", 20, 29, "tu-1"),
  zcall("o4", "outbound", 30, 30, "tu-1"), zcall("o5", "outbound", 40, 30, "tu-1", ["tg-nr"]), zcall("o6", "outbound", 50, 120, "tu-1", []),
  zcall("o7", "outbound", 60, 60, "tu-1", ["tg-nr-off"]), zcall("o8", "outbound", 70, undefined, "tu-1"), zcall("o9", "outbound", 80, 45, "tu-1", ["tg-type"]),
  zcall("i1", "inbound", 90, 20, "tu-2"), zcall("i2", "inbound", 100, 45, "tu-2"), zcall("i3", "inbound", 110, 45, "tu-2", ["tg-nr"]),
  zcall("i4", "inbound", 120, undefined, null),
];
const zcRecords = (connected = 0, conversation = 30, tags = tagsZc) => callRecords(calls101, callLines, "Europe/Amsterdam", callRules(connected, conversation, tags));
const zcPeople = { "tu-1": { userId: "u-anna", name: "Anna Verify" }, "tu-2": { userId: "u-bram", name: "Bram Verify" } };
const zcPersonOf = (system, ref) => (system === "verifytel" && ref ? zcPeople[ref] ?? null : null);
const zcPerCall = (rows) => rows.map((c, i) => `${calls101[i].sourceId}:${c.isConnectedOutbound ? "c" : "-"}${c.isConversation ? "v" : "-"}`).sort().join(" ");
expect("connected at 1 s and in progress; Conversation at 30 s without not_reached (removed, or on an uncounted tag still out), inbound alike, as 101 B1",
  zcPerCall(zcRecords()), "i1:-- i2:-v i3:-- i4:-- o1:c- o2:c- o3:c- o4:cv o5:c- o6:cv o7:c- o8:-- o9:cv",
  "i1:-- i2:-v i3:-v i4:-- o1:-- o2:-- o3:c- o4:cv o5:cv o6:cv o7:cv o8:-- o9:cv");
const zcTotals = (a, b) => { const f = callsFigures(zcRecords(a, b)); return `${f.connected}/${f.conversations}`; };
expect("connected from 5 s leaves 1 s and in progress out; the Conversation threshold at 29 and 46 s, as 101 B2",
  `${zcTotals(5, 30)} ${zcTotals(0, 29)} ${zcTotals(0, 46)}`, "6/4 8/5 8/1", "8/4 8/4 8/4");
const zf = callsFigures(zcRecords());
expect("Calls: connected and its rate, conversations, talk time over the answered calls, untagged over every call, as 101 B3",
  [zf.calls, zf.inbound, zf.outbound, zf.answeredInbound, zf.connected, zf.connectedRate, zf.conversations, zf.talkSeconds, zf.talkAvgSeconds,
    zf.outboundTalkSeconds, zf.outboundTalkAvgSeconds, zf.untagged, untaggedPct(zf)].join("/"),
  "13/4/9/3/8/88.9/4/425/42.5/315/45/9/69.2", "13/4/9/3/8/88.9/4/315/45/315/45/7/77.8");
const zcPeopleRows = callsPerPerson(zcRecords(), "2026-10-06", "2026-10-06", zcPersonOf);
expect("tag use and tags per person without an untagged row; per person connected, conversations and untagged over their own calls, as 101 B4",
  `${callsTagUse(zcRecords(), "2026-10-05", "2026-10-11", "week", tagsZc).map((r) => `${r.groupKey ?? "all"}:${r.tagName}=${r.conversations}`).join(",")}`
    + ` | ${callsPerPersonTags(zcRecords(), "2026-10-06", "2026-10-06", zcPersonOf, tagsZc).map((r) => `${r.tagName}=${r.conversations}`).join(",")}`
    + ` | ${[...zcPeopleRows.rows, zcPeopleRows.total].map((p) => `${p.name ?? p.kind}:${p.answeredInbound}/${p.outboundCalls}/${p.connected}/${p.conversations}/${p.untagged}`).join(" ")}`,
  "2026-10-05:Type=1,all:Type=1 | Type=1 | Anna Verify:0/9/8/3/6 Bram Verify:3/0/0/1/2 total:3/9/8/4/8",
  "2026-10-05:Type=1,2026-10-05:Not Reached=1,all:Type=1,all:Not Reached=1 | Type=1 | Anna Verify:0/9/8/4/6 Bram Verify:3/0/0/2/2 total:3/9/8/6/8");
expect("without a tag meaning not reached, Conversation counts on talk time alone, as 101 B1 without the meanings",
  [zcPerCall(zcRecords(0, 30, tagsZc.map((t) => ({ ...t, meaning: t.meaning === "not_reached" ? null : t.meaning })))), callRules(0, 30, []).notReachedTags.size],
  ["i1:-- i2:-v i3:-v i4:-- o1:c- o2:c- o3:c- o4:cv o5:cv o6:cv o7:cv o8:-- o9:cv", 0],
  ["i1:-- i2:-v i3:-- i4:-- o1:c- o2:c- o3:c- o4:cv o5:c- o6:cv o7:c- o8:-- o9:cv", 0]);
// The tag meaning incorrect data (addition 0008zd) on 103's own calls of 6 October 2026: tags Wrong Number (meaning
// incorrect_data), Incorrect Data off (incorrect_data, not counted), Not Reached (not_reached) and Type (call_type); o7
// nobody answered; then o1 and i1 with their tag removed (their current tags none)
const tagsZd = [
  { connectionId: CONN, tagRef: "tg-wrong", name: "Wrong Number", isCounted: true, meaning: "incorrect_data" },
  { connectionId: CONN, tagRef: "tg-wrong-off", name: "Incorrect Data off", isCounted: false, meaning: "incorrect_data" },
  { connectionId: CONN, tagRef: "tg-nr", name: "Not Reached", isCounted: true, meaning: "not_reached" },
  { connectionId: CONN, tagRef: "tg-type", name: "Type", isCounted: true, meaning: "call_type" },
];
const calls103 = (removed) => [
  zcall("o1", "outbound", 0, 45, "tu-1", removed ? [] : ["tg-wrong"]), zcall("o2", "outbound", 10, 45, "tu-1"),
  zcall("o3", "outbound", 20, 45, "tu-1", ["tg-nr"]), zcall("o4", "outbound", 30, 45, "tu-1", ["tg-wrong-off"]),
  zcall("o5", "outbound", 40, 45, "tu-1", ["tg-type"]), zcall("o6", "outbound", 50, 10, "tu-1", ["tg-wrong"]),
  zcall("o7", "outbound", 60, undefined, "tu-1", ["tg-wrong"]), zcall("o8", "outbound", 70, 45, "tu-1", ["tg-type", "tg-wrong"]),
  zcall("o9", "outbound", 80, 60, "tu-1", ["tg-wrong"]), zcall("i1", "inbound", 90, 45, "tu-2", removed ? [] : ["tg-wrong"]),
  zcall("i2", "inbound", 100, 45, "tu-2"), zcall("i3", "inbound", 110, 45, "tu-2", ["tg-nr"]),
];
const zdRecords = (removed = false) => callRecords(calls103(removed), callLines, "Europe/Amsterdam", callRules(0, 30, tagsZd));
const zdPerCall = (removed = false) => zdRecords(removed).map((c, i) => `${calls103(removed)[i].sourceId}:${c.isConnectedOutbound ? "c" : "-"}${c.isConversation ? "v" : "-"}`).sort().join(" ");
expect("incorrect data: connected, no conversation (uncounted tag, next to another tag, inbound alike); not reached as before, as 103 B1",
  [zdPerCall(), CONVERSATION_EXCLUDING_MEANINGS],
  ["i1:-- i2:-v i3:-- o1:c- o2:cv o3:c- o4:c- o5:cv o6:c- o7:-- o8:c- o9:c-", ["not_reached", "incorrect_data"]],
  ["i1:-v i2:-v i3:-- o1:cv o2:cv o3:c- o4:cv o5:cv o6:c- o7:-- o8:cv o9:cv", ["not_reached"]]);
const zdf = callsFigures(zdRecords());
const zdPeopleRows = callsPerPerson(zdRecords(), "2026-10-06", "2026-10-06", zcPersonOf);
expect("Calls, tag use and per person count no conversation with a tag meaning incorrect data, as 103 B2",
  [zdf.calls, zdf.inbound, zdf.outbound, zdf.answeredInbound, zdf.connected, zdf.connectedRate, zdf.conversations, zdf.untagged].join("/")
    + ` | ${callsTagUse(zdRecords(), "2026-10-05", "2026-10-11", "week", tagsZd).map((r) => `${r.groupKey ?? "all"}:${r.tagName}=${r.conversations}`).join(",")}`
    + ` | ${[...zdPeopleRows.rows, zdPeopleRows.total].map((p) => `${p.name ?? p.kind}:${p.answeredInbound}/${p.outboundCalls}/${p.connected}/${p.conversations}/${p.untagged}`).join(" ")}`,
  "12/3/9/3/8/88.9/3/2 | 2026-10-05:Type=1,all:Type=1 | Anna Verify:0/9/8/2/1 Bram Verify:3/0/0/1/1 total:3/9/8/3/2",
  "12/3/9/3/8/88.9/6/2 | 2026-10-05:Type=2,2026-10-05:Wrong Number=4,all:Type=2,all:Wrong Number=4 | Anna Verify:0/9/8/5/1 Bram Verify:3/0/0/2/1 total:3/9/8/7/2");
expect("the same call is a conversation once its incorrect-data tag is removed, as 103 B5",
  zdPerCall(true).split(" ").filter((x) => /^(o1|i1):/.test(x)).join(" "), "i1:-v o1:cv", "i1:-- o1:c-");
expect("talk time: seconds under a minute, minutes and seconds under an hour, hours and minutes from an hour",
  [fmtTalk(45, "en"), fmtTalk(88.75, "en"), fmtTalk(3725, "nl"), fmtTalk(null, "en"), fmtShare(0.375, "en"), fmtShare(null, "en")],
  ["45 s", "1m 29s", "1h 02m", "–", "38%", "–"], ["45.0 s", "88 s", "62m 05s", "0 s", "37.5%", "0%"]);
const answer = { rows: week.rows, total: week.total, people: perPerson.rows.map((p) => ({ ...p })), tags: tagUse };
expect("no hash, number, call id or telephony user id in a calls answer; an agent's own name is allowed",
  [personalDataIn(answer, "$", true), personalDataIn({ a: "c1".repeat(32), name: "Anna", callId: "x", userRef: "tel-user-1", tagName: "Sale" }, "$", true)],
  [[], ["$.a", "$.callId", "$.userRef"]], [["$.people"], []]);

// ---- Forms (addition 0008p) ----------------------------------------------------------------------
// 75's tenant one after B10 (written down from a run of 75 on a fresh database): every stored submission as
// cma.form_submissions_of gives it; "c" stands for the connection id, which only joins the form key
const FC = "00000000-0000-7000-8000-0000000000aa";
const YES = "Yes, I'm an existing Customer";
const NO = "No, I'm not a customer yet";
const fsub = (form, market, zone, date, localTime, resolution, answers) => ({
  formKey: `${FC}:${form}`, formName: { "f-contact": "NL Contact", "f-cancel": "Cancellation", "f-legacy": "Legacy form", "f-support": "General support" }[form],
  category: { "f-contact": "contact", "f-cancel": "cancellation", "f-legacy": null, "f-support": "support" }[form], market, zone, date, localTime, resolution, answers,
});
const AMS = "Europe/Amsterdam";
const SUBS = [
  fsub("f-contact", "NL", AMS, "2026-09-21", "00:10:00", "not_found", { are_you_already_a_customer: NO }),
  fsub("f-cancel", "GB", "Europe/London", "2026-09-20", "23:30:00", "not_found", { country_dropdown: "United Kingdom", cancellation_reason: "Other" }),
  fsub("f-contact", "NL", AMS, "2026-09-28", "11:00:00", "not_found", { are_you_already_a_customer: NO }),
  fsub("f-contact", "NL", AMS, "2026-09-30", "15:00:00", "not_found", { are_you_already_a_customer: NO }),
  fsub("f-contact", "NL", AMS, "2026-09-30", "18:00:00", "not_found", { are_you_already_a_customer: YES }),
  fsub("f-cancel", "GB", "Europe/London", "2026-10-01", "23:30:00", "not_found", { country_dropdown: "United Kingdom", cancellation_reason: "Moving" }),
  fsub("f-contact", "NL", AMS, "2026-10-02", "00:30:00", "not_found", {}),
  fsub("f-legacy", "unknown", AMS, "2026-10-02", "12:00:00", "not_found", { product: "aed plus" }),
  fsub("f-contact", "NL", AMS, "2026-10-05", "11:00:00", "not_found", { are_you_already_a_customer: NO }),
  fsub("f-support", "unknown", AMS, "2026-10-05", "12:00:00", "not_found", { hs_ticket_category: ["Billing", "Device"] }),
  fsub("f-support", "unknown", AMS, "2026-10-05", "13:00:00", "not_found", { hs_ticket_category: ["Delivery"] }),
  fsub("f-cancel", "DE", "Europe/Berlin", "2026-10-05", "14:00:00", "resolved", { country_dropdown: "Atlantis", cancellation_reason: "Price" }),
  fsub("f-support", "unknown", AMS, "2026-10-05", "14:00:00", "resolved", {}),
  fsub("f-support", "unknown", AMS, "2026-10-05", "14:30:00", "resolved", {}),
  fsub("f-cancel", "unknown", AMS, "2026-10-05", "15:00:00", "not_found", { country_dropdown: "Atlantis", cancellation_reason: "Price" }),
  fsub("f-contact", "NL", AMS, "2026-10-06", "12:00:00", "not_found", { are_you_already_a_customer: YES }),
  fsub("f-support", "unknown", AMS, "2026-10-06", "12:00:00", "not_found", { hs_ticket_category: ["Device"] }),
  fsub("f-support", "unknown", AMS, "2026-10-06", "13:00:00", "not_found", {}),
  fsub("f-cancel", "NL", AMS, "2026-10-06", "15:00:00", "not_found", { country_dropdown: "Netherlands" }),
  fsub("f-contact", "NL", AMS, "2026-10-07", "16:00:00", "not_found", {}),
];
const ALL_FORMS = { market: null, category: null, form: null };
const short = (k) => k.replace(`${FC}:`, "");
const formsToday = (instant) => dateKeyInZone(new Date(instant), AMS);

expect("forms: day or week, G cycles, anything else refused",
  [parseFormsGroup("day"), parseFormsGroup("week"), parseFormsGroup("month"), nextFormsGroup("day"), nextFormsGroup("week")],
  ["day", "week", null, "week", "day"], ["day", "week", "month", "day", "week"]);
expect("forms: filters as the database checks them (75 B14's refusals: uk, a form without its connection, a bad field)",
  [parseFormsFilter("uk", null, null).problem, parseFormsFilter(null, null, "f-cancel").problem, parseFormsFilter(null, "Support", null).problem,
    parseFormsFilter("unknown", "none", `${FC}:f-cancel`).problem, parseAnswerFilter("bad field", null).problem, parseAnswerFilter("hs_ticket_category", "Device").problem],
  ["market", "form", "category", null, true, false], [null, null, null, "market", false, true]);
expect("forms: only the filters that are set go into the address",
  formsFilterQuery({ market: "NL", category: null, form: `${FC}:f-contact` }), { market: "NL", form: `${FC}:f-contact` }, { market: "NL", category: "", form: "" });

// 75 B11: 22:30 UTC on 1 October is 1 October in London and 2 October in Amsterdam; the weeks with the resolution split
const b11day = formsFigures(SUBS, "2026-10-01", "2026-10-02", "day", ALL_FORMS).filter((r) => r.groupKey !== null)
  .map((r) => `${r.groupKey}:${short(r.formKey)}:${r.market}=${r.submissions}`).sort().join(" ");
const b11week = formsFigures(SUBS, "2026-10-05", "2026-10-11", "week", ALL_FORMS).filter((r) => r.groupKey !== null && ["NL", "DE"].includes(r.market))
  .map((r) => `${r.groupKey}:${short(r.formKey)}=${r.submissions}/${r.resolved}/${r.notFound}`).join(" ");
expect("forms: business dates in each market's zone, days and ISO weeks, the resolution split (75 B11)", `${b11day} | ${b11week}`,
  "2026-10-01:f-cancel:GB=1 2026-10-02:f-contact:NL=1 2026-10-02:f-legacy:unknown=1 | 2026-10-05:f-cancel=1/1/0 2026-10-05:f-cancel=1/0/1 2026-10-05:f-contact=3/0/3",
  "2026-10-02:f-cancel:GB=1 2026-10-02:f-contact:NL=1 2026-10-02:f-legacy:unknown=1 | 2026-10-05:f-cancel=2/1/1 2026-10-05:f-contact=3/0/3");

// 75 B12: 5 to 11 October seen on Wednesday 7 October at 16:30 in Amsterdam, after it ended, before it started
const contactNL = { market: "NL", category: null, form: `${FC}:f-contact` };
const b12 = (now) => {
  const prev = previousPeriod({ from: "2026-10-05", to: "2026-10-11" }, formsToday(now));
  return formsSum(previousForms(SUBS, prev, contactNL, now)).submissions;
};
expect("forms: the previous period like for like (75 B12: running 2, ended 4, not started 0; current 3)",
  [b12("2026-10-07T14:30:00Z"), b12("2026-10-20T09:00:00Z"), b12("2026-10-01T09:00:00Z"),
    formsSum(formsFigures(SUBS, "2026-10-05", "2026-10-11", "day", contactNL).filter((r) => r.groupKey === null)).submissions],
  [2, 4, 0, 3], [3, 4, 0, 3]);

// 75 B13: the answers per form, field and value with the previous period; a multiple-checkboxes answer under each value
const prevAfter = previousPeriod({ from: "2026-10-05", to: "2026-10-11" }, formsToday("2026-10-20T09:00:00Z"));
const b13rows = [...formsAnswersOf(SUBS, "2026-10-05", "2026-10-11", ALL_FORMS, null, null, "current"),
  ...formsAnswersOf(SUBS, prevAfter.from, prevAfter.to, ALL_FORMS, null, null, "previous")];
const b13 = b13rows.filter((a) => ["f-support", "f-contact"].includes(short(a.formKey)))
  .map((a) => `${a.period}:${short(a.formKey)}.${a.field}/${a.value}=${a.submissions}`).sort().join(" ");
const device = formsAnswersOf(SUBS, "2026-10-05", "2026-10-11", ALL_FORMS, "hs_ticket_category", "Device", "current").map((a) => `${a.value}=${a.submissions}`).join(" ");
expect("forms: answers per field and value with the previous period; field and value filters (75 B13)", `${b13} | ${device}`,
  `current:f-contact.are_you_already_a_customer/${NO}=1 current:f-contact.are_you_already_a_customer/${YES}=1 `
  + "current:f-support.hs_ticket_category/Billing=1 current:f-support.hs_ticket_category/Delivery=1 current:f-support.hs_ticket_category/Device=2 "
  + `previous:f-contact.are_you_already_a_customer/${NO}=2 previous:f-contact.are_you_already_a_customer/${YES}=1 | Device=2`,
  `current:f-support.hs_ticket_category/Billing,Device=1 | Device=1`);

// 75 B14 and B15: the filters narrow every figure alike; the history start is the earliest business date in its zone
const b14 = (filter) => formsSum(formsFigures(SUBS, "2026-10-01", "2026-10-11", "day", { ...ALL_FORMS, ...filter }).filter((r) => r.groupKey === null)).submissions;
expect("forms: filters by market, category, none and form (75 B14)",
  [b14({ market: "unknown" }), b14({ category: "support" }), b14({ category: "none" }), b14({ form: `${FC}:f-cancel` })], [8, 6, 1, 4], [8, 6, 0, 3]);
expect("forms: the history start is the earliest business date in its zone; none without submissions (75 B15)",
  [formsHistoryStart(SUBS), formsHistoryStart([])], ["2026-09-20", null], ["2026-09-21", null]);

// the screen: formLines per form and market with the previous period, the forms with their markets, the totals
const totals = formsFigures(SUBS, "2026-10-05", "2026-10-11", "day", ALL_FORMS).filter((r) => r.groupKey === null);
const formLines = formsLines(totals, previousForms(SUBS, prevAfter, ALL_FORMS, "2026-10-20T09:00:00Z"));
expect("forms: the table's rows by form name, then market with unknown last, the previous period beside them",
  formLines.map((l) => `${l.formName}/${l.market}=${l.submissions}/${l.previous}`),
  ["Cancellation/DE=1/0", "Cancellation/GB=0/1", "Cancellation/NL=1/0", "Cancellation/unknown=1/0", "General support/unknown=6/0", "Legacy form/unknown=0/1", "NL Contact/NL=3/4"],
  ["Cancellation/DE=1/0", "Cancellation/NL=1/0", "Cancellation/unknown=1/0", "General support/unknown=6/0", "NL Contact/NL=3/4"]);
expect("forms: each form with its total over its markets, then its markets",
  formsTableGroups(formLines).map((g) => `${g.formName}:${g.total.submissions}/${g.total.previous}[${g.markets.map((m) => m.market).join(",")}]`),
  ["Cancellation:3/1[DE,GB,NL,unknown]", "General support:6/0[unknown]", "Legacy form:0/1[unknown]", "NL Contact:3/4[NL]"],
  ["Cancellation:3/0[DE,NL,unknown]", "General support:6/0[unknown]", "NL Contact:3/3[NL]"]);
const formCatalog = [{ code: "support", name: "Support", sortOrder: 5, isActive: true, forms: 1 }, { code: "contact", name: "Contact", sortOrder: 10, isActive: true, forms: 1 },
  { code: "cancellation", name: "Cancellation", sortOrder: 20, isActive: false, forms: 1 }];
expect("forms: totals per category in the catalog's order, forms without one last",
  formsByCategory(formLines, formCatalog).map((c) => `${c.code ?? "none"}:${c.name ?? "-"}=${c.submissions}/${c.previous}`),
  ["support:Support=6/0", "contact:Contact=3/4", "cancellation:Cancellation=3/1", "none:-=0/1"],
  ["cancellation:Cancellation=3/1", "contact:Contact=3/4", "none:-=0/1", "support:Support=6/0"]);
expect("forms: totals per market by code, unknown last",
  formsByMarket(formLines).map((m) => `${m.market}=${m.submissions}/${m.previous}`), ["DE=1/0", "GB=0/1", "NL=4/4", "unknown=7/1"], ["unknown=7/1", "DE=1/0", "GB=0/1", "NL=4/4"]);
const week5 = formsFigures(SUBS, "2026-10-05", "2026-10-11", "day", ALL_FORMS);
expect("forms: the chart's days up to today without gaps; weeks by their Monday",
  [formsSeries(week5, "day", "2026-10-05", "2026-10-11", "2026-10-08").map((c) => `${c.key.slice(8)}=${c.submissions}`).join(" "),
    formsSeries(formsFigures(SUBS, "2026-09-28", "2026-10-11", "week", ALL_FORMS), "week", "2026-09-28", "2026-10-11", "2026-10-20").map((c) => `${c.key}=${c.submissions}`).join(" ")],
  ["05=7 06=4 07=1 08=0", "2026-09-28=6 2026-10-05=12"], ["05=7 06=4 07=1", "2026-10-05=12"]);
expect("forms: the answers per form (markets summed), each question's values most answered first",
  answerGroups(b13rows).map((g) => `${g.formName}:${g.fields.map((f) => `${f.field}=${f.values.map((v) => `${v.value.slice(0, 3)}${v.submissions}/${v.previous}`).join(",")}`).join(";")}`),
  ["Cancellation:cancellation_reason=Pri2/0,Mov0/1;country_dropdown=Atl2/0,Net1/0,Uni0/1", "General support:hs_ticket_category=Dev2/0,Bil1/0,Del1/0",
    "Legacy form:product=aed0/1", `NL Contact:are_you_already_a_customer=${NO.slice(0, 3)}1/2,${YES.slice(0, 3)}1/1`],
  ["Cancellation:cancellation_reason=Mov0/1,Pri2/0", "General support:hs_ticket_category=Bil1/0,Del1/0,Dev2/0"]);
expect("forms: the share of contacts found, none without a submission", [resolvedShare(formsSum(totals)), resolvedShare(formsSum([]))], [0.25, null], [3 / 13, 0]);
const formsAnswer = { totals, previous: formLines, answers: b13rows };
const leaks = JSON.stringify(formsAnswer).match(/"(email|contact\w*|submissionId|sourceId|source_id|contactId)"\s*:/gi) ?? [];
expect("forms: no submission, contact or email address in an answer", leaks, [], ["\"email\":"]);

// ---- Email and Email per agent (addition 0008t) -------------------------------------------------------
// Fictional ids; a Monday-to-Friday 09:00-17:00 week in October 2026 (summer time until the 25th), NL in
// Amsterdam's zone, GB in London's
const EC = "00000000-0000-7000-8000-0000000000c1";
const emailCatalog = {
  inboxes: [{ id: "ib1", name: "Inbox A", isCounted: true, market: "NL" }, { id: "ib2", name: "Inbox B", isCounted: true, market: null },
    { id: "ib3", name: "Inbox C", isCounted: false, market: "NL" }],
  accounts: [{ id: "ac1", name: "5001", label: "Mailbox A", isCounted: true, market: "GB" }, { id: "ac2", name: "5002", label: null, isCounted: false, market: null }],
  channels: [{ id: "ch1", isCounted: true }, { id: "ch2", isCounted: false }],
  inboxCopyOrigins: ["origin_copy"], automatedOrigins: ["origin_auto"],
  zones: { NL: "Europe/Amsterdam", GB: "Europe/London" }, tenantZone: "Europe/Amsterdam",
  officeHours: { 1: ["09:00", "17:00"], 2: ["09:00", "17:00"], 3: ["09:00", "17:00"], 4: ["09:00", "17:00"], 5: ["09:00", "17:00"] },
  replyTargetMinutes: 240,
};
const eThread = (id, o) => ({ connectionId: EC, sourceSystem: "hubspot", id, inboxId: "ib1", accountId: null, channelId: "ch1", status: "open", isSpam: false,
  category: null, market: null, events: [], ...o });
const eMsg = (o) => ({ kind: "inbox_message", connectionId: EC, sourceSystem: "hubspot", threadId: null, inboxId: "ib1", accountId: null, channelId: "ch1",
  direction: "in", status: "sent", actorKind: "customer", ownerRef: null, origin: null, category: null, market: null, deleted: false, ...o });
const eLog = (o) => eMsg({ kind: "crm_email", threadId: null, inboxId: null, channelId: null, direction: "out", actorKind: "agent", ...o });
const emailThreads = [
  // reopened after its close: two openings; the reply to the second by an owner id without a person
  eThread("t1", { createdAt: "2026-10-12T08:00:00Z", category: "billing",
    events: [{ kind: "closed", at: "2026-10-12T14:00:00Z", actorKind: "agent", ownerRef: "101" }, { kind: "reopened", at: "2026-10-13T08:00:00Z", actorKind: "customer", ownerRef: null }] }),
  // through a mailbox with its own market (GB) on an inbox without one; a reopen at creation is no opening
  eThread("t2", { inboxId: "ib2", accountId: "ac1", createdAt: "2026-10-13T16:30:00Z",
    events: [{ kind: "reopened", at: "2026-10-13T16:31:00Z", actorKind: "system", ownerRef: null }] }),
  eThread("t3", { createdAt: "2026-10-13T09:00:00Z", isSpam: true }),
  eThread("t4", { inboxId: "ib3", createdAt: "2026-10-13T09:00:00Z" }),
  eThread("t5", { channelId: "ch2", createdAt: "2026-10-13T09:00:00Z" }),
  // no market from the chain, its inbox has none: unknown, no office hours
  eThread("t6", { inboxId: "ib2", createdAt: "2026-10-14T08:00:00Z" }),
  // through a mailbox that does not count
  eThread("t7", { accountId: "ac2", createdAt: "2026-10-13T09:00:00Z" }),
];
const emailMessages = [
  eMsg({ threadId: "t1", at: "2026-10-12T08:00:00Z" }),
  eMsg({ threadId: "t1", at: "2026-10-12T09:00:00Z", direction: "out", actorKind: "agent", ownerRef: "101" }),
  eMsg({ threadId: "t1", at: "2026-10-13T08:30:00Z" }),
  eMsg({ threadId: "t1", at: "2026-10-13T12:00:00Z", direction: "out", actorKind: "agent", ownerRef: "102" }),
  eMsg({ threadId: "t2", inboxId: "ib2", at: "2026-10-13T16:30:00Z" }),
  eMsg({ threadId: "t2", inboxId: "ib2", at: "2026-10-14T09:30:00Z", direction: "out", actorKind: "agent", ownerRef: "103" }),
  eMsg({ threadId: "t2", inboxId: "ib2", at: "2026-10-14T10:00:00Z" }),
  eMsg({ threadId: "t2", inboxId: "ib2", at: "2026-10-14T10:05:00Z", direction: "out", actorKind: "bot" }),
  eMsg({ threadId: "t3", at: "2026-10-13T09:00:00Z" }),
  eMsg({ threadId: "t4", inboxId: "ib3", at: "2026-10-13T09:00:00Z" }),
  eMsg({ threadId: "t5", channelId: "ch2", at: "2026-10-13T09:00:00Z" }),
  eMsg({ threadId: "t6", inboxId: "ib2", at: "2026-10-14T08:00:00Z" }),
  eMsg({ threadId: "t6", inboxId: "ib2", at: "2026-10-14T08:30:00Z", direction: "out", actorKind: "agent", ownerRef: "101" }),
  eMsg({ threadId: "t7", at: "2026-10-13T09:00:00Z" }),
  eLog({ at: "2026-10-12T10:00:00Z", ownerRef: "101", market: "NL" }),
  eLog({ at: "2026-10-12T10:10:00Z", origin: "ORIGIN_AUTO", market: "NL" }),
  eLog({ at: "2026-10-12T10:20:00Z", origin: "ORIGIN_COPY", ownerRef: "101", market: "NL" }),
  eLog({ at: "2026-10-12T10:30:00Z", direction: "in", actorKind: "customer", market: "NL" }),
  eLog({ at: "2026-10-12T10:40:00Z", status: "bounced", ownerRef: "101", market: "NL" }),
  eLog({ at: "2026-10-12T10:50:00Z", ownerRef: "101", market: "NL", deleted: true }),
  eLog({ at: "2026-10-13T11:00:00Z", ownerRef: "999" }),
];
const eRecs = emailRecords(emailMessages, emailThreads, emailCatalog);
const eOpen = emailOpenings(emailMessages, emailThreads, emailCatalog);
const eClose = emailCloses(emailThreads, emailCatalog);
const NO_FILTER = { market: null, inbox: null, account: null };
const eFig = emailFigures(emailInPeriod(eRecs, "2026-10-12", "2026-10-16", NO_FILTER), emailInPeriod(eOpen, "2026-10-12", "2026-10-16", NO_FILTER),
  emailInPeriod(eClose, "2026-10-12", "2026-10-16", NO_FILTER));
expect("email: received, logged replies, agent sends, automated and bounced as cma.email_of flags them (uncounted, spam, inbox copy and deleted out)",
  `${eFig.received}/${eFig.loggedReplies}/${eFig.sentAgent}/${eFig.sentAutomated}/${eFig.bouncedFailed}`, "5/1/6/2/1", "8/1/7/2/1");
expect("email: openings at creation and after a close, never a reopen at creation; closes",
  eOpen.map((o) => `${o.threadId}:${o.kind}`).join(" ") + ` | ${eClose.length}`, "t1:created t1:reopened t2:created t6:created | 1",
  "t1:created t1:reopened t2:created t2:reopened t6:created | 1");
expect("email: first replies in business seconds of the market's zone (out of hours, a mailbox's market, unknown has none) and elapsed",
  eOpen.map((o) => `${o.threadId}:${o.market}:${o.replySeconds}/${o.replyBusinessSeconds ?? "-"}/${o.replyWithinTarget ?? "-"}`).join(" "),
  "t1:NL:3600/3600/true t1:NL:12600/12600/true t2:GB:61200/5400/true t6:unknown:1800/-/-",
  "t1:NL:3600/3600/true t1:NL:12600/12600/true t2:NL:61200/1800/true t6:unknown:1800/1800/true");
expect("email: medians as percentile_cont, within target of those with office hours, no hours apart",
  `${eFig.replied} ${eFig.replyMedianSeconds} ${eFig.replyMedianBusinessSeconds} ${eFig.withinTarget}/${eFig.targetKnown} ${eFig.noHours} ${withinShare(eFig)}`,
  "4 8100 5400 3/3 1 1", "4 12600 5400 3/4 0 0.75");
expect("email: business seconds stop at closing time and skip the weekend; none for an unknown market",
  [businessSeconds(emailCatalog, "NL", "2026-10-16T14:00:00Z", "2026-10-19T08:00:00Z"), businessSeconds(emailCatalog, "XX", "2026-10-16T14:00:00Z", "2026-10-19T08:00:00Z")],
  [3600 + 3600, null], [237600, 0]);
const byInbox = emailGroups(emailInPeriod(eRecs, "2026-10-12", "2026-10-16", NO_FILTER), emailInPeriod(eOpen, "2026-10-12", "2026-10-16", NO_FILTER),
  emailInPeriod(eClose, "2026-10-12", "2026-10-16", NO_FILTER), "inbox");
expect("email: per inbox by name, none (the logged emails) last",
  byInbox.map((r) => `${r.groupLabel ?? "none"}=${r.received}/${r.sentAgent}/${r.threadsOpened}`), ["Inbox A=2/2/2", "Inbox B=3/2/2", "none=0/2/0"],
  ["none=0/2/0", "Inbox A=2/2/2", "Inbox B=3/2/2"]);
expect("email: per market by code, unknown included",
  emailGroups(eRecs, eOpen, eClose, "market").map((r) => `${r.groupKey}=${r.received + r.loggedReplies}/${r.sentAgent}`), ["GB=2/1", "NL=3/3", "unknown=1/2"],
  ["NL=3/3", "GB=2/1", "unknown=1/2"]);
expect("email: a filter narrows every figure alike (the mailbox's GB conversation only)",
  (() => { const f = { market: "GB", inbox: null, account: `${EC}:ac1` }; const x = emailFigures(emailInPeriod(eRecs, "2026-10-12", "2026-10-16", f), emailInPeriod(eOpen, "2026-10-12", "2026-10-16", f), []); return `${x.received}/${x.sentAgent}/${x.threadsOpened}`; })(),
  "2/1/1", "5/6/4");
expect("email: the previous period like for like stops at the time of day on its last date, in each row's zone",
  emailPrevious(eRecs, { from: "2026-10-12", to: "2026-10-13", partial: true }, NO_FILTER, "2026-10-20T10:00:00Z")
    .map((r) => `${r.date.slice(8)}T${r.localTime.slice(0, 5)}`).join(" "),
  "12T10:00 12T11:00 13T10:30 12T12:00 12T12:10 12T12:30 12T12:40", "12T10:00 12T11:00 13T10:30 13T14:00 13T17:30 12T12:00 12T12:10 12T12:30 12T12:40 13T13:00");
const eSeries = emailSeries(eRecs, "day", "inbox");
expect("email: received per date and inbox, by name", eSeries.map((r) => `${r.groupKey.slice(8)}:${r.seriesLabel}=${r.received}`),
  ["12:Inbox A=1", "13:Inbox A=1", "13:Inbox B=1", "14:Inbox B=2"], ["12:Inbox A=1", "13:Inbox B=1", "13:Inbox A=1", "14:Inbox B=2"]);
const manySeries = Array.from({ length: 8 }, (_, i) => ({ groupKey: "2026-10-12", seriesKey: `k${i}`, seriesLabel: `S${i}`, received: 10 - i }));
const eCols = seriesColumns(manySeries, "day", "2026-10-12", "2026-10-18", "2026-10-14");
expect("email: the five largest series in the style's order, the rest as Other; every date up to today",
  `${eCols.series.map((x) => x.index ?? "other").join(",")} ${eCols.values.get("2026-10-12|other")} ${eCols.keys.map((k) => k.slice(8)).join(",")}`,
  "0,1,2,3,4,other 12 12,13,14", "0,1,2,3,4,5,6,7 0 12,13,14,15,16,17,18");
const ePeople = { "101": { userId: "u1", name: "Anna Example" }, "103": { userId: "u3", name: "Bram Example" } };
const ePerPerson = emailPerPerson(emailInPeriod(eRecs, "2026-10-12", "2026-10-16", NO_FILTER), emailInPeriod(eOpen, "2026-10-12", "2026-10-16", NO_FILTER),
  emailInPeriod(eClose, "2026-10-12", "2026-10-16", NO_FILTER), (_s, ref) => (ref ? ePeople[ref] ?? null : null));
expect("email per agent: by name, never ranked; owner ids without a person as one row with how many, last; the total",
  ePerPerson.rows.map((p) => `${p.name ?? `not linked (${p.unlinkedOwners})`}=${p.sent}/${p.replies}/${p.threadsClosed}`).join(" ")
    + ` | ${ePerPerson.total.sent}/${ePerPerson.total.replies}/${ePerPerson.total.threadsClosed}`,
  "Anna Example=3/2/1 Bram Example=1/1/0 not linked (2)=2/1/0 | 6/4/1", "Anna Example=3/2/1 not linked (2)=2/1/0 Bram Example=1/1/0 | 6/4/1");
expect("email per agent: sends by hour of the day in the email's market zone",
  ePerPerson.rows[0].sentByHour.map((v, h) => (v ? `${h}:${v}` : "")).filter(Boolean).join(" "), "10:1 11:1 12:1", "8:1 9:1 10:1");
const eWait = emailWaiting(emailMessages, emailThreads, emailCatalog, "2026-10-14T12:00:00Z");
expect("email: waiting now since the first incoming message after the last agent reply (a bot's message is no reply), in business time; an uncounted mailbox not",
  eWait.map((w) => `${w.threadId}:${w.market}:${w.waitedSeconds}/${w.waitedBusinessSeconds}`), ["t2:GB:7200/7200"], ["t2:GB:6900/6900", "t7:NL:97200/28800"]);
expect("email: groups and filters as the database takes them",
  [parseEmailGroup("week"), parseEmailGroup("month"), nextEmailGroup("day"), nextEmailGroup("week"),
    JSON.stringify(parseEmailFilter("NL", `${EC}:ib1`, " ")), parseEmailFilter("nl", null, null).problem, parseEmailFilter(null, "a@b", null).problem,
    JSON.stringify(emailFilterQuery({ market: "unknown", inbox: null, account: `${EC}:ac1` }))],
  ["week", null, "week", "day", JSON.stringify({ filter: { market: "NL", inbox: `${EC}:ib1`, account: null }, problem: null }), "market", "inbox",
    JSON.stringify({ market: "unknown", account: `${EC}:ac1` })],
  ["week", "month", "day", "week", "", null, null, ""]);
expect("email per agent: the permission and the tenant's switch, both",
  [perPersonOpen({ permissions: ["performance.team"], perPerson: ["email"] }, "email"), perPersonOpen({ permissions: ["performance.team"], perPerson: ["orders"] }, "email"),
    perPersonOpen({ permissions: ["reports.view"], perPerson: ["email"] }, "email")], [true, false, false], [true, true, true]);
const emailLeaks = JSON.stringify({ rows: ePerPerson.rows, waiting: eWait, groups: byInbox }).match(/"(subject|body|address|from|to|sender|recipient|ownerRef|email|phone)"\s*:/gi) ?? [];
expect("email: no subject, address, owner id or phone number in an answer", emailLeaks, [], ["\"ownerRef\":"]);

// ---- First orders and Orders per person (addition 0008u) ---------------------------------------------
// 85's scenario: tenant one's order deals of the week of 5 to 11 October 2026 with what the database finds around
// them (the touches in the window, the linked order, the contact's creation time); owners 101 Anna and 103 Bram, 102
// nobody, telephony user u1 Anna
const FO = "00000000-0000-7000-8000-0000000000c1";
const foSettings = { windowDays: 90, levelOrder: ["lead_deal", "conversation", "email", "phone_match", "attempt", "known_contact"],
  assistedLevels: ["lead_deal", "conversation", "email", "phone_match"], knownContactMinutes: 60, orderMatchMinutes: 1440 };
const foPeople = { "verifycrm_owner:101": { userId: "anna", name: "Anna Verify" }, "verifycrm_owner:103": { userId: "bram", name: "Bram Verify" },
  "verifytel_user:u1": { userId: "anna", name: "Anna Verify" } };
const foPersonOf = (system, ref) => foPeople[`${system}:${ref}`] ?? null;
const foNames = { anna: "Anna Verify", bram: "Bram Verify" };
const ord = (id, at, market, o = {}) => ({ connectionId: FO, dealSourceId: id, createdAt: at, market, zone: market === "GB" ? "Europe/London" : "Europe/Amsterdam",
  contact: `k-${id}`, earlierOrderDeal: false, storeOrderKind: null, currency: null, amount: null, phoneHashed: false, contactCreatedAt: null, touches: [],
  recordUrl: `https://crm.example.invalid/portal-1/deal/${id}`, ...o });
const tch = (kind, at, system, ownerRef) => ({ kind, at, system, ownerRef });
const crm = "verifycrm_owner";
const foDeals = [
  ord("o1", "2026-10-05T10:00:00.000Z", "NL", { storeOrderKind: "first", currency: "EUR", amount: 100, contactCreatedAt: "2026-01-01T00:00:00.000Z",
    touches: [tch("lead_deal", "2026-10-02T08:00:00.000Z", crm, "101"), tch("email", "2026-10-04T09:00:00.000Z", crm, "103")] }),
  ord("o2", "2026-10-06T09:00:00.000Z", "GB", { storeOrderKind: "first", currency: "GBP", amount: 50, contactCreatedAt: "2026-10-06T08:30:00.000Z",
    touches: [tch("conversation", "2026-10-01T08:00:10.000Z", crm, "103")] }),
  ord("o3", "2026-10-07T12:00:00.000Z", "NL", { currency: "EUR", amount: 70, contactCreatedAt: "2026-10-07T11:30:00.000Z",
    touches: [tch("email", "2026-10-06T12:00:00.000Z", crm, "102")] }),
  ord("o4", "2026-10-08T12:00:00.000Z", "NL", { storeOrderKind: "first", currency: "EUR", amount: 40, contactCreatedAt: "2025-12-01T00:00:00.000Z" }),
  ord("o5", "2026-10-08T14:00:00.000Z", "NL", { storeOrderKind: "first", currency: "EUR", amount: 30, phoneHashed: true, contactCreatedAt: "2026-10-08T13:30:00.000Z",
    touches: [tch("phone_match", "2026-09-28T10:00:00.000Z", crm, "101"), tch("phone_match", "2026-10-07T10:00:00.000Z", "verifytel_user", "u1")] }),
  ord("o6", "2026-10-09T09:00:00.000Z", "NL", { contactCreatedAt: "2026-10-09T08:30:00.000Z", touches: [tch("attempt", "2026-10-08T09:00:00.000Z", crm, "101")] }),
  ord("o7", "2026-10-09T15:00:00.000Z", "NL", { contactCreatedAt: "2026-10-09T14:00:00.000Z" }),
  ord("o8", "2026-10-10T10:00:00.000Z", "NL", { contact: null, currency: "EUR", amount: 25 }),
  ord("o9", "2026-10-10T12:00:00.000Z", "NL", { earlierOrderDeal: true, storeOrderKind: "repeat", currency: "EUR", amount: 20 }),
  ord("o10", "2026-10-11T09:00:00.000Z", "NL", { storeOrderKind: "renewal", currency: "EUR", amount: 15 }),
  ord("o11", "2026-10-11T10:00:00.000Z", "NL", { storeOrderKind: "repeat", currency: "EUR", amount: 60 }),
  // a lead deal exactly at the window's start counts; an email a second before it and one at T do not
  ord("o13", "2026-10-06T15:00:00.000Z", "NL", { contactCreatedAt: "2026-10-06T14:30:00.000Z",
    touches: [tch("lead_deal", "2026-07-08T15:00:00.000Z", crm, "101"), tch("email", "2026-07-08T14:59:59.000Z", crm, "103"), tch("email", "2026-10-06T15:00:00.000Z", crm, "103")] }),
  ord("o14", "2026-10-07T15:00:00.000Z", "NL", { contactCreatedAt: "2026-10-07T14:59:00.000Z",
    touches: [tch("lead_deal", "2026-10-07T15:00:00.000Z", crm, "101"), tch("lead_deal", "2026-07-09T14:59:59.000Z", crm, "101")] }),
];
const foRecs = firstOrderRecords(foDeals, foSettings, foPersonOf);
const foWeek = firstOrdersInPeriod(foRecs, "2026-10-05", "2026-10-11", { market: null, level: null });
const foById = (recs) => [...recs].sort((a, b) => a.dealSourceId.localeCompare(b.dealSourceId));
expect("first orders: the kinds, as 85 B5 (no contact, repeat, renewal, not first)",
  foById(foRecs).map((r) => `${r.dealSourceId}:${r.kind}`).join(" "),
  "o1:first o10:renewal o11:not_first o13:first o14:first o2:first o3:first o4:first o5:first o6:first o7:first o8:no_contact o9:repeat",
  "o1:first o10:renewal o11:repeat o13:first o14:first o2:first o3:first o4:first o5:first o6:first o7:first o8:first o9:not_first");
expect("first orders: every flag at the window's edges, a known contact at exactly an hour, as 85 B7",
  foById(foRecs.filter((r) => r.kind === "first")).map((r) => `${r.dealSourceId}:${["lead_deal", "conversation", "email", "phone_match", "attempt", "known_contact"].map((e) => Number(r.evidence[e])).join("")}`).join(" "),
  "o1:101001 o13:100000 o14:000000 o2:010000 o3:001000 o4:000001 o5:000100 o6:000010 o7:000001",
  "o1:101001 o13:101000 o14:100000 o2:010000 o3:001000 o4:000000 o5:000100 o6:000010 o7:000000");
expect("first orders: the level, the attribution and the credited person (the latest assisted touch, a telephony user, not linked), as 85 B8",
  foById(foRecs.filter((r) => r.kind === "first")).map((r) => `${r.dealSourceId}:${r.level}:${r.attribution}:${r.creditedUserId ?? (r.creditedOwnerRef ? "not linked" : "-")}`).join(" "),
  "o1:lead_deal:call_center:bram o13:lead_deal:call_center:anna o14:self_service:self_service:- o2:conversation:call_center:bram o3:email:call_center:not linked "
    + "o4:known_contact:self_service:- o5:phone_match:call_center:anna o6:attempt:self_service:- o7:known_contact:self_service:-",
  "o1:lead_deal:call_center:anna o13:lead_deal:call_center:anna o14:self_service:self_service:- o2:conversation:call_center:bram o3:email:call_center:- "
    + "o4:known_contact:self_service:- o5:phone_match:call_center:anna o6:attempt:call_center:anna o7:known_contact:self_service:-");
expect("first orders: days from the first touch, as 85 B9",
  foById(foRecs.filter((r) => r.kind === "first")).map((r) => `${r.dealSourceId}:${r.daysFromFirstTouch ?? "-"}`).join(" "),
  "o1:3.08 o13:90 o14:- o2:5.04 o3:1 o4:- o5:10.17 o6:1 o7:-", "o1:2.04 o13:90 o14:0 o2:5.04 o3:1 o4:- o5:0.17 o6:1 o7:-");
const foChanged = firstOrderRecords(foDeals, { ...foSettings, levelOrder: ["email", "lead_deal", "conversation", "phone_match", "attempt", "known_contact"],
  assistedLevels: ["lead_deal"] }, foPersonOf);
expect("first orders: the level order and the assisted set are configuration, as 85 B10",
  foById(foChanged.filter((r) => ["o1", "o2", "o3", "o5", "o13"].includes(r.dealSourceId))).map((r) => `${r.dealSourceId}:${r.level}:${r.attribution}`).join(" "),
  "o1:email:self_service o13:lead_deal:call_center o2:conversation:self_service o3:email:self_service o5:phone_match:self_service",
  "o1:lead_deal:call_center o13:lead_deal:call_center o2:conversation:call_center o3:email:call_center o5:phone_match:call_center");
const foFig = (f) => `${f.firstOrders}:${f.callCenter}/${f.selfService}:${f.repeats}/${f.renewals}/${f.notFirst}/${f.noContact}:${f.daysMedian ?? "-"}`;
expect("first orders: the total, per level and per market, as 85 B11",
  [foFig(firstOrderFigures(foWeek)), firstOrderGroups(foWeek, "level").map((r) => `${r.groupKey}=${foFig(r)}`).join(" "),
    firstOrderGroups(foWeek, "market").map((r) => `${r.groupKey}=${foFig(r)}`).join(" ")],
  ["9:5/4:1/1/1/1:4.1", "attempt=1:0/1:0/0/0/0:1 conversation=1:1/0:0/0/0/0:5 email=1:1/0:0/0/0/0:1 known_contact=2:0/2:0/0/0/0:- lead_deal=2:2/0:0/0/0/0:46.5 "
    + "phone_match=1:1/0:0/0/0/0:10.2 self_service=1:0/1:0/0/0/0:-", "GB=1:1/0:0/0/0/0:5 NL=8:4/4:1/1/1/1:3.1"],
  ["9:5/4:1/1/1/1:4.1", "", ""]);
expect("first orders: a level filter keeps that level's first orders and nothing counted apart",
  foFig(firstOrderFigures(firstOrdersInPeriod(foRecs, "2026-10-05", "2026-10-11", { market: null, level: "lead_deal" }))), "2:2/0:0/0/0/0:46.5", "2:2/0:1/1/1/1:46.5");
expect("first orders: amounts per currency, never summed across, as 85 B12",
  [...firstOrderAmounts(foWeek, false), ...firstOrderAmounts(foWeek, true)].map((a) => `${a.market ?? "*"}/${a.currency ?? "none"}=${a.orders}:${a.amount ?? "-"}:${a.callCenterAmount}:${a.selfServiceAmount}`).join(" "),
  "*/EUR=4:240:200:40 */GBP=1:50:50:0 */none=4:-:0:0 GB/GBP=1:50:50:0 NL/EUR=4:240:200:40 NL/none=4:-:0:0",
  "*/EUR=5:290:250:40 */none=4:-:0:0 GB/GBP=1:50:50:0 NL/EUR=4:240:200:40");
const foList = firstOrderList(foWeek, 2);
expect("first orders: the list newest first, capped, with the total, as 85 B15",
  `${foList.rows.map((r) => `${r.dealSourceId}:${r.level}`).join(" ")} ${foList.total}`, "o7:known_contact o6:attempt 9", "o1:lead_deal o2:conversation 9");
const foPeopleRows = ordersPerPerson(foWeek, (id) => foNames[id] ?? null);
expect("orders per person: by name, never ranked; the not-linked row; the total, as 85 B16",
  [...foPeopleRows.rows, foPeopleRows.total].map((p) => `${p.name ?? `${p.kind}(${p.unlinkedOwners ?? "-"})`}:${p.orders}:${p.leadDeal}/${p.conversation}/${p.email}/${p.phoneMatch}:${p.daysMedian ?? "-"}`).join(" "),
  "Anna Verify:2:1/0/0/1:50.1 Bram Verify:2:1/1/0/0:4.1 notLinked(1):1:0/0/1/0:1 total(-):5:2/1/1/1:5",
  "Bram Verify:2:1/1/0/0:4.1 Anna Verify:2:1/0/0/1:50.1 total(-):5:2/1/1/1:5");
expect("first orders: the previous span stops at the time of day on its last date in each deal's zone",
  firstOrdersInPeriod(foRecs, "2026-10-05", "2026-10-07", { market: null, level: null }, "2026-10-20T13:30:00.000Z").map((r) => r.dealSourceId).join(" "),
  "o1 o2 o3 o13", "o1 o2 o3 o13 o14");
expect("first orders: groups, filters and the share as the database takes them",
  [parseFirstOrderGroup("level"), parseFirstOrderGroup("month"), nextFirstOrderGroup("level"), JSON.stringify(parseFirstOrderFilter("GB", "phone_match")),
    parseFirstOrderFilter("gb", null).problem, parseFirstOrderFilter(null, "phone").problem, JSON.stringify(firstOrderFilterQuery({ market: "unknown", level: "self_service" })),
    callCenterShare({ callCenter: 5, firstOrders: 9 }) === 5 / 9, callCenterShare({ callCenter: 0, firstOrders: 0 }),
    levelsInOrder({ levelOrder: ["email", "lead_deal"] }).join(",")],
  ["level", null, "day", JSON.stringify({ filter: { market: "GB", level: "phone_match" }, problem: null }), "market", "level",
    JSON.stringify({ market: "unknown", level: "self_service" }), true, null, "email,lead_deal,conversation,phone_match,attempt,known_contact,self_service"],
  ["level", "month", "week", "", null, null, "", false, 0, "email,lead_deal"]);
const foLeaks = JSON.stringify({ list: foList, people: foPeopleRows }).match(/"(name|firstName|lastName|address|email_address|phone|phoneNumber|phoneHash|contact\w*)"\s*:/gi) ?? [];
expect("first orders: no customer name, address or phone number in an answer (a staff name only)", foLeaks.filter((x) => !/"name"/.test(x)), [], ["\"phone\":"]);

// ---- formats -----------------------------------------------------------------------------------
expect("business minutes: decimals under an hour, hours from an hour, a dash for none",
  [fmtBusinessMinutes(7.5, "en"), fmtBusinessMinutes(7.5, "nl"), fmtBusinessMinutes(74.8, "en"), fmtBusinessMinutes(null, "en")],
  ["7.5 min", "7,5 min", "1h 15m", "–"], ["7.5 min", "7.5 min", "74.8 min", "0"]);
expect("percentages whole, small shares not zero, a dash for none",
  [fmtPct(40, "en"), fmtPct(66.7, "nl"), fmtPct(0.3, "en"), fmtPct(0, "en"), fmtPct(null, "en")],
  ["40%", "67%", "< 1%", "0%", "–"], ["40%", "66,7%", "0%", "0%", "0%"]);
expect("counts with the locale's grouping", [fmtCount(1234, "en"), fmtCount(1234, "nl")], ["1,234", "1.234"], ["1234", "1234"]);

// ---- Callbacks kept (addition 0008w, brief N19-A part 4) on 89's own scenario --------------------------
// The callback tasks of a counted callback type that 89 keeps (k7 of an uncounted type, k8 not a callback and the deleted
// k9 never reach the definition), the calls with their contacts in either direction (l10's association removed, so no
// call of c10), the window set to 60 minutes, in Europe/Amsterdam
const cbTasks = [
  ["k1", "2026-10-06T10:00:00Z", "c1", "101"], ["k2", "2026-10-06T12:00:00Z", "c2", "101"], ["k3", "2026-10-07T09:00:00Z", "c3", "103"],
  ["k4", "2026-10-07T12:00:00Z", "c4", "102"], ["k5", "2026-10-08T09:00:00Z", null, "101"], ["k6", null, "c6", "101", "2026-10-08T10:00:00Z"],
  ["k10", "2026-10-11T21:30:00Z", "c10", "103"], ["k11", "2026-09-30T10:00:00Z", "c11", "101"], ["k12", "2026-10-01T10:00:00Z", "c12", "101"],
  ["k13", "2026-10-02T08:00:00Z", "c13", "101"], ["k14", "2026-10-09T07:00:00Z", "c14", "103"], ["k15", "2026-10-08T13:00:00Z", "c15", "101"],
].map(([id, dueAt, contactId, ownerRef, createdAt]) => ({ id, dueAt, contactId, ownerRef, createdAt: createdAt ?? "2026-09-20T09:00:00Z" }));
const cbCalls = [
  ["c1", "2026-10-06T10:30:00Z", "outbound"], ["c2", "2026-10-06T13:00:00Z", "unknown"], ["c3", "2026-10-07T10:01:00Z", "outbound"],
  ["c15", "2026-10-08T13:20:00Z", "inbound"], ["c4", "2026-10-07T11:00:00Z", "outbound"], ["c4", "2026-10-07T11:30:00Z", "outbound"],
  ["c11", "2026-09-30T10:00:00Z", "outbound"], ["c12", "2026-10-01T12:00:00Z", "outbound"], ["c13", "2026-10-02T08:10:00Z", "outbound"],
].map(([contactId, at, direction]) => ({ contactId, at, direction }));
const cbAfter = new Date("2026-10-20T09:00:00Z");
const cbRunning = new Date("2026-10-09T07:30:00Z");
const cbRecs = callbackRecords(cbTasks, cbCalls, 60, cbAfter, "Europe/Amsterdam");
const cbWeek = callbacksInPeriod(cbRecs, "2026-10-05", "2026-10-11");
expect("callbacks: the week's states and minutes, as 89's B1",
  [...cbWeek].sort((a, b) => Date.parse(cbTasks.find((t) => t.id === a.id).dueAt ?? cbTasks.find((t) => t.id === a.id).createdAt)
    - Date.parse(cbTasks.find((t) => t.id === b.id).dueAt ?? cbTasks.find((t) => t.id === b.id).createdAt)).map((r) => `${r.id}:${r.state}:${r.minutesFromDue ?? "-"}`).join(" "),
  "k1:kept:30 k2:kept:60 k3:not_kept:- k4:kept:-60 k5:no_contact:- k6:no_due:- k15:kept:20 k14:not_kept:- k10:not_kept:-",
  "k1:kept:30 k2:kept:60 k3:kept:61 k4:kept:-60 k5:no_contact:- k6:no_due:- k15:kept:20 k14:not_kept:- k10:not_kept:-");
expect("callbacks: the window moves with the setting (240: k3 kept), as 89's B3",
  callbackRecords(cbTasks, cbCalls, 240, cbAfter, "Europe/Amsterdam").find((r) => r.id === "k3").state, "kept", "not_kept");
expect("callbacks: pending while the window is open, not kept after, as 89's B4",
  [callbackRecords(cbTasks, cbCalls, 60, cbRunning, "Europe/Amsterdam").find((r) => r.id === "k14").state,
    callbackRecords(cbTasks, cbCalls, 60, new Date("2026-10-09T08:01:00Z"), "Europe/Amsterdam").find((r) => r.id === "k14").state],
  ["pending", "not_kept"], ["not_kept", "not_kept"]);
const cbFig = (c) => `${c.callbacks}/${c.kept}/${c.notKept}/${c.pending}/${c.noContact}/${c.noDue}`;
const cbFigures = callbackFigures(cbWeek);
expect("callbacks: per ISO week and in total, as 89's B6 (Sunday 23:30 in Amsterdam in its week)",
  [cbFigures.weeks.map((w) => `${w.weekStart}:${cbFig(w)}`).join(" "), cbFig(cbFigures.total)],
  ["2026-10-05:7/4/3/0/1/1", "7/4/3/0/1/1"], ["2026-10-12:1/0/1/0/0/0 2026-10-05:6/4/2/0/1/1", "7/4/3/0/1/1"]);
const cbRunRecs = callbackRecords(cbTasks, cbCalls, 60, cbRunning, "Europe/Amsterdam");
expect("callbacks: the previous week in full, and up to the time of day while the period runs, as 89's B7",
  [cbFig(callbackFigures(callbacksInPeriod(cbRecs, "2026-09-28", "2026-10-04")).total),
    cbFig(callbackFigures(callbacksInPeriod(cbRunRecs, "2026-10-05", "2026-10-11")).total),
    cbFig(callbackFigures(callbacksInPeriod(cbRunRecs, "2026-09-28", "2026-10-02", "09:30:00")).total)],
  ["3/2/1/0/0/0", "7/4/1/2/1/1", "2/1/1/0/0/0"], ["3/2/1/0/0/0", "7/4/1/2/1/1", "3/2/1/0/0/0"]);
const cbNames = { "101": { userId: "u-anna", name: "Anna Verify" }, "103": { userId: "u-bram", name: "Bram Verify" } };
const cbOwners = callbacksPerOwner(cbWeek, (ref) => cbNames[ref] ?? null);
expect("callbacks: per person by name with the not-linked row and the total, as 89's B8",
  [...cbOwners.rows, cbOwners.total].map((o) => `${o.name ?? o.kind}${o.unlinkedOwners ? `(${o.unlinkedOwners})` : ""}:${o.callbacks}/${o.kept}/${o.notKept}/${o.noContact}`).join(" "),
  "Anna Verify:3/3/0/1 Bram Verify:3/0/3/0 notLinked(1):1/1/0/0 total:7/4/3/1",
  "Bram Verify:3/0/3/0 Anna Verify:3/3/0/1 notLinked(1):1/1/0/0 total:7/4/3/1");
expect("callbacks: the kept share leaves pending out; none decided is no share",
  [keptShare({ kept: 3, notKept: 1 }), keptShare({ kept: 0, notKept: 0 })], [0.75, null], [0.6, 0]);
expect("callbacks: Follow-up's span is this week and the seven before",
  callbackWeeksRange("2026-10-18"), { from: "2026-08-24", to: "2026-10-18" }, { from: "2026-08-31", to: "2026-10-18" });

// ---- Attempts per deal and Attempts per agent (addition 0008y; for sales since 0008z) on 95's own scenario -------------
// Tenant one's deals of the week of 5 to 11 October 2026 and dP of the week before, each with the CRM calls the database
// finds for it (on the deal or its current contacts, so dA's call on the contact no longer associated is not there), the
// linked telephony call's start (10 seconds before the CRM call), answered and talk time, and its contacts' first orders
// after its creation (a won order deal at its close, a store order at its creation; dS's test, cancelled and deleted store
// orders never reach the definition, dB's store order before its creation and dA's order deal on the removed contact do
// not count). The order pipeline's dOrd, the renewals (counted, no lead pipeline) and the uncounted test pipeline are here
// to be left out. NL in Amsterdam, offices Monday to Friday 09:00 to 17:00, no holiday; owners o-1 Anna and o-2 Bram, o-3
// nobody; the pre-window 10 minutes; a conversation at 30 seconds of talk, the outcome deciding nothing (0008zc); seen on Wednesday 14 October at
// 10:00 UTC. Amsterdam is UTC+2 throughout.
const AT = "00000000-0000-7000-8000-0000000000a7";
const AMS_AT = "Europe/Amsterdam";
const AT_PIPES = { sales: "Sales", selfserve: "Self Serve", renew: "Renewals", test: "Test" };
const atT = (x) => `2026-${x}Z`;
// a CRM call: [id, CRM time, outcome, linked, talk (null: unanswered), agent]; a linked call starts 10 s earlier
const atCall = ([id, crmAt, outcome, linked, talk, agent]) => ({
  id, at: linked ? new Date(Date.parse(atT(crmAt)) - 10_000).toISOString().replace(".000Z", "Z") : atT(crmAt), direction: "outbound", linked,
  outcome: { connected: "Connected", no_answer: "No answer", voicemail: "Left voicemail" }[outcome] ?? null,
  connected: linked && talk !== null, talkSeconds: linked ? talk : null, agentName: linked ? agent : null,
});
const atDeal = (id, pipeline, created, o = {}) => ({
  dealId: `deal-${id}`, connectionId: AT, dealSourceId: id, pipelineId: pipeline, pipelineLabel: AT_PIPES[pipeline],
  stageLabel: o.stageOutcome === "won" ? "Won" : o.stageOutcome === "lost" ? "Lost" : o.isClosed ? "Closed" : "Open",
  isLead: pipeline !== "renew" && pipeline !== "test", isOrder: pipeline === "selfserve", isCounted: pipeline !== "test",
  market: "NL", zone: AMS_AT, ownerRef: null, createdAt: atT(created), isClosed: false, closedAt: null, stageOutcome: null,
  recordUrl: `https://crm.example.invalid/portal-1/deal/${id}`, calls: [], orders: [], ...o,
});
const atClosed = (when, outcome) => ({ isClosed: true, closedAt: atT(when), stageOutcome: outcome });
const ANNA = "Anna Verify";
const BRAM = "Bram Verify";
const atDeals = [
  atDeal("dP", "sales", "09-30T08:00:00", { ownerRef: "o-1", ...atClosed("10-01T08:00:00", "won"), calls: [["cp1", "09-30T08:10:00", "connected", true, 60, ANNA]].map(atCall) }),
  atDeal("dW", "sales", "10-05T08:00:00", { ownerRef: "o-1", ...atClosed("10-08T12:00:00", "won"), calls: [
    ["cw1", "10-05T08:05:00", "no_answer", true, null, ANNA], ["cw2", "10-05T09:00:00", null, true, 29, ANNA], ["cwh", "10-05T10:00:00", null, false, null, null],
    ["cw3", "10-06T09:00:00", null, true, 30, ANNA], ["cw4", "10-07T09:00:00", "connected", true, 5, BRAM], ["cw5", "10-09T09:00:00", "connected", true, 60, ANNA]].map(atCall) }),
  atDeal("dW2", "sales", "10-05T12:00:00", { ownerRef: "o-1", ...atClosed("10-09T10:00:00", "won"), calls: [["cw21", "10-06T07:30:00", "connected", true, 300, ANNA]].map(atCall) }),
  atDeal("dL", "sales", "10-05T09:00:00", { ownerRef: "o-2", ...atClosed("10-07T15:00:00", "lost"), calls: [
    ["cl1", "10-05T10:00:00", "voicemail", true, 90, ANNA], ["cl2", "10-06T10:00:00", null, true, 0, ANNA], ["cl3", "10-08T09:00:00", "connected", true, 60, ANNA]].map(atCall),
    orders: [{ createdAt: atT("10-08T10:00:00"), at: atT("10-08T10:00:00") }] }),
  atDeal("dL2", "sales", "10-06T12:00:00", { ownerRef: "o-3", ...atClosed("10-08T13:00:00", "lost") }),
  atDeal("dO", "sales", "10-06T08:00:00", { ownerRef: "o-1", calls: [["co1", "10-06T08:30:00", "connected", true, 60, ANNA], ["co2", "10-08T09:00:00", "connected", true, 60, ANNA]].map(atCall),
    orders: [{ createdAt: atT("10-07T10:00:00"), at: atT("10-07T10:00:00") }] }),
  atDeal("dS", "sales", "10-06T09:00:00", { ownerRef: "o-1", calls: [["cs1", "10-07T10:00:00", null, true, 45, ANNA], ["cs2", "10-09T09:00:00", null, true, 45, ANNA]].map(atCall),
    orders: [{ createdAt: atT("10-08T10:00:00"), at: atT("10-08T10:00:00") }] }),
  atDeal("dB", "sales", "10-07T08:00:00", { ownerRef: "o-2", calls: [["cb1", "10-08T09:00:00", "no_answer", true, null, ANNA]].map(atCall),
    orders: [{ createdAt: atT("10-05T10:00:00"), at: atT("10-05T10:00:00") }, { createdAt: atT("10-04T10:00:00"), at: atT("10-04T10:00:00") }] }),
  atDeal("dA", "sales", "10-07T09:00:00", { ownerRef: "o-2", calls: [["ca1", "10-09T09:00:00", null, true, null, ANNA]].map(atCall) }),
  atDeal("dT", "sales", "10-08T08:00:00", { calls: [["ct0", "10-08T08:02:00", null, false, null, null], ["ct1", "10-08T09:30:00", null, true, 10, ANNA]].map(atCall) }),
  atDeal("dN", "sales", "10-09T08:30:00", { ownerRef: "o-3" }),
  atDeal("dU", "sales", "10-09T09:00:00", { ...atClosed("10-09T11:00:00", null), calls: [["cu1", "10-09T09:30:00", "connected", true, 120, ANNA]].map(atCall) }),
  atDeal("dOrd", "selfserve", "10-07T10:00:00", { ...atClosed("10-07T10:00:00", "won") }),
  atDeal("dRen", "renew", "10-06T10:00:00", { ownerRef: "o-1", calls: [["cren", "10-06T11:00:00", "connected", true, 60, ANNA]].map(atCall) }),
  atDeal("dTest", "test", "10-06T10:00:00", { ownerRef: "o-1", calls: [["ctst", "10-06T11:00:00", "connected", true, 60, ANNA]].map(atCall) }),
];
const atHours = { zones: { NL: AMS_AT }, officeHours: { 1: ["09:00", "17:00"], 2: ["09:00", "17:00"], 3: ["09:00", "17:00"], 4: ["09:00", "17:00"], 5: ["09:00", "17:00"] } };
const atWorking = (market, date) => market === "NL" && Boolean(atHours.officeHours[new Date(`${date}T12:00:00Z`).getUTCDay() || 7]);
const atNoon = (market, when) => {
  if (market !== "NL") return null;
  let d = addDays(dateKeyInZone(when, AMS_AT), 1);
  while (!atWorking(market, d)) d = addDays(d, 1);
  return new Date(zonedInstant(d, "12:00", AMS_AT)).toISOString();
};
const atOwners = { "o-1": "u-anna", "o-2": "u-bram" };
const atNames = { "u-anna": ANNA, "u-bram": BRAM };
const AT_NOW = "2026-10-14T10:00:00Z";
const atOptions = (o = {}) => ({
  source: "telephony", preWindowMinutes: 10, conversationMinTalkSeconds: 30, sinceLastBuckets: "1,2,5", now: AT_NOW, tenantZone: AMS_AT, working: atWorking,
  ownerUserOf: (r) => atOwners[r] ?? null, businessSeconds: (market, from, to) => businessSeconds(atHours, market, from, to), nextNoon: atNoon, ...o,
});
const AT_ALL = { market: null, pipeline: null, attempted: "all", outcome: "all" };
const atWeek = (o = {}, filter = AT_ALL) => attemptsInPeriod(attemptRecords(atDeals, atOptions(o)), "2026-10-05", "2026-10-11", filter, null, AMS_AT);
const byId = (rows) => [...rows].sort((a, b) => (a.dealSourceId < b.dealSourceId ? -1 : a.dealSourceId > b.dealSourceId ? 1 : 0));
const atDealOf = (id) => atDeals.find((d) => d.dealSourceId === id);
const hms = (x) => (x ? `${x.slice(8, 10)} ${x.slice(11, 19)}` : "-");
// as 95's pg_temp.v0008z_fig
const atFig = (f) => [f.deals, f.attempted, f.attempts, f.avgAttempts === null ? "-" : f.avgAttempts.toFixed(2), f.medianAttempts === null ? "-" : f.medianAttempts.toFixed(1),
  f.conversationDeals, f.firstConversation, f.medianSpeedSeconds ?? "-", `${f.calledBeforeNoon}of${f.noonKnown}`, f.openDeals, f.openNeverAttempted, f.won, f.lost, f.ordered,
  f.unknown, f.talkSecondsTotal, f.talkSecondsConversation, f.attemptsWithoutOutcome, f.loggedWithoutAircall].join("/");

expect("attempts: the four groups parse, anything else is refused (the routes' 400)",
  ["day", "week", "market", "pipeline", "owner", "", null, "Day"].map(parseAttemptGroup),
  ["day", "week", "market", "pipeline", null, null, null, null], ["day", "week", "market", "pipeline", "owner", null, null, "day"]);
expect("attempts: G cycles day, week, market, pipeline and back",
  ["day", "week", "market", "pipeline"].map(nextAttemptGroup), ["week", "market", "pipeline", "day"], ["week", "market", "pipeline", "pipeline"]);
const atParsed = (m, p, a, o) => { const x = parseAttemptFilter(m, p, a, o); return `${x.problem ?? "ok"}:${x.filter.market ?? "-"}/${x.filter.pipeline ?? "-"}/${x.filter.attempted}/${x.filter.outcome}`; };
expect("attempts: the filters as the database checks them; a bad market, pipeline, attempted or outcome named, so the routes answer 400",
  [atParsed("NL", `${AT}:sales`, "some", "won"), atParsed("unknown", "", " ", null), atParsed("nl", null, null, null), atParsed(null, "sales", null, null),
    atParsed(null, null, "never", null), atParsed(null, null, null, "unknown"), atParsed(null, null, "none", "ordered")],
  [`ok:NL/${AT}:sales/some/won`, "ok:unknown/-/all/all", "market:-/-/all/all", "pipeline:-/-/all/all", "attempted:-/-/all/all", "outcome:-/-/all/all", "ok:-/-/none/ordered"],
  [`ok:NL/${AT}:sales/some/won`, "ok:unknown/-/all/all", "ok:nl/-/all/all", "pipeline:-/-/all/all", "attempted:-/-/all/all", "outcome:-/-/all/all", "ok:-/-/none/ordered"]);
expect("attempts: the filter as a query, the defaults left out; the per-person key and permission",
  [attemptFilterQuery({ market: "GB", pipeline: null, attempted: "all", outcome: "all" }), attemptFilterQuery({ market: null, pipeline: `${AT}:sales`, attempted: "none", outcome: "open" }),
    ATTEMPTS_PER_AGENT_KEY, ATTEMPTS_PER_AGENT_PERMISSION],
  [{ market: "GB" }, { pipeline: `${AT}:sales`, attempted: "none", outcome: "open" }, "attempts", "performance.team"],
  [{ market: "GB", attempted: "all" }, { pipeline: `${AT}:sales`, attempted: "none", outcome: "open" }, "attempts", "performance.team"]);
expect("attempts: only sales deals: an order pipeline, a pipeline that is no lead pipeline and an uncounted one out, as 95's B1",
  byId(atWeek()).map((r) => r.dealSourceId).join(" "), "dA dB dL dL2 dN dO dS dT dU dW dW2", "dA dB dL dL2 dN dO dOrd dS dT dU dW dW2");
expect("attempts: telephony: attempts, conversations, the first, talk, without outcome; logged without the telephony call apart, as 95's B2",
  byId(atWeek()).map((r) => `${r.dealSourceId}:${r.attempts}/${r.conversationAttempts}/${r.firstConversationAttempt ?? "-"}/${r.talkSecondsTotal}/${r.talkSecondsConversation}/${r.attemptsWithoutOutcome}/${r.loggedWithoutAircall}`).join(" "),
  "dA:1/0/-/0/0/1/0 dB:1/0/-/0/0/0/0 dL:2/1/1/90/90/1/0 dL2:0/0/-/0/0/0/0 dN:0/0/-/0/0/0/0 dO:1/1/1/60/60/0/0 dS:1/1/1/45/45/1/0 dT:1/0/-/10/0/1/1 dU:1/1/1/120/120/0/0 dW:4/1/3/64/30/2/1 dW2:1/1/1/300/300/0/0",
  "dA:1/0/-/0/0/1/0 dB:1/0/-/0/0/0/0 dL:3/1/3/150/60/1/0 dL2:0/0/-/0/0/0/0 dN:0/0/-/0/0/0/0 dO:2/2/1/120/120/0/0 dS:2/2/1/90/90/2/0 dT:2/0/-/10/0/2/0 dU:1/1/1/120/120/0/0 dW:5/3/3/124/95/3/0 dW2:1/1/1/300/300/0/0");
const atSrc = (rows) => byId(rows.filter((r) => ["dT", "dW"].includes(r.dealSourceId)))
  .map((r) => `${r.dealSourceId}:${r.attempts}/${r.firstConversationAttempt ?? "-"}/${hms(r.firstAttemptAt)}/${r.speedToLeadSeconds}`).join(" ");
expect("attempts: the source: crm counts every outbound CRM call, telephony only the telephony calls, as 95's B3",
  `${atSrc(atWeek({ source: "crm" }))} | ${atSrc(atWeek())}`,
  "dT:2/-/08 08:02:00/120 dW:5/4/05 08:04:50/290 | dT:1/-/08 09:29:50/5390 dW:4/3/05 08:04:50/290",
  "dT:1/-/08 09:29:50/5390 dW:4/3/05 08:04:50/290 | dT:1/-/08 09:29:50/5390 dW:4/3/05 08:04:50/290");
expect("attempts: the window ends at the close or the first order (a won order deal, a store order), else now, as 95's B4",
  byId(atWeek().filter((r) => ["dA", "dB", "dL", "dO", "dS", "dW"].includes(r.dealSourceId)))
    .map((r) => `${r.dealSourceId}:${r.windowEndReason}/${r.outcome}/${r.orderedAt ? `${r.orderedAt.slice(8, 10)} ${r.orderedAt.slice(11, 16)}` : "-"}/${r.attempts}`).join(" "),
  "dA:open/open/-/1 dB:open/open/-/1 dL:closed/lost/08 10:00/2 dO:ordered/ordered/07 10:00/1 dS:ordered/ordered/08 10:00/1 dW:closed/won/-/4",
  "dA:open/open/-/1 dB:ordered/ordered/05 10:00/0 dL:ordered/lost/08 10:00/3 dO:ordered/ordered/07 10:00/1 dS:ordered/ordered/08 10:00/1 dW:closed/won/-/4");
const atOpen = atWeek();
expect("attempts: an ordered deal is out of the open figures, without business days since its last attempt, as 95's B5",
  `${byId(atOpen.filter((r) => ["dA", "dB", "dN", "dO", "dS", "dT"].includes(r.dealSourceId))).map((r) => `${r.dealSourceId}:${r.businessDaysSinceLast ?? "-"}`).join(" ")}`
    + ` open ${attemptFigures(atOpen).openDeals} never ${attemptFigures(atOpen).openNeverAttempted} since ${sinceLastBuckets(atOpen, "1,2,5").buckets.map((b) => `${b.label}:${b.deals}`).join(" ")}`,
  "dA:3 dB:4 dN:3 dO:- dS:- dT:4 open 4 never 1 since 0–1:0 1–2:0 2–5:4 5+:0",
  "dA:3 dB:4 dN:3 dO:4 dS:3 dT:4 open 6 never 1 since 0–1:0 1–2:0 2–5:6 5+:0");
const atOf = (id, o = {}, names = true) => dealAttempts(atDealOf(id), atOptions(o), names);
const atAttemptText = (list) => list.map((a) => `${a.n}:${a.connected ? "t" : "f"}/${a.talkSeconds ?? "-"}/${a.conversation ? "t" : "f"}`).join(" ");
expect("attempts: a conversation at 30 s of talk, the outcome deciding nothing; answered with 0 s connected, no conversation, as 95's B6",
  `${atAttemptText(atOf("dW"))} | ${atAttemptText(atOf("dL"))}`,
  "1:f/-/f 2:t/29/f 3:t/30/t 4:t/5/f | 1:t/90/t 2:t/0/f",
  "1:f/-/f 2:t/29/f 3:t/30/t 4:t/5/t | 1:t/90/f 2:t/0/f");
const atEdge = (min) => { const r = atWeek({ conversationMinTalkSeconds: min }).find((x) => x.dealSourceId === "dW"); return `${min}:${r.conversationAttempts}/${r.firstConversationAttempt ?? ""}`; };
expect("attempts: calls.conversation_min_talk_seconds moves the edge, as 95's B7",
  `${atEdge(29)} ${atEdge(31)}`, "29:2/2 31:0/", "29:3/2 31:1/4");
expect("attempts: one deal's attempts in order with the start, the outcome's label and the agent (only with names), as 95's B9 and B10",
  [atOf("dW").map((a) => `${a.n}|${hms(a.startedAt)}|${a.outcomeLabel ?? "-"}|${a.agentName ?? "-"}`).join(" "), atOf("dW", {}, false).filter((a) => a.agentName !== null).length],
  ["1|05 08:04:50|No answer|Anna Verify 2|05 08:59:50|-|Anna Verify 3|06 08:59:50|-|Anna Verify 4|07 08:59:50|Connected|Bram Verify", 0],
  ["1|05 08:04:50|No answer|Anna Verify 2|05 08:59:50|-|Anna Verify 3|06 08:59:50|-|Anna Verify 4|07 08:59:50|Connected|Anna Verify", 4]);
const atFiltered = (a, o) => {
  const rows = atWeek({}, { ...AT_ALL, attempted: a, outcome: o });
  return `${a}:${o}=${rows.length}/${attemptList(rows, 100).total}/${byId(attemptList(rows, 100).rows).map((r) => r.dealSourceId).join(",")}`;
};
expect("attempts: the filters attempted and outcome narrow every figure and the list, as 95's B11",
  [["none", "all"], ["some", "all"], ["all", "open"], ["all", "won"], ["all", "lost"], ["all", "ordered"], ["none", "lost"]].map(([a, o]) => atFiltered(a, o)).join(" "),
  "none:all=2/2/dL2,dN some:all=9/9/dA,dB,dL,dO,dS,dT,dU,dW,dW2 all:open=4/4/dA,dB,dN,dT all:won=2/2/dW,dW2 all:lost=2/2/dL,dL2 all:ordered=2/2/dO,dS none:lost=1/1/dL2",
  "none:all=2/2/dL2,dN some:all=9/9/dA,dB,dL,dO,dS,dT,dU,dW,dW2 all:open=6/6/dA,dB,dN,dO,dS,dT all:won=2/2/dW,dW2 all:lost=2/2/dL,dL2 all:ordered=0/0/ none:lost=1/1/dL2");
const atOc = attemptOutcomes(atWeek());
expect("attempts: won against lost, the deals not decided counted apart, as 95's B12",
  `${atOc.rows.map((o) => `${o.outcome}:${o.deals}/${o.avgAttempts.toFixed(2)}/${o.medianAttempts.toFixed(1)}/${o.medianSpeedSeconds ?? "-"}/${o.calledBeforeNoon}of${o.noonKnown}/${o.conversationDeals}/${o.avgTalkConversationSeconds ?? "-"}`).join(" ")}`
    + ` not_decided:${atOc.notDecided} open:${atOc.open} ordered:${atOc.ordered} unknown:${atOc.unknown}`,
  "won:2/2.50/2.5/6440/2of2/2/165 lost:2/1.00/1.0/3590/1of2/1/90 not_decided:7 open:4 ordered:2 unknown:1",
  "won:2/2.50/2.5/6440/2of2/2/335 lost:2/1.00/1.0/3590/1of1/0/- not_decided:7 open:4 ordered:2 unknown:1");
const atSp = attemptSpeedBuckets(atWeek(), "5,15,60,240,1440");
expect("attempts: the win rate by attempts and by speed to lead with their buckets, as 95's B13",
  `${attemptBuckets(atWeek(), 5).map((b) => `${b.label}:${b.won}/${b.lost}`).join(" ")} | ${atSp.buckets.map((b) => `${b.label}:${b.won}/${b.lost}`).join(" ")}`
    + ` none:${atSp.none.won}/${atSp.none.lost} no_hours:${atSp.noHours}`,
  "0:0/1 1:1/0 2:0/1 3:0/0 4:1/0 5+:0/0 | 0–5:1/0 5–15:0/0 15–60:0/1 60–240:1/0 240–1440:0/0 1440+:0/0 none:0/1 no_hours:0",
  "0:0/1 1:1/0 2:0/1 3:0/0 4:1/0 5+:0/0 | 0–5:0/0 5–15:1/0 15–60:0/1 60–240:1/0 240–1440:0/0 1440+:0/0 none:0/1 no_hours:0");
const atPrev = attemptsInPeriod(attemptRecords(atDeals, atOptions()), "2026-09-28", "2026-10-04", AT_ALL, null, AMS_AT);
expect("attempts: the figures, the previous period and the first conversation per attempt, as 95's B14",
  `${atFig(attemptFigures(atWeek()))} | ${atFig(attemptFigures(atPrev))} | ${attemptBuckets(atWeek(), 5).filter((b) => b.bucket > 0).map((b) => `${b.label}:${b.firstConversation}`).join(" ")}`,
  "11/9/13/1.18/1.0/6/5/5390/8of11/4/1/2/2/2/1/689/645/6/2 | 1/1/1/1.00/1.0/1/1/590/1of1/0/0/1/0/0/0/60/60/0/0 | 1:5 2:0 3:1 4:0 5+:0",
  "11/9/13/1.18/1.0/5/4/5390/8of11/4/1/2/2/2/1/689/560/6/2 | 0/0/0/-/-/0/0/-/0of0/0/0/0/0/0/0/0/0/0/0 | 1:4 2:0 3:1 4:0 5+:0");
const atList = attemptList(atWeek(), 100);
const atCapped = attemptList(atWeek(), 4);
expect("attempts: the list's order, its cap and total, the deal's id, the link and the stage, as 95's B15",
  `${atList.rows.map((r) => r.dealSourceId).join(" ")} | ${atCapped.rows.map((r) => r.dealSourceId).join(" ")} of ${atCapped.total}`
    + ` ${atCapped.rows[0].recordUrl === "https://crm.example.invalid/portal-1/deal/dB"} ${atCapped.rows[0].dealId === "deal-dB"} ${atCapped.rows[0].stageLabel}`,
  "dB dT dN dA dU dW2 dL2 dW dS dL dO | dB dT dN dA of 11 true true Open",
  "dB dT dA dN dU dW2 dL2 dW dS dL dO | dB dT dA dN of 11 true true Open");
const atPeople = attemptsPerPerson(atWeek(), (id) => atNames[id] ?? null);
const atNl = atPeople.rows.find((p) => p.kind === "notLinked");
expect("attempts per agent: by name, never ranked, the not-linked row with one owner id, the total, as 95's B16",
  `${atPeople.rows.filter((p) => p.kind === "person").map((p) => `${p.name}:${p.deals}/${p.attempts}/${p.conversationDeals}/${p.medianSpeedSeconds ?? "-"}/${p.talkSecondsConversation}/${p.openNeverAttempted}`).join(" ")}`
    + ` not_linked(${atNl.unlinkedOwners}):${atNl.deals}/${atNl.attempts}/${atNl.conversationDeals}/${atNl.medianSpeedSeconds}/${atNl.talkSecondsConversation}/${atNl.openNeverAttempted}`
    + ` total:${atPeople.total.deals}/${atPeople.total.attempts}`,
  "Anna Verify:4/7/4/7190/435/0 Bram Verify:3/4/1/32390/90/0 not_linked(1):4/2/1/3590/120/1 total:11/13",
  "Bram Verify:3/4/0/32390/0/0 Anna Verify:4/7/4/7190/440/0 not_linked(1):4/2/1/3590/120/1 total:11/13");
expect("attempts: the figures per pipeline, the lead pipelines only, as 95's B22",
  attemptGroups(atWeek(), "pipeline").map((g) => `${g.label}=${g.deals}`).join(","), "Sales=11", "Sales=11,Self Serve=1");
expect("attempts: the buckets' edges as cma.age_bucket_of places them, spaces ignored; bucket words as Follow-up's",
  [ageBucket(0, "1,2,5"), ageBucket(1, "1,2,5"), ageBucket(2, " 1, 2 ,5"), ageBucket(6, "1,2,5"), ageBucket(null, "1,2,5"), bucketText(2, 5), bucketText(5, null)],
  [{ from: 0, to: 1 }, { from: 0, to: 1 }, { from: 1, to: 2 }, { from: 5, to: null }, null, "2–5", "5+"],
  [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 1, to: 2 }, { from: 5, to: null }, null, "2–5", "5+"]);
expect("attempts: business days count the dates after the first up to the second, none without a zone",
  [businessDays("NL", AMS_AT, "2026-10-09T09:00:00Z", AT_NOW, atWorking), businessDays("NL", AMS_AT, "2026-10-14T06:00:00Z", AT_NOW, atWorking),
    businessDays("unknown", null, "2026-10-09T09:00:00Z", AT_NOW, atWorking)],
  [3, 0, null], [4, 0, null]);
// the screen: the shares, the format, the colours (one series, never a red), and nothing personal in the list or per person
const atCur = attemptFigures(atWeek());
expect("attempts: the shares (attempted, a conversation, the first a conversation, noon, without an outcome, won), none without a base; one decimal",
  [attemptedShare(atCur), conversationShare(atCur), firstConversationShare(atCur), noonShare(atCur), withoutOutcomeShare(atCur), firstConversationOnShare({ firstConversation: 1 }, 0),
    wonRate({ won: 1, lost: 0 }), wonRate({ won: 0, lost: 0 }), fmtAttempts(1.55, "en"), fmtAttempts(1.55, "nl"), fmtAttempts(null, "en"), speedMinutes(290), speedMinutes(null)],
  [9 / 11, 6 / 11, 5 / 9, 8 / 11, 6 / 13, null, 1, null, "1.6", "1,6", "–", 4.8, null],
  [9 / 11, 5 / 11, 4 / 9, 8 / 11, 6 / 13, 0, 1, 0, "1.55", "1,6", "0", 4.8, null]);
expect("attempts: the bars in the series' colours, never a red",
  [ATTEMPTS_BAR_CLASS, SINCE_LAST_CLASS, /red|error|rose/.test(ATTEMPTS_BAR_CLASS + SINCE_LAST_CLASS)], ["bg-p4a-deepblue", "bg-p4a-lightblue", false], ["bg-p4a-error", "bg-p4a-lightblue", false]);
expect("attempts: no name, address, phone number or hash in the list or per person; a deal's attempts carry no call id",
  [personalDataIn(atList), personalDataIn(atPeople, "$", true), atOf("dW").some((a) => "id" in a || "callId" in a)], [[], [], false], [["$.x"], [], false]);

// the routes (addition 0008z), from their source as the server builds them: the attempts query refuses a scope and an
// attempted or outcome outside its list with a 400; one deal's attempts for the report permissions, its id a uuid; the
// withdrawal a same-site POST for messages.withdraw only; the data layer calls the database with the filters, the deal and
// the message
const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const atApi = src("../src/lib/api/attempts.ts");
const atDealRoute = src("../src/app/api/v1/reports/attempts/deals/[dealId]/route.ts");
const withdrawRoute = src("../src/app/api/v1/messages/[id]/withdraw/route.ts");
const pgLayer = src("../src/lib/data/postgres.ts");
expect("attempts routes: a scope, attempted or outcome outside the lists is a 400; the filters reach the database",
  [/if \(sp\.has\("scope"\)\) throw new ApiError\(400, "invalid_scope"/.test(atApi), /problem === "attempted"\) throw new ApiError\(400, "invalid_attempted"/.test(atApi),
    /problem === "outcome"\) throw new ApiError\(400, "invalid_outcome"/.test(atApi),
    pgLayer.includes("cma.attempts_per_deal_page($1::date, $2::date, $3, $4, $5, $6, $7)") && pgLayer.includes("filter.attempted, filter.outcome]"),
    pgLayer.includes("cma.attempts_per_person_page($1::date, $2::date, $3, $4, $5, $6)")],
  [true, true, true, true, true], [false, true, true, true, true]);
expect("one deal's attempts: GET for the report permissions, the id a uuid, cma.attempts_of_deal",
  [/export async function GET\(/.test(atDealRoute), atDealRoute.includes("requireAnyPermission(me, REPORT_PERMISSIONS);"),
    atDealRoute.includes('uuidParam(dealId, "dealId")'), pgLayer.includes("select * from cma.attempts_of_deal($1::uuid)")],
  [true, true, true, true], [true, false, true, true]);
expect("withdrawing a message: a same-site POST for messages.withdraw only, cma.withdraw_message",
  [/export async function POST\(/.test(withdrawRoute), withdrawRoute.includes("assertSameSiteWrite(request);"),
    withdrawRoute.includes("requireAnyPermission(me, [WITHDRAW_PERMISSION]);"), WITHDRAW_PERMISSION, pgLayer.includes("select cma.withdraw_message($1::uuid) as at"),
    /export async function (GET|PUT|DELETE|PATCH)\(/.test(withdrawRoute)],
  [true, true, true, "messages.withdraw", true, false], [true, true, true, "messages.send", true, false]);

// ---- Funnel, lost reasons, cancellations and deals per person (addition 0008zb) on 99's own scenario ----------------
// Tenant one's deals as 99's B8 to B22 store them (one CRM connection; Sales with New, Quote, Won and Lost, Lost not
// reading its times; Sales two with Open and Won; Self Serve the order pipeline; Test not counted), their stage times,
// the reason catalog after B3's refresh (Garbage and Duplicate data quality), and the tickets with the kinds' rules
// (Cancellation request: the Cancellations pipeline, or the category Cancellation; Complaint: Support and Complaint).
// intake.start_date 1 September 2026, NL in EUR and GB in GBP, owners o-1 Anna and o-2 Bram, o-3 nobody; seen on
// Wednesday 14 October 2026 at 10:00 UTC (12:00 in Amsterdam). Amsterdam is UTC+2 throughout.
const FN = "00000000-0000-7000-8000-0000000000f1";
const fnT = (x) => (x === null ? null : `2026-${x}Z`);
const fnStage = (stageId, label, order, isClosed, outcome = null, readTimes = null) => ({ stageId, label, order, isClosed, outcome, readTimes, isActive: true });
const fnPipe = (pipelineId, label, o, stages) => ({ connectionId: FN, pipelineId, label, isCounted: true, isLead: true, isOrder: false, isActive: true, stages, ...o });
const FN_PIPES = [
  fnPipe("sales", "Sales", {}, [fnStage("s1", "New", 1, false), fnStage("s2", "Quote", 2, false), fnStage("sw", "Won", 8, true, "won"), fnStage("sl", "Lost", 9, true, "lost", false)]),
  fnPipe("sales2", "Sales two", {}, [fnStage("q1", "Open", 1, false), fnStage("qw", "Won", 8, true, "won")]),
  fnPipe("selfserve", "Self Serve", { isOrder: true }, [fnStage("o1", "Won", 1, true, "won")]),
  fnPipe("test", "Test", { isCounted: false }, [fnStage("x1", "Open", 1, false)]),
];
const FN_STAGE_TIMES = {
  dA: [["s1", "10-05T08:00:00", "10-06T08:00:00"], ["s2", "10-06T08:00:00", "10-08T12:00:00"], ["sw", "10-08T12:00:00", null]],
  dB: [["s1", "10-05T09:00:00", "10-07T09:00:00"], ["sl", "10-07T09:00:00", null]],
  dC: [["s1", "10-06T10:00:00", "10-09T10:00:00"], ["sl", "10-09T10:00:00", null]],
  dD: [["s1", "10-06T11:00:00", "10-07T11:00:00"], ["s2", "10-07T11:00:00", "10-10T11:00:00"], ["sl", "10-10T11:00:00", null]],
  dE: [["s1", "10-07T08:00:00", "10-08T08:00:00"], ["s2", "10-08T08:00:00", null]],
  dF: [["s1", "10-08T08:00:00", null]],
  dG: [["s1", "09-29T08:00:00", "10-02T08:00:00"], ["s2", "10-02T08:00:00", "10-06T08:00:00"], ["sw", "10-06T08:00:00", null]],
  dH: [["s1", "09-30T09:00:00", "10-01T09:00:00"], ["sl", "10-01T09:00:00", null]],
  dJ: [["s1", "10-09T10:00:00", "10-10T10:00:00"], ["sw", "10-10T10:00:00", null]],
  dT: [["q1", "10-06T09:00:00", null]], dU: [["s1", "10-11T07:00:00", null]], dV: [["s1", "10-11T12:00:00", null]], dY: [["x1", "10-07T10:00:00", null]],
};
// [id, pipeline, stage, owner, market, channel, created, closed, reason, amount, currency], as 99's B8 stores them
const FN_DEALS = [
  ["dA", "sales", "sw", "o-1", "NL", "PAID_SEARCH", "10-05T08:00:00", "10-08T12:00:00", null, 100, "EUR"],
  ["dB", "sales", "sl", "o-2", "GB", "PAID_SEARCH", "10-05T09:00:00", "10-07T09:00:00", "too_expensive", 50, "GBP"],
  ["dC", "sales", "sl", "o-1", "NL", "DIRECT", "10-06T10:00:00", "10-09T10:00:00", "garbage", null, null],
  ["dD", "sales", "sl", "o-3", "NL", "DIRECT", "10-06T11:00:00", "10-10T11:00:00", null, null, null],
  ["dE", "sales", "s2", "o-2", "NL", "PAID_SEARCH", "10-07T08:00:00", null, null, null, null],
  ["dF", "sales", "s1", "o-1", "NL", "PAID_SEARCH", "10-08T08:00:00", null, null, null, null],
  ["dG", "sales", "sw", "o-1", "NL", "PAID_SEARCH", "09-29T08:00:00", "10-06T08:00:00", null, 200, null],
  ["dH", "sales", "sl", "o-2", "NL", "PAID_SEARCH", "09-30T09:00:00", "10-01T09:00:00", "too_expensive", null, null],
  ["dJ", "sales", "sw", "o-1", "GB", "PAID_SEARCH", "10-09T10:00:00", "10-10T10:00:00", null, 80, "GBP"],
  ["dM", "sales", "sl", "o-2", "GB", "PAID_SEARCH", "10-08T09:00:00", "10-11T09:00:00", "bad_timing", null, null],
  ["dN", "sales", "sl", "o-2", "GB", "PAID_SEARCH", "10-08T10:00:00", "10-10T12:00:00", "duplicate", null, null],
  ["dO", "sales", "sl", "o-1", "NL", "PAID_SEARCH", "10-07T12:00:00", "10-09T12:00:00", "too_expensive", null, null],
  ["dP", "sales", "sl", "o-1", "NL", "PAID_SEARCH", "10-07T13:00:00", "10-08T13:00:00", "ordered_elsewhere", null, null],
  ["dQ", "sales", "sl", "o-2", "NL", null, "10-09T07:00:00", "10-09T08:00:00", "bad_timing", null, null],
  ["dR", "sales", "sl", "o-1", "NL", "PAID_SEARCH", "10-08T11:00:00", "10-11T08:00:00", "too_expensive", null, null],
  ["dS", "sales", "sl", "o-2", "NL", "PAID_SEARCH", "10-09T11:00:00", "10-10T09:00:00", "bad_fit", null, null],
  ["dT", "sales2", "q1", "o-1", "NL", "PAID_SEARCH", "10-06T09:00:00", null, null, null, null],
  ["dU", "sales", "s1", "o-1", "NL", "PAID_SEARCH", "10-11T07:00:00", null, null, null, null],
  ["dV", "sales", "s1", "o-1", "NL", "PAID_SEARCH", "10-11T12:00:00", null, null, null, null],
  ["dX", "selfserve", "o1", null, "NL", null, "10-07T10:00:00", "10-07T10:00:00", null, 90, "EUR"],
  ["dY", "test", "x1", "o-1", "NL", "PAID_SEARCH", "10-07T10:00:00", null, null, null, null],
  ["dZ", "sales", "sl", "o-1", "NL", "PAID_SEARCH", "08-31T10:00:00", "10-06T10:00:00", "too_expensive", null, null],
].map(([id, pipelineId, stageId, ownerRef, market, sourceChannel, created, closed, reason, amount, currency]) => ({
  dealId: `deal-${id}`, connectionId: FN, dealSourceId: id, pipelineId, stageId, market, sourceChannel, reason, ownerRef, createdAt: fnT(created),
  closedAt: fnT(closed), isClosed: closed !== null, amount, currency, recordUrl: `https://crm.example.invalid/portal-1/deal/${id}`,
  stages: (FN_STAGE_TIMES[id] ?? []).map(([s, a, b]) => ({ stageId: s, enteredAt: fnT(a), exitedAt: fnT(b) })),
}));
const FN_NOW = "2026-10-14T10:00:00Z";
const FN_OPTIONS = {
  tenantZone: AMS_AT, startDate: "2026-09-01", now: FN_NOW, ownerUserOf: (r) => ({ "o-1": "u-anna", "o-2": "u-bram" })[r] ?? null,
  currencyOf: (m) => ({ NL: "EUR", GB: "GBP" })[m] ?? null,
};
const FN_REASONS = [["too_expensive", "Too expensive", 9], ["bad_timing", "Bad Timing", 2], ["bad_fit", "Bad Fit", 3], ["ordered_elsewhere", "Ordered Elsewhere", 4],
  ["garbage", "Garbage", 5, true], ["duplicate", "Duplicate", 6, true], ["wrong_phone", "Wrong Phone", 7, true]]
  .map(([value, label, sortOrder, dq]) => ({ value, label, sortOrder, isDataQuality: dq === true }));
const FN_ALL = funnelDeals(FN_DEALS, FN_PIPES, FN_OPTIONS);
const FN_ENTRIES = FN_DEALS.flatMap((d) => d.stages.map((x) => x.enteredAt));
const FN_NONE = { market: null, pipeline: null, sourceChannel: null };
const fnPrev = (from, to) => funnelPrevious(previousPeriod({ from, to }, dateKeyInZone(FN_NOW, AMS_AT)), FN_NOW);
const fnPage = (from, to, filter = FN_NONE) => funnelReport(FN_ALL, FN_PIPES, FN_OPTIONS, from, to, filter, fnPrev(from, to), FN_ENTRIES);
const fnLost = (from, to, group = "week", filter = FN_NONE, limit = 100) =>
  lostReasonsReport(FN_ALL, FN_REASONS, "enumeration", FN_OPTIONS, from, to, group, filter, fnPrev(from, to), limit);
// as 99's pg_temp.v0008zb_fig: created/won/lost/win rate/median days to won/to lost
const d1 = (x) => (x === null ? "-" : x.toFixed(1));
const fnFig = (f) => `${f.created}/${f.won}/${f.lost}/${f.winRate === null ? "-" : f.winRate.toFixed(4)}/${d1(f.medianDaysToWon)}/${d1(f.medianDaysToLost)}`;
const fnWeek = fnPage("2026-10-05", "2026-10-11");

expect("funnel: week and day parse, anything else is refused (the routes' 400); G cycles",
  [["week", "day", "month", "", null].map(parseFunnelGroup), ["week", "day"].map(nextFunnelGroup)],
  [["week", "day", null, null, null], ["day", "week"]], [["week", "day", "month", null, null], ["day", "week"]]);
const fnParsed = (m, p, s) => { const x = parseFunnelFilter(m, p, s); return `${x.problem ?? "ok"}:${x.filter.market ?? "-"}/${x.filter.pipeline ?? "-"}/${x.filter.sourceChannel ?? "-"}`; };
expect("funnel: the filters as cma.funnel_filters_check takes them; a bad market, pipeline or source named; the query without the empty ones",
  [fnParsed("GB", `${FN}:sales`, "PAID_SEARCH"), fnParsed("unknown", "", ""), fnParsed("nl", null, null), fnParsed(null, "sales", null), fnParsed(null, null, "x".repeat(101)),
    fnParsed(null, null, "a\u0007b"), funnelFilterQuery({ market: "GB", pipeline: null, sourceChannel: "DIRECT" })],
  [`ok:GB/${FN}:sales/PAID_SEARCH`, "ok:unknown/-/-", "market:-/-/-", "pipeline:-/-/-", "source:-/-/-", "source:-/-/-", { market: "GB", source: "DIRECT" }],
  [`ok:GB/${FN}:sales/PAID_SEARCH`, "ok:unknown/-/-", "ok:nl/-/-", "pipeline:-/-/-", "source:-/-/-", "source:-/-/-", { market: "GB", source: "DIRECT" }]);
expect("funnel: the deals are 0008z's sales deals (no order pipeline, no uncounted one, none before the start date), as 99's B22",
  FN_ALL.map((r) => r.dealSourceId).sort().join(","), "dA,dB,dC,dD,dE,dF,dG,dH,dJ,dM,dN,dO,dP,dQ,dR,dS,dT,dU,dV", "dA,dB,dC,dD,dE,dF,dG,dH,dJ,dM,dN,dO,dP,dQ,dR,dS,dT,dU,dV,dX,dZ");
expect("funnel: per pipeline and in total, the win rate by close date, the median days, the previous period, as 99's B8",
  `${fnWeek.byPipeline.rows.map((x) => `${x.label}:${fnFig(x.current)}|${fnFig(x.previous)}`).join(" ")} total:${fnFig(fnWeek.byPipeline.total.current)}|${fnFig(fnWeek.byPipeline.total.previous)}`
    + ` ${fnWeek.previousFrom}..${fnWeek.previousTo} ${fnWeek.previousPartial}`,
  "Sales:16/3/10/0.2308/3.2/2.0|2/0/1/0.0000/-/1.0 Sales two:1/0/0/-/-/-|0/0/0/-/-/- total:17/3/10/0.2308/3.2/2.0|2/0/1/0.0000/-/1.0 2026-09-28..2026-10-04 false",
  "Sales:16/3/10/0.2308/3.2/2.0|2/0/1/0.0000/-/1.0 Sales two:1/0/0/-/-/-|0/0/0/-/-/- total:17/3/10/0.2308/3.2/2.0|2/0/1/0.0000/-/1.0 2026-09-28..2026-10-04 true");
const fnStageText = (x) => [x.entered, x.stillThere, x.movedOn, x.timed, x.medianDays === null ? null : x.medianDays.toFixed(1),
  x.reachedWon, x.wonShare === null ? null : x.wonShare.toFixed(4), x.enteredPrevious].map((v) => v ?? "-").join("/");
// The median only (Decision log, 15 October 2026): a stage carries no 80th percentile, nor any key beyond these
const FN_STAGE_KEYS = ["pipeline", "pipelineLabel", "stageId", "label", "order", "isClosed", "outcome", "readsTimes", "entered", "stillThere", "movedOn",
  "timed", "medianDays", "reachedWon", "wonShare", "enteredPrevious"];
const fnExtraKeys = (stages) => [...new Set(stages.flatMap((x) => Object.keys(x).filter((k) => !FN_STAGE_KEYS.includes(k))))].sort().join(",");
expect("funnel: per stage entered, still there, moved on, the median days in stage, reached won, the previous period; a stage off without figures; no 80th percentile, as 99's B9",
  `${fnWeek.stages.map((x) => `${x.stageId}:${fnStageText(x)}`).join(" ")} ${fnWeek.historyStart.deals}/${fnWeek.historyStart.stages} ${fnWeek.timedStages} keys:${fnExtraKeys(fnWeek.stages)}`,
  "s1:9/3/6/6/1.0/2/0.2222/2 s2:3/1/2/2/2.6/1/0.3333/1 sw:3/3/0/0/-/3/1.0000/0 sl:-/-/-/-/-/-/-/- q1:1/1/0/0/-/0/0.0000/0 qw:0/0/0/0/-/0/-/0 2026-09-29/2026-09-29 6 keys:",
  "s1:9/3/6/6/1.0/2/0.2222/2 s2:3/1/2/2/2.6/1/0.3333/1 sw:3/3/0/0/-/3/1.0000/0 sl:0/0/0/0/-/0/-/0 q1:1/1/0/0/-/0/0.0000/0 qw:0/0/0/0/-/0/-/0 2026-09-29/2026-09-29 6 keys:p80Days");
const fnGb = fnPage("2026-10-05", "2026-10-11", { ...FN_NONE, market: "GB" });
const fnGbS1 = fnGb.stages.find((x) => x.stageId === "s1");
const fnTwo = fnPage("2026-10-05", "2026-10-11", { ...FN_NONE, pipeline: `${FN}:sales2` });
expect("funnel: a market, a source channel and a pipeline narrow every figure; the filter lists without them, as 99's B10",
  `${fnFig(fnGb.byPipeline.total.current)} ${[fnGbS1.entered, fnGbS1.stillThere, fnGbS1.movedOn, d1(fnGbS1.medianDays), fnGbS1.wonShare.toFixed(4)].join("/")}`
    + ` ${fnFig(fnPage("2026-10-05", "2026-10-11", { ...FN_NONE, sourceChannel: "DIRECT" }).byPipeline.total.current)}`
    + ` ${fnTwo.byPipeline.rows.map((x) => x.label).join(",")} ${fnTwo.stages.map((x) => x.stageId).join(",")} ${JSON.stringify(fnTwo.markets)}`
    + ` ${fnTwo.pipelines.map((x) => x.label).join(",")} ${JSON.stringify(fnTwo.sourceChannels)}`,
  '4/1/3/0.2500/1.0/2.1 2/0/2/1.5/0.5000 2/0/2/0.0000/-/3.5 Sales two q1,qw ["GB","NL"] Sales,Sales two ["DIRECT","PAID_SEARCH"]',
  '4/1/3/0.2500/1.0/2.1 2/0/2/1.5/0.5000 2/0/2/0.0000/-/3.5 Sales,Sales two q1,qw ["GB","NL"] Sales,Sales two ["DIRECT","PAID_SEARCH"]');
const fnRun = fnPage("2026-10-12", "2026-10-14");
expect("funnel: like for like, the previous span's last date cut at the time of day, as 99's B11",
  `${fnFig(fnRun.byPipeline.total.current)}|${fnFig(fnRun.byPipeline.total.previous)} ${fnRun.previousFrom}..${fnRun.previousTo} ${fnRun.previousPartial}`
    + ` s1prev:${fnRun.stages.find((x) => x.stageId === "s1").enteredPrevious}`,
  "0/0/0/-/-/-|4/1/8/0.1111/1.0/2.5 2026-10-09..2026-10-11 true s1prev:2", "0/0/0/-/-/-|4/1/8/0.1111/1.0/2.5 2026-10-09..2026-10-11 true s1prev:3");
const fnL = fnLost("2026-10-05", "2026-10-11");
const lf = (f) => [f.lost, f.withReason, f.noReason, f.dataQuality, f.real].join("/");
const rs = (list) => list.map((x) => `${x.label}=${x.deals}/${x.share.toFixed(4)}`).join(",");
expect("lost reasons: the real reasons and their share, the data-quality block, no reason, the previous period, as 99's B12",
  `${lf(fnL.current)}|${lf(fnL.previous)} ${rs(fnL.reasons)} dq:${rs(fnL.dataQualityReasons)} none:${fnL.noReason.deals}/${fnL.noReason.share.toFixed(4)} ${fnL.reasonState} ${fnL.historyStart}`,
  "10/9/1/2/7|1/1/0/0/1 Too expensive=3/0.4286,Bad Timing=2/0.2857,Bad Fit=1/0.1429,Ordered Elsewhere=1/0.1429 dq:Duplicate=1/0.1000,Garbage=1/0.1000 none:1/0.1000 enumeration 2026-09-29",
  "10/9/1/2/7|1/1/0/0/1 Too expensive=3/0.3333,Bad Timing=2/0.2222,Bad Fit=1/0.1111,Ordered Elsewhere=1/0.1111 dq:Duplicate=1/0.1000,Garbage=1/0.1000 none:1/0.1000 enumeration 2026-09-29");
const grp = (list) => list.map((x) => `${x.key ?? "none"}:${x.lost}/${x.real}/${x.noReason}/${x.dataQuality}[${x.top.map((t) => `${t.label}=${t.deals}`).join(",")}]`).join(" ");
expect("lost reasons: per market with the top 3 real reasons, per source channel with none last, as 99's B13",
  `${grp(fnL.byMarket)} | ${grp(fnL.bySource)}`,
  "GB:3/2/0/1[Bad Timing=1,Too expensive=1] NL:7/5/1/1[Too expensive=2,Bad Fit=1,Bad Timing=1] | DIRECT:2/0/1/1[] PAID_SEARCH:7/6/0/1[Too expensive=3,Bad Fit=1,Bad Timing=1] none:1/1/0/0[Bad Timing=1]",
  "GB:3/2/0/1[Too expensive=1,Bad Timing=1] NL:7/5/1/1[Too expensive=2,Bad Fit=1,Bad Timing=1] | DIRECT:2/0/1/1[] PAID_SEARCH:7/6/0/1[Too expensive=3,Bad Fit=1,Bad Timing=1] none:1/1/0/0[Bad Timing=1]");
const fnDay = fnLost("2026-10-05", "2026-10-11", "day");
const fnLGb = fnLost("2026-10-05", "2026-10-11", "week", { ...FN_NONE, market: "GB" });
const sortedReasons = (o) => Object.entries(o).sort((a, b) => a[0].localeCompare(b[0])).map(([k, v]) => `${k}:${v}`).join(",");
expect("lost reasons: per ISO week and per day, the list without a reason with its link, the market filter, as 99's B14",
  `${fnL.byPeriod.map((x) => `${x.key}:${x.lost}/${x.real}/${x.noReason}/${x.dataQuality}{${sortedReasons(x.reasons)}}`).join(" ")} | `
    + `${fnDay.byPeriod.map((x) => `${x.key.slice(5)}:${x.lost}/${x.real}/${x.noReason}/${x.dataQuality}`).join(" ")} | `
    + `${fnL.list.total} ${fnL.list.rows.map((x) => `${x.dealSourceId} ${x.recordUrl}`).join(",")} GB:${fnLGb.current.lost} ${fnLGb.reasons.map((x) => `${x.label}=${x.share.toFixed(4)}`).join(",")}`,
  "2026-10-05:10/7/1/2{bad_fit:1,bad_timing:2,ordered_elsewhere:1,too_expensive:3} | 10-07:1/1/0/0 10-08:1/1/0/0 10-09:3/2/0/1 10-10:3/1/1/1 10-11:2/2/0/0 | "
    + "1 dD https://crm.example.invalid/portal-1/deal/dD GB:3 Bad Timing=0.5000,Too expensive=0.5000",
  "2026-10-05:10/7/1/2{bad_fit:1,bad_timing:2,ordered_elsewhere:1,too_expensive:3} | 10-07:1/1/0/0 10-08:1/1/0/0 10-09:3/2/0/1 10-10:3/1/1/1 10-11:2/2/0/0 | "
    + "1 dD https://crm.example.invalid/portal-1/deal/dD GB:3 Too expensive=0.5000,Bad Timing=0.5000");
expect("lost reasons: the list capped, the newest close first; a reason only from an enumeration (cma.reason_state_of)",
  [fnLost("2026-09-28", "2026-10-11", "week", FN_NONE, 0).list.rows.length, fnLost("2026-09-28", "2026-10-11").list.total,
    reasonStateOf(null, null), reasonStateOf("lost_dropdown", null), reasonStateOf("lost_dropdown", "enumeration"), reasonStateOf("lost_text", "string")],
  [0, 1, "none", "unchecked", "enumeration", "refused"], [0, 1, "none", "unchecked", "enumeration", "enumeration"]);

// the tickets and the kinds, as 99's B5 to B7 and B15 store them; each market resolved as 0007d's rule gives it
const fnTicket = (id, pipelineId, market, category, created, closed, reason, o = {}) => ({
  recordId: `ticket-${id}`, connectionId: FN, recordType: "ticket", sourceId: id, pipelineId,
  pipelineLabel: { cancel: "Cancellations", support: "Support", spam: "Spam" }[pipelineId], pipelineCounted: pipelineId !== "spam", category, market, reason,
  isClosed: closed !== null, createdAt: fnT(created), closedAt: fnT(closed), deletedAt: null, recordUrl: `https://crm.example.invalid/portal-1/ticket/${id}`, ...o,
});
const FN_TICKETS = [
  fnTicket("tA", "cancel", "NL", null, "10-05T08:00:00", "10-07T08:00:00", "price"), fnTicket("tB", "cancel", "GB", null, "10-06T09:00:00", null, "moving"),
  fnTicket("tC", "support", "NL", "Cancellation", "10-08T10:00:00", "10-08T22:00:00", null), fnTicket("tD", "support", "NL", "Complaint", "10-08T11:00:00", null, null),
  fnTicket("tE", "spam", "NL", "Cancellation", "10-08T12:00:00", null, null), fnTicket("tF", "cancel", "NL", null, "10-01T08:00:00", null, null),
  fnTicket("tG", "cancel", "NL", null, "10-12T08:00:00", null, null), fnTicket("tH", "cancel", "unknown", null, "10-09T09:00:00", null, null),
  fnTicket("tI", "cancel", "NL", null, "10-07T08:00:00", null, null, { deletedAt: fnT("10-07T09:00:00") }),
];
const FN_KINDS = [{ key: "cancellation", label: "Cancellation request", recordType: "ticket", status: "active", sortOrder: 10 },
  { key: "complaint", label: "Complaint", recordType: "ticket", status: "active", sortOrder: 20 }];
const FN_RULES = [{ connectionId: FN, kindKey: "cancellation", pipelineId: "cancel", category: null, isActive: true },
  { connectionId: FN, kindKey: "cancellation", pipelineId: null, category: "Cancellation", isActive: true },
  { connectionId: FN, kindKey: "complaint", pipelineId: "support", category: "Complaint", isActive: true }];
expect("record kinds: a rule by pipeline, by category and by both; an empty rule matches nothing; archived rules and kinds none, as 99's B6",
  [kindRuleMatches("cancel", null, "cancel", null), kindRuleMatches(null, "Cancellation", "support", "Cancellation"), kindRuleMatches("support", "Complaint", "support", "Other"),
    kindRuleMatches(null, null, "cancel", null), FN_TICKETS.map((x) => `${x.sourceId}:${recordKindsOf(FN_KINDS, FN_RULES, x).join("+") || "-"}`).join(" "),
    recordKindsOf(FN_KINDS.map((k) => ({ ...k, status: "archived" })), FN_RULES, FN_TICKETS[0]).length,
    recordKindsOf(FN_KINDS, FN_RULES.map((r) => ({ ...r, isActive: false })), FN_TICKETS[0]).length],
  [true, true, false, false, "tA:cancellation tB:cancellation tC:cancellation tD:complaint tE:cancellation tF:cancellation tG:cancellation tH:cancellation tI:cancellation", 0, 0],
  [true, true, false, true, "tA:cancellation tB:cancellation tC:cancellation tD:complaint tE:cancellation tF:cancellation tG:cancellation tH:cancellation tI:cancellation", 0, 0]);
const fnKind = { key: "cancellation", label: "Cancellation request", recordType: "ticket", status: "active" };
const FN_TICKET_LABELS = new Map([["price", "Price"], ["moving", "Moving"]]);
const fnCancel = (from, to, group, market, limit, kind = fnKind) => cancellationsReport(cancellationRecords(FN_TICKETS, kind, FN_RULES, "2026-09-01", AMS_AT), kind,
  "enumeration", FN_TICKET_LABELS, "2026-09-01", AMS_AT, from, to, group, market, fnPrev(from, to), limit);
const cf = (f) => `${f.requests}/${f.open}/${f.closed}/${d1(f.medianDaysToClose)}`;
const fnC = fnCancel("2026-10-05", "2026-10-11", "week", null, 3);
expect("cancellations: the kind's requests (no uncounted pipeline, deleted ticket, other kind), open, closed, days to close, per market and week, reasons, the list, as 99's B15",
  `${fnC.kind.key}:${fnC.kind.label} ${cf(fnC.current)}|${cf(fnC.previous)} ${fnC.byMarket.map((x) => `${x.market}:${cf(x)}`).join(" ")}`
    + ` ${fnC.byPeriod.map((x) => `${x.key}/${x.market}=${x.requests}`).join(" ")} ${fnC.reasonState} ${fnC.reasons.map((x) => `${x.label ?? "-"}=${x.requests}`).join(" ")}`
    + ` ${fnC.list.total}:${fnC.list.rows.map((x) => x.sourceId).join(",")} ${fnC.list.rows[0].recordUrl} ${JSON.stringify(fnC.markets)} ${fnC.historyStart}`,
  'cancellation:Cancellation request 4/2/2/1.3|1/1/0/- GB:1/1/0/- NL:2/0/2/1.3 unknown:1/1/0/- 2026-10-05/GB=1 2026-10-05/NL=2 2026-10-05/unknown=1 '
    + 'enumeration Moving=1 Price=1 -=2 4:tH,tC,tB https://crm.example.invalid/portal-1/ticket/tH ["GB","NL","unknown"] 2026-10-01',
  'cancellation:Cancellation request 5/3/2/1.3|1/1/0/- GB:1/1/0/- NL:3/1/2/1.3 unknown:1/1/0/- 2026-10-05/GB=1 2026-10-05/NL=3 2026-10-05/unknown=1 '
    + 'enumeration Moving=1 Price=1 -=3 5:tH,tE,tC https://crm.example.invalid/portal-1/ticket/tH ["GB","NL","unknown"] 2026-10-01');
const fnCNl = fnCancel("2026-10-05", "2026-10-11", "day", "NL", 100);
const fnCOff = cancellationsReport([], null, "enumeration", FN_TICKET_LABELS, "2026-09-01", AMS_AT, "2026-10-05", "2026-10-11", "week", null, fnPrev("2026-10-05", "2026-10-11"), 100);
const fnArchived = { ...fnKind, status: "archived" };
expect("cancellations: by market and day; no kind set (nothing counted, no reason state); the kind archived, as 99's B16",
  `${fnCNl.current.requests}/${fnCNl.byPeriod.map((x) => `${x.key.slice(5)}=${x.requests}`).join(",")} ${fnCOff.kind ?? "none"}/${fnCOff.current.requests}/${fnCOff.reasonState}`
    + ` ${fnCancel("2026-10-05", "2026-10-11", "week", null, 100, fnArchived).kind.status}/${fnCancel("2026-10-05", "2026-10-11", "week", null, 100, fnArchived).current.requests}`,
  "2/10-05=1,10-08=1 none/0/none archived/0", "2/10-05=1,10-08=1 none/0/none archived/4");
const fnPivot = cancellationPivot(fnC.byPeriod);
expect("cancellations: the per-week table one row per Monday without gaps, a column per market, unknown last; the period keys",
  [fnPivot.markets, fnPivot.rows.map((r) => `${r.key}:${r.total}`), periodKeys("2026-10-05", "2026-10-18", "week"), periodKeys("2026-10-09", "2026-10-11", "day")],
  [["GB", "NL", "unknown"], ["2026-10-05:4"], ["2026-10-05", "2026-10-12"], ["2026-10-09", "2026-10-10", "2026-10-11"]],
  [["GB", "NL", "unknown"], ["2026-10-05:4"], ["2026-10-05"], ["2026-10-09", "2026-10-10", "2026-10-11"]]);
const fnPeople = dealsPerPerson(funnelFilter(FN_ALL, FN_NONE), "2026-10-05", "2026-10-11", (id) => ({ "u-anna": "Anna Verify", "u-bram": "Bram Verify" })[id] ?? null);
const am = (p) => p.amounts.map((a) => `${a.currency} ${a.amount.toFixed(2)} (${a.deals})`).join(",");
const fnNl = fnPeople.rows.find((p) => p.kind === "notLinked");
expect("deals per person: won, lost, the amounts per currency never summed, by name; the not-linked owners; the total, as 99's B17",
  `${fnPeople.rows.filter((p) => p.kind === "person").map((p) => `${p.name}:${p.won}/${p.lost}[${am(p)}]`).join(" ")} not_linked(${fnNl.unlinkedOwners}):${fnNl.won}/${fnNl.lost}`
    + ` total:${fnPeople.total.won}/${fnPeople.total.lost}[${am(fnPeople.total)}]`,
  "Anna Verify:3/4[EUR 300.00 (2),GBP 80.00 (1)] Bram Verify:0/5[] not_linked(1):0/1 total:3/10[EUR 300.00 (2),GBP 80.00 (1)]",
  "Anna Verify:3/4[EUR 380.00 (3)] Bram Verify:0/5[] not_linked(1):0/1 total:3/10[EUR 380.00 (3)]");
expect("funnel: read_times in force (a person's choice, else the pipeline's counted flag); the business date cut; stages per pipeline; reason columns",
  [readTimesOf(null, true), readTimesOf(null, false), readTimesOf(false, true), readTimesOf(true, false), readTimesOf(null, null),
    inPeriod("2026-10-11", "12:00:00", "2026-10-09", "2026-10-11", "12:00:00"), inPeriod("2026-10-11", "12:00:01", "2026-10-09", "2026-10-11", "12:00:00"),
    stagesByPipeline(fnWeek.stages).map((p) => `${p.label}:${p.stages.length}`), periodReasonColumns(fnL.reasons, 2).other],
  [true, false, false, true, true, true, false, ["Sales:4", "Sales two:2"], ["bad_fit", "ordered_elsewhere"]],
  [true, true, false, true, true, true, false, ["Sales:4", "Sales two:2"], ["bad_fit", "ordered_elsewhere"]]);
expect("funnel: the bars in the series' first colour and one neutral hue, never a red; the per-person key and permission",
  [FUNNEL_BAR_CLASS, FUNNEL_NEUTRAL_CLASS, /red|error|rose/.test(FUNNEL_BAR_CLASS + FUNNEL_NEUTRAL_CLASS), DEALS_PER_PERSON_KEY, DEALS_PER_PERSON_PERMISSION],
  ["bg-p4a-deepblue", "bg-p4a-lightblue", false, "deals", "performance.team"], ["bg-p4a-error", "bg-p4a-lightblue", false, "deals", "performance.team"]);
expect("funnel: no name, address, phone number or hash in the pages; a person's name only per person; no free text (a reason is a value)",
  [personalDataIn(fnWeek), personalDataIn(fnL), personalDataIn(fnC), personalDataIn(fnPeople, "$", true),
    [...fnL.list.rows, ...fnC.list.rows].some((r) => "reasonText" in r || "note" in r || "subject" in r)],
  [[], [], [], [], false], [["$.x"], [], [], [], false]);

// the routes (addition 0008zb), from their source: the funnel query refuses a bad group, market, pipeline or source with a
// 400, Cancellations takes the market only; Deals per person is not found while reports.per_person lacks deals; the data
// layer calls the four reads with the filters; the Sources writes are same-site PUTs for tenant.configure
const fnApi = src("../src/lib/api/funnel.ts");
const fnPerson = src("../src/app/api/v1/reports/deals-per-person/route.ts");
const fnCancelRoute = src("../src/app/api/v1/reports/cancellations/route.ts");
const fnWrites = ["stage-times", "reason-field", "reasons", "kind-rules"].map((x) => src(`../src/app/api/v1/configuration/sources/[id]/${x}/route.ts`))
  .concat([src("../src/app/api/v1/configuration/record-kinds/route.ts")]);
expect("funnel routes: the filters and the group as 400s, the market only for cancellations, the reads reach the database with the filters",
  [/problem === "source"\) throw new ApiError\(400, "invalid_source"/.test(fnApi), /if \(!group\) throw new ApiError\(400, "invalid_group"/.test(fnApi),
    fnCancelRoute.includes("{ marketOnly: true }"), pgLayer.includes("cma.deal_funnel_page($1::date, $2::date, $3, $4, $5)"),
    pgLayer.includes("cma.lost_reasons_page($1::date, $2::date, $3, $4, $5, $6)"), pgLayer.includes("cma.cancellations_page($1::date, $2::date, $3, $4)"),
    pgLayer.includes("cma.deals_per_person_page($1::date, $2::date, $3, $4, $5)")],
  [true, true, true, true, true, true, true], [true, true, false, true, true, true, true]);
expect("deals per person: 404 while reports.per_person lacks deals, then performance.team; the Sources writes same-site PUTs for tenant.configure",
  [fnPerson.includes('if (!me.perPerson.includes(DEALS_PER_PERSON_KEY)) throw new ApiError(404, "not_found"'), fnPerson.includes("requireAnyPermission(me, [DEALS_PER_PERSON_PERMISSION]);"),
    fnWrites.every((w) => /export async function PUT\(/.test(w) && w.includes("assertSameSiteWrite(request);") && w.includes('requireAnyPermission(me, ["tenant.configure"]);'))],
  [true, true, true], [false, true, true]);
// The median only (Decision log, 15 October 2026): no 80th percentile of days in stage in the read (98), the type, the data
// layer, the mirror, the table, the file or the copy, in English or Dutch
const fnNoP80 = { "db/98_funnel.sql": src("../../db/98_funnel.sql"), "lib/data/types.ts": src("../src/lib/data/types.ts"), "lib/data/postgres.ts": pgLayer,
  "lib/funnel.ts": src("../src/lib/funnel.ts"), "components/FunnelParts.tsx": src("../src/components/FunnelParts.tsx"), "lib/csv.ts": src("../src/lib/csv.ts"),
  "lib/copy.ts": src("../src/lib/copy.ts") };
const P80_IN_FUNNEL = /p80_?days|P80Days|percentile_cont\(0\.8\)|percentileCont\([^)]*0\.8\)|80th percentile days|80e percentiel/i;
expect("funnel: the median only, no 80th percentile of days in stage in the read, the type, the data layer, the mirror, the table, the file or the copy",
  Object.entries(fnNoP80).filter(([, text]) => P80_IN_FUNNEL.test(text)).map(([f]) => f), [], ["lib/funnel.ts"]);

// ---- Reviews (addition 0008ze, brief B18) on 105's own scenario -------------------------------------------------
// Tenant one's review channels and reviews as 105's B1 to B9 leave them (chl-nl NL and chl-gb GB counted, chl-fr FR
// counted without reviews, chl-x without a market, chl-old gone; rev-3 linked to a contact by B5), seen on Wednesday 14
// October 2026 at 10:00 UTC (12:00 in Amsterdam); the active markets DE, FR, GB and NL; the negative threshold 2
const RV_NOW = "2026-10-14T10:00:00Z";
const rvCh = { "chl-nl": ["Shop NL renamed", "NL", true], "chl-gb": ["Shop GB", "GB", true], "chl-x": ["Shop X", null, false] };
const rv = (reviewId, channel, rating, at, isPublished = true, linkLevel = "none", inviteEventType = null) => ({ reviewId, channel, channelName: rvCh[channel][0],
  market: rvCh[channel][1], channelCounted: rvCh[channel][2], isPublished, rating, submittedAt: `2026-${at}Z`, linkLevel, inviteEventType });
const RV_SOURCES = [rv("rev-1", "chl-nl", 5, "10-02T09:00:00", true, "order", "checkout"), rv("rev-2", "chl-nl", 2, "10-05T10:00:00", true, "order", "checkout"),
  rv("rev-3", "chl-gb", 4.5, "10-14T09:00:00", true, "contact", "klaviyo-integration"), rv("rev-4", "chl-gb", 1, "10-13T22:30:00"),
  rv("rev-5", "chl-x", 3, "10-03T10:00:00"), rv("rev-6", "chl-nl", 1, "10-04T10:00:00", false), rv("pre-1", "chl-nl", 4, "09-20T10:00:00", true, "none", "checkout"),
  rv("pre-2", "chl-gb", 2, "09-30T09:00:00"), rv("pre-3", "chl-nl", 5, "09-30T11:00:00"), rv("old-1", "chl-nl", 3, "08-01T10:00:00")];
const RV_MARKETS = [{ code: "NL", name: "Netherlands", sortOrder: 40 }, { code: "DE", name: "Germany", sortOrder: 10 }, { code: "GB", name: "United Kingdom", sortOrder: 30 },
  { code: "FR", name: "France", sortOrder: 20 }];
const RV_CHANNELS = [{ market: "NL", isCounted: true, deleted: false, publishedReviews: 5 }, { market: "GB", isCounted: true, deleted: false, publishedReviews: 3 },
  { market: "FR", isCounted: true, deleted: false, publishedReviews: 0 }, { market: null, isCounted: false, deleted: false, publishedReviews: 1 },
  { market: null, isCounted: false, deleted: true, publishedReviews: 0 }];
const RV_STATES = reviewMarketStates(RV_MARKETS, RV_CHANNELS);
const RV_RECORDS = reviewRecords(RV_SOURCES, AMS_AT, 2);
const rvPage = (market, group = "day") => reviewsReport(RV_RECORDS, { from: "2026-10-01", to: "2026-10-14", group, market,
  prev: funnelPrevious(previousPeriod({ from: "2026-10-01", to: "2026-10-14" }, dateKeyInZone(RV_NOW, AMS_AT)), RV_NOW), zone: AMS_AT, negativeMaxRating: 2,
  isSetUp: true, markets: RV_MARKETS, marketStates: RV_STATES, filterMarkets: ["FR", "GB", "NL"] });
const rvFig = (f) => `${f.reviews}/${f.averageRating === null ? "-" : f.averageRating.toFixed(2)}/${f.negative}/${f.linkedOrder}/${f.linkedContact}/${f.unlinked}`;
const rvAll = rvPage(null);
expect("reviews: the figures, the previous period like for like, per whole star, the link levels, the history start, as 105's B11",
  `${rvFig(rvAll.current)} prev ${rvFig(rvAll.previous)} ${rvAll.previousFrom}..${rvAll.previousTo}:${rvAll.previousPartial} stars ${rvAll.distribution.map((d) => `${d.reviews}/${d.previous}`).join(",")} `
    + `links ${rvAll.linkLevels.map((l) => `${l.level}:${l.reviews}/${l.previous}`).join(",")} start ${rvAll.historyStart} neg ${rvAll.negativeMaxRating} ${rvAll.isSetUp}`,
  "4/3.13/2/2/1/1 prev 2/3.00/1/0/0/2 2026-09-17..2026-09-30:true stars 1/0,1/1,0/0,0/1,2/0 links order:2/0,contact:1/0,none:1/2 start 2026-08-01 neg 2 true",
  "4/3.13/2/2/1/1 prev 3/3.67/1/0/0/3 2026-09-17..2026-09-30:true stars 1/0,1/1,0/0,0/1,2/1 links order:2/0,contact:1/0,none:1/3 start 2026-08-01 neg 2 true");
const rvWeek = rvPage(null, "week");
expect("reviews: by day and week (22:30 UTC on the 13th is the 14th), markets, channels, invite events, the states, a market, as 105's B12",
  `${rvAll.byPeriod.length} ${rvAll.byPeriod.filter((g) => g.reviews > 0).map((g) => `${g.key}=${g.reviews}`).join(",")} week ${rvWeek.byPeriod.map((g) => `${g.key}=${g.reviews}`).join(",")} `
    + `markets ${rvAll.byMarket.map((m) => `${m.market}:${rvFig(m.current)}<${rvFig(m.previous)}`).join(" ")} `
    + `channels ${rvAll.byChannel.map((c) => `${c.channel}:${c.name}:${c.market}:${c.current.reviews}`).join(" ")} `
    + `events ${rvAll.inviteEvents.map((e) => `${e.eventType ?? "none"}:${e.reviews}/${e.previous}`).join(",")} `
    + `states ${rvAll.marketStates.map((m) => `${m.market}:${m.state}:${m.channels}`).join(" ")} filter ${rvAll.markets.join(",")} `
    + `NL ${rvFig(rvPage("NL").current)} unknown ${rvFig(rvPage("unknown").current)}`,
  "14 2026-10-02=1,2026-10-05=1,2026-10-14=2 week 2026-09-28=1,2026-10-05=1,2026-10-12=2 markets GB:2/2.75/1/0/1/1<1/2.00/1/0/0/1 NL:2/3.50/1/2/0/0<1/4.00/0/0/0/1 "
    + "channels chl-gb:Shop GB:GB:2 chl-nl:Shop NL renamed:NL:2 events checkout:2/1,klaviyo-integration:1/0,none:1/1 "
    + "states DE:no_channel:0 FR:channel_no_reviews:1 GB:has_reviews:1 NL:has_reviews:1 filter FR,GB,NL NL 2/3.50/1/2/0/0 unknown 0/-/0/0/0/0",
  "14 2026-10-02=1,2026-10-05=1,2026-10-13=1,2026-10-14=1 week 2026-09-28=1,2026-10-05=1,2026-10-12=2 markets GB:2/2.75/1/0/1/1<1/2.00/1/0/0/1 NL:2/3.50/1/2/0/0<1/4.00/0/0/0/1 "
    + "channels chl-gb:Shop GB:GB:2 chl-nl:Shop NL renamed:NL:2 events checkout:2/1,klaviyo-integration:1/0,none:1/1 "
    + "states DE:no_channel:0 FR:channel_no_reviews:1 GB:has_reviews:1 NL:has_reviews:1 filter FR,GB,NL NL 2/3.50/1/2/0/0 unknown 0/-/0/0/0/0");
expect("reviews: a rating as a whole star (rounded up), the rating in both languages, a share, the markets without a channel",
  [[1, 1.2, 2, 4.5, 5].map(starsOf), fmtRating(3.125, "en"), fmtRating(3.13, "nl"), fmtRating(null, "en"), reviewShare(1, 4), reviewShare(0, 0), marketsWithoutChannel(RV_STATES)],
  [[1, 2, 2, 5, 5], "3.13", "3,13", "–", 0.25, null, ["DE"]],
  [[1, 1, 2, 4, 5], "3.13", "3,13", "–", 0.25, null, ["DE"]]);
// the route and the data layer, from their source: the market only (a pipeline or source is a 400), the report's
// permissions, the read with its four parameters; the review channels' write a same-site PUT for tenant.configure
const rvRoute = src("../src/app/api/v1/reports/reviews/route.ts");
const rvWrite = src("../src/app/api/v1/configuration/sources/[id]/review-channels/route.ts");
expect("reviews routes: the market only, reports.view or performance.team, the read with its parameters; the channels' write for tenant.configure",
  [rvRoute.includes("{ marketOnly: true }"), rvRoute.includes("requireAnyPermission(me, REPORT_PERMISSIONS);"),
    pgLayer.includes("cma.reviews_page($1::date, $2::date, $3, $4)"),
    /export async function PUT\(/.test(rvWrite) && rvWrite.includes("assertSameSiteWrite(request);") && rvWrite.includes('requireAnyPermission(me, ["tenant.configure"]);')],
  [true, true, true, true], [false, true, true, true]);
// no reviewer and no review text anywhere in the report's type, data layer, mirror, parts, page or copy keys
const rvNoText = { "lib/reviews.ts": src("../src/lib/reviews.ts"), "components/ReviewParts.tsx": src("../src/components/ReviewParts.tsx"),
  "app/reports/reviews/page.tsx": src("../src/app/reports/reviews/page.tsx") };
const RV_PERSONAL = /fullName|\.email\b|mobile|\.comment\b|\.title\b(?!\s*=)|reviewerName|reviewText/;
expect("reviews: no reviewer's name, email, phone, title or text in the mirror, the parts or the page",
  Object.entries(rvNoText).filter(([, text]) => RV_PERSONAL.test(text.replace(/t\.title|copy\.[a-zA-Z.]+title/gi, ""))).map(([f]) => f), [], ["lib/reviews.ts"]);

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
