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
  /** When the current status began; null once the day has ended */
  statusSince: Instant | null;
  clock: WorkdayClock;
}

/**
 * A status the caller can choose: the tenant's own list (work_status), in its order. Names are
 * tenant data, never copy, and no code branches on a key. Pay and billing flags stay out: the
 * screen only needs to know whether the clock runs.
 */
export interface WorkStatus {
  key: string;
  name: string;
  isWorking: boolean;
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

export interface CmaData {
  /**
   * The app_user check: who may work, with which role, tenant and employer,
   * matched on the identity provider's stable id. null means "no access yet".
   */
  findPrincipal(identity: Identity): Promise<Principal | null>;
  /**
   * Login is clock-in: returns today's workday, opening it if none exists.
   * An ended day stays ended (so a silent re-login after log out does not
   * start a new one); the next workday starts on the next calendar day.
   */
  openWorkday(me: Principal, now: Instant): Promise<Workday>;
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
}
