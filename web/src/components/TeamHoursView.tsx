"use client";

/**
 * The interactive part of Team hours: the person filter, Add day, the table and the day editor.
 * Rows arrive formatted from the server (each in its own zone); this component only navigates and
 * opens the editor. Keyboard: P focuses the person filter, A opens Add day, Down or Up anywhere on
 * the page enters the table, arrows move between the Correct buttons, Enter opens one, and closing
 * the editor returns focus to the row it came from.
 */
import { useEffect, useRef, useState, type KeyboardEvent as ReactKeyboardEvent } from "react";
import type { Route } from "next";
import { useRouter } from "next/navigation";
import type { Copy, Locale } from "@/lib/copy";
import type { DateKey, TeamPerson, WorkStatus } from "@/lib/data";
import { Badge, Button, Keycap } from "./primitives";
import { DayEditor, type EditorTarget } from "./DayEditor";

export interface HoursRow {
  key: string;
  userId: string;
  displayName: string;
  organisationName: string;
  date: DateKey;
  dateLabel: string;
  timeZone: string;
  inLabel: string;
  outLabel: string | null;
  /** Short zone name when the day's zone differs from the viewer's */
  zoneLabel: string | null;
  workedLabel: string;
  paidLabel: string;
  chips: { tone: "info" | "warning" | "neutral"; label: string }[];
  own: boolean;
}

