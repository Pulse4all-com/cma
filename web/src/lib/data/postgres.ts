import "server-only";
import { config } from "@/lib/config";
import type { Identity, Principal } from "@/lib/auth/identity";
import { CmaDbError, one, withTenant, withoutTenant, type Querier, type TenantContext } from "@/lib/db/client";
import type {
  AbsenceType, AppLink, CmaData, ConfigAppLink, ConfigStatus, CoverageTargetRow, DateKey, DirectoryPerson, ExportHoursRow, HoursRange, HoursSummary, MessageStat, MyMessage, MyMessages, MyProfile, MyRosterDay, OrganisationInfo,
  RoleInfo, RosterCoverageRow, RosterEntry, RosterPerson, RosterWeek, RosterWeekHeader, RosterWeekSummary, SkillInfo, TodayShift,
  StatusChangeRow, StatusTimeRow, TeamDay, TeamDayDetail, TeamInfo, TeamMembership, TeamNow, TeamNowPerson,
  TeamPerson, TenantSetting, TimeEvent, Workday, WorkStatus, PermissionInfo, SentMessage,
  CrmRecordsDay, DataQualityCheck, Intake, SourceConnections, SpeedToLeadRow, SpeedToLeadStatus, SpeedToLeadSummaryRow,
  AlertPipelineChoice, AlertRule, LinkedAccountSystem, MarketConfig, SourceConnection, SourceDetail, SourceKind, SourcePipeline, SourceSettings,
  InboundFigures, InboundNow, InboundService, MissedReason,
  CallsFigures, CallsFilter, CallsLine, CallsOverview, CallsPerAgent, CallsPerAgentTags, CallsPerson, CallsTagUse,
  FormAnswerRow, FormCategory, FormsAnswers, FormsReport, FormsRow, SourceFormField,
  Invitation, InvitationAcceptResult, InvitationLink, InvitationPreview,
  DueState, FollowUpOwner, FollowUpPage, FollowUpRowsAt, FollowUpSummary, FollowUpSummaryAt, MyFollowUp, OpenLead, OpenTask, OpenTicket, SlaState,
  DatabaseProbe, OutboxStatusRow, SystemHealthRun,
  EmailFigures, EmailNotRespondingRow, EmailPerAgent, EmailPerson, EmailReport, EmailRow, EmailSeriesRow, EmailWaitingRow,
  AttributionSettings, FirstOrderAmount, FirstOrderEvidence, FirstOrderFigures, FirstOrderListRow, FirstOrderRow, FirstOrdersReport, OrderPerson, OrdersPerPerson,
  Journey, JourneyStatus, CallbackCounts, CallbackOwner, CallbacksKept,
  AttemptBucket, AttemptFigures, AttemptGroupRow, AttemptListRow, AttemptOutcomeRow, AttemptPerson, AttemptSettings, AttemptsPerAgent, AttemptsReport,
  DealAttempt, LineStoredCalls,
} from "./types";
import { INVITE_TOKEN_RE, invitationFromDb, type InvitationDbRow } from "@/lib/invitations";
import { OUTBOX_LATE_MINUTES, applyConnections, previousPeriod, rangeProblem, withOutboxPending, type IntakeCounts } from "@/lib/reports";
import { workdayStartsAt } from "@/lib/live";
import { dateKeyInZone } from "@/lib/time";

/**
 * CmaData against Postgres, as cma_app (migration 0002).
 *
 * Rules every query here follows:
 *  - One transaction per call, tenant and acting user set for that transaction only (lib/db/client).
 *  - Own data only through the database: every read filters on cma.current_user_id(), the
 *    transaction's acting user, never on an id passed in. A bug that hands over a colleague's id
 *    still cannot read a colleague's hours.
 *  - The database clock decides: open_workday(), set_status() and end_workday() are called without
 *    a time, so they use now(). The `now` arguments of the interface exist for the mock only.
 *  - "Today" is the business date in the user's zone, computed in SQL (cma.business_date with
 *    cma.user_timezone), so the app server's zone never matters.
 *  - Errors surface as CmaDbError with the function's SQLSTATE (CMA01 to CMA05); SQL text never
 *    reaches a screen.
 */

/** The acting user's own rows; the value comes from the transaction context, not a parameter */
const OWN = "user_id = cma.current_user_id()";
/** Today's business date for the acting user, in the user's zone */
const TODAY = "cma.business_date(now(), cma.user_timezone(cma.current_user_id()))";
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

type HeaderRow = {
  business_date: string;
  status: "open" | "ended";
  started_at: Date;
  ended_at: Date | null;
};
type SummaryRow = HeaderRow & { working_seconds: number };

const HEADER = "business_date, status, started_at, ended_at";

type DayRow = HeaderRow & {
  status_key: string | null;
  status_name: string | null;
  status_since: Date | null;
  closed_seconds: number;
  running_since: Date | null;
  day_ends_at: Date;
};

/**
 * One own workday with its current status and the clock's inputs. Worked time counts intervals in
 * statuses with is_working; a capped interval (forgotten clock-out) counts as closed and never runs.
 * `dateSql` is TODAY or a bound parameter, never caller text.
 */
async function readDay(q: Querier, dateSql: string, params: unknown[]): Promise<DayRow[]> {
  const r = await q.query<DayRow>(
    `select s.business_date, s.status, s.started_at, s.ended_at,
            ws.key                                   as status_key,
            ws.name                                  as status_name,
            coalesce(c.closed_seconds, 0)::int       as closed_seconds,
            c.running_since,
            c.status_since,
            cma.business_day_end(s.business_date, s.timezone) as day_ends_at
       from cma.workday_summary s
       left join cma.work_status ws
              on ws.tenant_id = cma.current_tenant_id() and ws.id = s.current_status_id
       left join lateral (
         select sum(i.seconds) filter (where iws.is_working and (not i.is_open or i.is_capped)) as closed_seconds,
                max(i.from_at) filter (where iws.is_working and i.is_open and not i.is_capped)  as running_since,
                max(i.from_at) filter (where i.is_open and not i.is_capped)                     as status_since
           from cma.time_interval i
           join cma.work_status iws
             on iws.tenant_id = cma.current_tenant_id() and iws.id = i.status_id
          where i.workday_id = s.workday_id
       ) c on true
      where s.${OWN} and s.business_date = ${dateSql}`,
    params,
  );
  return r.rows;
}


// ---- Intake reports (migration 0007d, and 0006's crm_records_per_day; B11, 12 October 2026)
// Each function checks its permission and the 92-day bound itself (CMA06, CMA04), in the same
// transaction as everything else read here; the bound is checked here first as well, so a long range
// never reaches the database.

function assertReportRange(range: HoursRange): void {
  assertDate(range.from, "from");
  assertDate(range.to, "to");
  if (rangeProblem(range.from, range.to)) throw new CmaDbError("CMA04", "the range must run forward and cover at most 92 days");
}

/** numeric arrives as a string; null stays null */
const num = (v: string | number | null): number | null => (v === null ? null : Number(v));

type SpeedDbRow = {
  deal_id: string; connection_id: string; deal_source_id: string; pipeline_id: string | null; pipeline_label: string | null;
  business_date: string; created_at: Date; market: string; market_source: string | null; is_closed: boolean; status: SpeedToLeadStatus;
  first_call_source_id: string | null; first_call_at: Date | null; first_call_linked: boolean | null; first_any_call_at: Date | null;
  first_any_direction: string | null; inbound_first: boolean; first_connected_at: Date | null; agent_user_id: string | null;
  agent_from: string | null; elapsed_seconds: number | null; business_seconds: number | null; target_seconds: number | null;
  within_target: boolean | null; next_business_noon: Date | null; before_next_noon: boolean | null;
  waiting_business_seconds: number | null; record_url: string | null;
};

function toSpeedRow(r: SpeedDbRow): SpeedToLeadRow {
  return {
    dealId: r.deal_id, connectionId: r.connection_id, dealSourceId: r.deal_source_id, pipelineId: r.pipeline_id,
    pipelineLabel: r.pipeline_label, date: r.business_date, createdAt: r.created_at.toISOString(), market: r.market,
    marketSource: r.market_source, isClosed: r.is_closed, status: r.status, firstCallSourceId: r.first_call_source_id,
    firstCallAt: iso(r.first_call_at), firstCallLinked: r.first_call_linked, firstAnyCallAt: iso(r.first_any_call_at),
    firstAnyDirection: r.first_any_direction, inboundFirst: r.inbound_first, firstConnectedAt: iso(r.first_connected_at),
    agentUserId: r.agent_user_id, agentFrom: r.agent_from, elapsedSeconds: r.elapsed_seconds, businessSeconds: r.business_seconds,
    targetSeconds: r.target_seconds, withinTarget: r.within_target, nextBusinessNoon: iso(r.next_business_noon),
    beforeNextNoon: r.before_next_noon, waitingBusinessSeconds: r.waiting_business_seconds, recordUrl: r.record_url,
  };
}

type SummaryDbRow = {
  group_key: string; group_label: string | null; deals: number; called: number; median_business_minutes: string | null;
  p80_business_minutes: string | null; within_target_pct: string | null; before_next_noon_pct: string | null; open_not_called: number;
};

type IntakeDbRow = {
  business_date: string; market: string; form_submissions: number; deals_created: number; deals_closed: number;
  tickets_created: number; tickets_closed: number; calls_in: number; calls_out: number; tagged_calls: number;
  new_customers: number; first_orders: number; repeat_orders: number; renewals: number;
};

/**
 * Which kinds of source the tenant has connected, read under row-level security in the transaction
 * whose report function has just checked the permission. No function answers this for a reader
 * (cma.connections_all is tenant.configure only and names adapters, which are vendor values), so the
 * tables of 0007a and 0007b decide: telephony is connected when an active connection has a line in
 * the telephony catalog or a telephony call; commerce when an active connection has its store.
 */
async function readConnections(q: Querier): Promise<SourceConnections> {
  const r = await q.query<{ telephony: boolean; commerce: boolean }>(
    `select exists (select 1 from cma.telephony_number n
                      join cma.integration_connection c on c.tenant_id = n.tenant_id and c.id = n.connection_id
                     where c.status = 'active')
         or exists (select 1 from cma.telephony_call t
                      join cma.integration_connection c on c.tenant_id = t.tenant_id and c.id = t.connection_id
                     where c.status = 'active') as telephony,
            exists (select 1 from cma.commerce_store s
                      join cma.integration_connection c on c.tenant_id = s.tenant_id and c.id = s.connection_id
                     where c.status = 'active') as commerce`,
  );
  const row = one(r.rows, "connections");
  return { telephony: row.telephony, commerce: row.commerce };
}

// ---- Inbound service and callbacks (addition 0008i): the rows as the functions answer them ----------
type InboundDbRow = {
  group_key: string | null; group_label: string | null; offered: number; answered: number; unanswered: number; waiting: number;
  answered_within_target: number; service_level_base: number; service_level_pct: string | null; avg_answer_seconds: string | null;
  p80_answer_seconds: string | null; unanswered_by_reason: Record<string, number>;
};
type ReasonDbRow = { source_system: string; code: string; label: string; counts_in_service_level: boolean; needs_callback: boolean };
type MissedReasonDb = { code: string; label: string; countsInServiceLevel: boolean; needsCallback: boolean; inCatalog: boolean; seenCalls: number; lastSeenAt: string | null };
type CallbackDbRow = {
  call_id: string; connection_id: string; source_id: string; line_ref: string | null; line_name: string | null; market: string;
  reason_code: string; reason_label: string; started_at: Date; missed_count: number; waiting_seconds: number;
  waiting_business_seconds: number | null; record_url: string | null;
};

function toFigures(x: Omit<InboundDbRow, "group_key" | "group_label">): InboundFigures {
  return {
    offered: x.offered ?? 0, answered: x.answered ?? 0, unanswered: x.unanswered ?? 0, waiting: x.waiting ?? 0,
    answeredWithinTarget: x.answered_within_target ?? 0, serviceLevelBase: x.service_level_base ?? 0,
    serviceLevelPct: num(x.service_level_pct), avgAnswerSeconds: num(x.avg_answer_seconds), p80AnswerSeconds: num(x.p80_answer_seconds),
    unansweredByReason: x.unanswered_by_reason ?? {},
  };
}

function emptyFigures(): InboundFigures {
  return { offered: 0, answered: 0, unanswered: 0, waiting: 0, answeredWithinTarget: 0, serviceLevelBase: 0, serviceLevelPct: null,
    avgAnswerSeconds: null, p80AnswerSeconds: null, unansweredByReason: {} };
}

function toReason(x: ReasonDbRow): MissedReason {
  return { sourceSystem: x.source_system, code: x.code, label: x.label, countsInServiceLevel: x.counts_in_service_level, needsCallback: x.needs_callback };
}

// ---- Calls overview and calls per agent (addition 0008j): the rows as the functions answer them ----
type CallsDbRow = {
  period: string; group_key: string | null; group_label: string | null; calls: number; inbound: number; outbound: number;
  answered_inbound: number; connected_outbound: number; connected_pct: string | null; conversations: number;
  talk_seconds_total: string; talk_seconds_avg: string | null; outbound_talk_seconds: string; outbound_talk_avg: string | null;
  untagged_conversations: number;
};
type PersonDbRow = {
  row_kind: "person" | "not_linked" | "total"; user_id: string | null; display_name: string | null; unlinked_users: number | null;
  answered_inbound: number; inbound_talk_seconds: string; inbound_talk_avg: string | null; outbound_calls: number; connected_outbound: number;
  outbound_talk_seconds: string; outbound_talk_avg: string | null; conversations: number; untagged_conversations: number;
  first_call_time: string | null; last_call_time: string | null;
};

function toCallsFigures(x: CallsDbRow | undefined): CallsFigures {
  return {
    calls: x?.calls ?? 0, inbound: x?.inbound ?? 0, outbound: x?.outbound ?? 0, answeredInbound: x?.answered_inbound ?? 0,
    connectedOutbound: x?.connected_outbound ?? 0, connectedPct: num(x?.connected_pct ?? null), conversations: x?.conversations ?? 0,
    talkSeconds: Number(x?.talk_seconds_total ?? 0), talkAvgSeconds: num(x?.talk_seconds_avg ?? null),
    outboundTalkSeconds: Number(x?.outbound_talk_seconds ?? 0), outboundTalkAvgSeconds: num(x?.outbound_talk_avg ?? null),
    untaggedConversations: x?.untagged_conversations ?? 0,
  };
}

function toCallsPerson(x: PersonDbRow): CallsPerson {
  return {
    kind: x.row_kind === "not_linked" ? "notLinked" : x.row_kind, userId: x.user_id, name: x.display_name, unlinkedUsers: x.unlinked_users,
    answeredInbound: x.answered_inbound, inboundTalkSeconds: Number(x.inbound_talk_seconds), inboundTalkAvgSeconds: num(x.inbound_talk_avg),
    outboundCalls: x.outbound_calls, connectedOutbound: x.connected_outbound, outboundTalkSeconds: Number(x.outbound_talk_seconds),
    outboundTalkAvgSeconds: num(x.outbound_talk_avg), conversations: x.conversations, untaggedConversations: x.untagged_conversations,
    firstCallTime: x.first_call_time?.slice(0, 5) ?? null, lastCallTime: x.last_call_time?.slice(0, 5) ?? null,
  };
}

/**
 * The markets and lines with calls in the period, for the filters: every market, and the lines within the
 * chosen market (cma.calls_overview grouped by market and by line, in the same transaction)
 */
async function callsFilterLists(q: Querier, range: HoursRange, filter: CallsFilter): Promise<{ markets: string[]; lines: CallsLine[] }> {
  const m = await q.query<CallsDbRow>(`select * from cma.calls_overview($1::date, $2::date, null, null, 'market') where period = 'current' and group_key is not null`,
    [range.from, range.to]);
  const l = await q.query<CallsDbRow>(`select * from cma.calls_overview($1::date, $2::date, $3, null, 'line') where period = 'current' and group_key is not null`,
    [range.from, range.to, filter.market]);
  return { markets: m.rows.map((x) => x.group_key!), lines: l.rows.map((x) => ({ key: x.group_key!, name: x.group_label })) };
}

// ---- Forms reporting (addition 0008p): the rows as cma.forms_report answers them -----------------------
type FormsDbRow = {
  period: string; group_key: string | null; connection_id: string; form_id: string; form_name: string; category: string | null; market: string;
  submissions: number; resolved: number; not_found: number; ambiguous: number; no_email: number; pending: number;
};

function toFormsRow(x: FormsDbRow): FormsRow {
  return {
    groupKey: x.group_key, formKey: `${x.connection_id}:${x.form_id}`, formName: x.form_name, category: x.category, market: x.market,
    submissions: x.submissions, resolved: x.resolved, notFound: x.not_found, ambiguous: x.ambiguous, noEmail: x.no_email, pending: x.pending,
  };
}

// ---- Email reports (addition 0008t): the rows as cma.email_report and cma.email_per_person answer them ----
type EmailDbFigures = {
  received: number; logged_replies: number; sent_agent: number; sent_automated: number; bounced_failed: number; threads_opened: number;
  threads_closed: number; replied: number; reply_median_seconds: string | null; reply_median_business_seconds: string | null; within_target: number;
  target_known: number; no_hours: number; close_median_seconds: string | null; close_median_business_seconds: string | null;
};
type EmailDbRow = EmailDbFigures & { period: string; dimension: string; group_key: string | null; group_label: string | null };

const numOrNull = (v: string | number | null | undefined): number | null => (v === null || v === undefined ? null : Number(v));

function toEmailFigures(x: EmailDbFigures): EmailFigures {
  return {
    received: x.received, loggedReplies: x.logged_replies, sentAgent: x.sent_agent, sentAutomated: x.sent_automated, bouncedFailed: x.bounced_failed,
    threadsOpened: x.threads_opened, threadsClosed: x.threads_closed, replied: x.replied, replyMedianSeconds: numOrNull(x.reply_median_seconds),
    replyMedianBusinessSeconds: numOrNull(x.reply_median_business_seconds), withinTarget: x.within_target, targetKnown: x.target_known, noHours: x.no_hours,
    closeMedianSeconds: numOrNull(x.close_median_seconds), closeMedianBusinessSeconds: numOrNull(x.close_median_business_seconds),
  };
}

function toEmailRow(x: EmailDbRow): EmailRow {
  return { groupKey: x.group_key ?? "none", groupLabel: x.group_label, ...toEmailFigures(x) };
}

