/**
 * Building blocks of Customers → Active (addition 0009l, brief B35 with addendum A): the panel title with its hint and
 * its definition status, the link switches, the headline tiles with their change lines, the placeholder cards, the
 * markets table, the comparison of the two segments, the cohort heatmap, the customer list and the quiet data notes.
 * Server components, plain CSS; Pulse4all-Style 7.3 (cards), 7.5 (badges: the label is always there), 7.6 (tables:
 * numbers right-aligned in tabular figures, every header with its hint, the header row staying on top of its scroll
 * container) and 7.7 (a positive delta Leaf Green, a negative one Error, text only: a figure's change over time, never a
 * difference between two segments). Ids, codes, counts, dates, amounts and links only: never a customer's name, email, phone or
 * address.
 */
import Link from "next/link";
import type { Route } from "next";
import type { ReactNode } from "react";
import type { ActiveCopy, Copy as SharedCopy, Locale } from "@/lib/copy";
import type {
  ActiveCohort, ActiveComparisonRow, ActiveGrouping, ActiveList, ActiveMarketRow, ActiveMeasure, ActiveReport, ActiveSlotKey, ActiveSort,
} from "@/lib/data";
import { ACTIVE_SLOTS, changeAgainst, cohortLabel, cohortShare, counted, heatColour, signed, wholePercents } from "@/lib/active";
import { fmtCount, fmtPct, fmtShare } from "@/lib/reports";
import { fmtDate } from "@/lib/time";
import { Sparkline } from "./ActiveCharts";
import { LinkMark } from "./ActivePending";
import { fmtAmount, fmtNumber } from "./FlashParts";
import { HeaderHint } from "./HeaderHint";
import { HintLabel } from "./HintLabel";
import { RecordLink } from "./RecordLink";
import { StatusBadge } from "./StatusBadge";
import { Badge } from "./primitives";

/** The words these parts read: the shared ones with the page's own beside them (the page puts the two together; neither part hands it to a client component) */
export type ActivePageCopy = SharedCopy & { active: ActiveCopy };
type Copy = ActivePageCopy;
type T = ActiveCopy;
export type ActiveHref = (change: Record<string, string | null>) => { pathname: Route; query: Record<string, string> };

const th = "h-10 px-2 py-1 align-bottom font-semibold leading-tight";
const td = "h-10 whitespace-nowrap px-2 tabular text-right";
// the two widest tables (the markets, the customer list): the same cells with half the side padding, so their columns fit 1440 px (3 px a side; the first column keeps 8 px on its left)
const thD = "h-10 px-[3px] py-1 align-bottom font-semibold leading-tight";
const tdD = "h-10 whitespace-nowrap px-[3px] tabular text-right";
const row = "border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50";

/** A definition's status as a badge (components/StatusBadge, re-exported for the Active page's imports) */
export { StatusBadge };

/** A panel's title with the hint that holds its definition, its status badge and, for those who may open it, How this is computed */
export function PanelTitle({ label, hint, status = "Proposed", more, copy, children }: {
  label: string; hint: string; status?: "Proposed" | "Pending" | "Decided"; more?: { href: string; label: string }; copy: Copy; children?: ReactNode;
}) {
  return (
    <div className="mb-4 flex flex-wrap items-center gap-3" data-hint-anchor="" data-panel-title="">
      <h2 className="text-panel font-semibold text-p4a-heading">
        <HintLabel label={label}><HeaderHint label={copy.hints.about.replace("{label}", label)} text={hint} more={more} /></HintLabel>
      </h2>
      <StatusBadge status={status} copy={copy} />
      {children ? <div className="ml-auto flex flex-wrap items-center gap-4 print:hidden">{children}</div> : null}
    </div>
  );
}

/** A switch of links (a toggle with URL parameters, no script): the current option marked */
export function LinkSwitch<V extends string>({ label, options, current, href, testId }: {
  label: string; options: { value: V; label: string }[]; current: V; href: (value: V) => { pathname: Route; query: Record<string, string> }; testId: string;
}) {
  return (
    <div className="flex items-center gap-2 text-small font-semibold">
      <span className="text-p4a-muted">{label}</span>
      <nav aria-label={label} className="flex flex-wrap gap-1" data-testid={testId}>
        {options.map((o) => (
          <Link key={o.value} href={href(o.value)} prefetch={false} aria-current={o.value === current ? "page" : undefined} scroll={false}
            className={["inline-flex h-8 items-center rounded-button border px-3 font-semibold",
              o.value === current ? "border-p4a-deepblue bg-p4a-deepblue text-white" : "border-p4a-border text-p4a-deepblue hover:bg-p4a-bgblue"].join(" ")}>
            {o.label}<LinkMark />
          </Link>
        ))}
      </nav>
    </div>
  );
}

