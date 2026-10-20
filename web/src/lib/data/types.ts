/**
 * Data interface between the screens and the data layer.
 *
 * Screens only ever import from "@/lib/data". The mock implementation serves
 * this increment; the API implementation (Postgres as cma_app, after migration
 * 0002) replaces it without touching a component.
 *
 * Every call carries the Principal, so the implementation is tenant-aware and
 * can only return the caller's own data: hours are pay data, never a colleague's.
 */
import type { Identity, Principal } from "@/lib/auth/identity";
import type { HealthRun } from "@/lib/health";

/** ISO 8601 instant, always UTC on the wire; screens format in the user's zone */
export type Instant = string;
/** Calendar date in the user's zone, YYYY-MM-DD */
export type DateKey = string;

export type WorkdayStatus = "working" | "ended";

/**
 * What the clock on My day needs, stable between two status changes (no time-varying field, so
 * two reads of an unchanged day are equal). Worked time counts statuses with is_working only:
 * the same time My hours shows (which hours the agent sees is still open, see README).
 */
export interface WorkdayClock {
  /** Seconds already worked in closed working stretches */
  closedSeconds: number;
  /** Start of the current stretch while the current status is a working one; null while paused or ended */
  runningSince: Instant | null;
}

export interface Workday {
  date: DateKey;
  status: WorkdayStatus;
  startedAt: Instant;
  endedAt: Instant | null;
  /** Key of the current work status; null once the day has ended */
  statusKey: string | null;
  /**
   * Name of the current work status as stored, so the screen can name it even when it is no longer
   * in the choosable list (retired while the person was in it); null once the day has ended
   */
  statusName: string | null;
  /** When the current status began; null once the day has ended */
  statusSince: Instant | null;
  clock: WorkdayClock;
  /**
   * First instant after the working day: the tenant's window end on this date (addition 0008b,
   * 22:00 for Pulse4all, midnight by default). The clock stops counting here; time after it is
   * not counted by the database either
   */
  dayEndsAt: Instant;
}

/**
 * A status the caller can choose: the tenant's own list (work_status), in its order. Names are
 * tenant data, never copy, and no code branches on a key. Pay and billing flags stay out: the
 * screen needs to know whether the clock runs and, for the status colour, whether the work is
 * productive (since 7 October 2026). Whether a pause is paid is not shown to agents.
 */
export interface WorkStatus {
  key: string;
  name: string;
  isWorking: boolean;
  isProductive: boolean;
  isDefault: boolean;
}

export interface HoursDay {
  date: DateKey;
  /** Minutes of workday time; one row per calendar day */
  minutes: number;
  /** Minutes in non-working statuses (break, lunch): the Pauses column (Martin, 7 October 2026) */
  pauseMinutes: number;
  startedAt: Instant | null;
  endedAt: Instant | null;
}

export interface HoursRange {
  from: DateKey;
  to: DateKey;
}

export interface HoursSummary extends HoursRange {
  totalMinutes: number;
  days: HoursDay[];
}

/**
 * Team data (migration 0003), for people holding workday.team. The database checks the permission
 * on every call (CMA06); these shapes carry staff data, never customer data.
 */
export interface TeamDay {
  userId: string;
  displayName: string;
  /** Employer, for hours per employer */
  organisationName: string;
  date: DateKey;
  /** The day's own zone; the editor shows its times in this zone, not the viewer's */
  timeZone: string;
  status: "open" | "ended";
  startedAt: Instant;
  endedAt: Instant | null;
  /** Working minutes (is_working), the figure My hours shows */
  minutes: number;
  /** Paid minutes (is_paid), for payroll */
  paidMinutes: number;
  /** Open past its business day: hours stop at the day's end until someone corrects it */
  isCapped: boolean;
  needsCorrection: boolean;
  hasCorrection: boolean;
}

/** A person whose time is kept, for Add day and the person filter (cma.team_people) */
export interface TeamPerson {
  userId: string;
  displayName: string;
  organisationName: string;
  /** The person's zone; a new day opens in it */
  timeZone: string;
}

export interface TeamHours extends HoursRange {
  days: TeamDay[];
}

export type TimeEventKind = "start" | "status" | "end" | "void";

/**
 * Who entered an event: the person's own click, the system (the forgotten-day close), a correction
 * by a manager, or an import of an earlier system's sessions (addition 0008d)
 */
export type TimeEventSource = "user" | "system" | "correction" | "import";

/** One row of a day, effective or not: corrections never remove a row */
export interface TimeEvent {
  id: string;
  kind: TimeEventKind;
  statusKey: string | null;
  statusName: string | null;
  at: Instant;
  recordedAt: Instant;
  source: TimeEventSource;
  /** The import batch an imported event came from (its key); null for every other source */
  importBatchKey: string | null;
  /** The event this row replaces or cancels */
  supersedes: string | null;
  reason: string | null;
  approvedByName: string | null;
  /** False once a later correction replaced or voided it, and for the void row itself */
  isEffective: boolean;
}

export interface TeamDayDetail {
  /** null when the person has no day on this date */
  day: TeamDay | null;
  events: TimeEvent[];
}

/** One change of a correction; see cma.correct_workday */
export interface CorrectionChange {
  kind: TimeEventKind;
  /** ISO 8601 with an offset; required except for void */
  at?: Instant;
  /** Required for start and status */
  statusKey?: string;
  /** The event this change replaces; required for void */
  supersedes?: string;
}

export interface Correction {
  /** Required, 3 to 500 characters, stored on every row of the edit */
  reason: string;
  changes: CorrectionChange[];
}

/** One effective tenant setting (cma.tenant_settings): the tenant's own value or the default */
export interface TenantSetting {
  key: string;
  value: string;
  isDefault: boolean;
}

/**
 * Export data (migration 0003b), for people holding workday.export. The database checks the
 * permission on every call (CMA06). Seconds, not minutes: the file decides how to write them.
 */
export interface ExportHoursRow {
  userId: string;
  displayName: string;
  organisationName: string;
  date: DateKey;
  timeZone: string;
  status: "open" | "ended";
  startedAt: Instant;
  endedAt: Instant | null;
  workedSeconds: number;
  productiveSeconds: number;
  paidSeconds: number;
  billableSeconds: number;
  isCapped: boolean;
  needsCorrection: boolean;
  hasCorrection: boolean;
}

/** One stretch in a status, from its change to the next effective event of the day */
export interface StatusChangeRow {
  userId: string;
  displayName: string;
  organisationName: string;
  date: DateKey;
  timeZone: string;
  statusKey: string;
  statusName: string;
  isWorking: boolean;
  isProductive: boolean;
  isPaid: boolean;
  isBillable: boolean;
  from: Instant;
  /** null while the stretch is open, also when capped at the end of its business day */
  to: Instant | null;
  isOpen: boolean;
  isCapped: boolean;
  seconds: number;
  /** Who entered the change that began it */
  source: TimeEventSource;
}

/**
 * Time per status (addition 0003c), for people holding performance.team: one row per person per
 * business date per status, summed from the same stretches as Team hours. The database checks the
 * permission on every call (CMA06). Flags as stored, so groups and colours come from them.
 */
export interface StatusTimeRow {
  userId: string;
  displayName: string;
  organisationName: string;
  date: DateKey;
  timeZone: string;
  statusKey: string;
  statusName: string;
  /** The tenant's order of its statuses */
  sortOrder: number;
  /** False for a status set inactive since; its history stays */
  statusActive: boolean;
  isWorking: boolean;
  isProductive: boolean;
  isPaid: boolean;
  isBillable: boolean;
  seconds: number;
  /** How many stretches in this status that day */
  stretches: number;
  /** A stretch that runs to the end of a day not clocked out */
  isCapped: boolean;
}

export interface TeamStatusTime extends HoursRange {
  rows: StatusTimeRow[];
}

/** An export read with the tenant's settings, from one transaction */
export interface Export<Row> {
  settings: TenantSetting[];
  rows: Row[];
}

/**
 * The team now (addition 0003e, cma.team_now), for people holding monitoring.live: one person per
 * row whose time is kept, with today's day in the person's zone as the own-day read shapes it, so
 * a person's own row equals GET /api/v1/me/day field for field. Stable inputs only (closed seconds,
 * running since, status since): the screen ticks on its own and two reads of an unchanged team
 * are equal. The database checks the permission on every call (CMA06). Staff data, never
 * customer data.
 */
export interface TeamNowStatus {
  key: string;
  name: string;
  /** False for a status set inactive since; a day may still run in it */
  isActive: boolean;
  isWorking: boolean;
  isProductive: boolean;
  isPaid: boolean;
  isBillable: boolean;
}

export interface TeamNowPerson {
  userId: string;
  displayName: string;
  /** Employer key, for the employer filter; null for a person without an organisation */
  organisationKey: string | null;
  organisationName: string;
  timeZone: string;
  /** Today in the person's zone */
  date: DateKey;
  /** Today's day; null when the person has no day today (not clocked in) */
  day: Workday | null;
  /** The current status with its flags; null without a day and once the day has ended */
  status: TeamNowStatus | null;
}

export interface TeamNow {
  people: TeamNowPerson[];
  /**
   * The tenant's active statuses with the flags that decide a group, so the board shows a tile
   * only for a group that at least one status belongs to (a tenant without paid pauses gets no
   * Paid pause tile). Keys and names stay out: nothing on the board branches on them.
   */
  statusFlags: { isWorking: boolean; isProductive: boolean; isPaid: boolean }[];
}

/**
 * A button to another application on the Welcome page (cma.app_links, addition 0003d): the tenant's
 * own list, already filtered to what the caller may see. Deep links only, never customer data;
 * no address lives in code.
 */
export interface AppLink {
  key: string;
  label: string;
  /** https only, checked by the database */
  address: string;
}

/**
 * The Team screen (migration 0004): people with role, employer, teams and skills, for people
 * holding users.manage_agents (agents, supervisors and other non-managing roles) or
 * users.manage_all (everyone). The database decides who is listed and who may be edited (CMA06).
 * Staff data, never customer data; the login id never travels back to a screen.
 */
export type SkillDimension = "language" | "work_type" | "channel";

export interface SkillLevel {
  level: number;
  name: string;
}

/** One entry of the tenant's skill catalog with its dimension's scale (empty: held or not) */
export interface SkillInfo {
  dimension: SkillDimension;
  key: string;
  name: string;
  sortOrder: number;
  isActive: boolean;
  levels: SkillLevel[];
}

/** An active employer of the tenant (cma.organisations), for the Add a person dialog */
export interface OrganisationInfo {
  key: string;
  name: string;
  /** The zone a new person follows when they have none of their own */
  timeZone: string;
}

/** A current team of the tenant */
export interface TeamInfo {
  key: string;
  name: string;
  /** Market tokens the team serves (ISO 3166-1 alpha-2 by convention) */
  markets: string[];
  sortOrder: number;
  memberCount: number;
}

/** A role of the tenant's ladder, with whether the caller may assign it */
export interface RoleInfo {
  key: string;
  name: string;
  isSystem: boolean;
  /** Holds users.manage_agents, users.manage_all or tenant.configure: only users.manage_all assigns it */
  isManaging: boolean;
  assignable: boolean;
  permissions: string[];
}

export interface PersonSkill {
  dimension: SkillDimension;
  key: string;
  name: string;
  /** null for a binary dimension */
  level: number | null;
  levelName: string | null;
}

export interface DirectoryPerson {
  userId: string;
  email: string;
  displayName: string;
  isActive: boolean;
  organisationKey: string | null;
  organisationName: string;
  timeZone: string;
  /** null for a person without a role (may not work yet) */
  roleKey: string | null;
  roleName: string | null;
  isManaging: boolean;
  /** Active and holding workday.own: the clock runs for this person */
  timeKept: boolean;
  teams: { key: string; name: string }[];
  skills: PersonSkill[];
  /** Whether the caller may change this person; never for oneself */
  mayEdit: boolean;
}

/** The caller's own details for My account (cma.my_profile, addition 0005b): their own row only */
export interface MyProfile {
  userId: string;
  email: string;
  displayName: string;
  organisationName: string;
  timeZone: string;
  /** null for a person without a role */
  roleName: string | null;
  /** Active and holding workday.own: the clock runs for this person */
  timeKept: boolean;
  teams: { key: string; name: string }[];
  skills: PersonSkill[];
}

export interface AddPersonInput {
  email: string;
  displayName: string;
  organisationKey: string;
  roleKey: string;
  /** The identity provider as stored in app_user_external_id.system (google behind IAP, mock in dev) */
  loginSystem: string;
  loginId: string;
  timeZone: string | null;
}

/** An invitation's state, computed by the database (cma.invitation_state) */
export type InvitationState = "open" | "expired" | "accepted" | "revoked";

/** One row of cma.invitations() (addition 0008l): never a token or its hash */
export interface Invitation {
  invitationId: string;
  email: string;
  displayName: string;
  /** The language of the mail and of the /invite page, a copy locale */
  locale: string;
  roleKey: string;
  roleName: string;
  organisationKey: string;
  organisationName: string;
  teams: { key: string; name: string }[];
  skills: PersonSkill[];
  state: InvitationState;
  createdAt: Instant;
  createdByName: string;
  expiresAt: Instant;
  renewedAt: Instant | null;
  acceptedAt: Instant | null;
  acceptedUserId: string | null;
  acceptedName: string | null;
  revokedAt: Instant | null;
  revokedByName: string | null;
}

export interface CreateInvitationInput {
  email: string;
  displayName: string;
  locale: string;
  roleKey: string;
  organisationKey: string;
  teamKeys: string[];
  skills: SkillInput[];
}

/** The answer to create and renew, the only places a token travels; it is never stored or listed */
export interface InvitationLink {
  invitationId: string;
  token: string;
  expiresAt: Instant;
}

/** What /invite/<token> may show (cma.invitation_preview): read only, never a change */
export interface InvitationPreview {
  /** other_tenant: the sign-in already works in another business line (no tenant picker yet) */
  result: "open" | "invalid" | "expired" | "wrong_account" | "already_member" | "other_tenant";
  tenantName: string | null;
  roleName: string | null;
  /** The invited address: for open and wrong_account only, to the link's holder */
  invitedEmail: string | null;
  locale: string | null;
  expiresAt: Instant | null;
}

export type InvitationAcceptResult = "accepted" | "invalid" | "expired" | "wrong_account" | "already_member" | "other_tenant";

/** A skill to set on a person: the level for a scaled dimension, left out for a binary one */
export interface SkillInput {
  key: string;
  level?: number;
}

/** A person's current team, for the Live board's team filter (cma.team_members_now) */
export interface TeamMembership {
  userId: string;
  teamKey: string;
  teamName: string;
}


/**
 * Configuration (migration 0005a), for people holding tenant.configure; the database checks on
 * every read and write (CMA06). Everything here is tenant configuration: statuses with their
 * flags, app links, absence types, coverage targets, export settings. No code branches on a key.
 */