export function TeamHoursView({
  rows,
  totals,
  people,
  person,
  query,
  meId,
  today,
  statuses,
  copy,
  locale,
}: {
  rows: HoursRow[];
  totals: { worked: string; paid: string };
  people: TeamPerson[];
  /** The person filter, or "" for everyone */
  person: string;
  /** The period part of the query string, kept when the filter changes */
  query: Record<string, string>;
  meId: string;
  today: DateKey;
  statuses: WorkStatus[];
  copy: Copy;
  locale: Locale;
}) {
  const t = copy.teamHours;
  const router = useRouter();
  const [target, setTarget] = useState<EditorTarget | null>(null);
  const [opened, setOpened] = useState(0);
  const body = useRef<HTMLTableSectionElement>(null);
  /** The button that opened the editor, so focus can return to that row */
  const opener = useRef<HTMLElement | null>(null);

  // Down or Up outside the table (not while typing, not in a dialog) enters it, like S on My day
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if ((e.key !== "ArrowDown" && e.key !== "ArrowUp") || e.ctrlKey || e.metaKey || e.altKey) return;
      if (document.querySelector("dialog[open]")) return;
      const active = document.activeElement as HTMLElement | null;
      if (active && (["INPUT", "SELECT", "TEXTAREA"].includes(active.tagName) || active.isContentEditable)) return;
      const tbody = body.current;
      if (!tbody || (active && tbody.contains(active))) return;
      const buttons = Array.from(tbody.querySelectorAll<HTMLButtonElement>("button:not([disabled])"));
      const first = e.key === "ArrowDown" ? buttons[0] : buttons[buttons.length - 1];
      if (!first) return;
      e.preventDefault();
      first.focus();
    }
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);

  function open(next: EditorTarget) {
    opener.current = document.activeElement as HTMLElement | null;
    setOpened((n) => n + 1);
    setTarget(next);
  }

  function close() {
    setTarget(null);
    // After the dialog has gone, back to the row (or the Add day button) it came from
    requestAnimationFrame(() => opener.current?.focus());
  }

  function filter(userId: string) {
    const qs = new URLSearchParams({ ...query, ...(userId ? { person: userId } : {}) });
    router.push(`/team/hours?${qs.toString()}` as Route);
  }

  /** Arrow keys move between the Correct buttons, like the status buttons on My day */
  function move(e: ReactKeyboardEvent<HTMLTableSectionElement>) {
    if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
    const buttons = Array.from(e.currentTarget.querySelectorAll<HTMLButtonElement>("button:not([disabled])"));
    const i = buttons.indexOf(document.activeElement as HTMLButtonElement);
    if (i < 0) return;
    e.preventDefault();
    buttons[e.key === "ArrowDown" ? Math.min(buttons.length - 1, i + 1) : Math.max(0, i - 1)]?.focus();
  }

  const th = "h-10 whitespace-nowrap px-3 font-semibold";
  return (
    <>
      <div className="mb-4 flex items-end justify-between gap-4">
        <label className="flex flex-col gap-2 text-small font-semibold">
          <span className="flex items-center gap-2">
            {t.person} <Keycap>P</Keycap>
          </span>
          <select
            value={person}
            data-shortcut="p"
            onChange={(e) => filter(e.target.value)}
            className="h-10 min-w-64 rounded-input border border-p4a-border bg-white px-3 font-normal text-body text-p4a-body focus:border-p4a-deepblue"
          >
            <option value="">{t.everyone}</option>
            {people.map((p) => (
              <option key={p.userId} value={p.userId}>
                {p.displayName} · {p.organisationName}
              </option>
            ))}
          </select>
        </label>
        <Button variant="primary" shortcut="A" data-shortcut="a" onClick={() => open({ mode: "add" })}>
          {t.addDay}
        </Button>
      </div>

      {rows.length === 0 ? (
        <p className="text-body text-p4a-muted">{t.empty}</p>
      ) : (
        <table className="w-full border-collapse text-body">
          <thead>
            <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
              <th className={th}>{t.date}</th>
              <th className={th}>{t.person}</th>
              <th className={th}>{t.employer}</th>
              <th className={`${th} text-right`}>{t.clockedIn}</th>
              <th className={`${th} text-right`}>{t.clockedOut}</th>
              <th className={`${th} text-right`}>{t.worked}</th>
              <th className={`${th} text-right`}>{t.paid}</th>
              <th className={th}>{t.notes}</th>
              <th className={th} aria-label={t.correct} />
            </tr>
          </thead>
          <tbody ref={body} onKeyDown={move}>
            {rows.map((r) => (
              <tr
                key={r.key}
                className="h-10 border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50 focus-within:bg-p4a-bgblue"
              >
                <td className="whitespace-nowrap px-3">{r.dateLabel}</td>
                <td className="whitespace-nowrap px-3">{r.displayName}</td>
                <td className="whitespace-nowrap px-3 text-p4a-muted">{r.organisationName}</td>
                <td className="tabular whitespace-nowrap px-3 text-right">
                  {r.inLabel}
                  {r.zoneLabel ? <span className="ml-1 text-caption text-p4a-grey">{r.zoneLabel}</span> : null}
                </td>
                <td className="tabular whitespace-nowrap px-3 text-right">{r.outLabel ?? ""}</td>
                <td className="tabular whitespace-nowrap px-3 text-right">{r.workedLabel}</td>
                <td className="tabular whitespace-nowrap px-3 text-right">{r.paidLabel}</td>
                <td className="px-3">
                  <span className="flex flex-wrap gap-1 whitespace-nowrap">
                    {r.chips.map((c) => (
                      <Badge key={c.label} tone={c.tone}>
                        {c.label}
                      </Badge>
                    ))}
                  </span>
                </td>
                <td className="px-3 py-1 text-right">
                  <Button
                    variant="outlined"
                    size="sm"
                    disabled={r.own}
                    title={r.own ? t.ownDay : undefined}
                    onClick={() =>
                      open({ mode: "correct", userId: r.userId, displayName: r.displayName, date: r.date, timeZone: r.timeZone })
                    }
                  >
                    {t.correct}
                  </Button>
                </td>
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr className="h-10 font-semibold">
              <td className="px-3" colSpan={5}>
                {t.total}
              </td>
              <td className="tabular px-3 text-right">{totals.worked}</td>
              <td className="tabular px-3 text-right">{totals.paid}</td>
              <td colSpan={2} />
            </tr>
          </tfoot>
        </table>
      )}
      {rows.length > 0 ? <p className="mt-3 text-caption text-p4a-grey">{t.keysHint}</p> : null}

      {target ? (
        <DayEditor
          key={opened}
          target={target}
          people={people}
          meId={meId}
          today={today}
          statuses={statuses}
          copy={copy}
          locale={locale}
          onClose={close}
          onSaved={() => {
            close();
            router.refresh();
          }}
        />
      ) : null}
    </>
  );
}
