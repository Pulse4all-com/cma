"use client";

/**
 * Correct a day and Add day: one native <dialog>, mounted per opening (the parent gives it a key),
 * so every opening starts from the day as it stands now.
 *
 * Rows show the day's effective events in the day's own zone. The earliest row is the clock-in;
 * "Clocked out" is a choice in the status list. Saving sends the smallest diff through
 * POST /api/v1/team/days/{userId}/{date}/corrections, with one reason for the whole edit; the
 * database validates again and the caller is the approver (V1). Nothing here knows a status key.
 *
 * Keyboard: Tab through the rows, Ctrl+Enter saves, Esc closes (twice with unsaved changes).
 */
import { useEffect, useMemo, useRef, useState, useSyncExternalStore, useTransition } from "react";
import type { Copy, Locale } from "@/lib/copy";
import type { DateKey, TeamDayDetail, TeamPerson, TimeEvent, WorkStatus } from "@/lib/data";
import { check, localParts, normalizeTime, rowsFromEvents, type DayProblem, type EditorRow, type RowProblem } from "@/lib/corrections";
import { fmtDate } from "@/lib/time";
import { Badge, Button, Notice } from "./primitives";

export type EditorTarget =
  | { mode: "correct"; userId: string; displayName: string; date: DateKey; timeZone: string }
  | { mode: "add" };

type Who = { userId: string; displayName: string; timeZone: string };
type Step = "pick" | "loading" | "edit" | "error";

/** A coarse client clock for the "not in the future" hint; the database decides */
function subscribe(onTick: () => void) {
  const id = setInterval(onTick, 30_000);
  return () => clearInterval(id);
}
const clientNow = () => Math.floor(Date.now() / 30_000) * 30_000;
const serverNow = () => null;

const field =
  "h-10 rounded-input border border-p4a-border bg-white px-3 text-body text-p4a-body focus:border-p4a-deepblue";

function addMinute(time: string): string {
  const [h, m] = time.split(":").map(Number) as [number, number];
  const t = Math.min(23 * 60 + 59, h * 60 + m + 1);
  return `${String(Math.floor(t / 60)).padStart(2, "0")}:${String(t % 60).padStart(2, "0")}`;
}

