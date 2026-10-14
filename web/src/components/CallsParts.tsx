/**
 * Building blocks of Reports → Calls and Calls per agent (addition 0008j, brief B16): the grouping switch
 * (G), a tile with its change against the previous equal period, the calls per group as stacked bars
 * (inbound and outbound), the tags of the whole period as horizontal bars and the groups by tags as a
 * table. Server components, plain SVG and CSS, no chart library; the figures come from the data layer and
 * lib/reports arranges them. Colours per docs/style/Pulse4all-Style.md 7.7: inbound Deep Blue, outbound
 * Leaf Green (the series order), a counted tag Deep Blue, a tag that does not count Neutral, Other Light
 * Blue; every mark carries its label or a title, and no text sits on a Light Blue bar (7.8). A volume's
 * change against the previous period is neither good nor bad, so it is Muted with an arrow, never Leaf
 * Green or the error red (7.7 colours a delta only when its direction has a meaning). Counts, seconds,
 * line and tag names only: no number, no customer name, no call id, never the hash.
 */
import Link from "next/link";
import type { ReactNode } from "react";
import type { Copy, Locale } from "@/lib/copy";
import type { CallsFigures, CallsGroup, CallsRow, TagUseRow } from "@/lib/data";
import {
  CALLS_GROUPS, callsBars, callsDelta, countAxis, fmtCount, fmtShare, INBOUND_CLASS, nextCallsGroup, OTHER_TAGS_CLASS, OUTBOUND_CLASS,
  TAG_CLASS, TAG_NOT_COUNTED_CLASS, tagTable, topTags, weekNumber,
} from "@/lib/reports";
import { fmtDate } from "@/lib/time";
import { HeaderHint } from "./HeaderHint";
import { Keycap } from "./primitives";

/** Day, week, market or line as links on the Calls report; G moves to the next one */
export function CallsGroupSwitch({ group, query, copy }: { group: CallsGroup; query: Record<string, string>; copy: Copy }) {
  const t = copy.calls;
  const labels: Record<CallsGroup, string> = { day: t.day, week: t.week, market: t.market, line: t.line };
  const next = nextCallsGroup(group);
  return (
    <div className="flex flex-col gap-2 text-small font-semibold">
      <span className="flex items-center gap-2">
        {t.groupBy} <Keycap>G</Keycap>
      </span>
      <nav aria-label={t.groupBy} className="flex gap-2">
        {CALLS_GROUPS.map((g) => (
          <Link
            key={g}
            href={{ pathname: "/reports/calls", query: { ...query, group: g } }}
            aria-current={g === group ? "page" : undefined}
            data-shortcut={g === next ? "g" : undefined}
            className={[
              "inline-flex h-10 items-center rounded-button border px-4 text-body font-semibold",
              g === group ? "border-p4a-deepblue bg-p4a-deepblue text-white" : "border-p4a-border text-p4a-deepblue hover:bg-p4a-bgblue",
            ].join(" ")}
          >
            {labels[g]}
          </Link>
        ))}
      </nav>
    </div>
  );
}

/** The previous equal period in words, for the deltas: one date, or from and to */
export function previousLabel(from: string, to: string, locale: Locale): string {
  return from === to ? fmtDate(from, locale, "short") : `${fmtDate(from, locale, "short")} – ${fmtDate(to, locale, "short")}`;
}

/** A figure's change against the previous equal period, in words with an arrow; Muted whatever its direction */
export function DeltaLine({ current, previous, previousText, copy, locale }: {
  current: number | null; previous: number | null; previousText: string; copy: Copy; locale: Locale;
}) {
  const t = copy.calls;
  const d = callsDelta(current, previous);
  const text = d.direction === "none" ? t.deltaNone
    : d.direction === "same" ? t.deltaSame
    : d.pct === null ? t.deltaNew
    : (d.direction === "up" ? t.deltaUp : t.deltaDown).replace("{pct}", fmtShare(d.pct / 100, locale));
  return (
    <p className="mt-1 text-small text-p4a-muted" data-testid="delta" data-direction={d.direction}>
      {text.replace("{previous}", previousText)}
    </p>
  );
}

