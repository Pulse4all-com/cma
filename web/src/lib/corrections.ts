/**
 * The day editor's logic, pure and free of runtime imports (verify/corrections.mjs runs it in
 * plain Node).
 *
 * 1. Local time in a zone to an instant. The editor shows a day in the day's own zone, and the
 *    database wants every time with an explicit offset. On the autumn clock change one local hour
 *    occurs twice (two instants), on the spring change one hour does not exist (none). Intl only,
 *    no time library.
 * 2. Edited rows to corrections. The editor works like the demo: one row per event, a time and a
 *    status or "clocked out". The earliest row is the start. Saving sends the smallest honest
 *    diff for cma.correct_workday: a changed row replaces its event, a removed row voids it, a
 *    new row adds one. The database validates everything again; these checks only explain.
 */
import type { CorrectionChange, DateKey, TimeEvent, TimeEventKind } from "./data/types";

// ---- zone math ------------------------------------------------------------------------------

const offsetFormatters = new Map<string, Intl.DateTimeFormat>();
const partFormatters = new Map<string, Intl.DateTimeFormat>();

/** Minutes east of UTC that `timeZone` uses at the instant `ms` */
export function offsetMinutesAt(ms: number, timeZone: string): number {
  let f = offsetFormatters.get(timeZone);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", { timeZone, timeZoneName: "longOffset", year: "numeric" });
    offsetFormatters.set(timeZone, f);
  }
  const name = f.formatToParts(new Date(ms)).find((p) => p.type === "timeZoneName")?.value ?? "GMT";
  const m = /GMT([+-])(\d{1,2})(?::?(\d{2}))?/.exec(name);
  if (!m) return 0;
  return (m[1] === "-" ? -1 : 1) * (Number(m[2]) * 60 + Number(m[3] ?? 0));
}

/** +02:00 */
export function fmtOffset(minutes: number): string {
  const a = Math.abs(minutes);
  return `${minutes < 0 ? "-" : "+"}${String(Math.floor(a / 60)).padStart(2, "0")}:${String(a % 60).padStart(2, "0")}`;
}

/** Date, HH:MM and offset of an instant in a zone */
export function localParts(instant: string | number, timeZone: string): { date: DateKey; time: string; offset: string } {
  const ms = typeof instant === "number" ? instant : Date.parse(instant);
  let f = partFormatters.get(timeZone);
  if (!f) {
    f = new Intl.DateTimeFormat("en-CA", {
      timeZone, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23",
    });
    partFormatters.set(timeZone, f);
  }
  const p = Object.fromEntries(f.formatToParts(new Date(ms)).map((x) => [x.type, x.value]));
  return { date: `${p.year}-${p.month}-${p.day}`, time: `${p.hour}:${p.minute}`, offset: fmtOffset(offsetMinutesAt(ms, timeZone)) };
}

export interface LocalInstant {
  /** ISO 8601 with the offset, as the database wants it: 2026-10-25T02:30:00+02:00 */
  at: string;
  offset: string;
  ms: number;
}

const TIME_RE = /^([01]\d|2[0-3]):([0-5]\d)$/;

/**
 * What the person typed, as HH:MM on a 24-hour clock: "905", "0905", "9:05" and "9.05" all become
 * "09:05". Anything else comes back unchanged, so the check can say what is wrong.
 */
export function normalizeTime(input: string): string {
  const v = input.trim();
  const m = /^(\d{1,2})[:.h]?(\d{2})$/.exec(v);
  if (!m) return v;
  const out = `${m[1]!.padStart(2, "0")}:${m[2]}`;
  return TIME_RE.test(out) ? out : v;
}
const DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/;

/**
 * Every instant at which the clock in `timeZone` shows `time` on `date`, earliest first.
 * One normally, two in the repeated hour of the autumn change, none in the skipped spring hour.
 */
