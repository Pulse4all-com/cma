/**
 * Mock data: in memory, fictional, resets on every cold start.
 * It cannot persist, and the UI says so (handover: a mock that cannot persist
 * must say so). Nothing here reaches a database.
 */
import { MOCK_IDENTITY, MOCK_PRINCIPAL, type Principal } from "@/lib/auth/identity";
import { CmaDbError } from "@/lib/data/errors";
import { instantsForLocal } from "@/lib/corrections";
import { addDays, dateKeyInZone, startOfWeek } from "@/lib/time";
import type {
  AbsenceType, AppLink, CmaData, ConfigAppLink, ConfigStatus, CoverageTargetRow, MessageStat, MessageTarget, MyMessage, MyMessages, MyProfile, MyRosterDay, SentMessage, RosterCellInput, RosterEntry, RosterWeek, RosterWeekHeader, RosterWeekSummary, TodayShift, CorrectionChange, DateKey, DirectoryPerson, ExportHoursRow, HoursSummary, Instant, RoleInfo,
  SkillInfo, SkillInput, StatusChangeRow, StatusTimeRow, TeamDay, TeamDayDetail, TeamInfo, TeamMembership, TeamNow,
  TeamNowPerson, TeamPerson, TenantSetting, TimeEvent, WorkStatus, Workday,
  CrmRecordsDay, DataQualityCheck, Intake, SourceConnections, SpeedToLeadRow, SpeedToLeadStatus,
  AlertRule, LinkedAccount, MarketConfig, MarketHoliday, OfficeHours, SourceCallOutcome, SourceConnection, SourceDetail, SourceForm, SourceKind,
  SourceLine, SourcePipeline, SourceStore, SourceTag,
  InboundFigures, InboundGroup, InboundNow, InboundService, MissedReason, SourceMissedReason,
  CallsFilter, CallsGroup, CallsOverview, CallsPerAgent, CallsPerAgentTags, CallsTagUse, HoursRange,
  FormCategory, FormsAnswers, FormsFilter, FormsGroup, FormsReport, SourceFormField,
  Invitation, InvitationAcceptResult, InvitationLink, InvitationPreview,
  FollowUpCallbacks, FollowUpOwner, FollowUpPage, FollowUpRowsAt, FollowUpSummaryAt, MyFollowUp, OpenLead, OpenTask, OpenTicket, SourceTaskStatus, SourceTaskType,
  DatabaseProbe, OutboxStatusRow, SystemHealthRun,
  EmailFilter, EmailGroup, EmailNotRespondingRow, EmailPerAgent, EmailReport, EmailWaitingRow, SourceInbox, SourceMailbox,
  AttributionSettings, FirstOrderEvidence, FirstOrderFilter, FirstOrderGroup, FirstOrdersReport, OrdersPerPerson, SourceStage,
  Journey, JourneyStatus, CallbackOwner, CallbacksKept, DashboardData,
  AttemptFilter, AttemptGroup, AttemptSettings, AttemptsPerAgent, AttemptsReport, DealAttempt,
  CancellationsReport, DealsPerPerson, FunnelFilter, FunnelGroup, FunnelReport, LostReasonsReport, RecordKind, RecordKindConfig, SourceField, SourceReason,
  ReviewsReport,
} from "./types";
import {
  ATTEMPT_GROUPS, ATTEMPTS_PER_AGENT_KEY, ATTEMPTS_PER_AGENT_PERMISSION, attemptBuckets, attemptFigures, attemptGroups, attemptList, attemptOutcomes,
  attemptRecords, attemptSpeedBuckets, attemptsInPeriod, attemptsPerPerson, dealAttempts, parseAttemptFilter, sinceLastBuckets,
  type AttemptCallFixture, type AttemptDealFixture, type AttemptOptions, type WorkingDay,
} from "@/lib/attempts";
import {
  CALLBACKS_PER_OWNER_PERMISSION, CALLBACKS_PERMISSIONS, callbackFigures, callbackRecords, callbacksInPeriod, callbacksPerOwner,
  type CallbackCallFixture, type CallbackTaskFixture,
} from "@/lib/callbacks";
import {
  FIRST_ORDER_GROUPS, firstOrderAmounts, firstOrderFigures, firstOrderGroups, firstOrderList, firstOrderRecords, firstOrdersInPeriod, ordersPerPerson,
  ORDERS_PER_PERSON_KEY, ORDERS_PER_PERSON_PERMISSION, parseFirstOrderFilter, type OrderDealFixture, type OrderTouch,
} from "@/lib/first-orders";
import {
  EMAIL_GROUPS, EMAIL_PER_AGENT_PERMISSION, EMAIL_PER_PERSON_KEY, emailCloses, emailFigures, emailGroups, emailInPeriod, emailOpenings, emailPerPerson,
  emailPrevious, emailRecords, emailSeries, emailWaiting, parseEmailFilter, type EmailCatalog, type EmailMessageFixture, type EmailThreadFixture,
} from "@/lib/email";
import {
  byOwner, daysSince, FOLLOW_UP_BY_OWNER_PERMISSION, FOLLOW_UP_PERMISSIONS, FOLLOW_UP_SUMMARY_PERMISSIONS, followUpPage, listRowsOf,
  MY_FOLLOW_UP_PERMISSIONS, ownRows, summarise,
} from "@/lib/follow-up";
import { createHash, randomBytes } from "node:crypto";
import { INVITE_TOKEN_RE } from "@/lib/invitations";
import { recordUrlPreview, settingsProblem } from "@/lib/sources";
import {
  applyConnections, callRecords, callRules, callsFigures, callsPerPerson, callsPerPersonTags, callsTagUse, CALLS_GROUPS, groupCalls, groupInbound, groupSpeedToLead,
  historyStartOf, inboundCalls, inboundFigures, missedReasonOf, parseCallsFilter, PER_AGENT_PERMISSION, previousCalls, previousPeriod, rangeProblem,
  FORMS_GROUPS, formsAnswersOf, formsFigures, formsHistoryStart, parseAnswerFilter, parseFormsFilter, previousForms, type FormSubmissionRecord,
  type CallRecord, type CallRules, type CallTagFixture, type InboundLine, type IntakeCounts, type PersonOf, type TelephonyCallFixture, timeInZone,
} from "@/lib/reports";
import { missedCallbacks, type CallerCall } from "@/lib/live";
import {
  cancellationRecords, cancellationsReport, DEALS_PER_PERSON_KEY, DEALS_PER_PERSON_PERMISSION, dealsPerPerson, FUNNEL_GROUPS, funnelDeals, funnelFilter,
  funnelLists, funnelPrevious, funnelReport, lostReasonsReport, parseFunnelFilter, reasonStateOf, type CancellationTicketFixture, type FunnelDeal,
  type FunnelDealFixture, type FunnelOptions, type FunnelPipelineFixture, type FunnelReasonOption, type KindRuleFixture,
} from "@/lib/funnel";
import { reviewMarketStates, reviewRecords, reviewsReport, type ReviewSource } from "@/lib/reviews";

// ---- Intake reports fixture (B11, 12 October 2026) -------------------------------------------
// Fictional, shaped like the rows of migration 0007d: invented deal ids, fictional record links,
// counts only. Two tenants: the main one has telephony and a shop connected, the second (the
// invest-analyst identity) has neither, so both states of every screen can be seen. Markets: NL, GB
// and DE with business hours, and deals whose market is unknown (no business hours: their business
// measures are empty, as in the database). One agent in five is not mapped to a person.

/** A second fictional tenant without telephony or a shop, for the not-connected states */
const MOCK_TENANT_2 = "00000000-0000-7000-8000-000000000002";
const MOCK_INVEST_ANALYST_ID = "00000000-0000-7000-8000-000000000106";

// Functions, not constants: MOCK_PRINCIPAL comes from a module that imports this one, so it is not
// initialised while this module loads
const connectionsOf = (me: Principal): SourceConnections =>
  me.tenantId === MOCK_TENANT_2 ? { telephony: false, commerce: false } : { telephony: true, commerce: true };
const marketsOf = (me: Principal): string[] => (me.tenantId === MOCK_TENANT_2 ? ["NL", "BE"] : ["NL", "GB", "DE", "unknown"]);
const MOCK_CRM_CONNECTION = "00000000-0000-7000-8000-00000000c001";
const MOCK_PIPELINES = [
  { id: "p-sales", label: "Sales (test)" },
  { id: "p-renewal", label: "Renewals (test)" },
];

/** A stable number from a text, so the fixture is the same on every read */
function hashOf(text: string): number {
  let h = 2166136261;
  for (let i = 0; i < text.length; i++) h = Math.imul(h ^ text.charCodeAt(i), 16777619);
  return (h >>> 0) / 4294967296;
}

/** hashOf with a final mix (murmur3's fmix32), so keys that differ only in their last character spread evenly (the forms fixture) */
function mixedHashOf(text: string): number {
  let h = Math.round(hashOf(text) * 4294967296) >>> 0;
  h = Math.imul(h ^ (h >>> 16), 0x85ebca6b);
  h = Math.imul(h ^ (h >>> 13), 0xc2b2ae35);
  return ((h ^ (h >>> 16)) >>> 0) / 4294967296;
}

/** Same answer as the database for a caller holding none of the permissions */
function assertAny(me: Principal, permissions: string[]): void {
  if (!permissions.some((x) => me.permissions.includes(x))) throw new CmaDbError("CMA06", "not permitted");
}

function assertReportRange(range: { from: DateKey; to: DateKey }): void {
  if (rangeProblem(range.from, range.to)) throw new CmaDbError("CMA04", "the range must run forward and cover at most 92 days");
}

function mockToday(me: Principal): DateKey {
  return dateKeyInZone(new Date(), me.timeZone);
}

/** intake.start_date of the fixture: six weeks back, so a custom range can start before it */
function mockStartDate(me: Principal): DateKey {
  return addDays(mockToday(me), -42);
}

function datesOf(range: { from: DateKey; to: DateKey }, me: Principal): DateKey[] {
  const out: DateKey[] = [];
  const first = range.from < mockStartDate(me) ? mockStartDate(me) : range.from;
  const last = range.to > mockToday(me) ? mockToday(me) : range.to;
  for (let d = first; d <= last; d = addDays(d, 1)) out.push(d);
  return out;
}

function mockIntakeCounts(me: Principal, date: DateKey, market: string): IntakeCounts | null {
  const h = (k: string, n: number) => Math.floor(hashOf(`${me.tenantId}:${date}:${market}:${k}`) * n);
  const weekend = [0, 6].includes(new Date(`${date}T12:00:00Z`).getUTCDay());
  const scale = (market === "unknown" ? 0.2 : market === "NL" ? 1 : 0.6) * (weekend ? 0.3 : 1);
  const n = (k: string, max: number) => h(k, Math.max(1, Math.round(max * scale)) + 1);
  const row: IntakeCounts = {
    date, market, formSubmissions: n("form", 14), dealsCreated: n("deal", 8), dealsClosed: n("dealc", 5),
    ticketsCreated: n("ticket", 6), ticketsClosed: n("ticketc", 5), callsIn: n("in", 30), callsOut: n("out", 45),
    taggedCalls: n("tag", 12), newCustomers: n("cust", 5), firstOrders: n("first", 4), repeatOrders: n("repeat", 2),
    renewals: n("renew", 3),
  };
  const any = Object.entries(row).some(([k, v]) => k !== "date" && k !== "market" && v !== 0);
  return any ? row : null;
}

function mockSpeedRows(me: Principal, range: { from: DateKey; to: DateKey }): SpeedToLeadRow[] {
  const markets = marketsOf(me);
  const today = mockToday(me);
  const now = Date.now();
  const rows: SpeedToLeadRow[] = [];
  for (const date of datesOf(range, me)) {
    // today always holds one deal still waiting for its first call, so the open deals list never depends on the
    // date's hash (on 15 to 18 October 2026 it held none, the list's table was absent and verify:hints counted 7
    // headers instead of 12)
    const deals = Math.max(date === today ? 1 : 0, Math.floor(hashOf(`${me.tenantId}:${date}:deals`) * 6));
    for (let i = 0; i < deals; i++) {
      const h = (k: string) => hashOf(`${me.tenantId}:${date}:${i}:${k}`);
      const market = markets[Math.floor(h("market") * markets.length)]!;
      const known = market !== "unknown";
      const pipeline = MOCK_PIPELINES[h("pipe") < 0.7 ? 0 : 1]!;
      const createdMs = Math.min(now - 60_000, localMs(date, `${String(8 + Math.floor(h("hour") * 10)).padStart(2, "0")}:${String(Math.floor(h("min") * 60)).padStart(2, "0")}`, me.timeZone));
      const createdAt = new Date(createdMs).toISOString();
      const recent = addDays(date, 3) >= today;
      const roll = h("status");
      const status: SpeedToLeadStatus = date === today && i === 0 ? "not_called_open" : roll < 0.72 ? "called" : recent ? "not_called_open" : "not_called_closed";
      const called = status === "called";
      const businessMinutes = Math.round(2 + h("speed") ** 2 * 300);
      const businessSeconds = called && known ? businessMinutes * 60 : null;
      const callAt = called ? new Date(createdMs + Math.round(businessMinutes * 60_000 * (1 + h("gap")))).toISOString() : null;
      const noon = known ? new Date(localMs(addDays(date, 1), "12:00", me.timeZone)).toISOString() : null;
      const team = TEAM[Math.floor(h("agent") * TEAM.length)]!;
      const mapped = Math.floor(h("agent") * 1000) % 5 !== 0;
      const waiting = status === "not_called_open" && known ? Math.round(30 + h("wait") * 900) * 60 : null;
      const late = !called && known && (waiting === null || waiting > 3600);
      rows.push({
        dealId: `00000000-0000-7000-8000-${String(rows.length + 1).padStart(12, "0")}`,
        connectionId: MOCK_CRM_CONNECTION,
        dealSourceId: String(90_000_000 + Math.floor(h("id") * 9_000_000)),
        pipelineId: pipeline.id,
        pipelineLabel: pipeline.label,
        date,
        createdAt,
        market,
        marketSource: known ? (h("src") < 0.8 ? "record" : "contact") : null,
        isClosed: status === "not_called_closed" || (called && h("closed") < 0.4),
        status,
        firstCallSourceId: called ? String(70_000_000 + Math.floor(h("call") * 9_000_000)) : null,
        firstCallAt: callAt,
        firstCallLinked: called ? connectionsOf(me).telephony && h("linked") < 0.8 : null,
        firstAnyCallAt: callAt,
        firstAnyDirection: called ? "outbound" : null,
        inboundFirst: false,
        firstConnectedAt: called && h("conn") < 0.6 ? callAt : null,
        // the first call's owner when called, else the deal's owner, as the database picks the agent
        agentUserId: mapped ? team.userId : null,
        agentFrom: called ? "call" : "deal",
        elapsedSeconds: callAt ? Math.round((Date.parse(callAt) - createdMs) / 1000) : null,
        businessSeconds,
        targetSeconds: 3600,
        withinTarget: businessSeconds !== null ? businessSeconds <= 3600 : late ? false : null,
        nextBusinessNoon: noon,
        beforeNextNoon: called && noon ? Date.parse(callAt!) < Date.parse(noon) : noon && now >= Date.parse(noon) ? false : null,
        waitingBusinessSeconds: waiting,
        recordUrl: `https://example.com/crm/deal/${String(90_000_000 + Math.floor(h("id") * 9_000_000))}`,
      });
    }
  }
  return rows.sort((a, b) => a.createdAt.localeCompare(b.createdAt) || a.dealSourceId.localeCompare(b.dealSourceId));
}

/** The checks of cma.data_quality_checks() in its order, with the database's descriptions */
const MOCK_CHECKS: [string, string][] = [
  ["deal_without_contact", "Lead deals without any contact"],
  ["deal_contact_incomplete", "Primary contacts of lead deals without country or language"],
  ["market_not_in_catalog", "Markets or countries written by a source that are not in the market catalog"],
  ["owner_without_person", "CRM owners without a CMA person"],
  ["telephony_user_without_person", "Telephony users without a CMA person"],
  ["crm_call_without_contact", "CRM calls without a contact association"],
  ["telephony_call_unlinked", "Telephony calls without a link to a CRM call after 24 hours (once both sources run)"],
  ["commerce_unmatched", "Commerce customers whose id no CRM contact holds"],
  ["commerce_ambiguous", "Commerce customers whose id several CRM contacts hold"],
  ["writeback_parked", "CRM write-backs parked for review (from migration 0007c)"],
  ["contact_slots_full", "Contacts whose first two ref slots of a system are both taken"],
  ["contact_country_differs", "Contacts whose country differs from the market of a store their commerce id belongs to"],
  ["customer_in_two_stores", "Commerce customer ids present in more than one store"],
  ["pipeline_unreviewed", "Pipelines seen but never reviewed by a person (counted by default)"],
  ["form_without_market", "Counted forms without a market"],
  // the reviews' checks (addition 0008ze), listed once the tenant has a reviews connection
  ["review_channel_unmapped", "Review channels without a market, with the reviews held of each"],
  ["market_without_review_channel", "Active markets without a counted review channel"],
];

// ---- Inbound service and callbacks fixture (addition 0008i, brief B15) ----------------------------
// Fictional calls on the test telephony connection (adapter phonetest): per day of a period, inbound
// calls on the NL and UK lines, answered after a few seconds or missed for every reason of Pulse4all's
// seed plus one code nobody configured (the defaults apply); and relative to now, for the Live board,
// a caller missed twice and then called back, a caller missed twice and not called back, a caller
// missed four days ago (outside the lookback), an anonymous caller, a call waiting now. Callers are
// opaque keys standing in for the hash, which the screens never see. The invest-analyst's tenant has
// no telephony.

const MOCK_TEL_CONNECTION = "00000000-0000-7000-8000-00000000c002";
const MOCK_TEL_SYSTEM = "phonetest";
const MOCK_INBOUND_LINES: InboundLine[] = [
  { connectionId: MOCK_TEL_CONNECTION, lineRef: "l-1", name: "NL sales line (test)", market: "NL", zone: "Europe/Amsterdam", isCounted: true },
  { connectionId: MOCK_TEL_CONNECTION, lineRef: "l-2", name: "UK sales line (test)", market: "GB", zone: "Europe/London", isCounted: true },
  { connectionId: MOCK_TEL_CONNECTION, lineRef: "l-3", name: "Test line (test)", market: null, zone: null, isCounted: false },
];
/** Pulse4all's seed (02) on the test adapter */
const MOCK_REASON_SEED: [string, string, boolean][] = [
  ["out_of_opening_hours", "Outside opening hours", false],
  ["short_abandoned", "Hung up within 10 s", false],
  ["abandoned_in_ivr", "Hung up in the menu", true],
  ["no_available_agent", "No agent available", true],
  ["agents_did_not_answer", "Agents did not answer", true],
  ["unknown", "Unknown", true],
];
/** The codes the fixture's missed calls carry; abandoned_in_classic has no catalog row */
const MOCK_MISSED_CODES = ["no_available_agent", "agents_did_not_answer", "abandoned_in_ivr", "short_abandoned", "out_of_opening_hours", "abandoned_in_classic", null];
const MOCK_SL_SECONDS = 20;
const MOCK_LOOKBACK_DAYS = 3;
const MOCK_WAITING_MAX = 30;

function mockReasons(me: Principal): MissedReason[] {
  const all = (state.missedReasons ??= new Map());
  let list = all.get(me.tenantId);
  if (!list) {
    list = me.tenantId === MOCK_TENANT_2 ? [] : MOCK_REASON_SEED.map(([code, label, sl]) =>
      ({ sourceSystem: MOCK_TEL_SYSTEM, code, label, countsInServiceLevel: sl, needsCallback: true }));
    all.set(me.tenantId, list);
  }
  return list;
}

/**
 * One business date's inbound calls on a line, in its zone; since addition 0008j an answered call
 * carries the telephony user who took it and its current tags (the Calls reports)
 */
function mockInboundOn(me: Principal, date: DateKey, line: InboundLine, now: number): TelephonyCallFixture[] {
  const out: TelephonyCallFixture[] = [];
  const weekend = [0, 6].includes(new Date(`${date}T12:00:00Z`).getUTCDay());
  const calls = Math.floor(hashOf(`${me.tenantId}:${date}:${line.lineRef}:calls`) * (weekend ? 4 : line.market === "NL" ? 22 : 12));
  for (let i = 0; i < calls; i++) {
    const h = (k: string) => hashOf(`${me.tenantId}:${date}:${line.lineRef}:${i}:${k}`);
    const evening = h("evening") < 0.06;
    const hour = evening ? 19 + Math.floor(h("hour") * 3) : 8 + Math.floor(h("hour") * 10);
    const started = localMs(date, `${String(hour).padStart(2, "0")}:${String(Math.floor(h("min") * 60)).padStart(2, "0")}`, line.zone!);
    if (started > now - 60_000) continue;
    const answered = !evening && h("answered") < 0.78;
    const answerSeconds = Math.round(3 + h("speed") ** 2 * 70);
    const code = evening ? "out_of_opening_hours" : MOCK_MISSED_CODES[Math.floor(h("reason") * MOCK_MISSED_CODES.length)]!;
    out.push({
      sourceId: String(800_000_000 + Math.floor(h("id") * 99_000_000)), connectionId: MOCK_TEL_CONNECTION, sourceSystem: MOCK_TEL_SYSTEM,
      direction: "inbound", startedAt: new Date(started).toISOString(),
      answeredAt: answered ? new Date(started + answerSeconds * 1000).toISOString() : null,
      endedAt: new Date(started + (answered ? answerSeconds + 120 + Math.floor(h("talk") * 600) : 5 + Math.floor(h("ring") * 90)) * 1000).toISOString(),
      missedReason: answered ? null : code, lineRef: line.lineRef,
      userRef: answered ? mockUserOf(h("user")) : null, tagRefs: answered ? mockTagsOf(h("tag")) : [],
    });
  }
  return out;
}

/** The fixture's inbound calls of the business dates in the range (the tenant's start date to today), each in its line's zone */
function mockPeriodCalls(me: Principal, range: { from: DateKey; to: DateKey }): TelephonyCallFixture[] {
  const now = Date.now();
  const out: TelephonyCallFixture[] = [];
  for (const date of datesOf({ from: addDays(range.from, -1), to: addDays(range.to, 1) }, me)) {
    for (const line of MOCK_INBOUND_LINES.filter((l) => l.isCounted)) out.push(...mockInboundOn(me, date, line, now));
  }
  return out;
}

// ---- Calls overview and calls per agent fixture (addition 0008j, brief B16) ----------------------
// The same inbound calls, now with the telephony user who took them and their tags, and outbound calls
// per line and day: unanswered ones (not connected), short ones (connected, no conversation), the NL line's
// first call of each day answered at exactly telephony.connected_min_seconds of talk (connected), and calls
// of up to fifteen minutes. Tags from the test connection's catalog: Quote and Courtesy call count, Internal
// does not, Voicemail means not reached (so its calls are no conversation, addition 0008zc); some calls are
// untagged and some carry only Internal. Telephony users 900001 to 900004 are linked
// to people of the fictional team (People, linked accounts), 900009 to nobody. The test line l-3 does not
// count: its calls are in the fixture and in no figure. The calls start at intake.start_date, as the
// inbound calls do: there the fixture's telephony history starts (addition 0008k), so a previous period
// before it shows no change, as in prod since its first calls of 1 October 2026.

/** The telephony users of the fixture: four linked to a person, 900009 to nobody */
const MOCK_TEL_USERS = ["900001", "900001", "900002", "900002", "900003", "900003", "900004", "900004", "900009"];
function mockUserOf(r: number): string {
  return MOCK_TEL_USERS[Math.floor(r * MOCK_TEL_USERS.length)]!;
}

/** Twelve more tags of the test connection, each used now and then */
const MOCK_EXTRA_TAGS = ["Order placed", "Callback planned", "Voicemail", "Wrong number", "Not interested", "Exchange", "Complaint", "Review asked",
  "Renewal", "Information sent", "Language", "Escalated"];

/** A conversation's tags: none, a counted one, two, only Internal (which does not count), or one of the twelve others */
function mockTagsOf(r: number): string[] {
  if (r < 0.25) return [];
  if (r < 0.42) return ["t-1"];
  if (r < 0.56) return ["t-2"];
  if (r < 0.62) return ["t-3"];
  if (r < 0.7) return ["t-1", "t-3"];
  if (r < 0.76) return ["t-1", "t-2"];
  return [`t-${4 + Math.min(11, Math.floor(((r - 0.76) / 0.24) * 12))}`];
}

/** One business date's outbound calls on a line */
function mockOutboundOn(me: Principal, date: DateKey, line: InboundLine, now: number): TelephonyCallFixture[] {
  const out: TelephonyCallFixture[] = [];
  const weekend = [0, 6].includes(new Date(`${date}T12:00:00Z`).getUTCDay());
  const calls = Math.floor(hashOf(`${me.tenantId}:${date}:${line.lineRef}:out`) * (weekend ? 5 : line.market === "NL" ? 26 : 14));
  for (let i = 0; i < calls; i++) {
    const h = (k: string) => hashOf(`${me.tenantId}:${date}:${line.lineRef}:out:${i}:${k}`);
    const atThreshold = i === 0 && line.lineRef === "l-1";
    const hour = atThreshold ? 9 : 8 + Math.floor(h("hour") * 10);
    const started = localMs(date, `${String(hour).padStart(2, "0")}:${String(Math.floor(h("min") * 60)).padStart(2, "0")}`, line.zone!);
    if (started > now - 60_000) continue;
    const answered = atThreshold || h("answered") < 0.6;
    const ring = 4 + Math.floor(h("ring") * 20);
    const r = h("talk");
    const talk = atThreshold ? mockConnectedMin() : r < 0.18 ? 2 + Math.floor(r * 40) : 20 + Math.floor(h("length") ** 2 * 900);
    out.push({
      sourceId: String(700_000_000 + Math.floor(h("id") * 99_000_000)), connectionId: MOCK_TEL_CONNECTION, sourceSystem: MOCK_TEL_SYSTEM,
      direction: "outbound", startedAt: new Date(started).toISOString(),
      answeredAt: answered ? new Date(started + ring * 1000).toISOString() : null,
      endedAt: new Date(started + (ring + (answered ? talk : 5)) * 1000).toISOString(),
      missedReason: null, lineRef: line.lineRef, userRef: mockUserOf(h("user")), tagRefs: answered && talk >= 10 ? mockTagsOf(h("tag")) : [],
    });
  }
  return out;
}

/** telephony.connected_min_seconds of the fixture's settings */
function mockConnectedMin(): number {
  const list = state.config ? state.config.settings : MOCK_SETTINGS;
  return Number(list.find((x) => x.key === "telephony.connected_min_seconds")?.value ?? 0);
}

/** calls.conversation_min_talk_seconds of the fixture's settings (addition 0008zc) */
function mockConversationMin(): number {
  const list = state.config ? state.config.settings : MOCK_SETTINGS;
  return Number(list.find((x) => x.key === "calls.conversation_min_talk_seconds")?.value ?? 30);
}

/** The rules that classify the fixture's calls: both thresholds and the tags meaning not reached or incorrect data (0008zc, 0008zd) */
function mockCallRules(me: Principal): CallRules {
  return callRules(mockConnectedMin(), mockConversationMin(), mockCallTags(me));
}

/**
 * Every call of the fixture from a day before `from` to a day after `to` (up to now), none before
 * intake.start_date (the first call of the fixture's telephony history): both directions, both lines,
 * and the test line that does not count
 */
function mockCalls(me: Principal, range: HoursRange): TelephonyCallFixture[] {
  if (!connectionsOf(me).telephony) return [];
  const now = Date.now();
  const last = range.to < mockToday(me) ? addDays(range.to, 1) : mockToday(me);
  const first = addDays(range.from, -1) < mockStartDate(me) ? mockStartDate(me) : addDays(range.from, -1);
  const out: TelephonyCallFixture[] = [];
  for (let date = first; date <= last; date = addDays(date, 1)) {
    for (const line of MOCK_INBOUND_LINES.filter((l) => l.isCounted)) out.push(...mockInboundOn(me, date, line, now), ...mockOutboundOn(me, date, line, now));
    const started = localMs(date, "11:15", "Europe/Amsterdam");
    if (started < now - 60_000) {
      out.push({ sourceId: `t3-${date}`, connectionId: MOCK_TEL_CONNECTION, sourceSystem: MOCK_TEL_SYSTEM, direction: "outbound",
        startedAt: new Date(started).toISOString(), answeredAt: new Date(started + 5000).toISOString(), endedAt: new Date(started + 125_000).toISOString(),
        missedReason: null, lineRef: "l-3", userRef: "900001", tagRefs: ["t-1"] });
    }
  }
  return out;
}

/** The test connection's tags with their configuration (Configuration, Sources) */
function mockCallTags(me: Principal): CallTagFixture[] {
  const c = seedIntakeConfig(me).sources.find((x) => x.connection.id === MOCK_TEL_CONNECTION);
  return (c?.tags ?? []).map((t) => ({ connectionId: MOCK_TEL_CONNECTION, tagRef: t.tagRef, name: t.name, isCounted: t.isCounted, meaning: t.meaning }));
}

/** Who a telephony user is: the person who holds `<adapter>_user` with that id on People */
function mockPersonOf(me: Principal): PersonOf {
  const accounts = seedIntakeConfig(me).accounts;
  const names = new Map(TEAM.map((p) => [p.userId, p.displayName]));
  return (system, userRef) => {
    const a = accounts.find((x) => x.system === `${system}_user` && x.externalId === userRef);
    return a ? { userId: a.userId, name: names.get(a.userId) ?? a.userId } : null;
  };
}

/** The checks of cma.calls_overview and the per-person reads: the permission, the range, the group and the filters */
function assertCalls(me: Principal, range: HoursRange, filter: CallsFilter, group: CallsGroup | null, permissions: string[]): void {
  assertAny(me, permissions);
  assertReportRange(range);
  if (group !== null && !CALLS_GROUPS.includes(group)) throw new CmaDbError("CMA04", "group by day, week, market or line");
  if (parseCallsFilter(filter.market ?? "", filter.line ?? "").problem) throw new CmaDbError("CMA04", "invalid filter");
}

function assertForms(me: Principal, range: HoursRange, group: FormsGroup, filter: FormsFilter): void {
  assertAny(me, ["reports.view", "performance.team"]);
  assertReportRange(range);
  if (!FORMS_GROUPS.includes(group)) throw new CmaDbError("CMA04", "group by day or week");
  if (parseFormsFilter(filter.market ?? "", filter.category ?? "", filter.form ?? "").problem) throw new CmaDbError("CMA04", "invalid filter");
}

/** The form categories with how many fixture forms carry each, in their order */
function mockFormCategories(me: Principal): FormCategory[] {
  const cfg = seedIntakeConfig(me);
  const forms = cfg.sources.flatMap((x) => x.forms);
  return [...cfg.categories].sort((a, b) => a.sortOrder - b.sortOrder || a.name.localeCompare(b.name))
    .map((k) => ({ ...k, forms: forms.filter((f) => f.category === k.code).length }));
}

// ---- Email reports fixture (addition 0008t; brief N19-A part 1) -------------------------------------
// Fictional conversations and engagements on the test CRM connection, shaped as the email poll stores them:
// three inboxes (Support with NL as its market, Sales without one, Internal not counted), four mailboxes
// (one labelled, one whose source name held an address so it shows its id, one labelled GB, one not counted),
// email and chat channels (chat not counted). Per day a few conversations: the customer writes, a bot answers
// now and then, an agent replies after a while (sometimes a failed attempt first), some are closed, some
// reopened after a close, one now and then reopened at the moment it starts (no opening), a few spam, some of
// an unknown market; the latest ones still waiting. Engagements: agent sends, automations, inbox copies (left
// out), bounces, logged replies, an owner id nobody holds. Owner ids map to the fixture's people through
// crmtest_owner. The second tenant has none of it. Everything invented and stable across reads.

const MOCK_EMAIL_SYSTEM = "crmtest";
const MOCK_EMAIL_INBOXES: Omit<SourceInbox, "isActive">[] = [
  { inboxId: "1500000001", name: "Support (test)", isCounted: true, market: "NL" },
  { inboxId: "1500000002", name: "Sales (test)", isCounted: true, market: null },
  { inboxId: "1500000003", name: "Internal (test)", isCounted: false, market: null },
];
const MOCK_EMAIL_ACCOUNTS: Omit<SourceMailbox, "isActive">[] = [
  { accountId: "1600000001", name: "Support NL (test)", label: null, inboxId: "1500000001", channelId: "1002", isCounted: true, market: null },
  { accountId: "1600000002", name: "1600000002", label: "Support GB (test)", inboxId: "1500000001", channelId: "1002", isCounted: true, market: "GB" },
  { accountId: "1600000003", name: "1600000003", label: null, inboxId: "1500000002", channelId: "1002", isCounted: true, market: null },
  { accountId: "1600000004", name: "Old box (test)", label: null, inboxId: "1500000001", channelId: "1002", isCounted: false, market: null },
];
/** Owner ids: two people and the manager hold theirs (crmtest_owner), the last nobody does */
const MOCK_EMAIL_OWNERS = ["70000001", "70000002", "70000009", "70000004"];

function mockEmailCatalog(me: Principal): EmailCatalog {
  const crm = seedIntakeConfig(me).sources.find((x) => x.connection.kind === "crm")!;
  const codes = (k: string) => String(crm.connection.settings[k] ?? "").split(",").map((x) => x.trim().toLowerCase()).filter(Boolean);
  return {
    inboxes: crm.inboxes.map((x) => ({ id: x.inboxId, name: x.name, isCounted: x.isCounted, market: x.market })),
    accounts: crm.mailboxes.map((x) => ({ id: x.accountId, name: x.name, label: x.label, isCounted: x.isCounted, market: x.market })),
    channels: crm.inboxChannels.map((x) => ({ id: x.channelId, isCounted: x.isCounted })),
    inboxCopyOrigins: codes("email_inbox_copy_origins"),
    automatedOrigins: codes("email_automated_origins"),
    zones: { NL: "Europe/Amsterdam", GB: "Europe/London", DE: "Europe/Berlin", BE: "Europe/Brussels" },
    tenantZone: "Europe/Amsterdam",
    officeHours: { 1: ["09:00", "17:00"], 2: ["09:00", "17:00"], 3: ["09:00", "17:00"], 4: ["09:00", "17:00"], 5: ["09:00", "17:00"] },
    replyTargetMinutes: mockSettingNumber(me, "email.reply_target_minutes"),
  };
}

function mockSettingNumber(_me: Principal, key: string): number {
  const list = state.config ? state.config.settings : MOCK_SETTINGS;
  const v = Number(list.find((x) => x.key === key)?.value);
  if (!Number.isFinite(v) || v <= 0) throw new Error(`mock setting ${key} is missing`);
  return v;
}