/** A tile: the label with its hint, the figure, a detail line and, when given, the change against the previous period */
export function CallsTile({ label, value, detail, info, delta, testId }: {
  label: string; value: string; detail: ReactNode; info: { about: string; text: string }; delta?: ReactNode; testId: string;
}) {
  return (
    <div className="rounded-card border border-p4a-border bg-white p-5" data-tile="" data-testid={testId}>
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

/** A group's label in words: a date, a week number, a market (or unknown) or a line's name */
export function callsGroupLabel(row: Pick<CallsRow, "groupKey" | "groupLabel">, group: CallsGroup, copy: Copy, locale: Locale, short = false): string {
  switch (group) {
    case "day": return fmtDate(row.groupKey, locale, short ? "short" : "compact");
    case "week": return copy.calls.weekLabel.replace("{week}", String(weekNumber(row.groupKey)));
    case "market": return row.groupKey === "unknown" ? copy.reports.unknownMarket : row.groupKey;
    case "line": return row.groupLabel && row.groupLabel !== "unknown" ? row.groupLabel : copy.calls.unknownLine;
  }
}

/** The colours of the calls chart, with their labels */
export function CallsLegend({ copy }: { copy: Copy }) {
  const t = copy.calls;
  return (
    <ul className="mb-4 flex flex-wrap items-center gap-x-4 gap-y-2 text-caption text-p4a-grey" aria-label={t.legend} data-testid="calls-legend">
      <li className="flex items-center gap-2"><span aria-hidden="true" className={`inline-block h-2.5 w-2.5 rounded-full ${INBOUND_CLASS}`} />{t.legendInbound}</li>
      <li className="flex items-center gap-2"><span aria-hidden="true" className={`inline-block h-2.5 w-2.5 rounded-full ${OUTBOUND_CLASS}`} />{t.legendOutbound}</li>
    </ul>
  );
}

/**
 * Calls per group, inbound and outbound stacked: columns over the dates or weeks, horizontal bars for
 * markets and lines. Drawn in a fixed viewBox that scales with the card, gridlines Border Grey and axis
 * labels 12 units Footnote Grey (7.7)
 */
export function CallsChart({ rows, group, copy, locale }: { rows: CallsRow[]; group: CallsGroup; copy: Copy; locale: Locale }) {
  const t = copy.calls;
  const n = (x: number) => fmtCount(x, locale);
  const title = (r: CallsRow) => `${callsGroupLabel(r, group, copy, locale)}: ${n(r.inbound)} ${t.legendInbound.toLowerCase()}, ${n(r.outbound)} ${t.legendOutbound.toLowerCase()}`;
  if (group === "market" || group === "line") {
    const bars = callsBars(rows);
    return (
      <ul className="flex flex-col gap-2" aria-label={t[group === "market" ? "chartMarket" : "chartLine"]} data-testid="calls-chart">
        {rows.map((r, i) => (
          <li key={r.groupKey} className="grid grid-cols-[14rem_1fr_9rem] items-center gap-4 text-small" title={title(r)}>
            <span className="truncate font-semibold text-p4a-body">{callsGroupLabel(r, group, copy, locale)}</span>
            <span className="flex h-3 overflow-hidden rounded-full bg-p4a-neutral-surface">
              <span className={`h-3 ${INBOUND_CLASS}`} style={{ width: `${(bars[i]!.inbound * 100).toFixed(2)}%` }} />
              <span className={`h-3 ${OUTBOUND_CLASS}`} style={{ width: `${(bars[i]!.outbound * 100).toFixed(2)}%` }} />
            </span>
            <span className="tabular text-right text-p4a-muted">{n(r.inbound)} · {n(r.outbound)}</span>
          </li>
        ))}
      </ul>
    );
  }
  const W = 960;
  const H = 260;
  const m = { l: 44, r: 8, t: 12, b: 30 };
  const plotW = W - m.l - m.r;
  const plotH = H - m.t - m.b;
  const axis = countAxis(Math.max(0, ...rows.map((r) => r.calls)));
  const y = (count: number) => m.t + plotH - (count / axis.top) * plotH;
  const band = plotW / Math.max(1, rows.length);
  const barW = Math.min(44, band * 0.6);
  const labelEvery = Math.ceil(rows.length / 12);
  const ticks: number[] = [];
  for (let v = 0; v <= axis.top; v += axis.step) ticks.push(v);
  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="block h-auto w-full" role="img" aria-label={group === "day" ? t.chartDay : t.chartWeek} data-testid="calls-chart">
      {ticks.map((v) => (
        <g key={v}>
          <line x1={m.l} x2={W - m.r} y1={y(v)} y2={y(v)} fill="none" className="stroke-p4a-border" strokeWidth={1} />
          <text x={m.l - 8} y={y(v) + 4} textAnchor="end" fontSize={12} className="fill-p4a-grey tabular">{n(v)}</text>
        </g>
      ))}
      {rows.map((r, i) => {
        const x = m.l + i * band + (band - barW) / 2;
        return (
          <g key={r.groupKey}>
            <title>{title(r)}</title>
            {r.inbound > 0 ? <rect x={x} y={y(r.inbound)} width={barW} height={Math.max(0, y(0) - y(r.inbound))} className="fill-p4a-deepblue" /> : null}
            {r.outbound > 0 ? <rect x={x} y={y(r.calls)} width={barW} height={Math.max(0, y(r.inbound) - y(r.calls))} className="fill-p4a-green" /> : null}
            {i % labelEvery === 0 ? (
              <text x={m.l + i * band + band / 2} y={H - 10} textAnchor="middle" fontSize={12} className="fill-p4a-grey">
                {callsGroupLabel(r, group, copy, locale, rows.length > 7)}
              </text>
            ) : null}
          </g>
        );
      })}
    </svg>
  );
}

/** The whole period's tags as horizontal bars, largest first, the top twelve and Other; count and share of the conversations */
export function TagBars({ rows, conversations, copy, locale }: { rows: TagUseRow[]; conversations: number; copy: Copy; locale: Locale }) {
  const t = copy.calls;
  const { bars, other } = topTags(rows, conversations);
  const n = (x: number) => fmtCount(x, locale);
  const all = [...bars.map((b) => ({ ...b, label: b.name, className: b.isCounted ? TAG_CLASS : TAG_NOT_COUNTED_CLASS })),
    ...(other ? [{ ...other, label: t.other.replace("{n}", n(other.tags)), className: OTHER_TAGS_CLASS }] : [])];
  return (
    <ul className="flex flex-col gap-2" aria-label={t.tagBarsLabel} data-testid="tag-bars">
      {all.map((b) => (
        <li key={b.key} className="grid grid-cols-[16rem_1fr_9rem] items-center gap-4 text-small" title={`${b.label}: ${n(b.count)}`}>
          <span className="truncate text-p4a-body">
            <span className="font-semibold">{b.label}</span>
            {b.isCounted ? null : <span className="ml-2 text-caption text-p4a-muted">({t.notCounted})</span>}
          </span>
          <span className="h-3 rounded-full bg-p4a-neutral-surface">
            <span className={`block h-3 rounded-full ${b.className}`} style={{ width: `${(b.length * 100).toFixed(2)}%` }} />
          </span>
          <span className="tabular text-right text-p4a-muted">{n(b.count)} · {fmtShare(b.share, locale)}</span>
        </li>
      ))}
    </ul>
  );
}

/**
 * The groups by tags: the whole period's top twelve tags as columns, Other, then Untagged; counts with
 * their share of the row's conversations. Scrolls sideways inside its card where it is wider (1280 px)
 */
export function TagTable({ rows, groups, total, group, copy, locale }: {
  rows: TagUseRow[]; groups: CallsRow[]; total: CallsFigures; group: CallsGroup; copy: Copy; locale: Locale;
}) {
  const t = copy.calls;
  const h = copy.hints;
  // the columns are the whole period's top tags (as the bars above), the groups in the overview's order
  const table = tagTable(rows, groups);
  const whole = rows.filter((r) => r.groupKey === null);
  const shown = new Set(table.columns.map((c) => c.key));
  const of = (count: number) => ({ count, share: total.conversations === 0 ? null : count / total.conversations });
  const totalOf = (key: string | null) => of(whole.find((r) => r.tagKey === key)?.conversations ?? 0);
  const totalOther = of(whole.filter((r) => r.tagKey !== null && !shown.has(r.tagKey)).reduce((a, r) => a + r.conversations, 0));
  const otherLabel = t.other.replace("{n}", fmtCount(whole.filter((r) => r.tagKey !== null && !shown.has(r.tagKey)).length, locale));
  const hint = (label: string, text: string) => <HeaderHint label={h.about.replace("{label}", label)} text={text} />;
  const n = (x: number) => fmtCount(x, locale);
  const th = "h-10 whitespace-nowrap px-2 py-1 font-semibold";
  const td = "h-10 whitespace-nowrap px-2 tabular text-right";
  const groupHint: Record<CallsGroup, string> = { day: h.callsDay, week: h.callsWeek, market: h.callsMarket, line: h.callsLine };
  const groupTitle: Record<CallsGroup, string> = { day: t.day, week: t.week, market: t.market, line: t.line };
  const tableTitle: Record<CallsGroup, string> = { day: t.tagTableDay, week: t.tagTableWeek, market: t.tagTableMarket, line: t.tagTableLine };
  const cell = (c: { count: number; share: number | null }, key: string, bold = false) => (
    <td key={key} className={`${td} ${bold ? "font-semibold" : ""}`}>
      {n(c.count)} <span className="font-normal text-p4a-muted">· {fmtShare(c.share, locale)}</span>
    </td>
  );
  return (
    <div className="overflow-x-auto" data-testid="tag-table-scroll" role="region" aria-label={tableTitle[group]} tabIndex={0}>
      <table className="w-full border-collapse text-body leading-table" data-testid="tag-table">
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            <th className={th}>{groupTitle[group]}{hint(groupTitle[group], groupHint[group])}</th>
            <th className={`${th} text-right`}>{t.conversations}{hint(t.conversations, h.callsConversations)}</th>
            {table.columns.map((c) => (
              <th key={c.key} className={`${th} text-right`} data-tag={c.key}>
                {c.name}{hint(c.name, c.isCounted ? h.callsTag : h.callsTagNotCounted)}
              </th>
            ))}
            {table.hasOther ? <th className={`${th} text-right`}>{otherLabel}{hint(otherLabel, h.callsOther)}</th> : null}
            <th className={`${th} text-right`}>{t.untagged}{hint(t.untagged, h.callsUntagged)}</th>
          </tr>
        </thead>
        <tbody>
          {table.lines.map((l) => (
            <tr key={l.groupKey} className="border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50">
              <td className="h-10 whitespace-nowrap px-2 font-semibold">{callsGroupLabel(l, group, copy, locale)}</td>
              <td className={td}>{n(l.conversations)}</td>
              {l.cells.map((c, i) => cell(c, table.columns[i]!.key))}
              {table.hasOther ? cell(l.other, "other") : null}
              {cell(l.untagged, "untagged")}
            </tr>
          ))}
        </tbody>
        <tfoot>
          <tr className="text-p4a-body" data-testid="tag-table-total">
            <td className="h-10 whitespace-nowrap px-2 font-semibold">{copy.reports.total}</td>
            <td className={`${td} font-semibold`}>{n(total.conversations)}</td>
            {table.columns.map((c) => cell(totalOf(c.key), c.key, true))}
            {table.hasOther ? cell(totalOther, "other", true) : null}
            {cell(totalOf(null), "untagged", true)}
          </tr>
        </tfoot>
      </table>
    </div>
  );
}

/** The page's date line: the period, then the active filters in words (market, line by its name) */
export function CallsDateLine({ from, to, market, line, lines, copy, locale }: {
  from: string; to: string; market: string | null; line: string | null; lines: { key: string; name: string | null }[]; copy: Copy; locale: Locale;
}) {
  const t = copy.calls;
  const lineName = line === null ? null : lines.find((l) => l.key === line)?.name;
  const parts = [
    `${fmtDate(from, locale)}${from !== to ? ` – ${fmtDate(to, locale)}` : ""}`,
    ...(market ? [t.activeMarket.replace("{market}", market === "unknown" ? copy.reports.unknownMarket : market)] : []),
    ...(line ? [t.activeLine.replace("{line}", lineName && lineName !== "unknown" ? lineName : t.unknownLine)] : []),
  ];
  return <p className="text-caption text-p4a-grey" data-testid="calls-date-line">{parts.join(" · ")}</p>;
}