/** A month's end in words: "end of Oct 2026" */
export function monthEndText(month: string, locale: Locale, t: T): string {
  const d = new Date(Date.UTC(Number(month.slice(0, 4)), Number(month.slice(5, 7)) - 1, 1));
  return t.endOf.replace("{month}", new Intl.DateTimeFormat(locale === "nl" ? "nl-NL" : "en-GB", { month: "short", year: "numeric", timeZone: "UTC" }).format(d));
}

/**
 * A figure's change against an earlier month end: its sign and size in words, Leaf Green up and Error down where up is
 * the better direction, Muted otherwise; nothing at all where the history does not reach (never a zero)
 */
export function ChangeLine({ value, previous, when, fmt, better, t, testId }: {
  value: number | null; previous: number | null; when: string; fmt: (n: number) => string; better?: "up"; t: T; testId?: string;
}) {
  const c = changeAgainst(value, previous);
  if (c.direction === "none") return null;
  const tone = c.direction === "flat" || !better ? "text-p4a-muted" : c.direction === "up" ? "text-p4a-green" : "text-p4a-error";
  const text = c.direction === "flat" ? t.changeFlat.replace("{when}", when)
    : t.change.replace("{delta}", signed(fmt(Math.abs(c.delta ?? 0)), c.delta ?? 0)).replace("{when}", when);
  return <p className={`text-caption ${tone}`} data-testid={testId ?? "active-change"} data-direction={c.direction}>{text}</p>;
}

/** A headline tile: its label with the hint, the figure (or its lines), what stands under it and its change lines */
export function ActiveTile({ testId, label, info, value, children }: {
  testId: string; label: string; info: { about: string; text: string; more?: { href: string; label: string } }; value: ReactNode; children?: ReactNode;
}) {
  return (
    <div className="flex flex-col rounded-card border border-p4a-border bg-white p-5" data-tile="" data-testid={testId}>
      <p className="text-caption text-p4a-grey" data-hint-anchor="">
        <HintLabel label={label}><HeaderHint label={info.about} text={info.text} more={info.more} /></HintLabel>
      </p>
      <div className="tabular mt-1 text-title font-bold text-p4a-heading">{value}</div>
      <div className="mt-1 flex flex-col gap-1 text-small text-p4a-muted">{children}</div>
    </div>
  );
}

/**
 * A placeholder (decision D5): the slot of a figure the Workspace cannot compute yet. Its label, the neutral badge "Not
 * connected yet", what will feed it and its definition status Pending; never a number, a zero or a dash of its own.
 * related: a line under the badge for a figure that exists and belongs with the slot (the churned subscriptions of the
 * last 30 days under Churn rate, a link to Flash's overview): it sits apart from the placeholder's own words (data-related)
 */
export function PlaceholderCard({ slot, info, copy, related: given }: {
  slot: ActiveSlotKey; info: { about: string; text: string; more?: { href: string; label: string } }; copy: Copy; related?: ReactNode;
}) {
  const t = copy.active;
  const def = ACTIVE_SLOTS.find((s) => s.key === slot)!;
  // the one exception to "a placeholder shows no number" (decision D5; Martin, 12 November 2026): the Churn rate's card alone
  const related = slot === "churn_rate" ? given : undefined;
  return (
    <div className="flex flex-col gap-2 rounded-card border border-dashed border-p4a-border bg-white p-5" data-testid={`active-slot-${slot}`} data-placeholder="">
      <p className="text-caption text-p4a-grey" data-hint-anchor="">
        <HintLabel label={t[`slot_${slot}`]}><HeaderHint label={info.about} text={info.text} more={info.more} /></HintLabel>
      </p>
      <p><Badge tone="neutral">{t.notConnected}</Badge></p>
      {related ? <div className="text-small" data-related="">{related}</div> : null}
      <p className="text-small text-p4a-muted">{t.fedBy.replace("{sources}", def.fedBy.map((f) => t[`feed_${f}`]).join(t.listJoin))}</p>
      <p><StatusBadge status="Pending" copy={copy} /></p>
    </div>
  );
}

/** A quiet note above a panel: what the figures below leave out or cannot know, in words; never a figure of its own */
export function DataNote({ children, testId }: { children: ReactNode; testId: string }) {
  return <p className="mb-4 rounded-button border-l-4 border-p4a-border bg-p4a-offwhite px-4 py-2 text-small text-p4a-muted" role="note" data-testid={testId}>{children}</p>;
}

