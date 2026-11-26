/**
 * Assignments in the roster (addition 0009zx, brief A; Decision log, 25 November 2026, D1 to D13): the planner's typing
 * parser ("CODE" or "CODE-MARKET"), painting blocks over slots, the colours a block takes from what its type books, the
 * slot grid, the conversion between a person's zone and the planner zone, the planned figures (D12) and the plan check.
 * Pure and without runtime imports beyond the zone helpers of lib/corrections, so verify/roster.mjs tests it without a
 * browser or a database. Codes, markets, statuses and settings are the tenant's: nothing here knows a key.
 */
import type { DateKey, RosterWeek } from "./data/types";
// With its extension, so verify/roster.mjs can run this module under Node's type stripping
import { instantsForLocal, localParts } from "./corrections.ts";

/** An assignment type as the planner reads it (cma.assignment_types) */
export interface AssignmentTypeLike {
  code: string;
  name: string;
  kind: "work" | "pause";
  /** The Work area of the status the type books; null without one or for an extra type */
  workArea: "sales" | "operations" | null;
  isExtra: boolean;
  /** Whether the status it books is productive; null for an extra type */
  statusIsProductive: boolean | null;
  isActive: boolean;
}

/** A block of a person-date in minutes of the day it is drawn on (the person's day, or the planner zone's day) */
export interface Block {
  code: string;
  start: number;
  end: number;
  /** An hours market code; null is own market (the person's Default market at booking, D1) */
  market: string | null;
  note: string | null;
}

/** The alias the parser takes for an hours market: the planner may still type UK, the plan always says GB (D5) */
export const MARKET_ALIASES: Readonly<Record<string, string>> = { UK: "GB" };

export type ParseProblem = "empty" | "unknown" | "retired" | "market" | "pauseMarket" | "format";

/**
 * What the planner types over a selection (D5): a type's code, or the code and an hours market joined by a hyphen (SL,
 * SL-GB, GO-DE; an en dash too), any case. The market must be an active hours market of the tenant; UK is read as GB.
 * A pause has no hours market (0009zz): LB-GB is refused (pauseMarket).
 */
export function parseAssignment(
  text: string, types: readonly AssignmentTypeLike[], hoursMarkets: readonly { code: string; isActive: boolean }[],
): { code: string; market: string | null } | { problem: ParseProblem } {
  const raw = text.trim().toUpperCase().replace(/\s+/g, "");
  if (raw === "") return { problem: "empty" };
  const m = /^([A-Z0-9]{1,6})(?:[-–]([A-Z]{2}))?$/.exec(raw);
  if (!m) return { problem: "format" };
  const type = types.find((t) => t.code === m[1]);
  if (!type) return { problem: "unknown" };
  if (!type.isActive) return { problem: "retired" };
  if (!m[2]) return { code: type.code, market: null };
  if (type.kind === "pause") return { problem: "pauseMarket" };
  const code = MARKET_ALIASES[m[2]] ?? m[2];
  if (!hoursMarkets.some((h) => h.code === code && h.isActive)) return { problem: "market" };
  return { code: type.code, market: code };
}

/** The text a block shows in the planner's typing field: CODE, or CODE-MARKET */
export function assignmentText(b: { code: string; market: string | null }): string {
  return b.market ? `${b.code}-${b.market}` : b.code;
}

// ---- the planner's payload ------------------------------------------------------------------------

/** A week's blocks as the planner's page sends them to the browser: per `${userId}:${date}`, [code, start, end, market, note] */
export type CompactBlocks = Record<string, [string, string, string, string | null, string | null][]>;

/** The planner's week without the full block rows: the type's name, kind and colour come from the catalog it carries */
export type PlannerWeek = Omit<RosterWeek, "assignments"> & { blocks: CompactBlocks };

/**
 * The week for the planner's client components with its blocks compacted (about a tenth of the rows' size), so a full
 * week of blocks keeps the page within its HTML budget (web/verify/perf.json)
 */