export function DayEditor({
  target,
  people,
  meId,
  today,
  statuses,
  copy,
  locale,
  onClose,
  onSaved,
}: {
  target: EditorTarget;
  people: TeamPerson[];
  meId: string;
  /** Latest date Add day offers, in the viewer's zone; the database checks the person's zone */
  today: DateKey;
  statuses: WorkStatus[];
  copy: Copy;
  locale: Locale;
  onClose: () => void;
  onSaved: () => void;
}) {
  const t = copy.dayEditor;
  const ref = useRef<HTMLDialogElement>(null);
  const now = useSyncExternalStore(subscribe, clientNow, serverNow);
  const [pending, startTransition] = useTransition();

  const [step, setStep] = useState<Step>(target.mode === "add" ? "pick" : "loading");
  const [who, setWho] = useState<Who | null>(target.mode === "correct" ? target : null);
  const [date, setDate] = useState<DateKey>(target.mode === "correct" ? target.date : today);
  const [pickUser, setPickUser] = useState("");
  const [events, setEvents] = useState<TimeEvent[]>([]);
  const [existed, setExisted] = useState(false);
  const [original, setOriginal] = useState<EditorRow[]>([]);
  const [rows, setRows] = useState<EditorRow[]>([]);
  /** The rows as they opened, so Esc knows whether anything would be lost */
  const [initial, setInitial] = useState<EditorRow[]>([]);
  const [reason, setReason] = useState("");
  const [armed, setArmed] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  const defaultStatus = statuses.find((s) => s.isDefault) ?? statuses[0];
  const choosable = people.filter((p) => p.userId !== meId);

  useEffect(() => {
    const d = ref.current;
    if (d && !d.open) d.showModal();
  }, []);

  /** Reads the day; every state change happens in the answer's callbacks */
  function fetchDay(w: Who, d: DateKey) {
    fetch(`/api/v1/team/days/${w.userId}/${d}`, { cache: "no-store" })
      .then(async (res) => {
        if (!res.ok) throw new Error(String(res.status));
        const detail = ((await res.json()) as { data: TeamDayDetail }).data;
        const start = rowsFromEvents(detail.events, w.timeZone);
        setEvents(detail.events);
        setExisted(detail.day !== null);
        const opened = start.length ? start : [newRow(null)];
        setOriginal(start);
        setRows(opened);
        setInitial(opened);
        setStep("edit");
      })
      .catch(() => setStep("error"));
  }

  // Correct a day opens straight into the day (step starts as "loading")
  useEffect(() => {
    if (target.mode === "correct") fetchDay(target, target.date);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  function newRow(after: string | null): EditorRow {
    return {
      id: crypto.randomUUID(),
      eventId: null,
      end: false,
      statusKey: defaultStatus?.key ?? null,
      time: after ? addMinute(after) : "",
      offset: null,
    };
  }

  const checked = useMemo(
    () => (who ? check(original, rows, date, who.timeZone, now ?? Number.MAX_SAFE_INTEGER) : null),
    [who, original, rows, date, now],
  );
  const reasonOk = reason.trim().length >= 3 && reason.trim().length <= 500;
  const dirty = reason.trim() !== "" || JSON.stringify(rows) !== JSON.stringify(initial);
  const canSave = step === "edit" && !!checked && checked.changes.length > 0 && reasonOk && !pending;

  function update(id: string, patch: Partial<EditorRow>) {
    setArmed(false);
    setRows((rs) => rs.map((r) => (r.id === id ? { ...r, ...patch } : r)));
  }

  function addRow() {
    setArmed(false);
    setRows((rs) => {
      const live = rs.filter((r) => !r.end && /^\d{2}:\d{2}$/.test(r.time));
      const last = live.reduce<string | null>((m, r) => (m === null || r.time > m ? r.time : m), null);
      const row = newRow(last);
      const endAt = rs.findIndex((r) => r.end);
      return endAt < 0 ? [...rs, row] : [...rs.slice(0, endAt), row, ...rs.slice(endAt)];
    });
  }

  function save() {
    if (!canSave || !who || !checked) return;
    setSaveError(null);
    startTransition(async () => {
      const res = await fetch(`/api/v1/team/days/${who.userId}/${date}/corrections`, {
        method: "POST",
        headers: { "content-type": "application/json", "x-cma-request": "1" },
        body: JSON.stringify({ reason: reason.trim(), changes: checked.changes }),
      });
      if (res.ok) {
        onSaved();
        return;
      }
      setSaveError(
        res.status === 403 ? t.notPermitted : res.status === 404 ? t.notFound : res.status === 409 ? t.conflict : t.saveFailed,
      );
    });
  }

  function openPicked() {
    const p = choosable.find((x) => x.userId === pickUser);
    if (!p || !date) return;
    const w = { userId: p.userId, displayName: p.displayName, timeZone: p.timeZone };
    setWho(w);
    setStep("loading");
    fetchDay(w, date);
  }

  const rowProblem: Record<RowProblem, string> = {
    time: t.problemTime, gap: t.problemGap, ambiguous: t.problemAmbiguous, future: t.problemFuture, status: t.problemStatus,
  };
  const dayProblem: Record<DayProblem, string> = {
    empty: t.problemEmpty, firstIsEnd: t.problemFirstIsEnd, twoEnds: t.problemTwoEnds,
    endNotLast: t.problemEndNotLast, noChange: t.problemNoChange,
  };
  const startId = checked?.rows.find((r) => r.kind === "start")?.id;
  const hasHistory = events.some((e) => !e.isEffective || e.source !== "user");

  return (
    <dialog
      ref={ref}
      aria-labelledby="day-editor-title"
      onCancel={(e) => {
        e.preventDefault();
        if (pending) return;
        if (dirty && !armed) setArmed(true);
        else onClose();
      }}
      onKeyDown={(e) => {
        if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
          e.preventDefault();
          save();
        }
      }}
      className="m-auto max-h-[88vh] w-[52rem] overflow-y-auto rounded-card border border-p4a-border bg-white p-6 text-p4a-body shadow-[0_1px_2px_rgba(11,19,61,0.06)] backdrop:bg-p4a-inkt/30"
    >
      <h2 id="day-editor-title" className="text-panel font-semibold text-p4a-heading">
        {target.mode === "add" ? t.addTitle : t.correctTitle}
        {who && step !== "pick" ? (
          <span className="ml-3 text-small font-normal text-p4a-muted">
            {who.displayName} · {fmtDate(date, locale)}
          </span>
        ) : null}
      </h2>

      {step === "pick" ? (
        <form
          className="mt-4"
          onSubmit={(e) => {
            e.preventDefault();
            openPicked();
          }}
        >
          <p className="text-body">{t.addIntro}</p>
          <div className="mt-4 flex items-end gap-4">
            <label className="flex flex-col gap-2 text-small font-semibold">
              {t.person}
              <select required autoFocus value={pickUser} onChange={(e) => setPickUser(e.target.value)} className={`${field} min-w-64`}>
                <option value="" disabled>
                  {t.choosePerson}
                </option>
                {choosable.map((p) => (
                  <option key={p.userId} value={p.userId}>
                    {p.displayName} · {p.organisationName}
                  </option>
                ))}
              </select>
            </label>
            <label className="flex flex-col gap-2 text-small font-semibold">
              {t.date}
              <input type="date" required max={today} value={date} onChange={(e) => setDate(e.target.value)} className={field} />
            </label>
          </div>
          <div className="mt-6 flex gap-3">
            <Button type="submit" variant="primary" disabled={!pickUser || !date} shortcut="Enter">
              {t.open}
            </Button>
            <Button variant="outlined" onClick={onClose} shortcut="Esc">
              {t.cancel}
            </Button>
          </div>
        </form>
      ) : null}

      {step === "loading" ? <p className="mt-4 text-body text-p4a-muted">{t.loading}</p> : null}

      {step === "error" ? (
        <div className="mt-4 flex flex-col gap-4">
          <Notice tone="warning">{t.loadFailed}</Notice>
          <div>
            <Button variant="outlined" onClick={onClose} shortcut="Esc">
              {t.cancel}
            </Button>
          </div>
        </div>
      ) : null}

      {step === "edit" && who && checked ? (
        <div className="mt-4">
          <p className="text-caption text-p4a-grey">
            {t.timesIn} {who.timeZone}
          </p>
          {target.mode === "add" ? (
            <div className="mt-3">
              <Notice tone="info">{existed ? t.existingDay : t.newDay}</Notice>
            </div>
          ) : null}

          <table className="mt-4 w-full border-collapse text-body">
            <thead>
              <tr className="bg-p4a-bgblue text-left text-small font-semibold text-p4a-heading">
                <th className="h-10 w-28 px-3 font-semibold" aria-label={t.startLabel} />
                <th className="h-10 px-3 font-semibold">{t.time}</th>
                <th className="h-10 px-3 font-semibold">{t.status}</th>
                <th className="h-10 px-3" aria-label={t.remove} />
              </tr>
            </thead>
            <tbody>
              {rows.map((r, i) => {
                const problem = checked.rowProblems[r.id];
                const twice = checked.ambiguous[r.id];
                return (
                  <tr key={r.id} className="border-b border-p4a-border align-top">
                    <td className="px-3 py-2">{r.id === startId ? <Badge tone="info">{t.startLabel}</Badge> : null}</td>
                    <td className="px-3 py-2">
                      <div className="flex gap-2">
                        <input
                          type="text"
                          inputMode="numeric"
                          placeholder="hh:mm"
                          maxLength={5}
                          aria-label={t.time}
                          value={r.time}
                          autoFocus={i === 0}
                          onChange={(e) => update(r.id, { time: e.target.value })}
                          onBlur={(e) => update(r.id, { time: normalizeTime(e.target.value) })}
                          className={`${field} tabular w-24`}
                          aria-invalid={problem ? true : undefined}
                        />
                        {twice ? (
                          <select
                            aria-label={t.time}
                            value={r.offset ?? ""}
                            onChange={(e) => update(r.id, { offset: e.target.value })}
                            className={field}
                          >
                            <option value="" disabled>
                              …
                            </option>
                            {twice.map((o, k) => (
                              <option key={o.offset} value={o.offset}>
                                {k === 0 ? t.firstTime : t.secondTime} ({o.offset})
                              </option>
                            ))}
                          </select>
                        ) : null}
                      </div>
                      {problem ? <p className="mt-1 text-small text-p4a-error">{rowProblem[problem]}</p> : null}
                    </td>
                    <td className="px-3 py-2">
                      <select
                        aria-label={t.status}
                        value={r.end ? "end" : r.statusKey ? `s:${r.statusKey}` : ""}
                        onChange={(e) =>
                          update(r.id, e.target.value === "end"
                            ? { end: true, statusKey: null }
                            : { end: false, statusKey: e.target.value.slice(2) })
                        }
                        className={`${field} min-w-48`}
                      >
                        {statuses.map((s) => (
                          <option key={s.key} value={`s:${s.key}`}>
                            {s.name}
                          </option>
                        ))}
                        <option value="end">{t.clockedOut}</option>
                      </select>
                    </td>
                    <td className="px-3 py-2 text-right">
                      <Button variant="text" size="sm" onClick={() => { setArmed(false); setRows((rs) => rs.filter((x) => x.id !== r.id)); }}>
                        {t.remove}
                      </Button>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>

          <div className="mt-3">
            <Button variant="outlined" size="sm" onClick={addRow}>
              {t.addRow}
            </Button>
          </div>

          {checked.dayProblems.length ? (
            <div className="mt-4">
              <Notice tone={checked.dayProblems.includes("noChange") ? "info" : "warning"}>
                {checked.dayProblems.map((p) => dayProblem[p]).join(". ")}
              </Notice>
            </div>
          ) : null}

          <label className="mt-6 flex flex-col gap-2 text-small font-semibold">
            {t.reason}
            <textarea
              value={reason}
              onChange={(e) => { setArmed(false); setReason(e.target.value); }}
              maxLength={500}
              rows={2}
              required
              className="rounded-input border border-p4a-border bg-white px-3 py-2 font-normal text-body text-p4a-body focus:border-p4a-deepblue"
            />
            <span className="font-normal text-caption text-p4a-grey">
              {t.reasonHint} <span className="tabular">{reason.trim().length}/500</span>
            </span>
          </label>
          {reason.trim() !== "" && !reasonOk ? <p className="mt-1 text-small text-p4a-error">{t.problemReason}</p> : null}

          {hasHistory ? (
            <details className="mt-6" open>
              <summary className="cursor-pointer text-small font-semibold text-p4a-heading">{t.history}</summary>
              <ul className="mt-2 flex flex-col gap-1 text-small">
                {events.map((e) => (
                  <li key={e.id} className={e.isEffective ? "" : "text-p4a-muted"}>
                    <span className={`tabular ${e.isEffective || e.kind === "void" ? "" : "line-through"}`}>
                      {e.kind === "void" ? "" : `${localParts(e.at, who.timeZone).time} · ${e.kind === "end" ? t.clockedOut : e.statusName ?? ""}`}
                    </span>
                    {e.kind === "void" ? t.cancelledRow : null}
                    {" · "}
                    {e.source === "correction"
                      ? `${t.byCorrection} ${e.approvedByName ?? ""}, ${fmtDate(localParts(e.recordedAt, who.timeZone).date, locale, "short")}: ${e.reason ?? ""}`
                      : e.source === "system" ? t.bySystem : t.byPerson}
                    {!e.isEffective && e.kind !== "void" ? ` · ${t.replaced}` : null}
                  </li>
                ))}
              </ul>
            </details>
          ) : null}

          {armed ? (
            <div className="mt-4">
              <Notice tone="warning">{t.unsaved}</Notice>
            </div>
          ) : null}
          {saveError ? (
            <p role="alert" className="mt-4 text-small text-p4a-error">
              {saveError}
            </p>
          ) : null}

          <div className="mt-6 flex gap-3">
            <Button variant="primary" onClick={save} disabled={!canSave} shortcut="Ctrl Enter">
              {t.save}
            </Button>
            <Button variant="outlined" onClick={onClose} disabled={pending} shortcut="Esc">
              {t.cancel}
            </Button>
          </div>
        </div>
      ) : null}
    </dialog>
  );
}
