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
}