export interface ConfigStatus {
  key: string;
  name: string;
  isWorking: boolean;
  isProductive: boolean;
  isPaid: boolean;
  isBillable: boolean;
  isDefault: boolean;
  sortOrder: number;
  /** Retired statuses keep their history and cannot be chosen */
  isActive: boolean;
  /** Time events recorded in this status; the flags of a status with any are frozen */
  usageCount: number;
}

export interface ConfigStatusInput {
  key: string;
  name: string;
  isWorking: boolean;
  isProductive: boolean;
  isPaid: boolean;
  isBillable: boolean;
  sortOrder: number;
}

export interface ConfigAppLink {
  key: string;
  label: string;
  /** https only, checked by the database */
  address: string;
  /** null: everyone with a role */
  permissionKey: string | null;
  sortOrder: number;
  isActive: boolean;
}

export interface ConfigAppLinkInput {
  key: string;
  label: string;
  address: string;
  permissionKey: string | null;
  sortOrder: number;
}

/** A permission of the catalog, for the app link's permission choice */
export interface PermissionInfo {
  key: string;
  description: string;
}

export interface AbsenceTypeInput {
  key: string;
  name: string;
  isPaid: boolean;
  sortOrder: number;
}

/** How many people holding a work type a team wants on an ISO weekday (1 Monday to 7 Sunday) */
export interface CoverageTargetRow {
  teamKey: string;
  skillKey: string;
  weekday: number;
  minCount: number;
}

export interface TeamInput {
  key: string;
  name: string;
  markets: string[];
  sortOrder: number;
}

export interface SkillInputRow {
  dimension: SkillDimension;
  key: string;
  name: string;
  sortOrder: number;
}

/**
 * The roster (migration 0005). The planner's reads and writes need roster.manage, the own schedule
 * roster.view (published entries only), today's shifts monitoring.live; the database checks on
 * every call (CMA06). Times are local hh:mm in each person's own zone, within the business day
 * (no shift crosses midnight); dates are business dates. Staff data only.
 */
export interface AbsenceType {
  key: string;
  name: string;
  isPaid: boolean;
  sortOrder: number;
  isActive: boolean;
}

export interface RosterWeekHeader {
  /** null until the week has been written */
  weekId: string | null;
  /** null for a roster of the whole tenant */
  teamKey: string | null;
  teamName: string | null;
  weekStart: DateKey;
  status: "draft" | "published";
  /** How many times published; 0 for a draft */
  version: number;
  publishedAt: Instant | null;
  publishedByName: string | null;
  entryCount: number;
  /** Edited after the last publish: the agent still sees that publish until the next one */
  changedSincePublish: boolean;
}

/** One row of the planner's grid: a person whose time is kept, on this roster this week */
export interface RosterPerson {
  userId: string;
  displayName: string;
  organisationName: string;
  timeZone: string;
  teamKeys: string[];
  /** Work-type skill keys held now, for coverage */
  workTypeKeys: string[];
}

export interface RosterEntry {
  entryId: string;
  userId: string;
  date: DateKey;
  kind: "shift" | "absence";
  /** hh:mm:ss local; null for an absence */
  start: string | null;
  end: string | null;
  absenceKey: string | null;
  absenceName: string | null;
  note: string | null;
  recordedAt: Instant;
  recordedByName: string;
}

export interface RosterCoverageRow {
  date: DateKey;
  skillKey: string;
  skillName: string;
  plannedPeople: number;
  peopleNames: string[];
  target: number | null;
}

export interface RosterWeek {
  header: RosterWeekHeader;
  people: RosterPerson[];
  entries: RosterEntry[];
  coverage: RosterCoverageRow[];
}

/** One week of the range: the state of the roster of a team (or the tenant) for that week; an unwritten week is a draft at version 0 with no entries */
export interface RosterWeekSummary {
  weekStart: DateKey;
  status: "draft" | "published";
  version: number;
  publishedAt: Instant | null;
  entryCount: number;
  shiftCount: number;
}

/** A cell as the planner sets it; clear removes the entry */
export type RosterCellInput =
  | { kind: "shift"; start: string; end: string; note?: string | null }
  | { kind: "absence"; absenceKey: string; note?: string | null }
  | { kind: "clear" };

/** One day of a person's own schedule: published entries only */
export interface MyRosterDay {
  date: DateKey;
  /** False when no published roster covers this person on that date */
  isPublished: boolean;
  kind: "shift" | "absence" | null;
  start: string | null;
  end: string | null;
  absenceKey: string | null;
  absenceName: string | null;
  note: string | null;
  teamName: string | null;
  publishedAt: Instant | null;
}

/** Today's published entry per person whose time is kept, for the Live board (cma.roster_today) */
export interface TodayShift {
  userId: string;
  date: DateKey;
  isPublished: boolean;
  kind: "shift" | "absence" | null;
  start: string | null;
  end: string | null;
  absenceName: string | null;
}

// ---- Messaging (migration 0008): references only, never customer data

export type MessageKind = "alert" | "announcement";
export type MessageUrgency = "normal" | "urgent";

/** The record a message points to: the adapter, the record type, the source id and an https link */
export interface MessageRef {
  system: string;
  type: string;
  id: string;
  url: string | null;
}

/** One of the caller's own deliveries (cma.my_messages): the message plus the caller's three times */
export interface MyMessage {
  id: string;
  kind: MessageKind;
  urgency: MessageUrgency;
  title: string;
  body: string;
  ref: MessageRef | null;
  createdAt: Instant;
  expiresAt: Instant | null;
  /** Set by the first poll that returned the message */
  deliveredAt: Instant | null;
  readAt: Instant | null;
  acknowledgedAt: Instant | null;
}

export interface MyMessages {
  /** Newest first */
  messages: MyMessage[];
  /** Unread, unexpired deliveries of the caller, all of them, not only the listed ones */
  unreadCount: number;
}

/**
 * The target of a manual message, exactly one group (cma.send_message): everyone, teams by key, a
 * language skill with a minimum level, or named people; optionally only those clocked in now
 */
export type MessageTarget =
  | { everyone: true; onlyClockedIn?: boolean }
  | { teams: string[]; onlyClockedIn?: boolean }
  | { language: { skill: string; minLevel: number | null }; onlyClockedIn?: boolean }
  | { users: string[]; onlyClockedIn?: boolean };

export interface SendMessageInput {
  title: string;
  body: string;
  urgency: MessageUrgency;
  target: MessageTarget;
}

export interface SentMessage {
  id: string;
  /** Recipients resolved at send time */
  recipients: number;
}

/** One sent message with its delivery figures (cma.message_stats) */
export interface MessageStat {
  id: string;
  kind: MessageKind;
  urgency: MessageUrgency;
  title: string;
  ref: Omit<MessageRef, "url"> | null;
  /** True for an alert raised by a rule, false for a person's message */
  byRule: boolean;
  createdAt: Instant;
  recipients: number;
  delivered: number;
  read: number;
  acknowledged: number;
  medianSecondsToRead: number | null;
  /** When it was withdrawn for everyone (0008z); null while it stands */
  withdrawnAt: Instant | null;
}

// ---- Intake reports (migration 0007d and 0006; B11, 12 October 2026). Ids, counts and codes only:
// no customer name, email or phone number reaches these shapes.

/** How cma.speed_to_lead_summary groups its rows */
export type SpeedToLeadGroup = "day" | "market" | "agent" | "pipeline";

/** called: an outbound call reached the deal; otherwise not called, open or closed */
export type SpeedToLeadStatus = "called" | "not_called_open" | "not_called_closed";

/** One lead deal (cma.speed_to_lead_rows) with the link to its record (cma.record_url, null without a template) */
export interface SpeedToLeadRow {
  dealId: string;
  connectionId: string;
  /** The deal's id in the CRM */
  dealSourceId: string;
  pipelineId: string | null;
  pipelineLabel: string | null;
  /** Business date of the deal's creation in the tenant's zone */
  date: DateKey;
  createdAt: Instant;
  /** A catalog market code, or "unknown" (then the business measures are null) */
  market: string;
  /** Where the market came from: "record", "contact" or null for unknown */
  marketSource: string | null;
  isClosed: boolean;
  status: SpeedToLeadStatus;
  /** The first outbound call's id in the CRM */
  firstCallSourceId: string | null;
  firstCallAt: Instant | null;
  firstCallLinked: boolean | null;
  firstAnyCallAt: Instant | null;
  firstAnyDirection: string | null;
  inboundFirst: boolean;
  firstConnectedAt: Instant | null;
  /** The CMA person behind the call's or the deal's owner; null when the owner is not mapped */
  agentUserId: string | null;
  /** "call" or "deal": whose owner the agent came from; null without an owner */
  agentFrom: string | null;
  elapsedSeconds: number | null;
  businessSeconds: number | null;
  targetSeconds: number | null;
  /** null while a deal not yet called can still make it */
  withinTarget: boolean | null;
  nextBusinessNoon: Instant | null;
  beforeNextNoon: boolean | null;
  /** Office seconds waited so far, for open deals not called */
  waitingBusinessSeconds: number | null;
  recordUrl: string | null;
}

/** One group of cma.speed_to_lead_summary */
export interface SpeedToLeadSummaryRow {
  /** The business date, the market code, the agent's user id or "unknown", or connection:pipeline */
  groupKey: string;
  /** The date, the market, the agent's name or the pipeline label; null for an agent who is not mapped */
  groupLabel: string | null;
  deals: number;
  called: number;
  medianBusinessMinutes: number | null;
  p80BusinessMinutes: number | null;
  withinTargetPct: number | null;
  beforeNextNoonPct: number | null;
  openNotCalled: number;
}

export interface SpeedToLeadSummary {
  from: DateKey;
  to: DateKey;
  group: SpeedToLeadGroup;
  rows: SpeedToLeadSummaryRow[];
}

/**
 * Which kinds of source the tenant has connected. Telephony: an active connection with a line in the
 * telephony catalog or a telephony call (migration 0007a); commerce: an active connection with its
 * store (0007b, one store per commerce connection).
 */
export interface SourceConnections {
  telephony: boolean;
  commerce: boolean;
}

/**
 * Per business date and market (cma.intake_per_day). Telephony figures are null when the tenant has
 * no telephony connected, commerce figures null without a shop: never 0 for a source that is not there.
 */
export interface IntakeDay {
  date: DateKey;
  market: string;
  formSubmissions: number;
  dealsCreated: number;
  dealsClosed: number;
  ticketsCreated: number;
  ticketsClosed: number;
  callsIn: number | null;
  callsOut: number | null;
  taggedCalls: number | null;
  newCustomers: number | null;
  firstOrders: number | null;
  repeatOrders: number | null;
  renewals: number | null;
}

export interface Intake {
  from: DateKey;
  to: DateKey;
  connections: SourceConnections;
  /** The tenant's intake.start_date: nothing before it is counted */
  startDate: DateKey | null;
  rows: IntakeDay[];
}

/**
 * One check of cma.data_quality(); total null for a check whose source is not installed. The outbox
 * guard's row (outbox_pending, brief A5) follows them while its count is above 0 (reports.ts)
 */
export interface DataQualityCheck {
  key: string;
  /** The database's own description, for a check this screen does not know yet */
  description: string;
  total: number | null;
}

/** Records created per business date, type, market and pipeline (cma.crm_records_per_day, 0006) */
export interface CrmRecordsDay {
  date: DateKey;
  recordType: string;
  /** As the source wrote it; null without a market */
  market: string | null;
  pipelineId: string | null;
  pipelineLabel: string | null;
  records: number;
  closedNow: number;
}

// ---- Inbound service and callbacks (addition 0008i; brief B15, 14 October 2026). Ids, codes, line names
// and counts only: no number, no name and never the caller's hash reach these shapes.

/** How cma.inbound_service groups its calls */
export type InboundGroup = "day" | "market" | "line" | "hour";

/** A missed-reason code as the tenant's catalog holds it (cma.missed_reasons); a code without a row counts with the defaults */
export interface MissedReason {
  sourceSystem: string;
  code: string;
  label: string;
  countsInServiceLevel: boolean;
  needsCallback: boolean;
}

/** The measures of a set of inbound calls (one group, the total, or today) */
export interface InboundFigures {
  /** Inbound calls on counted lines */
  offered: number;
  answered: number;
  /** Not answered and no longer waiting */
  unanswered: number;
  /** No outcome yet: not answered, not ended, started within telephony.waiting_max_minutes */
  waiting: number;
  answeredWithinTarget: number;
  /** The service level's denominator: answered calls and unanswered calls whose reason counts */
  serviceLevelBase: number;
  /** 0 to 100 with one decimal; null without a call in the denominator */
  serviceLevelPct: number | null;
  avgAnswerSeconds: number | null;
  p80AnswerSeconds: number | null;
  /** Unanswered calls per reason code ("unknown" for a call without a reason) */
  unansweredByReason: Record<string, number>;
}

/** One group of cma.inbound_service */
export interface InboundServiceRow extends InboundFigures {
  /** The business date, the market code ("unknown" without one), connection:line ref, or the hour 00 to 23 */
  groupKey: string;
  /** The date, the market, the line's name, or the hour; null for a call without a line */
  groupLabel: string | null;
}

export interface InboundService {
  from: DateKey;
  to: DateKey;
  group: InboundGroup;
  /** False when the tenant has no telephony connected: the screen says so, never 0 */
  telephony: boolean;
  /** telephony.service_level_seconds and telephony.waiting_max_minutes, for the hints */
  serviceLevelSeconds: number;
  waitingMaxMinutes: number;
  /** The tenant's catalog, for the labels of the reason columns */
  reasons: MissedReason[];
  rows: InboundServiceRow[];
  /** Over every call of the period (the database's own total, not a sum of the groups) */
  total: InboundFigures;
}

/** Today's inbound in the tenant's zone, for the Live board (cma.inbound_today) */
export interface InboundToday extends InboundFigures {
  date: DateKey;
  waitingNow: number;
  /** Seconds the longest waiting call has waited; null when nobody waits */
  longestWaitingSeconds: number | null;
  serviceLevelSeconds: number;
  waitingMaxMinutes: number;
}

/** A caller's latest missed inbound call not called back (cma.missed_callbacks); never the caller's hash */
export interface MissedCallback {
  callId: string;
  connectionId: string;
  /** The call's id in the telephony system */
  sourceId: string;
  lineRef: string | null;
  lineName: string | null;
  /** A catalog market code, or "unknown" */
  market: string;
  reasonCode: string;
  reasonLabel: string;
  startedAt: Instant;
  /** The caller's missed calls in the lookback */
  missedCount: number;
  waitingSeconds: number;
  /** Office seconds since the call in the line's market; null for a line without a market */
  waitingBusinessSeconds: number | null;
  /** The call in its own system, from the connection's record_url_call template; null without one */
  recordUrl: string | null;
}

