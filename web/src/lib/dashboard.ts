/**
 * The Dashboard's figures from time per status (addition 0003c, cma.team_status_time): groups,
 * totals and the series of its three charts. Pure and without runtime imports, so
 * verify/dashboard.mjs tests it without a browser or a database.
 *
 * Groups come from a status's flags, never from its key or name (Martin, 7 October 2026):
 *   productive    working and productive          Leaf Green
 *   otherWork     working, not productive         Deep Blue
 *   paidPause     not working, paid               Light Blue
 *   unpaidPause   not working, not paid           Soft Rose (always with its label)
 * On My day an agent sees three of them: whether a pause is paid is not agent information.
 *
 * Worked and paid minutes are whole minutes per person per day, added up, exactly as Team hours
 * adds them, so the two screens show the same figure for the same period and person.
 */
import type { DateKey, StatusTimeRow } from "./data/types";

export type Group = "productive" | "otherWork" | "paidPause" | "unpaidPause";
/** Bottom to top in a stack, first to last in a legend */
export const GROUPS: readonly Group[] = ["productive", "otherWork", "paidPause", "unpaidPause"];

export interface StatusFlags {
  isWorking: boolean;
  isProductive: boolean;
  isPaid: boolean;
}

export function groupOf(f: StatusFlags): Group {
  if (f.isWorking) return f.isProductive ? "productive" : "otherWork";
  return f.isPaid ? "paidPause" : "unpaidPause";
}

/** The status colour an agent sees on My day: the same rule without the pay flag */
export type AgentGroup = "productive" | "otherWork" | "pause";

export function agentGroupOf(f: { isWorking: boolean; isProductive: boolean }): AgentGroup {
  return f.isWorking ? (f.isProductive ? "productive" : "otherWork") : "pause";
}

/**
 * Palette classes per group (Pulse4all-Style.md 7.7). Written out in full so Tailwind finds them;
 * the theme verifier checks that nothing off-palette is painted.
 */
export const GROUP_BG: Record<Group | "pause", string> = {
  productive: "bg-p4a-green",
  otherWork: "bg-p4a-deepblue",
  paidPause: "bg-p4a-lightblue",
  unpaidPause: "bg-p4a-rose",
  pause: "bg-p4a-lightblue",
};

export const GROUP_FILL: Record<Group, string> = {
  productive: "fill-p4a-green",
  otherWork: "fill-p4a-deepblue",
  paidPause: "fill-p4a-lightblue",
  unpaidPause: "fill-p4a-rose",
};

export type GroupSeconds = Record<Group, number>;

function noGroups(): GroupSeconds {
  return { productive: 0, otherWork: 0, paidPause: 0, unpaidPause: 0 };
}

export function groupTotal(g: GroupSeconds): number {
  return g.productive + g.otherWork + g.paidPause + g.unpaidPause;
}

/** part / whole between 0 and 1, or null when there is nothing to divide by */
export function share(part: number, whole: number): number | null {
  return whole > 0 ? part / whole : null;
}

interface PersonDay {
  userId: string;
  working: number;
  paid: number;
  capped: boolean;
}

function personDays(rows: StatusTimeRow[]): Map<string, PersonDay> {
  const out = new Map<string, PersonDay>();
  for (const r of rows) {
    const k = `${r.userId}:${r.date}`;
    const d = out.get(k) ?? { userId: r.userId, working: 0, paid: 0, capped: false };
    if (r.isWorking) d.working += r.seconds;
    if (r.isPaid) d.paid += r.seconds;
    d.capped ||= r.isCapped;
    out.set(k, d);
  }
  return out;
}

export interface Summary {
  /** Whole minutes per person per day, added up: the figure Team hours shows */
  workedMinutes: number;
  paidMinutes: number;
  workedSeconds: number;
  productiveSeconds: number;
  /** From clock-in to clock-out, every status */
  clockedSeconds: number;
  groups: GroupSeconds;
  people: number;
  personDays: number;
  /** Days that were not clocked out, so their time stops at the end of the day */
  cappedDays: number;
}

