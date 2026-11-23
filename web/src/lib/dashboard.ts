/**
 * The Dashboard's figures from time per status (addition 0003c, cma.team_status_time): groups,
 * totals and the series of its three charts. Pure and without runtime imports, so
 * verify/dashboard.mjs tests it without a browser or a database.
 *
 * Groups come from a status's flags and its work area, never from its key or name (Martin, 7 October 2026,
 * amended 23 November 2026):
 *   sales         working and productive, work area sales        Leaf Green
 *   operations    working and productive, work area operations   Deep Blue
 *   productive    working and productive, no work area           Leaf Green
 *   otherWork     working, not productive                        Inkt
 *   paidPause     not working, paid                              Light Blue
 *   unpaidPause   not working, not paid                          Soft Rose (always with its label)
 * A work area changes the group and the colour only, never a figure: worked, paid and productive time
 * read the flags alone. On My day an agent sees the working groups and one pause: whether a pause is
 * paid is not agent information.
 *
 * Worked and paid minutes are whole minutes per person per day, added up, exactly as Team hours
 * adds them, so the two screens show the same figure for the same period and person.
 */
import type { DateKey, StatusTimeRow, WorkArea } from "./data/types";

export type Group = "sales" | "operations" | "productive" | "otherWork" | "paidPause" | "unpaidPause";
/** Bottom to top in a stack, first to last in a legend, on the Live board's tiles and rows (D3, 23 November 2026) */
export const GROUPS: readonly Group[] = ["sales", "operations", "productive", "otherWork", "paidPause", "unpaidPause"];

export interface StatusFlags {
  isWorking: boolean;
  isProductive: boolean;
  isPaid: boolean;
  /** The status's current work area; null without one. Counts only on a working, productive status */
  workArea: WorkArea | null;
}

/** The working group: a work area splits working and productive time, and nothing else */
function workingGroup(f: Pick<StatusFlags, "isProductive" | "workArea">): "sales" | "operations" | "productive" | "otherWork" {
  if (!f.isProductive) return "otherWork";
  return f.workArea === "sales" ? "sales" : f.workArea === "operations" ? "operations" : "productive";
}

export function groupOf(f: StatusFlags): Group {
  if (f.isWorking) return workingGroup(f);
  return f.isPaid ? "paidPause" : "unpaidPause";
}

/** The status colour an agent sees on My day: the same rule without the pay flag */
export type AgentGroup = "sales" | "operations" | "productive" | "otherWork" | "pause";

export function agentGroupOf(f: Pick<StatusFlags, "isWorking" | "isProductive" | "workArea">): AgentGroup {
  return f.isWorking ? workingGroup(f) : "pause";
}

/**
 * Palette classes per group (Pulse4all-Style.md 7.7). Written out in full so Tailwind finds them;
 * the theme verifier checks that nothing off-palette is painted. Deep Blue marks Operations: the
 * style guide's On call state has no counterpart in the CMA (decision of 23 November 2026, D7).
 */
export const GROUP_BG: Record<Group | "pause", string> = {
  sales: "bg-p4a-green",
  operations: "bg-p4a-deepblue",
  productive: "bg-p4a-green",
  otherWork: "bg-p4a-inkt",
  paidPause: "bg-p4a-lightblue",
  unpaidPause: "bg-p4a-rose",
  pause: "bg-p4a-lightblue",
};

export const GROUP_FILL: Record<Group, string> = {
  sales: "fill-p4a-green",
  operations: "fill-p4a-deepblue",
  productive: "fill-p4a-green",
  otherWork: "fill-p4a-inkt",
  paidPause: "fill-p4a-lightblue",
  unpaidPause: "fill-p4a-rose",
};

export type GroupSeconds = Record<Group, number>;

/**
 * The name of the group of working, productive statuses without a work area (Martin, 23 November 2026): Other
 * productive when any of the tenant's statuses, active or retired, has a work area, so the word Productive keeps one
 * meaning beside Sales and Operations; Productive when none has (Invest). The Productive tile keeps its own meaning, all
 * working, productive time, and is not named here
 */
export function productiveGroupName(tenantHasWorkArea: boolean): "productive" | "otherProductive" {
  return tenantHasWorkArea ? "otherProductive" : "productive";
}

/** Whether any of the statuses has a work area: the input of productiveGroupName where a screen holds the statuses */
export function hasWorkArea(statuses: readonly { workArea: WorkArea | null }[]): boolean {
  return statuses.some((s) => s.workArea !== null);
}

/** The groups a work area makes: they exist only where a tenant configured one (decision of 23 November 2026, D6) */
export const WORK_AREA_GROUPS: readonly Group[] = ["sales", "operations"];

/**
 * The legend's groups in D3's order: the flag groups always, Sales and Operations only with time in the period,
 * so a tenant without work areas sees the legend it saw before
 */
export function legendGroups(g: GroupSeconds): Group[] {
  return GROUPS.filter((k) => !WORK_AREA_GROUPS.includes(k) || g[k] > 0);
}

function noGroups(): GroupSeconds {
  return { sales: 0, operations: 0, productive: 0, otherWork: 0, paidPause: 0, unpaidPause: 0 };
}

export function groupTotal(g: GroupSeconds): number {
  return GROUPS.reduce((n, k) => n + g[k], 0);
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