/** The stored conversations and emails of the main tenant, from the start date up to now */
function mockEmailStore(me: Principal): { threads: EmailThreadFixture[]; messages: EmailMessageFixture[] } {
  if (me.tenantId === MOCK_TENANT_2) return { threads: [], messages: [] };
  const conn = MOCK_CRM_CONNECTION;
  const now = Date.now();
  const threads: EmailThreadFixture[] = [];
  const messages: EmailMessageFixture[] = [];
  const iso = (ms: number) => new Date(ms).toISOString();
  const msg = (o: Partial<EmailMessageFixture> & Pick<EmailMessageFixture, "kind" | "direction" | "status" | "at" | "actorKind">): EmailMessageFixture => ({
    connectionId: conn, sourceSystem: MOCK_EMAIL_SYSTEM, threadId: null, inboxId: null, accountId: null, channelId: null, ownerRef: null, origin: null,
    category: null, market: null, deleted: false, ...o,
  });
  const markets = ["NL", "NL", "GB", "DE", null];
  for (let date = mockStartDate(me); date <= mockToday(me); date = addDays(date, 1)) {
    const weekend = [0, 6].includes(new Date(`${date}T12:00:00Z`).getUTCDay());
    const n = 2 + Math.floor(mixedHashOf(`${me.tenantId}:email:${date}`) * (weekend ? 2 : 9));
    for (let i = 0; i < n; i++) {
      const h = (k: string) => mixedHashOf(`${me.tenantId}:email:${date}:${i}:${k}`);
      const started = localMs(date, `${String(7 + Math.floor(h("hour") * 13)).padStart(2, "0")}:${String(Math.floor(h("min") * 60)).padStart(2, "0")}`, "Europe/Amsterdam");
      if (started > now - 5 * 60_000) continue;
      const inboxRoll = h("inbox");
      const inboxId = inboxRoll < 0.62 ? "1500000001" : inboxRoll < 0.92 ? "1500000002" : "1500000003";
      const accountRoll = h("account");
      const accountId = inboxId === "1500000002" ? "1600000003" : inboxId === "1500000003" ? null
        : accountRoll < 0.55 ? "1600000001" : accountRoll < 0.92 ? "1600000002" : "1600000004";
      const channelId = h("chat") < 0.05 ? "1003" : "1002";
      const market = markets[Math.floor(h("market") * markets.length)] ?? null;
      const id = `th-${date.replaceAll("-", "")}-${i}`;
      const t: EmailThreadFixture = { connectionId: conn, sourceSystem: MOCK_EMAIL_SYSTEM, id, inboxId, accountId, channelId, createdAt: iso(started),
        status: "open", isSpam: h("spam") < 0.04, category: h("cat") < 0.3 ? "billing" : h("cat") < 0.45 ? "partner" : null, market, events: [] };
      threads.push(t);
      const owner = MOCK_EMAIL_OWNERS[Math.floor(h("owner") * MOCK_EMAIL_OWNERS.length * 0.999)]!;
      const base = { threadId: id, inboxId, accountId, channelId, market, category: t.category };
      messages.push(msg({ kind: "inbox_message", direction: h("fwd") < 0.05 ? "forwarded" : "in", status: "other", at: iso(started), actorKind: "customer", ...base }));
      if (h("bot") < 0.2) messages.push(msg({ kind: "inbox_message", direction: "out", status: "sent", at: iso(started + 30_000), actorKind: "bot", ...base }));
      // the reply after 5 minutes to two working days, most within the morning; recent ones still waiting
      const replyAfter = Math.round((5 + h("reply") ** 3 * 2400) * 60_000);
      const replied = started + replyAfter < now - 60_000 && h("noreply") > 0.05;
      if (replied && h("failed") < 0.04) messages.push(msg({ kind: "inbox_message", direction: "out", status: "failed", at: iso(started + replyAfter - 60_000), actorKind: "agent", ownerRef: owner, ...base }));
      if (replied) messages.push(msg({ kind: "inbox_message", direction: "out", status: "sent", at: iso(started + replyAfter), actorKind: "agent", ownerRef: owner, ...base }));
      // a reopen at the moment it starts (no opening), now and then
      if (h("reopenAtStart") < 0.05) t.events.push({ kind: "reopened", at: iso(started + 1000), actorKind: "system", ownerRef: null });
      const closeAt = started + replyAfter + Math.round((10 + h("close") * 600) * 60_000);
      if (replied && closeAt < now - 60_000 && h("closed") < 0.8) {
        t.events.push({ kind: "closed", at: iso(closeAt), actorKind: h("closer") < 0.85 ? "agent" : "system", ownerRef: h("closer") < 0.85 ? owner : null });
        t.status = "closed";
        // reopened after the close by a new message, answered again
        const again = closeAt + Math.round((60 + h("again") * 1440) * 60_000);
        if (h("reopen") < 0.15 && again < now - 60_000) {
          messages.push(msg({ kind: "inbox_message", direction: "in", status: "other", at: iso(again - 1000), actorKind: "customer", ...base }));
          t.events.push({ kind: "reopened", at: iso(again), actorKind: "system", ownerRef: null });
          t.status = "open";
          const second = again + Math.round((5 + h("second") * 300) * 60_000);
          if (second < now - 60_000) messages.push(msg({ kind: "inbox_message", direction: "out", status: "sent", at: iso(second), actorKind: "agent", ownerRef: owner, ...base }));
        }
      }
    }
    // engagements of the day: agent sends, automations, inbox copies each way, a bounce, logged replies
    const m = 4 + Math.floor(mixedHashOf(`${me.tenantId}:engagements:${date}`) * (weekend ? 3 : 16));
    for (let i = 0; i < m; i++) {
      const h = (k: string) => mixedHashOf(`${me.tenantId}:engagements:${date}:${i}:${k}`);
      const at = localMs(date, `${String(8 + Math.floor(h("hour") * 11)).padStart(2, "0")}:${String(Math.floor(h("min") * 60)).padStart(2, "0")}`, "Europe/Amsterdam");
      if (at > now - 60_000) continue;
      const roll = h("kind");
      const market = markets[Math.floor(h("market") * markets.length)] ?? null;
      const owner = MOCK_EMAIL_OWNERS[Math.floor(h("owner") * MOCK_EMAIL_OWNERS.length * 0.999)]!;
      const category = h("cat") < 0.25 ? "billing" : null;
      if (roll < 0.55) messages.push(msg({ kind: "crm_email", direction: "out", status: "sent", at: iso(at), actorKind: owner ? "agent" : "unknown", ownerRef: h("noowner") < 0.05 ? null : owner, origin: "CRM_UI", market, category }));
      else if (roll < 0.68) messages.push(msg({ kind: "crm_email", direction: "out", status: "sent", at: iso(at), actorKind: "system", origin: "AUTOMATION_PLATFORM", market, category }));
      else if (roll < 0.8) messages.push(msg({ kind: "crm_email", direction: h("copyIn") < 0.5 ? "out" : "in", status: "sent", at: iso(at), actorKind: "agent", ownerRef: owner, origin: "CONVERSATIONS", market }));
      else if (roll < 0.84) messages.push(msg({ kind: "crm_email", direction: "out", status: "bounced", at: iso(at), actorKind: "agent", ownerRef: owner, origin: "CRM_UI", market }));
      else messages.push(msg({ kind: "crm_email", direction: "in", status: "other", at: iso(at), actorKind: "customer", origin: "EMAIL_INTEGRATION", market, category, deleted: h("deleted") < 0.03 }));
    }
  }
  return { threads, messages };
}

function mockEmailPersonOf(me: Principal) {
  const accounts = seedIntakeConfig(me).accounts;
  const names = new Map([...TEAM.map((p) => [p.userId, p.displayName] as const), [MOCK_MANAGER_ID, "Test manager"] as const]);
  return (system: string, ownerRef: string | null) => {
    const a = ownerRef === null ? undefined : accounts.find((x) => x.system === `${system}_owner` && x.externalId === ownerRef);
    return a ? { userId: a.userId, name: names.get(a.userId) ?? a.userId } : null;
  };
}

// ---- First orders (addition 0008u): the fixture's won order deals with what the database would find around them.
// Invented ids; today always holds one first order of every level, a repeat, a renewal, a store repeat, one without
// a contact, an order without a phone hash and one in pounds, so every page shows each case whatever the date.

/** The tenant's attribution settings as the mock holds them */
function mockAttribution(): AttributionSettings {
  const list = (k: string) => (mockSetting(k) === "" ? [] : (mockSetting(k).split(",") as FirstOrderEvidence[]));
  return {
    windowDays: Number(mockSetting("attribution.window_days")), levelOrder: list("attribution.level_order"), assistedLevels: list("attribution.assisted_levels"),
    knownContactMinutes: Number(mockSetting("attribution.known_contact_minutes")), orderMatchMinutes: Number(mockSetting("attribution.order_match_minutes")),
  };
}

const MOCK_ORDER_ZONES: Record<string, string> = { NL: "Europe/Amsterdam", GB: "Europe/London", DE: "Europe/Berlin" };

function mockOrderDeals(me: Principal): OrderDealFixture[] {
  if (me.tenantId === MOCK_TENANT_2) return [];
  const today = mockToday(me);
  const now = Date.now();
  const markets = ["NL", "NL", "GB", "DE", "unknown"];
  const owners = [{ system: "crmtest_owner", ref: "70000001" }, { system: "crmtest_owner", ref: "70000002" }, { system: "crmtest_owner", ref: "70000009" },
    { system: "crmtest_owner", ref: "70000004" }, { system: "phonetest_user", ref: "900001" }];
  const out: OrderDealFixture[] = [];
  const ago = (t: number, days: number) => new Date(t - days * 86_400_000).toISOString();
  const deal = (id: string, t: number, market: string, o: Partial<OrderDealFixture>): OrderDealFixture => ({
    connectionId: MOCK_CRM_CONNECTION, dealSourceId: id, createdAt: new Date(t).toISOString(), market, zone: MOCK_ORDER_ZONES[market] ?? me.timeZone,
    contact: `k-${id}`, earlierOrderDeal: false, storeOrderKind: "first", currency: market === "GB" ? "GBP" : "EUR", amount: 89.95, phoneHashed: true,
    contactCreatedAt: new Date(t - 10 * 60_000).toISOString(), touches: [], recordUrl: `https://example.com/crm/deal/${id}`, ...o,
  });
  const touch = (kind: OrderTouch["kind"], t: number, days: number, owner: number): OrderTouch =>
    ({ kind, at: ago(t, days), system: owners[owner]!.system, ownerRef: owners[owner]!.ref });
  for (let date = mockStartDate(me); date <= today; date = addDays(date, 1)) {
    const weekend = [0, 6].includes(new Date(`${date}T12:00:00Z`).getUTCDay());
    const n = Math.floor(hashOf(`${me.tenantId}:orders:${date}`) * (weekend ? 3 : 6));
    for (let i = 0; i < n; i++) {
      const h = (k: string) => hashOf(`${me.tenantId}:order:${date}:${i}:${k}`);
      const market = markets[Math.floor(h("market") * markets.length)]!;
      const t = Math.min(now - 60_000, localMs(date, `${String(8 + Math.floor(h("hour") * 12)).padStart(2, "0")}:${String(Math.floor(h("min") * 60)).padStart(2, "0")}`,
        MOCK_ORDER_ZONES[market] ?? me.timeZone));
      const roll = h("kind");
      const touches: OrderTouch[] = [];
      if (h("lead") < 0.35) touches.push(touch("lead_deal", t, 1 + h("leadAt") * 20, Math.floor(h("leadOwner") * 4)));
      if (h("conv") < 0.25) touches.push(touch("conversation", t, 0.5 + h("convAt") * 10, Math.floor(h("convOwner") * 4)));
      if (h("email") < 0.3) touches.push(touch("email", t, 0.2 + h("emailAt") * 15, Math.floor(h("emailOwner") * 4)));
      if (h("phone") < 0.12) touches.push(touch("phone_match", t, 1 + h("phoneAt") * 30, 4));
      if (h("attempt") < 0.15) touches.push(touch("attempt", t, 0.5 + h("attemptAt") * 5, Math.floor(h("attemptOwner") * 4)));
      out.push(deal(`9${date.replaceAll("-", "").slice(2)}${String(i).padStart(2, "0")}`, t, market, {
        contact: roll < 0.05 ? null : `k-${date}-${i}`,
        earlierOrderDeal: roll >= 0.05 && roll < 0.13,
        storeOrderKind: roll >= 0.13 && roll < 0.18 ? "renewal" : roll >= 0.18 && roll < 0.22 ? "repeat" : h("noOrder") < 0.1 ? null : "first",
        currency: h("noAmount") < 0.08 ? null : market === "GB" ? "GBP" : "EUR",
        amount: h("noAmount") < 0.08 ? null : Math.round((49.95 + h("amount") * 250) * 100) / 100,
        phoneHashed: h("hashed") < 0.7,
        contactCreatedAt: h("known") < 0.4 ? ago(t, 200) : new Date(t - 10 * 60_000).toISOString(),
        touches,
      }));
    }
  }
  // today's fixed cases, a few minutes apart
  const at = (k: number) => now - (k + 1) * 7 * 60_000;
  out.push(
    deal("8100000001", at(0), "NL", { touches: [touch("lead_deal", at(0), 3, 0), touch("email", at(0), 1, 1)] }),
    deal("8100000002", at(1), "GB", { touches: [touch("conversation", at(1), 2, 1)] }),
    deal("8100000003", at(2), "NL", { touches: [touch("email", at(2), 1, 3)] }),
    deal("8100000004", at(3), "DE", { touches: [touch("phone_match", at(3), 6, 4), touch("phone_match", at(3), 9, 2)] }),
    deal("8100000005", at(4), "NL", { touches: [touch("attempt", at(4), 1, 0)] }),
    deal("8100000006", at(5), "NL", { contactCreatedAt: ago(at(5), 300), phoneHashed: false }),
    deal("8100000007", at(6), "unknown", { currency: null, amount: null }),
    deal("8100000008", at(7), "NL", { contact: null }),
    deal("8100000009", at(8), "NL", { earlierOrderDeal: true }),
    deal("8100000010", at(9), "NL", { storeOrderKind: "renewal" }),
    deal("8100000011", at(10), "GB", { storeOrderKind: "repeat" }),
  );
  return out;
}

// ---- Attempts per deal (addition 0008y; for sales since 0008z): the fixture's deals with the CRM calls the database would find
// for them (each call at its effective start, outbound or inbound; linked to a telephony call with its answer and talk time, or
// logged without one; with an outcome from the catalog or none) and their contacts' orders. Invented ids; from the start date
// to today, more on weekdays, the lead pipeline Sales and the counted Renewals (never counted since 0008z), owners of the
// linked accounts (one owner id nobody holds and deals without an owner), a share closed won, lost or without an outcome, a
// share ordered another way, and today's fixed cases: never attempted, a call in the pre-window, seven attempts, an inbound
// call only, a deal of an unknown market, a call logged without a telephony call. The invest tenant's deals have no call.

const MOCK_ATTEMPT_ZONES: Record<string, string> = { NL: "Europe/Amsterdam", GB: "Europe/London", DE: "Europe/Berlin" };
const MOCK_TENANT_ZONE = "Europe/Amsterdam";
const MOCK_NO_ATTEMPT_FILTER: AttemptFilter = { market: null, pipeline: null, attempted: "all", outcome: "all" };
/** The fixture's call outcomes (the CRM's catalog): labels only, since an outcome decides neither connected nor a conversation (0008zc) */
const MOCK_OUTCOMES: string[] = ["Connected", "Meeting booked", "No answer", "Left voicemail", "Busy"];

function mockAttemptSettings(): AttemptSettings {
  return {
    maxBucket: Number(mockSetting("attempts.max_bucket")), sinceLastBuckets: mockSetting("attempts.since_last_buckets_business_days"),
    preWindowMinutes: Number(mockSetting("speed_to_lead.pre_window_minutes")), listRows: Number(mockSetting("follow_up.list_rows")),
    source: mockSetting("attempts.source") === "crm" ? "crm" : "telephony", conversationMinTalkSeconds: Number(mockSetting("calls.conversation_min_talk_seconds")),
    speedBuckets: mockSetting("attempts.speed_buckets_business_minutes"),
  };
}

/** A stable uuid-shaped id for a fixture deal (the CMA's deal id), from its source id */
function mockDealId(me: Principal, sourceId: string): string {
  const hex = (k: string) => Math.floor(mixedHashOf(`${me.tenantId}:deal-id:${sourceId}:${k}`) * 0xffffffff).toString(16).padStart(8, "0");
  const x = `${hex("a")}${hex("b")}${hex("c")}${hex("d")}`;
  return `${x.slice(0, 8)}-${x.slice(8, 12)}-7${x.slice(13, 16)}-8${x.slice(17, 20)}-${x.slice(20, 32)}`;
}

function mockAttemptDeals(me: Principal): AttemptDealFixture[] {
  const today = mockToday(me);
  const now = Date.now();
  const invest = me.tenantId === MOCK_TENANT_2;
  const markets = invest ? ["NL", "NL", "unknown"] : ["NL", "NL", "GB", "DE", "unknown"];
  const owners: (string | null)[] = ["70000001", "70000002", "70000009", "70000004", null];
  const agents = ["Agent One", "Agent Two", "Test supervisor", null];
  const out: AttemptDealFixture[] = [];
  const deal = (id: string, t: number, market: string, o: Partial<AttemptDealFixture>): AttemptDealFixture => ({
    dealId: mockDealId(me, id), connectionId: MOCK_CRM_CONNECTION, dealSourceId: id, pipelineId: "p-sales", pipelineLabel: "Sales (test)",
    stageLabel: "Open", isLead: true, isOrder: false, isCounted: true, market, zone: MOCK_ATTEMPT_ZONES[market] ?? null, ownerRef: owners[0]!,
    createdAt: new Date(t).toISOString(), isClosed: false, closedAt: null, stageOutcome: null,
    recordUrl: `https://crm.example.com/records/100200300/deal/${id}`, calls: [], orders: [], ...o,
  });
  const call = (id: string, t: number, o: Partial<AttemptCallFixture> = {}): AttemptCallFixture => ({
    id, at: new Date(t).toISOString(), direction: "outbound", linked: true, outcome: "No answer", connected: false,
    talkSeconds: null, agentName: "Agent One", ...o,
  });
  for (let date = mockStartDate(me); date <= today; date = addDays(date, 1)) {
    const weekend = [0, 6].includes(new Date(`${date}T12:00:00Z`).getUTCDay());
    const n = 1 + Math.floor(hashOf(`${me.tenantId}:attempts:${date}`) * (weekend ? 2 : 7));
    for (let i = 0; i < n; i++) {
      const h = (k: string) => mixedHashOf(`${me.tenantId}:attempt:${date}:${i}:${k}`);
      const market = markets[Math.floor(h("market") * markets.length)]!;
      const t = Math.min(now - 30 * 60_000, localMs(date, `${String(8 + Math.floor(h("hour") * 10)).padStart(2, "0")}:${String(Math.floor(h("min") * 60)).padStart(2, "0")}`,
        MOCK_ATTEMPT_ZONES[market] ?? MOCK_TENANT_ZONE));
      const id = `4${date.replaceAll("-", "").slice(2)}${String(i).padStart(2, "0")}`;
      const tries = invest ? 0 : [0, 1, 1, 2, 2, 3, 3, 4, 5, 6, 8][Math.floor(h("tries") * 11)]!;
      const calls: AttemptCallFixture[] = [];
      let at = t + (5 + h("first") * 120) * 60_000;
      for (let k = 0; k < tries && at < now; k++) {
        const g = (x: string) => h(`c${k}${x}`);
        const answered = g("answered") < 0.45;
        const talk = answered ? Math.floor(g("talk") ** 2 * 600) : null;
        // a third of the calls carry no outcome (the agent did not set one), the rest one from the catalog; a voicemail the
        // agent tagged not reached in the telephony system is never a conversation, whatever its talk time
        const outcome = g("outcome") < 0.33 ? null : answered && talk! > 20 ? MOCK_OUTCOMES[Math.floor(g("which") * 2)]! : MOCK_OUTCOMES[2 + Math.floor(g("which") * 3)]!;
        calls.push(call(`c-${id}-${k}`, at, {
          linked: g("linked") >= 0.08, connected: answered, talkSeconds: talk, outcome, notReached: answered && outcome === "Left voicemail",
          agentName: agents[Math.floor(g("agent") * agents.length)]!,
        }));
        at += (2 + h(`gap${k}`) * 30) * 3_600_000;
      }
      if (!invest && h("inbound") < 0.15) calls.push(call(`c-${id}-in`, t + 90 * 60_000, { direction: "inbound", outcome: "Connected", connected: false, talkSeconds: 120 }));
      const roll = h("close");
      const closedAt = t + (1 + h("closeAt") * 6) * 86_400_000;
      const closed = roll < 0.42 && closedAt < now;
      const ordered = !invest && h("order") < 0.12 ? t + (0.5 + h("orderAt") * 5) * 86_400_000 : null;
      const renewal = h("pipeline") < 0.12;
      out.push(deal(id, t, market, {
        pipelineId: renewal ? "p-renewal" : "p-sales", pipelineLabel: renewal ? "Renewals (test)" : "Sales (test)", isLead: !renewal,
        ownerRef: owners[Math.floor(h("owner") * owners.length)]!,
        isClosed: closed, closedAt: closed ? new Date(closedAt).toISOString() : null,
        stageOutcome: closed ? (roll < 0.2 ? "won" : roll < 0.37 ? "lost" : null) : null,
        stageLabel: closed ? (roll < 0.2 ? "Closed won" : roll < 0.37 ? "Closed lost" : "Closed") : "Open", calls,
        orders: ordered === null ? [] : [{ createdAt: new Date(ordered).toISOString(), at: new Date(ordered).toISOString() }],
      }));
    }
  }
  if (invest) return out;
  // today's fixed cases, an hour apart, and an order deal that never counts
  const at = (k: number) => now - (k + 2) * 60 * 60_000;
  out.push(
    deal("4100000001", at(0), "NL", { ownerRef: "70000001" }),
    deal("4100000002", at(1), "NL", { ownerRef: "70000002", calls: [call("c-41-2a", at(1) - 5 * 60_000)] }),
    deal("4100000003", at(2), "GB", { ownerRef: "70000009", calls: Array.from({ length: 7 }, (_, k) => call(`c-41-3-${k}`, at(2) + (k + 1) * 6 * 60_000,
      k === 6 ? { outcome: "Connected", connected: true, talkSeconds: 240 } : k === 4 ? { outcome: null, connected: true, talkSeconds: 12 } : {})) }),
    deal("4100000004", at(3), "DE", { ownerRef: null, calls: [call("c-41-4in", at(3) + 10 * 60_000, { direction: "inbound", outcome: "Connected", connected: false, talkSeconds: 60 })] }),
    deal("4100000005", at(4), "unknown", { ownerRef: "70000004", calls: [call("c-41-5a", at(4) + 15 * 60_000, { outcome: null, connected: true, talkSeconds: 95 })] }),
    deal("4100000007", at(6), "NL", { ownerRef: "70000001", calls: [call("c-41-7a", at(6) + 3 * 60_000, { linked: false, outcome: null }),
      call("c-41-7b", at(6) + 40 * 60_000, { outcome: "Left voicemail", connected: true, talkSeconds: 85, notReached: true })] }),
    deal("4100000006", at(5), "NL", { pipelineId: "p-self-serve", pipelineLabel: "Web orders (test)", stageLabel: "Won", isLead: false, isOrder: true, isClosed: true,
      closedAt: new Date(at(5)).toISOString(), stageOutcome: "won", calls: [call("c-41-6a", at(5) + 60_000, { outcome: "Connected" })] }),
  );
  return out;
}

/** Office hours (the market's own, else every market's) on a weekday and no holiday of the market or of every market, as the fixture holds them */
function mockWorkingDay(me: Principal): WorkingDay {
  const c = seedIntakeConfig(me);
  return (market, date) => {
    const weekday = ((new Date(`${date}T12:00:00Z`).getUTCDay() + 6) % 7) + 1;
    const sched = c.hours.some((x) => x.market === market) ? market : "*";
    return c.hours.some((x) => x.market === sched && x.weekday === weekday)
      && !c.holidays.some((x) => (x.market === market || x.market === "*") && x.day === date);
  };
}

/** What the definition reads besides the deals, as the fixture holds it: the settings, the working days, the office time */
function mockAttemptOptions(me: Principal): AttemptOptions {
  const s = mockAttemptSettings();
  const accounts = seedIntakeConfig(me).accounts;
  const working = mockWorkingDay(me);
  return {
    source: s.source, preWindowMinutes: s.preWindowMinutes, conversationMinTalkSeconds: s.conversationMinTalkSeconds, sinceLastBuckets: s.sinceLastBuckets,
    now: new Date().toISOString(), tenantZone: MOCK_TENANT_ZONE, working,
    ownerUserOf: (ref) => (ref === null ? null : accounts.find((x) => x.system === "crmtest_owner" && x.externalId === ref)?.userId ?? null),
    businessSeconds: (market, from, to) => (Date.parse(to) <= Date.parse(from) ? (MOCK_ATTEMPT_ZONES[market] ? 0 : null) : mockBusinessSeconds(market, from, Date.parse(to))),
    nextNoon: (market, at) => {
      const zone = MOCK_ATTEMPT_ZONES[market];
      if (!zone) return null;
      for (let i = 1, d = addDays(dateKeyInZone(at, zone), 1); i <= 31; i += 1, d = addDays(d, 1)) {
        if (working(market, d)) return new Date(localMs(d, "12:00", zone)).toISOString();
      }
      return null;
    },
  };
}

function mockAttemptRecords(me: Principal) {
  return attemptRecords(mockAttemptDeals(me), mockAttemptOptions(me));
}

/** The filter lists of the period without the filters: markets (unknown last) and pipelines by label */
function mockAttemptLists(rows: ReturnType<typeof mockAttemptRecords>) {
  return {
    markets: [...new Set(rows.map((r) => r.market))].sort((a, b) => (a === "unknown" ? 1 : b === "unknown" ? -1 : a.localeCompare(b))),
    pipelines: [...new Map(rows.map((r) => [`${r.connectionId}:${r.pipelineId}`, r.pipelineLabel])).entries()]
      .map(([key, label]) => ({ key, label })).sort((a, b) => a.label.localeCompare(b.label) || a.key.localeCompare(b.key)),
  };
}

function mockAttemptsHistory(me: Principal, rows: ReturnType<typeof mockAttemptRecords>): DateKey | null {
  const first = rows.flatMap((r) => (r.firstAttemptAt ? [dateKeyInZone(r.firstAttemptAt, MOCK_TENANT_ZONE)] : [])).sort()[0];
  return first === undefined || me.tenantId === MOCK_TENANT_2 ? null : (first < mockStartDate(me) ? mockStartDate(me) : first);
}

function assertAttempts(me: Principal, range: HoursRange, filter: AttemptFilter, group: AttemptGroup | null, permissions: string[]): void {
  assertAny(me, permissions);
  assertReportRange(range);
  if (group !== null && !ATTEMPT_GROUPS.includes(group)) throw new CmaDbError("CMA04", "group by day, week, market or pipeline");
  if (parseAttemptFilter(filter.market ?? "", filter.pipeline ?? "", filter.attempted, filter.outcome).problem) throw new CmaDbError("CMA04", "invalid filter");
}

// ---- Funnel, lost reasons and cancellations (addition 0008zb): the attempts fixture's sales deals with a stage history
// (each entered New at its creation, then Qualified and Quote sent a few days apart; a won or lost deal entered Won or Lost
// at its close), a source channel, a lost reason from the CRM connection's catalog (a share without one) and an amount on
// a share of the won deals; the CRM connection's tickets, one to three a weekday, in the Cancellations pipeline and some in
// Support with the category Cancellation (test) (the kind's two rules), others not of the kind. Invented ids and values.

const MOCK_SOURCE_CHANNELS = ["paid_search", "organic", "direct", "referral", null];
const MOCK_LOST_REASONS = ["too_expensive", "bad_timing", "chose_other", "no_budget", "duplicate", "wrong_number", null, null];

/** The CRM connection's deal pipelines as the funnel reads them (the stages' read_times in force unless a person chose) */
function mockFunnelPipelines(me: Principal): FunnelPipelineFixture[] {
  const crm = seedIntakeConfig(me).sources.find((x) => x.connection.adapter === "crmtest")!;
  return crm.pipelines.filter((p) => p.recordType === "deal").map((p) => ({
    connectionId: crm.connection.id, pipelineId: p.pipelineId, label: p.label, isCounted: p.isCounted, isLead: p.isLead, isOrder: p.isOrder, isActive: p.isActive,
    stages: p.stages.map((x, i) => ({ stageId: x.stageId, label: x.label, order: i + 1, isClosed: x.isClosed, outcome: x.outcome,
      readTimes: x.readTimesSet ? x.readTimes : null, isActive: x.isActive })),
  }));
}

/** The CRM connection's reason field state and options of a record type */
function mockReasonsOf(me: Principal, recordType: "deal" | "ticket"): { state: ReturnType<typeof reasonStateOf>; options: FunnelReasonOption[] } {
  const crm = seedIntakeConfig(me).sources.find((x) => x.connection.adapter === "crmtest")!;
  const f = crm.fields.find((x) => x.entity === recordType && x.field === "reason");
  return {
    state: reasonStateOf(f?.property ?? null, f?.sourceType ?? null),
    options: crm.reasons.filter((x) => x.recordType === recordType)
      .map((x) => ({ value: x.value, label: x.label, isDataQuality: x.isDataQuality, sortOrder: x.order })),
  };
}

function mockFunnelOptions(me: Principal): FunnelOptions {
  const markets = seedIntakeConfig(me).markets;
  return {
    tenantZone: MOCK_TENANT_ZONE, startDate: mockStartDate(me), now: new Date().toISOString(), ownerUserOf: mockAttemptOptions(me).ownerUserOf,
    currencyOf: (m) => markets.find((x) => x.code === m)?.currency ?? null,
  };
}

function mockFunnelFixtures(me: Principal): FunnelDealFixture[] {
  const now = Date.now();
  const reasonsOn = mockReasonsOf(me, "deal").state === "enumeration";
  return mockAttemptDeals(me).map((d): FunnelDealFixture => {
    const h = (k: string) => mixedHashOf(`${me.tenantId}:funnel:${d.dealSourceId}:${k}`);
    const t0 = Date.parse(d.createdAt);
    const end = d.isClosed && d.closedAt ? Date.parse(d.closedAt) : now;
    const qualified = t0 + (0.2 + h("q") * 2) * 86_400_000;
    const quote = qualified + (0.5 + h("o") * 3) * 86_400_000;
    const path: { stageId: string; at: number }[] = [{ stageId: d.isOrder ? "s-paid" : "s-new", at: t0 }];
    if (!d.isOrder) {
      const reach = d.stageOutcome === "won" ? 2 : h("reach") < 0.55 ? 1 : h("reach") < 0.8 ? 2 : 0;
      if (reach >= 1 && qualified < end) path.push({ stageId: "s-qualified", at: qualified });
      if (reach >= 2 && quote < end) path.push({ stageId: "s-quote", at: quote });
      if (d.isClosed) path.push({ stageId: d.stageOutcome === "won" ? "s-won" : d.stageOutcome === "lost" ? "s-lost" : "s-closed", at: end });
    }
    const iso = (x: number) => new Date(x).toISOString();
    const won = d.stageOutcome === "won";
    return {
      dealId: d.dealId, connectionId: d.connectionId, dealSourceId: d.dealSourceId, pipelineId: d.pipelineId, stageId: path.at(-1)!.stageId, market: d.market,
      sourceChannel: MOCK_SOURCE_CHANNELS[Math.floor(h("channel") * MOCK_SOURCE_CHANNELS.length)]!,
      reason: reasonsOn && d.stageOutcome === "lost" ? MOCK_LOST_REASONS[Math.floor(h("reason") * MOCK_LOST_REASONS.length)]! : null,
      ownerRef: d.ownerRef, createdAt: d.createdAt, closedAt: d.closedAt, isClosed: d.isClosed,
      amount: won && h("amount") < 0.8 ? Math.round(400 + h("value") * 1600) : null, currency: null, recordUrl: d.recordUrl,
      stages: path.map((x, i) => ({ stageId: x.stageId, enteredAt: iso(x.at), exitedAt: path[i + 1] ? iso(path[i + 1]!.at) : null })),
    };
  });
}

function mockFunnelDeals(me: Principal): { deals: FunnelDeal[]; entries: Instant[] } {
  const fixtures = mockFunnelFixtures(me);
  return {
    deals: funnelDeals(fixtures, mockFunnelPipelines(me), mockFunnelOptions(me)),
    entries: fixtures.flatMap((d) => d.stages.flatMap((x) => (x.enteredAt ? [x.enteredAt] : []))),
  };
}

function assertFunnel(me: Principal, range: HoursRange, filter: FunnelFilter, group: FunnelGroup | null, permissions: string[]): void {
  assertAny(me, permissions);
  assertReportRange(range);
  if (group !== null && !FUNNEL_GROUPS.includes(group)) throw new CmaDbError("CMA04", "group by day or week");
  if (parseFunnelFilter(filter.market ?? "", filter.pipeline ?? "", filter.sourceChannel ?? "").problem) throw new CmaDbError("CMA04", "invalid filter");
}

/** The tickets of the CRM connection (record kinds, 0008zb): the Cancellations pipeline, Support with a category, a deleted one */
function mockTickets(me: Principal): CancellationTicketFixture[] {
  const today = mockToday(me);
  const now = Date.now();
  const crm = seedIntakeConfig(me).sources.find((x) => x.connection.adapter === "crmtest")!;
  const reasonsOn = mockReasonsOf(me, "ticket").state === "enumeration";
  const markets = me.tenantId === MOCK_TENANT_2 ? ["NL", "BE", "unknown"] : ["NL", "NL", "GB", "DE", "unknown"];
  const label = (id: string) => crm.pipelines.find((p) => p.recordType === "ticket" && p.pipelineId === id);
  const out: CancellationTicketFixture[] = [];
  for (let date = mockStartDate(me); date <= today; date = addDays(date, 1)) {
    const weekend = [0, 6].includes(new Date(`${date}T12:00:00Z`).getUTCDay());
    const n = weekend ? 0 : 1 + Math.floor(hashOf(`${me.tenantId}:tickets:${date}`) * 3);
    for (let i = 0; i < n; i++) {
      const h = (k: string) => mixedHashOf(`${me.tenantId}:ticket:${date}:${i}:${k}`);
      const market = markets[Math.floor(h("market") * markets.length)]!;
      const t = Math.min(now - 20 * 60_000, localMs(date, `${String(8 + Math.floor(h("hour") * 9)).padStart(2, "0")}:15`, MOCK_TENANT_ZONE));
      const id = `5${date.replaceAll("-", "").slice(2)}${String(i).padStart(2, "0")}`;
      const roll = h("pipeline");
      const pipelineId = roll < 0.6 ? "p-cancel" : "p-support";
      const category = pipelineId === "p-support" ? (roll < 0.8 ? "Cancellation (test)" : "Complaint (test)") : null;
      const closedAt = t + (0.2 + h("close") * 5) * 86_400_000;
      const closed = h("closed") < 0.65 && closedAt < now;
      const p = label(pipelineId);
      out.push({
        recordId: mockDealId(me, id), connectionId: crm.connection.id, recordType: "ticket", sourceId: id, pipelineId, pipelineLabel: p?.label ?? pipelineId,
        pipelineCounted: p ? p.isCounted : null, category, market, reason: reasonsOn ? ["moving", "price", "other", null][Math.floor(h("reason") * 4)]! : null,
        isClosed: closed, createdAt: new Date(t).toISOString(), closedAt: closed ? new Date(closedAt).toISOString() : null,
        deletedAt: h("deleted") < 0.03 ? new Date(t + 3_600_000).toISOString() : null, recordUrl: `https://crm.example.com/records/100200300/ticket/${id}`,
      });
    }
  }
  return out;
}

