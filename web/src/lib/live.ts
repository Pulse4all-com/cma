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
import type { Instant, InboundToday, MissedCallback, MissedReason, TeamMembership, TeamNowPerson, WorkdayClock } from "./data/types";
// With its extension, so verify/live.mjs can run this module under Node's type stripping, which
// resolves no extensionless path (tsconfig: allowImportingTsExtensions)
import { GROUPS, groupOf, type Group } from "./dashboard.ts";
import { inboundCalls, unansweredPct, type InboundLine, type TelephonyCallFixture } from "./reports.ts";

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

/**
 * Worked seconds at `nowMs`: the closed stretches plus the running one, as the clock on My day.
 * With the day's end (the workday window, addition 0008b) the running stretch stops there, as the
 * database's count does; the Live board passes none and shows what its read returned.
 */
export function workedSeconds(clock: WorkdayClock, nowMs: number, dayEndsAt: Instant | null = null): number {
  const until = dayEndsAt === null ? nowMs : Math.min(nowMs, Date.parse(dayEndsAt));
  return clock.closedSeconds + (clock.runningSince ? secondsSince(clock.runningSince, until) : 0);
}

/**
 * The window start in a refused clock-in ("the workday starts at 07:00", cma.open_workday since
 * addition 0008b), or null for any other refusal. The time is the database's own setting, never
 * typed here.
 */
