/**
 * Mock data: in memory, fictional, resets on every cold start.
 * It cannot persist, and the UI says so (handover: a mock that cannot persist
 * must say so). Nothing here reaches a database.
 */
import { MOCK_IDENTITY, MOCK_PRINCIPAL, type Principal } from "@/lib/auth/identity";
import { CmaDbError } from "@/lib/db/client";
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
} from "./types";
import { recordUrlPreview, settingsProblem } from "@/lib/sources";
import {
  applyConnections, callRecords, callsPerPerson, callsPerPersonTags, callsTagUse, CALLS_GROUPS, groupCalls, groupInbound, groupSpeedToLead,
  inboundCalls, inboundFigures, missedReasonOf, parseCallsFilter, PER_AGENT_PERMISSION, previousPeriod, rangeProblem,
  type CallRecord, type CallTagFixture, type InboundLine, type IntakeCounts, type PersonOf, type TelephonyCallFixture,
} from "@/lib/reports";
import { missedCallbacks, type CallerCall } from "@/lib/live";

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
    const deals = Math.floor(hashOf(`${me.tenantId}:${date}:deals`) * 6);
    for (let i = 0; i < deals; i++) {
      const h = (k: string) => hashOf(`${me.tenantId}:${date}:${i}:${k}`);
      const market = markets[Math.floor(h("market") * markets.length)]!;
      const known = market !== "unknown";
      const pipeline = MOCK_PIPELINES[h("pipe") < 0.7 ? 0 : 1]!;
      const createdMs = Math.min(now - 60_000, localMs(date, `${String(8 + Math.floor(h("hour") * 10)).padStart(2, "0")}:${String(Math.floor(h("min") * 60)).padStart(2, "0")}`, me.timeZone));
      const createdAt = new Date(createdMs).toISOString();
      const recent = addDays(date, 3) >= today;
      const roll = h("status");
      const status: SpeedToLeadStatus = roll < 0.72 ? "called" : recent ? "not_called_open" : "not_called_closed";
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
// per line and day: unanswered ones, short ones under the threshold (not connected), the NL line's first
// call of each day at exactly the threshold (connected), and conversations of up to fifteen minutes.
// Tags from the test connection's catalog: Quote and Courtesy call count, Internal does not; some
// conversations are untagged and some carry only Internal. Telephony users 900001 to 900004 are linked
// to people of the fictional team (People, linked accounts), 900009 to nobody. The test line l-3 does not
// count: its calls are in the fixture and in no figure. Dates are not cut at intake.start_date (the
// database does not cut them either), so the previous equal period has calls too.

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
  return Number(list.find((x) => x.key === "telephony.connected_min_seconds")?.value ?? 10);
}

