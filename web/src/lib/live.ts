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
import type { Copy } from "./copy";
import type { DateKey, Instant, InboundToday, MissedCallback, MissedReason, OutboundNow, TeamMembership, TeamNowPerson, WorkdayClock } from "./data/types";
// With its extension, so verify/live.mjs can run this module under Node's type stripping, which
// resolves no extensionless path (tsconfig: allowImportingTsExtensions)
import { GROUPS, groupOf, type Group } from "./dashboard.ts";
import { callsFigures, inboundCalls, unansweredPct, type CallRecord, type InboundLine, type TelephonyCallFixture } from "./reports.ts";

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

/** What one contact center's board keeps of the board's read: the people with their memberships and shifts */
export interface OrganisationScoped {
  now: { people: TeamNowPerson[] };
  memberships: TeamMembership[];
  shifts: { userId: string }[];
}

/**
 * One contact center's board (addition 0008zv, /live/<key> and GET /api/v1/live/board?organisation=<key>): only the
 * people whose organisation has the key (a person without one is on no contact center's board), and only their team
 * memberships and today's shifts, so the tiles, the groups, the statuses, the team filter and the shift column all
 * follow from them. Everything else stays as read: the tenant's status flags (configuration), and the inbound, outbound, missed
 * and follow-up figures, tenant-wide until a line maps to an organisation (Open decisions). Pure, so the page's first
 * render and every poll's answer are filtered by one function
 */