/** The tenant's record kinds and the CRM connection's rules (cma.record_kind, cma.connection_record_kind) */
function mockKinds(me: Principal): { kinds: (RecordKind & { sortOrder: number })[]; rules: KindRuleFixture[] } {
  const c = seedIntakeConfig(me);
  return { kinds: c.kinds, rules: c.kindRules };
}

/** Whose a linked account is: the person holding it in the fixture's linked accounts */
function mockOrderPersonOf(me: Principal) {
  const accounts = seedIntakeConfig(me).accounts;
  return (system: string, ownerRef: string | null) => {
    const a = ownerRef === null ? undefined : accounts.find((x) => x.system === system && x.externalId === ownerRef);
    return a ? { userId: a.userId, name: mockOrderName(a.userId) ?? a.userId } : null;
  };
}

/** A credited person's name: the team's, the test manager's */
function mockOrderName(userId: string): string | null {
  return mockOwnerName(userId) ?? (userId === MOCK_MANAGER_ID ? "Test manager" : null);
}

function assertFirstOrders(me: Principal, range: HoursRange, filter: FirstOrderFilter, group: FirstOrderGroup | null, permissions: string[]): void {
  assertAny(me, permissions);
  assertReportRange(range);
  if (group !== null && !FIRST_ORDER_GROUPS.includes(group)) throw new CmaDbError("CMA04", "group by day, week, market or level");
  if (parseFirstOrderFilter(filter.market ?? "", filter.level ?? "").problem) throw new CmaDbError("CMA04", "invalid filter");
}

/**
 * The callback tasks of the fixture and the calls to their contacts (cma.callbacks_kept_of, addition 0008w): two to five
 * on each weekday from ten weeks back to two days ahead, each with an owner of the fixture's linked accounts (one owner id
 * nobody holds), a few without a contact or a due time; calls within the window (some without a direction), outside it,
 * inbound ones and none. Invented ids only; the invest tenant counts no callback type
 */
function mockCallbacks(me: Principal): { tasks: CallbackTaskFixture[]; calls: CallbackCallFixture[] } {
  if (me.tenantId === MOCK_TENANT_2) return { tasks: [], calls: [] };
  const owners = ["70000001", "70000002", "70000009", "70000004"];
  const today = mockToday(me);
  const now = Date.now();
  const tasks: CallbackTaskFixture[] = [];
  const calls: CallbackCallFixture[] = [];
  const call = (contactId: string, at: number, direction: CallbackCallFixture["direction"]) => {
    if (at < now) calls.push({ contactId, at: new Date(at).toISOString(), direction });
  };
  for (let date = addDays(today, -70); date <= addDays(today, 2); date = addDays(date, 1)) {
    if ([0, 6].includes(new Date(`${date}T12:00:00Z`).getUTCDay())) continue;
    const n = 2 + Math.floor(hashOf(`${me.tenantId}:callbacks:${date}`) * 4);
    for (let i = 0; i < n; i++) {
      const h = (k: string) => hashOf(`${me.tenantId}:callback:${date}:${i}:${k}`);
      const due = localMs(date, `${String(9 + Math.floor(h("hour") * 8)).padStart(2, "0")}:${h("half") < 0.5 ? "00" : "30"}`, me.timeZone);
      const roll = h("kind");
      const contactId = roll < 0.06 ? null : `k-cb-${date}-${i}`;
      tasks.push({ id: `${date.replaceAll("-", "")}${i}`, ownerRef: owners[Math.floor(h("owner") * owners.length)]!, contactId,
        dueAt: roll >= 0.06 && roll < 0.1 ? null : new Date(due).toISOString(), createdAt: new Date(due - 86_400_000).toISOString() });
      if (contactId === null) continue;
      const c = h("call");
      if (c < 0.68) call(contactId, due + (h("off") - 0.5) * 400 * 60_000, h("dir") < 0.1 ? "unknown" : "outbound");
      else if (c < 0.84) call(contactId, due + (300 + h("off") * 300) * 60_000, "outbound");
      else if (c < 0.92) call(contactId, due + 30 * 60_000, "inbound");
    }
  }
  return { tasks, calls };
}

function mockCallbackRecords(me: Principal) {
  const { tasks, calls } = mockCallbacks(me);
  return callbackRecords(tasks, calls, Number(mockSetting("tasks.callback_window_minutes")), new Date(), me.timeZone);
}

/**
 * The journeys of Campaign monitoring (cma.journeys(), addition 0008v): the three of db/02's seed for the first tenant,
 * one with an invented design link, and an archived one that never shows; the invest tenant has none
 */
const MOCK_JOURNEYS: (Omit<Journey, "status"> & { status: JourneyStatus | "archived"; sortOrder: number })[] = [
  {
    code: "fca-uk-consumers", name: "FCA · UK consumers", market: "GB", status: "placeholder", sortOrder: 10,
    summary: "Every UK consumer customer through every required communication and step, with drill-down per customer and an audit pack.",
    designUrl: "https://design.example.invalid/fca-uk-consumers",
    prerequisites: ["Consumer or business flag on every GB contact", "Agreement date on the contract", "A call tag that proves the welcome call",
      "Template ids on the journey's emails", "Call-recording consent decided", "Step list by Gemma and Kira, checked by Yordi",
      "Drill-down permission and access log agreed with Yordi"],
  },
  { code: "opc", name: "OPC", market: null, status: "placeholder", sortOrder: 20, summary: "Steps, coverage and drill-down to be defined with Kira.",
    designUrl: null, prerequisites: ["Step list and population defined by Kira."] },
  { code: "exchange", name: "Exchange", market: null, status: "placeholder", sortOrder: 30, summary: "Steps, coverage and drill-down to be defined with Kira.",
    designUrl: null, prerequisites: ["Step list and population defined by Kira."] },
  { code: "old-pilot", name: "Old pilot", market: "NL", status: "archived", sortOrder: 5, summary: null, designUrl: null, prerequisites: [] },
];

/** The open lead deals not responding (cma.email_not_responding): invented deals, ids and ages only */
function mockNotResponding(me: Principal): EmailNotRespondingRow[] {
  if (me.tenantId === MOCK_TENANT_2) return [];
  const days = mockSettingNumber(me, "email.no_response_days");
  const owners = [TEAM[0]!, TEAM[1]!, null];
  return [0, 1, 2, 3, 4, 5].map((i) => {
    const h = (k: string) => mixedHashOf(`${me.tenantId}:noresponse:${i}:${k}`);
    const since = days + Math.floor(h("days") * 20);
    const owner = owners[i % owners.length]!;
    const dealId = String(41_000_500 + i);
    return {
      connectionId: MOCK_CRM_CONNECTION, dealId, pipelineLabel: "Sales (test)", market: ["NL", "GB", "DE", "unknown"][i % 4]!,
      ownerUserId: owner?.userId ?? null, ownerName: owner?.displayName ?? null,
      lastEmailAt: new Date(Date.now() - since * 86_400_000 - Math.floor(h("h") * 8) * 3_600_000).toISOString(), daysSince: since,
      recordUrl: `https://crm.example.com/records/100200300/deal/${dealId}`,
    };
  }).sort((a, b) => a.lastEmailAt.localeCompare(b.lastEmailAt));
}

function assertEmail(me: Principal, range: HoursRange, filter: EmailFilter, group: EmailGroup | null, permissions: string[]): void {
  assertAny(me, permissions);
  assertReportRange(range);
  if (group !== null && !EMAIL_GROUPS.includes(group)) throw new CmaDbError("CMA04", "group by day or week");
  if (parseEmailFilter(filter.market ?? "", filter.inbox ?? "", filter.account ?? "").problem) throw new CmaDbError("CMA04", "invalid filter");
}

/** The mock's lists for the filters: markets, inboxes and mailboxes with email in the period, without the filters */
function mockEmailLists(records: ReturnType<typeof emailRecords>, from: DateKey, to: DateKey) {
  const all = emailInPeriod(records, from, to, { market: null, inbox: null, account: null });
  const named = (pairs: [string | null, string | null][]) => [...new Map(pairs.filter(([k]) => k !== null).map(([k, n]) => [k!, n ?? k!])).entries()]
    .map(([key, name]) => ({ key, name })).sort((a, b) => a.name.localeCompare(b.name));
  return {
    markets: [...new Set(all.map((r) => r.market))].sort((a, b) => (a === "unknown" ? 1 : b === "unknown" ? -1 : a.localeCompare(b))),
    inboxes: named(all.map((r) => [r.inboxKey, r.inboxName])),
    accounts: named(all.map((r) => [r.accountKey, r.accountName])),
  };
}

const MOCK_FORM_ZONES: Record<string, string> = { NL: "Europe/Amsterdam", BE: "Europe/Brussels", GB: "Europe/London", DE: "Europe/Berlin" };

/**
 * The fixture's stored submissions (addition 0008p), as cma.form_submissions_of gives them: every polled form
 * of the tenant's sources, from the start date up to today, a few a day (fewer at the weekend); the market
 * the form's, else the market field's answer through the aliases, else the contact's country (a share of the
 * contacts found), else unknown; times between 08:00 and 21:00 in the market's zone; answers drawn from the
 * kept choice fields' options. Everything invented and stable across reads
 */
function mockFormRecords(me: Principal): FormSubmissionRecord[] {
  const cfg = seedIntakeConfig(me);
  const aliasOf = (v: string) => cfg.markets.find((m) => m.code === v.toUpperCase() || m.aliases.includes(v.toLowerCase()) || m.name.toLowerCase() === v.toLowerCase())?.code ?? null;
  const out: FormSubmissionRecord[] = [];
  const resolutions: FormSubmissionRecord["resolution"][] = ["resolved", "resolved", "resolved", "not_found", "ambiguous", "no_email"];
  for (const x of cfg.sources) {
    for (const f of x.forms.filter((y) => y.isPolled)) {
      const formKey = `${x.connection.id}:${f.formId}`;
      for (let date = mockStartDate(me); date <= mockToday(me); date = addDays(date, 1)) {
        const weekend = [0, 6].includes(new Date(`${date}T12:00:00Z`).getUTCDay());
        const n = Math.floor(mixedHashOf(`${me.tenantId}:${formKey}:${date}`) * (f.isCounted ? 6 : 4) * (weekend ? 0.4 : 1));
        for (let i = 0; i < n; i++) {
          const h = (k: string) => mixedHashOf(`${me.tenantId}:${formKey}:${date}:${i}:${k}`);
          const answers: Record<string, string | string[]> = {};
          for (const name of f.keptFields) {
            const field = f.fields.find((y) => y.name === name);
            if (!field || field.options.length === 0 || h(`skip-${name}`) < 0.1) continue;
            const pick = field.options[Math.floor(h(name) * field.options.length)]!;
            answers[name] = field.kind === "multiple_checkboxes"
              ? [...new Set([pick, field.options[Math.floor(h(`${name}-2`) * field.options.length)]!])].sort()
              : pick;
          }
          const resolution = resolutions[Math.floor(h("resolution") * resolutions.length)]!;
          const answerMarket = f.marketField && typeof answers[f.marketField] === "string" ? aliasOf(answers[f.marketField] as string) : null;
          const contactMarket = resolution === "resolved" && h("contact") < 0.8 ? (["NL", "GB", "DE"] as const)[Math.floor(h("country") * 3)]! : null;
          const market = f.market ?? answerMarket ?? contactMarket ?? "unknown";
          const minutes = 8 * 60 + Math.floor(h("time") * 13 * 60);
          out.push({
            formKey, formName: f.name, category: f.category, market, zone: MOCK_FORM_ZONES[market] ?? me.timeZone, date,
            localTime: `${String(Math.floor(minutes / 60)).padStart(2, "0")}:${String(minutes % 60).padStart(2, "0")}:00`, resolution, answers,
          });
        }
      }
    }
  }
  return out;
}

/** The fixture's calls of the range and the previous period, classified and filtered */
function mockCallRecords(me: Principal, range: HoursRange, filter: CallsFilter): CallRecord[] {
  return callRecords(mockCalls(me, { from: previousPeriod(range, mockToday(me)).from, to: range.to }), MOCK_INBOUND_LINES, me.timeZone, mockCallRules(me), filter);
}

/** The markets and lines with calls in the period, the lines within the chosen market */
function mockCallsLists(me: Principal, range: HoursRange, filter: CallsFilter) {
  const all = callRecords(mockCalls(me, range), MOCK_INBOUND_LINES, me.timeZone, mockCallRules(me));
  return {
    markets: groupCalls(all, range.from, range.to, "market").rows.map((r) => r.groupKey),
    lines: groupCalls(all.filter((c) => filter.market === null || c.market === filter.market), range.from, range.to, "line").rows
      .map((r) => ({ key: r.groupKey, name: r.groupLabel })),
  };
}

function mockCallsOverview(me: Principal, range: HoursRange, group: CallsGroup, filter: CallsFilter): CallsOverview {
  const telephony = connectionsOf(me).telephony;
  const records = mockCallRecords(me, range, filter);
  // like for like, as the database: a period that reaches today against the same point in the previous one
  const prev = previousPeriod(range, mockToday(me));
  const { rows, total } = groupCalls(records, range.from, range.to, group);
  // the history start as cma.telephony_history_start: the earliest call of the whole fixture, without the filter
  const history = callRecords(mockCalls(me, { from: mockStartDate(me), to: mockToday(me) }), MOCK_INBOUND_LINES, me.timeZone, mockCallRules(me));
  return {
    ...range, group, filter, telephony, connectedMinSeconds: mockConnectedMin(), conversationMinSeconds: mockConversationMin(), rows, total,
    previous: callsFigures(previousCalls(records, prev, new Date().toISOString())),
    previousFrom: prev.from, previousTo: prev.to, previousPartial: prev.partial, historyStart: historyStartOf(history),
    ...mockCallsLists(me, range, filter),
  };
}

/** The fixture's calls relative to now, for the Live board: callers as opaque keys, never shown */
function mockLiveCalls(now: number): CallerCall[] {
  const at = (minutesAgo: number) => new Date(now - minutesAgo * 60_000).toISOString();
  const call = (sourceId: string, direction: "inbound" | "outbound", minutesAgo: number, answerAfter: number | null, ended: boolean,
    reason: string | null, lineRef: string, caller: string | null): CallerCall => ({
    sourceId, connectionId: MOCK_TEL_CONNECTION, sourceSystem: MOCK_TEL_SYSTEM, direction, startedAt: at(minutesAgo),
    answeredAt: answerAfter === null ? null : new Date(now - minutesAgo * 60_000 + answerAfter * 1000).toISOString(),
    endedAt: ended ? new Date(now - minutesAgo * 60_000 + ((answerAfter ?? 0) + 60) * 1000).toISOString() : null,
    missedReason: reason, lineRef, caller,
  });
  const answered: CallerCall[] = Array.from({ length: 16 }, (_, k) =>
    call(`9100000${String(k).padStart(2, "0")}`, "inbound", 7 + k * 23, 4 + ((k * 7) % 31), true, null, k % 3 === 0 ? "l-2" : "l-1", `caller-ok-${k}`));
  return [
    ...answered,
    // missed twice, then called back (an outbound attempt that did not connect): not listed
    call("910000101", "inbound", 180, null, true, "no_available_agent", "l-1", "caller-a"),
    call("910000102", "inbound", 130, null, true, "agents_did_not_answer", "l-1", "caller-a"),
    call("910000103", "outbound", 25, null, true, null, "l-1", "caller-a"),
    // missed once, waiting for a callback
    call("910000201", "inbound", 95, null, true, "abandoned_in_ivr", "l-2", "caller-b"),
    // missed twice and not called back: listed once, missed 2 times
    call("910000301", "inbound", 300, null, true, "short_abandoned", "l-1", "caller-c"),
    call("910000302", "inbound", 40, null, true, "no_available_agent", "l-1", "caller-c"),
    // missed four days ago: outside the lookback
    call("910000401", "inbound", 4 * 24 * 60, null, true, "no_available_agent", "l-1", "caller-d"),
    // missed outside opening hours last night (Pulse4all calls these back too)
    call("910000501", "inbound", 14 * 60, null, true, "out_of_opening_hours", "l-1", "caller-e"),
    // a code nobody configured: the defaults apply
    call("910000601", "inbound", 120, null, true, "abandoned_in_classic", "l-2", "caller-f"),
    // missed, then called in again and answered: not listed
    call("910000701", "inbound", 200, null, true, "no_available_agent", "l-1", "caller-g"),
    call("910000702", "inbound", 60, 9, true, null, "l-1", "caller-g"),
    // missed yesterday, called back an hour later, missed again today: listed, missed 1 time (since the callback)
    call("910001001", "inbound", 26 * 60, null, true, "no_available_agent", "l-1", "caller-i"),
    call("910001002", "outbound", 25 * 60, 8, true, null, "l-1", "caller-i"),
    call("910001003", "inbound", 75, null, true, "agents_did_not_answer", "l-1", "caller-i"),
    // anonymous: counted, never listed
    call("910000801", "inbound", 70, null, true, "no_available_agent", "l-1", null),
    call("910000802", "inbound", 32, null, true, null, "l-2", null),
    // waiting now
    call("910000901", "inbound", 2, null, false, null, "l-1", "caller-h"),
  ];
}

/** Office seconds between two instants in a fixture market: Monday to Friday 09:00 to 17:00 in the market's zone */
function mockBusinessSeconds(market: string, from: Instant, toMs: number): number | null {
  const zone = market === "NL" ? "Europe/Amsterdam" : market === "GB" ? "Europe/London" : market === "DE" ? "Europe/Berlin" : null;
  if (!zone) return null;
  let total = 0;
  for (let d = dateKeyInZone(from, zone); d <= dateKeyInZone(new Date(toMs), zone); d = addDays(d, 1)) {
    if ([0, 6].includes(new Date(`${d}T12:00:00Z`).getUTCDay())) continue;
    const opens = Math.max(localMs(d, "09:00", zone), Date.parse(from));
    const closes = Math.min(localMs(d, "17:00", zone), toMs);
    if (closes > opens) total += Math.floor((closes - opens) / 1000);
  }
  return total;
}

function mockCallUrl(me: Principal, connectionId: string, sourceId: string): string | null {
  const c = seedIntakeConfig(me).sources.find((x) => x.connection.id === connectionId)?.connection;
  const template = c?.settings.record_url_call;
  return c && typeof template === "string" ? recordUrlPreview(template, c.settings, c.accountId, sourceId) : null;
}

function mockInboundService(me: Principal, range: { from: DateKey; to: DateKey }, group: InboundGroup): InboundService {
  const telephony = connectionsOf(me).telephony;
  const calls = telephony ? inboundCalls(mockPeriodCalls(me, range), MOCK_INBOUND_LINES, mockReasons(me), me.timeZone, MOCK_WAITING_MAX, Date.now()) : [];
  const { rows, total } = groupInbound(calls, range.from, range.to, group, MOCK_SL_SECONDS);
  return { ...range, group, telephony, serviceLevelSeconds: MOCK_SL_SECONDS, waitingMaxMinutes: MOCK_WAITING_MAX, reasons: mockReasons(me), rows, total };
}

/** A telephony connection's missed reasons: its catalog rows plus the codes its fixture calls carry, as cma.connection_missed_reasons */
function mockSourceReasons(me: Principal, nowMs: number): { reasons: SourceMissedReason[]; sampleCallId: string | null } {
  const today = mockToday(me);
  const calls = [...mockPeriodCalls(me, { from: addDays(today, -13), to: today }), ...mockLiveCalls(nowMs)];
  const missed = inboundCalls(calls, MOCK_INBOUND_LINES, [], me.timeZone, MOCK_WAITING_MAX, nowMs).filter((c) => c.reasonCode !== null);
  const catalog = mockReasons(me).filter((r) => r.sourceSystem === MOCK_TEL_SYSTEM);
  const codes = [...new Set([...catalog.map((r) => r.code), ...missed.map((c) => c.reasonCode!)])].sort();
  const reasons = codes.map((code) => {
    const r = missedReasonOf(MOCK_TEL_SYSTEM, code, catalog);
    const seen = missed.filter((c) => c.reasonCode === code);
    return {
      code, label: r.label, countsInServiceLevel: r.countsInServiceLevel, needsCallback: r.needsCallback,
      inCatalog: catalog.some((x) => x.code === code), seenCalls: seen.length,
      lastSeenAt: seen.reduce<string | null>((m, c) => (m === null || c.startedAt > m ? c.startedAt : m), null),
    };
  });
  const newest = calls.reduce<TelephonyCallFixture | null>((m, c) => (m === null || c.startedAt > m.startedAt ? c : m), null);
  return { reasons, sampleCallId: newest?.sourceId ?? null };
}

function noFigures(): InboundFigures {
  return { offered: 0, answered: 0, unanswered: 0, waiting: 0, answeredWithinTarget: 0, serviceLevelBase: 0, serviceLevelPct: null,
    avgAnswerSeconds: null, p80AnswerSeconds: null, unansweredByReason: {} };
}

function mockInboundNow(me: Principal): InboundNow {
  if (!connectionsOf(me).telephony) return { telephony: false, today: null, callbacks: [], anonymousCount: 0, lookbackDays: MOCK_LOOKBACK_DAYS };
  const now = Date.now();
  const today = mockToday(me);
  const midnight = localMs(today, "00:00", me.timeZone);
  const live = mockLiveCalls(now);
  const reasons = mockReasons(me);
  const todays = inboundCalls(live.filter((c) => Date.parse(c.startedAt) >= midnight), MOCK_INBOUND_LINES, reasons, me.timeZone, MOCK_WAITING_MAX, now);
  const waiting = inboundCalls(live, MOCK_INBOUND_LINES, reasons, me.timeZone, MOCK_WAITING_MAX, now).filter((c) => c.isWaiting);
  const { rows, anonymousCount } = missedCallbacks(live, MOCK_INBOUND_LINES, reasons, me.timeZone, MOCK_WAITING_MAX, MOCK_LOOKBACK_DAYS, now,
    mockBusinessSeconds, (connectionId, sourceId) => mockCallUrl(me, connectionId, sourceId));
  const longest = waiting.reduce<number | null>((m, c) => Math.max(m ?? 0, Math.floor((now - Date.parse(c.startedAt)) / 1000)), null);
  return {
    telephony: true,
    today: { ...(todays.length ? inboundFigures(todays, MOCK_SL_SECONDS) : noFigures()), date: today, waitingNow: waiting.length,
      longestWaitingSeconds: longest, serviceLevelSeconds: MOCK_SL_SECONDS, waitingMaxMinutes: MOCK_WAITING_MAX },
    callbacks: rows,
    anonymousCount,
    lookbackDays: MOCK_LOOKBACK_DAYS,
  };
}

/** Same answer as the database for a caller without workday.team */
function assertTeam(me: Principal): void {
  if (!me.permissions.includes("workday.team")) throw new CmaDbError("CMA06", "not permitted");
}

/** Same answer as the database (0003d) when a day would be created for someone whose time is not kept */
function assertTimeKept(me: Principal): void {
  if (!me.permissions.includes("workday.own")) throw new CmaDbError("CMA06", "time is not kept for this person");
}

/**
 * Fixture links shaped like cma.app_link rows: fictional labels and addresses, one of them for
 * people holding workday.team only. The screens never branch on a key or a label.
 */
const MOCK_LINKS: (AppLink & { permission: string | null })[] = [
  { key: "crm", label: "CRM (test)", address: "https://example.com/crm", permission: null },
  { key: "phone", label: "Phone (test)", address: "https://example.com/phone", permission: null },
  { key: "team-sheet", label: "Team sheet (test)", address: "https://example.com/team-sheet", permission: "workday.team" },
];

/** Same answer as the database for a caller without performance.team (addition 0003c) */
function assertPerformance(me: Principal): void {
  if (!me.permissions.includes("performance.team")) throw new CmaDbError("CMA06", "not permitted");
}

/** Same answer as the database for a caller without monitoring.live (addition 0003e) */
function assertLive(me: Principal): void {
  if (!me.permissions.includes("monitoring.live")) throw new CmaDbError("CMA06", "not permitted");
}

/** Same answer as the database for a caller without workday.export */
function assertExport(me: Principal): void {
  if (!me.permissions.includes("workday.export")) throw new CmaDbError("CMA06", "not permitted");
}

/** Fixture settings shaped like cma.tenant_settings: the fictional tenant uses Dutch spreadsheet conventions */
const MOCK_SETTINGS: TenantSetting[] = [
  { key: "export.csv.date_format", value: "dd-mm-yyyy", isDefault: false },
  { key: "export.csv.decimal_mark", value: "comma", isDefault: false },
  { key: "export.csv.duration_format", value: "decimal_hours", isDefault: true },
  { key: "export.csv.separator", value: "semicolon", isDefault: false },
  { key: "export.csv.utf8_bom", value: "true", isDefault: true },
  // the connected-call threshold (addition 0008j), at its default
  { key: "telephony.connected_min_seconds", value: "0", isDefault: true },
  // the invitation settings (addition 0008l), at their defaults
  { key: "auth.invitation_valid_days", value: "7", isDefault: true },
  { key: "auth.invitation_email_domains", value: "", isDefault: true },
  // the lead target (0007d) and the follow-up settings (addition 0008o), at their defaults; the fixture's rows follow them
  { key: "speed_to_lead.target_minutes", value: "60", isDefault: true },
  { key: "tickets.sla_minutes", value: "240", isDefault: true },
  { key: "tickets.sla_warning_pct", value: "75", isDefault: true },
  { key: "leads.age_buckets_business_days", value: "1,2,5", isDefault: true },
  { key: "tasks.callback_window_minutes", value: "240", isDefault: true },
  // the rows each Follow-up list shows (addition 0008s), at its default
  { key: "follow_up.list_rows", value: "100", isDefault: true },
  // the email reports (additions 0008m and 0008t): the start date, the first-reply target, the not-responding days and the
  // market order at their defaults; both
  // per-person pages switched on (attempts too since addition 0008y), as the dev seed (03) does
  { key: "email.start_date", value: "", isDefault: true },
  { key: "email.reply_target_minutes", value: "240", isDefault: true },
  { key: "email.no_response_days", value: "5", isDefault: true },
  { key: "email.market_order", value: "contact,form,record,inbox", isDefault: true },
  { key: "reports.per_person", value: "email,orders,attempts,deals", isDefault: false },
  // the cancellation requests (addition 0008zb): the fixture's kind, as Configuration → Sources sets it
  { key: "reports.cancellation_kind", value: "cancellation", isDefault: false },
  // reviews (addition 0008ze): the negative threshold and the backfill's history start at their defaults
  { key: "reviews.negative_max_rating", value: "2", isDefault: true },
  { key: "reviews.history_start_date", value: "", isDefault: true },
  // first orders (addition 0008u): the attribution settings at their catalog defaults
  { key: "attribution.window_days", value: "90", isDefault: true },
  { key: "attribution.level_order", value: "lead_deal,conversation,email,phone_match,attempt,known_contact", isDefault: true },
  { key: "attribution.assisted_levels", value: "lead_deal,conversation,email,phone_match", isDefault: true },
  { key: "attribution.known_contact_minutes", value: "60", isDefault: true },
  { key: "attribution.order_match_minutes", value: "1440", isDefault: true },
  // attempts per deal (addition 0008y): the top bucket and the time-since-last buckets at their catalog defaults, and the
  // speed-to-lead pre-window they share with 0007d
  { key: "attempts.max_bucket", value: "5", isDefault: true },
  { key: "attempts.since_last_buckets_business_days", value: "1,2,5", isDefault: true },
  // attempts per deal for sales (addition 0008z): telephony attempts, the speed buckets; the Conversation threshold (0008zc), 30 s of talk
  { key: "attempts.source", value: "telephony", isDefault: true },
  { key: "calls.conversation_min_talk_seconds", value: "30", isDefault: true },
  { key: "attempts.speed_buckets_business_minutes", value: "5,15,60,240,1440", isDefault: true },
  { key: "speed_to_lead.pre_window_minutes", value: "10", isDefault: false },
];

type Key = `${string}:${string}:${DateKey}`;
const owner = (me: Principal) => `${me.tenantId}:${me.userId}:`;
const key = (me: Principal, date: DateKey): Key => `${owner(me)}${date}` as Key;

/**
 * The in-memory state lives on globalThis: every page and route handler is its own bundle in the
 * standalone server, so a module-level Map would exist once per bundle and a day opened through
 * the start route would be invisible to the page that renders it (seen 7 October 2026, increment
 * e, when Clock in moved from the page to a route).
 */
type MockConfig = {
  statuses: ConfigStatus[]; links: ConfigAppLink[]; absences: AbsenceType[]; targets: CoverageTargetRow[];
  settings: TenantSetting[]; teams: TeamInfo[]; skills: SkillInfo[];
};
/**
 * A fictional message as cma.message with its deliveries (0008). "everyone" messages hand a delivery to
 * any person of the tenant who polls, so a tester's own mock identity receives them too.
 */
type MockDelivery = { deliveredAt: Instant | null; readAt: Instant | null; acknowledgedAt: Instant | null };
type MockMessage = Omit<MyMessage, "deliveredAt" | "readAt" | "acknowledgedAt"> & {
  tenantId: string; everyone: boolean; users: Set<string>; byRule: boolean; deliveries: Map<string, MockDelivery>;
  /** When a person holding messages.withdraw withdrew it for everyone (0008z); recipients no longer see it */
  withdrawnAt?: Instant | null;
};
type MockState = {
  store: Map<Key, Workday>; teamStore: Map<string, Map<DateKey, TimeEvent[]>>; teamSeeded: boolean; people: Map<string, DirectoryPerson> | null;
  rosters: Map<string, MockRosterWeek> | null; config: MockConfig | null;
  messages: Map<string, MockMessage>; messagesSeeded: Set<string>; lastSyntheticAlertAt: number; messageSeq: number;
  /** Sources, markets, rules and linked accounts per tenant (addition 0008e), seeded on first use */
  intakeConfig?: Map<string, MockIntakeConfig>;
  /** The missed-reason catalog per tenant (addition 0008i), seeded on first use */
  missedReasons?: Map<string, MissedReason[]>;
  /** Invitations of both fictional tenants (addition 0008l), seeded on first use; the token's hash only */
  invitations?: MockInvitation[];
  /** Identities that accepted an invitation, as `${provider}:${subject}`, with the person they became */
  invitees?: Map<string, Principal>;
};
const g = globalThis as unknown as { __cmaMock?: MockState };
const state: MockState = (g.__cmaMock ??= {
  store: new Map(), teamStore: new Map(), teamSeeded: false, people: null, rosters: null, config: null,
  messages: new Map(), messagesSeeded: new Set(), lastSyntheticAlertAt: 0, messageSeq: 0,
});
const store = state.store;

/**
 * Fixture data, not app logic: a fictional status list shaped like a tenant's work_status rows
 * (the default ladder of the seed). The screens never branch on these keys or names.
 */
const MOCK_STATUSES: WorkStatus[] = [
  { key: "available", name: "Available", isWorking: true, isProductive: true, isDefault: true },
  { key: "training", name: "Training", isWorking: true, isProductive: false, isDefault: false },
  { key: "meeting", name: "Meeting", isWorking: true, isProductive: false, isDefault: false },
  { key: "break", name: "Break", isWorking: false, isProductive: false, isDefault: false },
  { key: "lunch", name: "Lunch", isWorking: false, isProductive: false, isDefault: false },
];
const DEFAULT_STATUS = MOCK_STATUSES.find((s) => s.isDefault)!;
/** Fixture pay flags (the seed's proposal: paid break, unpaid lunch); never shown to an agent */
const MOCK_PAID = new Set(["available", "training", "meeting", "break"]);

function secondsBetween(a: Instant, b: Instant): number {
  return Math.max(0, Math.floor((Date.parse(b) - Date.parse(a)) / 1000));
}

/**
 * The fictional tenant's workday window and forgotten-day close, Pulse4all's settings (addition
 * 0008b): clock-in from 07:00, time counted up to 22:00, a forgotten day closed at 17:00 when no
 * shift is planned. Fixture configuration following the database's rule; the screens read the
 * day's end from the data, never from here.
 */
const MOCK_WINDOW = { start: "07:00", end: "22:00", autoCloseAt: "17:00" } as const;

/** The first instant after a working day in a zone: the window end */
function dayEndMs(date: DateKey, timeZone: string): number {
  return localMs(date, MOCK_WINDOW.end, timeZone);
}

/** Worked seconds of a day up to `now`: closed stretches plus the running one, which stops at the day's end */
function workedSeconds(w: Workday, now: Instant): number {
  const until = new Date(Math.min(Date.parse(now), Date.parse(w.dayEndsAt))).toISOString();
  return w.clock.closedSeconds + (w.clock.runningSince ? secondsBetween(w.clock.runningSince, until) : 0);
}

/** Closes the running stretch at `now`; the result has nothing running */
function closeStretch(w: Workday, now: Instant): Workday["clock"] {
  return { closedSeconds: workedSeconds(w, now), runningSince: null };
}

/** A fortnight of fictional history so the hours screen has something to show */
function seedHistory(me: Principal, today: DateKey) {
  const base = new Date(`${today}T00:00:00Z`);
  for (let i = 1; i <= 14; i++) {
    const d = new Date(base);
    d.setUTCDate(base.getUTCDate() - i);
    const dow = d.getUTCDay();
    if (dow === 0 || dow === 6) continue;
    const date = d.toISOString().slice(0, 10);
    const k = key(me, date);
    if (store.has(k)) continue;
    // UTC minutes; roughly 08:00 to 17:00 in Central European summer time
    const startMin = 6 * 60 + ((i * 7) % 20);
    const endMin = 15 * 60 + ((i * 11) % 35) - (i % 3 === 0 ? 30 : 0);
    const at = (m: number) =>
      new Date(d.getTime() + m * 60000).toISOString();
    store.set(k, {
      date,
      status: "ended",
      startedAt: at(startMin),
      endedAt: at(endMin),
      statusKey: null,
      statusName: null,
      statusSince: null,
      clock: { closedSeconds: (endMin - startMin) * 60, runningSince: null },
      dayEndsAt: new Date(dayEndMs(date, me.timeZone)).toISOString(),
    });
  }
}

// ---- the fictional team (fixture data, not app logic) ----------------------------------------

const MOCK_SUPERVISOR_ID = "00000000-0000-7000-8000-000000000102";
const MOCK_MANAGER_ID = "00000000-0000-7000-8000-000000000103";
const MOCK_ANALYST_ID = "00000000-0000-7000-8000-000000000104";
const MOCK_ADMIN_ID = "00000000-0000-7000-8000-000000000105";