/** The Live board's inbound part (monitoring.live) */
export interface InboundNow {
  /** False when the tenant has no telephony connected: the board says so, never 0 */
  telephony: boolean;
  today: InboundToday | null;
  callbacks: MissedCallback[];
  /** Missed calls without a caller's hash in the lookback that need a callback: counted, never listed */
  anonymousCount: number;
  lookbackDays: number;
}

// ---- Calls overview and calls per agent (addition 0008j; brief B16, 14 October 2026). Counts, seconds,
// line names, tag names and the names of the organisation's own people only: no number, no customer name,
// no call id, no telephony user id and never the caller's hash reach these shapes.

/** How cma.calls_overview and cma.calls_tag_use group the calls */
export type CallsGroup = "day" | "week" | "market" | "line";

/** The market and line filters of both Calls pages: a market code ("unknown" for a line without one) and a connection:line key, each null for all */
export interface CallsFilter {
  market: string | null;
  line: string | null;
}

/** The figures of a set of calls (one group, the period's total or the previous period's) */
export interface CallsFigures {
  /** Calls on counted lines, both directions */
  calls: number;
  inbound: number;
  outbound: number;
  answeredInbound: number;
  /** Outbound calls with at least telephony.connected_min_seconds of talk time */
  connectedOutbound: number;
  /** 0 to 100 with one decimal; null without an outbound call */
  connectedPct: number | null;
  /** Answered inbound and connected outbound calls */
  conversations: number;
  /** Talk time (answer to end, no ringing) over the conversations, in seconds */
  talkSeconds: number;
  talkAvgSeconds: number | null;
  /** Talk time over the connected outbound calls */
  outboundTalkSeconds: number;
  outboundTalkAvgSeconds: number | null;
  /** Conversations without a current tag of any kind */
  untaggedConversations: number;
}

/** One group of cma.calls_overview */
export interface CallsRow extends CallsFigures {
  /** The business date, the ISO week's Monday, the market code ("unknown" without one) or connection:line ref */
  groupKey: string;
  /** The date, the Monday, the market or the line's name; null for a call without a line */
  groupLabel: string | null;
}

/** A line the filter can choose: its key and its name in the phone system */
export interface CallsLine {
  key: string;
  name: string | null;
}

export interface CallsOverview {
  from: DateKey;
  to: DateKey;
  group: CallsGroup;
  filter: CallsFilter;
  /** False when the tenant has no telephony connected: the screen says so, never 0 */
  telephony: boolean;
  /** telephony.connected_min_seconds, for the hints */
  connectedMinSeconds: number;
  rows: CallsRow[];
  /** Over every call of the period (the database's own total, not a sum of the groups) */
  total: CallsFigures;
  /**
   * The same totals over the previous period, for the deltas, like for like: a period that ended compares
   * with the whole previous equal period; one that reaches today with the same elapsed dates, the last of
   * them up to the current time of day (previousPartial). previousTo falls before previousFrom for a period
   * that starts after today: nothing to compare with
   */
  previous: CallsFigures;
  previousFrom: DateKey;
  previousTo: DateKey;
  /** The period reaches today, so the previous one is cut to the same point: "the same point in the previous period" */
  previousPartial: boolean;
  /**
   * The business date of the tenant's earliest stored call (cma.telephony_history_start, addition 0008k):
   * tenant-wide, whatever the market and line filters; null without a call. A previous span that starts
   * before it shows no change on any tile (previousBeforeHistory in lib/reports)
   */
  historyStart: DateKey | null;
  /** The markets and lines with calls in the period, for the filters (the line list within the chosen market) */
  markets: string[];
  lines: CallsLine[];
}

/** Conversations carrying a current tag, or without one (tagKey null), per group or over the whole period (groupKey null) */
export interface TagUseRow {
  groupKey: string | null;
  groupLabel: string | null;
  /** connection id ':' tag ref; null for the untagged conversations */
  tagKey: string | null;
  tagName: string | null;
  /** Whether the tag counts (configuration); null for the untagged row */
  isCounted: boolean | null;
  conversations: number;
}

export interface CallsTagUse {
  from: DateKey;
  to: DateKey;
  group: CallsGroup;
  filter: CallsFilter;
  telephony: boolean;
  rows: TagUseRow[];
}

/** One row of cma.calls_per_person: a person, the calls of telephony users without a person, or the total */
export interface CallsPerson {
  kind: "person" | "notLinked" | "total";
  /** The person (kind person); null otherwise */
  userId: string | null;
  name: string | null;
  /** How many telephony users have calls but no person (kind notLinked); never who they are */
  unlinkedUsers: number | null;
  answeredInbound: number;
  inboundTalkSeconds: number;
  inboundTalkAvgSeconds: number | null;
  outboundCalls: number;
  connectedOutbound: number;
  outboundTalkSeconds: number;
  outboundTalkAvgSeconds: number | null;
  conversations: number;
  untaggedConversations: number;
  /** The earliest and latest time of day ("HH:MM") of a call of theirs on any day of the period, in the line's market zone */
  firstCallTime: string | null;
  lastCallTime: string | null;
}

export interface CallsPerAgent {
  from: DateKey;
  to: DateKey;
  filter: CallsFilter;
  telephony: boolean;
  connectedMinSeconds: number;
  /** The people by name, then the not-linked row when there is one */
  rows: CallsPerson[];
  total: CallsPerson;
  markets: string[];
  lines: CallsLine[];
}

/** A person's (or the not-linked calls') conversations per counted tag; tagKey null for their untagged conversations */
export interface CallsPersonTag {
  kind: "person" | "notLinked";
  userId: string | null;
  tagKey: string | null;
  tagName: string | null;
  conversations: number;
}

export interface CallsPerAgentTags {
  from: DateKey;
  to: DateKey;
  filter: CallsFilter;
  telephony: boolean;
  rows: CallsPersonTag[];
}

// ---- Forms reporting (addition 0008p; brief B17d, 16 October 2026). Form and field names, option values,
// category codes and names, market codes and counts only: no submission id, no contact id, no email, no
// answer to a field that is no choice field.

/** How cma.forms_report groups the submissions over time */
export type FormsGroup = "day" | "week";

/**
 * The report's filters: a market code ("unknown" for a submission without one), a category code ("none" for
 * forms without one) and a form (connection id ':' form id); each null for all
 */
export interface FormsFilter {
  market: string | null;
  category: string | null;
  form: string | null;
}

/** How the submissions' contacts were resolved by the submitted email (never shown) */
export interface FormsResolution {
  resolved: number;
  notFound: number;
  ambiguous: number;
  noEmail: number;
  pending: number;
}

/** The submissions of one form in one market, over one day or ISO week (groupKey) or the whole period (groupKey null) */
export interface FormsRow extends FormsResolution {
  /** The business date or the week's Monday; null for the period */
  groupKey: DateKey | null;
  /** connection id ':' form id, as the form filter takes it */
  formKey: string;
  formName: string;
  /** A code of the tenant's form categories, or null */
  category: string | null;
  /** A market code, or "unknown" */
  market: string;
  submissions: number;
}

/** A form category (configuration, cma.form_category): what a form is for, as the tenant names it */
export interface FormCategory {
  code: string;
  name: string;
  sortOrder: number;
  isActive: boolean;
  /** How many forms carry it */
  forms: number;
}

export interface FormsReport {
  from: DateKey;
  to: DateKey;
  group: FormsGroup;
  filter: FormsFilter;
  /** False when no source of the tenant has a form: the screen says so, never 0 */
  forms: boolean;
  /** Per day or week, form and market */
  rows: FormsRow[];
  /** Per form and market over the period */
  totals: FormsRow[];
  /** Per form and market over the previous period, like for like (as the Calls report: previousPeriod in lib/reports) */
  previous: FormsRow[];
  previousFrom: DateKey;
  previousTo: DateKey;
  previousPartial: boolean;
  /** The business date of the tenant's earliest stored submission (cma.forms_history_start); null without one */
  historyStart: DateKey | null;
  categories: FormCategory[];
  /** The forms and markets with submissions in the period, for the filters */
  formList: { key: string; name: string }[];
  markets: string[];
}

/** Submissions per form, market, kept field and option value (a multiple-checkboxes answer under each of its values) */
export interface FormAnswerRow {
  period: "current" | "previous";
  formKey: string;
  formName: string;
  category: string | null;
  market: string;
  field: string;
  value: string;
  submissions: number;
}

export interface FormsAnswers {
  from: DateKey;
  to: DateKey;
  filter: FormsFilter;
  field: string | null;
  value: string | null;
  rows: FormAnswerRow[];
}

/** A form category as the Sources page saves it (set_form_category, set_form_category_status) */
export interface FormCategoryInput {
  code: string;
  name: string;
  sortOrder: number;
  isActive: boolean;
}

// ---- Email reports (addition 0008t; brief N19-A part 1, 18 October 2026). Ids, codes, counts and times
// only: no subject, body, address, name or phone number exists to show. Mailboxes are the inboxes' channel
// accounts; an engagement's origin tells inbox copies and automations apart, as configuration.

/** How cma.email_report groups the period over time */
export type EmailGroup = "day" | "week";

/**
 * The report's filters: a market code ("unknown" for an email without one), an inbox and a mailbox (each
 * connection id ':' source id); each null for all. An engagement has no inbox or mailbox, so either filter
 * leaves engagements out
 */
export interface EmailFilter {
  market: string | null;
  inbox: string | null;
  account: string | null;
}

/** The figures of a group, the period or the previous period (cma.email_figures_of) */
export interface EmailFigures {
  /** Inbox messages in or forwarded on counted inboxes, mailboxes and channels, spam left out */
  received: number;
  /** Engagements in or forwarded (logged replies): a column of their own, never added to received */
  loggedReplies: number;
  /** Out and sent by an agent (inbox messages and engagements that are no inbox copy and no automation) */
  sentAgent: number;
  /** Out and sent by an automation (the connection's automated origins, or a bot, an AI, the system, an integration) */
  sentAutomated: number;
  bouncedFailed: number;
  /** Conversations created, or reopened after a close */
  threadsOpened: number;
  threadsClosed: number;
  /** Openings with a first agent reply */
  replied: number;
  replyMedianSeconds: number | null;
  /** In the conversation's market's office hours; null when no opening had them */
  replyMedianBusinessSeconds: number | null;
  /** Openings replied within email.reply_target_minutes, of those whose market has office hours */
  withinTarget: number;
  targetKnown: number;
  /** Replied openings of an unknown market: no business hours */
  noHours: number;
  closeMedianSeconds: number | null;
  closeMedianBusinessSeconds: number | null;
}

/** The figures of one group: a date or a week's Monday, a market, an inbox, a mailbox or a category ('none' for an email without one) */
export interface EmailRow extends EmailFigures {
  groupKey: string;
  groupLabel: string | null;
}

/** Received inbox messages per date (or week) and inbox or mailbox, for the columns */
export interface EmailSeriesRow {
  groupKey: DateKey;
  seriesKey: string;
  seriesLabel: string | null;
  received: number;
}

/** A conversation waiting now: ids, ages and its link only */
export interface EmailWaitingRow {
  connectionId: string;
  threadId: string;
  inboxName: string | null;
  accountName: string | null;
  market: string;
  waitingSince: Instant;
  waitedSeconds: number;
  /** In the market's office hours; null for an unknown market (no business hours) */
  waitedBusinessSeconds: number | null;
  recordUrl: string | null;
}

/** An open lead deal not responding: ids, ages and its link only */
export interface EmailNotRespondingRow {
  connectionId: string;
  dealId: string;
  pipelineLabel: string;
  market: string;
  /** The deal's owner as a person; null when the owner maps to nobody */
  ownerUserId: string | null;
  ownerName: string | null;
  lastEmailAt: Instant;
  daysSince: number;
  recordUrl: string | null;
}

export interface EmailReport {
  from: DateKey;
  to: DateKey;
  group: EmailGroup;
  filter: EmailFilter;
  /** False when no source of the tenant has an inbox or an email: the screen says so, never 0 */
  email: boolean;
  /** Per date or week */
  rows: EmailRow[];
  total: EmailFigures;
  /** The previous period's total, like for like (as Calls) */
  previous: EmailFigures;
  previousFrom: DateKey;
  previousTo: DateKey;
  previousPartial: boolean;
  /** The business date of the tenant's earliest counted email (cma.email_history_start); null without one */
  historyStart: DateKey | null;
  byInbox: EmailRow[];
  byAccount: EmailRow[];
  byCategory: EmailRow[];
  byMarket: EmailRow[];
  receivedByInbox: EmailSeriesRow[];
  receivedByAccount: EmailSeriesRow[];
  /** The tenant's settings the hints name */
  replyTargetMinutes: number;
  noResponseDays: number;
  waiting: { rows: EmailWaitingRow[]; total: number };
  notResponding: { rows: EmailNotRespondingRow[]; total: number };
  /** The lists for the filters: markets, inboxes and mailboxes with email in the period */
  markets: string[];
  inboxes: { key: string; name: string }[];
  accounts: { key: string; name: string }[];
}

/** One row of cma.email_per_person: a person, the not-linked actions, or the total */
export interface EmailPerson {
  kind: "person" | "notLinked" | "total";
  userId: string | null;
  name: string | null;
  /** How many owner ids act without a person (kind notLinked); never which */
  unlinkedOwners: number | null;
  sent: number;
  replies: number;
  threadsClosed: number;
  replyMedianSeconds: number | null;
  replyMedianBusinessSeconds: number | null;
  withinTarget: number;
  targetKnown: number;
  /** Agent sends per hour of day (0 to 23), in each email's market zone */
  sentByHour: number[];
}

export interface EmailPerAgent {
  from: DateKey;
  to: DateKey;
  filter: EmailFilter;
  email: boolean;
  /** People by name, then the not-linked row when there is one */
  rows: EmailPerson[];
  total: EmailPerson;
  replyTargetMinutes: number;
  markets: string[];
  inboxes: { key: string; name: string }[];
  accounts: { key: string; name: string }[];
}

// ---- First orders (addition 0008u; brief N19-A part 2, 18 October 2026): of the new first orders, which came
// in by self-service and which through the call center. Ids, codes, counts, amounts and times only: no name,
// address or phone number exists to show; a phone is "hashed" or not.

/** How cma.first_orders_report groups the period */
export type FirstOrderGroup = "day" | "week" | "market" | "level";

/** The evidence of a first order, as attribution.level_order names it */
export type FirstOrderEvidence = "lead_deal" | "conversation" | "email" | "phone_match" | "attempt" | "known_contact";

/** A first order's level: the first evidence in the tenant's level order that holds, else self_service */
export type FirstOrderLevel = FirstOrderEvidence | "self_service";

