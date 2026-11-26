/**
 * My day's plan against actual (addition 0010a, brief B; the screens Arno and Kira approved on 26 November 2026, artboards
 * 1 to 5): the two lanes, Scheduled (today's published blocks) and Actual (the day's stretches), on one axis with a Now
 * marker; the words of a block (CODE · MARKET, a pause its code, an absence its name); the colour a block or a stretch
 * takes (lib/assignments' tones, so plan and actual look the same); the Switch button's label. Pure and without runtime
 * imports beyond lib/assignments, so verify/roster.mjs tests it without a browser or a database. Codes, statuses and
 * markets are the tenant's: nothing here knows a key.
 */
import type { ActualStretch, MyDayBlock, WorkArea } from "./data/types";
// With its extension, so verify/roster.mjs can run this module under Node's type stripping
import { toneOf, type Tone } from "./assignments.ts";

/** A thing drawn on a lane: a block of the plan or a stretch of the day */
export interface LaneItem {
  code: string | null;
  name: string;
  kind: "work" | "pause" | "absence" | "other";
  isExtra?: boolean;
  workArea: WorkArea | null;
  market: string | null;
  from: number;
  to: number;
  /** An Actual stretch that deviates from the plan (E7): drawn with an orange outline */
  deviates?: boolean;
}

/**
 * The words on a block or stretch (E10, Martin, 26 November 2026): CODE · MARKET for work (GO · SE), the code alone for a
 * pause (SB), the absence's name for an absence, the status's name for a stretch without an assignment (Training)
 */
export function itemLabel(x: Pick<LaneItem, "code" | "name" | "kind" | "market">): string {
  if (x.kind === "absence" || !x.code) return x.name;
  if (x.kind === "pause" || !x.market) return x.code;
  return `${x.code} · ${x.market}`;
}

/** The chip's words in the status line: CODE · Name (GO · General Ops), or the name alone without a code */
export function chipLabel(x: { code: string | null; name: string }): string {
  return x.code ? `${x.code} · ${x.name}` : x.name;
}

/**
 * The colour of a block or stretch: the tones of the planner (D13), so plan and actual look the same; an absence Background
 * Blue; a working stretch without an assignment its status group (productive or other work by its work area)
 */
export function itemTone(x: Pick<LaneItem, "kind" | "workArea" | "isExtra">): Tone | "absence" {
  if (x.kind === "absence") return "absence";
  if (x.kind === "pause") return "pause";
  if (x.kind === "other") return x.workArea ? toneOf({ kind: "work", workArea: x.workArea, isExtra: false, statusIsProductive: true }) : "otherWork";
  return toneOf({ kind: "work", workArea: x.workArea, isExtra: x.isExtra ?? false, statusIsProductive: true });
}

export function blockItem(b: MyDayBlock): LaneItem {
  return { code: b.code, name: b.name, kind: b.kind, isExtra: b.isExtra, workArea: b.workArea, market: b.hoursMarket, from: Date.parse(b.startAt), to: Date.parse(b.endAt) };
}

/** A stretch as a lane item; a running one up to now */
export function stretchItem(a: ActualStretch, nowMs: number): LaneItem {
  return {
    code: a.code, name: a.name, kind: a.kind, workArea: a.workArea, market: a.hoursMarket, from: Date.parse(a.fromAt),
    to: a.toAt ? Date.parse(a.toAt) : nowMs, deviates: a.deviates,
  };
}

/** The lanes' axis in ms: the plan's span, widened by the Actual lane and now when they lie outside it; a quarter hour each side */
export function laneAxis(plan: readonly LaneItem[], actual: readonly LaneItem[], nowMs: number | null): { from: number; to: number } {
  const all = [...plan, ...actual];
  const q = 15 * 60_000;
  if (all.length === 0) {
    const at = nowMs ?? 0;
    return { from: Math.floor(at / q) * q - 4 * q, to: Math.floor(at / q) * q + 4 * q };
  }
  // the plan alone sets the axis when there is one (artboards: Actual from 08:58 drawn from 09:00); else the stretches
  const base = plan.length > 0 ? plan : actual;
  let from = Math.min(...base.map((x) => x.from));
  let to = Math.max(...base.map((x) => x.to));
  if (plan.length > 0) {
    const late = Math.max(to, ...actual.map((x) => x.to), nowMs ?? 0);
    if (late > to) to = Math.ceil(late / q) * q;
  }
  if (to - from < q) { from -= q; to += q; }
  return { from, to };
}

/** A position on the axis in percent, clamped to the lane */
export function lanePct(ms: number, axis: { from: number; to: number }): number {
  const span = Math.max(1, axis.to - axis.from);
  return Math.max(0, Math.min(100, ((ms - axis.from) / span) * 100));
}

/** An item's left and width in percent, clamped to the lane (an Actual stretch from before the plan's start begins at its edge) */
export function laneBox(x: Pick<LaneItem, "from" | "to">, axis: { from: number; to: number }): { left: number; width: number } {
  const left = lanePct(x.from, axis);
  return { left, width: Math.max(0, lanePct(x.to, axis) - left) };
}

/**
 * The axis's labels: its start and its end, and between them whole hours from the start a step apart (1, 2, 3, 4, 6 or 12
 * hours: the smallest that fits), none within a tenth of the span of either end; at most `max` in all (the artboards show
 * five: 09:00, 11:00, 13:00, 15:00, 17:30)
 */
export function laneTicks(axis: { from: number; to: number }, max = 5): number[] {
  const hour = 60 * 60_000;
  const span = axis.to - axis.from;
  const room = Math.max(0, max - 2);
  for (const step of [1, 2, 3, 4, 6, 12]) {
    const inner: number[] = [];
    for (let t = axis.from + step * hour; t < axis.to; t += step * hour) {
      if (t - axis.from > span / 10 && axis.to - t > span / 10) inner.push(t);
    }
    if (inner.length <= room) return [axis.from, ...inner, axis.to];
  }
  return [axis.from, axis.to];
}

/**
 * The Switch panel's confirm label (E6): "Switch to GO · SE" for work under a market, "Switch to SB Short break" for a
 * pause, "Switch to Training" for an Other status; the words "Switch to" from the copy
 */
export function switchLabel(prefix: string, choice: { kind: "work" | "pause" | "other"; code: string | null; name: string; market: string | null }): string {
  if (choice.kind === "work") return `${prefix} ${choice.code}${choice.market ? ` · ${choice.market}` : ""}`;
  if (choice.kind === "pause") return `${prefix} ${choice.code} ${choice.name}`;
  return `${prefix} ${choice.name}`;
}

/** Seconds as the house's minutes, "4h 05m" or "30m" (lib/time's fmtMinutes, so My hours reads as Team hours) */
export function hoursMinutes(seconds: number): string {
  const minutes = Math.floor(Math.max(0, seconds) / 60);
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return h === 0 ? `${m}m` : `${h}h ${String(m).padStart(2, "0")}m`;
}