/** Two employers and three zones, so the screen shows employer and zone handling */
const TEAM: TeamPerson[] = [
  { userId: "00000000-0000-7000-8000-000000000201", displayName: "Ana Ferrer", organisationName: "Newco", timeZone: "Europe/Madrid" },
  { userId: "00000000-0000-7000-8000-000000000202", displayName: "Jordi Puig", organisationName: "Newco", timeZone: "Europe/Madrid" },
  { userId: "00000000-0000-7000-8000-000000000203", displayName: "Sanne Visser", organisationName: "Pulse4all", timeZone: "Europe/Amsterdam" },
  { userId: "00000000-0000-7000-8000-000000000204", displayName: "Lucas Moreau", organisationName: "Newco", timeZone: "Europe/Madrid" },
  { userId: "00000000-0000-7000-8000-000000000205", displayName: "Emma Clarke", organisationName: "Newco", timeZone: "Europe/London" },
];

type MockEvent = TimeEvent;
/** userId -> business date -> every event of that day, effective or not */
const teamStore = state.teamStore;

function localMs(date: DateKey, time: string, timeZone: string): number {
  // The earlier instant when a time occurs twice; fixture times avoid the skipped hour
  return instantsForLocal(date, time, timeZone)[0]?.ms ?? Date.parse(`${date}T${time}:00Z`);
}

function mockEvent(
  kind: TimeEvent["kind"], at: Instant, statusKey: string | null, source: TimeEvent["source"],
  extra: Partial<Pick<TimeEvent, "supersedes" | "reason" | "approvedByName" | "importBatchKey">> = {},
): MockEvent {
  return {
    id: crypto.randomUUID(),
    kind,
    statusKey,
    statusName: MOCK_STATUSES.find((s) => s.key === statusKey)?.name ?? null,
    at,
    recordedAt: source === "correction" ? new Date().toISOString() : at,
    source,
    supersedes: extra.supersedes ?? null,
    reason: extra.reason ?? null,
    approvedByName: extra.approvedByName ?? null,
    importBatchKey: extra.importBatchKey ?? null,
    isEffective: true,
  };
}

/** Effective events in time order: not a void, not replaced by a later correction */
function effective(events: MockEvent[]): MockEvent[] {
  return events
    .filter((e) => e.kind !== "void" && !events.some((x) => x.supersedes === e.id))
    .sort((a, b) => Date.parse(a.at) - Date.parse(b.at));
}

function withEffective(events: MockEvent[]): MockEvent[] {
  const live = new Set(effective(events).map((e) => e.id));
  return [...events]
    .map((e) => ({ ...e, isEffective: live.has(e.id) }))
    .sort((a, b) => Date.parse(a.at) - Date.parse(b.at) || Date.parse(a.recordedAt) - Date.parse(b.recordedAt));
}

/** One day's header and figures, the way cma.workday_summary derives them */
function teamDay(p: TeamPerson, date: DateKey, events: MockEvent[]): TeamDay {
  const live = effective(events);
  const start = live.find((e) => e.kind === "start")!;
  const end = live.find((e) => e.kind === "end") ?? null;
  // Every stretch stops at the window end; an open day past it is capped (0008b)
  const dayEnd = dayEndMs(date, p.timeZone);
  const isCapped = !end && Date.now() > dayEnd;
  const stop = end ? Date.parse(end.at) : Math.min(Date.now(), dayEnd);
  let working = 0;
  let paid = 0;
  const marks = live.filter((e) => e.kind !== "end");
  marks.forEach((e, i) => {
    const until = Math.min(stop, dayEnd, i + 1 < marks.length ? Date.parse(marks[i + 1]!.at) : stop);
    const seconds = Math.max(0, Math.floor((until - Date.parse(e.at)) / 1000));
    const s = MOCK_STATUSES.find((x) => x.key === e.statusKey);
    if (s?.isWorking) working += seconds;
    if (e.statusKey && MOCK_PAID.has(e.statusKey)) paid += seconds;
  });
  return {
    userId: p.userId,
    displayName: p.displayName,
    organisationName: p.organisationName,
    date,
    timeZone: p.timeZone,
    status: end ? "ended" : "open",
    startedAt: start.at,
    endedAt: end?.at ?? null,
    minutes: Math.floor(working / 60),
    paidMinutes: Math.floor(paid / 60),
    isCapped,
    // A day the system closed stays on the review list until a correction replaces its end (0005a)
    needsCorrection: isCapped || end?.source === "system",
    hasCorrection: events.some((e) => e.source === "correction"),
  };
}

function readTeamDay(userId: string, date: DateKey): TeamDayDetail {
  const p = TEAM.find((x) => x.userId === userId);
  const events = p ? teamStore.get(userId)?.get(date) ?? [] : [];
  return { day: p && events.length ? teamDay(p, date, events) : null, events: withEffective(events) };
}

/** One day's status stretches, the way cma.time_interval derives them (billable = paid in the fixture) */
function statusRows(p: TeamPerson, date: DateKey, events: MockEvent[]): StatusChangeRow[] {
  const live = effective(events);
  const end = live.find((e) => e.kind === "end") ?? null;
  const dayEnd = dayEndMs(date, p.timeZone);
  const capped = !end && Date.now() > dayEnd;
  const stop = end ? Date.parse(end.at) : Math.min(Date.now(), dayEnd);
  const marks = live.filter((e) => e.kind !== "end");
  return marks.map((e, i) => {
    const next = marks[i + 1] ? Date.parse(marks[i + 1]!.at) : end ? Date.parse(end.at) : null;
    const until = Math.min(stop, dayEnd, next ?? stop);
    const status = MOCK_STATUSES.find((x) => x.key === e.statusKey);
    const paid = !!e.statusKey && MOCK_PAID.has(e.statusKey);
    return {
      userId: p.userId,
      displayName: p.displayName,
      organisationName: p.organisationName,
      date,
      timeZone: p.timeZone,
      statusKey: e.statusKey ?? "",
      statusName: status?.name ?? e.statusKey ?? "",
      isWorking: !!status?.isWorking,
      isProductive: !!status?.isProductive,
      isPaid: paid,
      isBillable: paid,
      from: e.at,
      to: next === null ? null : new Date(next).toISOString(),
      isOpen: next === null,
      isCapped: next === null && capped,
      seconds: Math.max(0, Math.floor((until - Date.parse(e.at)) / 1000)),
      source: e.source,
    };
  });
}

/**
 * A fortnight of weekdays per person, with the cases the Hours screen must show: today still
 * clocked in, a forgotten clock-out, a missing day, and a day corrected afterwards.
 */
function seedTeam() {
  if (state.teamSeeded) return;
  state.teamSeeded = true;
  const now = Date.now();
  TEAM.forEach((p, n) => {
    const days = new Map<DateKey, MockEvent[]>();
    teamStore.set(p.userId, days);
    const today = dateKeyInZone(new Date(), p.timeZone);
    let weekday = 0;
    for (let i = 0; i <= 14; i++) {
      const date = addDays(today, -i);
      if (i === 0) {
        // Today, relative to now, so the Live board shows every state at any hour: Ana at work after
        // a break, Jordi on a break, Sanne in a meeting, Lucas clocked out, Emma not clocked in.
        // Minutes before now, scaled down when the day is young so nothing lands on yesterday.
        const elapsed = Math.max(60_000, now - localMs(date, "00:00", p.timeZone));
        const scale = Math.min(1, elapsed / (310 * 60_000));
        const ago = (minutes: number) => new Date(now - minutes * 60_000 * scale).toISOString();
        const todayPlan: [TimeEvent["kind"], string, string | null][][] = [
          [["start", ago(130), "available"], ["status", ago(70), "break"], ["status", ago(55), "available"]],
          [["start", ago(200), "available"], ["status", ago(12), "break"]],
          [["start", ago(95), "available"], ["status", ago(25), "meeting"]],
          [["start", ago(300), "available"], ["status", ago(120), "lunch"], ["status", ago(90), "available"], ["end", ago(30), null]],
          [],
        ];
        const events = (todayPlan[n] ?? []).map(([k, t, s]) => mockEvent(k, t, s, "user"));
        if (events.length) days.set(date, events);
        continue;
      }
      const dow = new Date(`${date}T00:00:00Z`).getUTCDay();
      if (dow === 0 || dow === 6) continue;
      weekday++;
      if (n === 4 && weekday === 3) continue;   // Emma: a day without any clock-in
      const j = (i * 7 + n * 3) % 20;
      const at = (time: string, plus = 0) => new Date(localMs(date, time, p.timeZone) + plus * 60_000).toISOString();
      const plan: [TimeEvent["kind"], string, string | null][] = [
        ["start", at("08:50", j), "available"],
        ["status", at("11:00", j % 7), "break"],
        ["status", at("11:15", j % 7), "available"],
        ["status", at("13:30"), "lunch"],
        ["status", at("14:00"), "available"],
      ];
      // Working time that is not productive, so every group of the Dashboard has something to show
      if ((weekday + n) % 3 === 0) plan.push(["status", at("15:30"), "meeting"], ["status", at("16:15"), "available"]);
      if (n === 2 && weekday % 4 === 1) plan.push(["status", at("09:30"), "training"], ["status", at("10:30"), "available"]);
      const forgot = n === 3 && weekday === 2;  // Lucas: forgot to clock out
      if (!forgot) plan.push(["end", at("17:30", j), null]);
      plan.sort((a, b) => Date.parse(a[1]) - Date.parse(b[1]));
      const events = plan.filter(([, t]) => Date.parse(t) <= now).map(([k, t, s]) => mockEvent(k, t, s, "user"));
      if (events.length === 0) continue;
      // ...and the hourly sweep closed it at the default time, as the database does without a
      // planned shift (0008b): never before his last event
      if (forgot) {
        const lastMs = Math.max(...events.map((e) => Date.parse(e.at)));
        events.push(mockEvent("end", new Date(Math.max(lastMs, localMs(date, MOCK_WINDOW.autoCloseAt, p.timeZone))).toISOString(), null, "system"));
      }
      if (n === 1 && weekday === 4) {         // Jordi: an end time confirmed afterwards
        const old = events.find((e) => e.kind === "end");
        if (old) {
          events.push(mockEvent("end", at("18:10"), null, "correction", {
            supersedes: old.id, reason: "Stayed for a customer call, confirmed by phone", approvedByName: "Test supervisor",
          }));
        }
      }
      days.set(date, events);
    }
  });
}


// ---- the Team screen's fixture (migration 0004): catalog and people shaped like the directory ---

/** Same answer as the database for a caller without users.manage_agents or users.manage_all */
function assertManage(me: Principal): void {
  if (!me.permissions.includes("users.manage_agents") && !me.permissions.includes("users.manage_all")) {
    throw new CmaDbError("CMA06", "not permitted");
  }
}

const MOCK_LEVELS = [
  { level: 1, name: "Basic" }, { level: 2, name: "Good" }, { level: 3, name: "Fluent" }, { level: 4, name: "Native" },
];

/** Fictional catalog: keys and names are tenant data; nothing branches on them */
/** Fixture employers shaped like cma.organisation rows, the two of the fictional tenant */
const MOCK_ORGANISATIONS = [
  { key: "pulse4all", name: "Pulse4all", timeZone: "Europe/Amsterdam" },
  { key: "newco", name: "Newco", timeZone: "Europe/Madrid" },
];

const MOCK_TEAMS: TeamInfo[] = [
  { key: "en", name: "Team EN", markets: ["gb", "ie"], sortOrder: 10, memberCount: 0 },
  { key: "nl", name: "Team NL", markets: ["nl", "be"], sortOrder: 20, memberCount: 0 },
  { key: "de", name: "Team DE", markets: ["de", "at", "ch"], sortOrder: 30, memberCount: 0 },
  { key: "fr", name: "Team FR", markets: ["fr"], sortOrder: 40, memberCount: 0 },
  { key: "nordics", name: "Team Nordics", markets: ["dk", "se", "no", "fi"], sortOrder: 50, memberCount: 0 },
];
const MOCK_SKILLS: SkillInfo[] = [
  ...["en:English", "nl:Dutch", "de:German", "fr:French", "da:Danish", "sv:Swedish"].map((x, i) => {
    const [key, name] = x.split(":") as [string, string];
    return { dimension: "language" as const, key, name, sortOrder: (i + 1) * 10, isActive: true, levels: MOCK_LEVELS };
  }),
  ...["sales:Sales", "operations:Operations", "debt:Debt"].map((x, i) => {
    const [key, name] = x.split(":") as [string, string];
    return { dimension: "work_type" as const, key, name, sortOrder: (i + 1) * 10, isActive: true, levels: [] };
  }),
];
/** The default ladder as rows, with the managing flag the database derives from the permissions */
const MOCK_ROLES: Omit<RoleInfo, "assignable">[] = [
  { key: "agent", name: "Agent", isSystem: true, isManaging: false, permissions: ["workday.own", "roster.view", "leads.accept", "performance.own"] },
  { key: "analytics", name: "Analytics", isSystem: true, isManaging: false, permissions: ["reports.view", "performance.team", "monitoring.live", "quality.manage"] },
  { key: "supervisor", name: "Supervisor", isSystem: true, isManaging: false, permissions: ["workday.own", "roster.view", "workday.team", "performance.team", "monitoring.live", "messages.send"] },
  { key: "manager", name: "Call center manager", isSystem: true, isManaging: true, permissions: ["workday.own", "workday.team", "roster.manage", "skills.manage", "users.manage_agents", "workday.export"] },
  { key: "admin", name: "Administrator", isSystem: true, isManaging: true, permissions: ["workday.own", "workday.team", "roster.manage", "skills.manage", "users.manage_agents", "users.manage_all", "tenant.configure", "workday.export", "messages.withdraw"] },
];

function mockSkill(key: string, level: number | null): DirectoryPerson["skills"][number] {
  const s = MOCK_SKILLS.find((x) => x.key === key)!;
  return { dimension: s.dimension, key: s.key, name: s.name, level, levelName: level ? MOCK_LEVELS.find((l) => l.level === level)?.name ?? null : null };
}

function mockTeam(key: string) {
  const t = MOCK_TEAMS.find((x) => x.key === key)!;
  return { key: t.key, name: t.name };
}

/** The fictional team of five plus the test identities, as the directory would list them */
function seedPeople(): Map<string, DirectoryPerson> {
  if (state.people) return state.people;
  const person = (
    p: Pick<DirectoryPerson, "userId" | "displayName" | "organisationName" | "timeZone"> & { email: string; roleKey: string; teams?: string[]; skills?: [string, number | null][] },
  ): DirectoryPerson => {
    const role = MOCK_ROLES.find((r) => r.key === p.roleKey)!;
    return {
      userId: p.userId, email: p.email, displayName: p.displayName, isActive: true,
      organisationKey: p.organisationName.toLowerCase(), organisationName: p.organisationName, timeZone: p.timeZone,
      roleKey: role.key, roleName: role.name, isManaging: role.isManaging,
      timeKept: role.permissions.includes("workday.own"),
      teams: (p.teams ?? []).map(mockTeam),
      skills: (p.skills ?? []).map(([k, l]) => mockSkill(k, l)),
      mayEdit: false,
    };
  };
  const list: DirectoryPerson[] = [
    person({ ...TEAM[0]!, email: "ana.ferrer@example.com", roleKey: "agent", teams: ["nl", "en"], skills: [["nl", 4], ["en", 2], ["sales", null], ["operations", null]] }),
    person({ ...TEAM[1]!, email: "jordi.puig@example.com", roleKey: "agent", teams: ["de"], skills: [["de", 3], ["en", 3], ["sales", null]] }),
    person({ ...TEAM[2]!, email: "sanne.visser@example.com", roleKey: "supervisor", teams: ["nl"], skills: [["nl", 4], ["en", 3], ["operations", null], ["debt", null]] }),
    person({ ...TEAM[3]!, email: "lucas.moreau@example.com", roleKey: "agent", teams: ["fr"], skills: [["fr", 4], ["en", 2], ["sales", null]] }),
    person({ ...TEAM[4]!, email: "emma.clarke@example.com", roleKey: "agent", teams: ["en", "nordics"], skills: [["en", 4], ["da", 1], ["sales", null], ["debt", null]] }),
    person({ userId: MOCK_PRINCIPAL.userId, displayName: "Agent One", organisationName: "Newco", timeZone: "Europe/Madrid", email: "agent-one@example.com", roleKey: "agent", teams: ["nl"], skills: [["nl", 4], ["sales", null]] }),
    person({ userId: MOCK_SUPERVISOR_ID, displayName: "Test supervisor", organisationName: "Newco", timeZone: "Europe/Madrid", email: "supervisor@example.com", roleKey: "supervisor", teams: ["nl"] }),
    person({ userId: MOCK_MANAGER_ID, displayName: "Test manager", organisationName: "Pulse4all", timeZone: "Europe/Amsterdam", email: "manager@example.com", roleKey: "manager" }),
    person({ userId: MOCK_ANALYST_ID, displayName: "Test analyst", organisationName: "Pulse4all", timeZone: "Europe/Amsterdam", email: "analyst@example.com", roleKey: "analytics" }),
    person({ userId: MOCK_ADMIN_ID, displayName: "Test admin", organisationName: "Pulse4all", timeZone: "Europe/Amsterdam", email: "admin@example.com", roleKey: "admin" }),
  ];
  state.people = new Map(list.map((p) => [p.userId, p]));
  return state.people;
}

/** The directory as the database shapes it for this caller: who is listed, who may be edited */
function directoryFor(me: Principal): DirectoryPerson[] {
  const all = me.permissions.includes("users.manage_all");
  return [...seedPeople().values()]
    .filter((p) => all || p.userId === me.userId || !p.isManaging)
    .map((p) => ({ ...p, mayEdit: p.userId !== me.userId && (all || !p.isManaging) }))
    .sort((a, b) => Number(!a.isActive) - Number(!b.isActive) || a.displayName.localeCompare(b.displayName));
}

/** The database's answer when the caller may not change this person */
function editable(me: Principal, userId: string): DirectoryPerson {
  assertManage(me);
  const p = seedPeople().get(userId);
  if (!p) throw new CmaDbError("CMA02", "person not found");
  if (!(me.permissions.includes("users.manage_all") || !p.isManaging)) throw new CmaDbError("CMA06", "may not manage this person");
  return p;
}


// ---- the roster (migration 0005): fixture data, in memory --------------------------------------
// One week per team (or the tenant) with its current cells and, once published, a copy of the cells
// as published, so the agent keeps seeing the publication while the planner edits (as the
// versioned entries of 0005 give it). Dates follow the current week, as the dev fixture does.

type MockRosterWeek = {
  teamKey: string | null;
  weekStart: DateKey;
  version: number;
  publishedAt: Instant | null;
  publishedByName: string | null;
  /** `${userId}:${date}` -> current cell */
  cells: Map<string, RosterEntry>;
  /** The cells as of the last publish; null for a draft */
  published: Map<string, RosterEntry> | null;
};

/** Fixture absence types shaped like cma.absence_type rows; the screens never branch on a key */
const MOCK_ABSENCES: AbsenceType[] = [
  { key: "off", name: "Day off", isPaid: false, sortOrder: 10, isActive: true },
  { key: "leave", name: "Leave", isPaid: true, sortOrder: 20, isActive: true },
  { key: "sick", name: "Sick", isPaid: true, sortOrder: 30, isActive: true },
  { key: "public_holiday", name: "Public holiday", isPaid: true, sortOrder: 40, isActive: true },
  { key: "other", name: "Other", isPaid: false, sortOrder: 50, isActive: true },
];

/** The permission catalog as the mock knows it (keys of the default ladder) */
const MOCK_PERMISSIONS = [
  "workday.own", "workday.team", "workday.export", "roster.view", "roster.manage", "skills.manage", "leads.accept", "leads.manage",
  "performance.own", "performance.team", "monitoring.live", "messages.send", "quality.manage", "reports.view",
  "users.manage_agents", "users.manage_all", "tenant.configure", "messages.withdraw",
].map((key) => ({ key, description: key }));

/** Same answer as the database for a caller without tenant.configure (migration 0005a) */
function assertConfigure(me: Principal): void {
  if (!me.permissions.includes("tenant.configure")) throw new CmaDbError("CMA06", "not permitted");
}

/**
 * The configuration screens' state in mock mode: copies of the fixture catalogs that the screens
 * may change (nothing is saved, the page says so). Usage counts mirror the fixture days roughly:
 * every status of the fixture list has time behind it, so its flags are frozen as in the database.
 */
function seedConfig(): MockConfig {
  if (state.config) return state.config;
  state.config = {
    statuses: MOCK_STATUSES.map((x, i) => ({ ...x, isPaid: MOCK_PAID.has(x.key), isBillable: MOCK_PAID.has(x.key), sortOrder: (i + 1) * 10, isActive: true, usageCount: 12 - i })),
    links: MOCK_LINKS.map((l, i) => ({ key: l.key, label: l.label, address: l.address, permissionKey: l.permission, sortOrder: (i + 1) * 10, isActive: true })),
    absences: MOCK_ABSENCES.map((a) => ({ ...a })),
    targets: [{ teamKey: "nl", skillKey: "sales", weekday: 1, minCount: 2 }, { teamKey: "nl", skillKey: "sales", weekday: 2, minCount: 2 }],
    settings: MOCK_SETTINGS.map((x) => ({ ...x })),
    teams: MOCK_TEAMS.map((t) => ({ ...t })),
    skills: MOCK_SKILLS.map((x) => ({ ...x, levels: [...x.levels] })),
  };
  return state.config;
}

/** The catalog defaults, as cma.setting holds them, for the mock's reset */
const MOCK_SETTING_DEFAULTS: Record<string, string> = {
  "export.csv.separator": "comma", "export.csv.decimal_mark": "point", "export.csv.date_format": "yyyy-mm-dd",
  "export.csv.duration_format": "decimal_hours", "export.csv.utf8_bom": "true", "roster.adherence_tolerance_minutes": "5",
  "workday.auto_close_grace_minutes": "120", "telephony.connected_min_seconds": "0",
  "auth.invitation_valid_days": "7", "auth.invitation_email_domains": "",
  "reports.cancellation_kind": "", "speed_to_lead.target_minutes": "60", "tickets.sla_minutes": "240", "tickets.sla_warning_pct": "75", "leads.age_buckets_business_days": "1,2,5", "tasks.callback_window_minutes": "240",
  "follow_up.list_rows": "100",
  "attribution.window_days": "90", "attribution.level_order": "lead_deal,conversation,email,phone_match,attempt,known_contact",
  "attribution.assisted_levels": "lead_deal,conversation,email,phone_match", "attribution.known_contact_minutes": "60", "attribution.order_match_minutes": "1440",
  "attempts.max_bucket": "5", "attempts.since_last_buckets_business_days": "1,2,5", "attempts.source": "telephony",
  "calls.conversation_min_talk_seconds": "30", "attempts.speed_buckets_business_minutes": "5,15,60,240,1440",
};

function assertRosterManage(me: Principal): void {
  if (!me.permissions.includes("roster.manage")) throw new CmaDbError("CMA06", "not permitted");
}

const rosterKey = (teamKey: string | null, weekStart: DateKey) => `${teamKey ?? ""}:${weekStart}`;

function mockEntry(userId: string, date: DateKey, cell: RosterCellInput, by: string): RosterEntry | null {
  if (cell.kind === "clear") return null;
  const absence = cell.kind === "absence" ? MOCK_ABSENCES.find((a) => a.key === cell.absenceKey) : null;
  if (cell.kind === "absence" && !absence) throw new CmaDbError("CMA02", "unknown absence type");
  return {
    entryId: crypto.randomUUID(), userId, date, kind: cell.kind,
    start: cell.kind === "shift" ? `${cell.start}:00` : null, end: cell.kind === "shift" ? `${cell.end}:00` : null,
    absenceKey: absence?.key ?? null, absenceName: absence?.name ?? null, note: cell.note ?? null,
    recordedAt: new Date().toISOString(), recordedByName: by,
  };
}

function rosterWeekOf(teamKey: string | null, weekStart: DateKey): MockRosterWeek {
  const weeks = seedRosters();
  const k = rosterKey(teamKey, weekStart);
  let w = weeks.get(k);
  if (!w) {
    w = { teamKey, weekStart, version: 0, publishedAt: null, publishedByName: null, cells: new Map(), published: null };
    weeks.set(k, w);
  }
  return w;
}

/** This week published for Team NL and Team Nordics (one cell changed afterwards), next week a draft for Team NL */
function seedRosters(): Map<string, MockRosterWeek> {
  if (state.rosters) return state.rosters;
  state.rosters = new Map();
  const today = dateKeyInZone(new Date(), "Europe/Amsterdam");
  const week = startOfWeek(today);
  const next = addDays(week, 7);
  const by = "Test manager";
  const put = (w: MockRosterWeek, userId: string, date: DateKey, cell: RosterCellInput) => {
    const e = mockEntry(userId, date, cell, by);
    if (e) w.cells.set(`${userId}:${date}`, e);
  };
  const publish = (w: MockRosterWeek) => {
    w.version += 1;
    w.publishedAt = new Date().toISOString();
    w.publishedByName = by;
    w.published = new Map([...w.cells].map(([k, e]) => [k, { ...e }]));
  };
  const nl = rosterWeekOf("nl", week);
  const nordics = rosterWeekOf("nordics", week);
  for (let i = 0; i < 5; i++) {
    const d = addDays(week, i);
    put(nl, MOCK_PRINCIPAL.userId, d, { kind: "shift", start: "09:00", end: "17:30" });
    put(nl, TEAM[0]!.userId, d, { kind: "shift", start: "09:00", end: "17:30" });
    put(nl, TEAM[2]!.userId, d, i === 2 ? { kind: "absence", absenceKey: "leave" } : { kind: "shift", start: "08:30", end: "17:00" });
    if (i < 4) put(nordics, TEAM[4]!.userId, d, { kind: "shift", start: "10:00", end: "18:00" });
  }
  put(nordics, TEAM[4]!.userId, addDays(week, 4), { kind: "absence", absenceKey: "leave" });
  publish(nl);
  publish(nordics);
  // One change after the publish: the planner shows it, the agent keeps the published time
  put(nl, MOCK_PRINCIPAL.userId, addDays(week, 4), { kind: "shift", start: "09:00", end: "15:00", note: "Dentist, agreed with the team lead" });
  const draft = rosterWeekOf("nl", next);
  for (let i = 0; i < 5; i++) {
    const d = addDays(next, i);
    put(draft, MOCK_PRINCIPAL.userId, d, { kind: "shift", start: "09:00", end: "17:30" });
    put(draft, TEAM[0]!.userId, d, i === 3 ? { kind: "absence", absenceKey: "off" } : { kind: "shift", start: "12:00", end: "20:00" });
  }
  return state.rosters;
}

function rosterHeaderOf(w: MockRosterWeek): RosterWeekHeader {
  const team = w.teamKey ? MOCK_TEAMS.find((t) => t.key === w.teamKey) : null;
  const changed = w.published !== null && (w.cells.size !== w.published.size ||
    [...w.cells].some(([k, e]) => { const p = w.published!.get(k); return !p || p.entryId !== e.entryId; }));
  return {
    weekId: w.version > 0 || w.cells.size > 0 ? `mock:${rosterKey(w.teamKey, w.weekStart)}` : null,
    teamKey: w.teamKey, teamName: team?.name ?? null, weekStart: w.weekStart,
    status: w.version > 0 ? "published" : "draft", version: w.version, publishedAt: w.publishedAt, publishedByName: w.publishedByName,
    entryCount: w.cells.size, changedSincePublish: changed,
  };
}

/** The people on a roster's grid: whose time is kept, and for a team roster its members */
function rosterPeopleOf(teamKey: string | null): DirectoryPerson[] {
  return [...seedPeople().values()]
    .filter((p) => p.isActive && p.timeKept && (!teamKey || p.teams.some((t) => t.key === teamKey)))
    .sort((a, b) => a.displayName.localeCompare(b.displayName));
}

/** The published cell of a person on a date across every roster, with the week it came from */
function publishedCellFor(userId: string, date: DateKey): { entry: RosterEntry | null; week: MockRosterWeek } | null {
  const weekStart = startOfWeek(date);
  const person = seedPeople().get(userId);
  for (const w of seedRosters().values()) {
    if (w.weekStart !== weekStart || !w.published) continue;
    if (w.teamKey && !person?.teams.some((t) => t.key === w.teamKey)) continue;
    const entry = w.published.get(`${userId}:${date}`) ?? null;
    if (entry) return { entry, week: w };
  }
  const covering = [...seedRosters().values()].find((w) => w.weekStart === weekStart && w.published && (!w.teamKey || person?.teams.some((t) => t.key === w.teamKey)));
  return covering ? { entry: null, week: covering } : null;
}

// ---- Messaging (migration 0008): fixtures shaped like cma.message and cma.message_delivery ---------

/** Same answer as the database for a caller without messages.send */
function assertSend(me: Principal): void {
  if (!me.permissions.includes("messages.send")) throw new CmaDbError("CMA06", "not permitted");
}

/** A synthetic alert arrives every few minutes in mock mode, so the toast and the inbox can be seen without a source */
const SYNTHETIC_ALERT_EVERY_MS = 3 * 60_000;

function mockMessageId(): string {
  state.messageSeq += 1;
  return `00000000-0000-7000-8000-0000000a${String(state.messageSeq).padStart(4, "0")}`;
}

function addMockMessage(m: Omit<MockMessage, "id" | "deliveries">): MockMessage {
  const row: MockMessage = { ...m, id: mockMessageId(), deliveries: new Map() };
  state.messages.set(row.id, row);
  return row;
}

/** Three fictional messages per tenant on first use: a welcome, an alert with a link, an urgent one already confirmed */
function seedMessages(me: Principal, now: Instant): void {
  if (state.messagesSeeded.has(me.tenantId)) return;
  state.messagesSeeded.add(me.tenantId);
  const ago = (minutes: number) => new Date(Date.parse(now) - minutes * 60_000).toISOString();
  addMockMessage({ tenantId: me.tenantId, kind: "announcement", urgency: "normal", title: "Welcome to the Workspace (test)",
    body: "Clock in on Welcome and pick your status on My day. Questions go to your supervisor.", ref: null,
    createdAt: ago(130), expiresAt: null, everyone: true, users: new Set(), byRule: false });
  addMockMessage({ tenantId: me.tenantId, kind: "alert", urgency: "normal", title: "New deal",
    body: "NL · Sales (test) · created 09:40", ref: { system: "crm_test", type: "deal", id: "4100000001", url: "https://example.com/crm/deals/4100000001" },
    createdAt: ago(25), expiresAt: null, everyone: true, users: new Set(), byRule: true });
  const urgent = addMockMessage({ tenantId: me.tenantId, kind: "announcement", urgency: "urgent", title: "Line check at 12:00 (test)",
    body: "Stay available between 12:00 and 12:15.", ref: null, createdAt: ago(60), expiresAt: null, everyone: true, users: new Set(), byRule: false });
  urgent.deliveries.set(me.userId, { deliveredAt: ago(59), readAt: ago(58), acknowledgedAt: ago(58) });
}

/** A new fictional alert every few minutes, to everyone, as the ingest service's rule would raise it */
function maybeSyntheticAlert(me: Principal, now: Instant): void {
  if (Date.parse(now) - state.lastSyntheticAlertAt < SYNTHETIC_ALERT_EVERY_MS) return;
  state.lastSyntheticAlertAt = Date.parse(now);
  const n = 4100000100 + state.messageSeq;
  const hhmm = new Intl.DateTimeFormat("en-GB", { timeZone: me.timeZone, hour: "2-digit", minute: "2-digit" }).format(new Date(now));
  addMockMessage({ tenantId: me.tenantId, kind: "alert", urgency: "normal", title: "New deal", body: `NL · Sales (test) · created ${hhmm}`,
    ref: { system: "crm_test", type: "deal", id: String(n), url: `https://example.com/crm/deals/${n}` }, createdAt: now, expiresAt: null,
    everyone: true, users: new Set(), byRule: true });
}

/** The caller's delivery of a message, created on the first poll for an "everyone" message; null when it is not theirs */
function deliveryOf(m: MockMessage, me: Principal): MockDelivery | null {
  if (m.tenantId !== me.tenantId) return null;
  const existing = m.deliveries.get(me.userId);
  if (existing) return existing;
  if (!m.everyone && !m.users.has(me.userId)) return null;
  const fresh: MockDelivery = { deliveredAt: null, readAt: null, acknowledgedAt: null };
  m.deliveries.set(me.userId, fresh);
  return fresh;
}

function isExpired(m: MockMessage, now: Instant): boolean {
  return m.expiresAt !== null && Date.parse(m.expiresAt) <= Date.parse(now);
}

/** The caller's own rows, newest first, as cma.my_messages lists them (expired and withdrawn ones left out) */
function ownMessages(me: Principal, now: Instant): { m: MockMessage; d: MockDelivery }[] {
  const out: { m: MockMessage; d: MockDelivery }[] = [];
  for (const m of state.messages.values()) {
    if (isExpired(m, now) || m.withdrawnAt) continue;
    const d = deliveryOf(m, me);
    if (d) out.push({ m, d });
  }
  return out.sort((a, b) => b.m.createdAt.localeCompare(a.m.createdAt) || b.m.id.localeCompare(a.m.id));
}

function toMyMessage(m: MockMessage, d: MockDelivery): MyMessage {
  return { id: m.id, kind: m.kind, urgency: m.urgency, title: m.title, body: m.body, ref: m.ref, createdAt: m.createdAt, expiresAt: m.expiresAt,
    deliveredAt: d.deliveredAt, readAt: d.readAt, acknowledgedAt: d.acknowledgedAt };
}

/** Whether a person has an open, started day today (cma.is_clocked_in) */
function isClockedIn(me: Principal, userId: string, now: Instant): boolean {
  const date = dateKeyInZone(now, me.timeZone);
  const w = store.get(`${me.tenantId}:${userId}:${date}` as Key);
  return !!w && w.status === "working";
}

/** Resolves a target to people now, as cma.send_message does; CMA02 for an unknown team, skill or person, CMA04 for nobody */
function resolveTarget(me: Principal, target: MessageTarget, now: Instant): { everyone: boolean; users: Set<string> } {
  const people = [...seedPeople().values()].filter((p) => p.isActive);
  const clocked = (id: string) => !target.onlyClockedIn || isClockedIn(me, id, now);
  let users: string[];
  let everyone = false;
  if ("everyone" in target) {
    everyone = !target.onlyClockedIn;
    users = people.map((p) => p.userId);
  } else if ("teams" in target) {
    for (const k of target.teams) if (!MOCK_TEAMS.some((t) => t.key === k)) throw new CmaDbError("CMA02", "not found");
    users = people.filter((p) => p.teams.some((t) => target.teams.includes(t.key))).map((p) => p.userId);
  } else if ("language" in target) {
    const skill = MOCK_SKILLS.find((x) => x.dimension === "language" && x.key === target.language.skill);
    if (!skill) throw new CmaDbError("CMA02", "not found");
    users = people.filter((p) => p.skills.some((x) => x.key === skill.key && (target.language.minLevel === null || (x.level ?? 0) >= target.language.minLevel))).map((p) => p.userId);
  } else {
    for (const id of target.users) if (!people.some((p) => p.userId === id)) throw new CmaDbError("CMA02", "not found");
    users = target.users;
  }
  const chosen = new Set(users.filter(clocked));
  if (chosen.size === 0 && !everyone) throw new CmaDbError("CMA04", "the target reaches nobody now");
  return { everyone, users: chosen };
}

