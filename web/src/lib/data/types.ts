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

/** One row of a day, effective or not: corrections never remove a row */
export interface TimeEvent {
  id: string;
  kind: TimeEventKind;
  statusKey: string | null;
  statusName: string | null;
  at: Instant;
  recordedAt: Instant;
  source: "user" | "system" | "correction";
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
  source: "user" | "system" | "correction";
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
}