function hintOf(copy: Copy) {
  return function hint(label: string, text: string): ReactNode {
    return <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} />;
  };
}

/**
 * A table inside its scroll container (Pulse4all-Style 7.6): the container scrolls both ways inside the panel (it
 * shrinks to what the panel leaves it), and the header row stays at its top while the rows scroll under it
 */
function Scroll({ testId, label, children }: { testId: string; label: string; children: ReactNode }) {
  return (
    <div className="min-h-0 overflow-auto" data-testid={`${testId}-scroll`} role="region" aria-label={label} tabIndex={0}>
      <table className="w-full border-collapse text-body leading-table [&_thead_th]:sticky [&_thead_th]:top-0 [&_thead_th]:z-10 [&_thead_th]:bg-p4a-bgblue" data-testid={testId}>{children}</table>
    </div>
  );
}

/** A part of a split in whole percents: "< 1%" for a part that is there but rounds to nothing, never "0%" */
export function splitPercent(percent: number, part: number, locale: Locale): string {
  return fmtPct(percent === 0 && part > 0 ? 0.4 : percent, locale);
}

/** Amounts per currency, one line each: never one figure across currencies */
export function Amounts({ amounts, locale, pick }: { amounts: Record<string, number | { amount: number; average: number | null }>; locale: Locale; pick?: "amount" | "average" }) {
  const lines = Object.entries(amounts).sort(([a], [b]) => (a < b ? -1 : 1)).flatMap(([cur, v]) => {
    const n = typeof v === "number" ? v : pick === "average" ? v.average : v.amount;
    return n === null ? [] : [<span key={cur} data-currency={cur}>{fmtAmount(n, cur, locale)}</span>];
  });
  if (lines.length === 0) return <span className="text-p4a-muted">–</span>;
  return <span className="flex flex-col items-end">{lines}</span>;
}

export const MARKET_SORTS = ["customers", "share", "subscriptions", "devices", "medianAge", "churned30d", "net30d", "indirectShare", "market"] as const;
export type MarketSort = (typeof MARKET_SORTS)[number];

/** The markets in the chosen order: a column's value, the higher first when descending; the market's code breaks ties */
export function sortMarkets(rows: readonly ActiveMarketRow[], sort: MarketSort, descending: boolean): ActiveMarketRow[] {
  const value = (r: ActiveMarketRow): number | string | null => (sort === "market" ? r.market : r[sort]);
  return [...rows].sort((a, b) => {
    const x = value(a);
    const y = value(b);
    const c = x === null ? (y === null ? 0 : 1) : y === null ? -1 : (x < y ? -1 : x > y ? 1 : 0) * (descending ? -1 : 1);
    return c || (a.market < b.market ? -1 : 1);
  });
}

/**
 * The markets, one row each, with the totals row the database computed. Every counted column sorts through its header's
 * link; a market's code links to the page filtered on it
 */