export function plannerWeek(week: RosterWeek): PlannerWeek {
  const { assignments, ...rest } = week;
  const blocks: CompactBlocks = {};
  for (const a of assignments) {
    (blocks[`${a.userId}:${a.date}`] ??= []).push([a.code, a.start.slice(0, 5), a.end.slice(0, 5), a.hoursMarket, a.note]);
  }
  return { ...rest, blocks };
}

// ---- colours (D13) --------------------------------------------------------------------------------

/** What a block's colour follows from (D13): the status group of the status its type books, a pause, or extra */
export type Tone = "sales" | "operations" | "productive" | "otherWork" | "pause" | "extra";

/**
 * D13 and the status groups of 23 November 2026, so plan and actual look the same: a type booking a status with Work
 * area Sales is Sales, with Operations is Operations; kind pause is Pause; is_extra is Extra. A working status without a
 * work area takes its status group as the Live board does: productive (Leaf Green), else Other work (Inkt).
 */
export function toneOf(t: Pick<AssignmentTypeLike, "kind" | "workArea" | "isExtra" | "statusIsProductive">): Tone {
  if (t.isExtra) return "extra";
  if (t.kind === "pause") return "pause";
  if (t.workArea === "sales") return "sales";
  if (t.workArea === "operations") return "operations";
  return t.statusIsProductive === false ? "otherWork" : "productive";
}

/** The palette's classes per tone (Pulse4all-Style 2.1 and 7.8: white text only on Deep Blue and Inkt) */
export const TONE_CLASS: Readonly<Record<Tone | "absence", string>> = {
  sales: "bg-p4a-green text-p4a-inkt border border-p4a-green",
  operations: "bg-p4a-deepblue text-white border border-p4a-deepblue",
  productive: "bg-p4a-green text-p4a-inkt border border-p4a-green",
  otherWork: "bg-p4a-inkt text-white border border-p4a-inkt",
  pause: "bg-p4a-rose text-p4a-inkt border border-p4a-rose",
  extra: "bg-white text-p4a-inkt border border-dashed border-p4a-inkt",
  absence: "bg-p4a-bgblue text-p4a-deepblue border border-p4a-bgblue",
};

// ---- times ----------------------------------------------------------------------------------------

/** Minutes from midnight of "hh:mm" or "hh:mm:ss"; 24:00 is 1440 */
export function toMinutes(time: string): number {
  return Number(time.slice(0, 2)) * 60 + Number(time.slice(3, 5));
}

/** "hh:mm" of minutes from midnight; 1440 is 24:00 */
export function fromMinutes(min: number): string {
  return `${String(Math.floor(min / 60)).padStart(2, "0")}:${String(min % 60).padStart(2, "0")}`;
}

/** A share in percent with two decimals, for a bar's left and width (fewer digits in the page than a float's) */
export function pct(part: number, whole: number): number {
  return Math.round((part / whole) * 10000) / 100;
}

/** The slot a minute lies in, as its start */
export function slotFloor(min: number, slotMinutes: number): number {
  return Math.floor(min / slotMinutes) * slotMinutes;
}

/** The instant (ms) of a local date and time in a zone; 24:00 is the next day's midnight; the earlier one when it occurs twice */
export function instantOf(date: DateKey, time: string, timeZone: string): number | null {
  const t = time.slice(0, 5);
  if (t === "24:00") {
    const [y, m, d] = date.split("-").map(Number) as [number, number, number];
    const next = new Date(Date.UTC(y, m - 1, d + 1)).toISOString().slice(0, 10);
    return instantsForLocal(next, "00:00", timeZone)[0]?.ms ?? null;
  }
  return instantsForLocal(date, t, timeZone)[0]?.ms ?? null;
}

/**
 * A person's local time on their business date in minutes of the planner zone's day (the Day view's axis). Equal zones
 * keep the minutes as they are; otherwise the instant decides, so a person an hour behind the planner starts an hour
 * later on the axis. Null when the time does not exist in the person's zone (a spring-forward gap)
 */