/** Where a first order came in: the call center when its level is an assisted one, else self-service */
export type FirstOrderAttribution = "call_center" | "self_service";

/** The report's filters: a market code ("unknown" for a deal without one) and a level; each null for all */
export interface FirstOrderFilter {
  market: string | null;
  level: FirstOrderLevel | null;
}

/** The figures of a group, the period or the previous period (cma.first_orders_figures_of) */
export interface FirstOrderFigures {
  /** Won order deals whose contact has no earlier one and whose store order is no renewal or repeat */
  firstOrders: number;
  callCenter: number;
  selfService: number;
  /** Counted apart, never attributed: the contact's later orders, renewals, orders the store counts as repeat, deals without a contact */
  repeats: number;
  renewals: number;
  notFirst: number;
  noContact: number;
  /** First orders with a touch in the window, and the median days from the first touch to the order */
  withTouch: number;
  daysMedian: number | null;
}

export interface FirstOrderRow extends FirstOrderFigures {
  /** A date, a Monday, a market code or a level */
  groupKey: string;
}

/** First orders' amounts in one currency (never summed across currencies); currency null for orders without one */
export interface FirstOrderAmount {
  market: string | null;
  currency: string | null;
  orders: number;
  amount: number | null;
  callCenterAmount: number;
  selfServiceAmount: number;
}

/** One first order of the list: ids, market, time, level, evidence, the link; no name, address or number */
export interface FirstOrderListRow {
  connectionId: string;
  dealSourceId: string;
  market: string;
  createdAt: Instant;
  level: FirstOrderLevel;
  attribution: FirstOrderAttribution;
  evidence: Record<FirstOrderEvidence, boolean>;
  /** The linked store order or its customer carries a phone hash (phone matching possible) */
  phoneHashed: boolean;
  hasOrder: boolean;
  currency: string | null;
  amount: number | null;
  daysFromFirstTouch: number | null;
  recordUrl: string | null;
}

/** The tenant's attribution settings, for the hints and the order of the levels */
export interface AttributionSettings {
  windowDays: number;
  levelOrder: FirstOrderEvidence[];
  assistedLevels: FirstOrderEvidence[];
  knownContactMinutes: number;
  orderMatchMinutes: number;
}

export interface FirstOrdersReport {
  from: DateKey;
  to: DateKey;
  group: FirstOrderGroup;
  filter: FirstOrderFilter;
  /** An order pipeline is set (Configuration, Sources); false: "No orders connected", never 0 */
  connected: boolean;
  /** Per group of the grouping, in order */
  rows: FirstOrderRow[];
  total: FirstOrderFigures;
  /** The previous period's total, like for like */
  previous: FirstOrderFigures;
  previousFrom: DateKey;
  previousTo: DateKey;
  previousPartial: boolean;
  byLevel: FirstOrderRow[];
  byMarket: FirstOrderRow[];
  amounts: FirstOrderAmount[];
  amountsByMarket: FirstOrderAmount[];
  list: { rows: FirstOrderListRow[]; total: number };
  /** The first date whose window the stored data covers; the phone tier's own start */
  historyStart: DateKey | null;
  phoneStart: DateKey | null;
  settings: AttributionSettings;
  markets: string[];
}

/** A person's credited first orders (the owner of the latest assisted touch), or the not-linked row, or the total */
export interface OrderPerson {
  kind: "person" | "notLinked" | "total";
  userId: string | null;
  name: string | null;
  /** How many owner ids without a person (the not-linked row only), never which */
  unlinkedOwners: number | null;
  orders: number;
  leadDeal: number;
  conversation: number;
  email: number;
  phoneMatch: number;
  otherLevels: number;
  daysMedian: number | null;
}

export interface OrdersPerPerson {
  from: DateKey;
  to: DateKey;
  filter: FirstOrderFilter;
  connected: boolean;
  rows: OrderPerson[];
  total: OrderPerson;
  settings: AttributionSettings;
  markets: string[];
}

// ---- Attempts per deal (addition 0008y; for sales since 0008z, 20 October 2026): how many attempts a sales deal gets,
// how often and how soon they reach the customer, won against lost, and how long the open deals have waited since their
// last attempt. Ids, codes, counts, links and times only; a person's name on Attempts per agent, and on one deal's
// attempts only while the per-person figures for attempts are on and the reader holds performance.team.

/** How cma.attempts_per_deal_page groups the period */
export type AttemptGroup = "day" | "week" | "market" | "pipeline";

/**
 * A deal's outcome: won or lost by its stage; ordered when the customer ordered another way while the deal was open and
 * not won (the window ended at that order); unknown for a closed stage without an outcome; else open
 */
export type AttemptOutcome = "open" | "won" | "lost" | "ordered" | "unknown";

/** Why a deal's window ended: its close, its contacts' first order, or not yet (now) */
export type AttemptWindowEnd = "closed" | "ordered" | "open";

/** The attempted filter: every deal, the deals with no attempt yet, the deals with at least one */
export type AttemptAttempted = "all" | "none" | "some";

/** The outcome filter */
export type AttemptOutcomeFilter = "all" | "open" | "won" | "lost" | "ordered";

/** What counts as an attempt (attempts.source): an outbound telephony call on the deal's contacts, or every outbound CRM call */
export type AttemptSource = "telephony" | "crm";

/** The filters: a market code ("unknown" for a deal without one), a lead pipeline ('<connection id>:<pipeline id>'), attempted, outcome */
export interface AttemptFilter {
  market: string | null;
  pipeline: string | null;
  attempted: AttemptAttempted;
  outcome: AttemptOutcomeFilter;
}

/** The figures of a set of deals (cma.attempts_figures_from) */
export interface AttemptFigures {
  deals: number;
  /** Deals with at least one attempt */
  attempted: number;
  attempts: number;
  /** Per deal, never-attempted deals as 0; null without a deal */
  avgAttempts: number | null;
  medianAttempts: number | null;
  /** Deals with at least one attempt that reached the customer */
  reachedDeals: number;
  /** Deals whose first attempt reached the customer */
  firstReached: number;
  reachedAttempts: number;
  /** Attempted deals in a market with business hours, and their median business seconds to the first attempt */
  speedDeals: number;
  medianSpeedSeconds: number | null;
  /** Deals whose answer is known, and of them those called before the next business noon */
  noonKnown: number;
  calledBeforeNoon: number;
  /** Open: the outcome open (an ordered deal is not) */
  openDeals: number;
  openNeverAttempted: number;
  won: number;
  lost: number;
  ordered: number;
  unknown: number;
  talkSecondsTotal: number;
  /** Talk time of the attempts that reached the customer */
  talkSecondsReached: number;
  /** Attempts whose CRM call carries no outcome */
  attemptsWithoutOutcome: number;
  /** Outbound CRM calls in the windows logged without a telephony call (never an attempt under telephony) */
  loggedWithoutAircall: number;
}

export interface AttemptGroupRow extends AttemptFigures {
  /** A date, a Monday, a market code or '<connection id>:<pipeline id>' */
  groupKey: string;
  /** The pipeline's label (pipeline grouping only) */
  label: string | null;
}

/** One attempt bucket, 0 to attempts.max_bucket ("n+" for the top) */
export interface AttemptBucket {
  bucket: number;
  label: string;
  /** Deals with that many attempts */
  deals: number;
  /** Deals first reached on that attempt (none for 0) */
  firstReached: number;
  /** Of the decided deals: won and lost */
  won: number;
  lost: number;
}

/** Won or lost, as the won-against-lost card shows it (cma.attempts_outcomes_from) */
export interface AttemptOutcomeRow {
  outcome: "won" | "lost";
  deals: number;
  avgAttempts: number | null;
  medianAttempts: number | null;
  speedDeals: number;
  medianSpeedSeconds: number | null;
  noonKnown: number;
  calledBeforeNoon: number;
  reachedDeals: number;
  /** The average talk time in contact of the deals reached at least once */
  avgTalkReachedSeconds: number | null;
}

/** One bucket of the win rate by speed to lead, in business minutes ("5–15", "1440+") */
export interface AttemptSpeedBucket {
  from: number;
  to: number | null;
  label: string;
  won: number;
  lost: number;
}

/** Open deals by business days since their last attempt (or creation), as attempts.since_last_buckets_business_days places them */
export interface SinceLastBucket {
  from: number;
  /** null for the open last bucket */
  to: number | null;
  label: string;
  deals: number;
}

/** One deal of the list: ids, codes, counts, times and the link; no customer data */
export interface AttemptListRow {
  /** The CMA's id of the deal, for its attempts */
  dealId: string;
  connectionId: string;
  dealSourceId: string;
  recordUrl: string | null;
  pipelineLabel: string | null;
  stageLabel: string | null;
  market: string;
  createdAt: Instant;
  closedAt: Instant | null;
  orderedAt: Instant | null;
  windowEndReason: AttemptWindowEnd;
  outcome: AttemptOutcome;
  attempts: number;
  reachedAttempts: number;
  firstReachedAttempt: number | null;
  talkSecondsTotal: number;
  talkSecondsReached: number;
  firstAttemptAt: Instant | null;
  /** Business seconds from the creation to the first attempt; null without one or for a market without business hours */
  speedToLeadSeconds: number | null;
  calledBeforeNextNoon: boolean | null;
  lastAttemptAt: Instant | null;
  /** Open deals only; null for a market without business hours */
  businessDaysSinceLast: number | null;
  sinceLastBucket: string | null;
  loggedWithoutAircall: number;
}

/** One attempt of a deal (cma.attempts_of_deal): never a call id, number, hash or recording */
export interface DealAttempt {
  n: number;
  startedAt: Instant;
  answered: boolean;
  talkSeconds: number | null;
  reached: boolean;
  reachedBy: "outcome" | "talk_time" | null;
  /** The outcome's label from the catalog; null without an outcome */
  outcomeLabel: string | null;
  /** The agent's name while the per-person figures for attempts are on and the reader holds performance.team; else null */
  agentName: string | null;
}

/** The settings the hints name, as their effective values */
export interface AttemptSettings {
  maxBucket: number;
  /** attempts.since_last_buckets_business_days, such as "1,2,5" */
  sinceLastBuckets: string;
  /** speed_to_lead.pre_window_minutes: a call this long before the creation counts */
  preWindowMinutes: number;
  /** follow_up.list_rows: the list's cap */
  listRows: number;
  source: AttemptSource;
  /** attempts.reached_min_talk_seconds: an attempt without an outcome reaches the customer at this much talk time */
  reachedMinTalkSeconds: number;
  /** attempts.speed_buckets_business_minutes, such as "5,15,60,240,1440" */
  speedBuckets: string;
}

export interface AttemptsReport {
  from: DateKey;
  to: DateKey;
  group: AttemptGroup;
  filter: AttemptFilter;
  current: AttemptFigures;
  /** The previous period's figures, like for like */
  previous: AttemptFigures;
  previousFrom: DateKey;
  previousTo: DateKey;
  previousPartial: boolean;
  buckets: AttemptBucket[];
  /** Won against lost, and the deals not decided (open, ordered, unknown) */
  outcomes: { rows: AttemptOutcomeRow[]; notDecided: number; open: number; ordered: number; unknown: number };
  /** The win rate by speed to lead; the decided deals never attempted and those without business hours apart */
  speedBuckets: { buckets: AttemptSpeedBucket[]; none: { won: number; lost: number }; noHours: number };
  groups: AttemptGroupRow[];
  sinceLast: { buckets: SinceLastBucket[]; noHours: number };
  list: { rows: AttemptListRow[]; total: number };
  /** The filter lists, from the period without the filters */
  markets: string[];
  pipelines: { key: string; label: string }[];
  /** The later of intake.start_date and the earliest stored CRM call's date; null without a CRM call */
  historyStart: DateKey | null;
  settings: AttemptSettings;
}

/** A deal owner's figures, the not-linked row (owner ids without a person, or no owner) or the total */
export interface AttemptPerson extends AttemptFigures {
  kind: "person" | "notLinked" | "total";
  userId: string | null;
  name: string | null;
  /** How many owner ids without a person (the not-linked row only), never which */
  unlinkedOwners: number | null;
}

export interface AttemptsPerAgent {
  from: DateKey;
  to: DateKey;
  filter: AttemptFilter;
  /** By name, never ranked; the not-linked row last when there is one */
  rows: AttemptPerson[];
  total: AttemptPerson;
  markets: string[];
  pipelines: { key: string; label: string }[];
  historyStart: DateKey | null;
  settings: AttemptSettings;
}

/** A telephony line's stored calls (cma.telephony_number_stored_calls, 0008y): what switching it off removes */
export interface LineStoredCalls {
  storedCalls: number;
  /** The first stored call's start; null without one */
  firstStartedAt: Instant | null;
}

// ---- Funnel, lost reasons and cancellations (addition 0008zb, 20 October 2026; backlog CMA-043, CMA-048, CMA-049 without CCL) ----

/** How the lost reasons and the cancellations are grouped in time: a business date, or an ISO week by its Monday */
export type FunnelGroup = "day" | "week";

/** The funnel's filters (cma.funnel_filters_check): a market code or unknown, a pipeline (connection id and pipeline id joined by ':'), a source channel; null for all */
export interface FunnelFilter {
  market: string | null;
  pipeline: string | null;
  sourceChannel: string | null;
}

/**
 * The state of a connection's reason field for a record type (cma.reason_state_of): none (not mapped), unchecked (mapped,
 * its data type not read yet), enumeration (its option values are stored) or refused (another data type: nothing is
 * stored, since free text can hold personal data)
 */
export type ReasonState = "none" | "unchecked" | "enumeration" | "refused";

/** A set of sales deals' figures (cma.funnel_figures_from): created by the creation's business date, won and lost by the close's */
export interface FunnelFigures {
  created: number;
  won: number;
  lost: number;
  /** Won over won and lost, of the deals closed in the period, four decimals; null without one */
  winRate: number | null;
  /** The median days from the creation to won and to lost, one decimal; null without one */
  medianDaysToWon: number | null;
  medianDaysToLost: number | null;
}

/** One pipeline's figures in the period and in the previous span, like for like */
export interface FunnelPipelineRow {
  /** '<connection id>:<pipeline id>' */
  key: string;
  label: string;
  current: FunnelFigures;
  previous: FunnelFigures;
}

/**
 * One stage of the funnel (cma.funnel_stages_of): of the deals whose entry (crm_record_stage.entered_at) falls in the
 * period, how many entered, are still there now, moved on, the median and 80th percentile of days in the stage of those
 * that moved on (exit after entry), and how many reached won; entered in the previous span. A stage that reads no times
 * has null figures
 */
