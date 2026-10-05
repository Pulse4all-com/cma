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

export interface Workday {
  date: DateKey;
  status: WorkdayStatus;
  startedAt: Instant;
  endedAt: Instant | null;
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
  getHours(me: Principal, range: HoursRange): Promise<HoursSummary>;
}
