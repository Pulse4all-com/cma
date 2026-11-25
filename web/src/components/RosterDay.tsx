"use client";

/**
 * The planner's Day view (addition 0009zw, brief A; Arno's layout): one row per person on the roster with the Default
 * market and the shift, the slots of the tenant's grid (roster.slot_minutes) from the earliest shift start to the latest
 * end of the day as the time axis, in the planner zone (roster.planner_timezone), the assignments as bars (D13).
 *
 * One action (the brief's principle): drag over slots, one row or several, type a code with an optional -MARKET, Enter.
 * Delete empties the selection, Esc lets it go. Clicking a bar opens a small dialog: code, from, to, market. Keyboard
 * first (Pulse4all-Style 7.8): the grid takes focus; the arrows move a one-slot selection, Shift and an arrow grows it,
 * a letter starts the code. Every write replaces the person-date's blocks (PUT .../assignments) and shows its result at
 * once (the optimistic writes of 24 November 2026); a refusal puts the row back and says why. A change to the person's
 * today in a published week is published at once, after a confirmation when other changes would go with it (D8).
 *
 * Under the grid: Working per slot (hover for each assignment and market), per person the Planned hours (hover for the
 * split), and the planned hours per assignment and hours market for the day and the week (D12). Staff data only.
 */
import { useMemo, useRef, useState, useTransition, type KeyboardEvent as ReactKeyboardEvent, type PointerEvent as ReactPointerEvent } from "react";
import { useRouter } from "next/navigation";
import type { Copy, Locale } from "@/lib/copy";
import type { AssignmentBlockInput, AssignmentType, RosterAssignmentsResult } from "@/lib/data";
import {
  addFigures, assignmentText, figureKey, fromMinutes, fromPlannerMinutes, paintBlocks, parseAssignment, plannedByKey, sameBlocks, slotFigures,
  slotFloor, toMinutes, toneOf, TONE_CLASS, toPlannerMinutes, type Block, type ParseProblem, type PlannerWeek,
} from "@/lib/assignments";
import { fmtDate, fmtMinutes } from "@/lib/time";
import { ConfirmDialog } from "./ConfirmDialog";
import { Button, Notice } from "./primitives";

/** Width of one slot on screen, px: 15 minutes over a twelve-hour day fit 1280 px with the name columns */
const SLOT_PX = 20;

type Sel = { r0: number; s0: number; r1: number; s1: number };
type RowProblem = ParseProblem | "outside" | "times" | "past" | "failed";
type Pending = { userId: string; prev: Block[]; next: Block[]; others: number };

async function send(path: string, body: unknown): Promise<Response> {
  return fetch(path, { method: "PUT", headers: { "content-type": "application/json", "x-cma-request": "1" }, body: JSON.stringify(body) });
}