export interface FunnelStageRow {
  pipeline: string;
  pipelineLabel: string;
  stageId: string;
  label: string;
  order: number;
  isClosed: boolean;
  outcome: "won" | "lost" | null;
  readsTimes: boolean;
  entered: number | null;
  stillThere: number | null;
  movedOn: number | null;
  /** Of those that moved on, the ones with an exit after their entry: what the days count over */
  timed: number | null;
  medianDays: number | null;
  p80Days: number | null;
  reachedWon: number | null;
  /** Reached won over entered, four decimals; null without an entry */
  wonShare: number | null;
  enteredPrevious: number | null;
}

/** The filter lists, from the sales deals without the filters */
export interface FunnelLists {
  markets: string[];
  pipelines: { key: string; label: string }[];
  sourceChannels: string[];
}

export interface FunnelReport extends FunnelLists {
  from: DateKey;
  to: DateKey;
  filter: FunnelFilter;
  stages: FunnelStageRow[];
  byPipeline: { rows: FunnelPipelineRow[]; total: { current: FunnelFigures; previous: FunnelFigures } };
  previousFrom: DateKey;
  previousTo: DateKey;
  previousPartial: boolean;
  /** The deals' history (the later of intake.start_date and the first sales deal) and the stage times' (the first stored entry; null before one) */
  historyStart: { deals: DateKey | null; stages: DateKey | null };
  /** How many active deal stages read their times (connection_stage.read_times, 0008za) */
  timedStages: number;
}

/** A set of lost deals' figures (cma.lost_figures_from) */
export interface LostFigures {
  lost: number;
  withReason: number;
  noReason: number;
  /** A reason the catalog flags as data quality: the lead was never a lead */
  dataQuality: number;
  /** A reason that is no data-quality reason */
  real: number;
}

/** A reason option with its lost deals; share of the real lost deals (a real reason) or of every lost deal (a data-quality reason) */
export interface LostReasonRow {
  /** The option's internal value */
  value: string;
  /** The option's label from the catalog, else the value */
  label: string;
  deals: number;
  share: number | null;
}

/** The lost deals of a market or a source channel (null: none) with the top 3 real reasons */
export interface LostGroupRow {
  key: string | null;
  lost: number;
  real: number;
  noReason: number;
  dataQuality: number;
  top: { value: string; label: string; deals: number }[];
}

/** The lost deals of a business date or ISO week (its Monday), each real reason's count by value */
export interface LostPeriodRow {
  key: DateKey;
  lost: number;
  real: number;
  noReason: number;
  dataQuality: number;
  reasons: Record<string, number>;
}

/** A lost deal without a reason: ids, the pipeline, the market, times and the link only */
export interface LostListRow {
  dealId: string;
  dealSourceId: string;
  recordUrl: string | null;
  pipelineLabel: string;
  market: string;
  createdAt: Instant;
  closedAt: Instant;
}

export interface LostReasonsReport extends FunnelLists {
  from: DateKey;
  to: DateKey;
  group: FunnelGroup;
  filter: FunnelFilter;
  current: LostFigures;
  previous: LostFigures;
  previousFrom: DateKey;
  previousTo: DateKey;
  previousPartial: boolean;
  reasonState: ReasonState;
  historyStart: DateKey | null;
  reasons: LostReasonRow[];
  dataQualityReasons: LostReasonRow[];
  noReason: { deals: number; share: number | null };
  byMarket: LostGroupRow[];
  bySource: LostGroupRow[];
  byPeriod: LostPeriodRow[];
  list: { rows: LostListRow[]; total: number };
}

/** A set of cancellation requests' figures (cma.cancellation_figures_from): by the creation's business date; open and closed now */
export interface CancellationFigures {
  requests: number;
  open: number;
  closed: number;
  /** The median days from the creation to the close of the closed ones, one decimal; null without one */
  medianDaysToClose: number | null;
}

/** A cancellation request (a ticket of the kind): ids, the pipeline, the market, the state, times, the reason's value and the link */
export interface CancellationListRow {
  recordId: string;
  sourceId: string;
  recordUrl: string | null;
  pipelineLabel: string;
  market: string;
  isClosed: boolean;
  createdAt: Instant;
  closedAt: Instant | null;
  reason: string | null;
}

/** A record kind (cma.record_kind): configuration, never a vendor's or a tenant's name in code */
export interface RecordKind {
  key: string;
  label: string;
  recordType: "deal" | "ticket";
  status: "active" | "archived";
}

export interface CancellationsReport {
  from: DateKey;
  to: DateKey;
  group: FunnelGroup;
  market: string | null;
  /** The kind reports.cancellation_kind names; null while none is set */
  kind: RecordKind | null;
  current: CancellationFigures;
  previous: CancellationFigures;
  previousFrom: DateKey;
  previousTo: DateKey;
  previousPartial: boolean;
  byMarket: (CancellationFigures & { market: string })[];
  byPeriod: (CancellationFigures & { key: DateKey; market: string })[];
  reasonState: ReasonState;
  /** Per reason value (null: none) with the catalog's label */
  reasons: { value: string | null; label: string | null; requests: number }[];
  list: { rows: CancellationListRow[]; total: number };
  markets: string[];
  /** The later of intake.start_date and the first request's date; null without a request */
  historyStart: DateKey | null;
}

/** The decided deals' figures (cma.deal_person_figures_from): the amount won per currency, never summed across currencies */
export interface DealPersonFigures {
  won: number;
  lost: number;
  /** Won deals without an amount: counted, adding nothing */
  wonWithoutAmount: number;
  amounts: { currency: string | null; amount: number; deals: number }[];
}

/** A deal owner's figures, the not-linked row (owner ids without a person, or no owner) or the total */
export interface DealPerson extends DealPersonFigures {
  kind: "person" | "notLinked" | "total";
  userId: string | null;
  name: string | null;
  /** How many owner ids without a person (the not-linked row only), never which */
  unlinkedOwners: number | null;
}

export interface DealsPerPerson extends FunnelLists {
  from: DateKey;
  to: DateKey;
  filter: FunnelFilter;
  /** By name, never ranked; the not-linked row last when there is one */
  rows: DealPerson[];
  total: DealPerson;
}

// ---- Sources, markets, alert rules and linked accounts (addition 0008e, night of 13 October 2026) ----

/**
 * The kind of source a connection is in the data model's terms (the tables its data lands in), never
 * a vendor: which sections the Sources screen shows and which id a person can hold come from it
 */
export type SourceKind = "crm" | "telephony" | "commerce" | "automation";

/** A connection's non-secret settings (cma.integration_connection.settings): a flat object of scalars */
export type SourceSettingValue = string | number | boolean;
export type SourceSettings = Record<string, SourceSettingValue>;

/** One connection as cma.sources() answers it: names of secrets, never their values */
export interface SourceConnection {
  id: string;
  /** The last segment of the ingest address: an identifier, not a secret */
  key: string;
  /** The adapter as a data value (the vendor), shown as it is stored */
  adapter: string;
  name: string;
  accountId: string;
  /** null until set */
  kind: SourceKind | null;
  /** The kinds the connection's rows imply */
  heldKinds: SourceKind[];
  isActive: boolean;
  signingSecretName: string | null;
  tokenSecretName: string | null;
  settings: SourceSettings;
  events24h: number;
  eventsWaiting: number;
  eventsParked: number;
  lastEventAt: Instant | null;
  pipelines: number;
  forms: number;
  callOutcomes: number;
  fields: number;
  lines: number;
  tags: number;
  storeHandle: string | null;
}

export interface SourcePipeline {
  recordType: string;
  pipelineId: string;
  label: string;
  isCounted: boolean;
  isRouted: boolean;
  isLead: boolean;
  workType: string | null;
  isActive: boolean;
  /** A ticket pipeline's own response time in business minutes (0008o), null for the tenant's tickets.sla_minutes */
  slaMinutes: number | null;
  /** A deal pipeline whose won deals are orders (0008u) */
  isOrder: boolean;
  /** Its stages with their outcome (0008u), in display order */
  stages: SourceStage[];
}

/** A pipeline stage (0008u): the source's closed flag and the outcome, from the source or a person's choice */
export interface SourceStage {
  stageId: string;
  label: string;
  isClosed: boolean;
  outcome: "won" | "lost" | null;
  outcomeSource: "source" | "person" | null;
  isActive: boolean;
  /** The adapter reads the stage's entry and exit times (0008za): a person's choice, else on for a counted pipeline's stage */
  readTimes: boolean;
  /** A person chose readTimes; false while the default applies */
  readTimesSet: boolean;
}

export interface SourceForm {
  formId: string;
  name: string;
  /** Counted in Intake (lead forms); a counted form is always polled */
  isCounted: boolean;
  /** Read by the poll and the backfill, whether or not it counts (addition 0008p) */
  isPolled: boolean;
  /** A code of the tenant's form categories, or null (addition 0008p) */
  category: string | null;
  leadSource: string | null;
  market: string | null;
  /** The kept choice fields whose answers are stored; kept as they are by every write of this screen */
  keptFields: string[];
  /** The kept field whose answer gives a submission's market when the form has none (addition 0008p) */
  marketField: string | null;
  /** The kept field and the values that make a submission a lead in Intake; null: every submission (addition 0008p) */
  leadCondition: { field: string; values: string[] } | null;
  /** The form's fields as the source describes them: name, kind and a choice field's option values (addition 0008p) */
  fields: SourceFormField[];
  isActive: boolean;
}

/** A field of a source's form: names and option values only */
export interface SourceFormField {
  name: string;
  kind: "dropdown" | "radio" | "multiple_checkboxes" | "single_checkbox" | "other";
  options: string[];
}

export interface SourceCallOutcome {
  outcomeRef: string;
  label: string;
  isConnected: boolean;
  isActive: boolean;
}

export interface SourceLine {
  lineRef: string;
  name: string;
  /** The company's own number, never a customer's */
  digits: string | null;
  market: string | null;
  isCounted: boolean;
  isActive: boolean;
}

export interface SourceTag {
  tagRef: string;
  name: string;
  isCounted: boolean;
  isActive: boolean;
}

/**
 * A missed-call reason of a telephony connection (addition 0008i): a code the connection has seen on
 * its unanswered inbound calls or a catalog row of its adapter, with the label and switches in force
 * (the catalog's, or the defaults: the code as label, both switches on)
 */
export interface SourceMissedReason {
  code: string;
  label: string;
  countsInServiceLevel: boolean;
  needsCallback: boolean;
  /** False while only the defaults apply: nobody saved the code yet */
  inCatalog: boolean;
  /** Unanswered inbound calls of this connection with the code */
  seenCalls: number;
  lastSeenAt: Instant | null;
}

export interface SourceMissedReasonInput {
  code: string;
  label: string;
  countsInServiceLevel: boolean;
  needsCallback: boolean;
}

/**
 * A task status of a CRM connection (addition 0008n): a status the connection's tasks carry, with the
 * label and whether it means done (the default: open). Counts only; a task's body or subject never
 * reaches the Workspace.
 */
export interface SourceTaskStatus {
  statusRef: string;
  label: string;
  isDone: boolean;
  /** Tasks of this connection, deleted ones left out, with the status */
  seenTasks: number;
  lastSeenAt: Instant | null;
}

/** A task type of a CRM connection (0008n): whether it is a callback (KPI 5) and whether it counts in Follow-up */
export interface SourceTaskType {
  typeRef: string;
  label: string;
  isCallback: boolean;
  isCounted: boolean;
  seenTasks: number;
  openTasks: number;
  lastSeenAt: Instant | null;
}

/** Which source property feeds which canonical field (read only, but for the reason field since 0008zb) */
export interface SourceField {
  entity: string;
  field: string;
  refSystem: string | null;
  slot: number;
  property: string;
  /** The property's data type as the adapter last read it, and when (0008zb); null until read */
  sourceType: string | null;
  checkedAt: Instant | null;
  /** The reason field's state (0008zb); null for another field */
  state: ReasonState | null;
}

/** An option of a connection's reason property (cma.connection_reason, 0008zb): value and label from the source, the data-quality flag a person's */
export interface SourceReason {
  recordType: "deal" | "ticket";
  value: string;
  label: string;
  order: number;
  isDataQuality: boolean;
  isActive: boolean;
}

/** A field written back to the CRM (0007c; read only here) */
export interface SourceWriteback {
  field: string;
  slot: number;
  property: string;
  mode: string;
  enabled: boolean;
}

export interface SourceStore {
  handle: string;
  name: string;
  market: string;
  currency: string;
  timeZone: string;
}

/** One connection with its catalogs, for its page */
export interface SourceDetail {
  connection: SourceConnection;
  pipelines: SourcePipeline[];
  forms: SourceForm[];
  callOutcomes: SourceCallOutcome[];
  lines: SourceLine[];
  tags: SourceTag[];
  fields: SourceField[];
  /** The reason properties' options per record type (0008zb); empty until the adapter reads an enumeration */
  reasons: SourceReason[];
  writeback: SourceWriteback[];
  store: SourceStore | null;
  /**
   * The newest record id per record type, for the record link preview (ids only); a telephony
   * connection's newest call id under "call" (addition 0008i), for record_url_call
   */
  sampleIds: Record<string, string>;
  /** A telephony connection's missed-call reasons (addition 0008i); empty for another kind */
  missedReasons: SourceMissedReason[];
  /** A CRM connection's task statuses and types (addition 0008n); empty for another kind */
  taskStatuses: SourceTaskStatus[];
  taskTypes: SourceTaskType[];
  /** A CRM connection's conversations: inboxes, mailboxes and channels (additions 0008m and 0008t); empty for another kind */
  inboxes: SourceInbox[];
  mailboxes: SourceMailbox[];
  inboxChannels: SourceInboxChannel[];
}

/** An inbox of a CRM connection's conversations (0008m): name from the source; counted and market as configuration */
export interface SourceInbox {
  inboxId: string;
  name: string;
  isCounted: boolean;
  market: string | null;
  isActive: boolean;
}

/**
 * A mailbox (0008t): an inbox's channel account. The name is the source's, or its id when the source's name
 * holds an address (the CMA keeps no address); the label is a person's and survives every refresh
 */
export interface SourceMailbox {
  accountId: string;
  name: string;
  label: string | null;
  inboxId: string | null;
  channelId: string | null;
  isCounted: boolean;
  market: string | null;
  isActive: boolean;
}

/** A channel of a CRM connection's conversations (0008m): name and kind from the source; counted as configuration */
export interface SourceInboxChannel {
  channelId: string;
  name: string;
  kind: string;
  isCounted: boolean;
  isActive: boolean;
}

export interface SourceInboxInput {
  inboxId: string;
  isCounted: boolean;
  market: string | null;
}

export interface SourceMailboxInput {
  accountId: string;
  label: string | null;
  isCounted: boolean;
  market: string | null;
}

export interface SourceInboxChannelInput {
  channelId: string;
  isCounted: boolean;
}