// ---- Sources, markets, alert rules and linked accounts (addition 0008e): fixture data, in memory --------
// Fictional connections with neutral adapter values (crmtest, phonetest, shoptest, automationtest),
// invented ids, example.com hosts and form, outcome, line and tag names that look like a tenant's, so every
// section and both pattern rules can be tried. The screens never branch on these values.

type MockSource = SourceDetail & { tenantId: string };
type MockIntakeConfig = {
  sources: MockSource[];
  /** The tenant's form categories (addition 0008p); forms counted from the sources */
  categories: Omit<FormCategory, "forms">[];
  markets: MarketConfig[];
  hours: OfficeHours[];
  holidays: MarketHoliday[];
  rules: AlertRule[];
  accounts: LinkedAccount[];
  /** The tenant's record kinds and the rules that give records a kind (addition 0008zb) */
  kinds: (RecordKind & { sortOrder: number })[];
  kindRules: KindRuleFixture[];
};

function mockSource(tenantId: string, n: number, adapter: string, name: string, accountId: string, kind: SourceKind | null, o: Partial<SourceDetail> = {}, settings: SourceConnection["settings"] = {}): MockSource {
  const connection: SourceConnection = {
    id: `00000000-0000-7000-8000-00000000c00${n}`, key: `k${n}${"0".repeat(20)}test`, adapter, name, accountId, kind, heldKinds: [], isActive: true,
    signingSecretName: `ingest-${adapter}-signing`,
    tokenSecretName: kind === "crm" || kind === "telephony" || kind === "reviews" ? `ingest-${adapter}-token` : null,
    settings, events24h: 40 + n * 7, eventsWaiting: n === 1 ? 2 : 0, eventsParked: 0, lastEventAt: new Date(Date.now() - n * 60_000).toISOString(),
    pipelines: 0, forms: 0, callOutcomes: 0, fields: 0, lines: 0, tags: 0, storeHandle: null,
  };
  return {
    tenantId, connection, pipelines: [], forms: [], callOutcomes: [], lines: [], tags: [], fields: [], writeback: [], store: null, sampleIds: {},
    missedReasons: [], taskStatuses: [], taskTypes: [], inboxes: [], mailboxes: [], inboxChannels: [], reasons: [], reviewChannels: [], ...o,
  };
}

const form = (formId: string, name: string, isCounted = true, leadSource: string | null = null, market: string | null = null, o: Partial<SourceForm> = {}): SourceForm =>
  ({ formId, name, isCounted, isPolled: isCounted, category: null, leadSource, market, keptFields: [], marketField: null, leadCondition: null, fields: [], isActive: true, ...o });
// The fixture forms' fields (addition 0008p): names and option values only, invented
const choice = (name: string, kind: SourceFormField["kind"], options: string[]): SourceFormField => ({ name, kind, options });
const MOCK_CUSTOMER = choice("are_you_already_a_customer", "radio", ["Yes, I'm an existing customer (test)", "No, I'm not a customer yet (test)"]);
const MOCK_COUNTRY = choice("country_dropdown", "dropdown", ["United Kingdom", "Netherlands", "Germany", "Atlantis (test)"]);
const MOCK_FORM_FIELDS = {
  quote: [choice("email", "other", []), choice("product_interest", "dropdown", ["AED Plus (test)", "AED 3 (test)"]), choice("message", "other", [])],
  contact: [choice("email", "other", []), MOCK_CUSTOMER, choice("message", "other", [])],
  info: [choice("email", "other", []), choice("use_case", "dropdown", ["Office (test)", "Sports club (test)", "Home (test)"])],
  cancellation: [choice("email", "other", []), choice("cancellation_reason", "dropdown", ["Moving (test)", "Price (test)", "Other (test)"]), MOCK_COUNTRY],
  replacement: [choice("email", "other", []), choice("exchange_reason", "dropdown", ["Battery (test)", "Pads (test)"]), choice("serial_number", "other", [])],
  support: [choice("email", "other", []), choice("hs_ticket_category", "multiple_checkboxes", ["Billing (test)", "Device (test)", "Delivery (test)"]), MOCK_COUNTRY],
};
const outcome = (outcomeRef: string, label: string, isConnected: boolean): SourceCallOutcome => ({ outcomeRef, label, isConnected, isActive: true });
const pipeline = (recordType: string, pipelineId: string, label: string, isCounted: boolean, isLead: boolean, slaMinutes: number | null = null,
  isOrder = false, stages: SourceStage[] = []): SourcePipeline =>
  ({ recordType, pipelineId, label, isCounted, isRouted: false, isLead, workType: null, isActive: true, slaMinutes, isOrder, stages });
/** A pipeline stage with its outcome (addition 0008u): the source's unless a person chose it */
const stage = (stageId: string, label: string, isClosed: boolean, outcome: SourceStage["outcome"] = null, outcomeSource: SourceStage["outcomeSource"] = null): SourceStage =>
  ({ stageId, label, isClosed, outcome, outcomeSource: outcome === null ? outcomeSource : outcomeSource ?? "source", isActive: true, readTimes: true, readTimesSet: false });
/** A field mapping (0008e); the reason field with its data type as the adapter read it (0008zb) */
const mapped = (entity: string, field: string, property: string, refSystem: string | null = null, sourceType: string | null = null): SourceField =>
  ({ entity, field, refSystem, slot: 1, property, sourceType, checkedAt: sourceType ? new Date(Date.now() - 50 * 60_000).toISOString() : null,
     state: field === "reason" ? reasonStateOf(property, sourceType) : null });
/** A reason option of the CRM connection's catalog (0008zb): invented values and labels */
const reason = (recordType: SourceReason["recordType"], value: string, label: string, order: number, isDataQuality = false): SourceReason =>
  ({ recordType, value, label, order, isDataQuality, isActive: true });
/** The task catalogs of the fixture's CRM connection (addition 0008n), consistent with the follow-up rows below */
const taskStatus = (statusRef: string, label: string, isDone: boolean, seenTasks: number): SourceTaskStatus =>
  ({ statusRef, label, isDone, seenTasks, lastSeenAt: seenTasks ? new Date(Date.now() - 3 * 3_600_000).toISOString() : null });
const taskType = (typeRef: string, label: string, isCallback: boolean, isCounted: boolean, seenTasks: number, openTasks: number): SourceTaskType =>
  ({ typeRef, label, isCallback, isCounted, seenTasks, openTasks, lastSeenAt: seenTasks ? new Date(Date.now() - 3 * 3_600_000).toISOString() : null });

function seedIntakeConfig(me: Principal): MockIntakeConfig {
  const all = (state.intakeConfig ??= new Map());
  const existing = all.get(me.tenantId);
  if (existing) return existing;
  const t = me.tenantId;
  const crm = mockSource(t, 1, "crmtest", "Customer records (test)", "100200300", "crm", {
    // since addition 0008u the deal pipelines carry their stages' outcomes; Web orders is the order pipeline (not for tenant two, which has no shop)
    // since addition 0008zb Sales has a Quote sent stage and a closed stage without an outcome, and the tickets a Cancellations pipeline
    pipelines: [pipeline("deal", "p-sales", "Sales (test)", true, true, null, false,
      [stage("s-new", "New (test)", false), stage("s-qualified", "Qualified (test)", false), stage("s-quote", "Quote sent (test)", false),
        stage("s-won", "Won (test)", true, "won"), stage("s-lost", "Lost (test)", true, "lost"), stage("s-closed", "Closed other (test)", true)]),
      pipeline("deal", "p-self-serve", "Web orders (test)", true, false, null, t !== MOCK_TENANT_2,
        [stage("s-paid", "Paid (test)", true, "won"), stage("s-refunded", "Refunded (test)", true, "lost", "person")]),
      pipeline("deal", "p-sandbox", "Sandbox (test)", true, true, null, false, [stage("s-open", "Open (test)", false)]),
      pipeline("ticket", "p-support", "Support (test)", true, true),
      // Billing keeps its own response time of an hour (addition 0008o); Support follows the tenant default
      pipeline("ticket", "p-billing", "Billing (test)", true, true, 60),
      pipeline("ticket", "p-cancel", "Cancellations (test)", true, false)],
    taskStatuses: [taskStatus("NOT_STARTED", "Not started", false, 5), taskStatus("IN_PROGRESS", "In progress", false, 0), taskStatus("COMPLETED", "Completed", true, 12)],
    taskTypes: [taskType("CALL", "Call", false, true, 3, 3), taskType("CALLBACK", "Callback", true, true, 1, 1), taskType("EMAIL", "Email", false, true, 1, 1),
      taskType("INTERNAL", "Internal note", false, false, 2, 0)],
    // since addition 0008p: lead forms counted and polled, support forms polled and not counted, a newsletter neither
    forms: [form("f-101", "NL - Quote form (test)", true, null, null, { category: "quote", keptFields: ["product_interest"], fields: MOCK_FORM_FIELDS.quote }),
      form("f-102", "UK - Contact form (test)", true, null, null, { category: "contact", keptFields: ["are_you_already_a_customer"], fields: MOCK_FORM_FIELDS.contact,
        leadCondition: { field: "are_you_already_a_customer", values: ["No, I'm not a customer yet (test)"] } }),
      form("f-103", "DE Info request (test)", true, null, null, { category: "info", keptFields: ["use_case"], fields: MOCK_FORM_FIELDS.info }),
      form("f-104", "NL - Cancellation form (test)", false, null, "NL", { isPolled: true, category: "cancellation", keptFields: ["cancellation_reason"], fields: MOCK_FORM_FIELDS.cancellation }),
      form("f-105", "UK - Replacement request (test)", false, null, "GB", { isPolled: true, category: "replacement", keptFields: ["exchange_reason"], fields: MOCK_FORM_FIELDS.replacement }),
      form("f-106", "Support question (test)", false, null, null, { isPolled: true, category: "support", keptFields: ["hs_ticket_category", "country_dropdown"],
        marketField: "country_dropdown", fields: MOCK_FORM_FIELDS.support }),
      form("f-107", "Newsletter sign-up (test)", false),
      form("f-108", "BE Quote form (test)", true, "quote", "BE", { category: "quote", keptFields: ["product_interest"], fields: MOCK_FORM_FIELDS.quote })],
    callOutcomes: [outcome("o-1", "Connected", true), outcome("o-2", "Not reached", true), outcome("o-3", "Voicemail", true), outcome("o-4", "Busy", false),
      outcome("o-5", "Wrong number", false), outcome("o-6", "Left live message", true), outcome("o-7", "Do not call or email", false)],
    fields: [mapped("contact", "country", "contact_country"), mapped("contact", "language", "contact_language"),
      mapped("contact", "ref", "contact_shop_id_1", "shoptest"), mapped("deal", "market", "deal_country"),
      // the reasons (addition 0008zb): the deal's lost reason from a dropdown, the ticket's cancellation reason likewise
      mapped("deal", "reason", "lost_reason_dropdown", null, "enumeration"), mapped("ticket", "reason", "cancel_reason_dropdown", null, "enumeration")],
    reasons: [reason("deal", "too_expensive", "Too expensive (test)", 1), reason("deal", "bad_timing", "Bad timing (test)", 2),
      reason("deal", "chose_other", "Chose another supplier (test)", 3), reason("deal", "no_budget", "No budget (test)", 4),
      reason("deal", "duplicate", "Duplicate (test)", 5, true), reason("deal", "wrong_number", "Wrong number (test)", 6, true),
      reason("ticket", "moving", "Moving (test)", 1), reason("ticket", "price", "Price (test)", 2), reason("ticket", "other", "Other (test)", 3)],
    writeback: [{ field: "commerce_ref", slot: 1, property: "contact_shop_id_1", mode: "slot", enabled: true },
      { field: "country", slot: 1, property: "contact_country", mode: "if_empty", enabled: true }],
    sampleIds: { deal: "41000123", ticket: "52000456", task: "63000789" },
    // the conversations' catalog (additions 0008m and 0008t; the second tenant has none: "No email connected")
    ...(t === MOCK_TENANT_2 ? {} : {
      inboxes: MOCK_EMAIL_INBOXES.map((x) => ({ ...x, isActive: true })),
      mailboxes: MOCK_EMAIL_ACCOUNTS.map((x) => ({ ...x, isActive: true })),
      inboxChannels: [{ channelId: "1002", name: "Email", kind: "email", isCounted: true, isActive: true },
        { channelId: "1003", name: "Chat", kind: "chat", isCounted: false, isActive: true }],
    }),
  }, { app_host: "crm.example.com", record_url_deal: "https://{app_host}/records/{account}/deal/{id}", record_url_ticket: "https://{app_host}/records/{account}/ticket/{id}",
       record_url_task: "https://{app_host}/records/{account}/task/{id}",
       ...(t === MOCK_TENANT_2 ? {} : { email_poll: true, email_origin_property: "hs_engagement_source", email_inbox_copy_origins: "CONVERSATIONS",
         email_automated_origins: "AUTOMATION_PLATFORM", record_url_thread: "https://{app_host}/inbox/{account}/thread/{id}" }) });
  const sources: MockSource[] = [crm];
  if (t !== MOCK_TENANT_2) {
    sources.push(mockSource(t, 2, "phonetest", "Phones (test)", "4400", "telephony", {
      lines: [{ lineRef: "l-1", name: "NL sales line (test)", digits: "+31200000001", market: "NL", isCounted: true, isActive: true },
        { lineRef: "l-2", name: "UK sales line (test)", digits: "+442000000002", market: "GB", isCounted: true, isActive: true },
        { lineRef: "l-3", name: "Test line (test)", digits: null, market: null, isCounted: false, isActive: true }],
      // with their meanings (addition 0008zc): Voicemail means not reached, so a call carrying it is no conversation
      tags: [{ tagRef: "t-1", name: "Quote", isCounted: true, meaning: "call_type", isActive: true },
        { tagRef: "t-2", name: "Courtesy call", isCounted: true, meaning: "courtesy_attempt", isActive: true },
        { tagRef: "t-3", name: "Internal", isCounted: false, meaning: null, isActive: true },
        // twelve more (addition 0008j), so the Calls report shows its top twelve tags and Other
        ...MOCK_EXTRA_TAGS.map((name, i) => ({ tagRef: `t-${i + 4}`, name, isCounted: true, meaning: name === "Voicemail" ? "not_reached" as const : null, isActive: true }))],
    }, { record_url_call: "https://phone.example.com/calls/{id}" }));
    sources.push(mockSource(t, 3, "shoptest", "Shop NL (test)", "shop-nl-test.example.com", "commerce", {
      store: { handle: "shop-nl-test", name: "Shop NL (test)", market: "NL", currency: "EUR", timeZone: "Europe/Amsterdam" },
    }, { api_version: "2026-10", client_id: "test-client-id" }));
    sources.push(mockSource(t, 4, "automationtest", "Automations (test)", "100200300", null, {}, { record_url_deal: "https://crm.example.com/records/{account}/deal/{id}" }));
    // a reviews connection (addition 0008ze): two channels mapped and counted, one new from the source (no market, not counted)
    sources.push(mockSource(t, 5, "reviewtest", "Reviews (test)", "acc-test", "reviews", {
      reviewChannels: MOCK_REVIEW_CHANNELS.map((c) => ({ channelId: c.channelId, name: c.name, locale: c.locale, market: c.market, isCounted: c.isCounted,
        firstSeenAt: new Date(Date.now() - 40 * 86_400_000).toISOString(), deletedAt: null, reviews: 0, lastSubmittedAt: null })),
    }, { client_id: "test-client-id", crm_connection_id: crm.connection.id, record_url_review: "https://reviews.example.com/{account}/reviews/{id}" }));
  }
  const market = (code: string, name: string, timeZone: string, languageCode: string, currency: string, sortOrder: number, aliases: string[], active = true): MarketConfig =>
    ({ code, name, timeZone, languageCode, languageSkillKey: active ? languageCode : null, minLanguageLevel: active ? 3 : null, currency, isActive: active, sortOrder, aliases });
  const category = (code: string, name: string, sortOrder: number, isActive = true) => ({ code, name, sortOrder, isActive });
  const cfg: MockIntakeConfig = {
    sources,
    categories: [category("contact", "Contact (test)", 10), category("info", "Info (test)", 20), category("quote", "Quote (test)", 30),
      category("cancellation", "Cancellation (test)", 40), category("replacement", "Replacement (test)", 50), category("support", "Support (test)", 60),
      category("legacy", "Legacy (test)", 90, false)],
    markets: [market("NL", "Netherlands", "Europe/Amsterdam", "nl", "EUR", 10, ["holland", "nederland", "the netherlands"]),
      market("BE", "Belgium", "Europe/Brussels", "nl", "EUR", 20, ["belgie", "belgique"]),
      market("GB", "United Kingdom", "Europe/London", "en", "GBP", 30, ["england", "great britain", "uk", "united kingdom"]),
      market("DE", "Germany", "Europe/Berlin", "de", "EUR", 40, ["deutschland"]),
      market("ES", "Spain", "Europe/Madrid", "es", "EUR", 90, [], false)],
    hours: [1, 2, 3, 4, 5].map((weekday) => ({ market: "*", weekday, hours: "09:00-17:00" }))
      .concat([1, 2, 3, 4, 5].map((weekday) => ({ market: "GB", weekday, hours: "09:00-12:30,13:00-17:30" }))),
    holidays: [{ market: "NL", day: `${new Date().getUTCFullYear()}-12-25`, name: "Christmas Day" }, { market: "*", day: `${new Date().getUTCFullYear()}-12-31`, name: "Office closed (test)" }],
    rules: [
      { id: "00000000-0000-7000-8000-0000000a0001", name: "New deal", trigger: "record_created", recordType: "deal", pipelineIds: [], audiencePermission: "leads.accept",
        matchLanguage: true, onlyClockedIn: true, fallbackPermission: "leads.manage", urgency: "normal", enabled: true, maxAgeMinutes: null, alerts30d: 214,
        lastAlertAt: new Date(Date.now() - 25 * 60_000).toISOString(), maxRating: null },
      { id: "00000000-0000-7000-8000-0000000a0002", name: "Assigned deal", trigger: "record_assigned", recordType: "deal", pipelineIds: ["p-sales"], audiencePermission: "leads.accept",
        matchLanguage: false, onlyClockedIn: false, fallbackPermission: null, urgency: "urgent", enabled: true, maxAgeMinutes: 60, alerts30d: 168,
        lastAlertAt: new Date(Date.now() - 12 * 60_000).toISOString(), maxRating: null },
      // the negative-review rule of seed 02 (addition 0008ze): disabled until Kira confirms it
      ...(t === MOCK_TENANT_2 ? [] : [{ id: "00000000-0000-7000-8000-0000000a0003", name: "Negative review", trigger: "review_submitted" as const, recordType: "review",
        pipelineIds: [], audiencePermission: "performance.team", matchLanguage: false, onlyClockedIn: false, fallbackPermission: null, urgency: "normal" as const,
        enabled: false, maxAgeMinutes: 1440, alerts30d: 0, lastAlertAt: null, maxRating: 2 }]),
    ],
    accounts: [
      { userId: "00000000-0000-7000-8000-000000000201", system: "crmtest_owner", externalId: "70000001" },
      { userId: "00000000-0000-7000-8000-000000000201", system: "phonetest_user", externalId: "900001" },
      // the Calls reports' people (addition 0008j); telephony user 900009 is linked to nobody
      { userId: "00000000-0000-7000-8000-000000000202", system: "phonetest_user", externalId: "900002" },
      { userId: "00000000-0000-7000-8000-000000000203", system: "phonetest_user", externalId: "900003" },
      { userId: "00000000-0000-7000-8000-000000000204", system: "phonetest_user", externalId: "900004" },
      { userId: "00000000-0000-7000-8000-000000000202", system: "crmtest_owner", externalId: "70000002" },
      { userId: MOCK_MANAGER_ID, system: "crmtest_owner", externalId: "70000009" },
    ],
    // the record kinds (addition 0008zb): a cancellation request is a ticket of the Cancellations pipeline or one with the
    // category Cancellation (test); a complaint kind with one rule, and an archived kind
    kinds: [{ key: "cancellation", label: "Cancellation request (test)", recordType: "ticket", status: "active", sortOrder: 10 },
      { key: "complaint", label: "Complaint (test)", recordType: "ticket", status: "active", sortOrder: 20 },
      { key: "old-callback", label: "Old callback (test)", recordType: "deal", status: "archived", sortOrder: 90 }],
    kindRules: [{ connectionId: crm.connection.id, kindKey: "cancellation", pipelineId: "p-cancel", category: null, isActive: true },
      { connectionId: crm.connection.id, kindKey: "cancellation", pipelineId: null, category: "Cancellation (test)", isActive: true },
      { connectionId: crm.connection.id, kindKey: "complaint", pipelineId: "p-support", category: "Complaint (test)", isActive: true }],
  };
  all.set(t, cfg);
  return cfg;
}

/** The kinds a fixture connection's rows imply, as cma.connection_held_kinds_of */
function heldKindsOf(x: SourceDetail): SourceKind[] {
  const out: SourceKind[] = [];
  if (x.pipelines.length + x.forms.length + x.callOutcomes.length + x.fields.length + x.writeback.length > 0) out.push("crm");
  if (x.lines.length + x.tags.length > 0) out.push("telephony");
  if (x.store) out.push("commerce");
  if (x.reviewChannels.length > 0) out.push("reviews");
  return out;
}

function sourceRow(x: MockSource): SourceConnection {
  return {
    ...x.connection, heldKinds: heldKindsOf(x), settings: { ...x.connection.settings }, pipelines: x.pipelines.length, forms: x.forms.length,
    callOutcomes: x.callOutcomes.length, fields: x.fields.length, lines: x.lines.length, tags: x.tags.length, storeHandle: x.store?.handle ?? null,
  };
}

function sourceOf(me: Principal, id: string): MockSource {
  assertConfigure(me);
  const x = seedIntakeConfig(me).sources.find((c) => c.connection.id === id);
  if (!x) throw new CmaDbError("CMA02", "no such connection in the current tenant");
  return x;
}

function assertMockMarket(me: Principal, code: string | null, allowDefault = false): void {
  if (code === null || (allowDefault && code === "*")) return;
  if (!seedIntakeConfig(me).markets.some((m) => m.code === code)) throw new CmaDbError("CMA02", "no such market");
}

// ---- Reviews fixture (addition 0008ze, brief B18) ---------------------------------------------------------------
// Invented channels and reviews of the main tenant's reviews connection: per day of the last 120 days, a few reviews on
// the NL and GB channels (the ratings, links and invite events spread by a hash) and one a week on the channel the source
// added without a market. Ids, ratings, times and codes only: no reviewer and no text exist here.
const MOCK_REVIEW_CHANNELS = [
  { channelId: "chl-test-nl", name: "shop-nl.example", locale: "nl_NL", market: "NL", isCounted: true },
  { channelId: "chl-test-gb", name: "shop-gb.example", locale: "en_GB", market: "GB", isCounted: true },
  { channelId: "chl-test-x", name: "shop-x.example", locale: "de_DE", market: null, isCounted: false },
];
const MOCK_INVITE_EVENTS = ["checkout", "klaviyo-integration", "order_status_from_woocommerce", null];

function mockReviewSources(me: Principal): ReviewSource[] {
  if (me.tenantId === MOCK_TENANT_2) return [];
  const channels = seedIntakeConfig(me).sources.flatMap((x) => x.reviewChannels);
  const now = Date.now();
  const out: ReviewSource[] = [];
  for (let day = 0; day < 120; day += 1) {
    for (const [i, ch] of channels.entries()) {
      const perDay = ch.channelId === "chl-test-x" ? (day % 7 === 0 ? 1 : 0) : 1 + Math.floor(hashOf(`${ch.channelId}-${day}`) * 3);
      for (let k = 0; k < perDay; k += 1) {
        const h = hashOf(`${ch.channelId}-${day}-${k}`);
        const at = now - day * 86_400_000 - Math.floor(h * 20 * 3_600_000) - (i + k) * 60_000;
        if (at > now) continue;
        out.push({ reviewId: `rev-test-${ch.channelId.slice(9)}-${day}-${k}`, channel: ch.channelId, channelName: ch.name, market: ch.market, channelCounted: ch.isCounted,
          isPublished: h > 0.04, rating: h < 0.12 ? 1 : h < 0.2 ? 2 : h < 0.3 ? 3 : h < 0.5 ? 4 : 5, submittedAt: new Date(at).toISOString(),
          linkLevel: h < 0.45 ? "order" : h < 0.6 ? "contact" : "none", inviteEventType: MOCK_INVITE_EVENTS[Math.floor(h * 1000) % 4]! });
      }
    }
  }
  return out;
}

/** The two reviews' checks over the fixture, as cma.data_quality_of counts them */
function reviewChecksOf(me: Principal): Record<string, number> {
  const c = seedIntakeConfig(me);
  const channels = c.sources.flatMap((x) => x.reviewChannels).filter((ch) => ch.deletedAt === null);
  if (channels.length === 0) return { review_channel_unmapped: 0, market_without_review_channel: 0 };
  return {
    review_channel_unmapped: channels.filter((ch) => ch.market === null).length,
    market_without_review_channel: c.markets.filter((m) => m.isActive && !channels.some((ch) => ch.market === m.code && ch.isCounted)).length,
  };
}

// ---- Follow-up fixture (addition 0008o, night run N16-B) -------------------------------------------------
// What is waiting right now in the fictional tenant, relative to the clock: leads not called (two past the
// target, one just in, one without business hours), tickets around the default response time of 240 minutes
// (74 %, 75 %, 100 %, 125 %, Billing's own hour, one without a market) and tasks around today. Owners are the
// Team hours people, Agent One and Agent Two (so Waiting for you has rows for a tester), one owner nobody maps
// to (70000077) and some rows without one. Ids only; the record links come from the connection's templates.
// The second tenant (no telephony, no shop) gets two leads and nothing else.

/** The names of the fixture's people, for the owner column; the directory's names where it has them */
function mockOwnerName(userId: string | null): string | null {
  if (userId === null) return null;
  if (userId === MOCK_PRINCIPAL.userId) return "Agent One";
  if (userId === MOCK_SUPERVISOR_ID) return "Agent Two";
  return TEAM.find((p) => p.userId === userId)?.displayName ?? null;
}

function mockRecordUrl(me: Principal, connectionId: string, recordType: string, sourceId: string): string | null {
  const c = seedIntakeConfig(me).sources.find((x) => x.connection.id === connectionId)?.connection;
  const template = c?.settings[`record_url_${recordType}`];
  return c && typeof template === "string" ? recordUrlPreview(template, c.settings, c.accountId, sourceId) : null;
}

/** cma.age_bucket_of against the fixture's edges 1,2,5 */
function mockBucket(days: number | null): { from: number | null; to: number | null } {
  if (days === null) return { from: null, to: null };
  let prev = 0;
  for (const edge of [1, 2, 5]) {
    if (days <= edge) return { from: prev, to: edge };
    prev = edge;
  }
  return { from: prev, to: null };
}

function mockFollowUpRows(me: Principal, nowMs: number): { leads: OpenLead[]; tickets: OpenTicket[]; tasks: OpenTask[] } {
  const conn = MOCK_CRM_CONNECTION;
  const today = mockToday(me);
  const target = Number(mockSetting("speed_to_lead.target_minutes") || 60) * 60;
  const sla = Number(mockSetting("tickets.sla_minutes") || 240);
  const warn = Number(mockSetting("tickets.sla_warning_pct") || 75);
  const at = (minutesAgo: number): Instant => new Date(nowMs - minutesAgo * 60_000).toISOString();
  const ANA = TEAM[0]!.userId;
  const JORDI = TEAM[1]!.userId;
  const SANNE = TEAM[2]!.userId;
  const AGENT_ONE = MOCK_PRINCIPAL.userId;
  const AGENT_TWO = MOCK_SUPERVISOR_ID;
  const UNMAPPED = "70000077";
  const refOf = (owner: string | null, ref: string | null) => (owner ? `7${owner.slice(-7)}` : ref);

  const lead = (id: string, owner: string | null, ref: string | null, market: string, minutesAgo: number, lastCallMinutesAgo: number | null): OpenLead => {
    const createdAt = at(minutesAgo);
    const waiting = market === "unknown" ? null : mockBusinessSeconds(market, createdAt, nowMs);
    const days = market === "unknown" ? null : daysSince(dateKeyInZone(createdAt, me.timeZone), today);
    const bucket = mockBucket(days);
    return {
      dealId: `00000000-0000-7000-8000-0000000d${id.slice(-4)}`, connectionId: conn, dealSourceId: id, pipelineId: "p-sales", pipelineLabel: "Sales (test)",
      ownerUserId: owner, ownerName: mockOwnerName(owner), ownerRef: refOf(owner, ref), market, createdAt, waitingBusinessSeconds: waiting, ageBusinessDays: days,
      bucketFrom: bucket.from, bucketTo: bucket.to, pastTarget: waiting === null ? null : waiting > target,
      lastCallAt: lastCallMinutesAgo === null ? null : at(lastCallMinutesAgo),
      lastCallDays: lastCallMinutesAgo === null ? null : Math.floor(lastCallMinutesAgo / 1440), recordUrl: mockRecordUrl(me, conn, "deal", id),
    };
  };
  const ticket = (id: string, owner: string | null, ref: string | null, market: string, minutesAgo: number, pipelineId: string, pipelineLabel: string, own: number | null): OpenTicket => {
    const createdAt = at(minutesAgo);
    const open = market === "unknown" ? null : mockBusinessSeconds(market, createdAt, nowMs);
    const inForce = own ?? sla;
    const state = open === null ? "no_hours" : open >= inForce * 60 ? "breached" : open * 100 >= inForce * 60 * warn ? "at_risk" : "ok";
    return {
      ticketId: `00000000-0000-7000-8000-0000000e${id.slice(-4)}`, connectionId: conn, ticketSourceId: id, pipelineId, pipelineLabel, stageId: "s-new", stageLabel: "New",
      ownerUserId: owner, ownerName: mockOwnerName(owner), ownerRef: refOf(owner, ref), market, createdAt, openBusinessSeconds: open, slaMinutes: inForce, slaState: state,
      minutesToBreach: open === null ? null : inForce - Math.floor(open / 60), recordUrl: mockRecordUrl(me, conn, "ticket", id),
    };
  };
  const task = (id: string, owner: string | null, ref: string | null, market: string | null, typeRef: string, typeLabel: string, isCallback: boolean, priority: string | null,
    dueAt: Instant | null, recordType: "deal" | "ticket" | null, recordSourceId: string | null): OpenTask => {
    const dueDate = dueAt === null ? null : dateKeyInZone(dueAt, me.timeZone);
    return {
      taskId: `00000000-0000-7000-8000-0000000f${id.slice(-4)}`, connectionId: conn, taskSourceId: id, typeRef, typeLabel, isCallback, priorityRef: priority,
      statusRef: "NOT_STARTED", statusLabel: "Not started", ownerUserId: owner, ownerName: mockOwnerName(owner), ownerRef: refOf(owner, ref), market, dueAt,
      dueState: dueDate === null ? "none" : dueDate < today ? "overdue" : dueDate === today ? "today" : "later", recordType, recordSourceId,
      createdAt: at(2 * 1440), recordUrl: mockRecordUrl(me, conn, "task", id),
    };
  };
  const dayAt = (dayOffset: number, time: string): Instant => new Date(localMs(addDays(today, dayOffset), time, me.timeZone)).toISOString();

  const leads = [
    lead("41001001", ANA, null, "NL", 3 * 1440, 1440),
    lead("41001002", AGENT_ONE, null, "GB", 26 * 60, null),
    lead("41001003", null, UNMAPPED, "NL", 50, null),
    lead("41001004", null, null, "unknown", 20 * 60, null),
    lead("41001005", JORDI, null, "NL", 2 * 1440, null),
  ];
  if (me.tenantId === MOCK_TENANT_2) return { leads: leads.slice(0, 2), tickets: [], tasks: [] };
  // the minutes of the Support tickets as business minutes of 09:00 to 17:00 days are what the figures show; the
  // percentages of the response time hold on a working day inside office hours
  const tickets = [
    ticket("52002001", ANA, null, "NL", 177, "p-support", "Support (test)", null),
    ticket("52002002", ANA, null, "GB", 180, "p-support", "Support (test)", null),
    ticket("52002003", JORDI, null, "NL", 240, "p-support", "Support (test)", null),
    ticket("52002004", null, null, "NL", 300, "p-support", "Support (test)", null),
    ticket("52002005", AGENT_ONE, null, "NL", 90, "p-billing", "Billing (test)", 60),
    ticket("52002006", AGENT_TWO, null, "unknown", 10, "p-support", "Support (test)", null),
  ].sort((a, b) => (a.minutesToBreach === null ? 1 : b.minutesToBreach === null ? -1 : a.minutesToBreach - b.minutesToBreach));
  const tasks = [
    task("63003001", ANA, null, "NL", "CALL", "Call", false, "HIGH", dayAt(-1, "23:30"), "deal", "41001001"),
    task("63003002", AGENT_ONE, null, "GB", "CALL", "Call", false, "MEDIUM", dayAt(0, "09:30"), "ticket", "52002002"),
    task("63003003", JORDI, null, "NL", "CALLBACK", "Callback", true, null, dayAt(1, "10:00"), "deal", "41001005"),
    task("63003004", null, null, null, "EMAIL", "Email", false, null, null, null, null),
    task("63003005", null, UNMAPPED, null, "CALL", "Call", false, "LOW", dayAt(1, "14:00"), null, null),
    task("63003006", SANNE, null, "NL", "CALL", "Call", false, null, dayAt(0, "16:00"), "ticket", "52002003"),
  ];
  return { leads, tickets, tasks };
}

// ---- Invitations (addition 0008l): fixture rows per tenant, shaped like cma.invitations() ----------------
// The fixture's tokens are fictional, fixed values so the browser verifiers can open each state of
// /invite/<token>; only their hashes are kept, as in the database. Mock identities whose subject starts with
// "invitee" have no person yet (as a signed-in account the CMA does not know), until they accept.

type MockInvitation = Omit<Invitation, "state"> & { tenantId: string; tokenHash: string; createdBy: string };

/** Fixture tokens: 43 url-safe characters, as the database makes them (verify/layout.mjs opens them) */
export const MOCK_INVITE_TOKENS = {
  open: "mock-open-invitation".padEnd(43, "0"),
  expired: "mock-expired-invitation".padEnd(43, "0"),
  tenantTwo: "mock-tenant-two-invitation".padEnd(43, "0"),
} as const;

const inviteHash = (token: string) => createHash("sha256").update(token, "utf8").digest("hex");
const inviteeKey = (provider: string, subject: string) => `${provider}:${subject}`;

function mockInvitationState(i: MockInvitation): Invitation["state"] {
  if (i.acceptedAt) return "accepted";
  if (i.revokedAt) return "revoked";
  return Date.parse(i.expiresAt) <= Date.now() ? "expired" : "open";
}

