"use client";

/**
 * The Planned hours meter at the top of the planner, in Week and Day view (Martin, 26 November 2026, point 9): the week's
 * planned hours of the roster on screen and, in Day view, the day's, each as a number and a bar against the hours on
 * shift. Planned counts the blocks of kind work (an extra type included) and a shift without any block whole; a pause
 * never (lib/assignments, plannedSummary, D12). "Per assignment" opens the split: one row per assignment type and hours
 * market with its hours and a bar in the type's colour (D13), the shifts without assignments, and the pauses on their own
 * lines, which do not add to the total.
 *
 * Computed in the browser from the week the planner already holds (the blocks of cma.roster_assignments, the same rule
 * as cma.roster_planned_hours): no read of its own. The colour never carries meaning alone: each row names its code.
 */
import { memo, useState } from "react";
import type { AssignmentType } from "@/lib/data";
import { pct, toneOf, TONE_CLASS, type PlannedSummary } from "@/lib/assignments";
import { fmtMinutes } from "@/lib/time";

export interface MeterWords {
  title: string;
  hint: string;
  week: string;
  day: string;
  of: string;
  perAssignment: string;
  dayLevel: string;
  pauses: string;
  pausesHint: string;
  noMarket: string;
  nothing: string;
}

/** Memoised: the planner re-renders on every key in a cell and every drag step; the meter only when its figures change */
export const PlannedMeter = memo(function PlannedMeter({ week, day, types, words }: {
  week: PlannedSummary;
  /** The Day view's date; none in Week view */
  day?: PlannedSummary;
  types: readonly AssignmentType[];
  words: MeterWords;
}) {
  const [open, setOpen] = useState(false);
  const typeOf = new Map(types.map((t) => [t.code, t]));
  const order = new Map(types.map((t, i) => [t.code, i]));
  const keys = [...new Set([...week.byKey.keys(), ...(day?.byKey.keys() ?? [])])]
    .sort((a, b) => (order.get(a.split("/")[0]!) ?? 999) - (order.get(b.split("/")[0]!) ?? 999) || a.localeCompare(b));
  const pauses = [...new Set([...week.pauses.keys(), ...(day?.pauses.keys() ?? [])])].sort((a, b) => (order.get(a) ?? 999) - (order.get(b) ?? 999));
  const scale = Math.max(1, week.planned);
  const label = (k: string) => { const [c, m] = k.split("/"); return `${c} ${m || words.noMarket}`; };
  const meter = (name: string, s: PlannedSummary, testId: string) => (
    <div className="flex min-w-64 flex-col gap-2" data-testid={testId}>
      <div className="flex items-baseline gap-3">
        <span className="text-small font-semibold text-p4a-body">{name}</span>
        <span className="tabular text-panel font-semibold text-p4a-heading">{fmtMinutes(s.planned)}</span>
        <span className="tabular text-small text-p4a-grey">{words.of.replace("{n}", fmtMinutes(s.onShift))}</span>
      </div>
      <div className="relative h-2 w-full overflow-hidden rounded-button bg-p4a-neutral-surface" role="meter" aria-label={name}
        aria-valuemin={0} aria-valuemax={s.onShift} aria-valuenow={s.planned} aria-valuetext={`${fmtMinutes(s.planned)} ${words.of.replace("{n}", fmtMinutes(s.onShift))}`}>
        <span className="absolute inset-y-0 left-0 bg-p4a-deepblue" style={{ width: `${s.onShift > 0 ? Math.min(100, pct(s.planned, s.onShift)) : 0}%` }} />
      </div>
    </div>
  );
  const row = (key: string, name: string, title: string | undefined, tone: string, w: number, d: number | undefined, counts: boolean) => (
    <tr key={key} className="h-10 border-b border-p4a-border">
      <td className="px-3" title={title}>
        <span className="flex items-center gap-2">
          <span aria-hidden="true" className={`h-3 w-3 shrink-0 rounded-button ${tone}`} />
          <span className="font-semibold">{name}</span>
        </span>
      </td>
      {day ? <td className="tabular px-3 text-right">{d ? fmtMinutes(d) : ""}</td> : null}
      <td className="tabular px-3 text-right">{fmtMinutes(w)}</td>
      <td className="w-64 px-3">
        {counts ? (
          <span className="relative block h-2 overflow-hidden rounded-button bg-p4a-neutral-surface">
            <span className={`absolute inset-y-0 left-0 ${tone}`} style={{ width: `${Math.min(100, pct(w, scale))}%` }} />
          </span>
        ) : null}
      </td>
    </tr>
  );
  return (
    <section className="rounded-card border border-p4a-border bg-white p-6" data-testid="planned-meter">
      <div className="flex flex-wrap items-end gap-8">
        <h2 className="text-panel font-semibold text-p4a-heading" title={words.hint}>{words.title}</h2>
        {meter(words.week, week, "planned-meter-week")}
        {day ? meter(words.day, day, "planned-meter-day") : null}
        <button type="button" aria-expanded={open} onClick={() => setOpen((x) => !x)} data-testid="planned-meter-toggle"
          className="ml-auto inline-flex h-10 items-center gap-2 rounded-button border border-p4a-deepblue px-4 font-semibold text-p4a-deepblue hover:bg-p4a-bgblue">
          {words.perAssignment}
          <span aria-hidden="true">{open ? "▴" : "▾"}</span>
        </button>
      </div>
      {open ? (
        keys.length === 0 && pauses.length === 0 && week.dayLevel === 0 ? <p className="mt-4 text-body text-p4a-muted">{words.nothing}</p> : (
          <table className="mt-4 border-collapse text-body" data-testid="planned-meter-split">
            <thead className="bg-p4a-bgblue text-small text-p4a-heading">
              <tr>
                <th className="h-10 px-3 text-left font-semibold">{words.perAssignment}</th>
                {day ? <th className="h-10 px-3 text-right font-semibold">{words.day}</th> : null}
                <th className="h-10 px-3 text-right font-semibold">{words.week}</th>
                <th className="h-10 px-3" />
              </tr>
            </thead>
            <tbody>
              {keys.map((k) => {
                const t = typeOf.get(k.split("/")[0]!);
                return row(k, label(k), t?.name, TONE_CLASS[t ? toneOf(t) : "productive"], week.byKey.get(k) ?? 0, day?.byKey.get(k), true);
              })}
              {week.dayLevel > 0 ? row("day-level", words.dayLevel, undefined, "bg-p4a-lightblue", week.dayLevel, day?.dayLevel, true) : null}
              {pauses.length > 0 ? (
                <tr className="h-10 border-b border-p4a-border text-small text-p4a-muted">
                  <td className="px-3 font-semibold" colSpan={day ? 4 : 3} title={words.pausesHint}>{words.pauses} · {words.pausesHint}</td>
                </tr>
              ) : null}
              {pauses.map((c) => {
                const t = typeOf.get(c);
                return row(`pause-${c}`, `${c}`, t?.name, TONE_CLASS[t ? toneOf(t) : "pause"], week.pauses.get(c) ?? 0, day?.pauses.get(c), false);
              })}
            </tbody>
          </table>
        )
      ) : null}
    </section>
  );
});