export function MarketsTable({ rows, total, sort, descending, href, hints, copy, locale, segments }: {
  rows: ActiveMarketRow[]; total: NonNullable<ActiveReport["marketsTotal"]>; sort: MarketSort; descending: boolean; href: ActiveHref;
  hints: Record<string, string>; copy: Copy; locale: Locale; segments: string[];
}) {
  const t = copy.active;
  const hint = hintOf(copy);
  const n = (x: number) => fmtCount(x, locale);
  // a header: a short label that may break over two lines (in these narrow columns the info mark may stand under the
  // label's last word); its hint is named with the column's full name
  const head = (label: string, text: string, key?: MarketSort, full = label) => {
    const current = key !== undefined && key === sort;
    const next = current && descending ? "asc" : "desc";
    return (
      <th className={`${thD} ${key === "market" ? "" : "text-right"}`} aria-sort={current ? (descending ? "descending" : "ascending") : undefined} data-full={full}>
        <HintLabel label={key ? (
          <Link href={href({ msort: key, mdir: next })} prefetch={false} scroll={false} className="whitespace-normal underline-offset-2 hover:underline" data-testid={`active-msort-${key}`}
            title={t.sortBy.replace("{column}", full)}>{label}{current ? (descending ? " ↓" : " ↑") : ""}<LinkMark /></Link>
        ) : label}>{hint(full, text)}</HintLabel>
      </th>
    );
  };
  const segCols = [...segments, "unknown"];
  // the markets' shares of the base in whole percents that add up to 100 (largest remainder), whatever the order shown
  // (the database's shares, rounded together)
  const shares = new Map(wholePercents(rows.map((r) => r.share ?? 0)).map((p, i) => [rows[i]!.market, p]));
  const delta = (x: number) => (
    <span className={x > 0 ? "text-p4a-green" : x < 0 ? "text-p4a-error" : "text-p4a-muted"}>{x === 0 ? "0" : signed(n(Math.abs(x)), x)}</span>
  );
  const line = (r: ActiveMarketRow | (NonNullable<ActiveReport["marketsTotal"]> & { market?: undefined; spark?: undefined }), isTotal: boolean) => (
    <tr key={isTotal ? "total" : r.market} className={isTotal ? "border-t-2 border-p4a-deepblue bg-p4a-bgblue font-semibold" : row} data-testid={isTotal ? "active-market-total" : "active-market-row"}>
      <td className="h-10 whitespace-nowrap px-[3px] pl-2 font-semibold">
        {isTotal ? t.total : (
          <Link href={href({ market: r.market!, msort: null, mdir: null, after: null, before: null, page: null })} prefetch={false} className="text-p4a-deepblue underline-offset-2 hover:underline" title={t.filterOnMarket.replace("{market}", r.market!)}>
            {r.market === "unknown" ? copy.reports.unknownMarket : r.market}<LinkMark />
          </Link>
        )}
      </td>
      <td className={tdD}>{n(r.customers)}</td>
      <td className={tdD}>{isTotal ? fmtShare(r.share, locale) : splitPercent(shares.get(r.market!) ?? 0, r.customers, locale)}</td>
      {segCols.map((s) => <td key={s} className={tdD}>{n(r.bySegment[s] ?? 0)}</td>)}
      <td className={tdD}>{n(r.subscriptions)}</td>
      <td className={tdD}>{n(r.devices)}</td>
      <td className={tdD}><Amounts amounts={r.amounts} locale={locale} pick="amount" /></td>
      <td className={tdD}><Amounts amounts={r.amounts} locale={locale} pick="average" /></td>
      <td className={tdD}>{r.medianAge === null ? "–" : fmtNumber(r.medianAge, locale, 1)}</td>
      <td className={tdD}><Amounts amounts={Object.fromEntries(Object.entries(r.clv).map(([c, v]) => [c, v.average]))} locale={locale} /></td>
      <td className={tdD}>{n(r.churned30d)}</td>
      <td className={tdD} data-testid="active-net">{delta(r.net30d)}</td>
      <td className={tdD} title={t.knownChannel.replace("{n}", n(r.indirect + r.direct))}>{r.indirectShare === null ? "–" : fmtShare(r.indirectShare, locale)}</td>
      <td className="h-10 px-[3px] text-right">
        {isTotal || !r.spark ? null : <Sparkline width={64} values={r.spark} title={t.sparkTitle.replace("{first}", n(r.spark[0] ?? 0)).replace("{last}", n(r.spark[r.spark.length - 1] ?? 0))} />}
      </td>
    </tr>
  );
  return (
    <Scroll testId="active-markets" label={t.marketsCard}>
      <thead>
        <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
          {head(t.colMarket, hints.mh_col_market!, "market")}
          {head(t.shortCustomers, hints.mh_active_customers!, "customers", t.activeCustomers)}
          {head(t.colShare, hints.mh_col_share!, "share")}
          {/* a segment's header: its info mark may stand under the word, as under the sortable headers of this narrow table */}
          {segCols.map((s) => <th key={s} className={`${thD} text-right`}>{s === "unknown" ? t.unknownSegment : s} {hint(s === "unknown" ? t.unknownSegment : s, hints.mh_col_segment!)}</th>)}
          {head(t.shortSubscriptions, hints.mh_total_subscriptions!, "subscriptions", t.totalSubscriptions)}
          {head(t.colDevices, hints.mh_col_devices!, "devices")}
          {head(t.shortMonthlyAmount, hints.mh_monthly_amount!, undefined, t.monthlyAmount)}
          {head(t.shortAverageAmount, hints.mh_average_amount!, undefined, t.averageAmount)}
          {head(t.shortMedianAge, hints.mh_customer_age!, "medianAge", t.medianAge)}
          {head(t.shortClvAverage, hints.mh_clv_realised!, undefined, t.clvAverage)}
          {head(t.shortChurned30d, hints.mh_churned_30d!, "churned30d", t.churned30d)}
          {head(t.shortNet30d, hints.mh_net_30d!, "net30d", t.net30d)}
          {head(t.shortIndirectShare, hints.mh_indirect_share!, "indirectShare", t.indirectShare)}
          {head(t.colTrend, hints.mh_col_trend!)}
        </tr>
      </thead>
      <tbody>
        {rows.map((r) => line(r, false))}
        {line(total, true)}
      </tbody>
    </Scroll>
  );
}

