"use client";

/**
 * The planner's Day view (addition 0009zx, brief A; Arno's layout): one row per person on the roster with the Default
 * market and the shift, the slots of the tenant's grid (roster.slot_minutes) from the earliest shift start to the latest
 * end of the day as the time axis, in the planner zone (roster.planner_timezone), the assignments as bars (D13).
 *
 * One action (the brief's principle): drag over slots, one row or several, choose an assignment in the dropdown (its
 * colour, code and name; or type CODE or CODE-MARKET) and it applies at once. Delete empties the selection, Esc lets it
 * go. Clicking a bar opens a small dialog with the same two dropdowns, from and to. Keyboard first (Pulse4all-Style 7.8):
 * a click or a drag keeps the focus on the grid (Martin, 26 November 2026); the arrows move a one-slot selection, Shift
 * and an arrow grows it, Enter applies the assignment chosen, Esc clears, a letter opens the dropdown with it. Every write
 * replaces the person-date's blocks (PUT .../assignments) and shows its result at once (the optimistic writes of 24
 * November 2026); a refusal puts the row back and says why. A change to the person's today in a published week is
 * published at once, after a confirmation when other changes would go with it (D8).
 *
 * Above the grid: the Planned hours meter of the week and the day (PlannedMeter). Under it: Working per slot, 0 inside
 * someone's shift so gaps show (hover for each assignment and market), and per person the Planned hours: the work blocks,
 * a shift without blocks whole, never a pause (hover for the split). Staff data only.
 *
 * Since addition 0010a (brief B; Arno's and Kira's artboard 7): every work bar reads CODE · MARKET (the block's market,
 * else the person's Default market), a pause its code; the Assignment dropdown's group Absence paints an absence block
 * (E9: Sick from 11:00, going home early), a Background Blue bar with the absence's name that counts neither as planned
 * nor as working; the market's default reads "Each person's default" (E10: the database writes the person's Default
 * market into the block), and the bar dialog shows the person's market itself.
 */
import { useMemo, useRef, useState, useTransition, type CSSProperties, type KeyboardEvent as ReactKeyboardEvent, type PointerEvent as ReactPointerEvent } from "react";
import { useRouter } from "next/navigation";
import type { Copy, Locale } from "@/lib/copy";
import type { AssignmentBlockInput, AssignmentType, RosterAssignmentsResult } from "@/lib/data";
import {
  absenceKeyOf, assignmentText, barLabel, blockCode, fromMinutes, fromPlannerMinutes, paintBlocks, plannedByKey, plannedMinutes, plannedSummary,
  sameBlocks, slotFigures, slotFloor, toMinutes, toneOf, TONE_CLASS, toPlannerMinutes, type Block, type ParseProblem, type PlannedDay, type PlannerWeek,
} from "@/lib/assignments";
import { fmtDate, fmtMinutes } from "@/lib/time";
import { AssignmentPicker, type Choice } from "./AssignmentPicker";
import { ConfirmDialog } from "./ConfirmDialog";
import { PlannedMeter, type MeterWords } from "./PlannedMeter";
import { Button, Notice } from "./primitives";

/** Width of one slot on screen, px: 15 minutes over a twelve-hour day fit 1280 px with the name columns */
const SLOT_PX = 20;

type Sel = { r0: number; s0: number; r1: number; s1: number };
type RowProblem = ParseProblem | "outside" | "times" | "past" | "failed" | "refused";
type Pending = { userId: string; prev: Block[]; next: Block[]; others: number };
/** A problem with text typed in the Assignment dropdown (not with the selection or the save) */
const typedProblem = (p: RowProblem | null): boolean => p === "unknown" || p === "retired" || p === "market" || p === "pauseMarket" || p === "format";

async function send(path: string, body: unknown): Promise<Response> {
  return fetch(path, { method: "PUT", headers: { "content-type": "application/json", "x-cma-request": "1" }, body: JSON.stringify(body) });
}