export function toPlannerMinutes(date: DateKey, time: string, personZone: string, plannerZone: string): number | null {
  if (personZone === plannerZone) return toMinutes(time);
  const at = instantOf(date, time, personZone);
  const dayStart = instantOf(date, "00:00", plannerZone);
  return at === null || dayStart === null ? null : Math.round((at - dayStart) / 60_000);
}

/**
 * The person's local "hh:mm" on their business date for minutes of the planner zone's day: null when the instant is not on
 * the person's date (an axis minute outside the person's day). 24:00 for the person's midnight after the date
 */
export function fromPlannerMinutes(min: number, date: DateKey, personZone: string, plannerZone: string): string | null {
  if (personZone === plannerZone) return min >= 0 && min <= 1440 ? fromMinutes(min) : null;
  const dayStart = instantOf(date, "00:00", plannerZone);
  if (dayStart === null) return null;
  const p = localParts(dayStart + min * 60_000, personZone);
  if (p.date === date) return p.time.slice(0, 5);
  const [y, m, d] = date.split("-").map(Number) as [number, number, number];
  const next = new Date(Date.UTC(y, m - 1, d + 1)).toISOString().slice(0, 10);
  return p.date === next && p.time.startsWith("00:00") ? "24:00" : null;
}

// ---- painting ---------------------------------------------------------------------------------------

/** Blocks in start order, neighbours of the same code, market and note joined: consecutive slots draw as one bar (D13) */
export function joinBlocks(blocks: readonly Block[]): Block[] {
  const sorted = [...blocks].filter((b) => b.end > b.start).sort((a, b) => a.start - b.start);
  const out: Block[] = [];
  for (const b of sorted) {
    const last = out[out.length - 1];
    if (last && last.end === b.start && last.code === b.code && last.market === b.market && last.note === b.note) last.end = b.end;
    else out.push({ ...b });
  }
  return out;
}

/**
 * Paints [from, to) of a person's day with a type and market, or empties it (paint null; Delete). A block the range
 * covers in part is cut, keeping its note on both sides; the result is joined (joinBlocks). The range is clipped to the
 * shift: nothing is painted outside it
 */
export function paintBlocks(
  blocks: readonly Block[], from: number, to: number, paint: { code: string; market: string | null } | null,
  shift: { start: number; end: number },
): Block[] {
  const a = Math.max(from, shift.start);
  const z = Math.min(to, shift.end);
  if (z <= a) return joinBlocks(blocks);
  const out: Block[] = [];
  for (const b of blocks) {
    if (b.end <= a || b.start >= z) { out.push({ ...b }); continue; }
    if (b.start < a) out.push({ ...b, end: a });
    if (b.end > z) out.push({ ...b, start: z });
  }
  if (paint) out.push({ code: paint.code, market: paint.market, note: null, start: a, end: z });
  return joinBlocks(out);
}

/** Whether two block lists of a person-date are the same plan (the write can be skipped) */
export function sameBlocks(a: readonly Block[], b: readonly Block[]): boolean {
  const x = joinBlocks(a);
  const y = joinBlocks(b);
  return x.length === y.length && x.every((p, i) => {
    const q = y[i]!;
    return p.code === q.code && p.start === q.start && p.end === q.end && p.market === q.market && p.note === q.note;
  });
}

// ---- the planned figures (D12) --------------------------------------------------------------------

/** A type and market as one key of the planned figures: "SL/GB", or "SL/" without a market (a pause, or no Default market) */
export function figureKey(code: string, market: string | null): string {
  return `${code}/${market ?? ""}`;
}

/** The market a block counts under (D12, 0009zz): a pause under none, a block without a market under the Default market */
export function figureMarket(b: Pick<Block, "code" | "market">, defaultMarket: string | null, kinds: ReadonlyMap<string, "work" | "pause">): string | null {
  return kinds.get(b.code) === "pause" ? null : b.market ?? defaultMarket;
}