/** The connection's own fields a person may change; each only when given */
export interface SourceConnectionInput {
  name?: string;
  isActive?: boolean;
  kind?: SourceKind;
}

export interface SourcePipelineInput {
  recordType: string;
  pipelineId: string;
  isCounted: boolean;
  isLead: boolean;
  /** A deal pipeline whose won deals are orders (0008u); left as it is when not given */
  isOrder?: boolean;
}

/** A deal stage's outcome as a person sets it (0008u) */
export interface SourceStageOutcomeInput {
  pipelineId: string;
  stageId: string;
  outcome: "won" | "lost" | "none";
}

/** Whether a deal stage's times are read (cma.set_stage_read_times, 0008za) */
export interface SourceStageReadTimesInput {
  pipelineId: string;
  stageId: string;
  readTimes: boolean;
}

/** The property a record type's reason comes from (cma.set_connection_field, field reason; 0008zb); null or empty removes the mapping */
export interface SourceReasonFieldInput {
  recordType: "deal" | "ticket";
  property: string | null;
}

/** A person's data-quality flag on a reason option (cma.set_reason_data_quality, 0008zb) */
export interface SourceReasonFlagInput {
  recordType: "deal" | "ticket";
  value: string;
  isDataQuality: boolean;
}

/** A rule that gives a connection's records a kind: a pipeline, a category value or both (cma.connection_record_kind, 0008zb) */
export interface RecordKindRule {
  connectionId: string;
  pipelineId: string | null;
  pipelineLabel: string | null;
  category: string | null;
  isActive: boolean;
}

/** A record kind with its rules, for Configuration → Sources (cma.record_kinds) */
export interface RecordKindConfig extends RecordKind {
  sortOrder: number;
  /** The tenant's reports.cancellation_kind names it */
  isCancellationKind: boolean;
  rules: RecordKindRule[];
}

/** Adds a kind or changes its label and order (cma.set_record_kind); its record type is set once */
export interface RecordKindInput {
  key: string;
  label: string;
  recordType: "deal" | "ticket";
  sortOrder: number | null;
  /** Switches the kind on or off (cma.set_record_kind_status) in the same transaction; null leaves it */
  isActive: boolean | null;
}

/** Adds a rule or puts it back (active), or archives it (cma.set_record_kind_rule) */
export interface RecordKindRuleInput {
  kindKey: string;
  pipelineId: string | null;
  category: string | null;
  active: boolean;
}

/** One form's new configuration; its kept fields stay as they are */
export interface SourceFormChange {
  formId: string;
  isCounted: boolean;
  leadSource: string | null;
  market: string | null;
  /** Polled (addition 0008p); left out: as it is (a counted form is polled anyway) */
  isPolled?: boolean;
  /** A category code or null (addition 0008p); left out: as it is */
  category?: string | null;
}

export interface SourceOutcomeChange {
  outcomeRef: string;
  isConnected: boolean;
}

export interface SourceLineInput {
  lineRef: string;
  market: string | null;
  isCounted: boolean;
}

export interface SourceTagInput {
  tagRef: string;
  isCounted: boolean;
}

/** A ticket pipeline's own response time (cma.set_pipeline_sla, 0008o); null for the tenant default */
export interface SourcePipelineSlaInput {
  recordType: string;
  pipelineId: string;
  slaMinutes: number | null;
}

export interface SourceTaskStatusInput {
  statusRef: string;
  label: string;
  isDone: boolean;
}

export interface SourceTaskTypeInput {
  typeRef: string;
  label: string;
  isCallback: boolean;
  isCounted: boolean;
}

export interface MarketConfig {
  code: string;
  name: string;
  timeZone: string;
  languageCode: string;
  languageSkillKey: string | null;
  minLanguageLevel: number | null;
  currency: string;
  isActive: boolean;
  sortOrder: number;
  /** How sources write the market, lower-cased */
  aliases: string[];
}

export interface MarketInput {
  code: string;
  name: string;
  timeZone: string;
  languageCode: string;
  currency: string;
  languageSkillKey: string | null;
  minLanguageLevel: number | null;
  sortOrder: number;
}

/** Office hours of one market ("*" is the default) on one weekday (1 Monday … 7 Sunday), as "09:00-12:30,13:00-17:00" */
export interface OfficeHours {
  market: string;
  weekday: number;
  hours: string;
}

export interface MarketHoliday {
  market: string;
  day: DateKey;
  name: string;
}

export interface MarketsConfig {
  markets: MarketConfig[];
  hours: OfficeHours[];
  holidays: MarketHoliday[];
}

export type AlertTrigger = "record_created" | "record_assigned";

/** One rule of cma.message_rule (0008, 0008a) with its alerts in the last 30 days */
export interface AlertRule {
  id: string;
  name: string;
  trigger: AlertTrigger;
  recordType: string;
  /** Source pipeline ids; empty means every counted pipeline */
  pipelineIds: string[];
  audiencePermission: string;
  matchLanguage: boolean;
  onlyClockedIn: boolean;
  fallbackPermission: string | null;
  urgency: "normal" | "urgent";
  enabled: boolean;
  /** null: the setting alerts.max_age_minutes */
  maxAgeMinutes: number | null;
  alerts30d: number;
  lastAlertAt: Instant | null;
}

/** A new or changed rule; the audience fields are read for created-record rules only */
export interface AlertRuleInput {
  name: string;
  trigger: AlertTrigger;
  recordType: string;
  pipelineIds: string[];
  urgency: "normal" | "urgent";
  maxAgeMinutes: number | null;
  audiencePermission: string;
  matchLanguage: boolean;
  onlyClockedIn: boolean;
  fallbackPermission: string | null;
}

/** A pipeline a rule can name: from the tenant's customer-record connections */
export interface AlertPipelineChoice {
  connectionName: string;
  recordType: string;
  pipelineId: string;
  label: string;
  isCounted: boolean;
}

export interface AlertRulesConfig {
  rules: AlertRule[];
  pipelines: AlertPipelineChoice[];
  /** alerts.max_age_minutes, the age limit of a rule without its own */
  defaultMaxAgeMinutes: number;
}

/** An id a person can hold in another system: <adapter>_owner for a CRM, <adapter>_user for telephony */
export interface LinkedAccountSystem {
  system: string;
  role: "owner" | "user";
  /** The connections that name this system; empty for a system only held ids still name */
  connections: string[];
  isActive: boolean;
}

export interface LinkedAccount {
  userId: string;
  system: string;
  externalId: string;
}

export interface LinkedAccounts {
  systems: LinkedAccountSystem[];
  accounts: LinkedAccount[];
}

// ---- Follow-up (addition 0008o, night run N16-B, 16 October 2026): what is waiting right now. Open lead deals
// not called, open tickets against their response time, open tasks; ids, codes, counts and the names of the
// organisation's own people only. Never a customer's name, number or address, never a task's body or subject.

/** An open ticket against its response time: ok, at risk (past the warning share), breached, or without business hours to count in */
export type SlaState = "ok" | "at_risk" | "breached" | "no_hours";
/** An open task against the tenant's business date: due on an earlier date, today, later, or without a due time */
export type DueState = "overdue" | "today" | "later" | "none";

/** A row of cma.open_leads (0007d's not-called open deals with their age) */
export interface OpenLead {
  dealId: string;
  connectionId: string;
  dealSourceId: string;
  pipelineId: string;
  pipelineLabel: string;
  /** The deal's owner as a person of the Workspace, or null while the owner is not linked or empty */
  ownerUserId: string | null;
  ownerName: string | null;
  /** The owner's id in the source, null for none; shown as Not mapped, never as the id */
  ownerRef: string | null;
  /** A market code, or "unknown" */
  market: string;
  createdAt: Instant;
  /** Business minutes waited so far as seconds; null without business hours (an unknown market) */
  waitingBusinessSeconds: number | null;
  ageBusinessDays: number | null;
  /** The age bucket from leads.age_buckets_business_days: from the previous edge to this one, the last open (to null) */
  bucketFrom: number | null;
  bucketTo: number | null;
  /** True once the target's business minutes have passed, false while within them, null without business hours */
  pastTarget: boolean | null;
  lastCallAt: Instant | null;
  lastCallDays: number | null;
  recordUrl: string | null;
}

/** A row of cma.open_tickets, sorted by the minutes to breach (no business hours last) */
export interface OpenTicket {
  ticketId: string;
  connectionId: string;
  ticketSourceId: string;
  pipelineId: string;
  pipelineLabel: string;
  stageId: string | null;
  stageLabel: string | null;
  ownerUserId: string | null;
  ownerName: string | null;
  ownerRef: string | null;
  market: string;
  createdAt: Instant;
  openBusinessSeconds: number | null;
  /** The response time in force: the pipeline's own, else the tenant's */
  slaMinutes: number;
  slaState: SlaState;
  /** Business minutes left, negative once breached; null without business hours */
  minutesToBreach: number | null;
  recordUrl: string | null;
}

/** A row of cma.open_tasks (0008n's tasks, status not done, type counted), sorted by due time */
export interface OpenTask {
  taskId: string;
  connectionId: string;
  taskSourceId: string;
  typeRef: string;
  typeLabel: string;
  isCallback: boolean;
  priorityRef: string | null;
  statusRef: string;
  statusLabel: string;
  ownerUserId: string | null;
  ownerName: string | null;
  ownerRef: string | null;
  /** The deal's or ticket's market, else the contact's country as a code; null when none names a market */
  market: string | null;
  dueAt: Instant | null;
  dueState: DueState;
  /** The record the task belongs to, by id: the deal, else the ticket; never the contact */
  recordType: "deal" | "ticket" | null;
  recordSourceId: string | null;
  createdAt: Instant;
  recordUrl: string | null;
}

/** cma.follow_up_summary: counts only */
export interface FollowUpSummary {
  leadsOpenNotCalled: number;
  leadsPastTarget: number;
  ticketsAtRisk: number;
  ticketsBreached: number;
  ticketsWithoutOwner: number;
  tasksOverdue: number;
  tasksDueToday: number;
  /** Open tasks whose owner is not linked to a person */
  tasksUnmappedOwner: number;
}

/** A row of cma.follow_up_by_owner: a person, or (ownerUserId null, last) everything whose owner maps to nobody */
export interface FollowUpOwner {
  ownerUserId: string | null;
  displayName: string | null;
  openLeads: number;
  leadsPastTarget: number;
  openTickets: number;
  ticketsAtRiskOrBreached: number;
  tasksOverdue: number;
  tasksDueToday: number;
}

/** cma.my_follow_up: the caller's own rows, with their record links, as the snapshot computed them */
export interface MyFollowUp {
  leads: OpenLead[];
  tickets: OpenTicket[];
  tasks: OpenTask[];
  /** When the snapshot was computed (addition 0008s): at most about a minute ago */
  computedAt: Instant;
}

/** The summary as the snapshot computed it, and when (addition 0008s) */
export type FollowUpSummaryAt = FollowUpSummary & { computedAt: Instant };

/** Every row of one of the snapshot's lists (the API reads them in full), and when they were computed */
export interface FollowUpRowsAt<T> {
  rows: T[];
  computedAt: Instant;
}

/** The choices of Reports → Follow-up's filters, from every row of the snapshot, so a choice never disappears while it is made */
export interface FollowUpFilterOptions {
  /** Market codes in order, "unknown" last when any row has none */
  markets: string[];
  /** The people who own something, by name */
  owners: { id: string; name: string | null }[];
  /** Some row has no person (OWNER_NONE) */
  hasUnowned: boolean;
}

/** A list after the filters: the filtered total and its first rows (follow_up.list_rows) */
export interface FollowUpList<T> {
  total: number;
  rows: T[];
}

/** Reports → Follow-up in one read (cma.follow_up_page, addition 0008s) */
export interface FollowUpPage {
  computedAt: Instant;
  durationMs: number;
  /** The rows each list shows at most (the tenant's follow_up.list_rows, 1 to 500) */
  rows: number;
  /** Every row waiting, whatever the filters */
  summary: FollowUpSummary;
  /** Per person, for performance.team only (null otherwise) */
  byOwner: FollowUpOwner[] | null;
  options: FollowUpFilterOptions;
  /** The lead target and the warning share the hints name */
  settings: { targetMinutes: number | null; warningPct: number | null };
  /** Every row of each list before the filters */
  counts: { leads: number; tickets: number; tasks: number };
  leads: FollowUpList<OpenLead>;
  tickets: FollowUpList<OpenTicket>;
  tasks: FollowUpList<OpenTask>;
}

// ---- System health (addition 0008r; Configuration → System health) ------------------------------

/** One row of cma.system_health_runs(): per job and connection over the last 30 days (lib/health) */
export type SystemHealthRun = HealthRun;

/** One row of cma.outbox_status(): actions per connection and state (0007c) */
export interface OutboxStatusRow {
  connectionId: string;
  connectionName: string;
  status: string;
  actions: number;
  oldestAt: Instant | null;
  newestAt: Instant | null;
  nextAttemptAt: Instant | null;
}

/** The database answering one trivial query under the tenant context, timed by the application */
export interface DatabaseProbe {
  /** Round trip of the query in milliseconds, including the pool's checkout; null when it failed */
  roundTripMs: number | null;
}

/** A callback's state (addition 0008w): kept, not kept, pending while its window is open; without a contact or a due time apart */
export type CallbackState = "kept" | "not_kept" | "pending" | "no_contact" | "no_due";

/** Callbacks counted (cma.callbacks_kept_figures_of): callbacks = kept + notKept + pending; noContact and noDue apart */
export interface CallbackCounts {
  callbacks: number;
  kept: number;
  notKept: number;
  pending: number;
  noContact: number;
  noDue: number;
}

/** One ISO week of callbacks, from its Monday */
export interface CallbackWeek extends CallbackCounts {
  weekStart: DateKey;
}

/**
 * Callbacks kept (cma.callbacks_kept_report, addition 0008w): the period per ISO week and in total, the previous
 * period's total like for like; connected false while the tenant counts no callback type (said in words, never 0)
 */
export interface CallbacksKept {
  from: DateKey;
  to: DateKey;
  connected: boolean;
  weeks: CallbackWeek[];
  total: CallbackCounts;
  previous: CallbackCounts;
  /** tasks.callback_window_minutes, for the hints */
  windowMinutes: number;
}

/** One row of callbacks kept per person (cma.callbacks_kept_per_owner): a person, the owners without one, the total */
export interface CallbackOwner {
  kind: "person" | "notLinked" | "total";
  userId: string | null;
  name: string | null;
  /** On the not-linked row: how many owner ids without a person (never which) */
  unlinkedOwners: number | null;
  callbacks: number;
  kept: number;
  notKept: number;
  pending: number;
  noContact: number;
}

/** A journey's status (addition 0008v): placeholder until its monitor is built; archived journeys never reach the screens */
export type JourneyStatus = "placeholder" | "building" | "live";