export function RosterDay({
  week, date, teamArg, copy, meterWords, locale, onPublishedNow, onChanged, absences = [],
}: {
  week: PlannerWeek;
  date: string;
  /** The team as the API takes it: null for Everyone */
  teamArg: string | null;
  copy: Pick<Copy, "assignmentsDay" | "assignments" | "dayEditor">;
  meterWords: MeterWords;
  locale: Locale;
  /** A write published the week at once (D8): the page reads the header again */
  onPublishedNow: () => void;
  /** A write was saved as a draft change: the header shows a change waiting for Publish */
  onChanged: () => void;
  /** The tenant's absence types (E9): the active ones in the dropdown, every one by name on its bars */
  absences?: readonly { key: string; name: string; isActive: boolean }[];
}) {
  const t = copy.assignmentsDay;
  const router = useRouter();
  const [busy, startTransition] = useTransition();
  // the week read again after a pause runs in its own transition: it is no save, so it neither says Saving nor blocks Apply
  const [, startRefresh] = useTransition();
  /** A read of the week is under way, and the planner changed a row while it was */
  const [refreshing, setRefreshing] = useState(false);
  const [changedDuringRefresh, setChangedDuringRefresh] = useState(false);
  const ctx = week.planner;
  const slot = ctx.slotMinutes;
  const zone = ctx.plannerZone;
  const kinds = useMemo(() => new Map(ctx.types.map((x) => [x.code, x.kind])), [ctx.types]);
  // The examples in the words come from the tenant's own catalog: its first active type and hours market (never a code in copy)
  const exampleCode = ctx.types.find((x) => x.isActive)?.code ?? "";
  const exampleMarket = ctx.hoursMarkets.find((m) => m.isActive)?.code ?? "";
  const example = (text: string) => text.replaceAll("{code}", exampleCode).replaceAll("{market}", exampleMarket);
  const typeOf = useMemo(() => new Map(ctx.types.map((x) => [x.code, x])), [ctx.types]);
  const absenceName = (key: string) => absences.find((a) => a.key === key)?.name ?? null;
  /** E5's refusal in words: the people and dates whose shifts have no assignment yet */
  const refusalText = (list: { userId: string; date: string }[]) => copy.assignments.refusedEmpty.replace("{list}", list.map((x) =>
    `${week.people.find((p) => p.userId === x.userId)?.displayName ?? ""} ${fmtDate(x.date, locale, "compact")}`.trim()).join(", "));
  const activeAbsences = absences.filter((a) => a.isActive);

  // The people of the day with their shift and blocks in minutes of the planner zone's day
  const rows = useMemo(() => week.people.map((p) => {
    const e = week.entries.find((x) => x.userId === p.userId && x.date === date) ?? null;
    const shift = e?.kind === "shift" && e.start && e.end
      ? { start: toPlannerMinutes(date, e.start, p.timeZone, zone) ?? 0, end: toPlannerMinutes(date, e.end, p.timeZone, zone) ?? 0 }
      : null;
    const blocks: Block[] = (week.blocks[`${p.userId}:${date}`] ?? []).map(([code, start, end, market, note]) => ({
      code, market, note,
      start: toPlannerMinutes(date, start, p.timeZone, zone) ?? 0, end: toPlannerMinutes(date, end, p.timeZone, zone) ?? 0,
    }));
    return { person: p, entry: e, shift, blocks };
  }), [week, date, zone]);

  const [blocksOf, setBlocksOf] = useState(() => new Map(rows.map((r) => [r.person.userId, r.blocks])));
  const [answer, setAnswer] = useState(week);
  if (answer !== week) {
    // a new answer of the same week (a refresh after a write): the blocks follow the database, unless the planner changed
    // a row after that read started (the answer would show the plan from before that change until the next read)
    setAnswer(week);
    if (!changedDuringRefresh) setBlocksOf(new Map(rows.map((r) => [r.person.userId, r.blocks])));
    setChangedDuringRefresh(false);
    setRefreshing(false);
  }
  const [problems, setProblems] = useState<Map<string, RowProblem>>(new Map());
  const [saving, setSaving] = useState<Set<string>>(new Set());
  const [notice, setNotice] = useState<string | null>(null);
  const [pending, setPending] = useState<Pending[] | null>(null);

  // The axis: the earliest shift start to the latest end of the day, on the grid; 08:00 to 18:00 without shifts
  const shifts = rows.flatMap((r) => (r.shift ? [r.shift] : []));
  const axisStart = shifts.length ? slotFloor(Math.min(...shifts.map((s) => s.start)), slot) : 8 * 60;
  const axisEnd = shifts.length ? Math.ceil(Math.max(...shifts.map((s) => s.end)) / slot) * slot : 18 * 60;
  const slots = Math.max(1, (axisEnd - axisStart) / slot);
  const px = (min: number) => ((min - axisStart) / slot) * SLOT_PX;

  // ---- selection ----------------------------------------------------------------------------------
  const [sel, setSel] = useState<Sel | null>(null);
  const drag = useRef<{ r: number; s: number; moved: boolean } | null>(null);
  // The assignment chosen in the dropdown (Martin, 26 November 2026): Enter on the grid applies it to the selection
  const [chosen, setChosen] = useState<Choice>({ code: null, market: null });
  const [codeProblem, setCodeProblem] = useState<RowProblem | null>(null);
  const grid = useRef<HTMLDivElement>(null);
  const codeField = useRef<HTMLInputElement>(null);
  const range = (s: Sel) => ({ rA: Math.min(s.r0, s.r1), rZ: Math.max(s.r0, s.r1), sA: Math.min(s.s0, s.s1), sZ: Math.max(s.s0, s.s1) });
  const slotAt = (e: ReactPointerEvent<HTMLDivElement>) => {
    const rect = e.currentTarget.getBoundingClientRect();
    return Math.max(0, Math.min(slots - 1, Math.floor((e.clientX - rect.left) / SLOT_PX)));
  };

  function down(e: ReactPointerEvent<HTMLDivElement>, r: number) {
    if (e.button !== 0) return;
    e.preventDefault();
    const s = slotAt(e);
    drag.current = { r, s, moved: false };
    setSel({ r0: r, s0: s, r1: r, s1: s });
    grid.current?.focus();
  }
  function move(e: ReactPointerEvent<HTMLDivElement>, r: number) {
    if (!drag.current) return;
    const s = slotAt(e);
    if (s !== drag.current.s || r !== drag.current.r) drag.current.moved = true;
    // the same object while the pointer stays in its slot: no render per pointer move
    setSel((x) => (x && (x.r1 !== r || x.s1 !== s) ? { ...x, r1: r, s1: s } : x));
  }
  function up(e: ReactPointerEvent<HTMLDivElement>, r: number) {
    const d = drag.current;
    drag.current = null;
    // the focus stays on the grid: the arrows, Shift and an arrow, Enter and Esc go on working (Martin, 26 November 2026)
    if (!d || d.moved) { grid.current?.focus(); return; }
    // A click on a bar opens its dialog; a click on an empty slot keeps the one-slot selection
    const min = axisStart + slotAt(e) * slot;
    const row = rows[r]!;
    const b = (blocksOf.get(row.person.userId) ?? []).find((x) => x.start <= min && min < x.end);
    if (b) { setSel(null); openDialog(r, b); } else grid.current?.focus();
  }

  // ---- writes -------------------------------------------------------------------------------------
  /** Blocks in the planner zone's minutes back to the person's local hh:mm; null when one falls outside the person's day */
  function toInput(userId: string, blocks: Block[]): AssignmentBlockInput[] | null {
    const p = week.people.find((x) => x.userId === userId)!;
    const out: AssignmentBlockInput[] = [];
    for (const b of blocks) {
      const start = fromPlannerMinutes(b.start, date, p.timeZone, zone);
      const end = fromPlannerMinutes(b.end, date, p.timeZone, zone);
      if (!start || !end || end <= start) return null;
      const absence = absenceKeyOf(b.code);
      // an absence block (E9) is written as {absence}, never with a market
      out.push(absence !== null ? { code: "", absence, start, end, hoursMarket: null, note: b.note } : { code: b.code, start, end, hoursMarket: b.market, note: b.note });
    }
    return out;
  }

  function write(changes: { userId: string; next: Block[] }[], publishOthers = false) {
    const real = changes.filter((c) => !sameBlocks(blocksOf.get(c.userId) ?? [], c.next));
    if (real.length === 0) return;
    const prevOf = new Map(real.map((c) => [c.userId, blocksOf.get(c.userId) ?? []]));
    if (refreshing) setChangedDuringRefresh(true);
    // the result shows at once; a refusal puts the row back
    setBlocksOf((m) => { const n = new Map(m); for (const c of real) n.set(c.userId, c.next); return n; });
    setSaving((x) => new Set([...x, ...real.map((c) => c.userId)]));
    setNotice(null);
    startTransition(async () => {
      const confirm: Pending[] = [];
      let published = false;
      for (const c of real) {
        const blocks = toInput(c.userId, c.next);
        const fail = (p: RowProblem) => {
          setProblems((m) => new Map(m).set(c.userId, p));
          setBlocksOf((m) => new Map(m).set(c.userId, prevOf.get(c.userId)!));
        };
        if (!blocks) { fail("times"); continue; }
        const res = await send(`/api/v1/roster/weeks/${week.header.weekStart}/assignments`, { team: teamArg, userId: c.userId, date, blocks, publishOthers });
        if (res.status === 409) {
          // E5 (addition 0010a): today publishes at once, and a shift of the week has no block yet: nothing was written
          const body = (await res.json().catch(() => null)) as { data?: { status?: string; emptyShifts?: { userId: string; date: string }[] } } | null;
          if (body?.data?.status === "refused") { fail("refused"); setNotice(refusalText(body.data.emptyShifts ?? [])); continue; }
          fail("failed");
          continue;
        }
        if (!res.ok) {
          const err = (await res.json().catch(() => null)) as { error?: { message?: string } } | null;
          const m = err?.error?.message ?? "";
          fail(/past/.test(m) ? "past" : /outside the shift|grid|overlap|ends after/.test(m) ? "times" : /is a pause/.test(m) ? "pauseMarket" : /hours market|no market/.test(m) ? "market" : /no longer in use/.test(m) ? "retired" : /does not exist/.test(m) ? "unknown" : "failed");
          continue;
        }
        const r = ((await res.json()) as { data: RosterAssignmentsResult }).data;
        if (r.status === "refused") { fail("refused"); setNotice(refusalText(r.emptyShifts)); continue; }
        if (r.status === "confirm") {
          // nothing was written: the row shows the database's blocks again until the planner confirms (D8)
          confirm.push({ userId: c.userId, prev: prevOf.get(c.userId)!, next: c.next, others: r.otherChanges });
          setBlocksOf((m) => new Map(m).set(c.userId, prevOf.get(c.userId)!));
          continue;
        }
        setProblems((m) => { const n = new Map(m); n.delete(c.userId); return n; });
        // the row as the database answered it (its own blocks, in the planner zone's minutes)
        const p = week.people.find((x) => x.userId === c.userId)!;
        setBlocksOf((m) => new Map(m).set(c.userId, r.blocks.map((b) => ({
          code: blockCode(b), market: b.hoursMarket, note: b.note,
          start: toPlannerMinutes(date, b.start, p.timeZone, zone) ?? 0, end: toPlannerMinutes(date, b.end, p.timeZone, zone) ?? 0,
        }))));
        published ||= r.published;
      }
      setSaving(new Set());
      if (confirm.length > 0) {
        // no read of the week while the planner decides: it would show the rows as the database holds them mid-question
        if (refreshTimer.current) { clearTimeout(refreshTimer.current); refreshTimer.current = null; }
        setPending(confirm);
        return;
      }
      if (published) { setNotice(copy.assignments.publishedNow); onPublishedNow(); } else { onChanged(); refreshSoon(); }
    });
  }

  function confirmPublish() {
    const p = pending ?? [];
    setPending(null);
    write(p.map((x) => ({ userId: x.userId, next: x.next })), true);
  }
  function cancelPublish() {
    // the rows already show the database's blocks again (write put them back when it was asked)
    setPending(null);
  }

  // The week read again once the planner pauses (night N07, D4), never one read per write
  const refreshTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  function refreshSoon() {
    if (refreshTimer.current) clearTimeout(refreshTimer.current);
    refreshTimer.current = setTimeout(() => { refreshTimer.current = null; setRefreshing(true); startRefresh(() => router.refresh()); }, 1500);
  }

  /** Paints the selection with an assignment type and market, or empties it (null) */
  function paint(what: { code: string; market: string | null } | null) {
    if (!sel) return;
    const { rA, rZ, sA, sZ } = range(sel);
    // a pause has no market (0009zz), nor an absence block (E9)
    if (what && (kinds.get(what.code) === "pause" || absenceKeyOf(what.code) !== null)) what = { code: what.code, market: null };
    const from = axisStart + sA * slot;
    const to = axisStart + (sZ + 1) * slot;
    const changes: { userId: string; next: Block[] }[] = [];
    let outside = true;
    for (let r = rA; r <= rZ; r++) {
      const row = rows[r]!;
      if (!row.shift || to <= row.shift.start || from >= row.shift.end) continue;
      outside = false;
      changes.push({ userId: row.person.userId, next: paintBlocks(blocksOf.get(row.person.userId) ?? [], from, to, what, row.shift) });
    }
    if (outside) { setCodeProblem("outside"); return; }
    setCodeProblem(null);
    write(changes);
    grid.current?.focus();
  }

  /** Enter on the grid or Apply: the assignment chosen in the dropdown; without one, the dropdown takes the keyboard */
  function applyChosen() {
    if (!sel) return;
    // typed text that names no type waits to be put right: the earlier choice is never painted in its place
    if (typedProblem(codeProblem)) { codeField.current?.focus(); return; }
    if (!chosen.code) { setCodeProblem("empty"); codeField.current?.focus(); return; }
    paint({ code: chosen.code, market: chosen.market });
  }

  function onGridKey(e: ReactKeyboardEvent<HTMLDivElement>) {
    if (e.target !== e.currentTarget) return;
    const arrows: Record<string, [number, number]> = { ArrowLeft: [0, -1], ArrowRight: [0, 1], ArrowUp: [-1, 0], ArrowDown: [1, 0] };
    const step = arrows[e.key];
    if (step) {
      e.preventDefault();
      const first = rows.findIndex((r) => r.shift);
      const base = sel ?? { r0: Math.max(0, first), s0: rows[first]?.shift ? Math.max(0, (rows[first]!.shift!.start - axisStart) / slot) : 0, r1: Math.max(0, first), s1: 0 };
      const r1 = Math.max(0, Math.min(rows.length - 1, (sel ? base.r1 : base.r0) + step[0]));
      const s1 = Math.max(0, Math.min(slots - 1, (sel ? base.s1 : base.s0) + step[1]));
      setSel(e.shiftKey && sel ? { ...sel, r1, s1 } : { r0: r1, s0: s1, r1, s1 });
      return;
    }
    if (!sel) return;
    if (e.key === "Enter") { e.preventDefault(); applyChosen(); return; }
    if (e.key === "Delete" || e.key === "Backspace") { e.preventDefault(); paint(null); return; }
    if (e.key === "Escape") { e.preventDefault(); setSel(null); setCodeProblem(null); return; }
    if (/^[a-zA-Z0-9]$/.test(e.key) && !e.ctrlKey && !e.metaKey && !e.altKey) {
      // the dropdown takes the letter (not prevented: the key lands in the field, which filters the list on it); the page's
      // shortcuts leave a role="grid" alone (useKeyboardShortcuts), so L on the grid is a code, not Log out
      codeField.current?.focus();
    }
  }

  // ---- the bar's dialog -----------------------------------------------------------------------------
  const [dialog, setDialog] = useState<{ r: number; block: Block; code: string; from: string; to: string; market: string | null } | null>(null);
  const [dialogProblem, setDialogProblem] = useState<RowProblem | null>(null);
  function openDialog(r: number, b: Block) {
    setDialogProblem(null);
    setDialog({ r, block: b, code: b.code, from: fromMinutes(b.start), to: fromMinutes(b.end), market: b.market });
  }
  function saveDialog(remove: boolean) {
    if (!dialog) return;
    if (!remove && typedProblem(dialogProblem)) return;   // the dialog keeps saying why; the bar's earlier type is not saved
    const row = rows[dialog.r]!;
    if (!row.shift) return;
    const without = paintBlocks(blocksOf.get(row.person.userId) ?? [], dialog.block.start, dialog.block.end, null, row.shift);
    if (remove) { setDialog(null); write([{ userId: row.person.userId, next: without }]); return; }
    const type = ctx.types.find((x) => x.code === dialog.code);
    const isAbsence = absenceKeyOf(dialog.code) !== null && absences.some((a) => blockCode({ code: null, absence: a.key }) === dialog.code);
    if (!type && !isAbsence) { setDialogProblem("unknown"); return; }
    const parsed = { code: dialog.code, market: !type || type.kind === "pause" ? null : dialog.market };
    const okTime = /^([01]\d|2[0-3]):[0-5]\d$|^24:00$/;
    if (!okTime.test(dialog.from) || !okTime.test(dialog.to)) { setDialogProblem("times"); return; }
    const from = toMinutes(dialog.from);
    const to = toMinutes(dialog.to);
    if (to <= from || from % slot !== 0 || to % slot !== 0 || from < row.shift.start || to > row.shift.end) { setDialogProblem("times"); return; }
    const next = paintBlocks(without, from, to, parsed, row.shift).map((b) =>
      b.start === from && b.end === to && b.code === parsed.code ? { ...b, note: dialog.block.note } : b);
    setDialog(null);
    write([{ userId: row.person.userId, next }]);
  }

  // ---- figures (D12) --------------------------------------------------------------------------------
  // Computed once per change of the blocks, never per pointer move or arrow key: a selection changes none of them
  const people = useMemo(() => rows.map((r) => ({ userId: r.person.userId, defaultMarket: r.person.defaultHoursMarket, blocks: blocksOf.get(r.person.userId) ?? [] })), [rows, blocksOf]);
  const figures = useMemo(() => slotFigures(people, kinds, slot, axisStart, axisEnd), [people, kinds, slot, axisStart, axisEnd]);
  // Working shows 0 inside someone's shift, so a gap shows; outside every shift it stays empty (Martin, 26 November 2026)
  const inShift = useMemo(() => new Set(figures.filter((f) => rows.some((r) => r.shift && r.shift.start <= f.start && f.start < r.shift.end)).map((f) => f.start)), [figures, rows]);
  // The meter (point 9): this date from the rows on screen (with their unsaved results), the week's other dates from the
  // week as read (once per week and date); each person-date in the person's own minutes (a duration does not depend on
  // the axis)
  const dayDays = useMemo((): PlannedDay[] => rows.map((r) => ({
    userId: r.person.userId, date, defaultMarket: r.person.defaultHoursMarket, shift: r.shift, blocks: blocksOf.get(r.person.userId) ?? [],
  })), [rows, blocksOf, date]);
  const otherDays = useMemo((): PlannedDay[] => {
    const byId = new Map(week.people.map((p) => [p.userId, p]));
    return week.entries.filter((e) => e.date !== date && byId.has(e.userId)).map((e) => ({
      userId: e.userId, date: e.date, defaultMarket: byId.get(e.userId)?.defaultHoursMarket ?? null,
      shift: e.kind === "shift" && e.start && e.end ? { start: toMinutes(e.start), end: toMinutes(e.end) } : null,
      blocks: (week.blocks[`${e.userId}:${e.date}`] ?? []).map(([code, start, end, market, note]) => ({ code, start: toMinutes(start), end: toMinutes(end), market, note })),
    }));
  }, [week, date]);
  const daySummary = useMemo(() => plannedSummary(dayDays, kinds), [dayDays, kinds]);
  const weekSummary = useMemo(() => plannedSummary([...dayDays, ...otherDays], kinds), [dayDays, otherDays, kinds]);
  const keyLabel = (k: string) => { const [c, m] = k.split("/"); return m ? `${c} ${m}` : c ?? ""; };
  const splitText = (m: Map<string, number>) => [...m].sort((a, b) => a[0].localeCompare(b[0]))
    .map(([k, v]) => `${keyLabel(k)} ${fmtMinutes(v)}${kinds.get(k.split("/")[0]!) === "pause" ? ` (${meterWords.pauses})` : ""}`).join("\n");
  const problemText: Record<RowProblem, string> = {
    empty: t.problemEmpty, unknown: t.problemUnknown, retired: t.problemRetired, market: example(t.problemMarket), format: example(t.problemFormat),
    pauseMarket: t.problemPauseMarket, outside: t.problemOutside, times: t.problemTimes, past: t.problemPast, failed: t.problemFailed,
    refused: t.problemRefused,
  };
  const hours: number[] = [];
  for (let h = Math.ceil(axisStart / 60) * 60; h < axisEnd; h += 60) hours.push(h);
  const nameCols = "w-56 shrink-0";
  const firstHour = (Math.ceil(axisStart / 60) * 60 - axisStart) / slot * SLOT_PX;
  const hourLines: CSSProperties = {
    backgroundImage: "linear-gradient(to right, var(--color-p4a-border) 1px, transparent 1px)",
    backgroundSize: `${(60 / slot) * SLOT_PX}px 100%`, backgroundPosition: `${firstHour}px 0`,
  };
  // A dotted line at every slot boundary (Martin, 26 November 2026): the border colour, lighter than the solid hour lines
  // (60 % and dotted), one background per row; the mask cuts the line into 2 px dots
  const slotLines: CSSProperties = {
    backgroundImage: "linear-gradient(to right, color-mix(in srgb, var(--color-p4a-border) 60%, transparent) 1px, transparent 1px)",
    backgroundSize: `${SLOT_PX}px 100%`,
    maskImage: "repeating-linear-gradient(to bottom, #000 0 2px, transparent 2px 4px)",
    WebkitMaskImage: "repeating-linear-gradient(to bottom, #000 0 2px, transparent 2px 4px)",
  };

  const othersPending = Math.max(0, ...(pending ?? []).map((p) => p.others));
  const selRange = sel ? range(sel) : null;
  const barText = (type: AssignmentType | undefined, b: Block, defaultMarket: string | null) =>
    `${type?.name ?? absenceName(absenceKeyOf(b.code) ?? "") ?? b.code}${type?.kind === "work" && (b.market ?? defaultMarket) ? ` · ${b.market ?? defaultMarket}` : ""} · ${fromMinutes(b.start)}–${fromMinutes(b.end)}`;
  const pickerLabels = (eachDefault: string) => ({
    assignment: t.codeLabel, market: t.market, eachDefault, pauseNoMarket: t.pauseNoMarket, absenceNoMarket: t.absenceNoMarket,
    absenceGroup: t.absenceGroup, placeholder: example(t.codeHint), noMatch: t.noMatch,
  });

  return (
    <div className="flex flex-col gap-4" data-testid="roster-day">
      <PlannedMeter week={weekSummary} day={daySummary} types={ctx.types} words={meterWords} />
      <p className="max-w-4xl text-small text-p4a-muted">{example(t.dayIntro)}</p>
      <div className="flex flex-wrap items-end gap-3">
        <AssignmentPicker
          types={ctx.types}
          markets={ctx.hoursMarkets}
          absences={activeAbsences}
          value={chosen}
          inputRef={codeField}
          invalid={codeProblem !== null}
          onChange={setChosen}
          // choosing a type (or its market) with slots selected applies it at once (Martin, 26 November 2026)
          onChoose={(v) => { if (sel) paint(v); }}
          onEscape={() => grid.current?.focus()}
          onProblem={(p) => setCodeProblem(p)}
          labels={pickerLabels(t.eachDefault)}
        />
        <Button variant="outlined" disabled={!sel || !chosen.code || busy} onClick={applyChosen}>{t.apply}</Button>
        {codeProblem ? <p className="pb-2 text-caption text-p4a-error" role="alert" data-testid="assignment-problem">{problemText[codeProblem]}</p> : null}
        {busy || saving.size > 0 ? <p className="pb-2 text-caption text-p4a-grey">{t.saving}</p> : null}
      </div>
      {notice ? <Notice tone="info">{notice}</Notice> : null}

      {shifts.length === 0 ? <p className="text-body text-p4a-muted">{t.noShiftsToday}</p> : null}
      <div className="overflow-x-auto rounded-card border border-p4a-border bg-white">
        <div
          ref={grid}
          tabIndex={0}
          role="grid"
          aria-label={`${copy.assignments.viewDay} ${fmtDate(date, locale, "compact")}`}
          onKeyDown={onGridKey}
          onPointerUp={() => { if (drag.current) { drag.current = null; grid.current?.focus(); } }}
          className="inline-block min-w-full select-none text-small focus:outline-2 focus:outline-p4a-lightblue"
          data-testid="roster-day-grid"
        >
          <div className="flex h-10 items-center border-b border-p4a-border bg-p4a-bgblue font-semibold text-p4a-heading">
            <div className={`${nameCols} px-2`}>{t.person}</div>
            <div className="w-24 shrink-0 px-2">{t.defaultMarket}</div>
            <div className="w-28 shrink-0 px-2">{t.shift}</div>
            <div className="relative h-10 shrink-0" style={{ width: slots * SLOT_PX }}>
              {hours.map((h) => (
                <span key={h} className="tabular absolute top-3 -translate-x-1/2 text-caption" style={{ left: px(h) }}>{fromMinutes(h)}</span>
              ))}
            </div>
            <div className="w-20 shrink-0 px-2 text-right" title={t.plannedHint}>{t.planned}</div>
          </div>
          {rows.map((row, r) => {
            const blocks = blocksOf.get(row.person.userId) ?? [];
            const planned = plannedByKey(blocks, row.person.defaultHoursMarket, kinds);
            const total = plannedMinutes(row.shift, blocks, kinds);
            const problem = problems.get(row.person.userId);
            return (
              <div key={row.person.userId} className="flex min-h-10 items-center border-b border-p4a-border odd:bg-p4a-offwhite" data-person={row.person.userId}>
                <div className={`${nameCols} px-2 py-1`}>
                  <div className="font-semibold text-body">{row.person.displayName}</div>
                  {problem ? <div className="text-caption text-p4a-error">{problemText[problem]}</div> : null}
                </div>
                <div className="w-24 shrink-0 px-2">{row.person.defaultHoursMarket ?? t.noMarket}</div>
                <div className="tabular w-28 shrink-0 px-2">
                  {row.entry?.kind === "shift" ? `${row.entry.start?.slice(0, 5)}–${row.entry.end?.slice(0, 5)}` : row.entry?.absenceName ?? t.noShift}
                </div>
                <div
                  className="relative h-8 shrink-0 cursor-crosshair"
                  style={{ width: slots * SLOT_PX }}
                  onPointerDown={(e) => down(e, r)}
                  onPointerMove={(e) => move(e, r)}
                  onPointerEnter={(e) => move(e, r)}
                  onPointerUp={(e) => up(e, r)}
                >
                  {/* outside the shift: the neutral surface; inside: the page's own background (an empty slot, D13) */}
                  <div className="absolute inset-0 bg-p4a-neutral-surface" />
                  {row.shift ? <div className="absolute inset-y-0 bg-white" style={{ left: px(row.shift.start), width: px(row.shift.end) - px(row.shift.start) }} /> : null}
                  {/* the slot lines dotted and the hour lines solid, each one background per row (not an element per line) */}
                  <div className="pointer-events-none absolute inset-0" style={slotLines} />
                  <div className="pointer-events-none absolute inset-0" style={hourLines} />
                  {row.entry?.kind === "absence" ? (
                    <div className={`absolute inset-y-1 flex items-center rounded-button px-2 font-semibold ${TONE_CLASS.absence}`} style={{ left: 0, right: 0 }}>{row.entry.absenceName}</div>
                  ) : null}
                  {blocks.map((b) => {
                    const type = typeOf.get(b.code);
                    const absent = absenceKeyOf(b.code) !== null;
                    const tone = absent ? "absence" : type ? toneOf(type) : "productive";
                    // E10: every work bar names its market, CODE · MARKET; a pause its code; an absence block its name
                    const label = barLabel(b, row.person.defaultHoursMarket, kinds, absenceName);
                    return (
                      <div
                        key={`${b.start}-${b.code}`}
                        // the type's name in words on hover (D13), built then: the page stays within its budget
                        onPointerEnter={(e) => { e.currentTarget.title = barText(type, b, row.person.defaultHoursMarket); }}
                        aria-label={`${absent ? label : assignmentText({ code: b.code, market: kinds.get(b.code) === "work" ? b.market ?? row.person.defaultHoursMarket : null })} ${fromMinutes(b.start)}–${fromMinutes(b.end)}`}
                        className={`absolute inset-y-1 flex items-center gap-1 overflow-hidden whitespace-nowrap rounded-button px-1 text-caption font-semibold ${TONE_CLASS[tone]}`}
                        style={{ left: px(b.start), width: Math.max(4, px(b.end) - px(b.start)) }}
                      >
                        <span>{label}</span>
                      </div>
                    );
                  })}
                  {selRange && r >= selRange.rA && r <= selRange.rZ ? (
                    <div className="pointer-events-none absolute inset-y-0 border-2 border-p4a-lightblue bg-p4a-lightblue/30"
                      style={{ left: selRange.sA * SLOT_PX, width: (selRange.sZ - selRange.sA + 1) * SLOT_PX }} />
                  ) : null}
                </div>
                <div className="tabular w-20 shrink-0 px-2 text-right" onPointerEnter={(e) => { e.currentTarget.title = splitText(planned); }}>{row.shift ? fmtMinutes(total) : ""}</div>
              </div>
            );
          })}
          <div className="flex h-10 items-center bg-p4a-bgblue font-semibold text-p4a-heading" data-testid="roster-day-coverage">
            <div className={`${nameCols} px-2`} title={t.workingHint}>{t.working}</div>
            <div className="w-24 shrink-0" />
            <div className="w-28 shrink-0" />
            <div className="relative flex h-10 shrink-0" style={{ width: slots * SLOT_PX }}>
              {figures.map((f) => (
                <div key={f.start} className="tabular flex h-10 shrink-0 items-center justify-center text-caption" style={{ width: SLOT_PX }}
                  onPointerEnter={(e) => { e.currentTarget.title = `${fromMinutes(f.start)}\n${[...f.byKey].sort((a, b) => a[0].localeCompare(b[0])).map(([k, n]) => `${keyLabel(k)}: ${n}`).join("\n")}`; }}>
                  {f.working > 0 || inShift.has(f.start) ? f.working : ""}
                </div>
              ))}
            </div>
            <div className="w-20 shrink-0" />
          </div>
        </div>
      </div>

      <ConfirmDialog
        open={pending !== null}
        title={copy.assignments.confirmTodayTitle}
        confirmLabel={copy.assignments.confirmTodayButton}
        cancelLabel={copy.dayEditor.cancel}
        onConfirm={confirmPublish}
        onCancel={cancelPublish}
        busy={busy}
      >
        {othersPending === 1 ? copy.assignments.confirmTodayOne : copy.assignments.confirmToday.replace("{n}", String(othersPending))}
      </ConfirmDialog>

      <ConfirmDialog
        open={dialog !== null}
        title={t.dialogTitle}
        confirmLabel={t.save}
        cancelLabel={copy.dayEditor.cancel}
        onConfirm={() => saveDialog(false)}
        onCancel={() => setDialog(null)}
        busy={busy}
      >
        {dialog ? (
          <div className="flex flex-col gap-3" data-testid="assignment-dialog">
            <AssignmentPicker
              types={ctx.types.filter((x) => x.isActive || x.code === dialog.code).map((x) => (x.code === dialog.code ? { ...x, isActive: true } : x))}
              absences={absences.filter((a) => a.isActive || blockCode({ code: null, absence: a.key }) === dialog.code)}
              markets={ctx.hoursMarkets}
              value={{ code: dialog.code, market: dialog.market }}
              onChange={(v) => setDialog({ ...dialog, code: v.code ?? dialog.code, market: v.market })}
              onChoose={() => undefined}
              onProblem={(p) => setDialogProblem(p)}
              // the bar dialog shows the person's market itself (E10): its empty choice names their Default market
              labels={pickerLabels(rows[dialog.r]?.person.defaultHoursMarket
                ? t.personDefault.replace("{market}", rows[dialog.r]!.person.defaultHoursMarket!) : t.eachDefault)}
              testId="assignment-dialog-code"
              inline
            />
            <div className="grid grid-cols-2 gap-3">
              <label className="flex flex-col gap-2 text-small font-semibold">
                {t.from}
                <input value={dialog.from} maxLength={5} onChange={(e) => setDialog({ ...dialog, from: e.target.value })}
                  className="tabular h-10 rounded-input border border-p4a-border bg-white px-2 font-normal text-body" />
              </label>
              <label className="flex flex-col gap-2 text-small font-semibold">
                {t.to}
                <input value={dialog.to} maxLength={5} onChange={(e) => setDialog({ ...dialog, to: e.target.value })}
                  className="tabular h-10 rounded-input border border-p4a-border bg-white px-2 font-normal text-body" />
              </label>
            </div>
            {dialogProblem ? <p className="text-caption text-p4a-error">{problemText[dialogProblem]}</p> : null}
            <div><Button variant="destructive" size="sm" onClick={() => saveDialog(true)}>{t.remove}</Button></div>
          </div>
        ) : null}
      </ConfirmDialog>
    </div>
  );
}