export interface PersonBlocks {
  userId: string;
  /** The person's Default market: a block without a market counts under it (D12) */
  defaultMarket: string | null;
  /** In minutes of the axis the figures are counted on */
  blocks: readonly Block[];
}

export interface SlotFigure {
  start: number;
  /** People with a block of kind work in the slot: on the inbound queue (D12) */
  working: number;
  /** People per type and market (figureKey) */
  byKey: Map<string, number>;
}

/**
 * D12 per slot, as cma.roster_slot_coverage counts them: from `from` to `to` on the slot grid, the people working (a
 * block of kind work) and the people per type and hours market (a pause under no market); a slot without a block counts 0
 */
export function slotFigures(people: readonly PersonBlocks[], kinds: ReadonlyMap<string, "work" | "pause">, slotMinutes: number, from: number, to: number): SlotFigure[] {
  const out: SlotFigure[] = [];
  for (let s = slotFloor(from, slotMinutes); s < to; s += slotMinutes) {
    const byKey = new Map<string, number>();
    const working = new Set<string>();
    for (const p of people) {
      for (const b of p.blocks) {
        if (b.start <= s && s < b.end) {
          const k = figureKey(b.code, figureMarket(b, p.defaultMarket, kinds));
          byKey.set(k, (byKey.get(k) ?? 0) + 1);
          if (kinds.get(b.code) === "work") working.add(p.userId);
        }
      }
    }
    out.push({ start: s, working: working.size, byKey });
  }
  return out;
}

/** D12 per person: the planned minutes per type and hours market over the blocks given (a pause under no market) */
export function plannedByKey(blocks: readonly Block[], defaultMarket: string | null, kinds: ReadonlyMap<string, "work" | "pause">): Map<string, number> {
  const out = new Map<string, number>();
  for (const b of blocks) {
    const k = figureKey(b.code, figureMarket(b, defaultMarket, kinds));
    out.set(k, (out.get(k) ?? 0) + (b.end - b.start));
  }
  return out;
}

/**
 * A person-date's Planned minutes (Martin, 26 November 2026): the blocks of kind work, an extra type included, a pause
 * never; a shift without any block is planned on the day level only and counts whole (as the plan check reads it), an
 * absence or no entry counts 0. Durations in local minutes of the person's day, as the shift's
 */
export function plannedMinutes(
  shift: { start: number; end: number } | null, blocks: readonly Pick<Block, "code" | "start" | "end">[], kinds: ReadonlyMap<string, "work" | "pause">,
): number {
  if (!shift) return 0;
  if (blocks.length === 0) return Math.max(0, shift.end - shift.start);
  return blocks.reduce((n, b) => n + (kinds.get(b.code) === "pause" ? 0 : b.end - b.start), 0);
}

/** Sums maps of minutes per key */
export function addFigures(into: Map<string, number>, from: ReadonlyMap<string, number>): Map<string, number> {
  for (const [k, v] of from) into.set(k, (into.get(k) ?? 0) + v);
  return into;
}

/** One person-date for the Planned hours meter: its entry's shift (null without one) and its blocks */
export interface PlannedDay {
  userId: string;
  date: DateKey;
  defaultMarket: string | null;
  /** The shift in minutes of the person's day; null for an absence or no entry */
  shift: { start: number; end: number } | null;
  blocks: readonly Block[];
}

/** The meter's figures over a set of person-dates (D12, Martin's point 9 of 26 November 2026) */
export interface PlannedSummary {
  /** Planned minutes: work blocks, and shifts planned on the day level only (plannedMinutes) */
  planned: number;
  /** The shifts' minutes: what Planned is measured against */
  onShift: number;
  /** Work minutes per type and hours market (figureKey) */
  byKey: Map<string, number>;
  /** Minutes of shifts without any block (planned on the day level only) */
  dayLevel: number;
  /** Pause minutes per type: never part of Planned */
  pauses: Map<string, number>;
}

