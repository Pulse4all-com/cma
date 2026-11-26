"use client";

/**
 * The planner's grid: people by seven days, one text field per cell. Typing 9-17:30 or an absence
 * such as leave and pressing Enter (or leaving the cell) parses it (lib/roster) and saves it at
 * once through PUT /api/v1/roster/weeks/{week}/cells; the database keeps every version. A cell in
 * the past is read-only (kept as it was). Each cell shows its own state (saving, saved, a problem
 * with the reason), so nothing is lost silently and there is no unsaved state to guard.
 *
 * Publish makes the week visible to agents as it stands; a later edit shows "changed since the
 * last publish" until Publish changes. Copy previous week fills this week from the one before.
 * Coverage per work type per day comes from the database; the states are lib/roster's.
 *
 * Keyboard: Tab across cells, Enter saves and moves down, Up and Down move between people, Esc
 * reverts the cell, P, W and N move between weeks (links), T picks the team, U publishes,
 * C copies the previous week, X opens the print view.
 *
 * Assignments (addition 0009zx, brief A): a Week | Day switch. Week keeps this grid, each cell with a thin bar of the
 * day's assignments in their colours (D13); Day is Arno's layout (RosterDay). The week bar adds Copy week, Apply standard
 * week and Save as standard week, each with its report (D9, D10), and Publish shows the plan check first (two warnings,
 * never blocking). Since 26 November 2026 (Martin): the Planned hours meter above the grid in both views (PlannedMeter),
 * Planned per person counts the work blocks and a shift without blocks whole, never a pause, and Publish reads Published
 * and waits while nothing changed since the last publication.
 *
 * One team per page view (brief B41, D2): the page resolves the team once and keys this component by the week and
 * the team, so the select, the header, the grid, People on shift, Planned, the coverage, the saved weeks, print, copy,
 * publish and the shortcuts all show and write that one team; another team or week is a new grid that appears whole
 * when the page's answer is there (a transition: until then the previous week stays, the filter row busy). A refresh
 * of the same week (after Publish or Copy previous week) brings the cells and the header from the database again.
 */
import { useEffect, useMemo, useOptimistic, useRef, useState, useTransition, type KeyboardEvent as ReactKeyboardEvent } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import type { Copy, Locale } from "@/lib/copy";
import type { AbsenceType, AssignmentBlock, RosterEntry, RosterReportRow, RosterWeekSummary, TeamInfo } from "@/lib/data";
import dynamic from "next/dynamic";
import { pct, planCheck, plannedMinutes, plannedSummary, toMinutes, toneOf, TONE_CLASS, type Block, type PlannedDay, type PlannerWeek } from "@/lib/assignments";
import { PlannedMeter, type MeterWords } from "./PlannedMeter";
// The Day view's code comes with the Day view only: the Week view's page carries none of it (web/verify/perf.json)
const RosterDay = dynamic(() => import("./RosterDay").then((m) => m.RosterDay));
import {
  absenceKeywordList, cellLabel, coverageGrid, EVERYONE, headcountByDate, isoWeek, parseCell, plannerSearch, plannerTeamOfHeader, rosterTeamArg, weekDays,
  type Cell, type CellProblem, type CoverageState,
} from "@/lib/roster";
import { addDays, fmtDate, fmtMinutes, fmtDateTime } from "@/lib/time";
import { ConfirmDialog } from "./ConfirmDialog";
import { Badge, Button, Keycap, LinkButton, Notice } from "./primitives";
import { WeekBar } from "./WeekBar";
import { PENDING_ROW, usePendingChoice } from "./usePendingPush";

type CellState = { status: "idle" } | { status: "saving" } | { status: "saved" } | { status: "problem"; problem: CellProblem | "past" | "conflict" | "scope" | "failed" };

async function send(method: "PUT" | "POST", path: string, body: unknown): Promise<Response> {
  return fetch(path, { method, headers: { "content-type": "application/json", "x-cma-request": "1" }, body: JSON.stringify(body) });
}