export function workdayStartsAt(message: string | null | undefined): string | null {
  const m = /^the workday starts at ((?:[01]\d|2[0-3]):[0-5]\d)$/.exec(message ?? "");
  return m ? m[1]! : null;
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

// ---- Inbound today and the missed calls not called back (addition 0008i, brief B15) ---------------

/** The tiles of the inbound row, in order; each a figure of cma.inbound_today */
export type InboundTileKey = "offered" | "answered" | "unansweredPct" | "serviceLevel" | "avgAnswer" | "waitingNow" | "longestWaiting";
export const INBOUND_TILES: readonly InboundTileKey[] = ["offered", "answered", "unansweredPct", "serviceLevel", "avgAnswer", "waitingNow", "longestWaiting"];

/** A tile's value, before formatting: a count, a percentage (0 to 100), seconds, or nothing yet */
export type InboundTileValue = { kind: "count"; value: number } | { kind: "pct"; value: number | null } | { kind: "seconds"; value: number | null };

export function inboundTileValue(today: InboundToday, key: InboundTileKey): InboundTileValue {
  switch (key) {
    case "offered": return { kind: "count", value: today.offered };
    case "answered": return { kind: "count", value: today.answered };
    case "unansweredPct": return { kind: "pct", value: unansweredPct(today) };
    case "serviceLevel": return { kind: "pct", value: today.serviceLevelPct };
    case "avgAnswer": return { kind: "seconds", value: today.avgAnswerSeconds };
    case "waitingNow": return { kind: "count", value: today.waitingNow };
    case "longestWaiting": return { kind: "seconds", value: today.longestWaitingSeconds };
  }
}

/** A telephony call of the fixture with the caller as an opaque key, standing in for the hash (never shown) */
export type CallerCall = TelephonyCallFixture & { caller: string | null };

/**
 * The missed calls not called back, as cma.missed_callbacks_of finds them: per caller the latest
 * missed inbound call whose reason needs a callback, started within the lookback, with no later
 * callback (an outbound call to the caller, connected or not, or an answered inbound call from them, on
 * any connection); missed_count the caller's missed calls in the lookback since their latest callback
 * before that call (missed Monday, called back Monday, missed Tuesday is 1); oldest first. Calls without
 * a caller are counted apart (anonymous), never listed. businessSeconds gives the office seconds of a
 * market (null without one), as cma.business_seconds_of.
 */
export function missedCallbacks(
  calls: readonly CallerCall[], lines: readonly InboundLine[], catalog: readonly MissedReason[], tenantZone: string,
  waitingMaxMinutes: number, lookbackDays: number, nowMs: number,
  businessSeconds: (market: string, from: Instant, toMs: number) => number | null,
  recordUrl: (connectionId: string, sourceId: string) => string | null,
): { rows: MissedCallback[]; anonymousCount: number } {
  const since = nowMs - Math.max(0, lookbackDays) * 86_400_000;
  const recent = calls.filter((c) => Date.parse(c.startedAt) >= since);
  const byId = new Map(recent.map((c) => [`${c.connectionId}/${c.sourceId}`, c]));
  const missed = inboundCalls(recent, lines, catalog, tenantZone, waitingMaxMinutes, nowMs)
    .filter((c) => c.reasonCode !== null)
    .map((c) => {
      const raw = byId.get(`${c.connectionId}/${c.sourceId}`);
      return { ...c, caller: raw?.caller ?? null, lineRef: raw?.lineRef ?? null };
    });
  const anonymousCount = missed.filter((c) => c.caller === null && c.needsCallback).length;
  const latest = new Map<string, (typeof missed)[number]>();
  for (const c of missed) {
    if (c.caller === null || !c.needsCallback) continue;
    const cur = latest.get(c.caller);
    if (!cur || c.startedAt > cur.startedAt || (c.startedAt === cur.startedAt && c.sourceId > cur.sourceId)) latest.set(c.caller, c);
  }
  const rows: MissedCallback[] = [];
  for (const [caller, m] of latest) {
    const at = Date.parse(m.startedAt);
    const callbacks = calls.filter((o) => o.caller === caller && !o.deleted && (o.direction === "outbound" || o.answeredAt !== null))
      .map((o) => Date.parse(o.startedAt));
    if (callbacks.some((t) => t > at)) continue;
    const lastCallback = Math.max(-Infinity, ...callbacks.filter((t) => t < at));
    rows.push({
      callId: `${m.connectionId}/${m.sourceId}`, connectionId: m.connectionId, sourceId: m.sourceId, lineRef: m.lineRef,
      lineName: m.lineName, market: m.market, reasonCode: m.reasonCode!, reasonLabel: m.reasonLabel!, startedAt: m.startedAt,
      missedCount: missed.filter((c) => c.caller === caller && Date.parse(c.startedAt) > lastCallback).length,
      waitingSeconds: Math.max(0, Math.floor((nowMs - Date.parse(m.startedAt)) / 1000)),
      waitingBusinessSeconds: m.market === "unknown" ? null : businessSeconds(m.market, m.startedAt, nowMs),
      recordUrl: recordUrl(m.connectionId, m.sourceId),
    });
  }
  return { rows: sortCallbacks(rows), anonymousCount };
}

/** Oldest first, then by the call's id, as the database orders them */
export function sortCallbacks<T extends Pick<MissedCallback, "startedAt" | "sourceId">>(rows: readonly T[]): T[] {
  return [...rows].sort((a, b) => Date.parse(a.startedAt) - Date.parse(b.startedAt) || a.sourceId.localeCompare(b.sourceId));
}

/**
 * How long a missed call has waited: office time in the line's market, else (a line without a market) the
 * time since the call. closed: no office time at all has passed since the call although time has, so the
 * line's market is closed right now (a Saturday, the evening); the board then says so instead of "0 min"
 * (the IT audit of 17 October 2026). The figure itself does not change.
 */
export function callbackWaiting(r: Pick<MissedCallback, "waitingBusinessSeconds" | "waitingSeconds">): { kind: "business" | "elapsed"; seconds: number; closed: boolean } {
  return r.waitingBusinessSeconds === null
    ? { kind: "elapsed", seconds: r.waitingSeconds, closed: false }
    : { kind: "business", seconds: r.waitingBusinessSeconds, closed: r.waitingBusinessSeconds === 0 && r.waitingSeconds > 0 };
}
