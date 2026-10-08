/**
 * The roster's logic (migration 0005): the quick-typing parser of the planner's cells, how a cell
 * is labelled, the week's days, planned time per person and per day, the coverage grid, and the
 * adherence flags the Live board derives from a planned shift and the actual clock. Pure and
 * without runtime imports beyond the zone helpers of lib/corrections, so verify/roster.mjs tests it
 * without a browser or a database. Absence types are the tenant's rows: nothing here knows a key.
 */
import type { DateKey, Instant } from "./data/types";
// With its extension, so verify/roster.mjs can run this module under Node's type stripping
import { instantsForLocal } from "./corrections.ts";

export interface AbsenceOption {
  key: string;
  name: string;
}

/** A cell as typed: a shift with local times, an absence by key, or nothing */
export type Cell =
  | { kind: "shift"; start: string; end: string }
  | { kind: "absence"; key: string }
  | { kind: "clear" };

export type CellProblem = "format" | "order" | "absence";

/** hh:mm from the many ways people type a time: 9, 9:30, 9.30, 930, 0930, 9h, 9h30, 17u15, 24 */
function parseTime(raw: string): string | null {
  const s = raw.trim().toLowerCase().replace(/\s+/g, "");
  let m = /^(\d{1,2})(?:[:.hu](\d{2})?)?$/.exec(s);
  if (!m) {
    m = /^(\d{2})(\d{2})$/.exec(s) ?? /^(\d{1})(\d{2})$/.exec(s);
  }
  if (!m) return null;
  const h = Number(m[1]);
  const min = Number(m[2] ?? "0");
  if (h > 24 || min > 59 || (h === 24 && min > 0)) return null;
  return `${String(h).padStart(2, "0")}:${String(min).padStart(2, "0")}`;
}

/**
 * The planner's quick typing: "9-17" and "9:30-18" become a shift of 09:00 to 17:00 or 09:30 to
 * 18:00 (separators - or – or "to"), an absence type's key or name (or an unambiguous start of
 * one) becomes that absence, and an empty cell clears. A shift ends after it starts and at the
 * latest at 24:00: no shift crosses midnight (README, decision of 7 October 2026).
 */
export function parseCell(text: string, absences: AbsenceOption[]): { cell: Cell } | { problem: CellProblem } {
  const raw = text.trim();
  if (raw === "") return { cell: { kind: "clear" } };
  const times = /^(.+?)\s*(?:-|–|—|to|tot)\s*(.+)$/i.exec(raw);
  if (times && /\d/.test(times[1] ?? "") && /\d/.test(times[2] ?? "")) {
    const start = parseTime(times[1] ?? "");
    const end = parseTime(times[2] ?? "");
    if (!start || !end) return { problem: "format" };
    if (start === "24:00" || end <= start) return { problem: "order" };
    return { cell: { kind: "shift", start, end } };
  }
  const word = raw.toLowerCase();
  const exact = absences.find((a) => a.key.toLowerCase() === word || a.name.toLowerCase() === word);
  if (exact) return { cell: { kind: "absence", key: exact.key } };
  const starts = absences.filter((a) => a.key.toLowerCase().startsWith(word) || a.name.toLowerCase().startsWith(word));
  if (starts.length === 1) return { cell: { kind: "absence", key: starts[0]!.key } };
  return { problem: /\d/.test(raw) ? "format" : "absence" };
}

/** A stored entry as the planner and the agent read it */
export interface EntryLike {
  kind: "shift" | "absence";
  start: string | null;
  end: string | null;
  absenceName: string | null;
}

/** "09:00–17:30", or the absence's name, or "" for an empty cell */
export function cellLabel(e: EntryLike | null): string {
  if (!e) return "";
  if (e.kind === "shift") return `${(e.start ?? "").slice(0, 5)}–${(e.end ?? "").slice(0, 5)}`;
  return e.absenceName ?? "";
}

/** The seven dates of the week that starts on `weekStart` (a Monday) */
export function weekDays(weekStart: DateKey): DateKey[] {
  const [y, m, d] = weekStart.split("-").map(Number) as [number, number, number];
  return Array.from({ length: 7 }, (_, i) => new Date(Date.UTC(y, m - 1, d + i)).toISOString().slice(0, 10));
}

/** The ISO 8601 week number of a date (weeks start on Monday, week 1 holds 4 January) */
export function isoWeek(date: DateKey): number {
  const [y, m, d] = date.split("-").map(Number) as [number, number, number];
  const t = new Date(Date.UTC(y, m - 1, d));
  const day = t.getUTCDay() || 7;
  t.setUTCDate(t.getUTCDate() + 4 - day);
  const yearStart = Date.UTC(t.getUTCFullYear(), 0, 1);
  return Math.ceil(((t.getTime() - yearStart) / 86_400_000 + 1) / 7);
}