/** A dimension's rows in the order the screen shows them: 'none' last, else by label (dates by key) */
function emailRowsOf(rows: EmailDbRow[], dimension: string): EmailRow[] {
  const dated = dimension === "day" || dimension === "week";
  return rows.filter((x) => x.period === "current" && x.dimension === dimension).map(toEmailRow)
    .sort((a, b) => (dated ? a.groupKey.localeCompare(b.groupKey)
      : Number(a.groupKey === "none") - Number(b.groupKey === "none") || (a.groupLabel ?? "").localeCompare(b.groupLabel ?? "") || a.groupKey.localeCompare(b.groupKey)));
}

/** The received series of a 'day_inbox'-like dimension: its key is 'date|series key' */
function emailSeriesOf(rows: EmailDbRow[], dimension: string): EmailSeriesRow[] {
  return rows.filter((x) => x.period === "current" && x.dimension === dimension && x.received > 0).map((x) => {
    const [groupKey, ...rest] = (x.group_key ?? "").split("|");
    return { groupKey: groupKey!, seriesKey: rest.join("|") || "none", seriesLabel: x.group_label, received: x.received };
  });
}

/** Whether the tenant has email at all: an inbox in a catalog or a stored email (else "No email connected", never 0) */
async function readHasEmail(q: Querier): Promise<boolean> {
  const r = await q.query<{ email: boolean }>(`select exists (select 1 from cma.connection_inbox) or exists (select 1 from cma.email_message) as email`);
  return r.rows[0]?.email ?? false;
}

async function emailSettings(q: Querier): Promise<{ replyTargetMinutes: number; noResponseDays: number }> {
  const r = await q.query<{ key: string; value: string }>(
    `select key, value from cma.tenant_settings() where key in ('email.reply_target_minutes', 'email.no_response_days')`);
  // the catalog holds both with their defaults (0008m), so a missing row is a database fault, never a value made up here
  const of = (k: string) => {
    const v = r.rows.find((x) => x.key === k)?.value;
    if (v === undefined) throw new Error(`tenant setting ${k} is missing from the catalog`);
    return Number(v);
  };
  return { replyTargetMinutes: of("email.reply_target_minutes"), noResponseDays: of("email.no_response_days") };
}

/** The lists for the filters: markets, inboxes and mailboxes with email in the period, without the filters (from the page's own read when unfiltered) */
function emailListsOf(rows: EmailDbRow[]): { markets: string[]; inboxes: { key: string; name: string }[]; accounts: { key: string; name: string }[] } {
  const named = (d: string) => rows.filter((x) => x.period === "current" && x.dimension === d && x.group_key !== null && x.group_key !== "none")
    .map((x) => ({ key: x.group_key!, name: x.group_label ?? x.group_key! })).sort((a, b) => a.name.localeCompare(b.name));
  return {
    markets: rows.filter((x) => x.period === "current" && x.dimension === "market").map((x) => x.group_key!)
      .sort((a, b) => (a === "unknown" ? 1 : b === "unknown" ? -1 : a.localeCompare(b))),
    inboxes: named("inbox"),
    accounts: named("account"),
  };
}

type EmailPersonDbRow = {
  row_kind: string; user_id: string | null; display_name: string | null; unlinked_owners: number | null; sent: number; replies: number; threads_closed: number;
  reply_median_seconds: string | null; reply_median_business_seconds: string | null; within_target: number; target_known: number; sent_by_hour: number[];
};
/** One row of cma.email_per_person_page: a person's row (part 'person') or a figures row without the filters (part 'dimension') */
type EmailPersonPageDbRow = EmailPersonDbRow & EmailDbFigures & { part: string; dimension: string; group_key: string | null; group_label: string | null };

function toEmailPerson(x: EmailPersonDbRow): EmailPerson {
  return {
    kind: x.row_kind === "not_linked" ? "notLinked" : x.row_kind === "total" ? "total" : "person", userId: x.user_id, name: x.display_name,
    unlinkedOwners: x.unlinked_owners, sent: x.sent, replies: x.replies, threadsClosed: x.threads_closed, replyMedianSeconds: numOrNull(x.reply_median_seconds),
    replyMedianBusinessSeconds: numOrNull(x.reply_median_business_seconds), withinTarget: x.within_target, targetKnown: x.target_known,
    sentByHour: x.sent_by_hour ?? Array(24).fill(0),
  };
}

async function telephonySetting(q: Querier): Promise<number> {
  const r = await q.query<{ value: string | null }>(`select value from cma.tenant_settings() where key = 'telephony.connected_min_seconds'`);
  return Number(r.rows[0]?.value ?? 10);
}

function ctx(me: Principal): TenantContext {
  return { tenantId: me.tenantId, userId: me.userId };
}

function toWorkday(r: DayRow): Workday {
  const ended = r.status === "ended";
  return {
    date: r.business_date,
    status: ended ? "ended" : "working",
    startedAt: r.started_at.toISOString(),
    endedAt: r.ended_at ? r.ended_at.toISOString() : null,
    statusKey: ended ? null : r.status_key,
    statusName: ended ? null : r.status_name,
    statusSince: !ended && r.status_since ? r.status_since.toISOString() : null,
    clock: {
      closedSeconds: r.closed_seconds,
      runningSince: !ended && r.running_since ? r.running_since.toISOString() : null,
    },
    dayEndsAt: r.day_ends_at.toISOString(),
  };
}

/**
 * Minutes shown for a day: working time, rounded down so the screen never shows more than was
 * worked. Which hours the agent's screen shows (working or paid) is an open decision with Arno and
 * Kira (README, Open decisions); switching is this one line.
 */
function minutesOf(r: SummaryRow): number {
  return Math.floor(r.working_seconds / 60);
}

function assertDate(d: string, name: string): void {
  if (!DATE_RE.test(d)) throw new CmaDbError("DB_ERROR", `${name} must be YYYY-MM-DD`);
}

// ---- Team (migrations 0003, 0003a): cma.team_hours, cma.team_day, cma.correct_workday, cma.team_people
// team_day carries import_batch_key since addition 0008d; before it the column is absent (null here)
// These read other people's days, so the permission check is inside each function (workday.team,
// CMA06), in the same transaction as the read: never a check here followed by a plain query.

type TeamRow = {
  user_id: string;
  display_name: string;
  organisation_name: string;
  business_date: string;
  timezone: string;
  status: "open" | "ended";
  started_at: Date;
  ended_at: Date | null;
  working_seconds: number;
  paid_seconds: number;
  is_capped: boolean;
  needs_correction: boolean;
  has_correction: boolean;
};

type EventRow = {
  event_id: string;
  kind: TimeEvent["kind"];
  status_key: string | null;
  status_name: string | null;
  occurred_at: Date;
  recorded_at: Date;
  source: TimeEvent["source"];
  supersedes_event_id: string | null;
  reason: string | null;
  approved_by_name: string | null;
  is_effective: boolean;
  import_batch_key: string | null;
};

function toTeamDay(r: TeamRow): TeamDay {
  return {
    userId: r.user_id,
    displayName: r.display_name,
    organisationName: r.organisation_name,
    date: r.business_date,
    timeZone: r.timezone,
    status: r.status,
    startedAt: r.started_at.toISOString(),
    endedAt: r.ended_at ? r.ended_at.toISOString() : null,
    minutes: Math.floor(r.working_seconds / 60),
    paidMinutes: Math.floor(r.paid_seconds / 60),
    isCapped: r.is_capped,
    needsCorrection: r.needs_correction,
    hasCorrection: r.has_correction,
  };
}

function toTimeEvent(r: EventRow): TimeEvent {
  return {
    id: r.event_id,
    kind: r.kind,
    statusKey: r.status_key,
    statusName: r.status_name,
    at: r.occurred_at.toISOString(),
    recordedAt: r.recorded_at.toISOString(),
    source: r.source,
    supersedes: r.supersedes_event_id,
    reason: r.reason,
    approvedByName: r.approved_by_name,
    isEffective: r.is_effective,
    importBatchKey: r.import_batch_key ?? null,
  };
}

async function readTeamDay(q: Querier, userId: string, date: DateKey): Promise<TeamDayDetail> {
  const day = await q.query<TeamRow>(`select * from cma.team_hours($2::date, $2::date, $1::uuid)`, [userId, date]);
  const events = await q.query<EventRow>(`select * from cma.team_day($1::uuid, $2::date)`, [userId, date]);
  return { day: day.rows[0] ? toTeamDay(day.rows[0]) : null, events: events.rows.map(toTimeEvent) };
}

// ---- Exports (migration 0003b): cma.export_hours, cma.export_status_changes, cma.tenant_settings
// workday.export is checked inside each export function, in the same transaction as the read.
// The settings are read in that same transaction, so a file never mixes two configurations.

async function readSettings(q: Querier): Promise<TenantSetting[]> {
  const r = await q.query<{ key: string; value: string; is_default: boolean }>(`select * from cma.tenant_settings()`);
  return r.rows.map((x) => ({ key: x.key, value: x.value, isDefault: x.is_default }));
}

type ExportHoursDbRow = {
  user_id: string; display_name: string; organisation_name: string; business_date: string; timezone: string;
  status: "open" | "ended"; started_at: Date; ended_at: Date | null;
  working_seconds: number; productive_seconds: number; paid_seconds: number;
  billable_seconds: number; is_capped: boolean; needs_correction: boolean; has_correction: boolean;
};

type StatusChangeDbRow = {
  user_id: string; display_name: string; organisation_name: string; business_date: string; timezone: string;
  status_key: string; status_name: string; is_working: boolean; is_productive: boolean; is_paid: boolean;
  is_billable: boolean; from_at: Date; to_at: Date | null; is_open: boolean; is_capped: boolean;
  seconds: number; source: StatusChangeRow["source"];
};

function toExportHoursRow(r: ExportHoursDbRow): ExportHoursRow {
  return {
    userId: r.user_id,
    displayName: r.display_name,
    organisationName: r.organisation_name,
    date: r.business_date,
    timeZone: r.timezone,
    status: r.status,
    startedAt: r.started_at.toISOString(),
    endedAt: r.ended_at ? r.ended_at.toISOString() : null,
    workedSeconds: r.working_seconds,
    productiveSeconds: r.productive_seconds,
    paidSeconds: r.paid_seconds,
    billableSeconds: r.billable_seconds,
    isCapped: r.is_capped,
    needsCorrection: r.needs_correction,
    hasCorrection: r.has_correction,
  };
}

type StatusTimeDbRow = {
  user_id: string; display_name: string; organisation_name: string; business_date: string; timezone: string;
  status_key: string; status_name: string; sort_order: number; status_active: boolean; is_working: boolean;
  is_productive: boolean; is_paid: boolean; is_billable: boolean; seconds: number; stretches: number; is_capped: boolean;
};

function toStatusTimeRow(r: StatusTimeDbRow): StatusTimeRow {
  return {
    userId: r.user_id,
    displayName: r.display_name,
    organisationName: r.organisation_name,
    date: r.business_date,
    timeZone: r.timezone,
    statusKey: r.status_key,
    statusName: r.status_name,
    sortOrder: r.sort_order,
    statusActive: r.status_active,
    isWorking: r.is_working,
    isProductive: r.is_productive,
    isPaid: r.is_paid,
    isBillable: r.is_billable,
    seconds: r.seconds,
    stretches: r.stretches,
    isCapped: r.is_capped,
  };
}

function toStatusChangeRow(r: StatusChangeDbRow): StatusChangeRow {
  return {
    userId: r.user_id,
    displayName: r.display_name,
    organisationName: r.organisation_name,
    date: r.business_date,
    timeZone: r.timezone,
    statusKey: r.status_key,
    statusName: r.status_name,
    isWorking: r.is_working,
    isProductive: r.is_productive,
    isPaid: r.is_paid,
    isBillable: r.is_billable,
    from: r.from_at.toISOString(),
    to: r.to_at ? r.to_at.toISOString() : null,
    isOpen: r.is_open,
    isCapped: r.is_capped,
    seconds: r.seconds,
    source: r.source,
  };
}

// ---- Team now (addition 0003e): cma.team_now
// One row per person whose time is kept, with today's day in the person's zone. The day part is
// mapped with toWorkday, the same mapping as the own-day read, so a person's own row equals
// GET /api/v1/me/day field for field. monitoring.live is checked inside the function (CMA06).

type TeamNowDbRow = {
  user_id: string; display_name: string; organisation_key: string | null; organisation_name: string; timezone: string;
  business_date: string; workday_id: string | null; day_status: "open" | "ended" | null;
  started_at: Date | null; ended_at: Date | null;
  status_key: string | null; status_name: string | null; status_active: boolean | null;
  is_working: boolean | null; is_productive: boolean | null; is_paid: boolean | null; is_billable: boolean | null;
  status_since: Date | null; closed_seconds: number; running_since: Date | null; day_ends_at: Date;
};

function toTeamNowPerson(r: TeamNowDbRow): TeamNowPerson {
  const day: Workday | null =
    r.workday_id && r.day_status && r.started_at
      ? toWorkday({
          business_date: r.business_date,
          status: r.day_status,
          started_at: r.started_at,
          ended_at: r.ended_at,
          status_key: r.status_key,
          status_name: r.status_name,
          status_since: r.status_since,
          closed_seconds: Number(r.closed_seconds),
          running_since: r.running_since,
          day_ends_at: r.day_ends_at,
        })
      : null;
  const status =
    day && day.status === "working" && r.status_key && r.status_name
      ? {
          key: r.status_key,
          name: r.status_name,
          isActive: r.status_active === true,
          isWorking: r.is_working === true,
          isProductive: r.is_productive === true,
          isPaid: r.is_paid === true,
          isBillable: r.is_billable === true,
        }
      : null;
  return {
    userId: r.user_id,
    displayName: r.display_name,
    organisationKey: r.organisation_key,
    organisationName: r.organisation_name,
    timeZone: r.timezone,
    date: r.business_date,
    day,
    status,
  };
}


// ---- Team screen (migration 0004): cma.directory, cma.roles, cma.teams, cma.skills and the writes
// Who is listed and who may be edited is the database's answer (users.manage_agents or
// users.manage_all inside each function, CMA06); this layer only reshapes rows. The login id a
// person was added with is written once and never read back.

type DirectoryDbRow = {
  user_id: string; email: string; display_name: string; status: "active" | "inactive";
  organisation_key: string | null; organisation_name: string; timezone: string;
  role_key: string | null; role_name: string | null; role_granted_at: Date | null; is_managing: boolean;
  time_kept: boolean; teams: { key: string; name: string }[];
  skills: { dimension: SkillInfo["dimension"]; key: string; name: string; level: number | null; levelName: string | null }[];
  may_edit: boolean;
};

function toDirectoryPerson(r: DirectoryDbRow): DirectoryPerson {
  return {
    userId: r.user_id,
    email: r.email,
    displayName: r.display_name,
    isActive: r.status === "active",
    organisationKey: r.organisation_key,
    organisationName: r.organisation_name,
    timeZone: r.timezone,
    roleKey: r.role_key,
    roleName: r.role_name,
    isManaging: r.is_managing,
    timeKept: r.time_kept,
    teams: r.teams ?? [],
    skills: (r.skills ?? []).map((k) => ({ dimension: k.dimension, key: k.key, name: k.name, level: k.level, levelName: k.levelName })),
    mayEdit: r.may_edit,
  };
}


// ---- Roster (migration 0005): cma.roster_week, roster_people, roster_entries, roster_coverage,
// roster_set_entry, roster_publish, roster_copy_week, roster_weeks, my_roster, roster_today,
// absence_types. Every function checks its permission inside (roster.manage, roster.view or
// monitoring.live, CMA06). Times stay local hh:mm:ss strings in the person's zone; dates are
// business dates; the date type parser keeps both as strings.

type RosterWeekDbRow = {
  week_id: string | null; team_key: string | null; team_name: string | null; week_start: string; status: "draft" | "published";
  version: number; published_at: Date | null; published_by_name: string | null; entry_count: number; changed_since_publish: boolean;
};
type RosterPersonDbRow = { user_id: string; display_name: string; organisation_name: string; timezone: string; team_keys: string[] | null; work_type_keys: string[] | null };
type RosterEntryDbRow = {
  entry_id: string; user_id: string; business_date: string; kind: "shift" | "absence"; start_time: string | null; end_time: string | null;
  absence_key: string | null; absence_name: string | null; note: string | null; recorded_at: Date; recorded_by_name: string;
};
type CoverageDbRow = { business_date: string; skill_key: string; skill_name: string; planned_people: number; people_names: string[] | null; target: number | null };

function toRosterHeader(r: RosterWeekDbRow): RosterWeekHeader {
  return {
    weekId: r.week_id, teamKey: r.team_key, teamName: r.team_name, weekStart: r.week_start, status: r.status, version: r.version,
    publishedAt: r.published_at ? r.published_at.toISOString() : null, publishedByName: r.published_by_name,
    entryCount: r.entry_count, changedSincePublish: r.changed_since_publish,
  };
}

function toRosterEntry(r: RosterEntryDbRow): RosterEntry {
  return {
    entryId: r.entry_id, userId: r.user_id, date: r.business_date, kind: r.kind, start: r.start_time, end: r.end_time,
    absenceKey: r.absence_key, absenceName: r.absence_name, note: r.note, recordedAt: r.recorded_at.toISOString(), recordedByName: r.recorded_by_name,
  };
}

async function readRosterHeader(q: Querier, weekStart: DateKey, teamKey: string | null): Promise<RosterWeekHeader> {
  const r = await q.query<RosterWeekDbRow>(`select * from cma.roster_week($1::date, $2)`, [weekStart, teamKey]);
  return toRosterHeader(one(r.rows, "roster_week"));
}

// ---- Messaging (migration 0008): cma.my_messages, my_unread_count, mark_messages_read, acknowledge_message,
// send_message, message_stats. Own deliveries only: every function takes the acting user from the
// transaction, never an id; the permission checks (messages.send, CMA06) are inside the functions.

type MessageDbRow = {
  message_id: string; kind: MyMessage["kind"]; urgency: MyMessage["urgency"]; title: string; body: string;
  ref_system: string | null; ref_type: string | null; ref_id: string | null; ref_url: string | null;
  created_at: Date; expires_at: Date | null; delivered_at: Date | null; read_at: Date | null; acknowledged_at: Date | null;
};

const iso = (d: Date | null): string | null => (d ? d.toISOString() : null);

function toMessage(r: MessageDbRow): MyMessage {
  return {
    id: r.message_id, kind: r.kind, urgency: r.urgency, title: r.title, body: r.body,
    ref: r.ref_system && r.ref_type && r.ref_id ? { system: r.ref_system, type: r.ref_type, id: r.ref_id, url: r.ref_url } : null,
    createdAt: r.created_at.toISOString(), expiresAt: iso(r.expires_at),
    deliveredAt: iso(r.delivered_at), readAt: iso(r.read_at), acknowledgedAt: iso(r.acknowledged_at),
  };
}