function seedInvitations(): MockInvitation[] {
  if (state.invitations) return state.invitations;
  const t1 = MOCK_PRINCIPAL.tenantId;
  const day = 86_400_000;
  const at = (ms: number) => new Date(Date.now() + ms).toISOString();
  const role = (key: string) => MOCK_ROLES.find((r) => r.key === key)!;
  const org = (key: string) => MOCK_ORGANISATIONS.find((o) => o.key === key)!;
  const row = (x: { id: string; tenantId: string; token: string; email: string; displayName: string; locale: string; roleKey: string; orgKey: string;
    teams?: string[]; skills?: [string, number | null][]; createdBy: string; createdByName: string; createdAgo: number; validFor: number;
    accepted?: { name: string; ago: number }; revoked?: { name: string; ago: number } }): MockInvitation => ({
    invitationId: x.id, tenantId: x.tenantId, tokenHash: inviteHash(x.token), email: x.email, displayName: x.displayName, locale: x.locale,
    roleKey: x.roleKey, roleName: role(x.roleKey).name, organisationKey: x.orgKey, organisationName: org(x.orgKey).name,
    teams: (x.teams ?? []).map(mockTeam), skills: (x.skills ?? []).map(([k, l]) => mockSkill(k, l)),
    createdAt: at(-x.createdAgo * day), createdBy: x.createdBy, createdByName: x.createdByName, expiresAt: at((x.validFor - x.createdAgo) * day),
    renewedAt: null, acceptedAt: x.accepted ? at(-x.accepted.ago * day) : null, acceptedUserId: x.accepted ? crypto.randomUUID() : null,
    acceptedName: x.accepted?.name ?? null, revokedAt: x.revoked ? at(-x.revoked.ago * day) : null, revokedByName: x.revoked?.name ?? null,
  });
  state.invitations = [
    row({ id: "00000000-0000-7000-8000-0000000e0001", tenantId: t1, token: MOCK_INVITE_TOKENS.open, email: "invitee-one@example.com", displayName: "Invitee One",
          locale: "en", roleKey: "agent", orgKey: "newco", teams: ["nl"], skills: [["nl", 3], ["sales", null]], createdBy: MOCK_MANAGER_ID,
          createdByName: "Test manager", createdAgo: 1, validFor: 7 }),
    row({ id: "00000000-0000-7000-8000-0000000e0002", tenantId: t1, token: MOCK_INVITE_TOKENS.expired, email: "invitee-late@example.com", displayName: "Invitee Late",
          locale: "nl", roleKey: "supervisor", orgKey: "newco", teams: ["de"], createdBy: MOCK_MANAGER_ID, createdByName: "Test manager", createdAgo: 9, validFor: 7 }),
    row({ id: "00000000-0000-7000-8000-0000000e0003", tenantId: t1, token: "mock-accepted-invitation".padEnd(43, "0"), email: "invitee-joined@example.com",
          displayName: "Invitee Joined", locale: "en", roleKey: "agent", orgKey: "newco", createdBy: MOCK_MANAGER_ID, createdByName: "Test manager",
          createdAgo: 5, validFor: 7, accepted: { name: "Invitee Joined", ago: 4 } }),
    row({ id: "00000000-0000-7000-8000-0000000e0004", tenantId: t1, token: "mock-revoked-invitation".padEnd(43, "0"), email: "old.invite@example.com",
          displayName: "Old invite", locale: "nl", roleKey: "analytics", orgKey: "pulse4all", createdBy: MOCK_ADMIN_ID, createdByName: "Test admin",
          createdAgo: 6, validFor: 7, revoked: { name: "Test admin", ago: 5 } }),
    row({ id: "00000000-0000-7000-8000-0000000e0005", tenantId: t1, token: "mock-manager-invitation".padEnd(43, "0"), email: "new.manager@example.com",
          displayName: "New manager", locale: "en", roleKey: "manager", orgKey: "pulse4all", createdBy: MOCK_ADMIN_ID, createdByName: "Test admin",
          createdAgo: 0, validFor: 7 }),
    row({ id: "00000000-0000-7000-8000-0000000e0006", tenantId: MOCK_TENANT_2, token: MOCK_INVITE_TOKENS.tenantTwo, email: "invitee-two@example.com",
          displayName: "Invitee Two", locale: "nl", roleKey: "analytics", orgKey: "pulse4all", createdBy: MOCK_INVEST_ANALYST_ID,
          createdByName: "Test invest analyst", createdAgo: 0, validFor: 7 }),
  ];
  return state.invitations;
}

function mockSetting(key: string): string {
  return (state.config?.settings ?? MOCK_SETTINGS).find((x) => x.key === key)?.value ?? MOCK_SETTING_DEFAULTS[key] ?? "";
}

/** The role an invitation may carry for this caller, as cma.assert_invitation_allowed answers */
/** The fixture's system role (the scheduler's, 0008b): a role row of the tenant that is never assignable to people */
const MOCK_UNASSIGNABLE_ROLES = ["scheduler"];

function invitableRole(me: Principal, roleKey: string) {
  const role = MOCK_ROLES.find((r) => r.key === roleKey);
  if (!role && MOCK_UNASSIGNABLE_ROLES.includes(roleKey)) throw new CmaDbError("CMA06", "the role is not assignable to people");
  if (!role) throw new CmaDbError("CMA02", "unknown role");
  if (role.isManaging && !me.permissions.includes("users.manage_all")) throw new CmaDbError("CMA06", "a managing role needs users.manage_all");
  return role;
}

function assertInvitationAllowed(me: Principal, email: string): void {
  const domains = mockSetting("auth.invitation_email_domains");
  if (domains && !domains.split(",").includes(email.split("@")[1] ?? "")) throw new CmaDbError("CMA04", "outside the email domains");
  if (me.tenantId === MOCK_PRINCIPAL.tenantId && [...seedPeople().values()].some((p) => p.email === email)) {
    throw new CmaDbError("CMA03", "a person with this address exists");
  }
}

function newMockLink(i: MockInvitation): InvitationLink {
  const token = randomBytes(32).toString("base64url");
  i.tokenHash = inviteHash(token);
  return { invitationId: i.invitationId, token, expiresAt: i.expiresAt };
}

/** The invitation a caller may act on: their tenant, a role within their ceiling */
function mockInvitationFor(me: Principal, id: string): MockInvitation {
  assertManage(me);
  const i = seedInvitations().find((x) => x.invitationId === id && x.tenantId === me.tenantId);
  if (!i) throw new CmaDbError("CMA02", "invitation not found");
  invitableRole(me, i.roleKey);
  return i;
}