export function RosterDay({
  week, date, teamArg, copy, locale, onPublishedNow,
}: {
  week: PlannerWeek;
  date: string;
  /** The team as the API takes it: null for Everyone */
  teamArg: string | null;
  copy: Pick<Copy, "assignmentsDay" | "assignments" | "dayEditor">;
  locale: Locale;
  /** A write published the week at once (D8): the page reads the header again */
  onPublishedNow: () => void;
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
  const [code, setCode] = useState("");
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
    if (!d || d.moved) { codeField.current?.focus(); return; }
    // A click on a bar opens its dialog; a click on an empty slot keeps the one-slot selection
    const min = axisStart + slotAt(e) * slot;
    const row = rows[r]!;
    const b = (blocksOf.get(row.person.userId) ?? []).find((x) => x.start <= min && min < x.end);
    if (b) { setSel(null); openDialog(r, b); } else codeField.current?.focus();
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
      out.push({ code: b.code, start, end, hoursMarket: b.market, note: b.note });
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
        if (!res.ok) {
          const err = (await res.json().catch(() => null)) as { error?: { message?: string } } | null;
          const m = err?.error?.message ?? "";
          fail(/past/.test(m) ? "past" : /outside the shift|grid|overlap|ends after/.test(m) ? "times" : /hours market|no market/.test(m) ? "market" : /no longer in use/.test(m) ? "retired" : /does not exist/.test(m) ? "unknown" : "failed");
          continue;
        }
        const r = ((await res.json()) as { data: RosterAssignmentsResult }).data;
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
          code: b.code, market: b.hoursMarket, note: b.note,
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
      if (published) { setNotice(t.publishedNow); onPublishedNow(); } else refreshSoon();
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

  /** Paints the selection with the typed code, or empties it (null) */
  function paint(text: string | null) {
    if (!sel) return;
    const { rA, rZ, sA, sZ } = range(sel);
    let what: { code: string; market: string | null } | null = null;
    if (text !== null) {
      const parsed = parseAssignment(text, ctx.types, ctx.hoursMarkets);
      if ("problem" in parsed) { setCodeProblem(parsed.problem); return; }
      what = parsed;
    }
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
    setCode("");
    write(changes);
    grid.current?.focus();
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
    if (e.key === "Delete" || e.key === "Backspace") { e.preventDefault(); paint(null); return; }
    if (e.key === "Escape") { e.preventDefault(); setSel(null); setCode(""); setCodeProblem(null); return; }
    if (/^[a-zA-Z0-9]$/.test(e.key) && !e.ctrlKey && !e.metaKey && !e.altKey) {
      e.preventDefault();
      setCode(e.key.toUpperCase());
      codeField.current?.focus();
    }
  }

  // ---- the bar's dialog -----------------------------------------------------------------------------
  const [dialog, setDialog] = useState<{ r: number; block: Block; code: string; from: string; to: string; market: string } | null>(null);
  const [dialogProblem, setDialogProblem] = useState<RowProblem | null>(null);
  function openDialog(r: number, b: Block) {
    setDialogProblem(null);
    setDialog({ r, block: b, code: b.code, from: fromMinutes(b.start), to: fromMinutes(b.end), market: b.market ?? "" });
  }
  function saveDialog(remove: boolean) {
    if (!dialog) return;
    const row = rows[dialog.r]!;
    if (!row.shift) return;
    const without = paintBlocks(blocksOf.get(row.person.userId) ?? [], dialog.block.start, dialog.block.end, null, row.shift);
    if (remove) { setDialog(null); write([{ userId: row.person.userId, next: without }]); return; }
    const parsed = parseAssignment(dialog.market ? `${dialog.code}-${dialog.market}` : dialog.code, ctx.types, ctx.hoursMarkets);
    if ("problem" in parsed) { setDialogProblem(parsed.problem); return; }
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
  const people = rows.map((r) => ({ userId: r.person.userId, defaultMarket: r.person.defaultHoursMarket, blocks: blocksOf.get(r.person.userId) ?? [] }));
  const figures = slotFigures(people, kinds, slot, axisStart, axisEnd);
  const dayTotals = new Map<string, number>();
  for (const p of people) addFigures(dayTotals, plannedByKey(p.blocks, p.defaultMarket));
  const weekTotals = new Map<string, number>();
  for (const [key, list] of Object.entries(week.blocks)) {
    const [userId, d] = key.split(":");
    if (d === date) continue;
    const def = week.people.find((p) => p.userId === userId)?.defaultHoursMarket ?? null;
    for (const [code, start, end, market] of list) {
      const k = figureKey(code, market ?? def);
      weekTotals.set(k, (weekTotals.get(k) ?? 0) + toMinutes(end) - toMinutes(start));
    }
  }
  addFigures(weekTotals, dayTotals);
  const keyLabel = (k: string) => { const [c, m] = k.split("/"); return m ? `${c} ${m}` : `${c} · ${t.ownMarket}`; };
  const splitText = (m: Map<string, number>) => [...m].sort((a, b) => a[0].localeCompare(b[0])).map(([k, v]) => `${keyLabel(k)} ${fmtMinutes(v)}`).join("\n");
  const problemText: Record<RowProblem, string> = {
    empty: t.problemEmpty, unknown: t.problemUnknown, retired: t.problemRetired, market: example(t.problemMarket), format: example(t.problemFormat),
    outside: t.problemOutside, times: t.problemTimes, past: t.problemPast, failed: t.problemFailed,
  };
  const hours: number[] = [];
  for (let h = Math.ceil(axisStart / 60) * 60; h < axisEnd; h += 60) hours.push(h);
  const nameCols = "w-56 shrink-0";
  const firstHour = (Math.ceil(axisStart / 60) * 60 - axisStart) / slot * SLOT_PX;
  const hourLines = {
    backgroundImage: "linear-gradient(to right, var(--color-p4a-border) 1px, transparent 1px)",
    backgroundSize: `${(60 / slot) * SLOT_PX}px 100%`, backgroundPosition: `${firstHour}px 0`,
  };
  const othersPending = Math.max(0, ...(pending ?? []).map((p) => p.others));
  const selRange = sel ? range(sel) : null;
  const barText = (type: AssignmentType | undefined, b: Block, defaultMarket: string | null) =>
    `${type?.name ?? b.code}${b.market ? ` · ${b.market}` : ""} · ${fromMinutes(b.start)}–${fromMinutes(b.end)}${defaultMarket && !b.market ? ` · ${t.ownMarket}` : ""}`;

  return (
    <div className="flex flex-col gap-4" data-testid="roster-day">
      <p className="max-w-4xl text-small text-p4a-muted">{example(t.dayIntro)}</p>
      <div className="flex items-end gap-3">
        <label className="flex flex-col gap-2 text-small font-semibold">
          {t.codeLabel}
          <input
            ref={codeField}
            value={code}
            maxLength={9}
            placeholder={example(t.codeHint)}
            disabled={!sel}
            data-testid="assignment-code"
            onChange={(e) => { setCode(e.target.value.toUpperCase()); setCodeProblem(null); }}
            onKeyDown={(e) => {
              if (e.key === "Enter") { e.preventDefault(); paint(code); }
              if (e.key === "Escape") { e.preventDefault(); setCode(""); setCodeProblem(null); grid.current?.focus(); }
            }}
            className={`h-10 w-40 rounded-input border bg-white px-3 font-normal uppercase text-body text-p4a-body focus:border-p4a-deepblue disabled:bg-p4a-sand ${codeProblem ? "border-p4a-error" : "border-p4a-border"}`}
          />
        </label>
        <Button variant="outlined" disabled={!sel || busy} onClick={() => paint(code)}>{t.apply}</Button>
        {codeProblem ? <p className="pb-2 text-caption text-p4a-error">{problemText[codeProblem]}</p> : null}
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
          onPointerUp={() => { if (drag.current) { drag.current = null; codeField.current?.focus(); } }}
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
            const planned = plannedByKey(blocks, row.person.defaultHoursMarket);
            const total = [...planned.values()].reduce((a, b) => a + b, 0);
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
                  {/* the hour lines, one background per row (not a line element per hour and row) */}
                  <div className="pointer-events-none absolute inset-0" style={hourLines} />
                  {row.shift ? <div className="absolute inset-y-0 bg-white" style={{ left: px(row.shift.start), width: px(row.shift.end) - px(row.shift.start) }} /> : null}
                  {row.entry?.kind === "absence" ? (
                    <div className={`absolute inset-y-1 flex items-center rounded-button px-2 font-semibold ${TONE_CLASS.absence}`} style={{ left: 0, right: 0 }}>{row.entry.absenceName}</div>
                  ) : null}
                  {blocks.map((b) => {
                    const type = typeOf.get(b.code);
                    const tone = type ? toneOf(type) : "productive";
                    return (
                      <div
                        key={`${b.start}-${b.code}`}
                        // the type's name in words on hover (D13), built then: the page stays within its budget
                        onPointerEnter={(e) => { e.currentTarget.title = barText(type, b, row.person.defaultHoursMarket); }}
                        aria-label={`${assignmentText(b)} ${fromMinutes(b.start)}–${fromMinutes(b.end)}`}
                        className={`absolute inset-y-1 flex items-center gap-1 overflow-hidden whitespace-nowrap rounded-button px-1 text-caption font-semibold ${TONE_CLASS[tone]}`}
                        style={{ left: px(b.start), width: Math.max(4, px(b.end) - px(b.start)) }}
                      >
                        <span>{b.code}</span>
                        {b.market && b.market !== row.person.defaultHoursMarket ? <span className="rounded-button bg-white/80 px-1 text-p4a-inkt">{b.market}</span> : null}
                      </div>
                    );
                  })}
                  {selRange && r >= selRange.rA && r <= selRange.rZ ? (
                    <div className="pointer-events-none absolute inset-y-0 border-2 border-p4a-lightblue bg-p4a-lightblue/30"
                      style={{ left: selRange.sA * SLOT_PX, width: (selRange.sZ - selRange.sA + 1) * SLOT_PX }} />
                  ) : null}
                </div>
                <div className="tabular w-20 shrink-0 px-2 text-right" onPointerEnter={(e) => { e.currentTarget.title = splitText(planned); }}>{total > 0 ? fmtMinutes(total) : ""}</div>
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
                  {f.working > 0 ? f.working : ""}
                </div>
              ))}
            </div>
            <div className="w-20 shrink-0" />
          </div>
        </div>
      </div>

      <section className="rounded-card border border-p4a-border bg-white p-6" data-testid="roster-totals">
        <h2 className="mb-1 text-panel font-semibold text-p4a-heading">{t.totals}</h2>
        <p className="mb-4 max-w-3xl text-small text-p4a-muted">{t.totalsIntro}</p>
        {weekTotals.size === 0 ? <p className="text-body text-p4a-muted">{t.noAssignments}</p> : (
          <table className="border-collapse text-body">
            <thead className="bg-p4a-bgblue text-small text-p4a-heading">
              <tr>
                <th className="h-10 px-3 text-left font-semibold">{t.codeLabel}</th>
                <th className="h-10 px-3 text-right font-semibold">{t.totalsDay}</th>
                <th className="h-10 px-3 text-right font-semibold">{t.totalsWeek}</th>
              </tr>
            </thead>
            <tbody>
              {[...weekTotals.keys()].sort((a, b) => a.localeCompare(b)).map((k) => (
                <tr key={k} className="h-10 border-b border-p4a-border">
                  <td className="px-3" title={typeOf.get(k.split("/")[0]!)?.name}>{keyLabel(k)}</td>
                  <td className="tabular px-3 text-right">{dayTotals.get(k) ? fmtMinutes(dayTotals.get(k)!) : ""}</td>
                  <td className="tabular px-3 text-right">{fmtMinutes(weekTotals.get(k)!)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      <ConfirmDialog
        open={pending !== null}
        title={t.confirmTodayTitle}
        confirmLabel={t.confirmTodayButton}
        cancelLabel={copy.dayEditor.cancel}
        onConfirm={confirmPublish}
        onCancel={cancelPublish}
        busy={busy}
      >
        {othersPending === 1 ? t.confirmTodayOne : t.confirmToday.replace("{n}", String(othersPending))}
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
            <div className="grid grid-cols-2 gap-3">
              <label className="flex flex-col gap-2 text-small font-semibold">
                {t.codeLabel}
                <select value={dialog.code} onChange={(e) => setDialog({ ...dialog, code: e.target.value })}
                  className="h-10 rounded-input border border-p4a-border bg-white px-2 font-normal text-body">
                  {ctx.types.filter((x) => x.isActive || x.code === dialog.code).map((x) => <option key={x.code} value={x.code}>{x.code} · {x.name}</option>)}
                </select>
              </label>
              <label className="flex flex-col gap-2 text-small font-semibold">
                {t.market}
                <select value={dialog.market} onChange={(e) => setDialog({ ...dialog, market: e.target.value })}
                  className="h-10 rounded-input border border-p4a-border bg-white px-2 font-normal text-body">
                  <option value="">{t.ownMarket}</option>
                  {ctx.hoursMarkets.filter((m) => m.isActive || m.code === dialog.market).map((m) => <option key={m.code} value={m.code}>{m.code} · {m.name}</option>)}
                </select>
              </label>
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