/** A comparison value in its unit: a count, a share, months, an amount in its currency, a ratio per customer */
export function measureText(measure: ActiveMeasure, value: number, currency: string | null, locale: Locale, t: T): string {
  switch (measure) {
    case "customers": return fmtCount(value, locale);
    case "share": case "retention": case "indirect_share": return fmtShare(value, locale);
    case "lifetime_median": return counted(t.monthsValue, value, fmtNumber(value, locale, 0));
    case "median_age": return counted(t.monthsValue, Number(value.toFixed(1)), fmtNumber(value, locale, 1));
    case "clv_average": case "clv_median": case "clv_per_month": case "average_monthly_amount": return currency ? fmtAmount(value, currency, locale) : fmtNumber(value, locale, 2);
    default: return fmtNumber(value, locale, 2);
  }
}

/** A difference in the measure's unit: shares in percentage points, the rest as the measure itself */
function differenceText(measure: ActiveMeasure, value: number, currency: string | null, locale: Locale, t: T): string {
  const abs = Math.abs(value);
  const text = measure === "share" || measure === "retention" || measure === "indirect_share"
    ? counted(t.pointsValue, Math.round(abs * 1000) / 10, fmtNumber(abs * 100, locale, 1))
    : measureText(measure, abs, currency, locale, t);
  return value === 0 ? text : signed(text, value);
}

/**
 * The first two segments side by side (decision D12): one row per measure, the difference (the first less the second) and
 * the ratio, the unknown segment beside them and never in the difference. Between two segments there is no better or
 * worse: every difference and ratio stands in Inkt with its sign (Martin, 12 November 2026); a currency one side lacks
 * leaves its cell empty with the reason in its title
 */
export function ComparisonTable({ comparison, hints, copy, locale }: { comparison: NonNullable<ActiveReport["comparison"]>; hints: Record<string, string>; copy: Copy; locale: Locale }) {
  const t = copy.active;
  const hint = hintOf(copy);
  const a = comparison.a ?? "–";
  const b = comparison.b ?? "–";
  const label = (r: ActiveComparisonRow) => {
    const base = r.measure === "retention" ? counted(t.m_retention, r.months ?? 0) : t[`m_${r.measure}`];
    return r.currency ? `${base} (${r.currency})` : base;
  };
  // the share of the base is a split over the two segments and the unknown one: whole percents that add up to 100
  const baseShares = (r: ActiveComparisonRow) => wholePercents([r.a ?? 0, r.b ?? 0, r.unknown ?? 0]);
  const cell = (r: ActiveComparisonRow, value: number | null, longest: number | null, side: string, part?: 0 | 1 | 2) => {
    if (value !== null && r.measure === "share" && part !== undefined) return <td className={td} data-split="">{splitPercent(baseShares(r)[part]!, value, locale)}</td>;
    if (value !== null) return <td className={td}>{measureText(r.measure, value, r.currency, locale, t)}</td>;
    if (r.measure === "lifetime_median" && longest !== null) {
      return <td className={`${td} text-p4a-muted`} title={`${t.notReachedShort}. ${t.notReachedTitle}`} data-not-reached="">{counted(t.moreThanMonths, longest)}</td>;
    }
    const why = r.currency ? t.noCustomersInCurrency.replace("{segment}", side) : r.measure === "retention" ? t.noSpellThatOld : t.noValue;
    return <td className={`${td} text-p4a-muted`} title={why} data-empty="">{r.currency ? "" : "–"}</td>;
  };
  return (
    <Scroll testId="active-comparison" label={t.comparisonCard}>
      <thead>
        <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
          <th className={th}><HintLabel label={t.colMeasure}>{hint(t.colMeasure, hints.mh_col_measure!)}</HintLabel></th>
          <th className={`${th} text-right`}><HintLabel label={a}>{hint(a, hints.mh_col_segment!)}</HintLabel></th>
          <th className={`${th} text-right`}><HintLabel label={b}>{hint(b, hints.mh_col_segment!)}</HintLabel></th>
          <th className={`${th} text-right`}><HintLabel label={t.colDifference.replace("{a}", a).replace("{b}", b)}>{hint(t.colDifference.replace("{a}", a).replace("{b}", b), hints.mh_col_difference!)}</HintLabel></th>
          <th className={`${th} text-right`}><HintLabel label={t.colRatio.replace("{a}", a).replace("{b}", b)}>{hint(t.colRatio.replace("{a}", a).replace("{b}", b), hints.mh_col_ratio!)}</HintLabel></th>
          <th className={`${th} text-right`}><HintLabel label={t.unknownSegmentCol}>{hint(t.unknownSegmentCol, hints.mh_col_unknown_segment!)}</HintLabel></th>
        </tr>
      </thead>
      <tbody>
        {comparison.rows.map((r) => (
          <tr key={`${r.measure}|${r.months ?? ""}|${r.currency ?? ""}`} className={row} data-testid="active-comparison-row" data-measure={r.measure}>
            <td className="h-10 px-2 font-semibold">{label(r)}</td>
            {cell(r, r.a, r.aLongest, a, 0)}
            {cell(r, r.b, r.bLongest, b, 1)}
            <td className={`${td} text-p4a-inkt`} data-difference="">
              {r.difference === null ? "" : differenceText(r.measure, r.difference, r.currency, locale, t)}
            </td>
            <td className={`${td} text-p4a-inkt`}>{r.ratio === null ? "" : t.ratioValue.replace("{n}", fmtNumber(r.ratio, locale, 2))}</td>
            {cell(r, r.unknown, r.unknownLongest, t.unknownSegment, 2)}
          </tr>
        ))}
        <tr className={row} data-testid="active-comparison-row" data-measure="clv_projected" data-placeholder="">
          <td className="h-10 px-2 font-semibold">{t.slot_clv_projected}</td>
          <td className="h-10 px-2 text-right" colSpan={5}>
            <span className="inline-flex items-center gap-2"><Badge tone="neutral">{t.notConnected}</Badge><StatusBadge status="Pending" copy={copy} /></span>
          </td>
        </tr>
      </tbody>
    </Scroll>
  );
}

