/**
 * The server parts of Sales → Speed to lead's cockpit (addition 0009zr, brief B40b; mockup approved 24 November 2026):
 * the six tiles with their change against the previous period, the per-market card (two stacked bars per market, a row
 * sets the market filter), the trend per day or week with the goals as dashed lines and the weekends shaded (the shared
 * LineChart, no chart library), and the Group by table. Every figure is the database's (cma.speed_to_lead_page); nothing
 * is computed here but the drawing. Pulse4all-Style 7.7: Deep Blue for within the target, Leaf Green for before the
 * cutoff, Light Blue and Border Grey for the rest; a tile's goal colours its surface (success at or above, error below).
 */
import Link from "next/link";
import type { Route } from "next";
import type { ReactNode } from "react";
import type { Locale } from "@/lib/copy";
import type { SpeedToLeadGroup, SpeedToLeadSummaryRow } from "@/lib/data";
import { fmtBusinessMinutes, fmtCount, fmtPct, goalTone, groupDisplay } from "@/lib/reports";
import { fmtAttempts } from "@/lib/attempts";
import { fmtDate } from "@/lib/time";
import { Legend, LineChart } from "./ActiveCharts";
import { HeaderHint } from "./HeaderHint";
import { HintLabel } from "./HintLabel";

export interface Info { about: string; text: string }

/** A tile: the label with its hint, the figure, a detail line and the change; with a goal, the surface says whether it is met */
export function SpeedTile({ label, value, detail, info, delta, testId, pct = null, goal = null }: {
  label: string; value: string; detail: ReactNode; info: Info; delta?: ReactNode; testId: string;
  /** The share the goal is held against, and the goal (whole percent); without a goal the tile is white */
  pct?: number | null; goal?: number | null;
}) {
  const tone = goalTone(pct, goal);
  const surface = tone === "met" ? "border-p4a-success bg-p4a-success-surface" : tone === "below" ? "border-p4a-error bg-p4a-error-surface" : "border-p4a-border bg-white";
  return (
    <div className={`rounded-card border p-5 ${surface}`} data-tile="" data-testid={testId} data-goal={tone}>
      <p className="flex items-start text-caption text-p4a-grey" data-hint-anchor="">
        {label}
        <HeaderHint label={info.about} text={info.text} />
      </p>
      <p className="tabular mt-1 text-title font-bold text-p4a-heading">{value}</p>
      <p className="mt-1 text-small text-p4a-muted">{detail}</p>
      {delta}
    </div>
  );
}

/** A share of 0 to 100 as a bar's width in percent of the deals whose outcome is known */
const width = (pct: number | null) => `${pct === null ? 0 : Math.max(0, Math.min(100, pct))}%`;

/** Two stacked bars: within or after the target, before or after the cutoff; the share written beside each */
function MarketBars({ row, words, locale }: { row: SpeedToLeadSummaryRow; words: { aria: string }; locale: Locale }) {
  return (
    <div className="flex flex-col gap-1" role="img" aria-label={words.aria} data-testid="speed-market-bars">
      {[{ pct: row.withinTargetPct, on: "bg-p4a-deepblue", off: "bg-p4a-lightblue" }, { pct: row.beforeNextNoonPct, on: "bg-p4a-green", off: "bg-p4a-border" }].map((b, i) => (
        <div key={i} className="flex items-center gap-2">
          <div className="flex h-3 w-full overflow-hidden rounded-sm bg-p4a-neutral-surface">
            {b.pct !== null ? (
              <>
                <span className={`h-full ${b.on}`} style={{ width: width(b.pct) }} />
                <span className={`h-full ${b.off}`} style={{ width: width(100 - b.pct) }} />
              </>
            ) : null}
          </div>
          <span className="tabular w-12 shrink-0 text-right text-caption text-p4a-grey">{fmtPct(b.pct, locale)}</span>
        </div>
      ))}
    </div>
  );
}