/** Every call of the fixture from a day before `from` to a day after `to` (up to now): both directions, both lines, and the test line that does not count */
function mockCalls(me: Principal, range: HoursRange): TelephonyCallFixture[] {
  if (!connectionsOf(me).telephony) return [];
  const now = Date.now();
  const last = range.to < mockToday(me) ? addDays(range.to, 1) : mockToday(me);
  const out: TelephonyCallFixture[] = [];
  for (let date = addDays(range.from, -1); date <= last; date = addDays(date, 1)) {
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
  return (c?.tags ?? []).map((t) => ({ connectionId: MOCK_TEL_CONNECTION, tagRef: t.tagRef, name: t.name, isCounted: t.isCounted }));
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

/** The fixture's calls of the range and the previous equal period, classified and filtered */
function mockCallRecords(me: Principal, range: HoursRange, filter: CallsFilter): CallRecord[] {
  return callRecords(mockCalls(me, { from: previousPeriod(range).from, to: range.to }), MOCK_INBOUND_LINES, me.timeZone, mockConnectedMin(), filter);
}

/** The markets and lines with calls in the period, the lines within the chosen market */
function mockCallsLists(me: Principal, range: HoursRange, filter: CallsFilter) {
  const all = callRecords(mockCalls(me, range), MOCK_INBOUND_LINES, me.timeZone, mockConnectedMin());
  return {
    markets: groupCalls(all, range.from, range.to, "market").rows.map((r) => r.groupKey),
    lines: groupCalls(all.filter((c) => filter.market === null || c.market === filter.market), range.from, range.to, "line").rows
      .map((r) => ({ key: r.groupKey, name: r.groupLabel })),
  };
}

function mockCallsOverview(me: Principal, range: HoursRange, group: CallsGroup, filter: CallsFilter): CallsOverview {
  const telephony = connectionsOf(me).telephony;
  const records = mockCallRecords(me, range, filter);
  const prev = previousPeriod(range);
  const { rows, total } = groupCalls(records, range.from, range.to, group);
  return {
    ...range, group, filter, telephony, connectedMinSeconds: mockConnectedMin(), rows, total,
    previous: groupCalls(records, prev.from, prev.to, group).total, previousFrom: prev.from, previousTo: prev.to,
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
  { key: "telephony.connected_min_seconds", value: "10", isDefault: true },
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
};
type MockState = {
  store: Map<Key, Workday>; teamStore: Map<string, Map<DateKey, TimeEvent[]>>; teamSeeded: boolean; people: Map<string, DirectoryPerson> | null;
  rosters: Map<string, MockRosterWeek> | null; config: MockConfig | null;
  messages: Map<string, MockMessage>; messagesSeeded: Set<string>; lastSyntheticAlertAt: number; messageSeq: number;
  /** Sources, markets, rules and linked accounts per tenant (addition 0008e), seeded on first use */
  intakeConfig?: Map<string, MockIntakeConfig>;
  /** The missed-reason catalog per tenant (addition 0008i), seeded on first use */
  missedReasons?: Map<string, MissedReason[]>;
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
  { key: "admin", name: "Administrator", isSystem: true, isManaging: true, permissions: ["workday.own", "workday.team", "roster.manage", "skills.manage", "users.manage_agents", "users.manage_all", "tenant.configure", "workday.export"] },
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
  "users.manage_agents", "users.manage_all", "tenant.configure",
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
  "workday.auto_close_grace_minutes": "120", "telephony.connected_min_seconds": "10",
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

/** The caller's own rows, newest first, as cma.my_messages lists them (expired ones left out) */
function ownMessages(me: Principal, now: Instant): { m: MockMessage; d: MockDelivery }[] {
  const out: { m: MockMessage; d: MockDelivery }[] = [];
  for (const m of state.messages.values()) {
    if (isExpired(m, now)) continue;
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
  markets: MarketConfig[];
  hours: OfficeHours[];
  holidays: MarketHoliday[];
  rules: AlertRule[];
  accounts: LinkedAccount[];
};

function mockSource(tenantId: string, n: number, adapter: string, name: string, accountId: string, kind: SourceKind | null, o: Partial<SourceDetail> = {}, settings: SourceConnection["settings"] = {}): MockSource {
  const connection: SourceConnection = {
    id: `00000000-0000-7000-8000-00000000c00${n}`, key: `k${n}${"0".repeat(20)}test`, adapter, name, accountId, kind, heldKinds: [], isActive: true,
    signingSecretName: `ingest-${adapter}-signing`,
    tokenSecretName: kind === "crm" || kind === "telephony" ? `ingest-${adapter}-token` : null,
    settings, events24h: 40 + n * 7, eventsWaiting: n === 1 ? 2 : 0, eventsParked: 0, lastEventAt: new Date(Date.now() - n * 60_000).toISOString(),
    pipelines: 0, forms: 0, callOutcomes: 0, fields: 0, lines: 0, tags: 0, storeHandle: null,
  };
  return {
    tenantId, connection, pipelines: [], forms: [], callOutcomes: [], lines: [], tags: [], fields: [], writeback: [], store: null, sampleIds: {},
    missedReasons: [], ...o,
  };
}

const form = (formId: string, name: string, isCounted = true, leadSource: string | null = null, market: string | null = null): SourceForm =>
  ({ formId, name, isCounted, leadSource, market, keptFields: [], isActive: true });
const outcome = (outcomeRef: string, label: string, isConnected: boolean): SourceCallOutcome => ({ outcomeRef, label, isConnected, isActive: true });
const pipeline = (recordType: string, pipelineId: string, label: string, isCounted: boolean, isLead: boolean): SourcePipeline =>
  ({ recordType, pipelineId, label, isCounted, isRouted: false, isLead, workType: null, isActive: true });

function seedIntakeConfig(me: Principal): MockIntakeConfig {
  const all = (state.intakeConfig ??= new Map());
  const existing = all.get(me.tenantId);
  if (existing) return existing;
  const t = me.tenantId;
  const crm = mockSource(t, 1, "crmtest", "Customer records (test)", "100200300", "crm", {
    pipelines: [pipeline("deal", "p-sales", "Sales (test)", true, true), pipeline("deal", "p-self-serve", "Web orders (test)", true, false),
      pipeline("deal", "p-sandbox", "Sandbox (test)", true, true), pipeline("ticket", "p-support", "Support (test)", true, true)],
    forms: [form("f-101", "NL - Quote form (test)"), form("f-102", "UK - Contact form (test)"), form("f-103", "DE Info request (test)"),
      form("f-104", "NL - Cancellation form (test)"), form("f-105", "UK - Replacement request (test)"), form("f-106", "Support question (test)"),
      form("f-107", "Newsletter sign-up (test)", false), form("f-108", "BE Quote form (test)", true, "quote", "BE")],
    callOutcomes: [outcome("o-1", "Connected", true), outcome("o-2", "Not reached", true), outcome("o-3", "Voicemail", true), outcome("o-4", "Busy", false),
      outcome("o-5", "Wrong number", false), outcome("o-6", "Left live message", true), outcome("o-7", "Do not call or email", false)],
    fields: [{ entity: "contact", field: "country", refSystem: null, slot: 1, property: "contact_country" },
      { entity: "contact", field: "language", refSystem: null, slot: 1, property: "contact_language" },
      { entity: "contact", field: "ref", refSystem: "shoptest", slot: 1, property: "contact_shop_id_1" },
      { entity: "deal", field: "market", refSystem: null, slot: 1, property: "deal_country" }],
    writeback: [{ field: "commerce_ref", slot: 1, property: "contact_shop_id_1", mode: "slot", enabled: true },
      { field: "country", slot: 1, property: "contact_country", mode: "if_empty", enabled: true }],
    sampleIds: { deal: "41000123", ticket: "52000456" },
  }, { app_host: "crm.example.com", record_url_deal: "https://{app_host}/records/{account}/deal/{id}", record_url_ticket: "https://{app_host}/records/{account}/ticket/{id}" });
  const sources: MockSource[] = [crm];
  if (t !== MOCK_TENANT_2) {
    sources.push(mockSource(t, 2, "phonetest", "Phones (test)", "4400", "telephony", {
      lines: [{ lineRef: "l-1", name: "NL sales line (test)", digits: "+31200000001", market: "NL", isCounted: true, isActive: true },
        { lineRef: "l-2", name: "UK sales line (test)", digits: "+442000000002", market: "GB", isCounted: true, isActive: true },
        { lineRef: "l-3", name: "Test line (test)", digits: null, market: null, isCounted: false, isActive: true }],
      tags: [{ tagRef: "t-1", name: "Quote", isCounted: true, isActive: true }, { tagRef: "t-2", name: "Courtesy call", isCounted: true, isActive: true },
        { tagRef: "t-3", name: "Internal", isCounted: false, isActive: true },
        // twelve more (addition 0008j), so the Calls report shows its top twelve tags and Other
        ...MOCK_EXTRA_TAGS.map((name, i) => ({ tagRef: `t-${i + 4}`, name, isCounted: true, isActive: true }))],
    }, { record_url_call: "https://phone.example.com/calls/{id}" }));
    sources.push(mockSource(t, 3, "shoptest", "Shop NL (test)", "shop-nl-test.example.com", "commerce", {
      store: { handle: "shop-nl-test", name: "Shop NL (test)", market: "NL", currency: "EUR", timeZone: "Europe/Amsterdam" },
    }, { api_version: "2026-10", client_id: "test-client-id" }));
    sources.push(mockSource(t, 4, "automationtest", "Automations (test)", "100200300", null, {}, { record_url_deal: "https://crm.example.com/records/{account}/deal/{id}" }));
  }
  const market = (code: string, name: string, timeZone: string, languageCode: string, currency: string, sortOrder: number, aliases: string[], active = true): MarketConfig =>
    ({ code, name, timeZone, languageCode, languageSkillKey: active ? languageCode : null, minLanguageLevel: active ? 3 : null, currency, isActive: active, sortOrder, aliases });
  const cfg: MockIntakeConfig = {
    sources,
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
        lastAlertAt: new Date(Date.now() - 25 * 60_000).toISOString() },
      { id: "00000000-0000-7000-8000-0000000a0002", name: "Assigned deal", trigger: "record_assigned", recordType: "deal", pipelineIds: ["p-sales"], audiencePermission: "leads.accept",
        matchLanguage: false, onlyClockedIn: false, fallbackPermission: null, urgency: "urgent", enabled: true, maxAgeMinutes: 60, alerts30d: 168,
        lastAlertAt: new Date(Date.now() - 12 * 60_000).toISOString() },
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

export const mockData: CmaData = {
  /**
   * Any verified identity may work as the test agent. A real person behind IAP
   * sees their own email, so nobody mistakes the mock for their record; roles,
   * employer and tenant are the test agent's.
   */
  async findPrincipal(identity) {
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
    // The admin (0004): everything the manager has plus configuration and user management for everyone
    if (identity.provider === MOCK_IDENTITY.provider && identity.subject === "admin") {
      return {
        ...MOCK_PRINCIPAL,
        userId: MOCK_ADMIN_ID,
        displayName: "Test admin",
        organisationName: "Pulse4all",
        roleKey: "admin",
        permissions: ["workday.own", "workday.team", "workday.export", "performance.team", "monitoring.live", "reports.view",
                      "users.manage_agents", "users.manage_all", "tenant.configure", "skills.manage", "roster.manage", "roster.view", "messages.send"],
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
      const d = m ? deliveryOf(m, me) : null;
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
    const d = m ? deliveryOf(m, me) : null;
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
        medianSecondsToRead: reads.length ? Math.round(reads[Math.floor((reads.length - 1) / 2)]!) : null });
    }
    return out.sort((a, b) => a.createdAt.localeCompare(b.createdAt));
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
    if (p) Object.assign(p, { isCounted: input.isCounted, isLead: input.isLead });
    else x.pipelines.push({ ...pipeline(input.recordType, input.pipelineId, input.pipelineId, input.isCounted, input.isLead) });
  },

  async setSourceForms(me, id, changes) {
    const x = sourceOf(me, id);
    for (const c of changes) assertMockMarket(me, c.market);   // all or nothing, as one transaction
    for (const c of changes) {
      const f = x.forms.find((y) => y.formId === c.formId);
      if (f) Object.assign(f, { isCounted: c.isCounted, leadSource: c.leadSource, market: c.market });
      else x.forms.push(form(c.formId, c.formId, c.isCounted, c.leadSource, c.market));
    }
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

  async setSourceTag(me, id, input) {
    const x = sourceOf(me, id);
    const t = x.tags.find((y) => y.tagRef === input.tagRef);
    if (t) t.isCounted = input.isCounted;
    else x.tags.push({ tagRef: input.tagRef, name: input.tagRef, isCounted: input.isCounted, isActive: true } satisfies SourceTag);
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
    return { rules: structuredClone(c.rules), pipelines, defaultMaxAgeMinutes: 60 };
  },

  async upsertAlertRule(me, input) {
    assertConfigure(me);
    const c = seedIntakeConfig(me);
    const name = input.name.trim();
    const cur = c.rules.find((r) => r.name === name);
    if (cur && cur.trigger !== input.trigger) throw new CmaDbError("CMA03", "a rule of the other trigger holds this name");
    const values = { ...input, name, pipelineIds: [...new Set(input.pipelineIds)].sort() };
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
    return MOCK_CHECKS.map(([key, description], i) => ({ key, description, total: main ? 1 + Math.floor(hashOf(key) * 40) + (i === 3 ? 3 : 0) : 0 }));
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
    return { ...range, filter, telephony, connectedMinSeconds: mockConnectedMin(), rows, total, ...mockCallsLists(me, range, filter) };
  },

  async getCallsPerAgentTags(me, range, filter): Promise<CallsPerAgentTags> {
    assertCalls(me, range, filter, null, [PER_AGENT_PERMISSION]);
    const telephony = connectionsOf(me).telephony;
    return { ...range, filter, telephony, rows: callsPerPersonTags(mockCallRecords(me, range, filter), range.from, range.to, mockPersonOf(me), mockCallTags(me)) };
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
};