/**
 * The customer cohorts as a heatmap table: the cohort, its size and, per age, the share still active with the count in
 * the cell's title, on one continuous scale of one blue hue by the share's value (lib/active heatColour: Inkt text on
 * the light part, white only from Denim on); a dash with its reason where the cohort is not Mature at the age. A small
 * legend under the table shows the scale from 0 % to 100 %
 */
export function CohortHeatmap({ cohorts, ages, grouping, hints, copy, locale }: {
  cohorts: ActiveCohort[]; ages: number[]; grouping: ActiveGrouping; hints: Record<string, string>; copy: Copy; locale: Locale;
}) {
  const t = copy.active;
  const hint = hintOf(copy);
  return (
    <>
    <Scroll testId="active-cohorts" label={t.cohortsCard}>
      <thead>
        <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
          <th className={th}><HintLabel label={t.colCohort}>{hint(t.colCohort, hints.mh_cohort!)}</HintLabel></th>
          <th className={`${th} text-right`}><HintLabel label={t.colStarted}>{hint(t.colStarted, hints.mh_col_started!)}</HintLabel></th>
          {ages.map((a) => (
            <th key={a} className={`${th} text-right`}><HintLabel label={counted(t.monthsValue, a)}>{hint(counted(t.monthsValue, a), hints.mh_col_cohort_age!)}</HintLabel></th>
          ))}
        </tr>
      </thead>
      <tbody>
        {cohorts.map((c) => (
          <tr key={c.cohort} className="border-b border-p4a-border" data-testid="active-cohort-row" data-cohort={c.cohort}>
            <td className="h-10 whitespace-nowrap px-2 font-semibold">{cohortLabel(c.cohort, grouping, locale)}</td>
            <td className={td}>{fmtCount(c.started, locale)}</td>
            {c.ages.map((a) => {
              const share = cohortShare(c, a);
              const heat = heatColour(share);
              if (share === null || heat === null) {
                return <td key={a.age} className={`${td} text-p4a-muted`} title={t.notMature} data-mature="false">–</td>;
              }
              return (
                <td key={a.age} className={`${td} ${heat.text === "white" ? "text-white" : "text-p4a-inkt"}`} style={{ backgroundColor: heat.background }} data-mature="true" data-heat={heat.percent}
                  title={t.cohortCellTitle.replace("{n}", fmtCount(a.stillActive, locale)).replace("{started}", fmtCount(c.started, locale))}>
                  {fmtShare(share, locale)} <span className="font-normal">({fmtCount(a.stillActive, locale)})</span>
                </td>
              );
            })}
          </tr>
        ))}
      </tbody>
    </Scroll>
    <div className="mt-3 flex shrink-0 items-center gap-2 text-caption text-p4a-grey" data-testid="active-heat-legend" role="img" aria-label={t.heatLegend}>
      <span className="tabular">{fmtShare(0, locale)}</span>
      <span className="flex h-3 w-64 overflow-hidden rounded-sm border border-p4a-border" aria-hidden="true">
        {Array.from({ length: 21 }, (_, i) => <span key={i} className="h-full flex-1" data-heat-swatch="" style={{ backgroundColor: heatColour(i / 20)!.background }} />)}
      </span>
      <span className="tabular">{fmtShare(1, locale)}</span>
      <span>{t.heatLegend}</span>
    </div>
    </>
  );
}