type StatDbRow = {
  message_id: string; kind: MyMessage["kind"]; urgency: MyMessage["urgency"]; title: string;
  ref_system: string | null; ref_type: string | null; ref_id: string | null; rule_id: string | null; sender_user_id: string | null;
  created_at: Date; recipients: number; delivered: number; read: number; acknowledged: number; median_seconds_to_read: number | null;
  withdrawn_at: Date | null;
};

function toStat(r: StatDbRow): MessageStat {
  return {
    id: r.message_id, kind: r.kind, urgency: r.urgency, title: r.title,
    ref: r.ref_system && r.ref_type && r.ref_id ? { system: r.ref_system, type: r.ref_type, id: r.ref_id } : null,
    byRule: r.rule_id !== null, createdAt: r.created_at.toISOString(),
    recipients: Number(r.recipients), delivered: Number(r.delivered), read: Number(r.read), acknowledged: Number(r.acknowledged),
    medianSecondsToRead: r.median_seconds_to_read === null ? null : Number(r.median_seconds_to_read),
    withdrawnAt: r.withdrawn_at ? r.withdrawn_at.toISOString() : null,
  };
}

// ---- Sources, markets, alert rules and linked accounts (addition 0008e): cma.sources, connection_config,
// connection_catalogs, markets_all, business_hours_all, business_holidays_all, message_rules,
// linked_account_systems, linked_accounts. Every write is an existing function of 0006 to 0008a; the
// values a write must pass back unchanged (secret names, routed and work type, kept fields) are read in
// the same transaction, never taken from the screen.

type SourceDbRow = {
  connection_id: string; key: string; adapter: string; name: string; external_account_id: string; kind: SourceKind | null;
  held_kinds: SourceKind[]; status: string; signing_secret_name: string | null; token_secret_name: string | null; settings: SourceSettings | null;
  events_24h: number; events_waiting: number; events_needs_review: number; last_event_at: Date | null;
  pipelines: number; forms: number; call_outcomes: number; fields: number; lines: number; tags: number; store_handle: string | null;
};

function toSource(r: SourceDbRow): SourceConnection {
  return {
    id: r.connection_id, key: r.key, adapter: r.adapter, name: r.name, accountId: r.external_account_id, kind: r.kind,
    heldKinds: r.held_kinds ?? [], isActive: r.status === "active", signingSecretName: r.signing_secret_name, tokenSecretName: r.token_secret_name,
    settings: r.settings ?? {}, events24h: r.events_24h, eventsWaiting: r.events_waiting, eventsParked: r.events_needs_review,
    lastEventAt: r.last_event_at ? r.last_event_at.toISOString() : null, pipelines: r.pipelines, forms: r.forms, callOutcomes: r.call_outcomes,
    fields: r.fields, lines: r.lines, tags: r.tags, storeHandle: r.store_handle,
  };
}

// ---- First orders (addition 0008u): the rows of cma.first_orders_report, first_orders_amounts, first_orders_list
// and first_orders_per_person; the page reads the first three in one (cma.first_orders_page, 0008x); numeric columns arrive as text
type FirstOrderDbRow = {
  period: string; dimension: string; group_key: string | null; first_orders: number; call_center: number; self_service: number; repeats: number;
  renewals: number; not_first: number; no_contact: number; with_touch: number; days_median: string | null;
};
function toFirstOrderFigures(r: FirstOrderDbRow | undefined): FirstOrderFigures {
  return {
    firstOrders: r?.first_orders ?? 0, callCenter: r?.call_center ?? 0, selfService: r?.self_service ?? 0, repeats: r?.repeats ?? 0,
    renewals: r?.renewals ?? 0, notFirst: r?.not_first ?? 0, noContact: r?.no_contact ?? 0, withTouch: r?.with_touch ?? 0, daysMedian: numOrNull(r?.days_median),
  };
}

function firstOrderRowsOf(rows: FirstOrderDbRow[], dimension: string): FirstOrderRow[] {
  return rows.filter((r) => r.period === "current" && r.dimension === dimension && r.group_key !== null)
    .map((r) => ({ groupKey: r.group_key!, ...toFirstOrderFigures(r) }));
}

/** The tenant's attribution settings; the catalog holds all five with their defaults (0008u), so a missing row is a database fault */
async function attributionSettings(q: Querier): Promise<AttributionSettings> {
  const r = await q.query<{ key: string; value: string }>(`select key, value from cma.tenant_settings() where key like 'attribution.%'`);
  const of = (k: string) => {
    const v = r.rows.find((x) => x.key === k)?.value;
    if (v === undefined) throw new Error(`tenant setting ${k} is missing from the catalog`);
    return v;
  };
  const list = (v: string) => (v === "" ? [] : (v.split(",") as FirstOrderEvidence[]));
  return {
    windowDays: Number(of("attribution.window_days")), levelOrder: list(of("attribution.level_order")), assistedLevels: list(of("attribution.assisted_levels")),
    knownContactMinutes: Number(of("attribution.known_contact_minutes")), orderMatchMinutes: Number(of("attribution.order_match_minutes")),
  };
}

/** One row of cma.callbacks_kept_report or its per-person read, as the database answers it */
interface CallbackKeptDbRow {
  period?: string; dimension?: string; week_start?: string | null; row_kind?: string; user_id?: string | null; display_name?: string | null;
  unlinked_owners?: number | null; callbacks: number; kept: number; not_kept: number; pending: number; no_contact: number; no_due?: number;
}

function toCallbackCounts(r: CallbackKeptDbRow | undefined): CallbackCounts {
  return { callbacks: r?.callbacks ?? 0, kept: r?.kept ?? 0, notKept: r?.not_kept ?? 0, pending: r?.pending ?? 0, noContact: r?.no_contact ?? 0, noDue: r?.no_due ?? 0 };
}

/** The tenant's active markets for the filter, then unknown */
async function marketCodes(q: Querier): Promise<string[]> {
  const r = await q.query<{ code: string }>(`select code from cma.market where status = 'active' order by sort_order, code`);
  return [...r.rows.map((x) => x.code), "unknown"];
}

type FirstOrderListDbRow = {
  connection_id: string; deal_source_id: string; market: string; created_at: Date; level: FirstOrderListRow["level"]; attribution: FirstOrderListRow["attribution"];
  lead_deal: boolean; conversation: boolean; email: boolean; phone_match: boolean; attempt: boolean; known_contact: boolean; phone_hashed: boolean;
  has_order: boolean; currency: string | null; amount: string | null; days_from_first_touch: string | null; record_url: string | null; total_rows: number;
};

/** One row of cma.first_orders_page: part 'report', 'amounts' or 'list'; the columns a part does not use are null */
type FirstOrderPageDbRow = FirstOrderDbRow & FirstOrderListDbRow & {
  part: string; orders: number; call_center_amount: string; self_service_amount: string;
};

function toFirstOrderListRow(x: FirstOrderListDbRow): FirstOrderListRow {
  return {
    connectionId: x.connection_id, dealSourceId: x.deal_source_id, market: x.market, createdAt: x.created_at.toISOString(), level: x.level, attribution: x.attribution,
    evidence: { lead_deal: x.lead_deal, conversation: x.conversation, email: x.email, phone_match: x.phone_match, attempt: x.attempt, known_contact: x.known_contact },
    phoneHashed: x.phone_hashed, hasOrder: x.has_order, currency: x.currency, amount: numOrNull(x.amount), daysFromFirstTouch: numOrNull(x.days_from_first_touch),
    recordUrl: x.record_url,
  };
}

type OrderPersonDbRow = {
  row_kind: string; user_id: string | null; display_name: string | null; unlinked_owners: number | null; orders: number; lead_deal: number;
  conversation: number; email: number; phone_match: number; other_levels: number; days_median: string | null;
};

function toOrderPerson(r: OrderPersonDbRow): OrderPerson {
  return {
    kind: r.row_kind === "not_linked" ? "notLinked" : r.row_kind === "total" ? "total" : "person", userId: r.user_id, name: r.display_name,
    unlinkedOwners: r.unlinked_owners, orders: r.orders, leadDeal: r.lead_deal, conversation: r.conversation, email: r.email, phoneMatch: r.phone_match,
    otherLevels: r.other_levels, daysMedian: numOrNull(r.days_median),
  };
}

async function readSource(q: Querier, id: string): Promise<SourceConnection> {
  const r = await q.query<SourceDbRow>(`select * from cma.sources() where connection_id = $1::uuid`, [id]);
  const row = r.rows[0];
  if (!row) throw new CmaDbError("CMA02", "no such connection in the current tenant");
  return toSource(row);
}

type ConfigJson = {
  fields: { entity: string; field: string; refSystem: string | null; slot: number; property: string }[];
  // additions 0008m and 0008t (a database before 0008t has no inboxAccounts)
  inboxes?: { inboxId: string; name: string; isCounted: boolean; market: string | null; status: string }[];
  inboxChannels?: { channelId: string; name: string; kind: string; isCounted: boolean; status: string }[];
  inboxAccounts?: { accountId: string; name: string; label: string | null; inboxId: string | null; channelId: string | null; isCounted: boolean;
    market: string | null; status: string }[];
  pipelines: { recordType: string; pipelineId: string; label: string; isCounted: boolean; isRouted: boolean; isLead: boolean; workType: string | null; status: string;
    // addition 0008u (a database before it has neither)
    isOrder?: boolean;
    stages?: { stageId: string; label: string; order: number; isClosed: boolean; outcome: "won" | "lost" | null; outcomeSource: "source" | "person" | null; status: string }[] }[];
  store: { handle: string; name: string; market: string; currency: string; timeZone: string } | null;
  writeback: { field: string; slot: number; property: string; mode: string; enabled: boolean }[];
};

type CatalogsJson = {
  forms: {
    formId: string; name: string; isCounted: boolean; leadSource: string | null; market: string | null; keptFields: string[]; status: string;
    // addition 0008p
    isPolled: boolean; category: string | null; marketField: string | null; leadCondition: { field: string; values: string[] } | null;
    fields: SourceFormField[];
  }[];
  callOutcomes: { outcomeRef: string; label: string; isConnected: boolean; status: string }[];
  lines: { lineRef: string; name: string; digits: string | null; market: string | null; isCounted: boolean; status: string }[];
  tags: { tagRef: string; name: string; isCounted: boolean; status: string }[];
  sampleIds: Record<string, string>;
};

async function readConfig(q: Querier, id: string): Promise<ConfigJson> {
  const r = await q.query<{ c: ConfigJson }>(`select cma.connection_config($1::uuid) as c`, [id]);
  return one(r.rows, "connection_config").c;
}

async function readCatalogs(q: Querier, id: string): Promise<CatalogsJson> {
  const r = await q.query<{ c: CatalogsJson }>(`select cma.connection_catalogs($1::uuid) as c`, [id]);
  return one(r.rows, "connection_catalogs").c;
}

function toPipeline(p: ConfigJson["pipelines"][number], slaMinutes: number | null = null): SourcePipeline {
  return {
    recordType: p.recordType, pipelineId: p.pipelineId, label: p.label, isCounted: p.isCounted, isRouted: p.isRouted, isLead: p.isLead, workType: p.workType,
    isActive: p.status === "active", slaMinutes, isOrder: p.isOrder ?? false,
    stages: (p.stages ?? []).map((x) => ({ stageId: x.stageId, label: x.label, isClosed: x.isClosed, outcome: x.outcome, outcomeSource: x.outcomeSource, isActive: x.status === "active" })),
  };
}

/** cma.connection_task_catalogs (addition 0008n): the task statuses and types a CRM connection has seen, with the configuration in force */
type TaskCatalogsJson = {
  statuses: { statusRef: string; label: string; isDone: boolean; seenTasks: number; lastSeenAt: string | null }[];
  types: { typeRef: string; label: string; isCallback: boolean; isCounted: boolean; seenTasks: number; openTasks: number; lastSeenAt: string | null }[];
  sampleTaskId: string | null;
};

// ---- Follow-up (addition 0008o): the rows of cma.open_leads, open_tickets and open_tasks, each joined with the
// owner's name (app_user, the same tenant) and the record link; the JSON of cma.my_follow_up has the same keys
// as text. Dates arrive as Date from a query and as text from JSON.
const isoAny = (v: Date | string | null | undefined): string | null => (v === null || v === undefined ? null : new Date(v).toISOString());

type OpenLeadDb = {
  deal_id: string; connection_id: string; deal_source_id: string; pipeline_id: string; pipeline_label: string; owner_user_id: string | null; owner_ref: string | null;
  market: string; created_at: Date | string; waiting_business_seconds: number | null; age_business_days: number | null; bucket_from: number | null; bucket_to: number | null;
  past_target: boolean | null; last_call_at: Date | string | null; last_call_days: number | null; owner_name?: string | null; record_url: string | null;
};
type OpenTicketDb = {
  ticket_id: string; connection_id: string; ticket_source_id: string; pipeline_id: string; pipeline_label: string; stage_id: string | null; stage_label: string | null;
  owner_user_id: string | null; owner_ref: string | null; market: string; created_at: Date | string; open_business_seconds: number | null; sla_minutes: number;
  sla_state: SlaState; minutes_to_breach: number | null; owner_name?: string | null; record_url: string | null;
};
type OpenTaskDb = {
  task_id: string; connection_id: string; task_source_id: string; type_ref: string; type_label: string; is_callback: boolean; priority_ref: string | null;
  status_ref: string; status_label: string; owner_user_id: string | null; owner_ref: string | null; market: string | null; due_at: Date | string | null;
  due_state: DueState; record_type: "deal" | "ticket" | null; record_source_id: string | null; created_at: Date | string; owner_name?: string | null; record_url: string | null;
};

function toOpenLead(r: OpenLeadDb, ownerName: string | null = r.owner_name ?? null): OpenLead {
  return {
    dealId: r.deal_id, connectionId: r.connection_id, dealSourceId: r.deal_source_id, pipelineId: r.pipeline_id, pipelineLabel: r.pipeline_label,
    ownerUserId: r.owner_user_id, ownerName: r.owner_user_id === null ? null : ownerName, ownerRef: r.owner_ref, market: r.market, createdAt: isoAny(r.created_at)!,
    waitingBusinessSeconds: r.waiting_business_seconds, ageBusinessDays: r.age_business_days, bucketFrom: r.bucket_from, bucketTo: r.bucket_to,
    pastTarget: r.past_target, lastCallAt: isoAny(r.last_call_at), lastCallDays: r.last_call_days, recordUrl: r.record_url,
  };
}

function toOpenTicket(r: OpenTicketDb, ownerName: string | null = r.owner_name ?? null): OpenTicket {
  return {
    ticketId: r.ticket_id, connectionId: r.connection_id, ticketSourceId: r.ticket_source_id, pipelineId: r.pipeline_id, pipelineLabel: r.pipeline_label,
    stageId: r.stage_id, stageLabel: r.stage_label, ownerUserId: r.owner_user_id, ownerName: r.owner_user_id === null ? null : ownerName, ownerRef: r.owner_ref,
    market: r.market, createdAt: isoAny(r.created_at)!, openBusinessSeconds: r.open_business_seconds, slaMinutes: r.sla_minutes, slaState: r.sla_state,
    minutesToBreach: r.minutes_to_breach, recordUrl: r.record_url,
  };
}

function toOpenTask(r: OpenTaskDb, ownerName: string | null = r.owner_name ?? null): OpenTask {
  return {
    taskId: r.task_id, connectionId: r.connection_id, taskSourceId: r.task_source_id, typeRef: r.type_ref, typeLabel: r.type_label, isCallback: r.is_callback,
    priorityRef: r.priority_ref, statusRef: r.status_ref, statusLabel: r.status_label, ownerUserId: r.owner_user_id,
    ownerName: r.owner_user_id === null ? null : ownerName, ownerRef: r.owner_ref, market: r.market, dueAt: isoAny(r.due_at), dueState: r.due_state,
    recordType: r.record_type, recordSourceId: r.record_source_id, createdAt: isoAny(r.created_at)!, recordUrl: r.record_url,
  };
}

