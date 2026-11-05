/**
 * The Live board's rows from one read (addition 0008zr's web, night N06): what the page computed on the server from six
 * reads, now a pure function of GET /api/v1/live/board's answer, so the board's client (LiveBoardLive) computes the
 * same rows from every poll. The labels are pre-formatted in the person's zone and the viewer's locale; the adherence
 * flags are judged at the read's instant (readAt), the same on the server and the client, so nothing differs between
 * the server render and the hydration.
 */
import type { Locale } from "@/lib/copy";
import type { LiveBoardData, TeamNowPerson, TodayShift, WorkdayClock } from "@/lib/data";
import { liveRows, teamKeysByUser, type LiveGroup, type LiveRow } from "@/lib/live";
import { adherence, cellLabel, type Adherence } from "@/lib/roster";
import { fmtTime, fmtZoneShort, sameOffset } from "@/lib/time";

/** One row, with its labels pre-formatted on the server in the person's zone and locale */
export interface BoardRow {
  userId: string;
  displayName: string;
  organisationKey: string;
  organisationName: string;
  group: LiveGroup;
  /** The current status; null without a day and once the day has ended */
  statusName: string | null;
  statusActive: boolean;
  statusSince: string | null;
  /** The clock's inputs; null without a day. An ended day has nothing running */
  clock: WorkdayClock | null;
  inLabel: string | null;
  outLabel: string | null;
  /** Short zone name when the person's zone differs from the viewer's */
  zoneLabel: string | null;
  /** The person's current teams (migration 0004), for the team filter and the Team column */
  teams: { key: string; name: string }[];
  /** Today's published shift (migration 0005) with the adherence flag derived on the server */
  shift: { label: string | null; published: boolean; flag: Adherence | null };
}

export interface LiveViewer {
  locale: Locale;
  timeZone: string;
}

/** The planned shift and the flag next to it, from today's published entry and the day's clock */
export function shiftLine(
  shift: TodayShift | undefined, person: TeamNowPerson, nowMs: number, tolerance: number,
): BoardRow["shift"] {
  if (!shift || !shift.isPublished) return { label: null, published: false, flag: null };
  const planned = shift.kind ? { kind: shift.kind, start: shift.start, end: shift.end } : null;
  const flag = adherence(planned, { startedAt: person.day?.startedAt ?? null, endedAt: person.day?.endedAt ?? null }, shift.date, person.timeZone, nowMs, tolerance);
  return {
    label: planned ? cellLabel({ kind: planned.kind, start: planned.start, end: planned.end, absenceName: shift.absenceName }) : null,
    published: true,
    flag,
  };
}

/** The board's rows (one per person whose time is kept) and the live rows the tiles and filters are built from */
export function boardRowsOf(data: LiveBoardData, viewer: LiveViewer): { rows: LiveRow[]; board: BoardRow[] } {
  const rows = liveRows(data.now.people);
  const teamKeys = teamKeysByUser(data.memberships);
  const teamName = new Map(data.memberships.map((m) => [m.teamKey, m.teamName]));
  const shiftOf = new Map(data.shifts.map((x) => [x.userId, x]));
  const nowMs = Date.parse(data.readAt);
  const board: BoardRow[] = rows.map(({ person, group }) => ({
    userId: person.userId,
    displayName: person.displayName,
    organisationKey: person.organisationKey ?? "",
    organisationName: person.organisationName,
    group,
    statusName: person.status?.name ?? null,
    statusActive: person.status?.isActive ?? true,
    statusSince: person.day?.statusSince ?? null,
    // The clock's inputs; an ended day has nothing running, so its figure stands still
    clock: person.day?.clock ?? null,
    // Times in the person's own zone, as Team hours shows them, with the zone's short name when
    // its clock differs from the viewer's (Madrid and Amsterdam share one, London does not)
    inLabel: person.day ? fmtTime(person.day.startedAt, person.timeZone, viewer.locale) : null,
    outLabel: person.day?.endedAt ? fmtTime(person.day.endedAt, person.timeZone, viewer.locale) : null,
    zoneLabel: person.day && !sameOffset(person.day.startedAt, person.timeZone, viewer.timeZone)
      ? fmtZoneShort(person.day.startedAt, person.timeZone, viewer.locale) : null,
    teams: (teamKeys.get(person.userId) ?? []).map((key) => ({ key, name: teamName.get(key) ?? key })),
    shift: shiftLine(shiftOf.get(person.userId), person, nowMs, data.settings.adherenceToleranceMinutes),
  }));
  return { rows, board };
}

/** The board's poll: every 10 seconds while the tab is visible; after a failed poll the wait doubles up to a minute */
export const LIVE_POLL_MS = 10_000;
export const LIVE_POLL_MAX_MS = 60_000;
export function nextPollMs(failures: number): number {
  return Math.min(LIVE_POLL_MAX_MS, LIVE_POLL_MS * 2 ** failures);
}