/** Minutes between two hh:mm times of one day; 24:00 is the end of the day */
export function shiftMinutes(start: string, end: string): number {
  const toMin = (t: string) => Number(t.slice(0, 2)) * 60 + Number(t.slice(3, 5));
  return Math.max(0, toMin(end) - toMin(start));
}

export interface GridEntry extends EntryLike {
  userId: string;
  date: DateKey;
}

/** Planned minutes per person over the entries given (shifts only) */
export function plannedMinutesByUser(entries: GridEntry[]): Map<string, number> {
  const out = new Map<string, number>();
  for (const e of entries) {
    if (e.kind !== "shift" || !e.start || !e.end) continue;
    out.set(e.userId, (out.get(e.userId) ?? 0) + shiftMinutes(e.start, e.end));
  }
  return out;
}

/** People on shift per date, over the entries given */
export function headcountByDate(entries: GridEntry[]): Map<DateKey, number> {
  const out = new Map<DateKey, number>();
  for (const e of entries) if (e.kind === "shift") out.set(e.date, (out.get(e.date) ?? 0) + 1);
  return out;
}

export interface CoverageRow {
  date: DateKey;
  skillKey: string;
  skillName: string;
  plannedPeople: number;
  peopleNames: string[];
  /** null when the team has no target for that weekday */
  target: number | null;
}

export type CoverageState = "none" | "single" | "ok" | "short";

/**
 * How deeply a work type is covered on a day: none (nobody), single (one person, a single-person
 * dependency), short (below the target), ok. Without a target, two or more people are ok.
 */
export function coverageState(planned: number, target: number | null): CoverageState {
  if (planned === 0) return "none";
  if (target !== null && planned < target) return "short";
  if (planned === 1) return "single";
  return "ok";
}

/** The coverage grid: one row per work type in catalog order, one column per day of the week */
export function coverageGrid(rows: CoverageRow[], days: DateKey[]): { skillKey: string; skillName: string; cells: (CoverageRow & { state: CoverageState })[] }[] {
  const skills: { key: string; name: string }[] = [];
  for (const r of rows) if (!skills.some((s) => s.key === r.skillKey)) skills.push({ key: r.skillKey, name: r.skillName });
  return skills.map((s) => ({
    skillKey: s.key,
    skillName: s.name,
    cells: days.map((date) => {
      const found = rows.find((r) => r.skillKey === s.key && r.date === date);
      const cell: CoverageRow = found ?? { date, skillKey: s.key, skillName: s.name, plannedPeople: 0, peopleNames: [], target: null };
      return { ...cell, state: coverageState(cell.plannedPeople, cell.target) };
    }),
  }));
}

// ---- adherence: the Live board's shift line -------------------------------------------------

export type Adherence = "onTime" | "late" | "leftEarly" | "expected" | "absent" | "unplanned";

export interface PlannedToday {
  kind: "shift" | "absence";
  start: string | null;
  end: string | null;
}

export interface ActualToday {
  startedAt: Instant | null;
  endedAt: Instant | null;
}

/** The instant of a local time on a date in a zone; the earlier one when the time occurs twice */
export function plannedInstant(date: DateKey, time: string, timeZone: string): number | null {
  const t = time.slice(0, 5);
  if (t === "24:00") {
    const next = weekDays(date)[1]!;
    return instantsForLocal(next, "00:00", timeZone)[0]?.ms ?? null;
  }
  return instantsForLocal(date, t, timeZone)[0]?.ms ?? null;
}

/**
 * The flags the board shows next to the planned shift, with a tolerance in minutes (the tenant
 * setting roster.adherence_tolerance_minutes): late (clocked in after the start plus tolerance),
 * leftEarly (clocked out before the end minus tolerance), expected (the start has passed, nobody
 * clocked in), absent (an absence is planned), unplanned (on the clock without a planned shift),
 * onTime otherwise; null while there is nothing to say (not started yet, within tolerance).
 */
export function adherence(
  planned: PlannedToday | null, actual: ActualToday, date: DateKey, timeZone: string, nowMs: number, toleranceMinutes: number,
): Adherence | null {
  const tol = toleranceMinutes * 60_000;
  if (!planned) return actual.startedAt ? "unplanned" : null;
  if (planned.kind === "absence") return actual.startedAt ? "unplanned" : "absent";
  if (!planned.start || !planned.end) return null;
  const start = plannedInstant(date, planned.start, timeZone);
  const end = plannedInstant(date, planned.end, timeZone);
  if (start === null || end === null) return null;
  if (!actual.startedAt) return nowMs > start + tol ? "expected" : null;
  const startedMs = Date.parse(actual.startedAt);
  if (actual.endedAt && Date.parse(actual.endedAt) < end - tol) return "leftEarly";
  if (startedMs > start + tol) return "late";
  return "onTime";
}
