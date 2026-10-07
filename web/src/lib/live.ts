/**
 * The Live board's logic from the team now (addition 0003e, cma.team_now): the group of each
 * person, the tiles, the rows in their order, the filters, and the two figures that tick on the
 * screen. Pure and without runtime imports, so verify/live.mjs tests it without a browser or a
 * database.
 *
 * Groups come from the current status's flags through the Dashboard's rule (lib/dashboard, one
 * definition for both screens), plus two states of the day itself: clocked out (today's day has
 * ended) and not clocked in (no day today). No ranking: rows are sorted by group, then by name
 * (the employee-monitoring decision, README).
 *
 * Nothing here looks at a status key or name, and nothing reads the clock: the figures that
 * change by the second take the instant as an argument, so a tab left open ticks without polling
 * and the server's rows stay equal between two reads of an unchanged team.
 */
import type { Instant, TeamMembership, TeamNowPerson, WorkdayClock } from "./data/types";
// With its extension, so verify/live.mjs can run this module under Node's type stripping, which
// resolves no extensionless path (tsconfig: allowImportingTsExtensions)
import { GROUPS, groupOf, type Group } from "./dashboard.ts";

export type LiveGroup = Group | "clockedOut" | "notClockedIn";

/** Tile and row order: at work first, then the pauses, then the people who are not on the clock */
export const LIVE_GROUPS: readonly LiveGroup[] = [...GROUPS, "clockedOut", "notClockedIn"];

export function liveGroupOf(p: TeamNowPerson): LiveGroup {
  if (!p.day) return "notClockedIn";
  if (p.day.status === "ended" || !p.status) return "clockedOut";
  return groupOf(p.status);
}

export interface LiveRow {
  person: TeamNowPerson;
  group: LiveGroup;
}

/** One row per person, sorted by group in LIVE_GROUPS order, then by name, then by id */
export function liveRows(people: TeamNowPerson[]): LiveRow[] {
  return people
    .map((person) => ({ person, group: liveGroupOf(person) }))
    .sort((a, b) =>
      LIVE_GROUPS.indexOf(a.group) - LIVE_GROUPS.indexOf(b.group) ||
      a.person.displayName.localeCompare(b.person.displayName) ||
      a.person.userId.localeCompare(b.person.userId));
}

export interface Tile {
  group: LiveGroup;
  count: number;
}

/**
 * The tiles: one per flag group that at least one active status belongs to (a tenant without
 * paid pauses gets no Paid pause tile), always Clocked out and Not clocked in, each with its
 * count over all rows, before any filter.
 */
export function tiles(rows: LiveRow[], statusFlags: { isWorking: boolean; isProductive: boolean; isPaid: boolean }[]): Tile[] {
  const present = new Set<LiveGroup>(statusFlags.map(groupOf));
  present.add("clockedOut");
  present.add("notClockedIn");
  return LIVE_GROUPS.filter((g) => present.has(g)).map((group) => ({
    group,
    count: rows.filter((r) => r.group === group).length,
  }));
}

export interface LiveFilter {
  /** A group, or "" for every group */
  group: LiveGroup | "";
  /** An employer key, or "" for every employer */
  employer: string;
  /** A team key, or "" for every team (migration 0004); needs the memberships */
  team?: string;
}

/** Team keys per person from the current memberships (cma.team_members_now) */
export function teamKeysByUser(memberships: TeamMembership[]): Map<string, string[]> {
  const out = new Map<string, string[]>();
  for (const m of memberships) out.set(m.userId, [...(out.get(m.userId) ?? []), m.teamKey].sort());
  return out;
}

export function filterRows(rows: LiveRow[], f: LiveFilter, memberships: TeamMembership[] = []): LiveRow[] {
  const byUser = teamKeysByUser(memberships);
  return rows.filter((r) =>
    (f.group === "" || r.group === f.group) &&
    (f.employer === "" || (r.person.organisationKey ?? "") === f.employer) &&
    (!f.team || (byUser.get(r.person.userId) ?? []).includes(f.team)));
}

export interface TeamOption {
  key: string;
  name: string;
}

/** The teams anyone on the board is in, by name; a person without a team is in none of them */
export function teamsOf(rows: LiveRow[], memberships: TeamMembership[]): TeamOption[] {
  const onBoard = new Set(rows.map((r) => r.person.userId));
  const out = new Map<string, string>();
  for (const m of memberships) if (onBoard.has(m.userId)) out.set(m.teamKey, m.teamName);
  return [...out.entries()].map(([key, name]) => ({ key, name })).sort((a, b) => a.name.localeCompare(b.name) || a.key.localeCompare(b.key));
}

export interface EmployerOption {
  key: string;
  name: string;
}

/** The employers on the board, by name; a person without one is left out of the list */
export function employersOf(rows: LiveRow[]): EmployerOption[] {
  const out = new Map<string, string>();
  for (const r of rows) if (r.person.organisationKey) out.set(r.person.organisationKey, r.person.organisationName);
  return [...out.entries()].map(([key, name]) => ({ key, name })).sort((a, b) => a.name.localeCompare(b.name) || a.key.localeCompare(b.key));
}

/** Whole seconds since an instant at `nowMs`, never negative */
export function secondsSince(since: Instant, nowMs: number): number {
  return Math.max(0, Math.floor((nowMs - Date.parse(since)) / 1000));
}

/** Worked seconds at `nowMs`: the closed stretches plus the running one, as the clock on My day */
export function workedSeconds(clock: WorkdayClock, nowMs: number): number {
  return clock.closedSeconds + (clock.runningSince ? secondsSince(clock.runningSince, nowMs) : 0);
}

/** 1:07:05 for the worked figure, 7:05 for a stretch under an hour: the clock's format, compact */
export function fmtSeconds(s: number): string {
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  return h > 0
    ? `${h}:${String(m).padStart(2, "0")}:${String(sec).padStart(2, "0")}`
    : `${m}:${String(sec).padStart(2, "0")}`;
}