/** The list's columns that sort, by their header */
const LIST_SORT: Partial<Record<string, ActiveSort>> = {
  colStoreCustomer: "store_customer", colStore: "store", colMarket: "market", colSegment: "segment", colCustomerStart: "customer_start", customerAge: "age_months",
  totalSubscriptions: "subscriptions", colDevices: "devices", monthlyAmount: "monthly_amount", clvRealised: "clv", channel: "channel", colAcquired: "level",
};

/**
 * The active customers, a page of them, sorted and paged by the database: the store's id of the customer, codes, dates,
 * amounts, the worst payment state and the CRM contact's link. No name, email, phone or address exists to show
 */
export function CustomerList({ list, sort, descending, page, pageSize, href, hints, copy, locale }: {
  list: ActiveList; sort: ActiveSort; descending: boolean; page: number; pageSize: number; href: ActiveHref; hints: Record<string, string>; copy: Copy; locale: Locale;
}) {
  const t = copy.active;
  const hint = hintOf(copy);
  const n = (x: number) => fmtCount(x, locale);
  // a header: a short label where the column's name is long (it may break over two lines); the hint is named with the full name
  const sortLink = (key: keyof T & string, short?: string): ReactNode => {
    const s = LIST_SORT[key];
    const full = t[key] as string;
    const label = short ?? full;
    const current = s !== undefined && s === sort;
    return s ? (
      <Link href={href({ sort: s, dir: current && descending ? "asc" : "desc", after: null, before: null, page: null })} prefetch={false} scroll={false} className="whitespace-normal underline-offset-2 hover:underline"
        data-testid={`active-sort-${s}`} title={t.sortBy.replace("{column}", full)}>{label}{current ? (descending ? " ↓" : " ↑") : ""}<LinkMark /></Link>
    ) : label;
  };
  // under: a second figure that shares the column (the Customer age under the Customer start), with its own sort link;
  // the header keeps one info mark, whose text explains both
  const head = (key: keyof T & string, text: string, right = true, short?: string, under?: { key: keyof T & string; text: string }) => {
    const sorted = [key, under?.key].map((k) => (k ? LIST_SORT[k] : undefined)).find((k) => k !== undefined && k === sort);
    return (
      <th className={`${thD} ${right ? "text-right" : ""}`} aria-sort={sorted ? (descending ? "descending" : "ascending") : undefined} data-full={t[key] as string}>
        <HintLabel label={sortLink(key, short)}>{hint(t[key] as string, under ? `${text} ${t[under.key] as string}: ${under.text}` : text)}</HintLabel>
        {under ? <span className="block font-normal" data-under={t[under.key] as string}>{sortLink(under.key)}</span> : null}
      </th>
    );
  };
  // keyset paging: the page's ends are cursors (next, prev); the page's number rides along in the address for these words only
  const total = list.total ?? 0;
  const pages = Math.max(1, Math.ceil(total / pageSize));
  const first = total === 0 ? 0 : (page - 1) * pageSize + 1;
  const payment: Record<string, "success" | "warning" | "error" | "neutral"> = { paid: "success", in_retry: "warning", failed: "error", paused: "neutral" };
  return (
    <div className="flex min-h-0 flex-col gap-4">
      <Scroll testId="active-list" label={t.listCard}>
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            {head("colStoreCustomer", hints.mh_col_store_customer!, false)}
            {head("colStore", hints.mh_col_store!, false)}
            {head("colMarket", hints.mh_col_market!, false)}
            {head("colSegment", hints.mh_col_segment!, false)}
            {head("colCustomerStart", hints.mh_customer_start!, true, undefined, { key: "customerAge", text: hints.mh_customer_age! })}
            {head("totalSubscriptions", hints.mh_total_subscriptions!, true, t.shortSubscriptions)}
            {head("colDevices", hints.mh_col_devices!)}
            {head("monthlyAmount", hints.mh_monthly_amount!, true, t.shortMonthlyAmount)}
            {head("clvRealised", hints.mh_clv_realised!, true, t.shortClvRealised)}
            {head("channel", hints.mh_channel!, false, undefined, { key: "colAcquired", text: hints.mh_col_acquired! })}
            {head("colPaymentState", hints.mh_col_payment_state!, false)}
            {head("colContact", hints.mh_col_contact!, false)}
          </tr>
        </thead>
        <tbody>
          {list.rows.map((r) => (
            <tr key={`${r.store}|${r.storeCustomer}`} className={row} data-testid="active-list-row">
              <td className="h-10 whitespace-nowrap px-[3px] pl-2 tabular">{r.storeCustomer}</td>
              <td className="h-10 whitespace-nowrap px-[3px]">{r.store}</td>
              <td className="h-10 whitespace-nowrap px-[3px]">{r.market === "unknown" ? copy.reports.unknownMarket : r.market}</td>
              <td className="h-10 whitespace-nowrap px-[3px]">{r.segment === "unknown" ? t.unknownSegment : r.segment}</td>
              <td className={`${tdD} leading-tight`}>
                <span className="block" data-testid="active-list-start">{r.customerStart ? fmtDate(r.customerStart, locale, "medium") : "–"}</span>
                <span className="block text-caption text-p4a-muted" data-testid="active-list-age">{r.ageMonths === null ? "–" : counted(t.monthsValue, r.ageMonths, n(r.ageMonths))}</span>
              </td>
              <td className={tdD}>{n(r.subscriptions)}</td>
              <td className={tdD}>{n(r.devices)}</td>
              <td className={tdD}>
                {r.monthlyAmount !== null && r.currency ? (
                  <span className="flex flex-col items-end">
                    <span>{fmtAmount(r.monthlyAmount, r.currency, locale)}</span>
                    {Object.entries(r.otherAmounts).map(([c, v]) => <span key={c}>{fmtAmount(v, c, locale)}</span>)}
                  </span>
                ) : <span className="text-p4a-muted" title={t.noPayingAmount}>–</span>}
              </td>
              <td className={tdD}>{r.clv !== null && r.clvCurrency ? fmtAmount(r.clv, r.clvCurrency, locale) : "–"}</td>
              {/* Direct / Indirect, with the level the first order was acquired through as its code; First orders' label on hover */}
              <td className="h-10 whitespace-nowrap px-[3px] leading-tight" data-testid="active-list-channel">
                <span className="block">{t[`channelShort_${r.channel}`]}</span>
                {r.level ? <span className="block text-caption text-p4a-muted" title={`${t.colAcquired}: ${(copy.firstOrders as Record<string, string>)[`level_${r.level}`] ?? r.level}`} data-level={r.level}>{r.level}</span>
                  : <span className="sr-only">{t.noLevel}</span>}
              </td>
              <td className="h-10 whitespace-nowrap px-[3px]">
                {r.paymentState ? <Badge tone={payment[r.paymentState] ?? "neutral"}>{(t as Record<string, string>)[`pay_${r.paymentState}`] ?? r.paymentState}</Badge> : "–"}
              </td>
              <td className="h-10 px-[3px]"><RecordLink url={r.contactUrl} label={t.openContact.replace("{id}", r.contactId ?? "")} /></td>
            </tr>
          ))}
        </tbody>
      </Scroll>
      <div className="flex flex-wrap items-center justify-between gap-4 text-small" data-testid="active-pager">
        <p className="text-p4a-muted">
          {t.listRange.replace("{first}", n(first)).replace("{last}", n(Math.min(total, first + list.rows.length - 1))).replace("{total}", n(total))}
        </p>
        <nav aria-label={t.listCard} className="flex items-center gap-2 print:hidden">
          {list.prev
            ? <Link href={href({ before: list.prev, after: null, page: page > 2 ? String(page - 1) : null })} prefetch={false} scroll={false} className="inline-flex h-8 items-center rounded-button border border-p4a-border px-3 font-semibold text-p4a-deepblue hover:bg-p4a-bgblue" data-testid="active-prev">{t.previousPage}<LinkMark /></Link>
            : null}
          <span className="tabular text-p4a-muted">{t.pageOf.replace("{page}", n(page)).replace("{pages}", n(pages))}</span>
          {list.next
            ? <Link href={href({ after: list.next, before: null, page: String(page + 1) })} prefetch={false} scroll={false} className="inline-flex h-8 items-center rounded-button border border-p4a-border px-3 font-semibold text-p4a-deepblue hover:bg-p4a-bgblue" data-testid="active-next">{t.nextPage}<LinkMark /></Link>
            : null}
        </nav>
      </div>
    </div>
  );
}