/** Per market: its bars and figures; a row's market sets the page's market filter */
export function MarketCard({ rows, market, hrefOf, headers, words, locale }: {
  rows: SpeedToLeadSummaryRow[];
  market: string;
  hrefOf: (market: string) => string;
  headers: { label: string; info: Info; right?: boolean }[];
  words: { title: string; legend: { key: string; label: string; colour: number; className: string }[]; legendLabel: string; note: string;
    unknown: string; filter: string; barsAria: string };
  locale: Locale;
}) {
  const n = (x: number) => fmtCount(x, locale);
  const th = "h-10 px-3 py-1 font-semibold";
  const td = "h-12 whitespace-nowrap px-3";
  return (
    <section className="rounded-card border border-p4a-border bg-white p-6" aria-labelledby="speed-markets-title" data-testid="speed-markets">
      <div className="mb-4 flex flex-wrap items-center justify-between gap-4">
        <h2 id="speed-markets-title" className="text-h3 font-bold text-p4a-heading">{words.title}</h2>
        <Legend items={words.legend.map((l) => ({ ...l, bar: true }))} label={words.legendLabel} />
      </div>
      <table className="w-full border-collapse text-body">
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            {headers.map((h) => (
              <th key={h.label} className={`${th} ${h.right ? "text-right" : ""}`}>
                <HintLabel label={h.label}><HeaderHint label={h.info.about} text={h.info.text} /></HintLabel>
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => {
            const label = r.groupKey === "unknown" ? words.unknown : r.groupKey;
            const on = r.groupKey === market;
            return (
              <tr key={r.groupKey} className={`border-b border-p4a-border ${on ? "bg-p4a-bgblue" : ""}`} data-market={r.groupKey}>
                <td className={`${td} font-semibold`}>
                  <Link href={hrefOf(on ? "" : r.groupKey) as Route} scroll={false} aria-current={on ? "true" : undefined}
                    title={words.filter.replace("{market}", label)} className="text-p4a-deepblue underline-offset-2 hover:underline">{label}</Link>
                </td>
                <td className={`${td} tabular text-right`}>{n(r.deals)}</td>
                <td className="w-1/4 min-w-48 px-3"><MarketBars row={r} words={{ aria: words.barsAria.replace("{market}", label)
                  .replace("{within}", fmtPct(r.withinTargetPct, locale)).replace("{before}", fmtPct(r.beforeNextNoonPct, locale)) }} locale={locale} /></td>
                <td className={`${td} tabular text-right`}>{fmtBusinessMinutes(r.medianBusinessMinutes, locale)}</td>
                <td className={`${td} tabular text-right`}>{n(r.openNotCalled)}</td>
                <td className={`${td} tabular text-right`}>{n(r.closedBeforeFirstCall)}</td>
                <td className={`${td} tabular text-right`}>{fmtAttempts(r.attemptsMean, locale)}</td>
                <td className={`${td} tabular text-right`}>{fmtPct(r.conversationShare, locale)}</td>
              </tr>
            );
          })}
        </tbody>
      </table>
      <p className="mt-4 max-w-3xl text-caption text-p4a-grey">{words.note}</p>
    </section>
  );
}

/**
 * The trend: within the target and before the cutoff per day (per week over 31 days) as two lines over the period's
 * days or weeks, the goals dashed when set, weekends shaded on the days' axis
 */
export function TrendCard({ rows, group, from, to, goals, words, locale }: {
  rows: SpeedToLeadSummaryRow[]; group: "day" | "week"; from: string; to: string;
  goals: { withinTarget: number | null; beforeCutoff: number | null };
  words: { title: string; within: string; before: string; goalWithin: string; goalBefore: string; weekend: string; share: string; empty: string; legendLabel: string };
  locale: Locale;
}) {
  // the x axis: every day (or every week's Monday) of the period, so a day without deals stays a gap in time
  const keys: string[] = [];
  for (let d = group === "week" ? mondayOf(from) : from; d <= to; d = addDaysKey(d, group === "week" ? 7 : 1)) keys.push(d);
  const at = new Map(keys.map((k, i) => [k, i]));
  const point = (r: SpeedToLeadSummaryRow, pct: number | null) =>
    pct === null || !at.has(r.groupKey) ? [] : [{ x: at.get(r.groupKey)!, y: pct / 100, title: `${fmtDate(r.groupKey, locale, "compact")} · ${fmtPct(pct, locale)}` }];
  const series = [
    { key: "within", label: words.within, colour: 0, points: rows.flatMap((r) => point(r, r.withinTargetPct)) },
    { key: "before", label: words.before, colour: 1, points: rows.flatMap((r) => point(r, r.beforeNextNoonPct)) },
  ];
  const step = Math.max(1, Math.ceil(keys.length / 12));
  const xLabels = keys.map((k, i) => ({ x: i, text: fmtDate(k, locale, "compact") })).filter((_, i) => i % step === 0);
  const bands = group === "day"
    ? keys.flatMap((k, i) => (isWeekend(k) ? [{ from: i - 0.5, to: i + 0.5, title: `${words.weekend} · ${fmtDate(k, locale, "compact")}` }] : []))
    : [];
  const refLines = [
    ...(goals.withinTarget !== null ? [{ y: goals.withinTarget / 100, text: words.goalWithin, colour: 0 }] : []),
    ...(goals.beforeCutoff !== null ? [{ y: goals.beforeCutoff / 100, text: words.goalBefore, colour: 1 }] : []),
  ];
  const legend = [
    { key: "within", label: words.within, colour: 0 },
    { key: "before", label: words.before, colour: 1 },
    ...(refLines.length > 0 ? refLines.map((r) => ({ key: `goal-${r.colour}`, label: r.text, colour: r.colour, dashed: true })) : []),
    ...(bands.length > 0 ? [{ key: "weekend", label: words.weekend, colour: 0, bar: true, className: "bg-p4a-neutral-surface border border-p4a-border" }] : []),
  ];
  return (
    <section className="rounded-card border border-p4a-border bg-white p-6" aria-labelledby="speed-trend-title" data-testid="speed-trend" data-group={group}>
      <div className="mb-4 flex flex-wrap items-center justify-between gap-4">
        <h2 id="speed-trend-title" className="text-h3 font-bold text-p4a-heading">{words.title}</h2>
        <Legend items={legend} label={words.legendLabel} />
      </div>
      {rows.length === 0 ? <p className="text-body text-p4a-muted">{words.empty}</p> : (
        <LineChart series={series} xLabels={xLabels} yFormat={(v) => fmtPct(Math.round(v * 100), locale)} yTop={1} yLabel={words.share}
          label={words.title} testId="speed-trend-chart" refLines={refLines} bands={bands} height={240} />
      )}
    </section>
  );
}

const DAY = 86_400_000;
const addDaysKey = (k: string, n: number) => new Date(Date.parse(`${k}T00:00:00Z`) + n * DAY).toISOString().slice(0, 10);
const dowOf = (k: string) => new Date(`${k}T00:00:00Z`).getUTCDay();
const isWeekend = (k: string) => dowOf(k) === 0 || dowOf(k) === 6;
const mondayOf = (k: string) => addDaysKey(k, dowOf(k) === 0 ? -6 : 1 - dowOf(k));

/** The Group by table: the summary's groups with the cockpit's two new columns; No attempt yet shows – for its shares */
export function GroupTable({ rows, group, label, headers, totals, totalLabel, totalNote, locale }: {
  rows: SpeedToLeadSummaryRow[]; group: SpeedToLeadGroup; label: (row: SpeedToLeadSummaryRow) => string;
  headers: { label: string; info: Info; right?: boolean }[];
  totals: { deals: number; called: number; openNotCalled: number; closedBeforeFirstCall: number };
  totalLabel: string; totalNote: string; locale: Locale;
}) {
  const n = (x: number) => fmtCount(x, locale);
  const th = "h-10 px-3 py-1 font-semibold";
  const td = "h-10 whitespace-nowrap px-3";
  return (
    <table className="w-full border-collapse text-body" data-testid="speed-summary" data-group={group}>
      <thead>
        <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
          {headers.map((h) => (
            <th key={h.label} className={`${th} ${h.right ? "text-right" : ""}`}>
              <HintLabel label={h.label}><HeaderHint label={h.info.about} text={h.info.text} /></HintLabel>
            </th>
          ))}
        </tr>
      </thead>
      <tbody>
        {rows.map((x) => (
          <tr key={x.groupKey} className="border-b border-p4a-border" data-group-key={x.groupKey}>
            <td className={`${td} font-semibold`}>{label(x)}</td>
            <td className={`${td} tabular text-right`}>{n(x.deals)}</td>
            <td className={`${td} tabular text-right`}>{n(x.called)}</td>
            <td className={`${td} tabular text-right`}>{fmtBusinessMinutes(x.medianBusinessMinutes, locale)}</td>
            <td className={`${td} tabular text-right`}>{fmtPct(x.withinTargetPct, locale)}</td>
            <td className={`${td} tabular text-right`}>{fmtPct(x.beforeNextNoonPct, locale)}</td>
            <td className={`${td} tabular text-right`}>{n(x.openNotCalled)}</td>
            <td className={`${td} tabular text-right`}>{n(x.closedBeforeFirstCall)}</td>
            <td className={`${td} tabular text-right`}>{fmtAttempts(x.attemptsMean, locale)}</td>
            <td className={`${td} tabular text-right`}>{fmtPct(x.conversationShare, locale)}</td>
          </tr>
        ))}
      </tbody>
      <tfoot>
        <tr className="font-semibold text-p4a-heading" title={totalNote}>
          <td className={td}>{totalLabel}</td>
          <td className={`${td} tabular text-right`}>{n(totals.deals)}</td>
          <td className={`${td} tabular text-right`}>{n(totals.called)}</td>
          <td className={`${td} text-right text-p4a-muted`} colSpan={3}><span className="sr-only">{totalNote}</span></td>
          <td className={`${td} tabular text-right`}>{n(totals.openNotCalled)}</td>
          <td className={`${td} tabular text-right`}>{n(totals.closedBeforeFirstCall)}</td>
          <td className={td} colSpan={2} />
        </tr>
      </tfoot>
    </table>
  );
}

/** A summary row's group in words, as the page shows it: a date (a week by its Monday), a market, a person, a pipeline */
export function speedGroupLabel(row: SpeedToLeadSummaryRow, group: SpeedToLeadGroup, words: { notMapped: string; noAttempt: string; unknownMarket: string; unknownPipeline: string }, locale: Locale): string {
  const d = groupDisplay(row, group);
  switch (d.kind) {
    case "date": return fmtDate(d.date, locale, "compact");
    case "text": return d.text;
    case "notMapped": return words.notMapped;
    case "noAttempt": return words.noAttempt;
    case "unknownMarket": return words.unknownMarket;
    case "unknownPipeline": return words.unknownPipeline;
  }
}