export function instantsForLocal(date: DateKey, time: string, timeZone: string): LocalInstant[] {
  const d = DATE_RE.exec(date);
  const t = TIME_RE.exec(time);
  if (!d || !t) return [];
  const wall = Date.UTC(Number(d[1]), Number(d[2]) - 1, Number(d[3]), Number(t[1]), Number(t[2]));
  const offsets = new Set([-86_400_000, 0, 86_400_000].map((shift) => offsetMinutesAt(wall + shift, timeZone)));
  const out: LocalInstant[] = [];
  for (const o of offsets) {
    const ms = wall - o * 60_000;
    if (offsetMinutesAt(ms, timeZone) === o && !out.some((x) => x.ms === ms)) {
      out.push({ at: `${date}T${time}:00${fmtOffset(o)}`, offset: fmtOffset(o), ms });
    }
  }
  return out.sort((a, b) => a.ms - b.ms);
}

// ---- rows -----------------------------------------------------------------------------------

/** One row of the editor: an event as the person correcting sees it */
export interface EditorRow {
  /** Client id, stable while editing */
  id: string;
  /** The effective event this row shows; null for a new row */
  eventId: string | null;
  /** True for "clocked out"; otherwise statusKey says which status starts here */
  end: boolean;
  statusKey: string | null;
  /** HH:MM in the day's zone */
  time: string;
  /** The chosen offset; only decides anything when the time occurs twice */
  offset: string | null;
}

/** The editor's starting rows: the day's effective events, in order */
export function rowsFromEvents(events: TimeEvent[], timeZone: string): EditorRow[] {
  return events
    .filter((e) => e.isEffective && e.kind !== "void")
    .sort((a, b) => Date.parse(a.at) - Date.parse(b.at))
    .map((e) => {
      const p = localParts(e.at, timeZone);
      return { id: e.id, eventId: e.id, end: e.kind === "end", statusKey: e.kind === "end" ? null : e.statusKey, time: p.time, offset: p.offset };
    });
}

export type RowProblem = "time" | "gap" | "ambiguous" | "future" | "status" | "inactive";
export type DayProblem = "empty" | "firstIsEnd" | "twoEnds" | "endNotLast" | "noChange";

export interface ResolvedRow extends EditorRow {
  kind: Exclude<TimeEventKind, "void">;
  at: string;
  ms: number;
}

export interface Checked {
  /** Rows that resolved, in time order, with their kind derived from that order */
  rows: ResolvedRow[];
  rowProblems: Record<string, RowProblem>;
  dayProblems: DayProblem[];
  /** The diff to send; empty while anything above is wrong */
  changes: CorrectionChange[];
  /** Rows whose time occurs twice: the editor asks for the offset */
  ambiguous: Record<string, LocalInstant[]>;
}

/**
 * Checks the edited rows of `date` and computes the corrections against the starting rows.
 * `nowMs` is the client's clock: the database refuses times in the future anyway. `activeKeys`
 * are the statuses that can be chosen now: a row that keeps a status no longer in use is fine
 * while nothing about it changes (the diff sends nothing for it, history keeps the old key), but a
 * changed row must carry an active status, because every change becomes a new event and the
 * database refuses an inactive status for one (CMA02). Without `activeKeys` the rule is off.
 */