export function boardOfOrganisation<T extends OrganisationScoped>(data: T, organisationKey: string): T {
  const people = data.now.people.filter((p) => p.organisationKey === organisationKey);
  const ids = new Set(people.map((p) => p.userId));
  return {
    ...data,
    now: { ...data.now, people },
    memberships: data.memberships.filter((m) => ids.has(m.userId)),
    shifts: data.shifts.filter((x) => ids.has(x.userId)),
  };
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

/**
 * The tiles of the inbound row, in order; each a figure of cma.inbound_now's today. Talk time is the fifth, in the
 * column of Outbound today's Talk time (OUTBOUND_TILES; Martin, 10 November 2026)
 */
export type InboundTileKey = "offered" | "answered" | "unansweredPct" | "serviceLevel" | "talk" | "avgAnswer";
export const INBOUND_TILES: readonly InboundTileKey[] = ["offered", "answered", "unansweredPct", "serviceLevel", "talk", "avgAnswer"];

/**
 * A tile's value, before formatting: a count, a percentage (0 to 100), seconds to answer, talk seconds (a duration, as
 * Outbound today's Talk time), or nothing yet
 */
export type InboundTileValue =
  | { kind: "count"; value: number } | { kind: "pct"; value: number | null } | { kind: "seconds"; value: number | null }
  | { kind: "talk"; value: number | null };

export function inboundTileValue(today: InboundToday, key: InboundTileKey): InboundTileValue {
  switch (key) {
    case "offered": return { kind: "count", value: today.offered };
    case "answered": return { kind: "count", value: today.answered };
    case "unansweredPct": return { kind: "pct", value: unansweredPct(today) };
    case "serviceLevel": return { kind: "pct", value: today.serviceLevelPct };
    // a dash without an answered call (Martin, 10 November 2026); Outbound today's Talk time shows 0 s without a connected
    // one. Answered counts the tenant's day and the talk time each call's day in its line's zone, so the dash needs both at
    // 0: a call on a line east of the tenant can carry talk time before the tenant's first answered call of the day
    case "talk": return { kind: "talk", value: today.answered === 0 && today.inboundTalkSeconds === 0 ? null : today.inboundTalkSeconds };
    case "avgAnswer": return { kind: "seconds", value: today.avgAnswerSeconds };
  }
}

/**
 * Today's inbound talk time as cma.inbound_today_live_of computes it (addition 0009j): the talk time (ended − answered,
 * whole seconds) of the answered inbound calls on counted lines (a line not in the catalog counts) started in the
 * tenant's day [fromMs, toMs), the same calls as the row's other figures (Martin, 10 November 2026), 0 without one. It
 * is Reports → Calls' talk time minus its outbound talk time for the date (while Connected needs no minimum talk time)
 * but for the calls whose day in their line's zone differs from the tenant's day (gap D34)
 */
export function inboundTalkToday(calls: readonly TelephonyCallFixture[], lines: readonly InboundLine[], fromMs: number, toMs: number): number {
  let n = 0;
  for (const c of calls) {
    if (c.direction !== "inbound" || c.deleted || !c.startedAt || c.answeredAt === null || c.endedAt === null) continue;
    const line = lines.find((l) => l.connectionId === c.connectionId && l.lineRef === c.lineRef);
    if (line && !line.isCounted) continue;
    const started = Date.parse(c.startedAt);
    if (started < fromMs || started >= toMs) continue;
    n += Math.max(0, Math.floor((Date.parse(c.endedAt) - Date.parse(c.answeredAt)) / 1000));
  }
  return n;
}

// ---- Outbound today (addition 0009h) -----------------------------------------------------------

/** The tiles of the outbound row, in order; each a figure of cma.outbound_now */
export type OutboundTileKey = "attempts" | "connected" | "connectedRate" | "conversations" | "talk" | "talkAvg";
export const OUTBOUND_TILES: readonly OutboundTileKey[] = ["attempts", "connected", "connectedRate", "conversations", "talk", "talkAvg"];

/** A tile's value, before formatting: a count, a rate (0 to 100, one decimal; null without an attempt) or talk seconds */
export type OutboundTileValue = { kind: "count"; value: number } | { kind: "rate"; value: number | null } | { kind: "talk"; value: number | null };

export function outboundTileValue(today: OutboundNow, key: OutboundTileKey): OutboundTileValue {
  switch (key) {
    case "attempts": return { kind: "count", value: today.attempts };
    case "connected": return { kind: "count", value: today.connected };
    case "connectedRate": return { kind: "rate", value: today.connectedRate };
    case "conversations": return { kind: "count", value: today.conversations };
    case "talk": return { kind: "talk", value: today.talkSeconds };
    case "talkAvg": return { kind: "talk", value: today.talkAvgSeconds };
  }
}

/**
 * Today's outbound figures as cma.outbound_today_of computes them: of the calls as cma.calls_of classifies them
 * (lib/reports callRecords: counted lines, each call's date in its line's zone), the outbound ones of the date; the
 * figures are Reports → Calls' own (callsFigures) over that set, so the conversations are the outbound ones only
 */
export function outboundToday(calls: readonly CallRecord[], date: DateKey): OutboundNow {
  const f = callsFigures(calls.filter((c) => c.direction === "outbound" && c.date === date));
  return {
    date, attempts: f.outbound, connected: f.connected, connectedRate: f.connectedRate, conversations: f.conversations,
    talkSeconds: f.outboundTalkSeconds, talkAvgSeconds: f.outboundTalkAvgSeconds,
  };
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

// ---- Inbound today by hour (the Live board's UX pass, 10 November 2026) -----------------------------

/** One hour of today's inbound calls, as Reports → Inbound's hour rows give them (each call's hour in its line's zone) */
export interface InboundHour {
  hour: number;
  offered: number;
  answered: number;
  unanswered: number;
  waiting: number;
  serviceLevelPct: number | null;
}

/**
 * The 24 hours 00 to 23 from cma.inbound_service's hour rows (group key "00" to "23"; the total row, with no key, left
 * out), an hour without calls at 0, so the chart's columns never move
 */
export function inboundHours(rows: readonly { groupKey: string | null; offered: number; answered: number; unanswered: number; waiting: number; serviceLevelPct: number | null }[]): InboundHour[] {
  const byHour = new Map<number, InboundHour>();
  for (const r of rows) {
    if (r.groupKey === null || !/^([01]\d|2[0-3])$/.test(r.groupKey)) continue;
    const hour = Number(r.groupKey);
    byHour.set(hour, { hour, offered: r.offered, answered: r.answered, unanswered: r.unanswered, waiting: r.waiting, serviceLevelPct: r.serviceLevelPct });
  }
  return Array.from({ length: 24 }, (_, hour) => byHour.get(hour) ?? { hour, offered: 0, answered: 0, unanswered: 0, waiting: 0, serviceLevelPct: null });
}

/**
 * The axis' top for counts: the largest value rounded up to a clean whole step (1, 1.5, 2, 2.5, 3, 4, 5, 6, 8 or 10 times
 * a power of ten), at least 4, so the tallest column fills most of the plot
 */
export function niceCeiling(max: number): number {
  const m = Math.max(4, Math.ceil(max));
  const p = 10 ** Math.floor(Math.log10(m));
  for (const f of [1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]) if (f * p >= m && Number.isInteger(f * p)) return f * p;
  return 10 * p;
}

// ---- The board's poll state and its words (the Live board's UX and speed pass, 10 November 2026) ---------

/** A poll that has not answered after this long is given up and counts as failed (the Live board's UX pass, 10 November 2026) */
export const LIVE_POLL_TIMEOUT_MS = 8_000;

/**
 * Whether the board says its figures are old: after two failed polls in a row (at least 30 seconds without a new read,
 * the wait doubling), never after one, which the next poll usually mends unseen (the Live board's UX pass)
 */
export const LIVE_STALE_AFTER_FAILURES = 2;
export function isStale(failures: number): boolean {
  return failures >= LIVE_STALE_AFTER_FAILURES;
}

/**
 * The hints and follow-up words the board shows, the only ones the page sends with it (the Live board's speed review, 10
 * November 2026: the whole hints object, 447 entries, weighed about 12 kB gzip in every board's page, of which the board
 * shows about thirty). The board's components take these types, so a hint used and not sent fails the build
 */
export const LIVE_HINT_KEYS = [
  "about", "howComputed", "officeHours",
  "liveOffered", "liveAnswered", "unansweredPct", "serviceLevel", "liveInboundTalk", "avgAnswer", "liveHours",
  "liveOutboundAttempts", "callsConnected", "callsConnectedMin", "callsConnectedRate", "liveOutboundConversations", "liveOutboundTalk", "liveOutboundAvgTalk",
  "fuLeadsOpen", "fuLeadsPast", "fuTicketsAtRisk", "fuTicketsBreached", "fuTasksOverdue", "fuTasksToday",
  "missedCallbacks", "missedLine", "missedMarket", "missedReason", "missedAt", "missedWaiting", "missedTimes",
] as const satisfies readonly (keyof Copy["hints"])[];
export type LiveHints = Pick<Copy["hints"], (typeof LIVE_HINT_KEYS)[number]>;
export const LIVE_FOLLOW_UP_KEYS = [
  "tileLeadsOpen", "tileLeadsPast", "tileTicketsAtRisk", "tileTicketsBreached", "tileTasksOverdue", "tileTasksToday",
] as const satisfies readonly (keyof Copy["followUp"])[];
export type LiveFollowUpWords = Pick<Copy["followUp"], (typeof LIVE_FOLLOW_UP_KEYS)[number]>;

/** The board's slice of the copy object: these keys of hints and followUp, the other parts whole (they are small) */
export type LiveBoardWords = Pick<Copy, "live" | "inbound" | "reports" | "dashboard"> & { hints: LiveHints; followUp: LiveFollowUpWords };
export function liveBoardWords(copy: Copy): LiveBoardWords {
  const pick = <T extends object, K extends keyof T>(o: T, keys: readonly K[]) => Object.fromEntries(keys.map((k) => [k, o[k]])) as Pick<T, K>;
  return {
    live: copy.live, inbound: copy.inbound, reports: copy.reports, dashboard: copy.dashboard,
    hints: pick(copy.hints, LIVE_HINT_KEYS), followUp: pick(copy.followUp, LIVE_FOLLOW_UP_KEYS),
  };
}

/** How often Inbound today by hour is read again while the tab is visible: the hours change by the call, not the second */
export const LIVE_HOURS_MS = 60_000;

/**
 * Whether the hours are due for a read: never read (0), or read at least LIVE_HOURS_MS ago. A tab that comes back
 * within the minute keeps its chart and waits for the rest of the minute (cma-performance, 10 November 2026)
 */
export function hoursDue(lastReadMs: number, nowMs: number): boolean {
  return lastReadMs === 0 || nowMs - lastReadMs >= LIVE_HOURS_MS;
}