/**
 * A journey of Campaign monitoring (addition 0008v): a placeholder for a compliance or campaign monitor, as
 * configuration (cma.journeys()). Code, name, summary and prerequisites as a person set them; no customer data
 */
export interface Journey {
  code: string;
  name: string;
  summary: string | null;
  /** A market code of the catalog, or null */
  market: string | null;
  status: JourneyStatus;
  /** The design's https link, or null until one exists */
  designUrl: string | null;
  /** The data prerequisites, in their order */
  prerequisites: string[];
}

export interface CmaData {
  /**
   * The app_user check: who may work, with which role, tenant and employer,
   * matched on the identity provider's stable id. null means "no access yet".
   */
  findPrincipal(identity: Identity): Promise<Principal | null>;
  /**
   * Clock in (increment e, 7 October 2026): an action, never a visit. Returns today's workday,
   * opening it if none exists; an existing day is returned unchanged whether it is open or ended
   * (an ended day stays ended, resuming is a correction). The database creates a day only for
   * someone whose time is kept (workday.own): CMA06 otherwise.
   */
  startWorkday(me: Principal, now: Instant): Promise<Workday>;
  /** Reading never clocks in: null when there is no day on that date */
  getWorkday(me: Principal, date: DateKey): Promise<Workday | null>;
  endWorkday(me: Principal, now: Instant): Promise<Workday>;
  /** The tenant's active work statuses, in the tenant's order */
  listStatuses(me: Principal): Promise<WorkStatus[]>;
  /**
   * Sets the caller's status on today's workday (cma.set_status). No day today is CMA02, an
   * unknown or inactive key is CMA02, an ended day is CMA03: changing an ended day is a correction.
   */
  setStatus(me: Principal, key: string, now: Instant): Promise<Workday>;
  getHours(me: Principal, range: HoursRange): Promise<HoursSummary>;
  /** Hours per person per day; all people of the tenant, or one. Needs workday.team (CMA06) */
  getTeamHours(me: Principal, range: HoursRange, userId: string | null): Promise<TeamHours>;
  /** The people whose time is kept: active, holding workday.own. Needs workday.team (CMA06) */
  listTeamPeople(me: Principal): Promise<TeamPerson[]>;
  /** One person's day with every event, for the day editor. Needs workday.team (CMA06) */
  getTeamDay(me: Principal, userId: string, date: DateKey): Promise<TeamDayDetail>;
  /**
   * Corrects one person's day in one transaction (cma.correct_workday); on a date without a day
   * this is Add day. The caller is the approver. Own day CMA06, unknown person or status CMA02,
   * invalid edit CMA04. Answers the day as it now stands.
   */
  correctWorkday(me: Principal, userId: string, date: DateKey, correction: Correction): Promise<TeamDayDetail>;
  /** The tenant's effective settings (cma.tenant_settings); any user of the tenant */
  listSettings(me: Principal): Promise<TenantSetting[]>;
  /** Hours per person per day for a file, with the settings. Needs workday.export (CMA06) */
  exportHours(me: Principal, range: HoursRange, userId: string | null): Promise<Export<ExportHoursRow>>;
  /** Status stretches per person per day for a file, with the settings. Needs workday.export (CMA06) */
  exportStatusChanges(me: Principal, range: HoursRange, userId: string | null): Promise<Export<StatusChangeRow>>;
  /** Seconds per person per day per status, for the Dashboard. Needs performance.team (CMA06) */
  getTeamStatusTime(me: Principal, range: HoursRange, userId: string | null): Promise<TeamStatusTime>;
  /** The app links the caller may see, in the tenant's order (cma.app_links); any person of the tenant */
  listAppLinks(me: Principal): Promise<AppLink[]>;
  /** Everyone whose time is kept, with today's day and status, for the Live board. Needs monitoring.live (CMA06) */
  getTeamNow(me: Principal): Promise<TeamNow>;
  /** Current team memberships of everyone, for the Live board's team filter. Needs a watching or managing permission (CMA06) */
  listTeamMembersNow(me: Principal): Promise<TeamMembership[]>;

  // ---- Team screen (migration 0004): the database decides who is listed and editable (CMA06)
  /** People with role, employer, teams and skills. Needs users.manage_agents or users.manage_all */
  listDirectory(me: Principal): Promise<DirectoryPerson[]>;
  /** The tenant's ladder with whether the caller may assign each role. Needs users.manage_agents or users.manage_all */
  listRoles(me: Principal): Promise<RoleInfo[]>;
  /** The tenant's current teams; any person of the tenant */
  listTeams(me: Principal): Promise<TeamInfo[]>;
  /** The tenant's active employers; any person of the tenant */
  listOrganisations(me: Principal): Promise<OrganisationInfo[]>;
  /** The tenant's skill catalog with the level scale per dimension; any person of the tenant */
  listSkills(me: Principal): Promise<SkillInfo[]>;
  /**
   * Adds a person with a login id and one role (cma.add_person). Rerun-safe for the same person
   * and id; a different id for an existing person, an id of another person or an inactive person
   * is CMA03; a managing role without users.manage_all is CMA06. Answers the person's id.
   */
  addPerson(me: Principal, input: AddPersonInput): Promise<string>;
  /** One role per person; own role or a managing role without users.manage_all is CMA06 */
  setPersonRole(me: Principal, userId: string, roleKey: string): Promise<void>;
  /** Deactivate or reactivate; oneself is CMA06 */
  setPersonActive(me: Principal, userId: string, active: boolean): Promise<void>;
  /** The full list of a person's teams; what is not in it ends. Unknown team CMA02 */
  setPersonTeams(me: Principal, userId: string, teamKeys: string[]): Promise<void>;
  /** The full list of a person's skills with levels; needs skills.manage too. Bad level CMA04 */
  setPersonSkills(me: Principal, userId: string, skills: SkillInput[]): Promise<void>;

  // ---- Invitations (addition 0008l): users.manage_agents or users.manage_all, the role ceiling of Add a person
  /** The invitations the caller may see, with their state; never a token */
  listInvitations(me: Principal): Promise<Invitation[]>;
  /**
   * A new invitation (cma.create_invitation): the token once. A role above the caller's ceiling or the
   * system role CMA06; an unknown employer, role, team or skill CMA02; a person or a pending invitation with
   * the address CMA03; an address outside the domain setting or a bad level CMA04
   */
  createInvitation(me: Principal, input: CreateInvitationInput): Promise<InvitationLink>;
  /** A new link for an open or expired invitation; the old one stops working. Accepted or revoked CMA03 */
  renewInvitation(me: Principal, invitationId: string): Promise<InvitationLink>;
  /** Revokes an open or expired invitation; a revoked one stays revoked. Accepted CMA03 */
  revokeInvitation(me: Principal, invitationId: string): Promise<void>;
  /** For the signed-in identity, before it is a person: what the link shows. Changes nothing */
  previewInvitation(identity: Identity, token: string): Promise<InvitationPreview>;
  /** For the signed-in identity: accepts the invitation in its tenant (cma.accept_invitation) */
  acceptInvitation(identity: Identity, token: string): Promise<InvitationAcceptResult>;

  // ---- Configuration (migration 0005a): the database checks tenant.configure on every call (CMA06)
  /** Every status with its flags, the default, active or retired, and its usage */
  listConfigStatuses(me: Principal): Promise<ConfigStatus[]>;
  /** Adds or changes a status; reactivates a retired key. Frozen flags CMA03, a bad key CMA04 */
  upsertConfigStatus(me: Principal, input: ConfigStatusInput): Promise<void>;
  /** The default must be an active working status (CMA03); unknown CMA02 */
  setDefaultStatus(me: Principal, key: string): Promise<void>;
  /** Retires a status: not the default, not the last working one (CMA03); unknown CMA02 */
  retireStatus(me: Principal, key: string): Promise<void>;
  /** Every app link, active or retired */
  listConfigAppLinks(me: Principal): Promise<ConfigAppLink[]>;
  /** Adds or changes a link; reactivates a retired key. Not https CMA04, unknown permission CMA02 */
  upsertAppLink(me: Principal, input: ConfigAppLinkInput): Promise<void>;
  retireAppLink(me: Principal, key: string): Promise<void>;
  /** The permission catalog, for the link's permission choice */
  listPermissions(me: Principal): Promise<PermissionInfo[]>;
  /** Adds or changes an absence type; reactivates a retired key */
  upsertAbsenceType(me: Principal, input: AbsenceTypeInput): Promise<void>;
  retireAbsenceType(me: Principal, key: string): Promise<void>;
  /** Every coverage target across teams */
  listCoverageTargets(me: Principal): Promise<CoverageTargetRow[]>;
  /** Sets a target; 0 or null clears it. Needs roster.manage as well (the function of 0005) */
  setCoverageTarget(me: Principal, teamKey: string, skillKey: string, weekday: number, minCount: number | null): Promise<void>;
  /** Adds or changes a team; a dissolved key is revived */
  upsertTeam(me: Principal, input: TeamInput): Promise<void>;
  /** Ends a team and its memberships; unknown CMA02 */
  dissolveTeam(me: Principal, key: string): Promise<void>;
  /** Adds or changes a skill; active true reactivates, false retires */
  upsertSkill(me: Principal, input: SkillInputRow, active: boolean): Promise<void>;
  /** Replaces a dimension's level scale; an empty list makes it binary. Levels in use CMA03 */
  setSkillLevels(me: Principal, dimension: SkillDimension, levels: SkillLevel[]): Promise<void>;
  /** Writes one tenant setting; null resets it to the catalog default. Unknown key CMA02, bad value CMA04 */
  setTenantSetting(me: Principal, key: string, value: string | null): Promise<TenantSetting>;

  // ---- Roster (migration 0005): the database checks roster.manage, roster.view or monitoring.live (CMA06)
  /** The planner's week: header, people on the grid, current entries, coverage. Needs roster.manage */
  getRosterWeek(me: Principal, weekStart: DateKey, teamKey: string | null): Promise<RosterWeek>;
  /** The weeks of a team's (or the tenant's) roster between two dates, for browsing. Needs roster.manage */
  listRosterWeeks(me: Principal, teamKey: string | null, range: HoursRange): Promise<RosterWeekSummary[]>;
  /** The tenant's absence types, active ones; any person of the tenant */
  listAbsenceTypes(me: Principal): Promise<AbsenceType[]>;
  /**
   * Sets one cell (cma.roster_set_entry): a new version of the entry, the old one ended; clear ends
   * it. Past dates, a date outside the week, a person not on the grid, bad times are CMA04; another
   * roster's entry on that date CMA03; an unknown absence CMA02. Answers the current entry, null after a clear.
   */
  setRosterEntry(me: Principal, weekStart: DateKey, teamKey: string | null, userId: string, date: DateKey, cell: RosterCellInput): Promise<RosterEntry | null>;
  /** Publishes the week as it stands: version + 1. Answers the header */
  publishRoster(me: Principal, weekStart: DateKey, teamKey: string | null): Promise<RosterWeekHeader>;
  /** Copies the current cells of one week into another of the same scope; answers how many were written */
  copyRosterWeek(me: Principal, fromWeekStart: DateKey, toWeekStart: DateKey, teamKey: string | null): Promise<number>;
  /** The caller's own schedule, published entries only, one row per date; at most 92 days. Needs roster.view */
  getMyRoster(me: Principal, range: HoursRange): Promise<MyRosterDay[]>;
  /** Today's published entry per person whose time is kept, for the Live board. Needs monitoring.live */
  getRosterToday(me: Principal): Promise<TodayShift[]>;
  /** The caller's own details, role, teams and skills for My account; no permission beyond being an active person */
  getMyProfile(me: Principal): Promise<MyProfile>;

  // ---- Messaging (migration 0008): the caller's own deliveries; sending needs messages.send (CMA06)
  /**
   * The caller's own messages, newest first, expired ones left out; `since` lists only messages created
   * after that instant. The first return of a message sets its delivered time. Any active person.
   */
  listMyMessages(me: Principal, since: Instant | null, limit: number): Promise<MyMessages>;
  /** Marks the caller's own deliveries read; other people's ids and rows already read are left alone. Answers how many changed */
  markMessagesRead(me: Principal, ids: string[]): Promise<number>;
  /** Acknowledges one of the caller's own messages (reads it too); a message not delivered to the caller is CMA02 */
  acknowledgeMessage(me: Principal, id: string): Promise<void>;
  /** A manager's message to a target resolved now (cma.send_message). Nobody reached CMA04, an unknown team, skill or person CMA02 */
  sendMessage(me: Principal, input: SendMessageInput): Promise<SentMessage>;
  /** Per message of a business-date range of at most 92 days: recipients, delivered, read, acknowledged. Needs messages.send or performance.team */
  getMessageStats(me: Principal, range: HoursRange): Promise<MessageStat[]>;
  /**
   * Withdraws a message for everyone (cma.withdraw_message, 0008z; messages.withdraw), manual or alert: recipients no longer
   * see it. Answers when it was withdrawn; a second withdrawal changes nothing. CMA02 for a message the tenant does not have
   */
  withdrawMessage(me: Principal, id: string): Promise<{ withdrawnAt: Instant }>;