export function check(
  original: EditorRow[], edited: EditorRow[], date: DateKey, timeZone: string, nowMs: number,
  activeKeys?: ReadonlySet<string>,
): Checked {
  const rowProblems: Record<string, RowProblem> = {};
  const ambiguous: Record<string, LocalInstant[]> = {};
  const resolved: Omit<ResolvedRow, "kind">[] = [];

  for (const r of edited) {
    if (!TIME_RE.test(r.time)) { rowProblems[r.id] = "time"; continue; }
    const options = instantsForLocal(date, r.time, timeZone);
    if (options.length === 0) { rowProblems[r.id] = "gap"; continue; }
    let pick = options[0]!;
    if (options.length > 1) {
      ambiguous[r.id] = options;
      const chosen = options.find((o) => o.offset === r.offset);
      if (!chosen) { rowProblems[r.id] = "ambiguous"; continue; }
      pick = chosen;
    }
    if (pick.ms > nowMs) { rowProblems[r.id] = "future"; continue; }
    if (!r.end && !r.statusKey) { rowProblems[r.id] = "status"; continue; }
    resolved.push({ ...r, at: pick.at, ms: pick.ms });
  }

  // The earliest row is the start; a stable order keeps equal times as entered
  const sorted = resolved
    .map((r, i) => ({ r, i }))
    .sort((a, b) => a.r.ms - b.r.ms || a.i - b.i)
    .map(({ r }, i): ResolvedRow => ({ ...r, kind: r.end ? "end" : i === 0 ? "start" : "status" }));

  if (activeKeys) {
    const before = byEvent(original);
    const kinds = originalKinds(original);
    for (const r of sorted) {
      if (r.end || !r.statusKey || activeKeys.has(r.statusKey)) continue;
      if (!unchanged(before, kinds, r)) rowProblems[r.id] = "inactive";
    }
  }

  const dayProblems: DayProblem[] = [];
  if (edited.length === 0) dayProblems.push("empty");
  const ends = sorted.filter((r) => r.kind === "end");
  // One message per mistake: a day that begins with its clock-out says only that
  if (sorted[0]?.end) dayProblems.push("firstIsEnd");
  else if (ends.length > 1) dayProblems.push("twoEnds");
  else if (ends.length === 1 && sorted[sorted.length - 1] !== ends[0]) dayProblems.push("endNotLast");

  let changes: CorrectionChange[] = [];
  if (Object.keys(rowProblems).length === 0 && dayProblems.length === 0) {
    changes = diff(original, sorted);
    if (changes.length === 0) dayProblems.push("noChange");
  }
  return { rows: sorted, rowProblems, dayProblems, changes, ambiguous };
}

/** Original kind of a starting row: the first is the start */
function originalKinds(original: EditorRow[]): Map<string, TimeEventKind> {
  const m = new Map<string, TimeEventKind>();
  original.forEach((r, i) => { if (r.eventId) m.set(r.eventId, r.end ? "end" : i === 0 ? "start" : "status"); });
  return m;
}

/** The starting rows by the event they show */
function byEvent(original: EditorRow[]): Map<string, EditorRow> {
  return new Map(original.filter((r) => r.eventId).map((r) => [r.eventId!, r]));
}

/**
 * True when a row still shows its event as it was: same kind, time, offset and status. Such a
 * row sends nothing; any other row with an event replaces it (one definition for the diff and
 * for the inactive-status rule in check)
 */
function unchanged(before: Map<string, EditorRow>, kinds: Map<string, TimeEventKind>, r: ResolvedRow): boolean {
  const b = r.eventId ? before.get(r.eventId) : undefined;
  if (!b) return false;
  return kinds.get(r.eventId!) === r.kind && b.time === r.time && b.offset === r.offset
    && (r.kind === "end" || b.statusKey === r.statusKey);
}

/**
 * The smallest set of changes from `original` to `rows`. The start goes first, so Add day (no
 * starting rows) always begins with its start, as the database requires.
 */
export function diff(original: EditorRow[], rows: ResolvedRow[]): CorrectionChange[] {
  const before = byEvent(original);
  const kinds = originalKinds(original);
  const kept = new Set<string>();
  const out: CorrectionChange[] = [];

  for (const r of rows) {
    const change: CorrectionChange = { kind: r.kind, at: r.at, ...(r.kind === "end" ? {} : { statusKey: r.statusKey ?? undefined }) };
    if (r.eventId && before.has(r.eventId)) {
      kept.add(r.eventId);
      if (!unchanged(before, kinds, r)) out.push({ ...change, supersedes: r.eventId });
    } else {
      out.push(change);
    }
  }
  for (const id of before.keys()) if (!kept.has(id)) out.push({ kind: "void", supersedes: id });

  // Start first, then voids, then the rest in time order (rows are already in time order)
  const rank = (c: CorrectionChange) => (c.kind === "start" ? 0 : c.kind === "void" ? 1 : 2);
  return out.map((c, i) => ({ c, i })).sort((a, b) => rank(a.c) - rank(b.c) || a.i - b.i).map(({ c }) => c);
}