type SummaryDb = {
  leads_open_not_called: number; leads_past_target: number; tickets_at_risk: number; tickets_breached: number;
  tickets_without_owner: number; tasks_overdue: number; tasks_due_today: number; tasks_unmapped_owner: number;
};
function toSummary(x: SummaryDb): FollowUpSummary {
  return {
    leadsOpenNotCalled: x.leads_open_not_called, leadsPastTarget: x.leads_past_target, ticketsAtRisk: x.tickets_at_risk, ticketsBreached: x.tickets_breached,
    ticketsWithoutOwner: x.tickets_without_owner, tasksOverdue: x.tasks_overdue, tasksDueToday: x.tasks_due_today, tasksUnmappedOwner: x.tasks_unmapped_owner,
  };
}
type OwnerDb = {
  owner_user_id: string | null; display_name: string | null; open_leads: number; leads_past_target: number; open_tickets: number;
  tickets_at_risk_or_breached: number; tasks_overdue: number; tasks_due_today: number;
};
function toOwner(x: OwnerDb): FollowUpOwner {
  return {
    ownerUserId: x.owner_user_id, displayName: x.display_name, openLeads: x.open_leads, leadsPastTarget: x.leads_past_target, openTickets: x.open_tickets,
    ticketsAtRiskOrBreached: x.tickets_at_risk_or_breached, tasksOverdue: x.tasks_overdue, tasksDueToday: x.tasks_due_today,
  };
}
// ---- Attempts per deal (addition 0008y; for sales since 0008z): cma.attempts_per_deal_page and attempts_per_person_page answer one
// JSON object each, snake_case keys, numbers as numbers (the averages and medians as JSON numbers), times as ISO text
type AttemptFiguresDb = {
  deals: number; attempted: number; attempts: number; avg_attempts: number | null; median_attempts: number | null; reached_deals: number;
  first_reached: number; reached_attempts: number; speed_deals: number; median_speed_seconds: number | null; noon_known: number;
  called_before_noon: number; open_deals: number; open_never_attempted: number; won: number; lost: number; ordered: number; unknown: number;
  talk_seconds_total: number; talk_seconds_reached: number; attempts_without_outcome: number; logged_without_aircall: number;
};
type AttemptListDb = {
  deal_id: string; connection_id: string; deal_source_id: string; record_url: string | null; pipeline_label: string | null; stage_label: string | null;
  market: string; created_at: string; closed_at: string | null; ordered_at: string | null; window_end_reason: AttemptListRow["windowEndReason"];
  outcome: AttemptListRow["outcome"]; attempts: number; reached_attempts: number; first_reached_attempt: number | null; talk_seconds_total: number;
  talk_seconds_reached: number; first_attempt_at: string | null; speed_to_lead_seconds: number | null; called_before_next_noon: boolean | null;
  last_attempt_at: string | null; business_days_since_last: number | null; since_last_bucket: string | null; logged_without_aircall: number;
};
type AttemptsCommonDb = {
  markets: string[]; pipelines: { key: string; label: string }[]; history_start: string | null;
  settings: {
    max_bucket: number; since_last_buckets: string; pre_window_minutes: number; list_rows: number; source: AttemptSettings["source"];
    reached_min_talk_seconds: number; speed_buckets: string;
  };
};
type AttemptOutcomeDb = {
  outcome: "won" | "lost"; deals: number; avg_attempts: number | null; median_attempts: number | null; speed_deals: number;
  median_speed_seconds: number | null; noon_known: number; called_before_noon: number; reached_deals: number; avg_talk_reached_seconds: number | null;
};
type AttemptsPageDb = AttemptsCommonDb & {
  current: AttemptFiguresDb; previous: AttemptFiguresDb;
  buckets: { bucket: number; label: string; deals: number; first_reached: number; won: number; lost: number }[];
  outcomes: { rows: AttemptOutcomeDb[]; not_decided: number; open: number; ordered: number; unknown: number };
  speed_buckets: { buckets: { from: number; to: number | null; label: string; won: number; lost: number }[]; none: { won: number; lost: number }; no_hours: number };
  groups: (AttemptFiguresDb & { key: string; label: string | null })[];
  since_last: { buckets: { from: number; to: number | null; label: string; deals: number }[]; no_hours: number };
  list: { total: number; rows: AttemptListDb[] };
};
type AttemptsPersonDb = AttemptsCommonDb & {
  rows: (AttemptFiguresDb & { user_id: string; display_name: string | null })[];
  not_linked: (AttemptFiguresDb & { unlinked_owners: number }) | null;
  total: AttemptFiguresDb;
};
type DealAttemptDb = {
  n: number; started_at: Date; answered: boolean; talk_seconds: number | null; reached: boolean; reached_by: DealAttempt["reachedBy"];
  outcome_label: string | null; agent_name: string | null;
};
/** An instant as ISO text in UTC, from the JSON's timestamptz text */
const isoOf = (v: string | null): string | null => (v === null ? null : new Date(v).toISOString());
function toAttemptFigures(x: AttemptFiguresDb): AttemptFigures {
  return {
    deals: x.deals, attempted: x.attempted, attempts: x.attempts, avgAttempts: numOrNull(x.avg_attempts), medianAttempts: numOrNull(x.median_attempts),
    reachedDeals: x.reached_deals, firstReached: x.first_reached, reachedAttempts: x.reached_attempts, speedDeals: x.speed_deals,
    medianSpeedSeconds: numOrNull(x.median_speed_seconds), noonKnown: x.noon_known, calledBeforeNoon: x.called_before_noon,
    openDeals: x.open_deals, openNeverAttempted: x.open_never_attempted, won: x.won, lost: x.lost, ordered: x.ordered, unknown: x.unknown,
    talkSecondsTotal: x.talk_seconds_total, talkSecondsReached: x.talk_seconds_reached, attemptsWithoutOutcome: x.attempts_without_outcome,
    loggedWithoutAircall: x.logged_without_aircall,
  };
}
function toAttemptSettings(x: AttemptsCommonDb["settings"]): AttemptSettings {
  return {
    maxBucket: x.max_bucket, sinceLastBuckets: x.since_last_buckets, preWindowMinutes: x.pre_window_minutes, listRows: x.list_rows, source: x.source,
    reachedMinTalkSeconds: x.reached_min_talk_seconds, speedBuckets: x.speed_buckets,
  };
}
function toAttemptListRow(x: AttemptListDb): AttemptListRow {
  return {
    dealId: x.deal_id, connectionId: x.connection_id, dealSourceId: x.deal_source_id, recordUrl: x.record_url, pipelineLabel: x.pipeline_label,
    stageLabel: x.stage_label, market: x.market, createdAt: isoOf(x.created_at)!, closedAt: isoOf(x.closed_at), orderedAt: isoOf(x.ordered_at),
    windowEndReason: x.window_end_reason, outcome: x.outcome, attempts: x.attempts, reachedAttempts: x.reached_attempts,
    firstReachedAttempt: x.first_reached_attempt, talkSecondsTotal: x.talk_seconds_total, talkSecondsReached: x.talk_seconds_reached,
    firstAttemptAt: isoOf(x.first_attempt_at), speedToLeadSeconds: x.speed_to_lead_seconds, calledBeforeNextNoon: x.called_before_next_noon,
    lastAttemptAt: isoOf(x.last_attempt_at), businessDaysSinceLast: x.business_days_since_last, sinceLastBucket: x.since_last_bucket,
    loggedWithoutAircall: x.logged_without_aircall,
  };
}
function toAttemptOutcomeRow(x: AttemptOutcomeDb): AttemptOutcomeRow {
  return {
    outcome: x.outcome, deals: x.deals, avgAttempts: numOrNull(x.avg_attempts), medianAttempts: numOrNull(x.median_attempts), speedDeals: x.speed_deals,
    medianSpeedSeconds: numOrNull(x.median_speed_seconds), noonKnown: x.noon_known, calledBeforeNoon: x.called_before_noon,
    reachedDeals: x.reached_deals, avgTalkReachedSeconds: numOrNull(x.avg_talk_reached_seconds),
  };
}

/** cma.follow_up_page's JSON (addition 0008s): snake_case keys, numbers as numbers, settings as text */
type FollowUpPageDb = {
  computed_at: string; duration_ms: number; rows: number; summary: SummaryDb; by_owner: OwnerDb[] | null;
  options: { markets: string[]; owners: { id: string; name: string | null }[]; has_unowned: boolean };
  settings: { target_minutes: string | null; warning_pct: string | null };
  counts: { lead?: number; ticket?: number; task?: number };
  leads: { total: number; rows: OpenLeadDb[] }; tickets: { total: number; rows: OpenTicketDb[] }; tasks: { total: number; rows: OpenTaskDb[] };
};
const wholeOrNull = (v: string | null | undefined): number | null => (v !== null && v !== undefined && /^\d+$/.test(v) ? Number(v) : null);

/** The owner's name joined in: the application reads app_user under row-level security, so only this tenant's people */
const OWNER_JOIN = `left join cma.app_user u on u.tenant_id = r.tenant_id and u.id = r.owner_user_id`;

/** When the snapshot the list was just read from was computed (a second statement in the list's transaction) */
async function computedAt(q: Querier): Promise<string> {
  return one((await q.query<{ at: Date }>(`select cma.follow_up_computed_at() as at`)).rows, "follow_up_computed_at").at.toISOString();
}

type MarketDbRow = {
  code: string; name: string; time_zone: string; language_code: string; language_skill_key: string | null; min_language_level: number | null;
  currency: string; status: string; sort_order: number; aliases: string[];
};

function toMarket(r: MarketDbRow): MarketConfig {
  return {
    code: r.code, name: r.name, timeZone: r.time_zone, languageCode: r.language_code, languageSkillKey: r.language_skill_key,
    minLanguageLevel: r.min_language_level, currency: r.currency, isActive: r.status === "active", sortOrder: r.sort_order, aliases: r.aliases ?? [],
  };
}

type RuleDbRow = {
  rule_id: string; name: string; trigger: AlertRule["trigger"]; record_type: string; pipeline_ids: string[]; audience_permission: string;
  match_language: boolean; only_clocked_in: boolean; fallback_permission: string | null; urgency: AlertRule["urgency"]; enabled: boolean;
  max_age_minutes: number | null; alerts_30d: number; last_alert_at: Date | null;
};

function toRule(r: RuleDbRow): AlertRule {
  return {
    id: r.rule_id, name: r.name, trigger: r.trigger, recordType: r.record_type, pipelineIds: r.pipeline_ids ?? [], audiencePermission: r.audience_permission,
    matchLanguage: r.match_language, onlyClockedIn: r.only_clocked_in, fallbackPermission: r.fallback_permission, urgency: r.urgency, enabled: r.enabled,
    maxAgeMinutes: r.max_age_minutes, alerts30d: r.alerts_30d, lastAlertAt: r.last_alert_at ? r.last_alert_at.toISOString() : null,
  };
}

async function readRules(q: Querier): Promise<AlertRule[]> {
  return (await q.query<RuleDbRow>(`select * from cma.message_rules()`)).rows.map(toRule);
}

