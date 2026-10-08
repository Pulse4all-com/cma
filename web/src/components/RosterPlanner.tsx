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
 */
import { useMemo, useRef, useState, useTransition, type KeyboardEvent as ReactKeyboardEvent } from "react";
import { useRouter } from "next/navigation";
import type { Copy, Locale } from "@/lib/copy";
import type { AbsenceType, RosterEntry, RosterWeek, RosterWeekSummary, TeamInfo } from "@/lib/data";
import { cellLabel, coverageGrid, headcountByDate, isoWeek, parseCell, plannedMinutesByUser, weekDays, type Cell, type CellProblem, type CoverageState } from "@/lib/roster";
import { addDays, fmtDate, fmtMinutes } from "@/lib/time";
import { ConfirmDialog } from "./ConfirmDialog";
import { Badge, Button, Keycap, LinkButton, Notice } from "./primitives";
import { WeekBar } from "./WeekBar";

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
  copy,
  locale,
}: {
  week: RosterWeek;
  weeks: RosterWeekSummary[];
  teams: TeamInfo[];
  /** The team on screen, null for everyone */
  team: string | null;
  absences: AbsenceType[];
  /** Today in the viewer's zone, for the header; each cell's own past follows the person's zone */
  today: string;
  thisWeek: string;
  viewerZone: string;
  copy: Copy;
  locale: Locale;
}) {
  const t = copy.roster;
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const weekStart = week.header.weekStart;
  const days = useMemo(() => weekDays(weekStart), [weekStart]);
  const keep = { team: team ?? "all" };
  const [entries, setEntries] = useState<Map<string, RosterEntry>>(() => new Map(week.entries.map((e) => [`${e.userId}:${e.date}`, e])));
  const [drafts, setDrafts] = useState<Map<string, string>>(new Map());
  const [states, setStates] = useState<Map<string, CellState>>(new Map());
  const [header, setHeader] = useState(week.header);
  const [confirm, setConfirm] = useState<"publish" | "copy" | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const grid = useRef<HTMLTableSectionElement>(null);

  // A retired absence type (configuration, 0005a) keeps its history but cannot be typed
  const absenceOptions = absences.filter((a) => a.isActive).map((a) => ({ key: a.key, name: a.name }));
  const key = (userId: string, date: string) => `${userId}:${date}`;
  const setState = (k: string, s: CellState) => setStates((m) => new Map(m).set(k, s));

  /** The person's own today decides which cells are in the past (the database uses the same rule) */
  const todayOf = (zone: string) => new Intl.DateTimeFormat("en-CA", { timeZone: zone, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());

  function save(userId: string, date: string, text: string) {
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
      const body = cell.kind === "shift" ? { kind: "shift", start: cell.start, end: cell.end, note: current?.note ?? null }
        : cell.kind === "absence" ? { kind: "absence", absenceKey: cell.key, note: current?.note ?? null } : { kind: "clear" };
      const res = await send("PUT", `/api/v1/roster/weeks/${weekStart}/cells`, { team, userId, date, cell: body });
      if (!res.ok) {
        const err = (await res.json().catch(() => null)) as { error?: { code?: string; message?: string } } | null;
        const m = err?.error?.message ?? "";
        const problem = res.status === 409 ? "conflict" : /past/.test(m) ? "past" : /not on this roster/.test(m) ? "scope" : res.status === 400 ? "format" : "failed";
        setState(k, { status: "problem", problem });
        return;
      }
      const saved = ((await res.json()) as { data: RosterEntry | null }).data;
      setEntries((m) => { const n = new Map(m); if (saved) n.set(k, saved); else n.delete(k); return n; });
      setDrafts((m) => { const n = new Map(m); n.delete(k); return n; });
      setState(k, { status: "saved" });
      setHeader((h) => ({ ...h, changedSincePublish: h.status === "published", entryCount: h.entryCount + (saved ? (current ? 0 : 1) : current ? -1 : 0) }));
    });
  }

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
      const res = await send("POST", `/api/v1/roster/weeks/${weekStart}/publish`, { team });
      if (!res.ok) { setNotice(t.publishFailed); return; }
      setHeader(((await res.json()) as { data: typeof header }).data);
      router.refresh();
    });
  }

  function copyPrevious() {
    setConfirm(null);
    setNotice(null);
    startTransition(async () => {
      const res = await send("POST", `/api/v1/roster/weeks/${weekStart}/copy`, { team, from: addDays(weekStart, -7) });
      if (!res.ok) { setNotice(t.copyFailed); return; }
      const { copied } = ((await res.json()) as { data: { copied: number } }).data;
      setNotice(t.copied.replace("{n}", String(copied)));
      router.refresh();
    });
  }

  const liveEntries = [...entries.values()];
  const planned = plannedMinutesByUser(liveEntries);
  const headcount = headcountByDate(liveEntries);
  const coverage = coverageGrid(week.coverage, days);
  const problemText: Record<string, string> = {
    format: t.problemFormat, order: t.problemOrder, absence: t.problemAbsence, past: t.problemPast,
    conflict: t.problemConflict, scope: t.problemScope, failed: t.problemSaveFailed,
  };
  const coverageTone: Record<CoverageState, "success" | "warning" | "error" | "neutral"> = { ok: "success", single: "warning", short: "error", none: "neutral" };
  const coverageText = (c: { state: CoverageState; plannedPeople: number; target: number | null }) =>
    c.state === "none" ? t.coverageNone : c.state === "single" ? t.coverageSingle
    : c.state === "short" ? t.coverageShort.replace("{n}", String(c.plannedPeople)).replace("{target}", String(c.target)) : `${t.coverageOk} · ${c.plannedPeople}`;
  const printHref = `/roster/planner/print?week=${weekStart}&team=${team ?? "all"}`;
  const th = "h-10 whitespace-nowrap px-2 text-left font-semibold";

  return (
    <div className="flex flex-col gap-6">
      <WeekBar pathname="/roster/planner" weekStart={weekStart} thisWeek={thisWeek} copy={copy} locale={locale} keep={keep}>
        <form method="get" action="/roster/planner" className="flex items-end gap-3">
          <input type="hidden" name="week" value={weekStart} />
          <label className="flex flex-col gap-2 text-small font-semibold">
            <span className="flex items-center gap-2">{t.team} <Keycap>T</Keycap></span>
            <select
              name="team"
              value={team ?? "all"}
              data-shortcut="t"
              onChange={(e) => router.push(`/roster/planner?week=${weekStart}&team=${e.target.value}`)}
              className="h-10 min-w-48 rounded-input border border-p4a-border bg-white px-3 font-normal text-body text-p4a-body focus:border-p4a-deepblue"
            >
              {teams.map((x) => (
                <option key={x.key} value={x.key}>{x.name}</option>
              ))}
              <option value="all">{t.wholeTenant}</option>
            </select>
          </label>
          <label className="flex flex-col gap-2 text-small font-semibold">
            {t.weeks}
            <select
              value=""
              onChange={(e) => { if (e.target.value) router.push(`/roster/planner?week=${e.target.value}&team=${team ?? "all"}`); }}
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

      <div className="flex items-center justify-between gap-4">
        <div className="flex items-center gap-3 text-small">
          <Badge tone={header.status === "published" ? "success" : "neutral"}>{header.status === "published" ? t.published : t.draft}</Badge>
          {header.status === "published" ? (
            <span className="text-p4a-muted">
              {t.publishedAs.replace("{version}", String(header.version)).replace("{when}", header.publishedAt ? new Intl.DateTimeFormat(locale === "nl" ? "nl-NL" : "en-GB", { dateStyle: "medium", timeStyle: "short" }).format(new Date(header.publishedAt)) : "").replace("{who}", header.publishedByName ?? "")}
            </span>
          ) : (
            <span className="text-p4a-muted">{t.notPublishedYet}</span>
          )}
          {header.changedSincePublish ? <Badge tone="warning">{t.changedSincePublish}</Badge> : null}
        </div>
        <div className="flex items-center gap-3">
          <LinkButton href={printHref} target="_blank" rel="noopener" shortcut="X" data-shortcut="x" title={t.printHint}>
            {t.print}
          </LinkButton>
          <Button variant="outlined" shortcut="C" data-shortcut="c" disabled={pending} onClick={() => setConfirm("copy")}>
            {t.copyPrevious}
          </Button>
          <Button variant={header.changedSincePublish || header.status === "draft" ? "primary" : "outlined"} shortcut="U" data-shortcut="u" disabled={pending} onClick={() => setConfirm("publish")} data-testid="roster-publish">
            {header.status === "published" ? t.publishAgain : t.publish}
          </Button>
        </div>
      </div>

      {notice ? <Notice tone="info">{notice}</Notice> : null}

      {week.people.length === 0 ? (
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
            <tbody ref={grid}>
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
                              placeholder={t.cellHint}
                              aria-label={`${p.displayName} ${fmtDate(d, locale, "compact")}`}
                              title={entry?.note ? `${t.legendNote}: ${entry.note}` : t.cellHint}
                              onChange={(e) => setDrafts((m) => new Map(m).set(k, e.target.value))}
                              onBlur={(e) => save(p.userId, d, e.target.value)}
                              onKeyDown={(e) => onKey(e, p.userId, d)}
                              className={[
                                "tabular h-10 w-full min-w-28 rounded-input border bg-white px-2 text-body text-p4a-body focus:border-p4a-deepblue",
                                st.status === "problem" ? "border-p4a-error" : entry?.kind === "absence" ? "border-p4a-border text-p4a-muted" : "border-p4a-border",
                              ].join(" ")}
                            />
                          )}
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

      <section className="rounded-card border border-p4a-border bg-white p-6">
        <h2 className="mb-1 text-panel font-semibold text-p4a-heading">{t.coverage}</h2>
        <p className="mb-4 text-small text-p4a-muted">{t.coverageIntro}</p>
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
      </section>

      <ConfirmDialog
        open={confirm !== null}
        title={confirm === "copy" ? t.copyPrevious : header.status === "published" ? t.publishAgain : t.publish}
        confirmLabel={confirm === "copy" ? t.copyPrevious : t.publish}
        cancelLabel={copy.dayEditor.cancel}
        onConfirm={confirm === "copy" ? copyPrevious : publish}
        onCancel={() => setConfirm(null)}
        busy={pending}
      >
        {confirm === "copy" ? t.copyConfirm : t.publishConfirm}
      </ConfirmDialog>
    </div>
  );
}