/** The meter's figures: Planned (= the sum of every person's Planned), its split per type and market, pauses apart */
export function plannedSummary(days: readonly PlannedDay[], kinds: ReadonlyMap<string, "work" | "pause">): PlannedSummary {
  const out: PlannedSummary = { planned: 0, onShift: 0, byKey: new Map(), dayLevel: 0, pauses: new Map() };
  for (const d of days) {
    if (!d.shift) continue;
    out.onShift += Math.max(0, d.shift.end - d.shift.start);
    out.planned += plannedMinutes(d.shift, d.blocks, kinds);
    if (d.blocks.length === 0) { out.dayLevel += Math.max(0, d.shift.end - d.shift.start); continue; }
    for (const b of d.blocks) {
      if (kinds.get(b.code) === "pause") out.pauses.set(b.code, (out.pauses.get(b.code) ?? 0) + (b.end - b.start));
      else {
        const k = figureKey(b.code, b.market ?? d.defaultMarket);
        out.byKey.set(k, (out.byKey.get(k) ?? 0) + (b.end - b.start));
      }
    }
  }
  return out;
}

/**
 * The order the Assignment dropdown lists the active types in (Martin, 26 November 2026): work types first, then pauses,
 * then the extra types, each group in the tenant's sort order
 */
export function pickerOrder<T extends Pick<AssignmentTypeLike, "kind" | "isExtra" | "isActive"> & { sortOrder?: number; code: string }>(types: readonly T[]): T[] {
  const group = (t: T) => (t.isExtra ? 2 : t.kind === "pause" ? 1 : 0);
  return types.filter((t) => t.isActive)
    .map((t, i) => ({ t, i }))
    .sort((a, b) => group(a.t) - group(b.t) || (a.t.sortOrder ?? 0) - (b.t.sortOrder ?? 0) || a.i - b.i)
    .map((x) => x.t);
}

/**
 * The types the dropdown offers for typed text: the codes that start with it first, then the names that hold it (any case),
 * each in the dropdown's order, so "L" highlights LB before Sales
 */
export function pickerFilter<T extends { code: string; name: string }>(types: readonly T[], text: string): T[] {
  const q = text.trim().toUpperCase().split(/[-–]/)[0] ?? "";
  if (q === "") return [...types];
  const byCode = types.filter((t) => t.code.startsWith(q));
  return [...byCode, ...types.filter((t) => !byCode.includes(t) && t.name.toUpperCase().includes(q))];
}

// ---- the plan check -----------------------------------------------------------------------------

export type PlanWarning = { kind: "lunch" } | { kind: "gap"; start: number; end: number };

/**
 * The plan check before Publish (brief A), two warnings that never block: a shift longer than the tenant's
 * roster.lunch_after_minutes without a lunch block (a block of the type roster.lunch_type_code names; without one, any
 * block of a pause type), and a gap inside a shift that holds blocks. A shift without any block is not checked (a
 * person-date planned on the day level only)
 */
export function planCheck(
  shift: { start: number; end: number }, blocks: readonly Block[], lunchAfterMinutes: number, lunchCode: string,
  kinds: ReadonlyMap<string, "work" | "pause">,
): PlanWarning[] {
  if (blocks.length === 0) return [];
  const out: PlanWarning[] = [];
  const isLunch = (b: Block) => (lunchCode ? b.code === lunchCode : kinds.get(b.code) === "pause");
  if (shift.end - shift.start > lunchAfterMinutes && !blocks.some(isLunch)) out.push({ kind: "lunch" });
  let at = shift.start;
  for (const b of joinBlocks(blocks)) {
    if (b.start > at) out.push({ kind: "gap", start: at, end: b.start });
    at = Math.max(at, b.end);
  }
  if (at < shift.end) out.push({ kind: "gap", start: at, end: shift.end });
  return out;
}