export const postgresData: CmaData = {
  async findPrincipal(identity: Identity): Promise<Principal | null> {
    // One transaction for both steps (the IT audit of 17 October 2026: identity cost two checkouts and two
    // begin/commit pairs on every request). 1. Before a tenant is known: the one SECURITY DEFINER lookup,
    // tenant ids only. 2. The tenant context, set as withTenant sets it (set_config(…, true) is transaction-
    // local), then the app_user check as cma_app under row-level security. The same two statements as before.
    return withoutTenant(async (q) => {
      const tenants = await q.query<{ tenant_id: string }>(
        "select tenant_id from cma.find_tenants_for_identity($1, $2)",
        [identity.provider, identity.subject],
      );
      const match = tenants.rows[0];
      if (!match) return null;
      if (tenants.rows.length > 1) {
        // No tenant picker yet; never guess. Count only: the subject is a personal identifier.
        console.warn(`[cma-data] identity (${identity.provider}) matches ${tenants.rows.length} tenants; no tenant picker yet`);
        return null;
      }
      const tenantId = match.tenant_id;
      await q.query(
        `select set_config('app.tenant_id', $1, true), set_config('app.user_id', '', true), set_config('app.actor_label', '', true)`,
        [tenantId],
      );
      const r = await q.query<{
        user_id: string;
        display_name: string;
        tenant_name: string;
        organisation_name: string;
        time_zone: string;
        role_key: string | null;
        permissions: string[];
        per_person: string[] | null;
      }>(
        `select u.id                         as user_id,
                u.display_name,
                t.name                       as tenant_name,
                coalesce(o.name, '')         as organisation_name,
                cma.user_timezone(u.id)      as time_zone,
                -- earliest grant: deterministic without ranking role keys (no hardcoded ladder)
                (select r.key
                   from cma.user_role ur
                   join cma.app_role r on r.tenant_id = ur.tenant_id and r.id = ur.role_id
                  where ur.tenant_id = u.tenant_id and ur.user_id = u.id
                  order by ur.granted_at, r.key
                  limit 1)                   as role_key,
                array(select p from cma.user_permissions(u.id) p order by 1) as permissions,
                -- the per-person report pages switched on (addition 0008t); a catalog without the setting reads none
                (select string_to_array(nullif(s.value, ''), ',') from cma.tenant_settings() s where s.key = 'reports.per_person') as per_person
           from cma.app_user_external_id x
           join cma.app_user u      on u.tenant_id = x.tenant_id and u.id = x.user_id
           join cma.tenant t        on t.id = u.tenant_id
           left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
          where x.tenant_id   = cma.current_tenant_id()
            and x.system      = $1
            and x.external_id = $2
            and u.status      = 'active'`,
        [identity.provider, identity.subject],
      );
      const row = r.rows[0];
      // No row: no active person for the id in that tenant. No role: may not work yet. Both: no access yet.
      if (!row || !row.role_key) return null;
      return {
        tenantId,
        tenantName: row.tenant_name,
        userId: row.user_id,
        displayName: row.display_name,
        organisationName: row.organisation_name,
        roleKey: row.role_key,
        permissions: row.permissions,
        locale: config.defaultLocale,
        timeZone: row.time_zone,
        // getAccess() computes both from the real permissions and the preview cookie
        preview: null,
        canPreview: false,
        perPerson: (row.per_person ?? []).filter((k) => k === "email" || k === "orders" || k === "attempts"),
      };
    });
  },

  async startWorkday(me: Principal): Promise<Workday> {
    // Clock in: today's day, open or ended, created if needed; an ended day stays ended. The
    // database creates a day only for someone whose time is kept (0003d, CMA06 otherwise) and not
    // before the workday window starts (0008b, CMA04 "the workday starts at HH:MI"): that refusal
    // keeps its own text, so the screen can say when the day starts
    try {
      return await withTenant(ctx(me), async (q) => {
        const opened = await q.query<{ business_date: string }>(`select business_date from cma.open_workday()`);
        const date = one(opened.rows, "open_workday").business_date;
        return toWorkday(one(await readDay(q, "$1::date", [date]), "open_workday"));
      });
    } catch (e) {
      const startsAt = e instanceof CmaDbError && e.sqlState === "CMA04" ? workdayStartsAt(e.detail) : null;
      throw startsAt ? new CmaDbError("CMA04", `the workday starts at ${startsAt}`) : e;
    }
  },

  async getWorkday(me: Principal, date: DateKey): Promise<Workday | null> {
    assertDate(date, "date");
    return withTenant(ctx(me), async (q) => {
      const row = (await readDay(q, "$1::date", [date]))[0];
      return row ? toWorkday(row) : null;
    });
  },

  async endWorkday(me: Principal): Promise<Workday> {
    return withTenant(ctx(me), async (q) => {
      // Lock today's own row so two tabs cannot both end it
      const today = await q.query<{ id: string; status: "open" | "ended" }>(
        `select id, status from cma.workday
          where tenant_id = cma.current_tenant_id() and ${OWN} and business_date = ${TODAY}
          for update`,
      );
      const w = today.rows[0];
      if (!w) throw new CmaDbError("CMA02", "no workday today");
      // Same as the mock: ending an ended day returns it, so a repeated log out is harmless
      if (w.status !== "ended") await q.query(`select 1 from cma.end_workday($1)`, [w.id]);
      return toWorkday(one(await readDay(q, TODAY, []), "end_workday"));
    });
  },

  async listStatuses(me: Principal): Promise<WorkStatus[]> {
    return withTenant(ctx(me), async (q) => {
      // Pay and billing flags stay out: not agent information (decision of 6 October 2026)
      const r = await q.query<{ key: string; name: string; is_working: boolean; is_productive: boolean; is_default: boolean }>(
        `select key, name, is_working, is_productive, is_default
           from cma.work_status
          where tenant_id = cma.current_tenant_id() and status = 'active'
          order by sort_order, key`,
      );
      return r.rows.map((s) => ({
        key: s.key, name: s.name, isWorking: s.is_working, isProductive: s.is_productive, isDefault: s.is_default,
      }));
    });
  },

  async setStatus(me: Principal, key: string): Promise<Workday> {
    return withTenant(ctx(me), async (q) => {
      // Today's own day; set_status locks it and enforces own day, not ended, active key
      const today = await q.query<{ id: string }>(
        `select id from cma.workday
          where tenant_id = cma.current_tenant_id() and ${OWN} and business_date = ${TODAY}`,
      );
      const w = today.rows[0];
      if (!w) throw new CmaDbError("CMA02", "no workday today");
      await q.query(`select 1 from cma.set_status($1, $2)`, [w.id, key]);
      return toWorkday(one(await readDay(q, TODAY, []), "set_status"));
    });
  },

  async getHours(me: Principal, range: HoursRange): Promise<HoursSummary> {
    assertDate(range.from, "from");
    assertDate(range.to, "to");
    return withTenant(ctx(me), async (q) => {
      // Pauses: the day's seconds in non-working statuses, the complement of working time within the day
      const r = await q.query<SummaryRow & { pause_seconds: number }>(
        `select ${HEADER}, s.working_seconds,
                coalesce((select sum(i.seconds) from cma.time_interval i
                            join cma.work_status ws on ws.tenant_id = cma.current_tenant_id() and ws.id = i.status_id
                           where i.workday_id = s.workday_id and not ws.is_working), 0)::bigint as pause_seconds
           from cma.workday_summary s
          where s.${OWN} and s.business_date between $1::date and $2::date
          order by s.business_date`,
        [range.from, range.to],
      );
      const days = r.rows.map((row) => ({
        date: row.business_date,
        minutes: minutesOf(row),
        pauseMinutes: Math.floor(Number(row.pause_seconds) / 60),
        startedAt: row.started_at.toISOString(),
        endedAt: row.ended_at ? row.ended_at.toISOString() : null,
      }));
      return { ...range, days, totalMinutes: days.reduce((sum, d) => sum + d.minutes, 0) };
    });
  },

  async getTeamHours(me, range, userId) {
    assertDate(range.from, "from");
    assertDate(range.to, "to");
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<TeamRow>(
        `select * from cma.team_hours($1::date, $2::date, $3::uuid)`,
        [range.from, range.to, userId],
      );
      return { ...range, days: r.rows.map(toTeamDay) };
    });
  },

  async listTeamPeople(me): Promise<TeamPerson[]> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{ user_id: string; display_name: string; organisation_name: string; timezone: string }>(
        `select * from cma.team_people()`,
      );
      return r.rows.map((p) => ({
        userId: p.user_id,
        displayName: p.display_name,
        organisationName: p.organisation_name,
        timeZone: p.timezone,
      }));
    });
  },

  async getTeamDay(me, userId, date) {
    assertDate(date, "date");
    return withTenant(ctx(me), (q) => readTeamDay(q, userId, date));
  },

  async correctWorkday(me, userId, date, correction) {
    assertDate(date, "date");
    return withTenant(ctx(me), async (q) => {
      // The function validates everything again; the route's checks only give clearer 400s
      await q.query(`select 1 from cma.correct_workday($1::uuid, $2::date, $3::jsonb, $4)`, [
        userId,
        date,
        JSON.stringify(correction.changes),
        correction.reason,
      ]);
      // A new statement sees the edit (one transaction, read committed)
      return readTeamDay(q, userId, date);
    });
  },

  async listSettings(me) {
    return withTenant(ctx(me), (q) => readSettings(q));
  },

  async exportHours(me, range, userId) {
    assertDate(range.from, "from");
    assertDate(range.to, "to");
    return withTenant(ctx(me), async (q) => {
      // The export function first: without workday.export it refuses before anything else is read
      const r = await q.query<ExportHoursDbRow>(
        `select * from cma.export_hours($1::date, $2::date, $3::uuid)`,
        [range.from, range.to, userId],
      );
      return { settings: await readSettings(q), rows: r.rows.map(toExportHoursRow) };
    });
  },

  async exportStatusChanges(me, range, userId) {
    assertDate(range.from, "from");
    assertDate(range.to, "to");
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<StatusChangeDbRow>(
        `select * from cma.export_status_changes($1::date, $2::date, $3::uuid)`,
        [range.from, range.to, userId],
      );
      return { settings: await readSettings(q), rows: r.rows.map(toStatusChangeRow) };
    });
  },

  // Addition 0003c: the permission (performance.team) is checked inside the function, in the same
  // transaction as the read
  async getTeamStatusTime(me, range, userId) {
    assertDate(range.from, "from");
    assertDate(range.to, "to");
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<StatusTimeDbRow>(
        `select * from cma.team_status_time($1::date, $2::date, $3::uuid)`,
        [range.from, range.to, userId],
      );
      return { ...range, rows: r.rows.map(toStatusTimeRow) };
    });
  },

  // Addition 0003e: team_now() checks monitoring.live and raises CMA06 otherwise, so the plain read
  // of the status flags that follows runs only in a transaction where the check already passed
  async getTeamNow(me): Promise<TeamNow> {
    return withTenant(ctx(me), async (q) => {
      // The day's end per person (0008b), so a day on the board carries the same field as the own day
      const r = await q.query<TeamNowDbRow>(`select n.*, cma.business_day_end(n.business_date, n.timezone) as day_ends_at from cma.team_now() n`);
      const flags = await q.query<{ is_working: boolean; is_productive: boolean; is_paid: boolean }>(
        `select is_working, is_productive, is_paid from cma.work_status where status = 'active' order by sort_order, key`,
      );
      return {
        people: r.rows.map(toTeamNowPerson),
        statusFlags: flags.rows.map((f) => ({ isWorking: f.is_working, isProductive: f.is_productive, isPaid: f.is_paid })),
      };
    });
  },

  // Addition 0003d: the function filters on the acting user's permissions, so a link that needs
  // one never reaches a screen that would have to hide it
  async listAppLinks(me): Promise<AppLink[]> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{ key: string; label: string; address: string }>(`select key, label, address from cma.app_links()`);
      return r.rows.map((l) => ({ key: l.key, label: l.label, address: l.address }));
    });
  },

  async listTeamMembersNow(me): Promise<TeamMembership[]> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{ user_id: string; team_key: string; team_name: string }>(`select * from cma.team_members_now()`);
      return r.rows.map((m) => ({ userId: m.user_id, teamKey: m.team_key, teamName: m.team_name }));
    });
  },

  async listDirectory(me): Promise<DirectoryPerson[]> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<DirectoryDbRow>(`select * from cma.directory()`);
      return r.rows.map(toDirectoryPerson);
    });
  },

  async listRoles(me): Promise<RoleInfo[]> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{ key: string; name: string; is_system: boolean; is_managing: boolean; assignable: boolean; permissions: string[] }>(
        `select * from cma.roles()`,
      );
      return r.rows.map((x) => ({
        key: x.key, name: x.name, isSystem: x.is_system, isManaging: x.is_managing, assignable: x.assignable, permissions: x.permissions,
      }));
    });
  },

  async listTeams(me): Promise<TeamInfo[]> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{ key: string; name: string; markets: string[]; sort_order: number; member_count: number }>(`select * from cma.teams()`);
      return r.rows.map((x) => ({ key: x.key, name: x.name, markets: x.markets, sortOrder: x.sort_order, memberCount: x.member_count }));
    });
  },

  async listOrganisations(me): Promise<OrganisationInfo[]> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{ key: string; name: string; timezone: string }>(`select * from cma.organisations()`);
      return r.rows.map((o) => ({ key: o.key, name: o.name, timeZone: o.timezone }));
    });
  },

  async listSkills(me): Promise<SkillInfo[]> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{ dimension: SkillInfo["dimension"]; key: string; name: string; sort_order: number; status: string; levels: { level: number; name: string }[] }>(
        `select * from cma.skills()`,
      );
      return r.rows.map((x) => ({
        dimension: x.dimension, key: x.key, name: x.name, sortOrder: x.sort_order, isActive: x.status === "active", levels: x.levels ?? [],
      }));
    });
  },

  async addPerson(me, input): Promise<string> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{ id: string }>(
        `select cma.add_person($1, $2, $3, $4, $5, $6, $7) as id`,
        [input.email, input.displayName, input.organisationKey, input.roleKey, input.loginSystem, input.loginId, input.timeZone],
      );
      return one(r.rows, "add_person").id;
    });
  },

  async setPersonRole(me, userId, roleKey): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select cma.set_person_role($1::uuid, $2)`, [userId, roleKey]));
  },

  async setPersonActive(me, userId, active): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select cma.set_person_active($1::uuid, $2)`, [userId, active]));
  },

  async setPersonTeams(me, userId, teamKeys): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select 1 from cma.set_person_teams($1::uuid, $2::text[])`, [userId, teamKeys]));
  },

  async setPersonSkills(me, userId, skills): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select 1 from cma.set_person_skills($1::uuid, $2::jsonb)`, [userId, JSON.stringify(skills)]));
  },

  // ---- Invitations (addition 0008l): the people rule and the role ceiling inside every function (CMA06) ----

  async listInvitations(me): Promise<Invitation[]> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<InvitationDbRow>(`select * from cma.invitations()`);
      return r.rows.map(invitationFromDb);
    });
  },

  async createInvitation(me, input): Promise<InvitationLink> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{ invitation_id: string; token: string; expires_at: Date }>(
        `select * from cma.create_invitation($1, $2, $3, $4, $5, $6::text[], $7::jsonb)`,
        [input.email, input.displayName, input.locale, input.roleKey, input.organisationKey, input.teamKeys, JSON.stringify(input.skills)],
      );
      const row = one(r.rows, "create_invitation");
      return { invitationId: row.invitation_id, token: row.token, expiresAt: row.expires_at.toISOString() };
    });
  },

  async renewInvitation(me, invitationId): Promise<InvitationLink> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{ invitation_id: string; token: string; expires_at: Date }>(
        `select * from cma.renew_invitation($1::uuid)`, [invitationId]);
      const row = one(r.rows, "renew_invitation");
      return { invitationId: row.invitation_id, token: row.token, expiresAt: row.expires_at.toISOString() };
    });
  },

  async revokeInvitation(me, invitationId): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select cma.revoke_invitation($1::uuid)`, [invitationId]));
  },

  // The invitee is no person yet: both run without a tenant, through the owner's two functions, which find
  // the invitation by the token's hash and act on its tenant only (a token of another shape finds nothing)
  async previewInvitation(identity, token): Promise<InvitationPreview> {
    if (!INVITE_TOKEN_RE.test(token)) return { result: "invalid", tenantName: null, roleName: null, invitedEmail: null, locale: null, expiresAt: null };
    const r = await withoutTenant((q) =>
      q.query<{ result: InvitationPreview["result"]; tenant_name: string | null; role_name: string | null; invited_email: string | null; locale: string | null; expires_at: Date | null }>(
        `select * from cma.invitation_preview($1, $2, $3, $4)`,
        [token, identity.provider, identity.subject, identity.email],
      ));
    const row = one(r.rows, "invitation_preview");
    return {
      result: row.result, tenantName: row.tenant_name, roleName: row.role_name, invitedEmail: row.invited_email,
      locale: row.locale, expiresAt: iso(row.expires_at),
    };
  },

  async acceptInvitation(identity, token): Promise<InvitationAcceptResult> {
    if (!INVITE_TOKEN_RE.test(token)) return "invalid";
    const r = await withoutTenant((q) =>
      q.query<{ result: InvitationAcceptResult }>(
        `select result from cma.accept_invitation($1, $2, $3, $4)`,
        [token, identity.provider, identity.subject, identity.email],
      ));
    return one(r.rows, "accept_invitation").result;
  },

  // ---- Configuration (migration 0005a): every function checks tenant.configure inside (CMA06) ----

  async listConfigStatuses(me): Promise<ConfigStatus[]> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{ key: string; name: string; is_working: boolean; is_productive: boolean; is_paid: boolean; is_billable: boolean;
                                 is_default: boolean; sort_order: number; status: string; usage_count: number }>(`select * from cma.work_statuses_all()`);
      return r.rows.map((x) => ({
        key: x.key, name: x.name, isWorking: x.is_working, isProductive: x.is_productive, isPaid: x.is_paid, isBillable: x.is_billable,
        isDefault: x.is_default, sortOrder: x.sort_order, isActive: x.status === "active", usageCount: x.usage_count,
      }));
    });
  },

  async upsertConfigStatus(me, input): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select cma.upsert_work_status($1, $2, $3, $4, $5, $6, $7)`,
      [input.key, input.name, input.isWorking, input.isProductive, input.isPaid, input.isBillable, input.sortOrder]));
  },

  async setDefaultStatus(me, key): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select cma.set_default_work_status($1)`, [key]));
  },

  async retireStatus(me, key): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select cma.retire_work_status($1)`, [key]));
  },

  async listConfigAppLinks(me): Promise<ConfigAppLink[]> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{ key: string; label: string; address: string; permission_key: string | null; sort_order: number; status: string }>(
        `select * from cma.app_links_all()`);
      return r.rows.map((x) => ({ key: x.key, label: x.label, address: x.address, permissionKey: x.permission_key, sortOrder: x.sort_order, isActive: x.status === "active" }));
    });
  },

  async upsertAppLink(me, input): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select cma.upsert_app_link($1, $2, $3, $4, $5)`,
      [input.key, input.label, input.address, input.permissionKey, input.sortOrder]));
  },

  async retireAppLink(me, key): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select cma.retire_app_link($1)`, [key]));
  },

  async listPermissions(me): Promise<PermissionInfo[]> {
    return withTenant(ctx(me), async (q) => {
      // The catalog is defined by migrations, not tenant data; the list is read after the links'
      // own permission check, in the same transaction, so only a configurer sees it
      await q.query(`select 1 from cma.app_links_all() limit 1`);
      const r = await q.query<{ key: string; description: string }>(`select key, description from cma.permission order by key`);
      return r.rows;
    });
  },

  async upsertAbsenceType(me, input): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select cma.upsert_absence_type($1, $2, $3, $4, 'active')`, [input.key, input.name, input.isPaid, input.sortOrder]));
  },

  async retireAbsenceType(me, key): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select cma.retire_absence_type($1)`, [key]));
  },

  async listCoverageTargets(me): Promise<CoverageTargetRow[]> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{ team_key: string; skill_key: string; weekday: number; min_count: number }>(`select * from cma.coverage_targets_all()`);
      return r.rows.map((x) => ({ teamKey: x.team_key, skillKey: x.skill_key, weekday: x.weekday, minCount: x.min_count }));
    });
  },

  async setCoverageTarget(me, teamKey, skillKey, weekday, minCount): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select cma.set_coverage_target($1, $2, $3::smallint, $4)`, [teamKey, skillKey, weekday, minCount && minCount > 0 ? minCount : null]));
  },

  async upsertTeam(me, input): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select cma.upsert_team($1, $2, $3::text[], $4)`, [input.key, input.name, input.markets, input.sortOrder]));
  },

  async dissolveTeam(me, key): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select cma.dissolve_team($1)`, [key]));
  },

  async upsertSkill(me, input, active): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select cma.upsert_skill($1, $2, $3, $4, $5)`, [input.dimension, input.key, input.name, input.sortOrder, active ? "active" : "inactive"]));
  },

  async setSkillLevels(me, dimension, levels): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select 1 from cma.set_skill_levels($1, $2::jsonb)`, [dimension, JSON.stringify(levels)]));
  },

  async setTenantSetting(me, key, value): Promise<TenantSetting> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{ key: string; value: string; is_default: boolean }>(`select * from cma.set_tenant_setting($1, $2)`, [key, value]);
      const x = one(r.rows, "set_tenant_setting");
      return { key: x.key, value: x.value, isDefault: x.is_default };
    });
  },

  async getRosterWeek(me, weekStart, teamKey): Promise<RosterWeek> {
    assertDate(weekStart, "weekStart");
    return withTenant(ctx(me), async (q) => {
      // The header first: its permission check decides the rest of the transaction
      const header = await readRosterHeader(q, weekStart, teamKey);
      const people = await q.query<RosterPersonDbRow>(`select * from cma.roster_people($1::date, $2)`, [weekStart, teamKey]);
      const entries = await q.query<RosterEntryDbRow>(`select * from cma.roster_entries($1::date, $2)`, [weekStart, teamKey]);
      const coverage = await q.query<CoverageDbRow>(`select * from cma.roster_coverage($1::date, $2)`, [weekStart, teamKey]);
      return {
        header,
        people: people.rows.map((p): RosterPerson => ({
          userId: p.user_id, displayName: p.display_name, organisationName: p.organisation_name, timeZone: p.timezone,
          teamKeys: p.team_keys ?? [], workTypeKeys: p.work_type_keys ?? [],
        })),
        entries: entries.rows.map(toRosterEntry),
        coverage: coverage.rows.map((c): RosterCoverageRow => ({
          date: c.business_date, skillKey: c.skill_key, skillName: c.skill_name, plannedPeople: c.planned_people,
          peopleNames: c.people_names ?? [], target: c.target,
        })),
      };
    });
  },

  async listRosterWeeks(me, teamKey, range): Promise<RosterWeekSummary[]> {
    assertDate(range.from, "from");
    assertDate(range.to, "to");
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{ week_start: string; status: "draft" | "published"; version: number; published_at: Date | null; entry_count: number; shift_count: number }>(
        `select * from cma.roster_weeks($1, $2::date, $3::date)`, [teamKey, range.from, range.to],
      );
      return r.rows.map((w) => ({
        weekStart: w.week_start, status: w.status, version: w.version, publishedAt: w.published_at ? w.published_at.toISOString() : null,
        entryCount: w.entry_count, shiftCount: w.shift_count,
      }));
    });
  },

  async listAbsenceTypes(me): Promise<AbsenceType[]> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{ key: string; name: string; is_paid: boolean; sort_order: number; status: string }>(`select * from cma.absence_types()`);
      return r.rows.map((a) => ({ key: a.key, name: a.name, isPaid: a.is_paid, sortOrder: a.sort_order, isActive: a.status === "active" }));
    });
  },

  async setRosterEntry(me, weekStart, teamKey, userId, date, cell): Promise<RosterEntry | null> {
    assertDate(weekStart, "weekStart");
    assertDate(date, "date");
    return withTenant(ctx(me), async (q) => {
      const kind = cell.kind === "clear" ? null : cell.kind;
      const start = cell.kind === "shift" ? cell.start : null;
      const end = cell.kind === "shift" ? cell.end : null;
      const absence = cell.kind === "absence" ? cell.absenceKey : null;
      const note = cell.kind === "clear" ? null : cell.note ?? null;
      await q.query(`select 1 from cma.roster_set_entry($1::date, $2, $3::uuid, $4::date, $5, $6::time, $7::time, $8, $9)`,
        [weekStart, teamKey, userId, date, kind, start, end, absence, note]);
      const r = await q.query<RosterEntryDbRow>(
        `select * from cma.roster_entries($1::date, $2) e where e.user_id = $3::uuid and e.business_date = $4::date`,
        [weekStart, teamKey, userId, date],
      );
      return r.rows[0] ? toRosterEntry(r.rows[0]) : null;
    });
  },

  async publishRoster(me, weekStart, teamKey): Promise<RosterWeekHeader> {
    assertDate(weekStart, "weekStart");
    return withTenant(ctx(me), async (q) => {
      await q.query(`select 1 from cma.roster_publish($1::date, $2)`, [weekStart, teamKey]);
      return readRosterHeader(q, weekStart, teamKey);
    });
  },

  async copyRosterWeek(me, fromWeekStart, toWeekStart, teamKey): Promise<number> {
    assertDate(fromWeekStart, "from");
    assertDate(toWeekStart, "to");
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{ n: number }>(`select cma.roster_copy_week($1::date, $2::date, $3) as n`, [fromWeekStart, toWeekStart, teamKey]);
      return Number(one(r.rows, "roster_copy_week").n);
    });
  },

  async getMyRoster(me, range): Promise<MyRosterDay[]> {
    assertDate(range.from, "from");
    assertDate(range.to, "to");
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{
        business_date: string; is_published: boolean; kind: "shift" | "absence" | null; start_time: string | null; end_time: string | null;
        absence_key: string | null; absence_name: string | null; note: string | null; team_name: string | null; published_at: Date | null;
      }>(`select * from cma.my_roster($1::date, $2::date)`, [range.from, range.to]);
      return r.rows.map((d) => ({
        date: d.business_date, isPublished: d.is_published, kind: d.kind, start: d.start_time, end: d.end_time,
        absenceKey: d.absence_key, absenceName: d.absence_name, note: d.note, teamName: d.team_name,
        publishedAt: d.published_at ? d.published_at.toISOString() : null,
      }));
    });
  },

  async getRosterToday(me): Promise<TodayShift[]> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{
        user_id: string; business_date: string; is_published: boolean; kind: "shift" | "absence" | null;
        start_time: string | null; end_time: string | null; absence_name: string | null;
      }>(`select * from cma.roster_today()`);
      return r.rows.map((d) => ({
        userId: d.user_id, date: d.business_date, isPublished: d.is_published, kind: d.kind, start: d.start_time, end: d.end_time, absenceName: d.absence_name,
      }));
    });
  },

  async getMyProfile(me): Promise<MyProfile> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{
        user_id: string; email: string; display_name: string; organisation_name: string; timezone: string;
        role_name: string | null; time_kept: boolean; teams: DirectoryDbRow["teams"]; skills: DirectoryDbRow["skills"];
      }>(`select * from cma.my_profile()`);
      const p = one(r.rows, "my_profile");
      return {
        userId: p.user_id, email: p.email, displayName: p.display_name, organisationName: p.organisation_name, timeZone: p.timezone,
        roleName: p.role_name, timeKept: p.time_kept, teams: p.teams ?? [],
        skills: (p.skills ?? []).map((k) => ({ dimension: k.dimension, key: k.key, name: k.name, level: k.level, levelName: k.levelName })),
      };
    });
  },

  async listMyMessages(me, since, limit): Promise<MyMessages> {
    return withTenant(ctx(me), async (q) => {
      // The screen knows instants to the millisecond and the database to the microsecond: the newest
      // message the poller saw would come back on every poll, so "after" means after its millisecond
      const r = await q.query<MessageDbRow>(
        `select * from cma.my_messages(case when $1::timestamptz is null then null else $1::timestamptz + interval '999 microseconds' end, $2::int)`, [since, limit]);
      const c = await q.query<{ n: number }>(`select cma.my_unread_count() as n`);
      return { messages: r.rows.map(toMessage), unreadCount: Number(one(c.rows, "my_unread_count").n) };
    });
  },

  async markMessagesRead(me, ids): Promise<number> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{ n: number }>(`select cma.mark_messages_read($1::uuid[]) as n`, [ids]);
      return Number(one(r.rows, "mark_messages_read").n);
    });
  },

  async acknowledgeMessage(me, id): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select cma.acknowledge_message($1::uuid)`, [id]));
  },

  async sendMessage(me, input): Promise<SentMessage> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{ id: string }>(`select cma.send_message($1, $2, $3, $4::jsonb) as id`,
        [input.title, input.body, input.urgency, JSON.stringify(input.target)]);
      const id = one(r.rows, "send_message").id;
      // The recipients were written in this transaction; the stats function counts them (messages.send holds it)
      const c = await q.query<{ recipients: number }>(
        `select recipients from cma.message_stats((now() - interval '1 day')::date, (now() + interval '1 day')::date) where message_id = $1::uuid`, [id]);
      return { id, recipients: Number(c.rows[0]?.recipients ?? 0) };
    });
  },

  async getMessageStats(me, range): Promise<MessageStat[]> {
    assertDate(range.from, "from");
    assertDate(range.to, "to");
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<StatDbRow>(`select * from cma.message_stats($1::date, $2::date)`, [range.from, range.to]);
      return r.rows.map(toStat);
    });
  },

  async withdrawMessage(me, id) {
    return withTenant(ctx(me), async (q) => {
      // the function checks messages.withdraw (CMA06) and the message (CMA02); a second withdrawal answers the first time
      const r = await q.query<{ at: Date }>(`select cma.withdraw_message($1::uuid) as at`, [id]);
      return { withdrawnAt: one(r.rows, "withdraw_message").at.toISOString() };
    });
  },

  // ---- Sources, markets, alert rules (addition 0008e): every function checks tenant.configure inside (CMA06) ----

  async listSources(me): Promise<SourceConnection[]> {
    return withTenant(ctx(me), async (q) => (await q.query<SourceDbRow>(`select * from cma.sources()`)).rows.map(toSource));
  },

  async getSource(me, id): Promise<SourceDetail> {
    return withTenant(ctx(me), async (q) => {
      const connection = await readSource(q, id);
      const config = await readConfig(q, id);
      const cat = await readCatalogs(q, id);
      // A telephony connection's missed-call reasons and newest call id (addition 0008i)
      const telephony = connection.kind === "telephony" || (connection.kind === null && connection.heldKinds.includes("telephony"));
      const reasons = telephony
        ? (await q.query<{ r: { missedReasons: MissedReasonDb[]; sampleCallId: string | null } }>(`select cma.connection_missed_reasons($1::uuid) as r`, [id])).rows[0]!.r
        : { missedReasons: [], sampleCallId: null };
      // A CRM connection's task catalogs and newest task id (addition 0008n), and every pipeline's own response time (0008o)
      const crm = connection.kind === "crm" || (connection.kind === null && connection.heldKinds.includes("crm"));
      const tasks: TaskCatalogsJson = crm
        ? (await q.query<{ r: TaskCatalogsJson }>(`select cma.connection_task_catalogs($1::uuid) as r`, [id])).rows[0]!.r
        : { statuses: [], types: [], sampleTaskId: null };
      const sla = await q.query<{ record_type: string; source_pipeline_id: string; sla_minutes: number | null }>(
        `select record_type, source_pipeline_id, sla_minutes from cma.connection_pipeline where connection_id = $1::uuid`, [id]);
      const slaOf = new Map(sla.rows.map((x) => [`${x.record_type}:${x.source_pipeline_id}`, x.sla_minutes]));
      return {
        connection,
        pipelines: config.pipelines.map((p) => toPipeline(p, slaOf.get(`${p.recordType}:${p.pipelineId}`) ?? null)),
        forms: cat.forms.map((f) => ({
          formId: f.formId, name: f.name, isCounted: f.isCounted, isPolled: f.isPolled, category: f.category, leadSource: f.leadSource, market: f.market,
          keptFields: f.keptFields ?? [], marketField: f.marketField, leadCondition: f.leadCondition, fields: f.fields ?? [], isActive: f.status === "active",
        })),
        callOutcomes: cat.callOutcomes.map((o) => ({ outcomeRef: o.outcomeRef, label: o.label, isConnected: o.isConnected, isActive: o.status === "active" })),
        lines: cat.lines.map((l) => ({ lineRef: l.lineRef, name: l.name, digits: l.digits, market: l.market, isCounted: l.isCounted, isActive: l.status === "active" })),
        tags: cat.tags.map((t) => ({ tagRef: t.tagRef, name: t.name, isCounted: t.isCounted, isActive: t.status === "active" })),
        fields: config.fields.map((f) => ({ entity: f.entity, field: f.field, refSystem: f.refSystem, slot: f.slot, property: f.property })),
        writeback: config.writeback.map((w) => ({ field: w.field, slot: w.slot, property: w.property, mode: w.mode, enabled: w.enabled })),
        store: config.store,
        sampleIds: { ...(cat.sampleIds ?? {}), ...(reasons.sampleCallId ? { call: reasons.sampleCallId } : {}), ...(tasks.sampleTaskId ? { task: tasks.sampleTaskId } : {}) },
        missedReasons: reasons.missedReasons.map((x) => ({
          code: x.code, label: x.label, countsInServiceLevel: x.countsInServiceLevel, needsCallback: x.needsCallback,
          inCatalog: x.inCatalog, seenCalls: x.seenCalls, lastSeenAt: x.lastSeenAt ? new Date(x.lastSeenAt).toISOString() : null,
        })),
        taskStatuses: tasks.statuses.map((s) => ({ statusRef: s.statusRef, label: s.label, isDone: s.isDone, seenTasks: s.seenTasks, lastSeenAt: isoAny(s.lastSeenAt) })),
        taskTypes: tasks.types.map((y) => ({ typeRef: y.typeRef, label: y.label, isCallback: y.isCallback, isCounted: y.isCounted, seenTasks: y.seenTasks, openTasks: y.openTasks, lastSeenAt: isoAny(y.lastSeenAt) })),
        inboxes: crm ? (config.inboxes ?? []).map((b) => ({ inboxId: b.inboxId, name: b.name, isCounted: b.isCounted, market: b.market, isActive: b.status === "active" })) : [],
        mailboxes: crm ? (config.inboxAccounts ?? []).map((a) => ({ accountId: a.accountId, name: a.name, label: a.label, inboxId: a.inboxId, channelId: a.channelId,
          isCounted: a.isCounted, market: a.market, isActive: a.status === "active" })) : [],
        inboxChannels: crm ? (config.inboxChannels ?? []).map((k) => ({ channelId: k.channelId, name: k.name, kind: k.kind, isCounted: k.isCounted, isActive: k.status === "active" })) : [],
      };
    });
  },

  async getEmailReport(me, range, group, filter): Promise<EmailReport> {
    assertReportRange(range);
    return withTenant(ctx(me), async (q) => {
      // the function checks the permission, the group and the filters first; one pass over the period and its previous span for
      // every section, and with a filter set the figures without it (period 'unfiltered', 0008x)
      const r = await q.query<EmailDbRow>(`select * from cma.email_report_page($1::date, $2::date, $3, $4, $5, $6)`,
        [range.from, range.to, group, filter.market, filter.inbox, filter.account]);
      const filtered = filter.market !== null || filter.inbox !== null || filter.account !== null;
      // the filter lists come from the period without the filters: the page's own rows when it has none
      const whole = filtered ? r.rows.filter((x) => x.period === "unfiltered").map((x) => ({ ...x, period: "current" })) : r.rows;
      const has = await readHasEmail(q);
      const history = await q.query<{ history_start: string | null }>(`select cma.email_history_start()::text as history_start`);
      const settings = await emailSettings(q);
      const waiting = await q.query<{ connection_id: string; thread_source_id: string; inbox_name: string | null; account_name: string | null; market: string;
        waiting_since: Date; waited_seconds: number; waited_business_seconds: number | null; record_url: string | null; total_rows: number }>(
        `select * from cma.email_waiting($1, $2, $3)`, [filter.market, filter.inbox, filter.account]);
      const nr = await q.query<{ connection_id: string; deal_source_id: string; pipeline_label: string; market: string; owner_user_id: string | null;
        owner_name: string | null; last_email_at: Date; days_since: number; record_url: string | null; total_rows: number }>(
        `select r.*, u.display_name as owner_name from cma.email_not_responding($1) r left join cma.app_user u on u.id = r.owner_user_id`, [filter.market]);
      const prev = previousPeriod(range, dateKeyInZone(new Date(), me.timeZone));
      const total = r.rows.find((x) => x.period === "current" && x.dimension === "total");
      const previous = r.rows.find((x) => x.period === "previous");
      return {
        ...range, group, filter, email: has,
        rows: emailRowsOf(r.rows, group), total: toEmailFigures(total!), previous: toEmailFigures(previous!),
        previousFrom: prev.from, previousTo: prev.to, previousPartial: prev.partial, historyStart: history.rows[0]?.history_start ?? null,
        byInbox: emailRowsOf(r.rows, "inbox"), byAccount: emailRowsOf(r.rows, "account"), byCategory: emailRowsOf(r.rows, "category"),
        byMarket: emailRowsOf(r.rows, "market"),
        receivedByInbox: emailSeriesOf(r.rows, `${group}_inbox`), receivedByAccount: emailSeriesOf(r.rows, `${group}_account`),
        ...settings,
        waiting: {
          rows: waiting.rows.map((x): EmailWaitingRow => ({
            connectionId: x.connection_id, threadId: x.thread_source_id, inboxName: x.inbox_name, accountName: x.account_name, market: x.market,
            waitingSince: x.waiting_since.toISOString(), waitedSeconds: x.waited_seconds, waitedBusinessSeconds: x.waited_business_seconds, recordUrl: x.record_url,
          })),
          total: waiting.rows[0]?.total_rows ?? 0,
        },
        notResponding: {
          rows: nr.rows.map((x): EmailNotRespondingRow => ({
            connectionId: x.connection_id, dealId: x.deal_source_id, pipelineLabel: x.pipeline_label, market: x.market, ownerUserId: x.owner_user_id,
            ownerName: x.owner_name, lastEmailAt: x.last_email_at.toISOString(), daysSince: x.days_since, recordUrl: x.record_url,
          })),
          total: nr.rows[0]?.total_rows ?? 0,
        },
        ...emailListsOf(whole),
      };
    });
  },

  async getEmailPerAgent(me, range, filter): Promise<EmailPerAgent> {
    assertReportRange(range);
    return withTenant(ctx(me), async (q) => {
      // the function checks performance.team and the tenant's reports.per_person first (CMA06); one pass over the period for
      // per person (part 'person') and the figures without the filters for the filter lists (part 'dimension', 0008x)
      const r = await q.query<EmailPersonPageDbRow>(`select * from cma.email_per_person_page($1::date, $2::date, $3, $4, $5)`,
        [range.from, range.to, filter.market, filter.inbox, filter.account]);
      const whole = r.rows.filter((x) => x.part === "dimension").map((x): EmailDbRow => ({ ...x, period: "current" }));
      const has = await readHasEmail(q);
      const settings = await emailSettings(q);
      const rows = r.rows.filter((x) => x.part === "person").map(toEmailPerson);
      return {
        ...range, filter, email: has, rows: rows.filter((x) => x.kind !== "total"), total: rows.find((x) => x.kind === "total")!,
        replyTargetMinutes: settings.replyTargetMinutes, ...emailListsOf(whole),
      };
    });
  },

  async getFirstOrders(me, range, group, filter): Promise<FirstOrdersReport> {
    assertReportRange(range);
    return withTenant(ctx(me), async (q) => {
      // the function checks the permission, the group and the filters first; one pass of cma.first_orders_of for the report
      // (part 'report'), the amounts (part 'amounts') and the list (part 'list'), each in its read's order (0008x)
      const page = await q.query<FirstOrderPageDbRow>(`select * from cma.first_orders_page($1::date, $2::date, $3, $4, $5)`,
        [range.from, range.to, group, filter.market, filter.level]);
      const r = { rows: page.rows.filter((x) => x.part === "report") };
      const amounts = { rows: page.rows.filter((x) => x.part === "amounts") };
      const list = { rows: page.rows.filter((x) => x.part === "list") };
      const history = await q.query<{ history_start: string | null; phone_start: string | null; connected: boolean }>(
        `select history_start::text, phone_start::text, connected from cma.first_orders_history_start()`);
      const prev = previousPeriod(range, dateKeyInZone(new Date(), me.timeZone));
      const toAmount = (a: (typeof amounts.rows)[number]): FirstOrderAmount => ({
        market: a.group_key, currency: a.currency === "none" ? null : a.currency, orders: a.orders, amount: numOrNull(a.amount),
        callCenterAmount: Number(a.call_center_amount), selfServiceAmount: Number(a.self_service_amount),
      });
      return {
        ...range, group, filter, connected: history.rows[0]?.connected ?? false,
        rows: firstOrderRowsOf(r.rows, group),
        total: toFirstOrderFigures(r.rows.find((x) => x.period === "current" && x.dimension === "total")),
        previous: toFirstOrderFigures(r.rows.find((x) => x.period === "previous")),
        previousFrom: prev.from, previousTo: prev.to, previousPartial: prev.partial,
        byLevel: firstOrderRowsOf(r.rows, "level"), byMarket: firstOrderRowsOf(r.rows, "market"),
        amounts: amounts.rows.filter((a) => a.dimension === "total").map(toAmount),
        amountsByMarket: amounts.rows.filter((a) => a.dimension === "market").map(toAmount),
        list: {
          rows: list.rows.map(toFirstOrderListRow),
          total: list.rows[0]?.total_rows ?? 0,
        },
        historyStart: history.rows[0]?.history_start ?? null, phoneStart: history.rows[0]?.phone_start ?? null,
        settings: await attributionSettings(q), markets: await marketCodes(q),
      };
    });
  },

  async getFirstOrdersExport(me, range, filter): Promise<FirstOrderListRow[]> {
    assertReportRange(range);
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<FirstOrderListDbRow>(`select * from cma.first_orders_list($1::date, $2::date, $3, $4, 500)`,
        [range.from, range.to, filter.market, filter.level]);
      return r.rows.map(toFirstOrderListRow);
    });
  },

  async getOrdersPerPerson(me, range, filter): Promise<OrdersPerPerson> {
    assertReportRange(range);
    return withTenant(ctx(me), async (q) => {
      // the function checks performance.team and the tenant's reports.per_person (orders) first (CMA06)
      const r = await q.query<OrderPersonDbRow>(`select * from cma.first_orders_per_person($1::date, $2::date, $3, $4)`,
        [range.from, range.to, filter.market, filter.level]);
      const history = await q.query<{ connected: boolean }>(`select connected from cma.first_orders_history_start()`);
      const rows = r.rows.map(toOrderPerson);
      const total = rows.find((x) => x.kind === "total") ?? toOrderPerson({ row_kind: "total", user_id: null, display_name: null, unlinked_owners: null,
        orders: 0, lead_deal: 0, conversation: 0, email: 0, phone_match: 0, other_levels: 0, days_median: null });
      return {
        ...range, filter, connected: history.rows[0]?.connected ?? false, rows: rows.filter((x) => x.kind !== "total"), total,
        settings: await attributionSettings(q), markets: await marketCodes(q),
      };
    });
  },

  async getAttempts(me, range, group, filter): Promise<AttemptsReport> {
    assertReportRange(range);
    return withTenant(ctx(me), async (q) => {
      // the function checks the permission, the group and the filters first; one pass of cma.attempts_per_deal_of over the
      // previous span and the period (0008y, 0008z)
      const j = one((await q.query<{ j: AttemptsPageDb }>(`select cma.attempts_per_deal_page($1::date, $2::date, $3, $4, $5, $6, $7) as j`,
        [range.from, range.to, group, filter.market, filter.pipeline, filter.attempted, filter.outcome])).rows, "attempts_per_deal_page").j;
      const prev = previousPeriod(range, dateKeyInZone(new Date(), me.timeZone));
      return {
        ...range, group, filter, current: toAttemptFigures(j.current), previous: toAttemptFigures(j.previous),
        previousFrom: prev.from, previousTo: prev.to, previousPartial: prev.partial,
        buckets: j.buckets.map((b): AttemptBucket => ({ bucket: b.bucket, label: b.label, deals: b.deals, firstReached: b.first_reached, won: b.won, lost: b.lost })),
        outcomes: { rows: j.outcomes.rows.map(toAttemptOutcomeRow), notDecided: j.outcomes.not_decided, open: j.outcomes.open, ordered: j.outcomes.ordered,
          unknown: j.outcomes.unknown },
        speedBuckets: { buckets: j.speed_buckets.buckets, none: j.speed_buckets.none, noHours: j.speed_buckets.no_hours },
        groups: j.groups.map((g): AttemptGroupRow => ({ groupKey: g.key, label: g.label, ...toAttemptFigures(g) })),
        sinceLast: { buckets: j.since_last.buckets, noHours: j.since_last.no_hours },
        list: { total: j.list.total, rows: j.list.rows.map(toAttemptListRow) },
        markets: j.markets, pipelines: j.pipelines, historyStart: j.history_start, settings: toAttemptSettings(j.settings),
      };
    });
  },

  async getAttemptsPerAgent(me, range, filter): Promise<AttemptsPerAgent> {
    assertReportRange(range);
    return withTenant(ctx(me), async (q) => {
      // the function checks performance.team and the tenant's reports.per_person (attempts) first (CMA06)
      const j = one((await q.query<{ j: AttemptsPersonDb }>(`select cma.attempts_per_person_page($1::date, $2::date, $3, $4, $5, $6) as j`,
        [range.from, range.to, filter.market, filter.pipeline, filter.attempted, filter.outcome])).rows, "attempts_per_person_page").j;
      const rows: AttemptPerson[] = j.rows.map((p) => ({ kind: "person", userId: p.user_id, name: p.display_name, unlinkedOwners: null, ...toAttemptFigures(p) }));
      if (j.not_linked) rows.push({ kind: "notLinked", userId: null, name: null, unlinkedOwners: j.not_linked.unlinked_owners, ...toAttemptFigures(j.not_linked) });
      return {
        ...range, filter, rows, total: { kind: "total", userId: null, name: null, unlinkedOwners: null, ...toAttemptFigures(j.total) },
        markets: j.markets, pipelines: j.pipelines, historyStart: j.history_start, settings: toAttemptSettings(j.settings),
      };
    });
  },

  async getDealAttempts(me, dealId): Promise<DealAttempt[]> {
    return withTenant(ctx(me), async (q) => {
      // the function checks reports.view or performance.team (CMA06) and the deal (CMA02); the agent's name only when allowed
      const r = await q.query<DealAttemptDb>(`select * from cma.attempts_of_deal($1::uuid)`, [dealId]);
      return r.rows.map((x) => ({
        n: x.n, startedAt: x.started_at.toISOString(), answered: x.answered, talkSeconds: x.talk_seconds, reached: x.reached, reachedBy: x.reached_by,
        outcomeLabel: x.outcome_label, agentName: x.agent_name,
      }));
    });
  },

  async getCallbacksKept(me, range): Promise<CallbacksKept> {
    assertReportRange(range);
    return withTenant(ctx(me), async (q) => {
      // the functions check reports.view or performance.team (CMA06) and the 92 days (CMA04)
      const r = await q.query<CallbackKeptDbRow>(`select * from cma.callbacks_kept_report($1::date, $2::date)`, [range.from, range.to]);
      const connected = await q.query<{ connected: boolean }>(`select cma.callbacks_kept_connected() as connected`);
      const win = await q.query<{ value: string }>(`select value from cma.tenant_settings() where key = 'tasks.callback_window_minutes'`);
      if (win.rows[0] === undefined) throw new Error("tenant setting tasks.callback_window_minutes is missing from the catalog");
      const current = r.rows.filter((x) => x.period === "current");
      return {
        ...range, connected: connected.rows[0]?.connected ?? false,
        weeks: current.filter((x) => x.dimension === "week" && x.week_start).map((x) => ({ weekStart: x.week_start as string, ...toCallbackCounts(x) })),
        total: toCallbackCounts(current.find((x) => x.dimension === "total")),
        previous: toCallbackCounts(r.rows.find((x) => x.period === "previous" && x.dimension === "total")),
        windowMinutes: Number(win.rows[0].value),
      };
    });
  },

  async getCallbacksPerOwner(me, range): Promise<CallbackOwner[]> {
    assertReportRange(range);
    return withTenant(ctx(me), async (q) => {
      // the function checks performance.team (CMA06)
      const r = await q.query<CallbackKeptDbRow>(`select * from cma.callbacks_kept_per_owner($1::date, $2::date)`, [range.from, range.to]);
      return r.rows.map((x) => ({
        kind: x.row_kind === "person" ? "person" : x.row_kind === "not_linked" ? "notLinked" : "total",
        userId: x.user_id ?? null, name: x.display_name ?? null, unlinkedOwners: x.unlinked_owners ?? null,
        callbacks: x.callbacks, kept: x.kept, notKept: x.not_kept, pending: x.pending, noContact: x.no_contact,
      }));
    });
  },

  async getJourneys(me): Promise<Journey[]> {
    return withTenant(ctx(me), async (q) => {
      // the function checks reports.view or performance.team (CMA06) and leaves the archived journeys out
      const r = await q.query<{ code: string; name: string; summary: string | null; market: string | null; status: JourneyStatus;
        design_url: string | null; prerequisites: string[] }>(`select code, name, summary, market, status, design_url, prerequisites from cma.journeys()`);
      return r.rows.map((x) => ({ code: x.code, name: x.name, summary: x.summary, market: x.market, status: x.status, designUrl: x.design_url,
        prerequisites: x.prerequisites }));
    });
  },

  async setSourceStageOutcome(me, id, input): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select cma.set_stage_outcome($1::uuid, 'deal', $2, $3, $4)`, [id, input.pipelineId, input.stageId, input.outcome]));
  },

  async setSourceInbox(me, id, input): Promise<void> {
    await withTenant(ctx(me), async (q) => {
      // set_inbox takes the work type and channel too: the stored ones travel back unchanged
      const cur = await q.query<{ work_type: string | null; channel: string | null }>(
        `select s.key as work_type, ch.key as channel from cma.connection_inbox b
           left join cma.skill s on s.tenant_id = b.tenant_id and s.id = b.work_type_skill_id
           left join cma.channel ch on ch.tenant_id = b.tenant_id and ch.id = b.channel_id
          where b.connection_id = $1::uuid and b.source_inbox_id = $2`, [id, input.inboxId]);
      await q.query(`select cma.set_inbox($1::uuid, $2, $3, $4, $5, $6)`,
        [id, input.inboxId, input.isCounted, input.market, cur.rows[0]?.work_type ?? null, cur.rows[0]?.channel ?? null]);
    });
  },

  async setSourceMailbox(me, id, input): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select cma.set_inbox_account($1::uuid, $2, $3, $4, $5)`, [id, input.accountId, input.label, input.isCounted, input.market]));
  },

  async setSourceInboxChannel(me, id, input): Promise<void> {
    await withTenant(ctx(me), async (q) => {
      const cur = await q.query<{ channel: string | null }>(
        `select ch.key as channel from cma.connection_inbox_channel k left join cma.channel ch on ch.tenant_id = k.tenant_id and ch.id = k.channel_id
          where k.connection_id = $1::uuid and k.source_channel_id = $2`, [id, input.channelId]);
      await q.query(`select cma.set_inbox_channel($1::uuid, $2, $3, $4)`, [id, input.channelId, cur.rows[0]?.channel ?? null, input.isCounted]);
    });
  },

  async setSourcePipelineSla(me, id, input): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select cma.set_pipeline_sla($1::uuid, $2, $3, $4)`, [id, input.recordType, input.pipelineId, input.slaMinutes]));
  },

  async setSourceTaskStatus(me, id, input): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select cma.set_task_status($1::uuid, $2, $3, $4)`, [id, input.statusRef, input.label, input.isDone]));
  },

  async setSourceTaskType(me, id, input): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select cma.set_task_type($1::uuid, $2, $3, $4, $5)`, [id, input.typeRef, input.label, input.isCallback, input.isCounted]));
  },

  async setSourceConnection(me, id, input): Promise<void> {
    await withTenant(ctx(me), async (q) => {
      const cur = await readSource(q, id);
      if (input.name !== undefined && input.name !== cur.name) {
        // the name through the function that owns it, with the stored secret names passed back unchanged
        await q.query(`select 1 from cma.upsert_connection($1, $2, $3, $4, $5)`, [cur.adapter, input.name, cur.accountId, cur.signingSecretName, cur.tokenSecretName]);
      }
      if (input.isActive !== undefined && input.isActive !== cur.isActive) {
        await q.query(`select cma.set_connection_status($1::uuid, $2)`, [id, input.isActive ? "active" : "inactive"]);
      }
      if (input.kind !== undefined && input.kind !== cur.kind) {
        await q.query(`select cma.set_connection_kind($1::uuid, $2)`, [id, input.kind]);
      }
    });
  },

  async setSourceSettings(me, id, settings): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select cma.set_connection_settings($1::uuid, $2::jsonb)`, [id, JSON.stringify(settings)]));
  },

  async setSourcePipeline(me, id, input): Promise<void> {
    await withTenant(ctx(me), async (q) => {
      const cur = (await readConfig(q, id)).pipelines.find((p) => p.recordType === input.recordType && p.pipelineId === input.pipelineId);
      if (!cur || cur.isCounted !== input.isCounted) {
        await q.query(`select cma.set_connection_pipeline($1::uuid, $2, $3, $4, $5, $6)`,
          [id, input.recordType, input.pipelineId, input.isCounted, cur?.isRouted ?? false, cur?.workType ?? null]);
      }
      if (!cur || cur.isLead !== input.isLead) {
        await q.query(`select cma.set_pipeline_lead($1::uuid, $2, $3, $4)`, [id, input.recordType, input.pipelineId, input.isLead]);
      }
      // the order pipeline switch (0008u), when given
      if (input.isOrder !== undefined && (!cur || (cur.isOrder ?? false) !== input.isOrder)) {
        await q.query(`select cma.set_pipeline_order($1::uuid, $2, $3, $4)`, [id, input.recordType, input.pipelineId, input.isOrder]);
      }
    });
  },

  async setSourceForms(me, id, changes): Promise<void> {
    await withTenant(ctx(me), async (q) => {
      const forms = (await readCatalogs(q, id)).forms;
      for (const c of changes) {
        const f = forms.find((x) => x.formId === c.formId);
        await q.query(`select cma.set_form($1::uuid, $2, $3, $4, $5, $6::text[])`, [id, c.formId, c.isCounted, c.leadSource, c.market, f?.keptFields ?? []]);
        // polled and the category (addition 0008p), when given; set_form made a counted form polled already
        if (c.isPolled !== undefined || c.category !== undefined) {
          await q.query(`select cma.set_form_reporting($1::uuid, $2, $3, $4, $5)`,
            [id, c.formId, c.isPolled ?? (c.isCounted || (f?.isPolled ?? false)), c.category === undefined ? (f?.category ?? null) : c.category, c.market]);
        }
      }
    });
  },

  async getFormCategories(me): Promise<FormCategory[]> {
    return withTenant(ctx(me), async (q) => (await q.query<{ code: string; name: string; sort_order: number; status: string; forms: number }>(
      `select * from cma.form_categories()`)).rows.map((r) => ({ code: r.code, name: r.name, sortOrder: r.sort_order, isActive: r.status === "active", forms: r.forms })));
  },

  async setFormCategory(me, input): Promise<void> {
    await withTenant(ctx(me), async (q) => {
      await q.query(`select cma.set_form_category($1, $2, $3)`, [input.code, input.name, input.sortOrder]);
      await q.query(`select cma.set_form_category_status($1, $2)`, [input.code, input.isActive ? "active" : "inactive"]);
    });
  },

  async setSourceCallOutcomes(me, id, changes): Promise<void> {
    await withTenant(ctx(me), async (q) => {
      for (const c of changes) await q.query(`select cma.set_call_outcome($1::uuid, $2, $3)`, [id, c.outcomeRef, c.isConnected]);
    });
  },

  async setSourceLine(me, id, input): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select cma.set_telephony_number($1::uuid, $2, $3, $4)`, [id, input.lineRef, input.market, input.isCounted]));
  },

  async getSourceLineStoredCalls(me, id, lineRef): Promise<LineStoredCalls> {
    return withTenant(ctx(me), async (q) => {
      // tenant.configure, and CMA02 for a line the tenant does not have (0008y)
      const r = one((await q.query<{ stored_calls: number; first_started_at: Date | null }>(
        `select stored_calls, first_started_at from cma.telephony_number_stored_calls($1::uuid, $2)`, [id, lineRef])).rows, "telephony_number_stored_calls");
      return { storedCalls: r.stored_calls, firstStartedAt: r.first_started_at ? r.first_started_at.toISOString() : null };
    });
  },

  async setSourceTag(me, id, input): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select cma.set_telephony_tag($1::uuid, $2, $3)`, [id, input.tagRef, input.isCounted]));
  },

  async setSourceMissedReason(me, id, input): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select cma.set_telephony_missed_reason($1::uuid, $2, $3, $4, $5)`,
      [id, input.code, input.label, input.countsInServiceLevel, input.needsCallback]));
  },

  async setSourceStore(me, id, store): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select cma.upsert_commerce_store($1::uuid, $2, $3, $4, $5, $6)`,
      [id, store.handle, store.name, store.market, store.currency, store.timeZone]));
  },

  async getMarkets(me) {
    return withTenant(ctx(me), async (q) => {
      const markets = (await q.query<MarketDbRow>(`select * from cma.markets_all()`)).rows.map(toMarket);
      const hours = (await q.query<{ market: string; weekday: number; hours: string }>(`select * from cma.business_hours_all()`)).rows;
      const holidays = (await q.query<{ market: string; day: string; name: string }>(`select market, to_char(day, 'YYYY-MM-DD') as day, name from cma.business_holidays_all()`)).rows;
      return { markets, hours: hours.map((h) => ({ market: h.market, weekday: h.weekday, hours: h.hours })), holidays };
    });
  },

  async upsertMarket(me, input, active): Promise<void> {
    await withTenant(ctx(me), async (q) => {
      await q.query(`select cma.upsert_market($1, $2, $3, $4, $5, $6, $7::smallint, $8)`,
        [input.code, input.name, input.timeZone, input.languageCode, input.currency, input.languageSkillKey, input.minLanguageLevel, input.sortOrder]);
      const cur = await q.query<{ status: string }>(`select status from cma.markets_all() where code = $1`, [input.code]);
      if ((cur.rows[0]?.status === "active") !== active) await q.query(`select cma.set_market_status($1, $2)`, [input.code, active ? "active" : "inactive"]);
    });
  },

  async setMarketAlias(me, alias, code): Promise<void> {
    await withTenant(ctx(me), (q) => code === null
      ? q.query(`select cma.remove_market_alias($1)`, [alias])
      : q.query(`select cma.set_market_alias($1, $2)`, [alias, code]));
  },

  async setOfficeHours(me, market, days): Promise<void> {
    await withTenant(ctx(me), async (q) => {
      for (const d of days) await q.query(`select cma.set_business_hours($1, $2::smallint, $3)`, [market, d.weekday, d.hours]);
    });
  },

  async setHoliday(me, market, day, name): Promise<void> {
    await withTenant(ctx(me), (q) => name === null
      ? q.query(`select cma.remove_business_holiday($1, $2::date)`, [market, day])
      : q.query(`select cma.set_business_holiday($1, $2::date, $3)`, [market, day, name]));
  },

  async getAlertRules(me) {
    return withTenant(ctx(me), async (q) => {
      const rules = await readRules(q);
      // The pipelines a rule can name: of the tenant's customer-record connections (kind crm, or rows that say so),
      // read with the connections in one statement, so the page costs the same whatever the number of connections
      // (before 18 October 2026 one cma.connection_config statement per connection)
      const sources = await q.query<SourceDbRow & { config: ConfigJson | null }>(
        `select s.*, case when s.kind = 'crm' or (s.kind is null and 'crm' = any(s.held_kinds))
                          then cma.connection_config(s.connection_id) end as config
         from cma.sources() s`,
      );
      const pipelines: AlertPipelineChoice[] = [];
      for (const row of sources.rows) {
        for (const p of row.config?.pipelines ?? []) {
          pipelines.push({ connectionName: row.name, recordType: p.recordType, pipelineId: p.pipelineId, label: p.label, isCounted: p.isCounted });
        }
      }
      const age = await q.query<{ value: string | null }>(`select value from cma.tenant_settings() where key = 'alerts.max_age_minutes'`);
      return { rules, pipelines, defaultMaxAgeMinutes: Number(age.rows[0]?.value ?? 60) };
    });
  },

  async upsertAlertRule(me, input): Promise<string> {
    return withTenant(ctx(me), async (q) => {
      const same = (await readRules(q)).find((r) => r.name === input.name.trim());
      if (same && same.trigger !== input.trigger) throw new CmaDbError("CMA03", "a rule of the other trigger holds this name");
      const r = input.trigger === "record_assigned"
        ? await q.query<{ id: string }>(`select cma.upsert_assignment_rule($1, $2, $3::text[], $4, $5) as id`,
            [input.name, input.recordType, input.pipelineIds, input.urgency, input.maxAgeMinutes])
        : await q.query<{ id: string }>(`select cma.upsert_message_rule($1, $2, $3::text[], $4, $5, $6, $7, $8, $9) as id`,
            [input.name, input.recordType, input.pipelineIds, input.audiencePermission, input.matchLanguage, input.onlyClockedIn,
             input.fallbackPermission, input.urgency, input.maxAgeMinutes]);
      return one(r.rows, "upsert rule").id;
    });
  },

  async setAlertRuleEnabled(me, id, enabled): Promise<void> {
    await withTenant(ctx(me), (q) => q.query(`select cma.set_message_rule_enabled($1::uuid, $2)`, [id, enabled]));
  },

  // ---- Linked accounts (addition 0008e): users.manage_agents or users.manage_all, the directory's scope ----

  async getLinkedAccounts(me) {
    return withTenant(ctx(me), async (q) => {
      const systems = (await q.query<{ system: string; role: LinkedAccountSystem["role"]; connections: string[]; is_active: boolean }>(
        `select * from cma.linked_account_systems()`)).rows;
      const accounts = (await q.query<{ user_id: string; system: string; external_id: string }>(`select * from cma.linked_accounts()`)).rows;
      return {
        systems: systems.map((x) => ({ system: x.system, role: x.role, connections: x.connections ?? [], isActive: x.is_active })),
        accounts: accounts.map((a) => ({ userId: a.user_id, system: a.system, externalId: a.external_id })),
      };
    });
  },

  async setLinkedAccount(me, userId, system, externalId): Promise<void> {
    await withTenant(ctx(me), async (q) => {
      // the People rule, read in the same transaction: a person the caller sees must be editable (never
      // oneself); a person the caller does not see is answered by the function itself (CMA06 for a managing
      // person, CMA02 for nobody), as every other write of People is
      const r = await q.query<{ may_edit: boolean }>(`select may_edit from cma.directory() where user_id = $1::uuid`, [userId]);
      if (r.rows[0] && !r.rows[0].may_edit) throw new CmaDbError("CMA06", "may not edit this person");
      if (externalId === null) await q.query(`select cma.remove_user_external_id($1::uuid, $2)`, [userId, system]);
      else await q.query(`select cma.set_user_external_id($1::uuid, $2, $3)`, [userId, system, externalId]);
    });
  },

  async getSpeedToLeadRows(me, range): Promise<SpeedToLeadRow[]> {
    assertReportRange(range);
    return withTenant(ctx(me), async (q) => {
      // cma.record_url (migration 0008) builds the link from the connection's own template; null without one
      const r = await q.query<SpeedDbRow>(
        `select r.*, cma.record_url(r.connection_id, 'deal', r.deal_source_id) as record_url
           from cma.speed_to_lead_rows($1::date, $2::date) r`,
        [range.from, range.to],
      );
      return r.rows.map(toSpeedRow);
    });
  },

  async getSpeedToLeadSummary(me, range, group) {
    assertReportRange(range);
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<SummaryDbRow>(`select * from cma.speed_to_lead_summary($1::date, $2::date, $3)`, [range.from, range.to, group]);
      const rows: SpeedToLeadSummaryRow[] = r.rows.map((x) => ({
        groupKey: x.group_key,
        // the function labels an agent who is not mapped 'unknown'; the screen says Not mapped
        groupLabel: group === "agent" && x.group_key === "unknown" ? null : x.group_label,
        deals: x.deals, called: x.called,
        medianBusinessMinutes: num(x.median_business_minutes), p80BusinessMinutes: num(x.p80_business_minutes),
        withinTargetPct: num(x.within_target_pct), beforeNextNoonPct: num(x.before_next_noon_pct), openNotCalled: x.open_not_called,
      }));
      return { ...range, group, rows };
    });
  },

  async getIntake(me, range): Promise<Intake> {
    assertReportRange(range);
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<IntakeDbRow>(`select * from cma.intake_per_day($1::date, $2::date)`, [range.from, range.to]);
      const connections = await readConnections(q);
      const start = await q.query<{ value: string | null }>(`select value from cma.tenant_settings() where key = 'intake.start_date'`);
      const counts: IntakeCounts[] = r.rows.map((x) => ({
        date: x.business_date, market: x.market, formSubmissions: x.form_submissions, dealsCreated: x.deals_created,
        dealsClosed: x.deals_closed, ticketsCreated: x.tickets_created, ticketsClosed: x.tickets_closed, callsIn: x.calls_in,
        callsOut: x.calls_out, taggedCalls: x.tagged_calls, newCustomers: x.new_customers, firstOrders: x.first_orders,
        repeatOrders: x.repeat_orders, renewals: x.renewals,
      }));
      return { ...range, connections, startDate: start.rows[0]?.value ?? null, rows: applyConnections(counts, connections) };
    });
  },

  async getDataQuality(me): Promise<DataQualityCheck[]> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{ check_key: string; description: string; total: number | null }>(`select * from cma.data_quality()`);
      // The outbox guard (brief A5), read after cma.data_quality() checked the permission; the same
      // definition as the sweep's (ingest store, outboxLate)
      const o = await q.query<{ n: number }>(
        `select count(*)::integer as n
           from cma.outbox_action o
           join cma.integration_connection c on c.tenant_id = o.tenant_id and c.id = o.connection_id and c.status = 'active'
          where o.tenant_id = cma.current_tenant_id()
            and o.status in ('pending', 'failed', 'in_flight') and o.next_attempt_at < now() - make_interval(mins => $1)`,
        [OUTBOX_LATE_MINUTES]);
      return withOutboxPending(r.rows.map((x) => ({ key: x.check_key, description: x.description, total: x.total })), o.rows[0]?.n ?? 0);
    });
  },

  async getInboundService(me, range, group): Promise<InboundService> {
    assertReportRange(range);
    return withTenant(ctx(me), async (q) => {
      // the function checks the permission first; the connection state, the catalog and the setting follow
      const r = await q.query<InboundDbRow>(`select * from cma.inbound_service($1::date, $2::date, $3)`, [range.from, range.to, group]);
      const connections = await readConnections(q);
      const reasons = (await q.query<ReasonDbRow>(`select * from cma.missed_reasons()`)).rows.map(toReason);
      const set = await q.query<{ key: string; value: string }>(
        `select key, value from cma.tenant_settings() where key in ('telephony.service_level_seconds', 'telephony.waiting_max_minutes')`);
      const setting = (key: string, fallback: number) => Number(set.rows.find((x) => x.key === key)?.value ?? fallback);
      const rows = r.rows.filter((x) => x.group_key !== null).map((x) => ({ groupKey: x.group_key!, groupLabel: x.group_label, ...toFigures(x) }));
      const totalRow = r.rows.find((x) => x.group_key === null);
      return {
        ...range, group, telephony: connections.telephony, reasons,
        serviceLevelSeconds: setting("telephony.service_level_seconds", 20), waitingMaxMinutes: setting("telephony.waiting_max_minutes", 30),
        rows: connections.telephony ? rows : [],
        total: totalRow ? toFigures(totalRow) : emptyFigures(),
      };
    });
  },

  async getInboundNow(me): Promise<InboundNow> {
    return withTenant(ctx(me), async (q) => {
      const t = (await q.query<InboundDbRow & { business_date: string; waiting_now: number; longest_waiting_seconds: number | null;
        service_level_seconds: number; waiting_max_minutes: number }>(`select * from cma.inbound_today()`)).rows[0]!;
      // cma.record_url (migration 0008) builds the call's link from the connection's record_url_call template; null without one
      const cb = await q.query<CallbackDbRow>(
        `select m.*, cma.record_url(m.connection_id, 'call', m.source_id) as record_url from cma.missed_callbacks() m`);
      const sum = (await q.query<{ anonymous_count: number; lookback_days: number }>(`select * from cma.missed_callbacks_summary()`)).rows[0]!;
      const connections = await readConnections(q);
      return {
        telephony: connections.telephony,
        today: connections.telephony ? {
          ...toFigures(t), date: t.business_date, waitingNow: t.waiting_now, longestWaitingSeconds: t.longest_waiting_seconds,
          serviceLevelSeconds: t.service_level_seconds, waitingMaxMinutes: t.waiting_max_minutes,
        } : null,
        callbacks: connections.telephony ? cb.rows.map((x) => ({
          callId: x.call_id, connectionId: x.connection_id, sourceId: x.source_id, lineRef: x.line_ref, lineName: x.line_name, market: x.market,
          reasonCode: x.reason_code, reasonLabel: x.reason_label, startedAt: x.started_at.toISOString(), missedCount: x.missed_count,
          waitingSeconds: x.waiting_seconds, waitingBusinessSeconds: x.waiting_business_seconds, recordUrl: x.record_url,
        })) : [],
        anonymousCount: connections.telephony ? sum.anonymous_count : 0,
        lookbackDays: sum.lookback_days,
      };
    });
  },

  async getCallsOverview(me, range, group, filter): Promise<CallsOverview> {
    assertReportRange(range);
    return withTenant(ctx(me), async (q) => {
      // the function checks the permission and the filters first; the connection state, the lists and the setting follow
      const r = await q.query<CallsDbRow>(`select * from cma.calls_overview($1::date, $2::date, $3, $4, $5)`,
        [range.from, range.to, filter.market, filter.line, group]);
      const connections = await readConnections(q);
      const lists = await callsFilterLists(q, range, filter);
      const current = r.rows.filter((x) => x.period === "current");
      // the previous period the database compared with (like for like: a period that reaches today
      // against the same point in the previous one), named for the deltas; today as the page resolves it
      const prev = previousPeriod(range, dateKeyInZone(new Date(), me.timeZone));
      // where the tenant's telephony history starts (addition 0008k), tenant-wide: a previous span before it shows no change
      const history = await q.query<{ history_start: string | null }>(`select cma.telephony_history_start() as history_start`);
      return {
        ...range, group, filter, telephony: connections.telephony, connectedMinSeconds: await telephonySetting(q),
        rows: connections.telephony ? current.filter((x) => x.group_key !== null).map((x) => ({ groupKey: x.group_key!, groupLabel: x.group_label, ...toCallsFigures(x) })) : [],
        total: toCallsFigures(current.find((x) => x.group_key === null)),
        previous: toCallsFigures(r.rows.find((x) => x.period === "previous")),
        previousFrom: prev.from, previousTo: prev.to, previousPartial: prev.partial,
        historyStart: history.rows[0]?.history_start ?? null,
        ...(connections.telephony ? lists : { markets: [], lines: [] }),
      };
    });
  },

  async getFormsReport(me, range, group, filter): Promise<FormsReport> {
    assertReportRange(range);
    return withTenant(ctx(me), async (q) => {
      // the function checks the permission, the group and the filters first; the lists and the history start follow
      const r = await q.query<FormsDbRow>(`select * from cma.forms_report($1::date, $2::date, $3, $4, $5, $6)`,
        [range.from, range.to, group, filter.market, filter.category, filter.form]);
      const whole = await q.query<FormsDbRow>(`select * from cma.forms_report($1::date, $2::date, 'week', null, null, null) where period = 'current' and group_key is null`,
        [range.from, range.to]);
      const has = await q.query<{ forms: boolean }>(`select exists (select 1 from cma.connection_form) as forms`);
      const history = await q.query<{ history_start: string | null }>(`select cma.forms_history_start() as history_start`);
      const categories = (await q.query<{ code: string; name: string; sort_order: number; status: string; forms: number }>(`select * from cma.form_categories()`)).rows
        .map((x) => ({ code: x.code, name: x.name, sortOrder: x.sort_order, isActive: x.status === "active", forms: x.forms }));
      // the previous period the database compared with (like for like), named for the deltas; today as the page resolves it
      const prev = previousPeriod(range, dateKeyInZone(new Date(), me.timeZone));
      const current = r.rows.filter((x) => x.period === "current");
      const forms = new Map(whole.rows.map((x) => [`${x.connection_id}:${x.form_id}`, x.form_name]));
      return {
        ...range, group, filter, forms: has.rows[0]?.forms ?? false,
        rows: current.filter((x) => x.group_key !== null).map(toFormsRow),
        totals: current.filter((x) => x.group_key === null).map(toFormsRow),
        previous: r.rows.filter((x) => x.period === "previous").map(toFormsRow),
        previousFrom: prev.from, previousTo: prev.to, previousPartial: prev.partial,
        historyStart: history.rows[0]?.history_start ?? null,
        categories,
        formList: [...forms.entries()].map(([key, name]) => ({ key, name })).sort((a, b) => a.name.localeCompare(b.name)),
        markets: [...new Set(whole.rows.map((x) => x.market))].sort((a, b) => (a === "unknown" ? 1 : b === "unknown" ? -1 : a.localeCompare(b))),
      };
    });
  },

  async getFormsAnswers(me, range, filter, field, value): Promise<FormsAnswers> {
    assertReportRange(range);
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{ period: string; connection_id: string; form_id: string; form_name: string; category: string | null; market: string;
        field: string; value: string; submissions: number }>(`select * from cma.forms_answers($1::date, $2::date, $3, $4, $5, $6, $7)`,
        [range.from, range.to, filter.market, filter.category, filter.form, field, value]);
      return {
        ...range, filter, field, value,
        rows: r.rows.map((x): FormAnswerRow => ({
          period: x.period === "previous" ? "previous" : "current", formKey: `${x.connection_id}:${x.form_id}`, formName: x.form_name,
          category: x.category, market: x.market, field: x.field, value: x.value, submissions: x.submissions,
        })),
      };
    });
  },

  async getCallsTagUse(me, range, group, filter): Promise<CallsTagUse> {
    assertReportRange(range);
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{ group_key: string | null; group_label: string | null; tag_key: string | null; tag_name: string | null; is_counted: boolean | null; conversations: number }>(
        `select * from cma.calls_tag_use($1::date, $2::date, $3, $4, $5)`, [range.from, range.to, filter.market, filter.line, group]);
      const connections = await readConnections(q);
      return {
        ...range, group, filter, telephony: connections.telephony,
        rows: connections.telephony ? r.rows.map((x) => ({ groupKey: x.group_key, groupLabel: x.group_label, tagKey: x.tag_key, tagName: x.tag_name,
          isCounted: x.is_counted, conversations: x.conversations })) : [],
      };
    });
  },

  async getCallsPerAgent(me, range, filter): Promise<CallsPerAgent> {
    assertReportRange(range);
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<PersonDbRow>(`select * from cma.calls_per_person($1::date, $2::date, $3, $4)`, [range.from, range.to, filter.market, filter.line]);
      const connections = await readConnections(q);
      const lists = await callsFilterLists(q, range, filter);
      const rows = r.rows.map(toCallsPerson);
      return {
        ...range, filter, telephony: connections.telephony, connectedMinSeconds: await telephonySetting(q),
        rows: connections.telephony ? rows.filter((x) => x.kind !== "total") : [],
        total: rows.find((x) => x.kind === "total")!,
        ...(connections.telephony ? lists : { markets: [], lines: [] }),
      };
    });
  },

  async getCallsPerAgentTags(me, range, filter): Promise<CallsPerAgentTags> {
    assertReportRange(range);
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{ row_kind: "person" | "not_linked"; user_id: string | null; tag_key: string | null; tag_name: string | null; conversations: number }>(
        `select * from cma.calls_per_person_tags($1::date, $2::date, $3, $4)`, [range.from, range.to, filter.market, filter.line]);
      const connections = await readConnections(q);
      return {
        ...range, filter, telephony: connections.telephony,
        rows: connections.telephony ? r.rows.map((x) => ({ kind: x.row_kind === "not_linked" ? "notLinked" as const : "person" as const, userId: x.user_id,
          tagKey: x.tag_key, tagName: x.tag_name, conversations: x.conversations })) : [],
      };
    });
  },

  async getCrmRecordsPerDay(me, range): Promise<CrmRecordsDay[]> {
    assertReportRange(range);
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{ business_date: string; record_type: string; market: string | null; pipeline_id: string | null; pipeline_label: string | null; records: number; closed_now: number }>(
        `select * from cma.crm_records_per_day($1::date, $2::date)`, [range.from, range.to]);
      return r.rows.map((x) => ({ date: x.business_date, recordType: x.record_type, market: x.market, pipelineId: x.pipeline_id,
        pipelineLabel: x.pipeline_label, records: x.records, closedNow: x.closed_now }));
    });
  },

  // ---- Follow-up (addition 0008o): every function checks its permission and reads the current tenant under row-level security.
  // Since addition 0008s they read the snapshot the refresh job computes once a minute (computed once on demand when a tenant has none)
  async getFollowUpPage(me, filter): Promise<FollowUpPage> {
    return withTenant(ctx(me), async (q) => {
      // the function checks the permission, the filters and the per-person figures' permission itself; the rows are capped there
      const j = one((await q.query<{ j: FollowUpPageDb }>(`select cma.follow_up_page($1, $2, $3, null) as j`,
        [filter.market, filter.owner, filter.state])).rows, "follow_up_page").j;
      return {
        computedAt: isoAny(j.computed_at)!, durationMs: j.duration_ms, rows: j.rows, summary: toSummary(j.summary),
        byOwner: j.by_owner ? j.by_owner.map(toOwner) : null,
        options: { markets: j.options.markets, owners: j.options.owners, hasUnowned: j.options.has_unowned },
        settings: { targetMinutes: wholeOrNull(j.settings.target_minutes), warningPct: wholeOrNull(j.settings.warning_pct) },
        counts: { leads: j.counts.lead ?? 0, tickets: j.counts.ticket ?? 0, tasks: j.counts.task ?? 0 },
        leads: { total: j.leads.total, rows: j.leads.rows.map((x) => toOpenLead(x)) },
        tickets: { total: j.tickets.total, rows: j.tickets.rows.map((x) => toOpenTicket(x)) },
        tasks: { total: j.tasks.total, rows: j.tasks.rows.map((x) => toOpenTask(x)) },
      };
    });
  },

  async getOpenLeads(me): Promise<FollowUpRowsAt<OpenLead>> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<OpenLeadDb>(
        `select r.*, u.display_name as owner_name, cma.record_url(r.connection_id, 'deal', r.deal_source_id) as record_url from cma.open_leads() r ${OWNER_JOIN}`);
      return { rows: r.rows.map((x) => toOpenLead(x)), computedAt: await computedAt(q) };
    });
  },

  async getOpenTickets(me): Promise<FollowUpRowsAt<OpenTicket>> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<OpenTicketDb>(
        `select r.*, u.display_name as owner_name, cma.record_url(r.connection_id, 'ticket', r.ticket_source_id) as record_url from cma.open_tickets() r ${OWNER_JOIN}`);
      return { rows: r.rows.map((x) => toOpenTicket(x)), computedAt: await computedAt(q) };
    });
  },

  async getOpenTasks(me): Promise<FollowUpRowsAt<OpenTask>> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<OpenTaskDb>(
        `select r.*, u.display_name as owner_name, cma.record_url(r.connection_id, 'task', r.task_source_id) as record_url from cma.open_tasks() r ${OWNER_JOIN}`);
      return { rows: r.rows.map((x) => toOpenTask(x)), computedAt: await computedAt(q) };
    });
  },

  async getFollowUpSummary(me): Promise<FollowUpSummaryAt> {
    return withTenant(ctx(me), async (q) => {
      const s = one((await q.query<SummaryDb & { computed_at: Date }>(`select * from cma.follow_up_summary()`)).rows, "follow_up_summary");
      return { ...toSummary(s), computedAt: s.computed_at.toISOString() };
    });
  },

  async getFollowUpByOwner(me): Promise<FollowUpRowsAt<FollowUpOwner>> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<OwnerDb>(`select * from cma.follow_up_by_owner()`);
      return { rows: r.rows.map(toOwner), computedAt: await computedAt(q) };
    });
  },

  async getMyFollowUp(me): Promise<MyFollowUp> {
    return withTenant(ctx(me), async (q) => {
      // the function answers the caller's own rows as JSON (snake_case keys, the record links filled in); the owner is the caller
      const j = one((await q.query<{ j: { leads: OpenLeadDb[]; tickets: OpenTicketDb[]; tasks: OpenTaskDb[]; computed_at: string } }>(
        `select cma.my_follow_up() as j`)).rows, "my_follow_up").j;
      return {
        leads: j.leads.map((x) => toOpenLead(x, me.displayName)),
        tickets: j.tickets.map((x) => toOpenTicket(x, me.displayName)),
        tasks: j.tasks.map((x) => toOpenTask(x, me.displayName)),
        computedAt: isoAny(j.computed_at)!,
      };
    });
  },

  // ---- System health (addition 0008r) --------------------------------------------------------

  async getSystemHealthRuns(me): Promise<SystemHealthRun[]> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{
        job: string; connection_id: string | null; last_started_at: Date; last_finished_at: Date | null; last_status: "running" | "succeeded" | "failed";
        last_error: string | null; last_counts: Record<string, number>; last_succeeded_at: Date | null; last_failed_at: Date | null; last_failed_error: string | null;
        runs_24h: number; failed_24h: number;
      }>(`select * from cma.system_health_runs()`);
      return r.rows.map((x) => ({
        job: x.job, connectionId: x.connection_id, lastStartedAt: x.last_started_at.toISOString(),
        lastFinishedAt: x.last_finished_at ? x.last_finished_at.toISOString() : null, lastStatus: x.last_status, lastError: x.last_error,
        lastCounts: x.last_counts ?? {}, lastSucceededAt: x.last_succeeded_at ? x.last_succeeded_at.toISOString() : null,
        lastFailedAt: x.last_failed_at ? x.last_failed_at.toISOString() : null, lastFailedError: x.last_failed_error, runs24h: x.runs_24h, failed24h: x.failed_24h,
      }));
    });
  },

  async getOutboxStatus(me): Promise<OutboxStatusRow[]> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{ connection_id: string; connection_name: string; status: string; actions: number; oldest_at: Date | null; newest_at: Date | null; next_attempt_at: Date | null }>(
        `select * from cma.outbox_status()`);
      return r.rows.map((x) => ({
        connectionId: x.connection_id, connectionName: x.connection_name, status: x.status, actions: x.actions,
        oldestAt: x.oldest_at ? x.oldest_at.toISOString() : null, newestAt: x.newest_at ? x.newest_at.toISOString() : null,
        nextAttemptAt: x.next_attempt_at ? x.next_attempt_at.toISOString() : null,
      }));
    });
  },

  async probeDatabase(me): Promise<DatabaseProbe> {
    // The permission first (the page is tenant.configure's), then one trivial query timed around the whole
    // transaction: checkout, begin, the context, the query, commit. A failure is a null, never an error page
    const t0 = performance.now();
    try {
      await withTenant(ctx(me), async (q) => {
        await q.query(`select cma.assert_permission('tenant.configure')`);
        await q.query(`select 1`);
      });
      return { roundTripMs: Math.round(performance.now() - t0) };
    } catch (e) {
      if (e instanceof CmaDbError && (e.sqlState === "CMA06" || e.sqlState === "CMA01")) throw e;
      console.error(`[cma-data] probe failed: ${e instanceof CmaDbError ? e.sqlState : "error"}`);
      return { roundTripMs: null };
    }
  },
};