export function summarise(rows: StatusTimeRow[]): Summary {
  const groups = noGroups();
  let workedSeconds = 0;
  let productiveSeconds = 0;
  for (const r of rows) {
    groups[groupOf(r)] += r.seconds;
    if (r.isWorking) workedSeconds += r.seconds;
    if (r.isWorking && r.isProductive) productiveSeconds += r.seconds;
  }
  const days = [...personDays(rows).values()];
  return {
    workedMinutes: days.reduce((n, d) => n + Math.floor(d.working / 60), 0),
    paidMinutes: days.reduce((n, d) => n + Math.floor(d.paid / 60), 0),
    workedSeconds,
    productiveSeconds,
    clockedSeconds: groupTotal(groups),
    groups,
    people: new Set(rows.map((r) => r.userId)).size,
    personDays: days.length,
    cappedDays: days.filter((d) => d.capped).length,
  };
}

export interface StatusTotal {
  key: string;
  name: string;
  sortOrder: number;
  active: boolean;
  group: Group;
  seconds: number;
}

/** One total per status, in the tenant's order (sort order, then key) */
export function byStatus(rows: StatusTimeRow[]): StatusTotal[] {
  const out = new Map<string, StatusTotal>();
  for (const r of rows) {
    const t = out.get(r.statusKey);
    if (t) {
      t.seconds += r.seconds;
      continue;
    }
    out.set(r.statusKey, {
      key: r.statusKey, name: r.statusName, sortOrder: r.sortOrder, active: r.statusActive, group: groupOf(r), seconds: r.seconds,
    });
  }
  return [...out.values()].sort((a, b) => a.sortOrder - b.sortOrder || a.key.localeCompare(b.key));
}

export interface DayTotal {
  date: DateKey;
  groups: GroupSeconds;
  seconds: number;
}

function nextDate(d: DateKey): DateKey {
  const [y, m, day] = d.split("-").map(Number) as [number, number, number];
  return new Date(Date.UTC(y, m - 1, day + 1)).toISOString().slice(0, 10);
}

/** Every date from `from` to `to`, a day without time included, so the axis never skips a day */
export function byDay(rows: StatusTimeRow[], from: DateKey, to: DateKey): DayTotal[] {
  const out = new Map<DateKey, DayTotal>();
  for (let d = from; d <= to && out.size < 366; d = nextDate(d)) out.set(d, { date: d, groups: noGroups(), seconds: 0 });
  for (const r of rows) {
    const t = out.get(r.date);
    if (!t) continue;
    t.groups[groupOf(r)] += r.seconds;
    t.seconds += r.seconds;
  }
  return [...out.values()];
}

export interface PersonTotal {
  userId: string;
  displayName: string;
  organisationName: string;
  groups: GroupSeconds;
  clockedSeconds: number;
  workedMinutes: number;
  paidMinutes: number;
}

/**
 * One total per person, by name. No ranking: whether and how people are compared follows the
 * employee-monitoring decision (README, Open decisions).
 */
export function byPerson(rows: StatusTimeRow[]): PersonTotal[] {
  const out = new Map<string, PersonTotal>();
  for (const r of rows) {
    const p = out.get(r.userId) ?? {
      userId: r.userId, displayName: r.displayName, organisationName: r.organisationName,
      groups: noGroups(), clockedSeconds: 0, workedMinutes: 0, paidMinutes: 0,
    };
    p.groups[groupOf(r)] += r.seconds;
    p.clockedSeconds += r.seconds;
    out.set(r.userId, p);
  }
  for (const d of personDays(rows).values()) {
    const p = out.get(d.userId)!;
    p.workedMinutes += Math.floor(d.working / 60);
    p.paidMinutes += Math.floor(d.paid / 60);
  }
  return [...out.values()].sort((a, b) => a.displayName.localeCompare(b.displayName) || a.userId.localeCompare(b.userId));
}

export interface PersonOption {
  userId: string;
  displayName: string;
  organisationName: string;
}

/** The people with time in the rows, for the person filter (no team list needed) */
export function peopleOf(rows: StatusTimeRow[]): PersonOption[] {
  return byPerson(rows).map(({ userId, displayName, organisationName }) => ({ userId, displayName, organisationName }));
}

/**
 * A readable hours axis: at most five steps of 1, 2, 3, 4, 6, 8, 12 or 24 hours (then whole
 * days), and a top that is a whole number of steps at or above the highest bar.
 */
export function hoursAxis(maxSeconds: number): { top: number; step: number } {
  const hours = Math.max(0, maxSeconds) / 3600;
  if (hours === 0) return { top: 8, step: 2 };
  const steps = [1, 2, 3, 4, 6, 8, 12, 24];
  const step = steps.find((s) => Math.ceil(hours / s) <= 5) ?? Math.ceil(hours / 5 / 24) * 24;
  return { top: Math.max(step, Math.ceil(hours / step) * step), step };
}