export const mockData: CmaData = {
  /**
   * Any verified identity may work as the test agent. A real person behind IAP
   * sees their own email, so nobody mistakes the mock for their record; roles,
   * employer and tenant are the test agent's.
   */
  async findPrincipal(identity) {
    // An identity that accepted an invitation is the person it became; an invitee-* identity has none yet
    const invitee = state.invitees?.get(inviteeKey(identity.provider, identity.subject));
    if (invitee) return invitee;
    if (identity.provider === MOCK_IDENTITY.provider && identity.subject.startsWith("invitee")) return null;
    if (identity.provider === MOCK_IDENTITY.provider && identity.subject === MOCK_IDENTITY.subject) {
      return MOCK_PRINCIPAL;
    }
    // The dev seed's test supervisor and manager: they may see and correct the fictional team
    if (identity.provider === MOCK_IDENTITY.provider && (identity.subject === "supervisor" || identity.subject === "manager")) {
      return {
        ...MOCK_PRINCIPAL,
        userId: identity.subject === "supervisor" ? MOCK_SUPERVISOR_ID : MOCK_MANAGER_ID,
        displayName: identity.subject === "supervisor" ? "Test supervisor" : "Test manager",
        roleKey: identity.subject,
        // As the default ladder after 0004: the manager also exports, manages agents and skills and plans the
        // roster; the supervisor does not; both watch the Live board
        // Both push messages to agents (messages.send, migration 0008)
        permissions: identity.subject === "manager"
          ? ["workday.own", "workday.team", "workday.export", "performance.team", "monitoring.live", "reports.view",
             "users.manage_agents", "skills.manage", "roster.manage", "roster.view", "messages.send"]
          : ["workday.own", "workday.team", "performance.team", "monitoring.live", "roster.view", "messages.send"],
      };
    }
    // The admin (0004): everything the manager has plus configuration and user management for everyone; since addition
    // 0008z also withdrawing any message (messages.withdraw, the default ladder's admin)
    if (identity.provider === MOCK_IDENTITY.provider && identity.subject === "admin") {
      return {
        ...MOCK_PRINCIPAL,
        userId: MOCK_ADMIN_ID,
        displayName: "Test admin",
        organisationName: "Pulse4all",
        roleKey: "admin",
        permissions: ["workday.own", "workday.team", "workday.export", "performance.team", "monitoring.live", "reports.view",
                      "users.manage_agents", "users.manage_all", "tenant.configure", "skills.manage", "roster.manage", "roster.view", "messages.send",
                      "messages.withdraw"],
      };
    }
    // An analytics user as in the default ladder: reports and the Dashboard, no clock, no corrections
    if (identity.provider === MOCK_IDENTITY.provider && identity.subject === "analyst") {
      return {
        ...MOCK_PRINCIPAL,
        userId: MOCK_ANALYST_ID,
        displayName: "Test analyst",
        organisationName: "Pulse4all",
        roleKey: "analytics",
        permissions: ["reports.view", "performance.team", "monitoring.live", "quality.manage"],
      };
    }
    // A reports reader (addition 0008j): reports.view without performance.team, a role a tenant can make (no
    // default role is one), so the rail shows Calls and leaves Calls per agent out
    if (identity.provider === MOCK_IDENTITY.provider && identity.subject === "reader") {
      return {
        ...MOCK_PRINCIPAL,
        userId: "00000000-0000-7000-8000-000000000107",
        displayName: "Test reader",
        organisationName: "Pulse4all",
        roleKey: "reader",
        permissions: ["reports.view"],
      };
    }
    // The second fictional tenant (B11): an analyst whose tenant has no telephony and no shop connected
    if (identity.provider === MOCK_IDENTITY.provider && identity.subject === "invest-analyst") {
      return {
        ...MOCK_PRINCIPAL,
        tenantId: MOCK_TENANT_2,
        tenantName: "Pulse4all invest (test)",
        userId: MOCK_INVEST_ANALYST_ID,
        displayName: "Test invest analyst",
        organisationName: "Pulse4all",
        roleKey: "analytics",
        timeZone: "Europe/Amsterdam",
        permissions: ["reports.view", "performance.team", "monitoring.live", "quality.manage"],
        // the second tenant switched no per-person page on: Email per agent is absent there
        perPerson: [],
      };
    }
    return {
      ...MOCK_PRINCIPAL,
      // one mock user per real person, so two testers do not share a clock
      userId: `mock:${identity.provider}:${identity.subject}`,
      displayName: identity.email,
    };
  },

  async startWorkday(me, now) {
    const date = dateKeyInZone(now, me.timeZone);
    const k = key(me, date);
    const existing = store.get(k);
    if (existing) return existing;
    // Same contract as cma.open_workday after 0003d and 0008b: nothing exists yet, so only a person
    // whose time is kept gets a day, and not before the window starts
    assertTimeKept(me);
    if (Date.parse(now) < localMs(date, MOCK_WINDOW.start, me.timeZone)) {
      throw new CmaDbError("CMA04", `the workday starts at ${MOCK_WINDOW.start}`);
    }
    seedHistory(me, date);
    const fresh: Workday = {
      date,
      status: "working",
      startedAt: now,
      endedAt: null,
      statusKey: DEFAULT_STATUS.key,
      statusName: DEFAULT_STATUS.name,
      statusSince: now,
      clock: { closedSeconds: 0, runningSince: DEFAULT_STATUS.isWorking ? now : null },
      dayEndsAt: new Date(dayEndMs(date, me.timeZone)).toISOString(),
    };
    store.set(k, fresh);
    return fresh;
  },

  async getWorkday(me, date) {
    // The fictional history exists for anyone whose time is kept, whether or not they clocked in yet
    if (me.permissions.includes("workday.own")) seedHistory(me, dateKeyInZone(new Date(), me.timeZone));
    return store.get(key(me, date)) ?? null;
  },

  async endWorkday(me, now) {
    const date = dateKeyInZone(now, me.timeZone);
    const current = store.get(key(me, date));
    // Same contract as the Postgres implementation: no day today is CMA02 (not found)
    if (!current) throw new CmaDbError("CMA02", "no workday today");
    if (current.status === "ended") return current;
    const ended: Workday = {
      ...current,
      status: "ended",
      endedAt: now,
      statusKey: null,
      statusName: null,
      statusSince: null,
      clock: closeStretch(current, now),
    };
    store.set(key(me, date), ended);
    return ended;
  },

  async listStatuses() {
    return MOCK_STATUSES;
  },

  async setStatus(me, statusKey, now) {
    const date = dateKeyInZone(now, me.timeZone);
    const current = store.get(key(me, date));
    // Same contract as cma.set_status: CMA02 no day or unknown key, CMA03 ended day
    if (!current) throw new CmaDbError("CMA02", "no workday today");
    if (current.status === "ended") throw new CmaDbError("CMA03", "workday already ended");
    const next = MOCK_STATUSES.find((s) => s.key === statusKey);
    if (!next) throw new CmaDbError("CMA02", "unknown work status");
    const closed = closeStretch(current, now);
    const updated: Workday = {
      ...current,
      statusKey: next.key,
      statusName: next.name,
      statusSince: now,
      clock: { closedSeconds: closed.closedSeconds, runningSince: next.isWorking ? now : null },
    };
    store.set(key(me, date), updated);
    return updated;
  },

  async getHours(me, range) {
    // Own hours only: hours are pay data, never a colleague's
    if (me.permissions.includes("workday.own")) seedHistory(me, dateKeyInZone(new Date(), me.timeZone));
    const mine = owner(me);
    const now = new Date().toISOString();
    const days = [...store.entries()]
      .filter(([k]) => k.startsWith(mine))
      .map(([, w]) => w)
      .filter((w) => w.date >= range.from && w.date <= range.to)
      .sort((a, b) => a.date.localeCompare(b.date))
      .map((w) => ({
        date: w.date,
        startedAt: w.startedAt,
        endedAt: w.endedAt,
        minutes: Math.floor(workedSeconds(w, now) / 60),
        // Everything between clock in and clock out that was not working time
        pauseMinutes: Math.max(0, Math.floor(secondsBetween(w.startedAt, w.endedAt ?? now) / 60) - Math.floor(workedSeconds(w, now) / 60)),
      }));
    const summary: HoursSummary = {
      ...range,
      days,
      totalMinutes: days.reduce((sum, d) => sum + d.minutes, 0),
    };
    return summary;
  },

  // Team data: a fictional team of five with a fortnight of days, held in memory like the rest.
  // The cheap rules of cma.correct_workday hold here too; the database proves the real ones.
  async listTeamPeople(me) {
    assertTeam(me);
    return TEAM;
  },

  async getTeamHours(me, range, userId) {
    assertTeam(me);
    seedTeam();
    const days: TeamDay[] = [];
    for (const p of TEAM) {
      if (userId && p.userId !== userId) continue;
      for (const [date, events] of teamStore.get(p.userId) ?? []) {
        if (date >= range.from && date <= range.to && events.length) days.push(teamDay(p, date, events));
      }
    }
    days.sort((a, b) => a.date.localeCompare(b.date) || a.displayName.localeCompare(b.displayName));
    return { ...range, days };
  },

  async getTeamDay(me, userId, date) {
    assertTeam(me);
    seedTeam();
    return readTeamDay(userId, date);
  },

  async correctWorkday(me, userId, date, correction) {
    assertTeam(me);
    seedTeam();
    if (userId === me.userId) throw new CmaDbError("CMA06", "nobody corrects their own day");
    const person = TEAM.find((p) => p.userId === userId);
    if (!person) throw new CmaDbError("CMA02", "no such person");
    const reason = correction.reason.trim();
    if (reason.length < 3 || reason.length > 500) throw new CmaDbError("CMA04", "a reason of 3 to 500 characters");
    if (date > dateKeyInZone(new Date(), person.timeZone)) throw new CmaDbError("CMA04", "date in the future");

    const days = teamStore.get(userId)!;
    const events = [...(days.get(date) ?? [])];
    const isNew = events.length === 0;
    // Within the day's window (0008b)
    const from = localMs(date, MOCK_WINDOW.start, person.timeZone);
    const to = dayEndMs(date, person.timeZone);
    correction.changes.forEach((c: CorrectionChange, i) => {
      if (isNew && i === 0 && (c.kind !== "start" || c.supersedes)) throw new CmaDbError("CMA04", "the first change must be the start");
      if (c.supersedes) {
        if (!events.some((e) => e.id === c.supersedes)) throw new CmaDbError("CMA04", "event not in this day");
        if (events.some((e) => e.supersedes === c.supersedes)) throw new CmaDbError("CMA04", "event already superseded");
      } else if (c.kind === "void") {
        throw new CmaDbError("CMA04", "void needs the event it cancels");
      }
      const ms = c.at ? Date.parse(c.at) : Date.now();
      if (c.kind !== "void" && (ms < from || ms > to || ms > Date.now() + 300_000)) {
        throw new CmaDbError("CMA04", "time outside the day or in the future");
      }
      const status = c.statusKey ? MOCK_STATUSES.find((s) => s.key === c.statusKey) : undefined;
      if ((c.kind === "start" || c.kind === "status") && !status) throw new CmaDbError("CMA02", "unknown work status");
      events.push(mockEvent(c.kind, new Date(ms).toISOString(), status?.key ?? null, "correction", {
        supersedes: c.supersedes ?? null, reason, approvedByName: me.displayName,
      }));
    });

    const live = effective(events);
    const starts = live.filter((e) => e.kind === "start");
    const ends = live.filter((e) => e.kind === "end");
    const startMs = starts[0] ? Date.parse(starts[0].at) : 0;
    const lastLive = Math.max(...live.filter((e) => e.kind !== "end").map((e) => Date.parse(e.at)));
    if (starts.length !== 1 || ends.length > 1 || live.some((e) => Date.parse(e.at) < startMs)
        || (ends[0] && Date.parse(ends[0].at) < lastLive)) {
      throw new CmaDbError("CMA04", "the day must have one start, at most one end, nothing before the start or after the end");
    }
    days.set(date, events);
    return readTeamDay(userId, date);
  },

  async listSettings() {
    return state.config ? state.config.settings.map((x) => ({ ...x })) : MOCK_SETTINGS;
  },

  async exportHours(me, range, userId) {
    assertExport(me);
    seedTeam();
    const rows: ExportHoursRow[] = [];
    for (const p of TEAM) {
      if (userId && p.userId !== userId) continue;
      for (const [date, events] of teamStore.get(p.userId) ?? []) {
        if (date < range.from || date > range.to || !events.length) continue;
        const d = teamDay(p, date, events);
        rows.push({
          userId: d.userId, displayName: d.displayName, organisationName: d.organisationName, date: d.date,
          timeZone: d.timeZone, status: d.status, startedAt: d.startedAt, endedAt: d.endedAt,
          workedSeconds: d.minutes * 60,
          productiveSeconds: statusRows(p, date, events).filter((r) => r.isProductive).reduce((n, r) => n + r.seconds, 0),
          paidSeconds: d.paidMinutes * 60, billableSeconds: d.paidMinutes * 60,
          isCapped: d.isCapped, needsCorrection: d.needsCorrection, hasCorrection: d.hasCorrection,
        });
      }
    }
    rows.sort((a, b) => a.date.localeCompare(b.date) || a.displayName.localeCompare(b.displayName));
    return { settings: MOCK_SETTINGS, rows };
  },

  async exportStatusChanges(me, range, userId) {
    assertExport(me);
    seedTeam();
    const rows: StatusChangeRow[] = [];
    for (const p of TEAM) {
      if (userId && p.userId !== userId) continue;
      for (const [date, events] of teamStore.get(p.userId) ?? []) {
        if (date >= range.from && date <= range.to && events.length) rows.push(...statusRows(p, date, events));
      }
    }
    rows.sort((a, b) => a.date.localeCompare(b.date) || a.displayName.localeCompare(b.displayName) || a.from.localeCompare(b.from));
    return { settings: MOCK_SETTINGS, rows };
  },

  /** The stretches of statusRows summed per person, day and status, as cma.team_status_time does */
  async getTeamStatusTime(me, range, userId) {
    assertPerformance(me);
    seedTeam();
    const sums = new Map<string, StatusTimeRow>();
    for (const p of TEAM) {
      if (userId && p.userId !== userId) continue;
      for (const [date, events] of teamStore.get(p.userId) ?? []) {
        if (date < range.from || date > range.to || !events.length) continue;
        for (const s of statusRows(p, date, events)) {
          const k = `${s.userId}:${s.date}:${s.statusKey}`;
          const row = sums.get(k);
          if (row) {
            row.seconds += s.seconds;
            row.stretches += 1;
            row.isCapped ||= s.isCapped;
            continue;
          }
          const order = MOCK_STATUSES.findIndex((x) => x.key === s.statusKey);
          sums.set(k, {
            userId: s.userId, displayName: s.displayName, organisationName: s.organisationName, date: s.date,
            timeZone: s.timeZone, statusKey: s.statusKey, statusName: s.statusName,
            sortOrder: (order < 0 ? MOCK_STATUSES.length : order) * 10 + 10, statusActive: true,
            isWorking: s.isWorking, isProductive: s.isProductive, isPaid: s.isPaid, isBillable: s.isBillable,
            seconds: s.seconds, stretches: 1, isCapped: s.isCapped,
          });
        }
      }
    }
    const rows = [...sums.values()].sort((a, b) =>
      a.date.localeCompare(b.date) || a.displayName.localeCompare(b.displayName) || a.userId.localeCompare(b.userId) ||
      a.sortOrder - b.sortOrder || a.statusKey.localeCompare(b.statusKey));
    return { ...range, rows };
  },

  /** The Dashboard's reads together, as the database answers them in one transaction */
  async getDashboard(me, range): Promise<DashboardData> {
    assertReportRange(range);
    return {
      time: await mockData.getTeamStatusTime(me, range, null),
      intake: await mockData.getIntake(me, range),
      records: await mockData.getCrmRecordsPerDay(me, range),
      speed: await mockData.getSpeedToLeadRows(me, range),
      callbacks: await mockData.getCallbacksKept(me, range),
    };
  },

  /** Today per person, the way cma.team_now derives it from the day's effective events */
  async getTeamNow(me): Promise<TeamNow> {
    assertLive(me);
    seedTeam();
    const people: TeamNowPerson[] = TEAM.map((p) => {
      const date = dateKeyInZone(new Date(), p.timeZone);
      const events = teamStore.get(p.userId)?.get(date) ?? [];
      const live = effective(events);
      const start = live.find((e) => e.kind === "start");
      if (!start) {
        return { userId: p.userId, displayName: p.displayName, organisationKey: p.organisationName.toLowerCase(),
          organisationName: p.organisationName, timeZone: p.timeZone, date, day: null, status: null };
      }
      const end = live.find((e) => e.kind === "end") ?? null;
      const marks = live.filter((e) => e.kind !== "end");
      const last = marks[marks.length - 1]!;
      const current = MOCK_STATUSES.find((x) => x.key === last.statusKey) ?? null;
      // Closed stretches in working statuses, each stopping at the window end; the last stretch is
      // open while the day is
      const dayEnd = dayEndMs(date, p.timeZone);
      let closed = 0;
      marks.forEach((e, i) => {
        const s = MOCK_STATUSES.find((x) => x.key === e.statusKey);
        const until = i + 1 < marks.length ? Date.parse(marks[i + 1]!.at) : end ? Date.parse(end.at) : null;
        if (s?.isWorking && until !== null) closed += Math.max(0, Math.floor((Math.min(until, dayEnd) - Date.parse(e.at)) / 1000));
      });
      const day: Workday = {
        date,
        status: end ? "ended" : "working",
        startedAt: start.at,
        endedAt: end?.at ?? null,
        statusKey: end ? null : last.statusKey,
        statusName: end ? null : current?.name ?? last.statusKey,
        statusSince: end ? null : last.at,
        clock: { closedSeconds: closed, runningSince: !end && current?.isWorking ? last.at : null },
        dayEndsAt: new Date(dayEnd).toISOString(),
      };
      const status = !end && current
        ? { key: current.key, name: current.name, isActive: true, isWorking: current.isWorking,
            isProductive: current.isProductive, isPaid: MOCK_PAID.has(current.key), isBillable: MOCK_PAID.has(current.key) }
        : null;
      return { userId: p.userId, displayName: p.displayName, organisationKey: p.organisationName.toLowerCase(),
        organisationName: p.organisationName, timeZone: p.timeZone, date, day, status };
    });
    return {
      people,
      statusFlags: MOCK_STATUSES.map((x) => ({ isWorking: x.isWorking, isProductive: x.isProductive, isPaid: MOCK_PAID.has(x.key) })),
    };
  },

  /** The fixture links this person may see, as cma.app_links filters them */
  async listAppLinks(me) {
    return MOCK_LINKS
      .filter((l) => l.permission === null || me.permissions.includes(l.permission))
      .map(({ key, label, address }) => ({ key, label, address }));
  },

  async listTeamMembersNow(me): Promise<TeamMembership[]> {
    if (!["monitoring.live", "workday.team", "roster.manage", "users.manage_agents", "users.manage_all"].some((p) => me.permissions.includes(p))) {
      throw new CmaDbError("CMA06", "not permitted");
    }
    return [...seedPeople().values()].flatMap((p) => p.teams.map((t) => ({ userId: p.userId, teamKey: t.key, teamName: t.name })));
  },

  // Team screen (0004): the cheap rules of the functions hold here too; the database proves the real ones
  async listDirectory(me) {
    assertManage(me);
    return directoryFor(me);
  },

  async listRoles(me): Promise<RoleInfo[]> {
    assertManage(me);
    const all = me.permissions.includes("users.manage_all");
    return MOCK_ROLES.map((r) => ({ ...r, assignable: all || !r.isManaging }));
  },

  async listTeams(): Promise<TeamInfo[]> {
    const people = [...seedPeople().values()];
    return MOCK_TEAMS.map((t) => ({ ...t, memberCount: people.filter((p) => p.isActive && p.teams.some((x) => x.key === t.key)).length }));
  },

  async listOrganisations() {
    return MOCK_ORGANISATIONS;
  },

  async listSkills() {
    return MOCK_SKILLS;
  },

  async addPerson(me, input) {
    assertManage(me);
    const role = MOCK_ROLES.find((r) => r.key === input.roleKey);
    if (!role) throw new CmaDbError("CMA02", "unknown role");
    if (role.isManaging && !me.permissions.includes("users.manage_all")) throw new CmaDbError("CMA06", "a managing role needs users.manage_all");
    const email = input.email.trim().toLowerCase();
    const existing = [...seedPeople().values()].find((p) => p.email === email);
    if (existing) {
      if (!existing.isActive) throw new CmaDbError("CMA03", "exists but is inactive");
      return existing.userId;   // rerun-safe, as cma.add_person
    }
    const org = MOCK_ORGANISATIONS.find((o) => o.key === input.organisationKey);
    if (!org) throw new CmaDbError("CMA02", "unknown employer");
    const userId = crypto.randomUUID();
    seedPeople().set(userId, {
      userId, email, displayName: input.displayName.trim(), isActive: true,
      organisationKey: org.key, organisationName: org.name, timeZone: input.timeZone ?? org.timeZone,
      roleKey: role.key, roleName: role.name, isManaging: role.isManaging, timeKept: role.permissions.includes("workday.own"),
      teams: [], skills: [], mayEdit: false,
    });
    return userId;
  },

  async setPersonRole(me, userId, roleKey) {
    const p = editable(me, userId);
    const role = MOCK_ROLES.find((r) => r.key === roleKey);
    if (!role) throw new CmaDbError("CMA02", "unknown role");
    if (role.isManaging && !me.permissions.includes("users.manage_all")) throw new CmaDbError("CMA06", "a managing role needs users.manage_all");
    seedPeople().set(userId, { ...p, roleKey: role.key, roleName: role.name, isManaging: role.isManaging, timeKept: p.isActive && role.permissions.includes("workday.own") });
  },

  async setPersonActive(me, userId, active) {
    const p = editable(me, userId);
    const role = MOCK_ROLES.find((r) => r.key === p.roleKey);
    seedPeople().set(userId, { ...p, isActive: active, timeKept: active && (role?.permissions.includes("workday.own") ?? false) });
  },

  async setPersonTeams(me, userId, teamKeys) {
    const p = editable(me, userId);
    for (const k of teamKeys) if (!MOCK_TEAMS.some((t) => t.key === k)) throw new CmaDbError("CMA02", "unknown team");
    seedPeople().set(userId, { ...p, teams: MOCK_TEAMS.filter((t) => teamKeys.includes(t.key)).map((t) => mockTeam(t.key)) });
  },

  async setPersonSkills(me, userId, skills: SkillInput[]) {
    const p = editable(me, userId);
    if (!me.permissions.includes("skills.manage")) throw new CmaDbError("CMA06", "not permitted");
    const next = skills.map((x) => {
      const s = MOCK_SKILLS.find((k) => k.key === x.key);
      if (!s) throw new CmaDbError("CMA02", "unknown skill");
      const scaled = s.levels.length > 0;
      if (scaled && (x.level === undefined || !s.levels.some((l) => l.level === x.level))) throw new CmaDbError("CMA04", "level outside the scale");
      if (!scaled && x.level !== undefined) throw new CmaDbError("CMA04", "a binary skill takes no level");
      return mockSkill(s.key, scaled ? x.level! : null);
    });
    const order = (k: DirectoryPerson["skills"][number]) => MOCK_SKILLS.findIndex((s) => s.key === k.key);
    seedPeople().set(userId, { ...p, skills: next.sort((a, b) => order(a) - order(b)) });
  },

  // Roster (migration 0005): the cheap rules of the functions hold here too; the database proves the real ones
  async getRosterWeek(me, weekStart, teamKey): Promise<RosterWeek> {
    assertRosterManage(me);
    if (teamKey && !MOCK_TEAMS.some((t) => t.key === teamKey)) throw new CmaDbError("CMA02", "unknown team");
    const w = rosterWeekOf(teamKey, weekStart);
    const people = rosterPeopleOf(teamKey);
    const entries = [...w.cells.values()].filter((e) => people.some((p) => p.userId === e.userId));
    const workTypes = MOCK_SKILLS.filter((s) => s.dimension === "work_type" && s.isActive);
    const coverage = [] as RosterWeek["coverage"];
    for (let i = 0; i < 7; i++) {
      const date = addDays(weekStart, i);
      for (const skill of workTypes) {
        const names = people
          .filter((p) => p.skills.some((k) => k.key === skill.key) && entries.some((e) => e.userId === p.userId && e.date === date && e.kind === "shift"))
          .map((p) => p.displayName);
        if (names.length > 0) coverage.push({ date, skillKey: skill.key, skillName: skill.name, plannedPeople: names.length, peopleNames: names, target: skill.key === workTypes[0]?.key ? 2 : null });
      }
    }
    return {
      header: rosterHeaderOf(w),
      people: people.map((p) => ({
        userId: p.userId, displayName: p.displayName, organisationName: p.organisationName, timeZone: p.timeZone,
        teamKeys: p.teams.map((t) => t.key), workTypeKeys: p.skills.filter((k) => k.dimension === "work_type").map((k) => k.key),
      })),
      entries,
      coverage,
    };
  },

  async listRosterWeeks(me, teamKey, range): Promise<RosterWeekSummary[]> {
    assertRosterManage(me);
    return [...seedRosters().values()]
      .filter((w) => w.teamKey === teamKey && w.weekStart >= startOfWeek(range.from) && w.weekStart <= range.to && (w.version > 0 || w.cells.size > 0))
      .sort((a, b) => a.weekStart.localeCompare(b.weekStart))
      .map((w) => ({
        weekStart: w.weekStart, status: w.version > 0 ? "published" : "draft", version: w.version, publishedAt: w.publishedAt,
        entryCount: w.cells.size, shiftCount: [...w.cells.values()].filter((e) => e.kind === "shift").length,
      }));
  },

  // ---- Configuration (migration 0005a): the same refusals as the database functions ----

  // Invitations (0008l): the cheap rules of the functions hold here too; the database proves the real ones
  async listInvitations(me): Promise<Invitation[]> {
    assertManage(me);
    const all = me.permissions.includes("users.manage_all");
    return seedInvitations()
      .filter((i) => i.tenantId === me.tenantId && (all || !MOCK_ROLES.find((r) => r.key === i.roleKey)?.isManaging))
      .map(({ tenantId: _t, tokenHash: _h, createdBy: _c, ...rest }) => ({ ...rest, state: mockInvitationState({ tenantId: _t, tokenHash: _h, createdBy: _c, ...rest }) }))
      .sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  },

  async createInvitation(me, input): Promise<InvitationLink> {
    assertManage(me);
    const role = invitableRole(me, input.roleKey);
    const org = MOCK_ORGANISATIONS.find((o) => o.key === input.organisationKey);
    if (!org) throw new CmaDbError("CMA02", "unknown employer");
    const teams = input.teamKeys.map((k) => {
      if (!MOCK_TEAMS.some((t) => t.key === k)) throw new CmaDbError("CMA02", "unknown team");
      return mockTeam(k);
    });
    if (input.skills.length > 0 && !me.permissions.includes("skills.manage")) throw new CmaDbError("CMA06", "skills need skills.manage");
    const skills = input.skills.map((x) => {
      const s = MOCK_SKILLS.find((k) => k.key === x.key);
      if (!s) throw new CmaDbError("CMA02", "unknown skill");
      if (s.levels.length > 0 ? !s.levels.some((l) => l.level === x.level) : x.level !== undefined) throw new CmaDbError("CMA04", "level outside the scale");
      return mockSkill(x.key, x.level ?? null);
    });
    const email = input.email.trim().toLowerCase();
    assertInvitationAllowed(me, email);
    if (seedInvitations().some((i) => i.tenantId === me.tenantId && i.email === email && !i.acceptedAt && !i.revokedAt)) {
      throw new CmaDbError("CMA03", "a pending invitation for this address");
    }
    const days = Number(mockSetting("auth.invitation_valid_days")) || 7;
    const i: MockInvitation = {
      invitationId: crypto.randomUUID(), tenantId: me.tenantId, tokenHash: "", email, displayName: input.displayName.trim(), locale: input.locale,
      roleKey: role.key, roleName: role.name, organisationKey: org.key, organisationName: org.name, teams, skills,
      createdAt: new Date().toISOString(), createdBy: me.userId, createdByName: me.displayName,
      expiresAt: new Date(Date.now() + days * 86_400_000).toISOString(), renewedAt: null, acceptedAt: null, acceptedUserId: null,
      acceptedName: null, revokedAt: null, revokedByName: null,
    };
    seedInvitations().push(i);
    return newMockLink(i);
  },

  async renewInvitation(me, invitationId): Promise<InvitationLink> {
    const i = mockInvitationFor(me, invitationId);
    if (i.acceptedAt || i.revokedAt) throw new CmaDbError("CMA03", "accepted or revoked");
    assertInvitationAllowed(me, i.email);
    const days = Number(mockSetting("auth.invitation_valid_days")) || 7;
    Object.assign(i, { expiresAt: new Date(Date.now() + days * 86_400_000).toISOString(), renewedAt: new Date().toISOString(), createdBy: me.userId });
    return newMockLink(i);
  },

  async revokeInvitation(me, invitationId): Promise<void> {
    const i = mockInvitationFor(me, invitationId);
    if (i.acceptedAt) throw new CmaDbError("CMA03", "accepted");
    if (!i.revokedAt) Object.assign(i, { revokedAt: new Date().toISOString(), revokedByName: me.displayName });
  },

  async previewInvitation(identity, token): Promise<InvitationPreview> {
    const none: InvitationPreview = { result: "invalid", tenantName: null, roleName: null, invitedEmail: null, locale: null, expiresAt: null };
    const i = INVITE_TOKEN_RE.test(token) ? seedInvitations().find((x) => x.tokenHash === inviteHash(token)) : undefined;
    if (!i || i.revokedAt) return none;
    const tenantName = i.tenantId === MOCK_TENANT_2 ? "Pulse4all invest (test)" : MOCK_PRINCIPAL.tenantName;
    const principal = await mockData.findPrincipal(identity);
    if (principal?.tenantId === i.tenantId) return { ...none, result: "already_member", tenantName, locale: i.locale };
    if (i.acceptedAt) return none;
    // a sign-in that works in the other fictional tenant (no tenant picker yet), as cma.invitation_other_tenant
    if (principal) return { ...none, result: "other_tenant", tenantName, locale: i.locale };
    if (Date.parse(i.expiresAt) <= Date.now()) return { ...none, result: "expired", tenantName, locale: i.locale, expiresAt: i.expiresAt };
    if (identity.email.trim().toLowerCase() !== i.email) {
      return { result: "wrong_account", tenantName, roleName: i.roleName, invitedEmail: i.email, locale: i.locale, expiresAt: i.expiresAt };
    }
    return { result: "open", tenantName, roleName: i.roleName, invitedEmail: i.email, locale: i.locale, expiresAt: i.expiresAt };
  },

  async acceptInvitation(identity, token): Promise<InvitationAcceptResult> {
    const preview = await mockData.previewInvitation(identity, token);
    if (preview.result !== "open") return preview.result;
    const i = seedInvitations().find((x) => x.tokenHash === inviteHash(token))!;
    const role = MOCK_ROLES.find((r) => r.key === i.roleKey)!;
    const org = MOCK_ORGANISATIONS.find((o) => o.key === i.organisationKey)!;
    const userId = crypto.randomUUID();
    const principal: Principal = {
      ...MOCK_PRINCIPAL, tenantId: i.tenantId, tenantName: preview.tenantName ?? MOCK_PRINCIPAL.tenantName, userId, displayName: i.displayName,
      organisationName: org.name, roleKey: role.key, permissions: [...role.permissions],
      timeZone: org.timeZone,
    };
    (state.invitees ??= new Map()).set(inviteeKey(identity.provider, identity.subject), principal);
    if (i.tenantId === MOCK_PRINCIPAL.tenantId) {
      seedPeople().set(userId, {
        userId, email: i.email, displayName: i.displayName, isActive: true, organisationKey: org.key, organisationName: org.name,
        timeZone: org.timeZone, roleKey: role.key, roleName: role.name, isManaging: role.isManaging, timeKept: role.permissions.includes("workday.own"),
        teams: i.teams, skills: i.skills, mayEdit: false,
      });
    }
    Object.assign(i, { acceptedAt: new Date().toISOString(), acceptedUserId: userId, acceptedName: i.displayName });
    return "accepted";
  },

  async listConfigStatuses(me) {
    assertConfigure(me);
    return seedConfig().statuses.map((x) => ({ ...x }));
  },

  async upsertConfigStatus(me, input) {
    assertConfigure(me);
    if (!/^[a-z0-9_]+$/.test(input.key)) throw new CmaDbError("CMA04", "bad key");
    const c = seedConfig();
    const cur = c.statuses.find((x) => x.key === input.key);
    if (!cur) {
      c.statuses.push({ ...input, isDefault: false, isActive: true, usageCount: 0 });
      return;
    }
    const flagsChange = cur.isWorking !== input.isWorking || cur.isProductive !== input.isProductive || cur.isPaid !== input.isPaid || cur.isBillable !== input.isBillable;
    if (flagsChange && cur.usageCount > 0) throw new CmaDbError("CMA03", "flags frozen");
    if (cur.isDefault && !input.isWorking) throw new CmaDbError("CMA03", "default must work");
    Object.assign(cur, input, { isActive: true });
  },

  async setDefaultStatus(me, key) {
    assertConfigure(me);
    const c = seedConfig();
    const s = c.statuses.find((x) => x.key === key);
    if (!s) throw new CmaDbError("CMA02", "unknown status");
    if (!s.isActive || !s.isWorking) throw new CmaDbError("CMA03", "default must be an active working status");
    for (const x of c.statuses) x.isDefault = x === s;
  },

  async retireStatus(me, key) {
    assertConfigure(me);
    const c = seedConfig();
    const s = c.statuses.find((x) => x.key === key);
    if (!s) throw new CmaDbError("CMA02", "unknown status");
    if (!s.isActive) return;
    if (s.isDefault) throw new CmaDbError("CMA03", "the default cannot be retired");
    if (s.isWorking && !c.statuses.some((x) => x !== s && x.isActive && x.isWorking)) throw new CmaDbError("CMA03", "the last working status");
    s.isActive = false;
  },

  async listConfigAppLinks(me) {
    assertConfigure(me);
    return seedConfig().links.map((x) => ({ ...x }));
  },

  async upsertAppLink(me, input) {
    assertConfigure(me);
    if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(input.key) || !/^https:\/\/[^\s]+$/.test(input.address)) throw new CmaDbError("CMA04", "bad link");
    if (input.permissionKey && !MOCK_PERMISSIONS.some((p) => p.key === input.permissionKey)) throw new CmaDbError("CMA02", "unknown permission");
    const c = seedConfig();
    const cur = c.links.find((x) => x.key === input.key);
    if (cur) Object.assign(cur, input, { isActive: true });
    else c.links.push({ ...input, isActive: true });
  },

  async retireAppLink(me, key) {
    assertConfigure(me);
    const l = seedConfig().links.find((x) => x.key === key);
    if (!l) throw new CmaDbError("CMA02", "unknown link");
    l.isActive = false;
  },

  async listPermissions(me) {
    assertConfigure(me);
    return MOCK_PERMISSIONS;
  },

  async upsertAbsenceType(me, input) {
    assertConfigure(me);
    const c = seedConfig();
    const cur = c.absences.find((x) => x.key === input.key);
    if (cur) Object.assign(cur, input, { isActive: true });
    else c.absences.push({ ...input, isActive: true });
  },

  async retireAbsenceType(me, key) {
    assertConfigure(me);
    const a = seedConfig().absences.find((x) => x.key === key);
    if (!a) throw new CmaDbError("CMA02", "unknown absence type");
    a.isActive = false;
  },

  async listCoverageTargets(me) {
    assertConfigure(me);
    return seedConfig().targets.map((x) => ({ ...x }));
  },

  async setCoverageTarget(me, teamKey, skillKey, weekday, minCount) {
    assertRosterManage(me);
    const c = seedConfig();
    if (!c.teams.some((t) => t.key === teamKey)) throw new CmaDbError("CMA04", "unknown team");
    if (!c.skills.some((s) => s.key === skillKey && s.dimension === "work_type" && s.isActive)) throw new CmaDbError("CMA02", "unknown work type");
    if (weekday < 1 || weekday > 7) throw new CmaDbError("CMA04", "weekday");
    c.targets = c.targets.filter((x) => !(x.teamKey === teamKey && x.skillKey === skillKey && x.weekday === weekday));
    if (minCount && minCount > 0) c.targets.push({ teamKey, skillKey, weekday, minCount });
  },

  async upsertTeam(me, input) {
    assertConfigure(me);
    const c = seedConfig();
    const cur = c.teams.find((t) => t.key === input.key);
    if (cur) Object.assign(cur, input);
    else c.teams.push({ ...input, memberCount: 0 });
  },

  async dissolveTeam(me, key) {
    assertConfigure(me);
    const c = seedConfig();
    if (!c.teams.some((t) => t.key === key)) throw new CmaDbError("CMA02", "unknown team");
    c.teams = c.teams.filter((t) => t.key !== key);
  },

  async upsertSkill(me, input, active) {
    assertConfigure(me);
    const c = seedConfig();
    const cur = c.skills.find((x) => x.key === input.key && x.dimension === input.dimension);
    if (cur) Object.assign(cur, { name: input.name, sortOrder: input.sortOrder, isActive: active });
    else c.skills.push({ ...input, isActive: active, levels: c.skills.find((x) => x.dimension === input.dimension)?.levels ?? [] });
  },

  async setSkillLevels(me, dimension, levels) {
    assertConfigure(me);
    const c = seedConfig();
    for (const x of c.skills) if (x.dimension === dimension) x.levels = levels.map((l) => ({ ...l }));
  },

  async setTenantSetting(me, key, value) {
    assertConfigure(me);
    const c = seedConfig();
    const cur = c.settings.find((x) => x.key === key);
    const fallback = MOCK_SETTING_DEFAULTS[key];
    if (!cur && fallback === undefined) throw new CmaDbError("CMA02", "unknown setting");
    const next: TenantSetting = value === null
      ? { key, value: fallback ?? cur!.value, isDefault: true }
      : { key, value, isDefault: value === fallback };
    if (cur) Object.assign(cur, next);
    else c.settings.push(next);
    return { ...next };
  },

  async listAbsenceTypes() {
    return (state.config ? state.config.absences : MOCK_ABSENCES).map((a) => ({ ...a }));
  },

  async setRosterEntry(me, weekStart, teamKey, userId, date, cell): Promise<RosterEntry | null> {
    assertRosterManage(me);
    const person = seedPeople().get(userId);
    if (!person) throw new CmaDbError("CMA02", "unknown person");
    if (date < weekStart || date > addDays(weekStart, 6)) throw new CmaDbError("CMA04", "date outside the week");
    if (!rosterPeopleOf(teamKey).some((p) => p.userId === userId)) throw new CmaDbError("CMA04", "person not on this roster");
    if (date < dateKeyInZone(new Date(), person.timeZone)) throw new CmaDbError("CMA04", "the past is not planned");
    if (cell.kind === "shift" && (cell.end <= cell.start || cell.start === "24:00")) throw new CmaDbError("CMA04", "a shift ends after it starts, within the day");
    for (const other of seedRosters().values()) {
      if (other.weekStart === weekStart && other.teamKey !== teamKey && other.cells.has(`${userId}:${date}`)) {
        throw new CmaDbError("CMA03", "already planned on another roster that day");
      }
    }
    const w = rosterWeekOf(teamKey, weekStart);
    const entry = mockEntry(userId, date, cell, me.displayName);
    if (entry) w.cells.set(`${userId}:${date}`, entry);
    else w.cells.delete(`${userId}:${date}`);
    return entry;
  },

  async publishRoster(me, weekStart, teamKey): Promise<RosterWeekHeader> {
    assertRosterManage(me);
    const w = rosterWeekOf(teamKey, weekStart);
    w.version += 1;
    w.publishedAt = new Date().toISOString();
    w.publishedByName = me.displayName;
    w.published = new Map([...w.cells].map(([k, e]) => [k, { ...e }]));
    return rosterHeaderOf(w);
  },

  async copyRosterWeek(me, fromWeekStart, toWeekStart, teamKey): Promise<number> {
    assertRosterManage(me);
    const from = rosterWeekOf(teamKey, fromWeekStart);
    const to = rosterWeekOf(teamKey, toWeekStart);
    const people = rosterPeopleOf(teamKey);
    let n = 0;
    for (const e of from.cells.values()) {
      const person = people.find((p) => p.userId === e.userId);
      if (!person) continue;
      const offset = Math.round((Date.parse(e.date) - Date.parse(fromWeekStart)) / 86_400_000);
      const date = addDays(toWeekStart, offset);
      if (date < dateKeyInZone(new Date(), person.timeZone)) continue;
      to.cells.set(`${e.userId}:${date}`, { ...e, entryId: crypto.randomUUID(), date, recordedAt: new Date().toISOString(), recordedByName: me.displayName });
      n += 1;
    }
    return n;
  },

  async getMyRoster(me, range): Promise<MyRosterDay[]> {
    if (!me.permissions.includes("roster.view")) throw new CmaDbError("CMA06", "not permitted");
    const out: MyRosterDay[] = [];
    for (let d = range.from; d <= range.to; d = addDays(d, 1)) {
      const found = publishedCellFor(me.userId, d);
      const e = found?.entry ?? null;
      const team = found?.week.teamKey ? MOCK_TEAMS.find((t) => t.key === found.week.teamKey) : null;
      out.push({
        date: d, isPublished: found !== null, kind: e?.kind ?? null, start: e?.start ?? null, end: e?.end ?? null,
        absenceKey: e?.absenceKey ?? null, absenceName: e?.absenceName ?? null, note: e?.note ?? null,
        teamName: found ? team?.name ?? null : null, publishedAt: found?.week.publishedAt ?? null,
      });
    }
    return out;
  },

  async getRosterToday(me): Promise<TodayShift[]> {
    assertLive(me);
    return [...seedPeople().values()].filter((p) => p.isActive && p.timeKept).map((p) => {
      const date = dateKeyInZone(new Date(), p.timeZone);
      const found = publishedCellFor(p.userId, date);
      const e = found?.entry ?? null;
      return { userId: p.userId, date, isPublished: found !== null, kind: e?.kind ?? null, start: e?.start ?? null, end: e?.end ?? null, absenceName: e?.absenceName ?? null };
    });
  },

  async getMyProfile(me): Promise<MyProfile> {
    // The seed's own entry when there is one (the mock principal is), else the principal alone
    const p = seedPeople().get(me.userId);
    return {
      userId: me.userId, email: p?.email ?? "", displayName: p?.displayName ?? me.displayName,
      organisationName: p?.organisationName ?? me.organisationName, timeZone: p?.timeZone ?? me.timeZone,
      roleName: p?.roleName ?? MOCK_ROLES.find((r) => r.key === me.roleKey)?.name ?? null, timeKept: p?.timeKept ?? me.permissions.includes("workday.own"),
      teams: p?.teams ?? [], skills: p?.skills ?? [],
    };
  },

  async listMyMessages(me, since, limit): Promise<MyMessages> {
    const now = new Date().toISOString();
    seedMessages(me, now);
    maybeSyntheticAlert(me, now);
    const own = ownMessages(me, now);
    const listed = own.filter(({ m }) => since === null || m.createdAt > since).slice(0, limit);
    for (const { d } of listed) d.deliveredAt ??= now;
    return { messages: listed.map(({ m, d }) => toMyMessage(m, d)), unreadCount: own.filter(({ d }) => d.readAt === null).length };
  },

  async markMessagesRead(me, ids): Promise<number> {
    const now = new Date().toISOString();
    let n = 0;
    for (const id of ids) {
      const m = state.messages.get(id);
      const d = m && !m.withdrawnAt ? deliveryOf(m, me) : null;
      if (!d || d.readAt !== null) continue;
      d.deliveredAt ??= now;
      d.readAt = now;
      n += 1;
    }
    return n;
  },

  async acknowledgeMessage(me, id): Promise<void> {
    const now = new Date().toISOString();
    const m = state.messages.get(id);
    const d = m && !m.withdrawnAt ? deliveryOf(m, me) : null;
    if (!d) throw new CmaDbError("CMA02", "not found");
    if (d.acknowledgedAt !== null) return;
    d.deliveredAt ??= now;
    d.readAt ??= now;
    d.acknowledgedAt = now;
  },

  async sendMessage(me, input): Promise<SentMessage> {
    assertSend(me);
    const now = new Date().toISOString();
    seedMessages(me, now);
    const { everyone, users } = resolveTarget(me, input.target, now);
    const m = addMockMessage({ tenantId: me.tenantId, kind: "announcement", urgency: input.urgency, title: input.title.trim(), body: input.body,
      ref: null, createdAt: now, expiresAt: null, everyone, users, byRule: false });
    for (const id of users) m.deliveries.set(id, { deliveredAt: null, readAt: null, acknowledgedAt: null });
    return { id: m.id, recipients: m.deliveries.size };
  },

  async getMessageStats(me, range): Promise<MessageStat[]> {
    if (!me.permissions.includes("messages.send") && !me.permissions.includes("performance.team")) throw new CmaDbError("CMA06", "not permitted");
    const now = new Date().toISOString();
    seedMessages(me, now);
    const out: MessageStat[] = [];
    for (const m of state.messages.values()) {
      if (m.tenantId !== me.tenantId) continue;
      const date = dateKeyInZone(m.createdAt, me.timeZone);
      if (date < range.from || date > range.to) continue;
      const ds = [...m.deliveries.values()];
      const reads = ds.filter((d) => d.readAt).map((d) => (Date.parse(d.readAt!) - Date.parse(m.createdAt)) / 1000).sort((a, b) => a - b);
      out.push({ id: m.id, kind: m.kind, urgency: m.urgency, title: m.title, ref: m.ref ? { system: m.ref.system, type: m.ref.type, id: m.ref.id } : null,
        byRule: m.byRule, createdAt: m.createdAt, recipients: ds.length, delivered: ds.filter((d) => d.deliveredAt).length,
        read: reads.length, acknowledged: ds.filter((d) => d.acknowledgedAt).length,
        medianSecondsToRead: reads.length ? Math.round(reads[Math.floor((reads.length - 1) / 2)]!) : null, withdrawnAt: m.withdrawnAt ?? null });
    }
    return out.sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  },

  async withdrawMessage(me, id) {
    if (!me.permissions.includes("messages.withdraw")) throw new CmaDbError("CMA06", "not permitted");
    const m = state.messages.get(id);
    if (!m || m.tenantId !== me.tenantId) throw new CmaDbError("CMA02", "not found");
    m.withdrawnAt ??= new Date().toISOString();
    return { withdrawnAt: m.withdrawnAt };
  },

  // ---- Sources, markets, alert rules (addition 0008e): the same refusals as the database functions ----

  async listSources(me) {
    assertConfigure(me);
    return seedIntakeConfig(me).sources.map(sourceRow);
  },

  async getSource(me, id) {
    const x = sourceOf(me, id);
    const { tenantId: _t, ...detail } = structuredClone(x);
    void _t;
    if (detail.reviewChannels.length > 0) {
      // the reviews held of each channel and its newest submission (cma.connection_catalogs), from the review fixture
      const held = mockReviewSources(me);
      detail.reviewChannels = detail.reviewChannels.map((ch) => {
        const own = held.filter((r) => r.channel === ch.channelId);
        return { ...ch, reviews: own.length, lastSubmittedAt: own.reduce<string | null>((m, r) => (m === null || r.submittedAt > m ? r.submittedAt : m), null) };
      });
    }
    if (x.connection.adapter !== MOCK_TEL_SYSTEM) return { ...detail, connection: sourceRow(x) };
    // the telephony connection's missed reasons and newest call id (addition 0008i), from the call fixture
    const { reasons, sampleCallId } = mockSourceReasons(me, Date.now());
    return { ...detail, connection: sourceRow(x), missedReasons: reasons, sampleIds: { ...detail.sampleIds, ...(sampleCallId ? { call: sampleCallId } : {}) } };
  },

  async setSourceConnection(me, id, input) {
    const x = sourceOf(me, id);
    if (input.kind !== undefined) {
      const held = heldKindsOf(x);
      if (held.length > 0 && !held.includes(input.kind)) throw new CmaDbError("CMA03", "the connection holds rows of another kind");
    }
    if (input.name !== undefined) x.connection.name = input.name.trim();
    if (input.isActive !== undefined) x.connection.isActive = input.isActive;
    if (input.kind !== undefined) x.connection.kind = input.kind;
  },

  async setSourceSettings(me, id, settings) {
    const x = sourceOf(me, id);
    if (settingsProblem(settings)) throw new CmaDbError("CMA04", "settings refused");
    x.connection.settings = { ...settings };
  },

  async setSourcePipeline(me, id, input) {
    const x = sourceOf(me, id);
    const p = x.pipelines.find((y) => y.recordType === input.recordType && y.pipelineId === input.pipelineId);
    if (input.isOrder && input.recordType !== "deal") throw new CmaDbError("CMA04", "only a deal pipeline can be an order pipeline");
    if (p) Object.assign(p, { isCounted: input.isCounted, isLead: input.isLead, ...(input.isOrder !== undefined ? { isOrder: input.isOrder } : {}) });
    else x.pipelines.push({ ...pipeline(input.recordType, input.pipelineId, input.pipelineId, input.isCounted, input.isLead, null, input.isOrder ?? false) });
  },

  async setSourceStageOutcome(me, id, input) {
    const x = sourceOf(me, id);
    const st = x.pipelines.find((p) => p.recordType === "deal" && p.pipelineId === input.pipelineId)?.stages.find((y) => y.stageId === input.stageId);
    if (!st) throw new CmaDbError("CMA02", "no such stage");
    Object.assign(st, { outcome: input.outcome === "none" ? null : input.outcome, outcomeSource: "person" });
  },

  async setSourceStageReadTimes(me, id, input) {
    const x = sourceOf(me, id);
    const st = x.pipelines.find((p) => p.recordType === "deal" && p.pipelineId === input.pipelineId)?.stages.find((y) => y.stageId === input.stageId);
    if (!st) throw new CmaDbError("CMA02", "no such stage");
    Object.assign(st, { readTimes: input.readTimes, readTimesSet: true });
  },

  async setSourceReasonField(me, id, input) {
    const x = sourceOf(me, id);
    const property = input.property?.trim() ?? "";
    const i = x.fields.findIndex((f) => f.entity === input.recordType && f.field === "reason");
    if (property === "") {
      if (i >= 0) x.fields.splice(i, 1);
      return;
    }
    // as cma.set_connection_field: a changed property loses its checked data type until the next sweep reads it; the mock's
    // sweep never comes, so a property named *_text stays refused and any other reads as an enumeration at once
    const sourceType = property.endsWith("_text") ? "string" : "enumeration";
    const f: SourceField = { entity: input.recordType, field: "reason", refSystem: null, slot: 1, property, sourceType, checkedAt: new Date().toISOString(),
      state: reasonStateOf(property, sourceType) };
    if (i >= 0) x.fields[i] = f;
    else x.fields.push(f);
  },

  async setSourceReasonDataQuality(me, id, input) {
    const x = sourceOf(me, id);
    const r = x.reasons.find((y) => y.recordType === input.recordType && y.value === input.value);
    if (!r) throw new CmaDbError("CMA02", "no such reason option");
    r.isDataQuality = input.isDataQuality;
  },

  async getRecordKinds(me): Promise<RecordKindConfig[]> {
    assertConfigure(me);
    const c = seedIntakeConfig(me);
    const key = mockSetting("reports.cancellation_kind");
    const crm = c.sources.find((x) => x.connection.adapter === "crmtest");
    return [...c.kinds].sort((a, b) => (a.status === b.status ? 0 : a.status === "active" ? -1 : 1) || a.sortOrder - b.sortOrder || a.key.localeCompare(b.key))
      .map((k) => ({
        ...k, isCancellationKind: k.key === key,
        rules: c.kindRules.filter((r) => r.kindKey === k.key).map((r) => ({
          connectionId: r.connectionId, pipelineId: r.pipelineId, category: r.category, isActive: r.isActive,
          pipelineLabel: crm?.pipelines.find((p) => p.recordType === k.recordType && p.pipelineId === r.pipelineId)?.label ?? null,
        })),
      }));
  },

  async setRecordKind(me, input) {
    assertConfigure(me);
    if (!/^[a-z][a-z0-9_-]{1,40}$/.test(input.key)) throw new CmaDbError("CMA04", "a kind's key is 2 to 41 lower-case characters");
    if (input.label.trim().length < 1 || input.label.trim().length > 80) throw new CmaDbError("CMA04", "a kind's label has 1 to 80 characters");
    if (input.sortOrder !== null && (input.sortOrder < 0 || input.sortOrder > 10000)) throw new CmaDbError("CMA04", "a sort order is 0 to 10000");
    const c = seedIntakeConfig(me);
    const k = c.kinds.find((x) => x.key === input.key);
    if (k && k.recordType !== input.recordType) throw new CmaDbError("CMA03", "a kind's record type stays");
    const status = input.isActive === null ? undefined : input.isActive ? "active" as const : "archived" as const;
    if (k) Object.assign(k, { label: input.label.trim(), sortOrder: input.sortOrder ?? k.sortOrder, ...(status ? { status } : {}) });
    else c.kinds.push({ key: input.key, label: input.label.trim(), recordType: input.recordType, status: status ?? "active", sortOrder: input.sortOrder ?? 100 });
  },

  async setRecordKindRule(me, id, input) {
    const x = sourceOf(me, id);
    const c = seedIntakeConfig(me);
    const k = c.kinds.find((y) => y.key === input.kindKey);
    if (!k) throw new CmaDbError("CMA02", "no such record kind");
    const pipelineId = input.pipelineId?.trim() || null;
    const category = input.category?.trim() || null;
    if (pipelineId === null && category === null) throw new CmaDbError("CMA04", "a rule needs a pipeline, a category value or both");
    if (pipelineId !== null && !x.pipelines.some((p) => p.recordType === k.recordType && p.pipelineId === pipelineId)) throw new CmaDbError("CMA02", "no such pipeline");
    const r = c.kindRules.find((y) => y.connectionId === id && y.kindKey === k.key && y.pipelineId === pipelineId && y.category === category);
    if (r) r.isActive = input.active;
    else if (input.active) c.kindRules.push({ connectionId: id, kindKey: k.key, pipelineId, category, isActive: true });
  },

  async setSourceForms(me, id, changes) {
    const x = sourceOf(me, id);
    const categories = seedIntakeConfig(me).categories;
    for (const c of changes) {   // all or nothing, as one transaction
      assertMockMarket(me, c.market);
      const f = x.forms.find((y) => y.formId === c.formId);
      if (c.isCounted && c.isPolled === false) throw new CmaDbError("CMA03", "a counted form is always polled; set it not counted first");
      if (c.category !== undefined && c.category !== null) {
        const k = categories.find((y) => y.code === c.category);
        if (!k) throw new CmaDbError("CMA02", `no form category ${c.category}`);
        if (!k.isActive && f?.category !== c.category) throw new CmaDbError("CMA04", `form category ${c.category} is switched off`);
      }
    }
    for (const c of changes) {
      const f = x.forms.find((y) => y.formId === c.formId);
      const isPolled = c.isCounted || (c.isPolled ?? f?.isPolled ?? c.isCounted);
      const category = c.category === undefined ? (f?.category ?? null) : c.category;
      if (f) Object.assign(f, { isCounted: c.isCounted, isPolled, category, leadSource: c.leadSource, market: c.market });
      else x.forms.push(form(c.formId, c.formId, c.isCounted, c.leadSource, c.market, { isPolled, category }));
    }
  },

  async getFormCategories(me): Promise<FormCategory[]> {
    assertAny(me, ["tenant.configure", "reports.view", "performance.team"]);
    return mockFormCategories(me);
  },

  async setFormCategory(me, input) {
    assertConfigure(me);
    if (!/^[a-z][a-z0-9_]{0,39}$/.test(input.code) || input.code === "none") throw new CmaDbError("CMA04", "a category code is lower-case letters, digits and _");
    if (input.name.trim().length < 1 || input.name.trim().length > 60) throw new CmaDbError("CMA04", "a category name has 1 to 60 characters");
    const list = seedIntakeConfig(me).categories;
    const k = list.find((y) => y.code === input.code);
    if (k) Object.assign(k, { name: input.name.trim(), sortOrder: input.sortOrder, isActive: input.isActive });
    else list.push({ code: input.code, name: input.name.trim(), sortOrder: input.sortOrder, isActive: input.isActive });
  },

  async setSourceCallOutcomes(me, id, changes) {
    const x = sourceOf(me, id);
    for (const c of changes) {
      const o = x.callOutcomes.find((y) => y.outcomeRef === c.outcomeRef);
      if (o) o.isConnected = c.isConnected;
      else x.callOutcomes.push(outcome(c.outcomeRef, c.outcomeRef, c.isConnected));
    }
  },

  async setSourceLine(me, id, input) {
    const x = sourceOf(me, id);
    assertMockMarket(me, input.market);
    const l = x.lines.find((y) => y.lineRef === input.lineRef);
    if (l) Object.assign(l, { market: input.market, isCounted: input.isCounted });
    else x.lines.push({ lineRef: input.lineRef, name: input.lineRef, digits: null, market: input.market, isCounted: input.isCounted, isActive: true } satisfies SourceLine);
  },

  async getSourceLineStoredCalls(me, id, lineRef) {
    assertAny(me, ["tenant.configure"]);
    const x = sourceOf(me, id);
    const line = x.lines.find((l) => l.lineRef === lineRef);
    if (!line) throw new CmaDbError("CMA02", "no such line");
    // a line that does not count stores no call (0008f); the fixture's calls of a counted line since the start date
    const calls = line.isCounted ? mockCalls(me, { from: mockStartDate(me), to: mockToday(me) }).filter((c) => c.connectionId === id && c.lineRef === lineRef) : [];
    const first = calls.map((c) => c.startedAt).sort()[0] ?? null;
    return { storedCalls: calls.length, firstStartedAt: first };
  },

  async setSourceTag(me, id, input) {
    const x = sourceOf(me, id);
    const t = x.tags.find((y) => y.tagRef === input.tagRef);
    if (t) t.isCounted = input.isCounted;
    else x.tags.push({ tagRef: input.tagRef, name: input.tagRef, isCounted: input.isCounted, meaning: null, isActive: true } satisfies SourceTag);
  },

  async setSourceTagMeaning(me, id, input) {
    const x = sourceOf(me, id);
    const t = x.tags.find((y) => y.tagRef === input.tagRef);
    if (t) t.meaning = input.meaning;
    else x.tags.push({ tagRef: input.tagRef, name: input.tagRef, isCounted: true, meaning: input.meaning, isActive: true } satisfies SourceTag);
  },

  async setSourceMissedReason(me, id, input) {
    const x = sourceOf(me, id);
    const kinds = x.connection.kind !== null ? [x.connection.kind] : heldKindsOf(x);
    if (kinds.length > 0 && !kinds.includes("telephony")) throw new CmaDbError("CMA04", "missed reasons belong to a telephony connection");
    const code = input.code.trim();
    const label = input.label.trim();
    if (code.length < 1 || code.length > 60 || label.length < 1 || label.length > 100) throw new CmaDbError("CMA04", "invalid missed reason");
    const list = mockReasons(me);
    const cur = list.find((r) => r.sourceSystem === x.connection.adapter && r.code === code);
    if (cur) Object.assign(cur, { label, countsInServiceLevel: input.countsInServiceLevel, needsCallback: input.needsCallback });
    else list.push({ sourceSystem: x.connection.adapter, code, label, countsInServiceLevel: input.countsInServiceLevel, needsCallback: input.needsCallback });
  },

  async setSourceStore(me, id, store: SourceStore) {
    const x = sourceOf(me, id);
    assertMockMarket(me, store.market);
    if (seedIntakeConfig(me).sources.some((c) => c !== x && c.store?.handle === store.handle)) throw new CmaDbError("CMA03", "the handle belongs to another store");
    x.store = { ...store };
  },

  async getMarkets(me) {
    assertConfigure(me);
    const c = seedIntakeConfig(me);
    return { markets: structuredClone(c.markets), hours: structuredClone(c.hours), holidays: structuredClone(c.holidays) };
  },

  async upsertMarket(me, input, active) {
    assertConfigure(me);
    if (input.code === "UK" || !/^[A-Z]{2}$/.test(input.code)) throw new CmaDbError("CMA04", "use GB");
    const c = seedIntakeConfig(me);
    const cur = c.markets.find((m) => m.code === input.code);
    const next: MarketConfig = { ...input, isActive: active, aliases: cur?.aliases ?? [] };
    if (cur) Object.assign(cur, next);
    else c.markets.push(next);
  },

  async setMarketAlias(me, alias, code) {
    assertConfigure(me);
    const c = seedIntakeConfig(me);
    const holder = c.markets.find((m) => m.aliases.includes(alias));
    if (code === null) {
      if (!holder) throw new CmaDbError("CMA02", "no such alias");
      holder.aliases = holder.aliases.filter((a) => a !== alias);
      return;
    }
    const target = c.markets.find((m) => m.code === code);
    if (!target) throw new CmaDbError("CMA02", "no such market");
    if (holder) holder.aliases = holder.aliases.filter((a) => a !== alias);
    target.aliases = [...target.aliases, alias].sort();
  },

  async setOfficeHours(me, market, days) {
    assertConfigure(me);
    assertMockMarket(me, market, true);
    const c = seedIntakeConfig(me);
    for (const { weekday, hours } of days) {
      c.hours = c.hours.filter((h) => !(h.market === market && h.weekday === weekday));
      if (hours !== "") c.hours.push({ market, weekday, hours });
    }
    c.hours.sort((a, b) => Number(a.market !== "*") - Number(b.market !== "*") || a.market.localeCompare(b.market) || a.weekday - b.weekday);
  },

  async setHoliday(me, market, day, name) {
    assertConfigure(me);
    assertMockMarket(me, market, true);
    const c = seedIntakeConfig(me);
    const cur = c.holidays.find((h) => h.market === market && h.day === day);
    if (name === null) {
      if (!cur) throw new CmaDbError("CMA02", "no such holiday");
      c.holidays = c.holidays.filter((h) => h !== cur);
    } else if (cur) cur.name = name;
    else c.holidays.push({ market, day, name });
  },

  async getAlertRules(me) {
    assertConfigure(me);
    const c = seedIntakeConfig(me);
    const pipelines = c.sources.filter((x) => x.connection.kind === "crm")
      .flatMap((x) => x.pipelines.map((p) => ({ connectionName: x.connection.name, recordType: p.recordType, pipelineId: p.pipelineId, label: p.label, isCounted: p.isCounted })));
    return { rules: structuredClone(c.rules), pipelines, defaultMaxAgeMinutes: 60, negativeMaxRating: Number(mockSetting("reviews.negative_max_rating")) };
  },

  async upsertAlertRule(me, input) {
    assertConfigure(me);
    const c = seedIntakeConfig(me);
    const name = input.name.trim();
    const cur = c.rules.find((r) => r.name === name);
    if (cur && cur.trigger !== input.trigger) throw new CmaDbError("CMA03", "a rule of the other trigger holds this name");
    if (input.trigger === "review_submitted" && input.maxRating !== null && !(input.maxRating >= 1 && input.maxRating <= 5)) {
      throw new CmaDbError("CMA04", "the highest rating is 1 to 5, or none for any rating");
    }
    // a review rule (addition 0008ze) is of record type review, without pipelines; the other triggers keep no highest rating
    const values = input.trigger === "review_submitted"
      ? { ...input, name, recordType: "review", pipelineIds: [] }
      : { ...input, name, pipelineIds: [...new Set(input.pipelineIds)].sort(), maxRating: null };
    if (cur) {
      Object.assign(cur, values);
      return cur.id;
    }
    const id = crypto.randomUUID();
    c.rules.push({ ...values, id, enabled: true, alerts30d: 0, lastAlertAt: null });
    return id;
  },

  async setAlertRuleEnabled(me, id, enabled) {
    assertConfigure(me);
    const r = seedIntakeConfig(me).rules.find((x) => x.id === id);
    if (!r) throw new CmaDbError("CMA02", "no such rule");
    r.enabled = enabled;
  },

  // ---- Linked accounts (addition 0008e): the directory's scope and the People rule ----

  async getLinkedAccounts(me) {
    assertManage(me);
    const c = seedIntakeConfig(me);
    const visible = new Set(directoryFor(me).map((p) => p.userId));
    const fromConnections = c.sources.filter((x) => x.connection.kind === "crm" || x.connection.kind === "telephony")
      .map((x) => ({ system: `${x.connection.adapter}_${x.connection.kind === "crm" ? "owner" : "user"}`, name: x.connection.name, active: x.connection.isActive }));
    const names = [...new Set([...fromConnections.map((x) => x.system), ...c.accounts.map((a) => a.system)])]
      .sort((a, b) => Number(!a.endsWith("_owner")) - Number(!b.endsWith("_owner")) || a.localeCompare(b));
    return {
      systems: names.map((system) => ({
        system, role: system.endsWith("_owner") ? "owner" as const : "user" as const,
        connections: fromConnections.filter((x) => x.system === system).map((x) => x.name).sort(),
        isActive: fromConnections.some((x) => x.system === system && x.active),
      })),
      accounts: c.accounts.filter((a) => visible.has(a.userId)).map((a) => ({ ...a })),
    };
  },

  async setLinkedAccount(me, userId, system, externalId) {
    assertManage(me);
    const p = directoryFor(me).find((x) => x.userId === userId);
    if (!p) {
      if (seedPeople().has(userId)) throw new CmaDbError("CMA06", "may not manage this person");
      throw new CmaDbError("CMA02", "person not found");
    }
    if (!p.mayEdit) throw new CmaDbError("CMA06", "may not edit this person");
    if (!/^[a-z0-9]+_(owner|user)$/.test(system)) throw new CmaDbError("CMA04", "system must read <system>_owner or <system>_user");
    const c = seedIntakeConfig(me);
    const cur = c.accounts.find((a) => a.userId === userId && a.system === system);
    if (externalId === null) {
      if (!cur) throw new CmaDbError("CMA02", "no such id");
      c.accounts = c.accounts.filter((a) => a !== cur);
      return;
    }
    if (c.accounts.some((a) => a.system === system && a.externalId === externalId && a.userId !== userId)) throw new CmaDbError("CMA03", "the id belongs to another person");
    if (cur) cur.externalId = externalId;
    else c.accounts.push({ userId, system, externalId });
  },

  async getSpeedToLeadRows(me, range): Promise<SpeedToLeadRow[]> {
    assertAny(me, ["reports.view", "performance.team"]);
    assertReportRange(range);
    return mockSpeedRows(me, range);
  },

  async getSpeedToLeadSummary(me, range, group) {
    assertAny(me, ["reports.view", "performance.team"]);
    assertReportRange(range);
    if (!["day", "market", "agent", "pipeline"].includes(group)) throw new CmaDbError("CMA04", "group by day, market, agent or pipeline");
    const names = new Map(TEAM.map((p) => [p.userId, p.displayName]));
    return { ...range, group, rows: groupSpeedToLead(mockSpeedRows(me, range), group, (id) => names.get(id) ?? null) };
  },

  async getIntake(me, range): Promise<Intake> {
    assertAny(me, ["reports.view", "performance.team"]);
    assertReportRange(range);
    const counts: IntakeCounts[] = [];
    for (const date of datesOf(range, me)) {
      for (const market of marketsOf(me)) {
        const row = mockIntakeCounts(me, date, market);
        if (row) counts.push(row);
      }
    }
    const connections = connectionsOf(me);
    return { ...range, connections, startDate: mockStartDate(me), rows: applyConnections(counts, connections) };
  },

  async getDataQuality(me): Promise<DataQualityCheck[]> {
    assertAny(me, ["reports.view", "tenant.configure"]);
    // The main tenant has something to fix in every check; the second tenant has nothing yet
    const main = me.tenantId === MOCK_PRINCIPAL.tenantId;
    // the reviews' checks (addition 0008ze) count the fixture: its unmapped channel, and the active markets without a counted channel
    const reviews: Record<string, number> = main ? reviewChecksOf(me) : {};
    return MOCK_CHECKS.filter(([key]) => main || !key.includes("review"))
      .map(([key, description], i) => ({ key, description, total: key in reviews ? reviews[key]! : main ? 1 + Math.floor(hashOf(key) * 40) + (i === 3 ? 3 : 0) : 0 }));
  },

  async getInboundService(me, range, group): Promise<InboundService> {
    assertAny(me, ["reports.view", "performance.team"]);
    assertReportRange(range);
    if (!["day", "market", "line", "hour"].includes(group)) throw new CmaDbError("CMA04", "group by day, market, line or hour");
    return mockInboundService(me, range, group);
  },

  async getInboundNow(me): Promise<InboundNow> {
    assertLive(me);
    return mockInboundNow(me);
  },

  async getCallsOverview(me, range, group, filter): Promise<CallsOverview> {
    assertCalls(me, range, filter, group, ["reports.view", "performance.team"]);
    return mockCallsOverview(me, range, group, filter);
  },

  async getCallsTagUse(me, range, group, filter): Promise<CallsTagUse> {
    assertCalls(me, range, filter, group, ["reports.view", "performance.team"]);
    const telephony = connectionsOf(me).telephony;
    return { ...range, group, filter, telephony, rows: callsTagUse(mockCallRecords(me, range, filter), range.from, range.to, group, mockCallTags(me)) };
  },

  async getCallsPerAgent(me, range, filter): Promise<CallsPerAgent> {
    assertCalls(me, range, filter, null, [PER_AGENT_PERMISSION]);
    const telephony = connectionsOf(me).telephony;
    const { rows, total } = callsPerPerson(mockCallRecords(me, range, filter), range.from, range.to, mockPersonOf(me));
    return { ...range, filter, telephony, connectedMinSeconds: mockConnectedMin(), conversationMinSeconds: mockConversationMin(), rows, total,
      ...mockCallsLists(me, range, filter) };
  },

  async getCallsPerAgentTags(me, range, filter): Promise<CallsPerAgentTags> {
    assertCalls(me, range, filter, null, [PER_AGENT_PERMISSION]);
    const telephony = connectionsOf(me).telephony;
    return { ...range, filter, telephony, rows: callsPerPersonTags(mockCallRecords(me, range, filter), range.from, range.to, mockPersonOf(me), mockCallTags(me)) };
  },

  async getFormsReport(me, range, group, filter): Promise<FormsReport> {
    assertForms(me, range, group, filter);
    const records = mockFormRecords(me);
    const all = formsFigures(records, range.from, range.to, group, filter);
    // the lists: the forms and markets with submissions in the period, without the filters
    const whole = formsFigures(records, range.from, range.to, "week", { market: null, category: null, form: null }).filter((r) => r.groupKey === null);
    // like for like, as the database: a period that reaches today against the same point in the previous one
    const prev = previousPeriod(range, mockToday(me));
    return {
      ...range, group, filter, forms: seedIntakeConfig(me).sources.some((x) => x.forms.length > 0),
      rows: all.filter((r) => r.groupKey !== null), totals: all.filter((r) => r.groupKey === null),
      previous: previousForms(records, prev, filter, new Date().toISOString()),
      previousFrom: prev.from, previousTo: prev.to, previousPartial: prev.partial, historyStart: formsHistoryStart(records),
      categories: mockFormCategories(me),
      formList: [...new Map(whole.map((r) => [r.formKey, r.formName])).entries()].map(([key, name]) => ({ key, name })).sort((a, b) => a.name.localeCompare(b.name)),
      markets: [...new Set(whole.map((r) => r.market))].sort((a, b) => (a === "unknown" ? 1 : b === "unknown" ? -1 : a.localeCompare(b))),
    };
  },

  async getFormsAnswers(me, range, filter, field, value): Promise<FormsAnswers> {
    assertForms(me, range, "day", filter);
    if (parseAnswerFilter(field ?? "", value ?? "").problem) throw new CmaDbError("CMA04", "invalid field or value");
    const records = mockFormRecords(me);
    const prev = previousPeriod(range, mockToday(me));
    return {
      ...range, filter, field, value,
      rows: [...formsAnswersOf(records, range.from, range.to, filter, field, value, "current"),
        ...formsAnswersOf(records, prev.from, prev.to, filter, field, value, "previous", prev.partial ? new Date().toISOString() : null)],
    };
  },

  async getCrmRecordsPerDay(me, range): Promise<CrmRecordsDay[]> {
    assertPerformance(me);
    assertReportRange(range);
    // The deals and tickets of the intake fixture, split over the two fictional pipelines
    const out: CrmRecordsDay[] = [];
    for (const date of datesOf(range, me)) {
      for (const market of marketsOf(me)) {
        const row = mockIntakeCounts(me, date, market);
        if (!row) continue;
        const m = market === "unknown" ? null : market;
        if (row.dealsCreated) out.push({ date, recordType: "deal", market: m, pipelineId: MOCK_PIPELINES[0]!.id, pipelineLabel: MOCK_PIPELINES[0]!.label, records: row.dealsCreated, closedNow: Math.min(row.dealsCreated, row.dealsClosed) });
        if (row.ticketsCreated) out.push({ date, recordType: "ticket", market: m, pipelineId: "p-service", pipelineLabel: "Service (test)", records: row.ticketsCreated, closedNow: Math.min(row.ticketsCreated, row.ticketsClosed) });
      }
    }
    return out;
  },

  // ---- Follow-up (addition 0008o): the same permission checks as the database functions, over the fixture. Since
  // addition 0008s the database reads a snapshot computed once a minute; the mock computes on every read, so its
  // figures are always "now" (computedAt is the read's own time)
  async getFollowUpPage(me, filter, callbacks): Promise<FollowUpPage & FollowUpCallbacks> {
    assertAny(me, [...FOLLOW_UP_PERMISSIONS]);
    const now = Date.now();
    const { leads, tickets, tasks } = mockFollowUpRows(me, now);
    const num = (key: string) => (/^\d+$/.test(mockSetting(key)) ? Number(mockSetting(key)) : null);
    const page = followUpPage(leads, tickets, tasks, filter, {
      rows: listRowsOf(mockSetting("follow_up.list_rows")), canByOwner: me.permissions.includes(FOLLOW_UP_BY_OWNER_PERMISSION),
      computedAt: new Date(now).toISOString(), durationMs: 0,
      targetMinutes: num("speed_to_lead.target_minutes"), warningPct: num("tickets.sla_warning_pct"),
    });
    // the callbacks kept with it, as the database reads them in the same statement; per person once a callback type counts
    const kept = callbacks ? await mockData.getCallbacksKept(me, callbacks.range) : null;
    const owners = callbacks?.perOwner ? await mockData.getCallbacksPerOwner(me, callbacks.range) : null;
    return { ...page, callbacks: kept, callbackOwners: kept?.connected && owners ? owners : null };
  },

  async getOpenLeads(me): Promise<FollowUpRowsAt<OpenLead>> {
    assertAny(me, [...FOLLOW_UP_PERMISSIONS]);
    const now = Date.now();
    return { rows: mockFollowUpRows(me, now).leads, computedAt: new Date(now).toISOString() };
  },

  async getOpenTickets(me): Promise<FollowUpRowsAt<OpenTicket>> {
    assertAny(me, [...FOLLOW_UP_PERMISSIONS]);
    const now = Date.now();
    return { rows: mockFollowUpRows(me, now).tickets, computedAt: new Date(now).toISOString() };
  },

  async getOpenTasks(me): Promise<FollowUpRowsAt<OpenTask>> {
    assertAny(me, [...FOLLOW_UP_PERMISSIONS]);
    const now = Date.now();
    return { rows: mockFollowUpRows(me, now).tasks, computedAt: new Date(now).toISOString() };
  },

  async getFollowUpSummary(me): Promise<FollowUpSummaryAt> {
    assertAny(me, [...FOLLOW_UP_SUMMARY_PERMISSIONS]);
    const now = Date.now();
    const { leads, tickets, tasks } = mockFollowUpRows(me, now);
    return { ...summarise(leads, tickets, tasks), computedAt: new Date(now).toISOString() };
  },

  async getFollowUpByOwner(me): Promise<FollowUpRowsAt<FollowUpOwner>> {
    assertAny(me, [FOLLOW_UP_BY_OWNER_PERMISSION]);
    const now = Date.now();
    const { leads, tickets, tasks } = mockFollowUpRows(me, now);
    return { rows: byOwner(leads, tickets, tasks), computedAt: new Date(now).toISOString() };
  },

  async getMyFollowUp(me): Promise<MyFollowUp> {
    assertAny(me, [...MY_FOLLOW_UP_PERMISSIONS]);
    const now = Date.now();
    const { leads, tickets, tasks } = mockFollowUpRows(me, now);
    return { leads: ownRows(leads, me.userId), tickets: ownRows(tickets, me.userId), tasks: ownRows(tasks, me.userId), computedAt: new Date(now).toISOString() };
  },

  // ---- System health (addition 0008r): invented runs around the current minute ------------------

  async getSystemHealthRuns(me): Promise<SystemHealthRun[]> {
    assertConfigure(me);
    const now = Date.now();
    const at = (secondsAgo: number) => new Date(now - secondsAgo * 1000).toISOString();
    const sources = seedIntakeConfig(me).sources;
    const crm = sources.find((x) => x.connection.kind === "crm")?.connection.id ?? null;
    const tel = sources.find((x) => x.connection.kind === "telephony")?.connection.id ?? null;
    const shop = sources.find((x) => x.connection.kind === "commerce")?.connection.id ?? null;
    const ok = (job: string, connectionId: string | null, startedAgo: number, took: number, counts: Record<string, number>, runs24h: number): SystemHealthRun => ({
      job, connectionId, lastStartedAt: at(startedAgo), lastFinishedAt: at(startedAgo - took), lastStatus: "succeeded", lastError: null, lastCounts: counts,
      lastSucceededAt: at(startedAgo - took), lastFailedAt: null, lastFailedError: null, runs24h, failed24h: 0,
    });
    const rows: SystemHealthRun[] = [
      // the heartbeat: the sweep's link_calls row, written a moment ago
      ok("link_calls", crm, 40, 1, { upserted: 2 }, 1440),
      ok("forms_poll", crm, 35, 2, { fetched: 3, upserted: 1 }, 1440),
      // the email poll recovered from one failure this morning
      { ...ok("email_poll", crm, 50, 3, { fetched: 12, upserted: 4 }, 1440), lastFailedAt: at(5 * 3600), lastFailedError: "rate_limited", failed24h: 1 },
      ok("reconcile", crm, 9.5 * 3600, 95, { fetched: 240, upserted: 7, stale: 2 }, 1),
      ok("close_forgotten_workdays", null, 25 * 60, 1, { closed: 0 }, 24),
      // the follow-up snapshot (0008s): refreshed every minute
      ok("refresh_follow_up", null, 20, 1, { rows: 27, leads: 5, tickets: 12, tasks: 10, duration_ms: 140, skipped: 0 }, 1440),
    ];
    if (tel) rows.push(ok("reconcile", tel, 9.5 * 3600, 40, { fetched: 80, upserted: 3 }, 1));
    if (shop) rows.push(ok("subscriptions_check", shop, 9.5 * 3600, 4, { fetched: 2 }, 1), ok("reconcile", shop, 9.4 * 3600, 60, { fetched: 30, upserted: 1 }, 1));
    return rows;
  },

  async getOutboxStatus(me): Promise<OutboxStatusRow[]> {
    assertConfigure(me);
    // Nothing enqueues an action since 0008h (README): an empty outbox is the normal state
    return [];
  },

  async probeDatabase(me): Promise<DatabaseProbe> {
    assertConfigure(me);
    return { roundTripMs: 1 };
  },

  async setSourcePipelineSla(me, id, input) {
    const x = sourceOf(me, id);
    if (input.slaMinutes !== null && (input.slaMinutes < 1 || input.slaMinutes > 100000)) throw new CmaDbError("CMA04", "an SLA is 1 to 100000 business minutes");
    const p = x.pipelines.find((y) => y.recordType === input.recordType && y.pipelineId === input.pipelineId);
    if (!p) throw new CmaDbError("CMA02", "no such pipeline on this connection");
    p.slaMinutes = input.slaMinutes;
  },

  async setSourceTaskStatus(me, id, input) {
    const x = sourceOf(me, id);
    if (x.connection.kind === "telephony" || x.connection.kind === "commerce") throw new CmaDbError("CMA04", "tasks belong to a CRM connection");
    const s = x.taskStatuses.find((y) => y.statusRef === input.statusRef);
    if (s) Object.assign(s, { label: input.label, isDone: input.isDone });
    else x.taskStatuses.push(taskStatus(input.statusRef, input.label, input.isDone, 0));
  },

  async setSourceTaskType(me, id, input) {
    const x = sourceOf(me, id);
    if (x.connection.kind === "telephony" || x.connection.kind === "commerce") throw new CmaDbError("CMA04", "tasks belong to a CRM connection");
    const y = x.taskTypes.find((z) => z.typeRef === input.typeRef);
    if (y) Object.assign(y, { label: input.label, isCallback: input.isCallback, isCounted: input.isCounted });
    else x.taskTypes.push(taskType(input.typeRef, input.label, input.isCallback, input.isCounted, 0, 0));
  },
  async getEmailReport(me, range, group, filter): Promise<EmailReport> {
    assertEmail(me, range, filter, group, ["reports.view", "performance.team"]);
    const c = mockEmailCatalog(me);
    const { threads, messages } = mockEmailStore(me);
    const emails = emailRecords(messages, threads, c);
    const openings = emailOpenings(messages, threads, c);
    const closes = emailCloses(threads, c);
    const e = emailInPeriod(emails, range.from, range.to, filter);
    const o = emailInPeriod(openings, range.from, range.to, filter);
    const x = emailInPeriod(closes, range.from, range.to, filter);
    // like for like, as the database: a period that reaches today against the same point in the previous one
    const prev = previousPeriod(range, mockToday(me));
    const now = new Date().toISOString();
    const list = mockSettingNumber(me, "follow_up.list_rows");
    const keyed = (rows: EmailWaitingRow[]) => rows;
    const crm = seedIntakeConfig(me).sources.find((s) => s.connection.kind === "crm")!;
    const waitingAll = emailWaiting(messages, threads.filter((t) =>
      (filter.inbox === null || `${t.connectionId}:${t.inboxId}` === filter.inbox) && (filter.account === null || `${t.connectionId}:${t.accountId}` === filter.account)), c, now)
      .filter((w) => filter.market === null || w.market === filter.market)
      .map((w) => ({ ...w, recordUrl: recordUrlPreview(String(crm.connection.settings.record_url_thread ?? ""), crm.connection.settings, crm.connection.accountId, w.threadId) }));
    const notResponding = mockNotResponding(me).filter((r) => filter.market === null || r.market === filter.market);
    return {
      ...range, group, filter, email: crm.inboxes.length > 0 || messages.length > 0,
      rows: emailGroups(e, o, x, group), total: emailFigures(e, o, x),
      previous: emailFigures(emailPrevious(emails, prev, filter, now), emailPrevious(openings, prev, filter, now), emailPrevious(closes, prev, filter, now)),
      previousFrom: prev.from, previousTo: prev.to, previousPartial: prev.partial,
      historyStart: emails.reduce<DateKey | null>((first, r) => (first === null || r.date < first ? r.date : first), null),
      byInbox: emailGroups(e, o, x, "inbox"), byAccount: emailGroups(e, o, x, "account"), byCategory: emailGroups(e, o, x, "category"), byMarket: emailGroups(e, o, x, "market"),
      receivedByInbox: emailSeries(e, group, "inbox"), receivedByAccount: emailSeries(e, group, "account"),
      replyTargetMinutes: c.replyTargetMinutes, noResponseDays: mockSettingNumber(me, "email.no_response_days"),
      waiting: { rows: keyed(waitingAll.slice(0, list)), total: waitingAll.length },
      notResponding: { rows: notResponding.slice(0, list), total: notResponding.length },
      ...mockEmailLists(emails, range.from, range.to),
    };
  },

  async getEmailPerAgent(me, range, filter): Promise<EmailPerAgent> {
    assertEmail(me, range, filter, null, [EMAIL_PER_AGENT_PERMISSION]);
    if (!me.perPerson.includes(EMAIL_PER_PERSON_KEY)) throw new CmaDbError("CMA06", "per-person figures for email are switched off for this tenant");
    const c = mockEmailCatalog(me);
    const { threads, messages } = mockEmailStore(me);
    const emails = emailRecords(messages, threads, c);
    const { rows, total } = emailPerPerson(emailInPeriod(emails, range.from, range.to, filter), emailInPeriod(emailOpenings(messages, threads, c), range.from, range.to, filter),
      emailInPeriod(emailCloses(threads, c), range.from, range.to, filter), mockEmailPersonOf(me));
    const crm = seedIntakeConfig(me).sources.find((s) => s.connection.kind === "crm")!;
    return { ...range, filter, email: crm.inboxes.length > 0 || messages.length > 0, rows, total, replyTargetMinutes: c.replyTargetMinutes,
      ...mockEmailLists(emails, range.from, range.to) };
  },

  async getFirstOrders(me, range, group, filter): Promise<FirstOrdersReport> {
    assertFirstOrders(me, range, filter, group, ["reports.view", "performance.team"]);
    const settings = mockAttribution();
    const records = firstOrderRecords(mockOrderDeals(me), settings, mockOrderPersonOf(me));
    const rows = firstOrdersInPeriod(records, range.from, range.to, filter);
    const prev = previousPeriod(range, mockToday(me));
    const previous = firstOrdersInPeriod(records, prev.from, prev.to, filter, prev.partial ? new Date().toISOString() : null);
    const firstDate = records.reduce<string | null>((m, r) => (m === null || r.date < m ? r.date : m), null);
    const phoneDate = records.filter((r) => r.phoneHashed).reduce<string | null>((m, r) => (m === null || r.date < m ? r.date : m), null);
    const intakeStart = addDays(mockToday(me), -200);
    const historyStart = firstDate === null ? null : [addDays(intakeStart, settings.windowDays), firstDate].sort()[1]!;
    return {
      ...range, group, filter, connected: me.tenantId !== MOCK_TENANT_2,
      rows: firstOrderGroups(rows, group), total: firstOrderFigures(rows), previous: firstOrderFigures(previous),
      previousFrom: prev.from, previousTo: prev.to, previousPartial: prev.partial,
      byLevel: firstOrderGroups(rows, "level"), byMarket: firstOrderGroups(rows, "market"),
      amounts: firstOrderAmounts(rows, false), amountsByMarket: firstOrderAmounts(rows, true),
      list: firstOrderList(rows, listRowsOf(mockSetting("follow_up.list_rows"))),
      historyStart, phoneStart: phoneDate, settings, markets: marketsOf(me),
    };
  },

  async getFirstOrdersExport(me, range, filter) {
    assertFirstOrders(me, range, filter, null, ["reports.view", "performance.team"]);
    const records = firstOrderRecords(mockOrderDeals(me), mockAttribution(), mockOrderPersonOf(me));
    return firstOrderList(firstOrdersInPeriod(records, range.from, range.to, filter), 500).rows;
  },

  async getOrdersPerPerson(me, range, filter): Promise<OrdersPerPerson> {
    assertFirstOrders(me, range, filter, null, [ORDERS_PER_PERSON_PERMISSION]);
    if (!me.perPerson.includes(ORDERS_PER_PERSON_KEY)) throw new CmaDbError("CMA06", "per-person figures for orders are switched off for this tenant");
    const settings = mockAttribution();
    const records = firstOrderRecords(mockOrderDeals(me), settings, mockOrderPersonOf(me));
    const { rows, total } = ordersPerPerson(firstOrdersInPeriod(records, range.from, range.to, filter), mockOrderName);
    return { ...range, filter, connected: me.tenantId !== MOCK_TENANT_2, rows, total, settings, markets: marketsOf(me) };
  },

  async getAttempts(me, range, group, filter): Promise<AttemptsReport> {
    assertAttempts(me, range, filter, group, ["reports.view", "performance.team"]);
    const settings = mockAttemptSettings();
    const records = mockAttemptRecords(me);
    const rows = attemptsInPeriod(records, range.from, range.to, filter, null, MOCK_TENANT_ZONE);
    const prev = previousPeriod(range, mockToday(me));
    const previous = attemptsInPeriod(records, prev.from, prev.to, filter, prev.partial ? new Date().toISOString() : null, MOCK_TENANT_ZONE);
    return {
      ...range, group, filter, current: attemptFigures(rows), previous: attemptFigures(previous),
      previousFrom: prev.from, previousTo: prev.to, previousPartial: prev.partial,
      buckets: attemptBuckets(rows, settings.maxBucket), outcomes: attemptOutcomes(rows), speedBuckets: attemptSpeedBuckets(rows, settings.speedBuckets),
      groups: attemptGroups(rows, group), sinceLast: sinceLastBuckets(rows, settings.sinceLastBuckets),
      list: attemptList(rows, listRowsOf(mockSetting("follow_up.list_rows"))),
      ...mockAttemptLists(attemptsInPeriod(records, range.from, range.to, MOCK_NO_ATTEMPT_FILTER, null, MOCK_TENANT_ZONE)),
      historyStart: mockAttemptsHistory(me, records), settings,
    };
  },

  async getAttemptsPerAgent(me, range, filter): Promise<AttemptsPerAgent> {
    assertAttempts(me, range, filter, null, [ATTEMPTS_PER_AGENT_PERMISSION]);
    if (!me.perPerson.includes(ATTEMPTS_PER_AGENT_KEY)) throw new CmaDbError("CMA06", "per-person figures for attempts are switched off for this tenant");
    const records = mockAttemptRecords(me);
    const period = attemptsInPeriod(records, range.from, range.to, MOCK_NO_ATTEMPT_FILTER, null, MOCK_TENANT_ZONE);
    const { rows, total } = attemptsPerPerson(attemptsInPeriod(records, range.from, range.to, filter, null, MOCK_TENANT_ZONE), mockOrderName);
    return { ...range, filter, rows, total, ...mockAttemptLists(period), historyStart: mockAttemptsHistory(me, records), settings: mockAttemptSettings() };
  },

  async getDealAttempts(me, dealId): Promise<DealAttempt[]> {
    assertAny(me, ["reports.view", "performance.team"]);
    const d = mockAttemptDeals(me).find((x) => x.dealId === dealId && x.isCounted && x.isLead && !x.isOrder);
    if (!d) throw new CmaDbError("CMA02", `no sales deal ${dealId}`);
    return dealAttempts(d, mockAttemptOptions(me), me.perPerson.includes(ATTEMPTS_PER_AGENT_KEY) && me.permissions.includes("performance.team"));
  },

  async getFunnel(me, range, filter): Promise<FunnelReport> {
    assertFunnel(me, range, filter, null, ["reports.view", "performance.team"]);
    const { deals, entries } = mockFunnelDeals(me);
    const prev = funnelPrevious(previousPeriod(range, mockToday(me)), new Date().toISOString());
    return funnelReport(deals, mockFunnelPipelines(me), mockFunnelOptions(me), range.from, range.to, filter, prev, entries);
  },

  async getLostReasons(me, range, group, filter): Promise<LostReasonsReport> {
    assertFunnel(me, range, filter, group, ["reports.view", "performance.team"]);
    const { state, options } = mockReasonsOf(me, "deal");
    const prev = funnelPrevious(previousPeriod(range, mockToday(me)), new Date().toISOString());
    return lostReasonsReport(mockFunnelDeals(me).deals, options, state, mockFunnelOptions(me), range.from, range.to, group, filter, prev,
      listRowsOf(mockSetting("follow_up.list_rows")));
  },

  async getCancellations(me, range, group, market): Promise<CancellationsReport> {
    assertFunnel(me, range, { market, pipeline: null, sourceChannel: null }, group, ["reports.view", "performance.team"]);
    const { kinds, rules } = mockKinds(me);
    const key = mockSetting("reports.cancellation_kind");
    const k = kinds.find((x) => x.key === key);
    const kind: RecordKind | null = k ? { key: k.key, label: k.label, recordType: k.recordType, status: k.status } : null;
    const { state, options } = mockReasonsOf(me, kind?.recordType ?? "ticket");
    const requests = cancellationRecords(mockTickets(me), kind, rules, mockStartDate(me), MOCK_TENANT_ZONE);
    const prev = funnelPrevious(previousPeriod(range, mockToday(me)), new Date().toISOString());
    return cancellationsReport(requests, kind, state, new Map(options.map((x) => [x.value, x.label])), mockStartDate(me), MOCK_TENANT_ZONE,
      range.from, range.to, group, market, prev, listRowsOf(mockSetting("follow_up.list_rows")));
  },

  async getReviews(me, range, group, market): Promise<ReviewsReport> {
    assertFunnel(me, range, { market, pipeline: null, sourceChannel: null }, group, ["reports.view", "performance.team"]);
    const c = seedIntakeConfig(me);
    const negative = Number(mockSetting("reviews.negative_max_rating"));
    const records = reviewRecords(mockReviewSources(me), MOCK_TENANT_ZONE, negative);
    const markets = c.markets.filter((m) => m.isActive).map((m) => ({ code: m.code, name: m.name, sortOrder: m.sortOrder }));
    const channels = c.sources.flatMap((x) => x.reviewChannels);
    const states = reviewMarketStates(markets, channels.map((ch) => ({ market: ch.market, isCounted: ch.isCounted, deleted: ch.deletedAt !== null,
      publishedReviews: mockReviewSources(me).filter((r) => r.channel === ch.channelId && r.isPublished).length })));
    const prev = funnelPrevious(previousPeriod(range, mockToday(me)), new Date().toISOString());
    return reviewsReport(records, { from: range.from, to: range.to, group, market, prev, zone: MOCK_TENANT_ZONE, negativeMaxRating: negative,
      isSetUp: channels.length > 0, markets, marketStates: states,
      filterMarkets: [...new Set(channels.filter((ch) => ch.isCounted).map((ch) => ch.market ?? "unknown"))]
        .sort((a, b) => (a === "unknown" ? 1 : 0) - (b === "unknown" ? 1 : 0) || a.localeCompare(b)) });
  },

  async setSourceReviewChannel(me, id, input) {
    const x = sourceOf(me, id);
    if (x.connection.kind !== "reviews" && x.reviewChannels.length === 0) throw new CmaDbError("CMA02", "no review channel in this connection");
    if (input.market !== null) assertMockMarket(me, input.market);
    const ch = x.reviewChannels.find((c) => c.channelId === input.channelId);
    if (!ch) throw new CmaDbError("CMA02", "no such review channel");
    Object.assign(ch, { market: input.market, isCounted: input.isCounted });
  },

  async getDealsPerPerson(me, range, filter): Promise<DealsPerPerson> {
    assertFunnel(me, range, filter, null, [DEALS_PER_PERSON_PERMISSION]);
    if (!me.perPerson.includes(DEALS_PER_PERSON_KEY)) throw new CmaDbError("CMA06", "per-person figures for deals are switched off for this tenant");
    const { deals } = mockFunnelDeals(me);
    const { rows, total } = dealsPerPerson(funnelFilter(deals, filter), range.from, range.to, mockOrderName);
    return { ...range, filter, rows, total, ...funnelLists(deals) };
  },


  async getCallbacksKept(me, range): Promise<CallbacksKept> {
    assertAny(me, [...CALLBACKS_PERMISSIONS]);
    assertReportRange(range);
    const records = mockCallbackRecords(me);
    const { weeks, total } = callbackFigures(callbacksInPeriod(records, range.from, range.to));
    // the previous period like for like: the same length before; while the period runs, its last day up to the time now
    const days = Math.round((Date.parse(`${range.to}T00:00:00Z`) - Date.parse(`${range.from}T00:00:00Z`)) / 86_400_000) + 1;
    const today = mockToday(me);
    const running = range.to >= today;
    const previous = callbackFigures(callbacksInPeriod(records, addDays(range.from, -days), addDays(running ? today : range.to, -days),
      running ? timeInZone(new Date().toISOString(), me.timeZone) : null)).total;
    return { ...range, connected: me.tenantId !== MOCK_TENANT_2, weeks, total, previous, windowMinutes: Number(mockSetting("tasks.callback_window_minutes")) };
  },

  async getCallbacksPerOwner(me, range): Promise<CallbackOwner[]> {
    assertAny(me, [CALLBACKS_PER_OWNER_PERMISSION]);
    assertReportRange(range);
    const accounts = seedIntakeConfig(me).accounts;
    const personOf = (ownerRef: string) => {
      const a = accounts.find((x) => x.system === "crmtest_owner" && x.externalId === ownerRef);
      return a ? { userId: a.userId, name: mockOrderName(a.userId) ?? a.userId } : null;
    };
    const { rows, total } = callbacksPerOwner(callbacksInPeriod(mockCallbackRecords(me), range.from, range.to), personOf);
    return [...rows, total];
  },

  async getJourneys(me): Promise<Journey[]> {
    assertAny(me, ["reports.view", "performance.team"]);
    if (me.tenantId === MOCK_TENANT_2) return [];
    return MOCK_JOURNEYS.filter((j) => j.status !== "archived")
      .sort((a, b) => a.sortOrder - b.sortOrder || a.name.localeCompare(b.name) || a.code.localeCompare(b.code))
      .map((j) => ({ code: j.code, name: j.name, summary: j.summary, market: j.market, status: j.status as JourneyStatus, designUrl: j.designUrl,
        prerequisites: j.prerequisites }));
  },

  async setSourceInbox(me, id, input) {
    const x = sourceOf(me, id);
    if (x.connection.kind === "telephony" || x.connection.kind === "commerce") throw new CmaDbError("CMA04", "email activity belongs to the CRM");
    if (input.market !== null && !seedIntakeConfig(me).markets.some((m) => m.code === input.market)) throw new CmaDbError("CMA02", "no such market");
    const y = x.inboxes.find((z) => z.inboxId === input.inboxId);
    if (y) Object.assign(y, { isCounted: input.isCounted, market: input.market });
    else x.inboxes.push({ inboxId: input.inboxId, name: input.inboxId, isCounted: input.isCounted, market: input.market, isActive: true });
  },

  async setSourceMailbox(me, id, input) {
    const x = sourceOf(me, id);
    if (x.connection.kind === "telephony" || x.connection.kind === "commerce") throw new CmaDbError("CMA04", "email activity belongs to the CRM");
    const label = input.label?.trim() || null;
    if (label !== null && (label.length > 80 || label.includes("@"))) throw new CmaDbError("CMA04", "a mailbox label has 1 to 80 characters and no @");
    if (input.market !== null && !seedIntakeConfig(me).markets.some((m) => m.code === input.market)) throw new CmaDbError("CMA02", "no such market");
    const y = x.mailboxes.find((z) => z.accountId === input.accountId);
    if (y) Object.assign(y, { label, isCounted: input.isCounted, market: input.market });
    else x.mailboxes.push({ accountId: input.accountId, name: input.accountId, label, inboxId: null, channelId: null, isCounted: input.isCounted, market: input.market, isActive: true });
  },

  async setSourceInboxChannel(me, id, input) {
    const x = sourceOf(me, id);
    if (x.connection.kind === "telephony" || x.connection.kind === "commerce") throw new CmaDbError("CMA04", "email activity belongs to the CRM");
    const y = x.inboxChannels.find((z) => z.channelId === input.channelId);
    if (y) y.isCounted = input.isCounted;
    else x.inboxChannels.push({ channelId: input.channelId, name: input.channelId, kind: "other", isCounted: input.isCounted, isActive: true });
  },
};
