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

/** One check of cma.data_quality(); total null for a check whose source is not installed */
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
}

export interface SourceForm {
  formId: string;
  name: string;
  isCounted: boolean;
  leadSource: string | null;
  market: string | null;
  /** Field names whose values are not personal; kept as they are by every write of this screen */
  keptFields: string[];
  isActive: boolean;
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

/** Which source property feeds which canonical field (read only in this increment) */
export interface SourceField {
  entity: string;
  field: string;
  refSystem: string | null;
  slot: number;
  property: string;
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
  writeback: SourceWriteback[];
  store: SourceStore | null;
  /** The newest record id per record type, for the record link preview (ids only) */
  sampleIds: Record<string, string>;
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
}

/** One form's new configuration; its kept fields stay as they are */
export interface SourceFormChange {
  formId: string;
  isCounted: boolean;
  leadSource: string | null;
  market: string | null;
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

  // ---- Sources, markets, alert rules (addition 0008e): the database checks tenant.configure on every call (CMA06)
  /** Every connection of the tenant with its kind, settings and catalog sizes */
  listSources(me: Principal): Promise<SourceConnection[]>;
  /** One connection with its catalogs; unknown or another tenant's CMA02 */
  getSource(me: Principal, id: string): Promise<SourceDetail>;
  /** Name (upsert_connection with the stored secret names), status and kind; a kind against the connection's rows CMA03 */
  setSourceConnection(me: Principal, id: string, input: SourceConnectionInput): Promise<void>;
  /** Replaces the non-secret settings (set_connection_settings); a secret-looking key CMA04 */
  setSourceSettings(me: Principal, id: string, settings: SourceSettings): Promise<void>;
  /** Counted (set_connection_pipeline, routed and work type kept) and lead (set_pipeline_lead) of one pipeline */
  setSourcePipeline(me: Principal, id: string, input: SourcePipelineInput): Promise<void>;
  /** Several forms in one transaction (set_form, kept fields kept); an unknown market CMA02 writes nothing */
  setSourceForms(me: Principal, id: string, changes: SourceFormChange[]): Promise<void>;
  /** Several call outcomes in one transaction (set_call_outcome) */
  setSourceCallOutcomes(me: Principal, id: string, changes: SourceOutcomeChange[]): Promise<void>;
  setSourceLine(me: Principal, id: string, input: SourceLineInput): Promise<void>;
  setSourceTag(me: Principal, id: string, input: SourceTagInput): Promise<void>;
  /** The connection's store (upsert_commerce_store); a handle another store holds CMA03 */
  setSourceStore(me: Principal, id: string, store: SourceStore): Promise<void>;
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
}