export function RosterPlanner({
  week,
  weeks,
  teams,
  team,
  absences,
  today,
  thisWeek,
  viewerZone,
  copy,
  locale,
  view = "week",
  day,
}: {
  /** The week with its blocks compacted (lib/assignments plannerWeek) */
  week: PlannerWeek;
  weeks: RosterWeekSummary[];
  teams: TeamInfo[];
  /** The team on screen as the page resolved it: a team's key or "all" for Everyone (lib/roster, plannerTeam) */
  team: string;
  absences: AbsenceType[];
  /** Today in the viewer's zone, for the header; each cell's own past follows the person's zone */
  today: string;
  thisWeek: string;
  viewerZone: string;
  /** The Day view's words (assignmentsDay) only when the page shows the Day view: the Week view's page stays lighter */
  copy: Pick<Copy, "dayEditor" | "roster" | "assignments"> & Partial<Pick<Copy, "assignmentsDay">>;
  locale: Locale;
  /** Week (the cells) or Day (Arno's layout of one date, addition 0009zx) */
  view?: "week" | "day";
  /** The Day view's date, in the week */
  day?: string;
}) {
  const ta = copy.assignments;
  const t = copy.roster;
  const router = useRouter();
  // the team and the week navigate as a transition: the row says it is busy and the team select shows the choice at once
  const [choosing, shownTeam, choose] = usePendingChoice(team);
  const [pending, startTransition] = useTransition();
  // The writes take the team as the API does: null for Everyone
  const teamArg = rosterTeamArg(team);
  const weekStart = week.header.weekStart;
  const days = useMemo(() => weekDays(weekStart), [weekStart]);
  const keep = { team };
  const entryMap = (w: PlannerWeek) => new Map(w.entries.map((e) => [`${e.userId}:${e.date}`, e]));
  const [saved, setEntries] = useState<Map<string, RosterEntry>>(() => entryMap(week));
  /**
   * A cell saved shows its new value at once (night N07, decision D3): the entry, the person's planned hours, the day's
   * headcount and the cell's style follow the typed value from the moment the cell is left; the server's entry replaces
   * it when the write answers, and a refusal drops it when the transition ends, the cell keeping its text and its problem
   */
  const [entries, showEntry] = useOptimistic(saved, (m: Map<string, RosterEntry>, change: { k: string; entry: RosterEntry | null }) => {
    const n = new Map(m);
    if (change.entry) n.set(change.k, change.entry);
    else n.delete(change.k);
    return n;
  });
  const [drafts, setDrafts] = useState<Map<string, string>>(new Map());
  const [states, setStates] = useState<Map<string, CellState>>(new Map());
  const [header, setHeader] = useState(week.header);
  // The week's blocks per cell, for the thin bar under each cell (addition 0009zx)
  const blockMap = (w: PlannerWeek) => new Map(Object.entries(w.blocks).map(([k, list]) =>
    [k, list.map(([code, start, end, hoursMarket, note]): AssignmentBlock => ({ assignmentId: "", code, start, end, hoursMarket, note }))]));
  const [cellBlocks, setCellBlocks] = useState(() => blockMap(week));
  // A refresh of this week and team (Publish, Copy previous week) brings a new answer: the cells and the header follow it
  const [answer, setAnswer] = useState(week);
  if (answer !== week) {
    setAnswer(week);
    setEntries(entryMap(week));
    setHeader(week.header);
    setCellBlocks(blockMap(week));
  }

  // The address always carries the team on screen (D2): a load without ?team= (the rail) or with one that named no
  // current team gets the resolved key, without a new request, so a reload shows the same team
  useEffect(() => {
    if (new URLSearchParams(window.location.search).get("team") !== team) {
      window.history.replaceState(null, "", plannerSearch(window.location.search, team));
    }
  }, [team]);
  const [confirm, setConfirm] = useState<"publish" | "copy" | "copyWeek" | "apply" | "save" | null>(null);
  const [copyFrom, setCopyFrom] = useState(() => weeks.filter((w) => w.weekStart !== week.header.weekStart).at(-1)?.weekStart ?? addDays(week.header.weekStart, -7));
  const [notice, setNotice] = useState<string | null>(null);
  const grid = useRef<HTMLTableSectionElement>(null);

  // A retired absence type (configuration, 0005a) keeps its history but cannot be typed
  const absenceOptions = absences.filter((a) => a.isActive).map((a) => ({ key: a.key, name: a.name }));
  // The placeholder names the first absence type's key; the refusal lists them all (never a fixed list)
  const cellHint = t.cellHint.replace("{absence}", absenceOptions[0]?.key ?? "");
  const absenceList = absenceKeywordList(absenceOptions);
  const key = (userId: string, date: string) => `${userId}:${date}`;
  const setState = (k: string, s: CellState) => setStates((m) => new Map(m).set(k, s));

  /** The person's own today decides which cells are in the past (the database uses the same rule) */
  const todayOf = (zone: string) => new Intl.DateTimeFormat("en-CA", { timeZone: zone, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());

  /** A cell of today waiting for the planner's yes (D8): the week holds other unpublished changes that would go with it */
  const [cellConfirm, setCellConfirm] = useState<{ userId: string; date: string; text: string; others: number } | null>(null);

  function save(userId: string, date: string, text: string, publishOthers = false) {
    const k = key(userId, date);
    const current = entries.get(k) ?? null;
    if (text.trim() === cellLabel(current)) {
      setDrafts((m) => { const n = new Map(m); n.delete(k); return n; });
      return;
    }
    const parsed = parseCell(text, absenceOptions);
    if ("problem" in parsed) {
      setState(k, { status: "problem", problem: parsed.problem });
      return;
    }
    const cell: Cell = parsed.cell;
    setState(k, { status: "saving" });
    startTransition(async () => {
      showEntry({ k, entry: cell.kind === "clear" ? null : {
        entryId: current?.entryId ?? "", userId, date, kind: cell.kind, note: current?.note ?? null,
        start: cell.kind === "shift" ? `${cell.start}:00`.slice(0, 8) : null, end: cell.kind === "shift" ? `${cell.end}:00`.slice(0, 8) : null,
        absenceKey: cell.kind === "absence" ? cell.key : null,
        absenceName: cell.kind === "absence" ? absenceOptions.find((a) => a.key === cell.key)?.name ?? cell.key : null,
        recordedAt: new Date().toISOString(), recordedByName: current?.recordedByName ?? "",
      } });
      const body = cell.kind === "shift" ? { kind: "shift", start: cell.start, end: cell.end, note: current?.note ?? null }
        : cell.kind === "absence" ? { kind: "absence", absenceKey: cell.key, note: current?.note ?? null } : { kind: "clear" };
      const res = await send("PUT", `/api/v1/roster/weeks/${weekStart}/cells`, { team: teamArg, userId, date, cell: body, publishOthers });
      if (!res.ok) {
        const err = (await res.json().catch(() => null)) as { error?: { code?: string; message?: string } } | null;
        const m = err?.error?.message ?? "";
        const problem = res.status === 409 ? "conflict" : /past/.test(m) ? "past" : /not on this roster/.test(m) ? "scope" : res.status === 400 ? "format" : "failed";
        setState(k, { status: "problem", problem });
        return;
      }
      const answer = ((await res.json()) as { data: (RosterEntry & { assignments: AssignmentBlock[]; endedAssignments: number; published: boolean }) | { status: "confirm"; otherChanges: number } | null }).data;
      if (answer && "status" in answer && answer.status === "confirm") {
        // today in a published week with other changes waiting (D8): nothing was written; the cell keeps its text until
        // the planner says yes (the optimistic value drops when this transition ends)
        setState(k, { status: "idle" });
        setCellConfirm({ userId, date, text, others: answer.otherChanges });
        return;
      }
      const stored = answer as (RosterEntry & { assignments: AssignmentBlock[]; endedAssignments: number; published: boolean }) | null;
      setEntries((m) => { const n = new Map(m); if (stored) n.set(k, stored); else n.delete(k); return n; });
      // the blocks outside the new shift ended with it (addition 0009zx); a clear ends every block of the day
      const endedNow = stored ? stored.endedAssignments : (cellBlocks.get(k) ?? []).length;
      setCellBlocks((m) => new Map(m).set(k, stored?.assignments ?? []));
      if (endedNow > 0) setNotice(ta.endedWithShift.replace("{n}", String(endedNow)));
      setDrafts((m) => { const n = new Map(m); n.delete(k); return n; });
      setState(k, { status: "saved" });
      setHeader((h) => ({ ...h, changedSincePublish: h.status === "published", entryCount: h.entryCount + (stored ? (current ? 0 : 1) : current ? -1 : 0) }));
      if (stored?.published || (publishOthers && !stored)) {
        // the person's today in a published week: published at once (D8), so the header is read again now
        setNotice(ta.publishedNow);
        router.refresh();
        return;
      }
      refreshSoon();
    });
  }

  /**
   * The week read again once the person pauses (night N07, D4): the client router cache keeps a page 30 seconds, so a
   * click back to the planner within that time would otherwise show the week before these edits. One read after the last
   * save of a run of edits, 1.5 s later, never one per cell
   */
  const refreshTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  function refreshSoon() {
    if (refreshTimer.current) clearTimeout(refreshTimer.current);
    refreshTimer.current = setTimeout(() => {
      refreshTimer.current = null;
      startTransition(() => router.refresh());
    }, 1500);
  }
  useEffect(() => () => { if (refreshTimer.current) clearTimeout(refreshTimer.current); }, []);

  function onKey(e: ReactKeyboardEvent<HTMLInputElement>, userId: string, date: string) {
    const inputs = Array.from(grid.current?.querySelectorAll<HTMLInputElement>("input[data-cell]") ?? []);
    const i = inputs.indexOf(e.currentTarget);
    if (e.key === "Enter" || e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      e.currentTarget.blur();
      const step = e.key === "ArrowUp" ? -7 : 7;
      inputs[i + step]?.focus();
      inputs[i + step]?.select();
    }
    if (e.key === "Escape") {
      e.preventDefault();
      setDrafts((m) => { const n = new Map(m); n.delete(key(userId, date)); return n; });
      setState(key(userId, date), { status: "idle" });
      e.currentTarget.blur();
    }
  }

  function publish() {
    setConfirm(null);
    setNotice(null);
    startTransition(async () => {
      const res = await send("POST", `/api/v1/roster/weeks/${weekStart}/publish`, { team: teamArg });
      if (!res.ok) { setNotice(t.publishFailed); return; }
      setHeader(((await res.json()) as { data: typeof header }).data);
      router.refresh();
    });
  }

  /** What Copy week, Apply standard week and Save as standard week did and skipped, and why (D9, D10), in one line */
  function reportLine(done: string, rows: RosterReportRow[]): string {
    const skipped = rows.filter((r) => r.outcome === "skipped");
    const reasons = new Map<string, number>();
    for (const r of skipped) reasons.set(r.reason ?? "", (reasons.get(r.reason ?? "") ?? 0) + 1);
    const why = [...reasons].map(([r, n]) => `${n} ${ta[`reason_${r}` as keyof typeof ta] ?? r}`).join(", ");
    const dropped = rows.reduce((n, r) => n + r.blocksDropped, 0);
    return [
      done.replace("{n}", String(rows.filter((r) => r.outcome === "done").length)),
      skipped.length ? ta.reportSkipped.replace("{n}", String(skipped.length)).replace("{reasons}", why) : null,
      dropped ? ta.reportDropped.replace("{n}", String(dropped)) : null,
    ].filter(Boolean).join(". ");
  }

  function copyPrevious(from = addDays(weekStart, -7)) {
    setConfirm(null);
    setNotice(null);
    startTransition(async () => {
      const res = await send("POST", `/api/v1/roster/weeks/${weekStart}/copy`, { team: teamArg, from });
      if (!res.ok) { setNotice(t.copyFailed); return; }
      const { report } = ((await res.json()) as { data: { copied: number; report: RosterReportRow[] } }).data;
      setNotice(reportLine(ta.reportCopied, report));
      router.refresh();
    });
  }

  function standardWeek(action: "apply" | "save") {
    setConfirm(null);
    setNotice(null);
    startTransition(async () => {
      const res = await send("POST", `/api/v1/roster/weeks/${weekStart}/${action === "apply" ? "apply-standard-week" : "standard-week"}`, { team: teamArg });
      if (!res.ok) { setNotice(ta.reportFailed); return; }
      const report = ((await res.json()) as { data: RosterReportRow[] }).data;
      setNotice(reportLine(action === "apply" ? ta.reportApplied : ta.reportSaved, report));
      if (action === "apply") router.refresh();
    });
  }

  // The plan check before Publish (brief A): two warnings that never block, over the week's shifts that hold blocks
  const kinds = useMemo(() => new Map(week.planner.types.map((x) => [x.code, x.kind])), [week.planner.types]);
  const typeOf = useMemo(() => new Map(week.planner.types.map((x) => [x.code, x])), [week.planner.types]);
  const warnings = confirm === "publish" ? [...entries.values()].flatMap((e) => {
    if (e.kind !== "shift" || !e.start || !e.end) return [];
    const blocks: Block[] = (cellBlocks.get(`${e.userId}:${e.date}`) ?? []).map((b) => ({ code: b.code, start: toMinutes(b.start), end: toMinutes(b.end), market: b.hoursMarket, note: b.note }));
    const name = week.people.find((p) => p.userId === e.userId)?.displayName ?? "";
    return planCheck({ start: toMinutes(e.start), end: toMinutes(e.end) }, blocks, week.planner.lunchAfterMinutes, week.planner.lunchTypeCode, kinds).map((w) =>
      w.kind === "lunch"
        ? ta.checkLunch.replace("{name}", name).replace("{date}", fmtDate(e.date, locale, "compact")).replace("{hours}", fmtMinutes(week.planner.lunchAfterMinutes))
        : ta.checkGap.replace("{name}", name).replace("{date}", fmtDate(e.date, locale, "compact")).replace("{from}", `${String(Math.floor(w.start / 60)).padStart(2, "0")}:${String(w.start % 60).padStart(2, "0")}`).replace("{to}", `${String(Math.floor(w.end / 60)).padStart(2, "0")}:${String(w.end % 60).padStart(2, "0")}`));
  }) : [];
  const dayHref = (d: string) => `/roster/planner?week=${weekStart}&team=${encodeURIComponent(team)}&view=day&date=${d}`;
  const weekHref = `/roster/planner?week=${weekStart}&team=${encodeURIComponent(team)}`;
  const shownDay = day && days.includes(day) ? day : days.includes(today) ? today : weekStart;

  const liveEntries = [...entries.values()];
  // Planned per person and the meter (Martin, 26 November 2026): the work blocks, a shift without blocks whole, no pause
  const plannedDays: PlannedDay[] = liveEntries.filter((e) => week.people.some((p) => p.userId === e.userId)).map((e) => ({
    userId: e.userId, date: e.date, defaultMarket: week.people.find((p) => p.userId === e.userId)?.defaultHoursMarket ?? null,
    shift: e.kind === "shift" && e.start && e.end ? { start: toMinutes(e.start), end: toMinutes(e.end) } : null,
    blocks: (cellBlocks.get(`${e.userId}:${e.date}`) ?? []).map((b) => ({ code: b.code, start: toMinutes(b.start), end: toMinutes(b.end), market: b.hoursMarket, note: b.note })),
  }));
  const planned = new Map<string, number>();
  for (const d of plannedDays) planned.set(d.userId, (planned.get(d.userId) ?? 0) + plannedMinutes(d.shift, d.blocks, kinds));
  const meterWords: MeterWords = {
    title: ta.meterTitle, hint: ta.meterHint, week: ta.meterWeek, day: ta.meterDay, of: ta.meterOf, perAssignment: ta.meterPerAssignment,
    dayLevel: ta.meterDayLevel, pauses: ta.meterPauses, pausesHint: ta.meterPausesHint, noMarket: ta.meterNoMarket, nothing: ta.meterNothing,
  };
  const headcount = headcountByDate(liveEntries);
  const coverage = coverageGrid(week.coverage, days);
  const problemText: Record<string, string> = {
    format: t.problemFormat, order: t.problemOrder, absence: t.problemAbsence.replace("{list}", absenceList), past: t.problemPast,
    conflict: t.problemConflict, scope: t.problemScope, failed: t.problemSaveFailed,
  };
  const coverageTone: Record<CoverageState, "success" | "warning" | "error" | "neutral"> = { ok: "success", single: "warning", short: "error", none: "neutral" };
  const coverageText = (c: { state: CoverageState; plannedPeople: number; target: number | null }) =>
    c.state === "none" ? t.coverageNone : c.state === "single" ? t.coverageSingle
    : c.state === "short" ? t.coverageShort.replace("{n}", String(c.plannedPeople)).replace("{target}", String(c.target)) : `${t.coverageOk} · ${c.plannedPeople}`;
  const printHref = `/roster/planner/print?week=${weekStart}&team=${encodeURIComponent(team)}`;
  const th = "h-10 whitespace-nowrap px-2 text-left font-semibold";

  return (
    <div className="flex flex-col gap-6">
      <WeekBar pathname="/roster/planner" weekStart={weekStart} thisWeek={thisWeek} copy={copy} locale={locale} keep={keep}>
        <form method="get" action="/roster/planner" className={`flex items-end gap-3 ${PENDING_ROW}`} data-testid="planner-filters" aria-busy={choosing || undefined}>
          <input type="hidden" name="week" value={weekStart} />
          <label className="flex flex-col gap-2 text-small font-semibold">
            <span className="flex items-center gap-2">{t.team} <Keycap>T</Keycap></span>
            <select
              name="team"
              value={shownTeam}
              data-shortcut="t"
              onChange={(e) => choose(e.target.value, `/roster/planner?week=${weekStart}&team=${encodeURIComponent(e.target.value)}`)}
              className="h-10 min-w-48 rounded-input border border-p4a-border bg-white px-3 font-normal text-body text-p4a-body focus:border-p4a-deepblue"
            >
              {teams.map((x) => (
                <option key={x.key} value={x.key}>{x.name}</option>
              ))}
              <option value={EVERYONE}>{t.wholeTenant}</option>
            </select>
          </label>
          <label className="flex flex-col gap-2 text-small font-semibold">
            {t.weeks}
            <select
              value=""
              data-menu=""
              onChange={(e) => { if (e.target.value) choose(shownTeam, `/roster/planner?week=${encodeURIComponent(e.target.value)}&team=${encodeURIComponent(shownTeam)}`); }}
              className="h-10 min-w-56 rounded-input border border-p4a-border bg-white px-3 font-normal text-body text-p4a-body focus:border-p4a-deepblue"
            >
              <option value="">{weeks.length === 0 ? t.noWeeks : `${weeks.length} ${t.weeks.toLowerCase()}`}</option>
              {weeks.map((w) => (
                <option key={w.weekStart} value={w.weekStart}>
                  {t.weekOf.replace("{n}", String(isoWeek(w.weekStart)))} · {fmtDate(w.weekStart, locale, "short")} · {w.status === "published" ? `${t.published} ${w.version}` : t.draft} · {w.shiftCount}
                </option>
              ))}
            </select>
          </label>
        </form>
      </WeekBar>

      <div className="flex flex-col gap-3">
        <div className="flex items-center gap-3 text-small" data-testid="roster-status" data-status={header.status} data-team={plannerTeamOfHeader(header)}>
          <Badge tone={header.status === "published" ? "success" : "neutral"}>{header.status === "published" ? t.published : t.draft}</Badge>
          {header.status === "published" ? (
            <span className="text-p4a-muted">
              {t.publishedAs.replace("{version}", String(header.version)).replace("{when}", header.publishedAt ? fmtDateTime(header.publishedAt, viewerZone, locale) : "").replace("{who}", header.publishedByName ?? "")}
            </span>
          ) : (
            <span className="text-p4a-muted">{t.notPublishedYet}</span>
          )}
          {header.changedSincePublish ? <Badge tone="warning">{t.changedSincePublish}</Badge> : null}
        </div>
        <div className="flex flex-wrap items-center justify-end gap-3">
          <Button variant="outlined" disabled={pending} onClick={() => setConfirm("copyWeek")} data-testid="roster-copy-week">{ta.copyWeek}</Button>
          <Button variant="outlined" disabled={pending} onClick={() => setConfirm("apply")} data-testid="roster-apply-standard">{ta.applyStandard}</Button>
          <Button variant="outlined" disabled={pending} onClick={() => setConfirm("save")} data-testid="roster-save-standard">{ta.saveStandard}</Button>
          <LinkButton href={printHref} target="_blank" rel="noopener" shortcut="X" data-shortcut="x" title={t.printHint}>
            {t.print}
          </LinkButton>
          <Button variant="outlined" shortcut="C" data-shortcut="c" disabled={pending} onClick={() => setConfirm("copy")}>
            {t.copyPrevious}
          </Button>
          {/* published with nothing waiting: it says so and waits until a change does (Martin, 26 November 2026) */}
          <Button variant={header.changedSincePublish || header.status === "draft" ? "primary" : "outlined"} shortcut="U" data-shortcut="u"
            disabled={pending || (header.status === "published" && !header.changedSincePublish)} onClick={() => setConfirm("publish")} data-testid="roster-publish">
            {header.status !== "published" ? t.publish : header.changedSincePublish ? t.publishAgain : t.published}
          </Button>
        </div>
      </div>

      {notice ? <Notice tone="info">{notice}</Notice> : null}

      <nav aria-label={ta.view} className="flex flex-wrap items-center gap-2" data-testid="roster-view">
        <Link href={weekHref} aria-current={view === "week" ? "page" : undefined}
          className={`inline-flex h-10 items-center rounded-button border px-4 font-semibold ${view === "week" ? "border-p4a-deepblue bg-p4a-deepblue text-white" : "border-p4a-border text-p4a-deepblue hover:bg-p4a-bgblue"}`}>{ta.viewWeek}</Link>
        <Link href={dayHref(shownDay)} aria-current={view === "day" ? "page" : undefined}
          className={`inline-flex h-10 items-center rounded-button border px-4 font-semibold ${view === "day" ? "border-p4a-deepblue bg-p4a-deepblue text-white" : "border-p4a-border text-p4a-deepblue hover:bg-p4a-bgblue"}`}>{ta.viewDay}</Link>
        {view === "day" ? days.map((d) => (
          <Link key={d} href={dayHref(d)} aria-current={d === shownDay ? "date" : undefined}
            className={`inline-flex h-10 items-center rounded-button px-3 text-body ${d === shownDay ? "bg-p4a-bgblue font-semibold text-p4a-deepblue" : "text-p4a-deepblue hover:underline"}`}>
            {fmtDate(d, locale, "compact")}
          </Link>
        )) : null}
      </nav>

      {view === "week" && week.people.length > 0 ? <PlannedMeter week={plannedSummary(plannedDays, kinds)} types={week.planner.types} words={meterWords} /> : null}

      {view === "day" && copy.assignmentsDay ? (
        <RosterDay key={shownDay} week={week} date={shownDay} teamArg={teamArg} copy={{ ...copy, assignmentsDay: copy.assignmentsDay }} meterWords={meterWords} locale={locale}
          onPublishedNow={() => startTransition(() => router.refresh())}
          onChanged={() => setHeader((h) => (h.status === "published" && !h.changedSincePublish ? { ...h, changedSincePublish: true } : h))} />
      ) : week.people.length === 0 ? (
        <p className="text-body text-p4a-muted">{t.noPeople}</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full border-collapse text-body">
            <thead className="bg-p4a-bgblue text-small text-p4a-heading">
              <tr>
                <th className={th}>{t.person}</th>
                {days.map((d) => (
                  <th key={d} className={`${th} ${d === today ? "text-p4a-deepblue underline decoration-2 underline-offset-4" : ""}`}>
                    {fmtDate(d, locale, "compact")}
                  </th>
                ))}
                <th className={`${th} text-right`}>{t.planned}</th>
              </tr>
            </thead>
            <tbody ref={grid} data-testid="roster-grid">
              {week.people.map((p) => {
                const personToday = todayOf(p.timeZone);
                return (
                  <tr key={p.userId} className="border-b border-p4a-border odd:bg-p4a-offwhite">
                    <td className="whitespace-nowrap px-2 py-1 align-top">
                      <div className="font-semibold">{p.displayName}</div>
                      <div className="text-caption text-p4a-grey">{p.organisationName}</div>
                    </td>
                    {days.map((d) => {
                      const k = key(p.userId, d);
                      const entry = entries.get(k) ?? null;
                      const past = d < personToday;
                      const st = states.get(k) ?? { status: "idle" };
                      const value = drafts.get(k) ?? cellLabel(entry);
                      return (
                        <td key={d} className="px-1 py-1 align-top">
                          {past ? (
                            <div className="h-10 rounded-input bg-p4a-sand px-2 py-2 text-small text-p4a-muted" title={t.cellPast}>{cellLabel(entry) || "–"}</div>
                          ) : (
                            <input
                              data-cell={k}
                              value={value}
                              maxLength={24}
                              placeholder={cellHint}
                              aria-label={`${p.displayName} ${fmtDate(d, locale, "compact")}`}
                              title={entry?.note ? `${t.legendNote}: ${entry.note}` : cellHint}
                              onChange={(e) => setDrafts((m) => new Map(m).set(k, e.target.value))}
                              onBlur={(e) => save(p.userId, d, e.target.value)}
                              onKeyDown={(e) => onKey(e, p.userId, d)}
                              className={[
                                "tabular h-10 w-full min-w-28 rounded-input border bg-white px-2 text-body text-p4a-body focus:border-p4a-deepblue",
                                st.status === "problem" ? "border-p4a-error" : entry?.kind === "absence" ? "border-p4a-border text-p4a-muted" : "border-p4a-border",
                              ].join(" ")}
                            />
                          )}
                          <CellBar entry={entry} blocks={cellBlocks.get(k) ?? []} typeOf={typeOf} />
                          {st.status === "problem" ? <p className="mt-1 max-w-32 text-caption text-p4a-error">{problemText[st.problem]}</p> : null}
                          {st.status === "saving" ? <p className="mt-1 text-caption text-p4a-grey">{t.cellSaving}</p> : null}
                          {st.status === "saved" ? <p className="mt-1 text-caption text-p4a-success">{t.cellSaved}</p> : null}
                        </td>
                      );
                    })}
                    <td className="tabular whitespace-nowrap px-2 py-3 text-right">{fmtMinutes(planned.get(p.userId) ?? 0)}</td>
                  </tr>
                );
              })}
            </tbody>
            <tfoot>
              <tr className="text-small font-semibold text-p4a-heading">
                <td className="px-2 py-2">{t.people}</td>
                {days.map((d) => (
                  <td key={d} className="tabular px-2 py-2">{headcount.get(d) ?? 0}</td>
                ))}
                <td />
              </tr>
            </tfoot>
          </table>
        </div>
      )}

      {view === "week" ? <section className="rounded-card border border-p4a-border bg-white p-6" data-testid="roster-coverage">
        <h2 className="mb-1 text-panel font-semibold text-p4a-heading">{t.coverage}</h2>
        <p className="mb-4 max-w-3xl text-small text-p4a-muted">{t.coverageIntro}</p>
        {coverage.length === 0 ? (
          <p className="text-body text-p4a-muted">{t.noCoverage}</p>
        ) : (
          <table className="w-full border-collapse text-body">
            <thead className="bg-p4a-bgblue text-small text-p4a-heading">
              <tr>
                <th className={th} />
                {days.map((d) => (
                  <th key={d} className={th}>{fmtDate(d, locale, "compact")}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {coverage.map((row) => (
                <tr key={row.skillKey} className="border-b border-p4a-border">
                  <td className="whitespace-nowrap px-2 py-2 font-semibold">{row.skillName}</td>
                  {row.cells.map((c) => (
                    <td key={c.date} className="px-2 py-2" title={c.peopleNames.join(", ")}>
                      <Badge tone={coverageTone[c.state]}>{coverageText(c)}</Badge>
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section> : null}

      <ConfirmDialog
        open={cellConfirm !== null}
        title={ta.confirmTodayTitle}
        confirmLabel={ta.confirmTodayButton}
        cancelLabel={copy.dayEditor.cancel}
        onConfirm={() => { const c = cellConfirm!; setCellConfirm(null); save(c.userId, c.date, c.text, true); }}
        onCancel={() => setCellConfirm(null)}
        busy={pending}
      >
        {cellConfirm?.others === 1 ? ta.confirmTodayOne : ta.confirmToday.replace("{n}", String(cellConfirm?.others ?? 0))}
      </ConfirmDialog>

      <ConfirmDialog
        open={confirm !== null}
        title={confirm === "copy" ? t.copyPrevious : confirm === "copyWeek" ? ta.copyWeekTitle : confirm === "apply" ? ta.applyStandard : confirm === "save" ? ta.saveStandard : header.status === "published" ? t.publishAgain : t.publish}
        confirmLabel={confirm === "copy" ? t.copyPrevious : confirm === "copyWeek" ? ta.copyWeek : confirm === "apply" ? ta.applyStandard : confirm === "save" ? ta.saveStandard : t.publish}
        cancelLabel={copy.dayEditor.cancel}
        onConfirm={confirm === "copy" ? () => copyPrevious() : confirm === "copyWeek" ? () => copyPrevious(copyFrom) : confirm === "apply" ? () => standardWeek("apply") : confirm === "save" ? () => standardWeek("save") : publish}
        onCancel={() => setConfirm(null)}
        busy={pending}
        irreversible={confirm === "copy" || confirm === "copyWeek" || confirm === "save"}
        confirmDisabled={confirm === "copyWeek" && copyFrom === weekStart}
      >
        {confirm === "copy" ? t.copyConfirm : confirm === "apply" ? ta.applyConfirm : confirm === "save" ? ta.saveConfirm : confirm === "copyWeek" ? (
          <span className="flex flex-col gap-3">
            <span>{ta.copyWeekBody}</span>
            <label className="flex flex-col gap-2 text-small font-semibold">
              {ta.copyWeekFrom}
              <input type="date" value={copyFrom} step={7} onChange={(e) => setCopyFrom(e.target.value ? startOfWeekKey(e.target.value) : copyFrom)}
                className="h-10 rounded-input border border-p4a-border bg-white px-3 font-normal text-body" data-testid="roster-copy-from" />
            </label>
          </span>
        ) : (
          <span className="flex flex-col gap-3">
            <span>{t.publishConfirm}</span>
            <span className="font-semibold text-p4a-heading">{ta.checkTitle}</span>
            {warnings.length === 0 ? <span>{ta.checkNone}</span> : (
              <span className="flex flex-col gap-1 text-small" data-testid="roster-plan-check">
                {warnings.slice(0, 8).map((w) => <span key={w}>{w}</span>)}
                {warnings.length > 8 ? <span>{ta.checkMore.replace("{n}", String(warnings.length - 8))}</span> : null}
              </span>
            )}
            <span className="text-small text-p4a-muted">{ta.checkHint}</span>
          </span>
        )}
      </ConfirmDialog>
    </div>
  );
}

/** The Monday of a date's week */
function startOfWeekKey(d: string): string {
  const x = new Date(`${d}T00:00:00Z`);
  x.setUTCDate(x.getUTCDate() - ((x.getUTCDay() + 6) % 7));
  return x.toISOString().slice(0, 10);
}

/**
 * The thin bar under a week cell (addition 0009zx, D13): the day's blocks in their colours across the shift, a gap in the
 * page's background; an absence a Background Blue bar. The code is the title, so colour never carries meaning alone
 */
function CellBar({ entry, blocks, typeOf }: {
  entry: RosterEntry | null;
  blocks: AssignmentBlock[];
  typeOf: Map<string, Parameters<typeof toneOf>[0] & { name: string }>;
}) {
  if (entry?.kind === "absence") return <div className={`mt-1 h-1.5 rounded-button ${TONE_CLASS.absence}`} title={entry.absenceName ?? ""} />;
  if (entry?.kind !== "shift" || !entry.start || !entry.end || blocks.length === 0) return null;
  const s = toMinutes(entry.start);
  const span = Math.max(1, toMinutes(entry.end) - s);
  return (
    <div className="relative mt-1 h-1.5 overflow-hidden rounded-button bg-p4a-neutral-surface" data-testid="roster-cell-bar"
      // the blocks in words on hover, built then: a week of cells would otherwise carry them all in the page (perf.json)
      onPointerEnter={(e) => { e.currentTarget.title = blocks.map((b) => `${b.start}–${b.end} ${b.code}${b.hoursMarket ? `-${b.hoursMarket}` : ""} ${typeOf.get(b.code)?.name ?? ""}`.trim()).join("\n"); }}>
      {blocks.map((b) => {
        const type = typeOf.get(b.code);
        return <span key={`${b.start}-${b.code}`} className={`absolute inset-y-0 ${TONE_CLASS[type ? toneOf(type) : "productive"]}`}
          style={{ left: `${pct(toMinutes(b.start) - s, span)}%`, width: `${pct(toMinutes(b.end) - toMinutes(b.start), span)}%` }} />;
      })}
    </div>
  );
}