  // ---- Sources, markets, alert rules (addition 0008e): the database checks tenant.configure on every call (CMA06)
  /** Every connection of the tenant with its kind, settings and catalog sizes */
  listSources(me: Principal): Promise<SourceConnection[]>;
  /** One connection with its catalogs; unknown or another tenant's CMA02 */
  getSource(me: Principal, id: string): Promise<SourceDetail>;
  /** Name (upsert_connection with the stored secret names), status and kind; a kind against the connection's rows CMA03 */
  setSourceConnection(me: Principal, id: string, input: SourceConnectionInput): Promise<void>;
  /** Replaces the non-secret settings (set_connection_settings); a secret-looking key CMA04 */
  setSourceSettings(me: Principal, id: string, settings: SourceSettings): Promise<void>;
  /** Counted (set_connection_pipeline, routed and work type kept), lead (set_pipeline_lead) and, when given, order (set_pipeline_order, 0008u) of one pipeline */
  setSourcePipeline(me: Principal, id: string, input: SourcePipelineInput): Promise<void>;
  /** A deal stage's outcome, a person's choice kept over every later read (set_stage_outcome, 0008u); an unknown stage CMA02 */
  setSourceStageOutcome(me: Principal, id: string, input: SourceStageOutcomeInput): Promise<void>;
  /** Whether the adapter reads a deal stage's times (set_stage_read_times, 0008za); an unknown stage CMA02 */
  setSourceStageReadTimes(me: Principal, id: string, input: SourceStageReadTimesInput): Promise<void>;
  /** The property a record type's reason comes from (set_connection_field, 0008zb); its data type is read by the next sweep */
  setSourceReasonField(me: Principal, id: string, input: SourceReasonFieldInput): Promise<void>;
  /** A reason option's data-quality flag, kept by every refresh (set_reason_data_quality, 0008zb); an option not read CMA02 */
  setSourceReasonDataQuality(me: Principal, id: string, input: SourceReasonFlagInput): Promise<void>;
  /** The tenant's record kinds with their rules (cma.record_kinds, 0008zb) */
  getRecordKinds(me: Principal): Promise<RecordKindConfig[]>;
  /** Adds a kind or changes its label and order (set_record_kind), then on or off when given (set_record_kind_status), in one transaction; a malformed key CMA04, a changed record type CMA03 */
  setRecordKind(me: Principal, input: RecordKindInput): Promise<void>;
  /** A connection's rule for a kind (set_record_kind_rule); an unknown kind or pipeline CMA02, neither value CMA04 */
  setRecordKindRule(me: Principal, id: string, input: RecordKindRuleInput): Promise<void>;
  /**
   * Several forms in one transaction (set_form, kept fields kept; then set_form_reporting when polled or the
   * category is given, addition 0008p); an unknown market or category CMA02 writes nothing, a counted form
   * not polled CMA03
   */
  setSourceForms(me: Principal, id: string, changes: SourceFormChange[]): Promise<void>;
  /** The tenant's form categories with how many forms carry each (addition 0008p) */
  getFormCategories(me: Principal): Promise<FormCategory[]>;
  /** Adds or renames a form category and switches it on or off (set_form_category, set_form_category_status); a malformed code CMA04 */
  setFormCategory(me: Principal, input: FormCategoryInput): Promise<void>;
  /** Several call outcomes in one transaction (set_call_outcome) */
  setSourceCallOutcomes(me: Principal, id: string, changes: SourceOutcomeChange[]): Promise<void>;
  setSourceLine(me: Principal, id: string, input: SourceLineInput): Promise<void>;
  /** The stored calls of a line, which switching it off removes, and the first one's start (tenant.configure; backlog CMA-020) */
  getSourceLineStoredCalls(me: Principal, id: string, lineRef: string): Promise<LineStoredCalls>;
  setSourceTag(me: Principal, id: string, input: SourceTagInput): Promise<void>;
  /** One missed-call reason of a telephony connection (set_telephony_missed_reason, 0008i); another kind of connection CMA04 */
  setSourceMissedReason(me: Principal, id: string, input: SourceMissedReasonInput): Promise<void>;
  /** The connection's store (upsert_commerce_store); a handle another store holds CMA03 */
  setSourceStore(me: Principal, id: string, store: SourceStore): Promise<void>;
  /** A ticket pipeline's own response time (set_pipeline_sla, 0008o); an unknown pipeline CMA02, out of bounds CMA04 */
  setSourcePipelineSla(me: Principal, id: string, input: SourcePipelineSlaInput): Promise<void>;
  /** One task status of a CRM connection (set_task_status, 0008n); another kind of connection CMA04 */
  setSourceTaskStatus(me: Principal, id: string, input: SourceTaskStatusInput): Promise<void>;
  /** One task type of a CRM connection (set_task_type, 0008n) */
  setSourceTaskType(me: Principal, id: string, input: SourceTaskTypeInput): Promise<void>;
  /** One inbox of a CRM connection (set_inbox, 0008m: counted and market; its work type and channel kept) */
  setSourceInbox(me: Principal, id: string, input: SourceInboxInput): Promise<void>;
  /** One mailbox (set_inbox_account, 0008t): label, counted, market; a label with an @ CMA04 */
  setSourceMailbox(me: Principal, id: string, input: SourceMailboxInput): Promise<void>;
  /** One channel of the conversations (set_inbox_channel, 0008m: counted; its tenant channel kept) */
  setSourceInboxChannel(me: Principal, id: string, input: SourceInboxChannelInput): Promise<void>;
  /** Markets with their aliases, office hours and holidays */
  getMarkets(me: Principal): Promise<MarketsConfig>;
  /** Adds or changes a market (upsert_market) and its status (set_market_status) */
  upsertMarket(me: Principal, input: MarketInput, active: boolean): Promise<void>;
  /** Adds or moves an alias (set_market_alias); code null removes it (remove_market_alias) */
  setMarketAlias(me: Principal, alias: string, code: string | null): Promise<void>;
  /** Replaces weekdays' office hours of a market or "*" in one transaction (set_business_hours per day); "" closes a day */
  setOfficeHours(me: Principal, market: string, days: { weekday: number; hours: string }[]): Promise<void>;
  /** Adds or renames a holiday (set_business_holiday); name null removes it */
  setHoliday(me: Principal, market: string, day: DateKey, name: string | null): Promise<void>;
  /** The alert rules with the pipelines a rule can name */
  getAlertRules(me: Principal): Promise<AlertRulesConfig>;
  /** Adds or changes a rule by name (upsert_message_rule or upsert_assignment_rule); a name of a rule with the other trigger CMA03 */
  upsertAlertRule(me: Principal, input: AlertRuleInput): Promise<string>;
  setAlertRuleEnabled(me: Principal, id: string, enabled: boolean): Promise<void>;

  // ---- Linked accounts on People (addition 0008e): users.manage_agents or users.manage_all, the directory's scope
  /** The ids a person can hold and the ids held by the people the caller may see */
  getLinkedAccounts(me: Principal): Promise<LinkedAccounts>;
  /**
   * Links (set_user_external_id) or, with null, unlinks (remove_user_external_id) one id of a person the
   * caller may edit on People (not oneself); an id another person holds CMA03
   */
  setLinkedAccount(me: Principal, userId: string, system: string, externalId: string | null): Promise<void>;

  // ---- Intake reports (0007d, 0006): the database checks the permission on every call (CMA06); at most 92 days
  /** One row per lead deal created in the range, with its record link. Needs reports.view or performance.team */
  getSpeedToLeadRows(me: Principal, range: HoursRange): Promise<SpeedToLeadRow[]>;
  /** The rows grouped by day, market, agent or pipeline. Needs reports.view or performance.team; another group CMA04 */
  getSpeedToLeadSummary(me: Principal, range: HoursRange, group: SpeedToLeadGroup): Promise<SpeedToLeadSummary>;
  /** Intake per business date and market with the tenant's source connections. Needs reports.view or performance.team */
  getIntake(me: Principal, range: HoursRange): Promise<Intake>;
  /** Every data-quality check with its total, in the database's order. Needs reports.view or tenant.configure */
  getDataQuality(me: Principal): Promise<DataQualityCheck[]>;
  /** CRM records created per business date, type, market and pipeline. Needs performance.team */
  getCrmRecordsPerDay(me: Principal, range: HoursRange): Promise<CrmRecordsDay[]>;

  // ---- Inbound service and callbacks (addition 0008i): the database checks the permission on every call (CMA06)
  /** Inbound calls per group with the total and the catalog. Needs reports.view or performance.team; at most 92 days */
  getInboundService(me: Principal, range: HoursRange, group: InboundGroup): Promise<InboundService>;
  /** Today's inbound and the missed calls not called back, for the Live board. Needs monitoring.live */
  getInboundNow(me: Principal): Promise<InboundNow>;

  // ---- Calls overview and calls per agent (addition 0008j): the database checks the permission on every call (CMA06)
  /** Calls per group with the total, the previous period's total and the filter lists. Needs reports.view or performance.team; at most 92 days */
  getCallsOverview(me: Principal, range: HoursRange, group: CallsGroup, filter: CallsFilter): Promise<CallsOverview>;
  /** Conversations per group and current tag, and over the whole period. Needs reports.view or performance.team */
  getCallsTagUse(me: Principal, range: HoursRange, group: CallsGroup, filter: CallsFilter): Promise<CallsTagUse>;
  /** The same figures per person, the not-linked calls as one row, and the total. Needs performance.team */
  getCallsPerAgent(me: Principal, range: HoursRange, filter: CallsFilter): Promise<CallsPerAgent>;
  /** Per person the conversations per counted tag and the untagged ones. Needs performance.team */
  getCallsPerAgentTags(me: Principal, range: HoursRange, filter: CallsFilter): Promise<CallsPerAgentTags>;

  // ---- Forms reporting (addition 0008p): the database checks the permission on every call (CMA06); at most 92 days
  /** Submissions per day or week, form and market, the period's and the previous period's per form and market, the lists. Needs reports.view or performance.team */
  getFormsReport(me: Principal, range: HoursRange, group: FormsGroup, filter: FormsFilter): Promise<FormsReport>;
  /** Submissions per form, market, kept field and value, with the previous period; narrowed by a field and a value. Needs reports.view or performance.team */
  getFormsAnswers(me: Principal, range: HoursRange, filter: FormsFilter, field: string | null, value: string | null): Promise<FormsAnswers>;
  // ---- Email reports (addition 0008t): the database checks the permission on every call (CMA06); at most 92 days
  /** Reports → Email: every section of the period in one read, waiting now and not responding. Needs reports.view or performance.team */
  getEmailReport(me: Principal, range: HoursRange, group: EmailGroup, filter: EmailFilter): Promise<EmailReport>;
  /** Email per agent: per person, the not-linked actions, the total. Needs performance.team and reports.per_person holding email */
  getEmailPerAgent(me: Principal, range: HoursRange, filter: EmailFilter): Promise<EmailPerAgent>;
  // ---- First orders (addition 0008u): the database checks the permission on every call (CMA06); at most 92 days
  /** Reports → First orders: the period per group, level and market, the previous total, the amounts per currency, the list, the history. Needs reports.view or performance.team */
  getFirstOrders(me: Principal, range: HoursRange, group: FirstOrderGroup, filter: FirstOrderFilter): Promise<FirstOrdersReport>;
  /** The first orders of the list for the CSV file, newest first, up to 500. Needs reports.view or performance.team */
  getFirstOrdersExport(me: Principal, range: HoursRange, filter: FirstOrderFilter): Promise<FirstOrderListRow[]>;
  /** Orders per person: the credited first orders per person, the not-linked row, the total. Needs performance.team and reports.per_person holding orders */
  getOrdersPerPerson(me: Principal, range: HoursRange, filter: FirstOrderFilter): Promise<OrdersPerPerson>;
  /** Reports → Attempts per deal (addition 0008y): reports.view or performance.team; one read (cma.attempts_per_deal_page) */
  getAttempts(me: Principal, range: HoursRange, group: AttemptGroup, filter: AttemptFilter): Promise<AttemptsReport>;
  /** Reports → Attempts per agent: performance.team and the tenant's reports.per_person holding attempts (CMA06 otherwise) */
  getAttemptsPerAgent(me: Principal, range: HoursRange, filter: AttemptFilter): Promise<AttemptsPerAgent>;
  /** One sales deal's attempts in time order (cma.attempts_of_deal, 0008z): reports.view or performance.team; CMA02 for a deal that is no sales deal of the tenant */
  getDealAttempts(me: Principal, dealId: string): Promise<DealAttempt[]>;
  // ---- Funnel, lost reasons and cancellations (addition 0008zb): the database checks the permission on every call (CMA06); at most 92 days
  /** Reports → Funnel, the funnel: per stage and per pipeline (cma.deal_funnel_page). Needs reports.view or performance.team */
  getFunnel(me: Principal, range: HoursRange, filter: FunnelFilter): Promise<FunnelReport>;
  /** Reports → Funnel, lost reasons (cma.lost_reasons_page). Needs reports.view or performance.team */
  getLostReasons(me: Principal, range: HoursRange, group: FunnelGroup, filter: FunnelFilter): Promise<LostReasonsReport>;
  /** Reports → Cancellations: the requests of reports.cancellation_kind (cma.cancellations_page). Needs reports.view or performance.team */
  getCancellations(me: Principal, range: HoursRange, group: FunnelGroup, market: string | null): Promise<CancellationsReport>;
  /** Reports → Funnel, deals per person: performance.team and the tenant's reports.per_person holding deals (CMA06 otherwise) */
  getDealsPerPerson(me: Principal, range: HoursRange, filter: FunnelFilter): Promise<DealsPerPerson>;
  // ---- Callbacks kept (addition 0008w): the database checks the permission on every call (CMA06); at most 92 days
  /** The period per ISO week and in total, the previous period's total, whether a callback type counts. Needs reports.view or performance.team */
  getCallbacksKept(me: Principal, range: HoursRange): Promise<CallbacksKept>;
  /** Per person by name, the owners without a person as one row, the total. Needs performance.team */
  getCallbacksPerOwner(me: Principal, range: HoursRange): Promise<CallbackOwner[]>;
  // ---- Campaign monitoring (addition 0008v): the database checks the permission on every call (CMA06)
  /** Every journey of the tenant but the archived ones, in their order. Needs reports.view or performance.team */
  getJourneys(me: Principal): Promise<Journey[]>;
  // ---- Follow-up (addition 0008o): the database checks the permission on every call (CMA06); the person's
  // name comes from app_user, the record link from the connection's template (cma.record_url). Since addition
  // 0008s every read comes from the snapshot the refresh job computes once a minute (computedAt says when)
  /** Reports → Follow-up in one read: the counts, per person (performance.team), the filter choices, the three lists after the filter. Needs reports.view, performance.team or monitoring.live */
  getFollowUpPage(me: Principal, filter: { market: string | null; owner: string | null; state: "attention" | null }): Promise<FollowUpPage>;
  /** Every open lead deal not called, longest waiting first. Needs reports.view, performance.team or monitoring.live */
  getOpenLeads(me: Principal): Promise<FollowUpRowsAt<OpenLead>>;
  /** Every open ticket of a counted pipeline against its response time, the least time left first. The same permissions */
  getOpenTickets(me: Principal): Promise<FollowUpRowsAt<OpenTicket>>;
  /** Every open task, due first. The same permissions */
  getOpenTasks(me: Principal): Promise<FollowUpRowsAt<OpenTask>>;
  /** The counts. Needs monitoring.live, performance.team or workday.team */
  getFollowUpSummary(me: Principal): Promise<FollowUpSummaryAt>;
  /** Per person, the not-linked row last. Needs performance.team */
  getFollowUpByOwner(me: Principal): Promise<FollowUpRowsAt<FollowUpOwner>>;
  /** The caller's own rows. Needs leads.accept or workday.own */
  getMyFollowUp(me: Principal): Promise<MyFollowUp>;

  // System health (addition 0008r). Needs tenant.configure; the database checks again (CMA06)
  /** The jobs' runs per job and connection over the last 30 days (cma.system_health_runs) */
  getSystemHealthRuns(me: Principal): Promise<SystemHealthRun[]>;
  /** The outbox per connection and state (cma.outbox_status, 0007c) */
  getOutboxStatus(me: Principal): Promise<OutboxStatusRow[]>;
  /** One trivial query under the tenant context, timed, so a slow database shows at a glance */
  probeDatabase(me: Principal): Promise<DatabaseProbe>;
}
