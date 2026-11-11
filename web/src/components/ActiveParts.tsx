/**
 * Building blocks of Customers → Active (addition 0009l, brief B35 with addendum A): the panel title with its hint and
 * its definition status, the link switches, the headline tiles with their change lines, the placeholder cards, the
 * markets table, the comparison of the two segments, the cohort heatmap, the customer list and the quiet data notes.
 * Server components, plain CSS; Pulse4all-Style 7.3 (cards), 7.5 (badges: the label is always there), 7.6 (tables:
 * numbers right-aligned in tabular figures, every header with its hint) and 7.7 (a positive delta Leaf Green, a negative
 * one Error, text only). Ids, codes, counts, dates, amounts and links only: never a customer's name, email, phone or
 * address.
 */
import Link from "next/link";
import type { Route } from "next";
import type { ReactNode } from "react";
import type { ActiveCopy, Copy as SharedCopy, Locale } from "@/lib/copy";
import type {
  ActiveCohort, ActiveComparisonRow, ActiveGrouping, ActiveList, ActiveMarketRow, ActiveMeasure, ActiveReport, ActiveSlotKey, ActiveSort,
} from "@/lib/data";
import { ACTIVE_SLOTS, changeAgainst, cohortLabel, cohortShare, differenceTone, heatStep, signed } from "@/lib/active";
import { fmtCount, fmtShare } from "@/lib/reports";
import { fmtDate } from "@/lib/time";
import { Sparkline } from "./ActiveCharts";
import { fmtAmount, fmtNumber } from "./FlashParts";
import { HeaderHint } from "./HeaderHint";
import { HintLabel } from "./HintLabel";
import { RecordLink } from "./RecordLink";
import { Badge } from "./primitives";

/** The words these parts read: the shared ones with the page's own beside them (the page puts the two together; neither part hands it to a client component) */
export type ActivePageCopy = SharedCopy & { active: ActiveCopy };
type Copy = ActivePageCopy;
type T = ActiveCopy;
export type ActiveHref = (change: Record<string, string | null>) => { pathname: Route; query: Record<string, string> };

const th = "h-10 px-2 py-1 align-bottom font-semibold";
const td = "h-10 whitespace-nowrap px-2 tabular text-right";
const row = "border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50";

/** A definition's status as a badge: Proposed (for Kira to confirm) or Pending (an open question, named in the hint) */
export function StatusBadge({ status, copy }: { status: "Proposed" | "Pending" | "Decided"; copy: Copy }) {
  return <Badge tone={status === "Decided" ? "success" : status === "Proposed" ? "info" : "warning"}>{copy.flash[`status_${status}`]}</Badge>;
}

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
            {o.label}
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
 * connected yet", what will feed it and its definition status Pending; never a number, a zero or a dash, and it takes no children, so
 * nothing else can be drawn inside it
 */
export function PlaceholderCard({ slot, info, copy }: {
  slot: ActiveSlotKey; info: { about: string; text: string; more?: { href: string; label: string } }; copy: Copy;
}) {
  const t = copy.active;
  const def = ACTIVE_SLOTS.find((s) => s.key === slot)!;
  return (
    <div className="flex flex-col gap-2 rounded-card border border-dashed border-p4a-border bg-white p-5" data-testid={`active-slot-${slot}`} data-placeholder="">
      <p className="text-caption text-p4a-grey" data-hint-anchor="">
        <HintLabel label={t[`slot_${slot}`]}><HeaderHint label={info.about} text={info.text} more={info.more} /></HintLabel>
      </p>
      <p><Badge tone="neutral">{t.notConnected}</Badge></p>
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

function Scroll({ testId, label, children }: { testId: string; label: string; children: ReactNode }) {
  return (
    <div className="overflow-x-auto" data-testid={`${testId}-scroll`} role="region" aria-label={label} tabIndex={0}>
      <table className="w-full border-collapse text-body leading-table" data-testid={testId}>{children}</table>
    </div>
  );
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
  const head = (label: string, text: string, key?: MarketSort, extra = "") => {
    const current = key !== undefined && key === sort;
    const next = current && descending ? "asc" : "desc";
    return (
      <th className={`${th} ${key === "market" ? "" : "text-right"} ${extra}`} aria-sort={current ? (descending ? "descending" : "ascending") : undefined}>
        <HintLabel label={key ? (
          <Link href={href({ msort: key, mdir: next })} prefetch={false} scroll={false} className="underline-offset-2 hover:underline" data-testid={`active-msort-${key}`}
            title={t.sortBy.replace("{column}", label)}>{label}{current ? (descending ? " ↓" : " ↑") : ""}</Link>
        ) : label}>{hint(label, text)}</HintLabel>
      </th>
    );
  };
  const segCols = [...segments, "unknown"];
  const delta = (x: number) => (
    <span className={x > 0 ? "text-p4a-green" : x < 0 ? "text-p4a-error" : "text-p4a-muted"}>{x === 0 ? "0" : signed(n(Math.abs(x)), x)}</span>
  );
  const line = (r: ActiveMarketRow | (NonNullable<ActiveReport["marketsTotal"]> & { market?: undefined; spark?: undefined }), isTotal: boolean) => (
    <tr key={isTotal ? "total" : r.market} className={isTotal ? "border-t-2 border-p4a-deepblue bg-p4a-bgblue font-semibold" : row} data-testid={isTotal ? "active-market-total" : "active-market-row"}>
      <td className="h-10 whitespace-nowrap px-2 font-semibold">
        {isTotal ? t.total : (
          <Link href={href({ market: r.market!, msort: null, mdir: null, page: null })} prefetch={false} className="text-p4a-deepblue underline-offset-2 hover:underline" title={t.filterOnMarket.replace("{market}", r.market!)}>
            {r.market === "unknown" ? copy.reports.unknownMarket : r.market}
          </Link>
        )}
      </td>
      <td className={td}>{n(r.customers)}</td>
      <td className={td}>{fmtShare(r.share, locale)}</td>
      {segCols.map((s) => <td key={s} className={td}>{n(r.bySegment[s] ?? 0)}</td>)}
      <td className={td}>{n(r.subscriptions)}</td>
      <td className={td}>{n(r.devices)}</td>
      <td className={td}><Amounts amounts={r.amounts} locale={locale} pick="amount" /></td>
      <td className={td}><Amounts amounts={r.amounts} locale={locale} pick="average" /></td>
      <td className={td}>{r.medianAge === null ? "–" : fmtNumber(r.medianAge, locale, 1)}</td>
      <td className={td}><Amounts amounts={Object.fromEntries(Object.entries(r.clv).map(([c, v]) => [c, v.average]))} locale={locale} /></td>
      <td className={td}>{n(r.churned30d)}</td>
      <td className={td} data-testid="active-net">{delta(r.net30d)}</td>
      <td className={td} title={t.knownChannel.replace("{n}", n(r.indirect + r.direct))}>{r.indirectShare === null ? "–" : fmtShare(r.indirectShare, locale)}</td>
      <td className="h-10 px-2 text-right">
        {isTotal || !r.spark ? null : <Sparkline values={r.spark} title={t.sparkTitle.replace("{first}", n(r.spark[0] ?? 0)).replace("{last}", n(r.spark[r.spark.length - 1] ?? 0))} />}
      </td>
    </tr>
  );
  return (
    <Scroll testId="active-markets" label={t.marketsCard}>
      <thead>
        <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
          {head(t.colMarket, hints.mh_col_market!, "market")}
          {head(t.activeCustomers, hints.mh_active_customers!, "customers")}
          {head(t.colShare, hints.mh_col_share!, "share")}
          {segCols.map((s) => <th key={s} className={`${th} text-right`}><HintLabel label={s === "unknown" ? t.unknownSegment : s}>{hint(s === "unknown" ? t.unknownSegment : s, hints.mh_col_segment!)}</HintLabel></th>)}
          {head(t.totalSubscriptions, hints.mh_total_subscriptions!, "subscriptions")}
          {head(t.colDevices, hints.mh_col_devices!, "devices")}
          {head(t.monthlyAmount, hints.mh_monthly_amount!)}
          {head(t.averageAmount, hints.mh_average_amount!)}
          {head(t.medianAge, hints.mh_customer_age!, "medianAge")}
          {head(t.clvAverage, hints.mh_clv_realised!)}
          {head(t.churned30d, hints.mh_churned_30d!, "churned30d")}
          {head(t.net30d, hints.mh_net_30d!, "net30d")}
          {head(t.indirectShare, hints.mh_indirect_share!, "indirectShare")}
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
    case "lifetime_median": return t.monthsValue.replace("{n}", fmtNumber(value, locale, 0));
    case "median_age": return t.monthsValue.replace("{n}", fmtNumber(value, locale, 1));
    case "clv_average": case "clv_median": case "clv_per_month": case "average_monthly_amount": return currency ? fmtAmount(value, currency, locale) : fmtNumber(value, locale, 2);
    default: return fmtNumber(value, locale, 2);
  }
}

/** A difference in the measure's unit: shares in percentage points, the rest as the measure itself */
function differenceText(measure: ActiveMeasure, value: number, currency: string | null, locale: Locale, t: T): string {
  const abs = Math.abs(value);
  const text = measure === "share" || measure === "retention" || measure === "indirect_share"
    ? t.pointsValue.replace("{n}", fmtNumber(abs * 100, locale, 1))
    : measureText(measure, abs, currency, locale, t);
  return value === 0 ? text : signed(text, value);
}

/**
 * The first two segments side by side (decision D12): one row per measure, the difference (the first less the second) and
 * the ratio, the unknown segment beside them and never in the difference. A difference is coloured only where the higher
 * value is unambiguously the better one; a currency one side lacks leaves its cell empty with the reason in its title
 */
export function ComparisonTable({ comparison, hints, copy, locale }: { comparison: NonNullable<ActiveReport["comparison"]>; hints: Record<string, string>; copy: Copy; locale: Locale }) {
  const t = copy.active;
  const hint = hintOf(copy);
  const a = comparison.a ?? "–";
  const b = comparison.b ?? "–";
  const label = (r: ActiveComparisonRow) => {
    const base = r.measure === "retention" ? t.m_retention.replace("{n}", String(r.months)) : t[`m_${r.measure}`];
    return r.currency ? `${base} (${r.currency})` : base;
  };
  const cell = (r: ActiveComparisonRow, value: number | null, longest: number | null, side: string) => {
    if (value !== null) return <td className={td}>{measureText(r.measure, value, r.currency, locale, t)}</td>;
    if (r.measure === "lifetime_median" && longest !== null) {
      return <td className={`${td} text-p4a-muted`} title={`${t.notReachedShort}. ${t.notReachedTitle}`} data-not-reached="">{t.moreThanMonths.replace("{n}", String(longest))}</td>;
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
        {comparison.rows.map((r) => {
          const tone = differenceTone(r.measure, r.difference);
          return (
            <tr key={`${r.measure}|${r.months ?? ""}|${r.currency ?? ""}`} className={row} data-testid="active-comparison-row" data-measure={r.measure}>
              <td className="h-10 whitespace-nowrap px-2 font-semibold">{label(r)}</td>
              {cell(r, r.a, r.aLongest, a)}
              {cell(r, r.b, r.bLongest, b)}
              <td className={`${td} ${tone === "good" ? "text-p4a-green" : tone === "bad" ? "text-p4a-error" : "text-p4a-inkt"}`} data-tone={tone}>
                {r.difference === null ? "" : differenceText(r.measure, r.difference, r.currency, locale, t)}
              </td>
              <td className={td}>{r.ratio === null ? "" : t.ratioValue.replace("{n}", fmtNumber(r.ratio, locale, 2))}</td>
              {cell(r, r.unknown, r.unknownLongest, t.unknownSegment)}
            </tr>
          );
        })}
        <tr className={row} data-testid="active-comparison-row" data-measure="clv_projected" data-placeholder="">
          <td className="h-10 whitespace-nowrap px-2 font-semibold">{t.slot_clv_projected}</td>
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
 * the cell's title, on five steps of one blue hue (white text on the two dark steps only); a dash with its reason where
 * the cohort is not Mature at the age
 */
export function CohortHeatmap({ cohorts, ages, grouping, hints, copy, locale }: {
  cohorts: ActiveCohort[]; ages: number[]; grouping: ActiveGrouping; hints: Record<string, string>; copy: Copy; locale: Locale;
}) {
  const t = copy.active;
  const hint = hintOf(copy);
  return (
    <Scroll testId="active-cohorts" label={t.cohortsCard}>
      <thead>
        <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
          <th className={th}><HintLabel label={t.colCohort}>{hint(t.colCohort, hints.mh_cohort!)}</HintLabel></th>
          <th className={`${th} text-right`}><HintLabel label={t.colStarted}>{hint(t.colStarted, hints.mh_col_started!)}</HintLabel></th>
          {ages.map((a) => (
            <th key={a} className={`${th} text-right`}><HintLabel label={t.monthsValue.replace("{n}", String(a))}>{hint(t.monthsValue.replace("{n}", String(a)), hints.mh_col_cohort_age!)}</HintLabel></th>
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
              const heat = heatStep(share);
              if (share === null || heat === null) {
                return <td key={a.age} className={`${td} text-p4a-muted`} title={t.notMature} data-mature="false">–</td>;
              }
              return (
                <td key={a.age} className={`${td} ${heat.className}`} data-mature="true" data-heat={heat.step}
                  title={t.cohortCellTitle.replace("{n}", fmtCount(a.stillActive, locale)).replace("{started}", fmtCount(c.started, locale))}>
                  {fmtShare(share, locale)} <span className="font-normal opacity-90">({fmtCount(a.stillActive, locale)})</span>
                </td>
              );
            })}
          </tr>
        ))}
      </tbody>
    </Scroll>
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
  const head = (key: keyof T & string, text: string, right = true) => {
    const s = LIST_SORT[key];
    const label = t[key] as string;
    const current = s !== undefined && s === sort;
    return (
      <th className={`${th} ${right ? "text-right" : ""}`} aria-sort={current ? (descending ? "descending" : "ascending") : undefined}>
        <HintLabel label={s ? (
          <Link href={href({ sort: s, dir: current && descending ? "asc" : "desc", page: null })} prefetch={false} scroll={false} className="underline-offset-2 hover:underline"
            data-testid={`active-sort-${s}`} title={t.sortBy.replace("{column}", label)}>{label}{current ? (descending ? " ↓" : " ↑") : ""}</Link>
        ) : label}>{hint(label, text)}</HintLabel>
      </th>
    );
  };
  const pages = Math.max(1, Math.ceil(list.total / pageSize));
  const first = list.total === 0 ? 0 : (page - 1) * pageSize + 1;
  const payment: Record<string, "success" | "warning" | "error" | "neutral"> = { paid: "success", in_retry: "warning", failed: "error", paused: "neutral" };
  return (
    <div className="flex flex-col gap-4">
      <Scroll testId="active-list" label={t.listCard}>
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            {head("colStoreCustomer", hints.mh_col_store_customer!, false)}
            {head("colStore", hints.mh_col_store!, false)}
            {head("colMarket", hints.mh_col_market!, false)}
            {head("colSegment", hints.mh_col_segment!, false)}
            {head("channel", hints.mh_channel!, false)}
            {head("colAcquired", hints.mh_col_acquired!, false)}
            {head("colCustomerStart", hints.mh_customer_start!)}
            {head("customerAge", hints.mh_customer_age!)}
            {head("totalSubscriptions", hints.mh_total_subscriptions!)}
            {head("colDevices", hints.mh_col_devices!)}
            {head("monthlyAmount", hints.mh_monthly_amount!)}
            {head("clvRealised", hints.mh_clv_realised!)}
            {head("colPaymentState", hints.mh_col_payment_state!, false)}
            {head("colContact", hints.mh_col_contact!, false)}
          </tr>
        </thead>
        <tbody>
          {list.rows.map((r) => (
            <tr key={`${r.store}|${r.storeCustomer}`} className={row} data-testid="active-list-row">
              <td className="h-10 whitespace-nowrap px-2 tabular">{r.storeCustomer}</td>
              <td className="h-10 whitespace-nowrap px-2">{r.store}</td>
              <td className="h-10 whitespace-nowrap px-2">{r.market === "unknown" ? copy.reports.unknownMarket : r.market}</td>
              <td className="h-10 whitespace-nowrap px-2">{r.segment === "unknown" ? t.unknownSegment : r.segment}</td>
              <td className="h-10 whitespace-nowrap px-2">{t[`channel_${r.channel}`]}</td>
              <td className="h-10 whitespace-nowrap px-2 tabular" title={r.level ? (copy.firstOrders as Record<string, string>)[`level_${r.level}`] ?? r.level : t.noLevel}>
                {r.level ?? <span className="text-p4a-muted">–</span>}
              </td>
              <td className={td}>{r.customerStart ? fmtDate(r.customerStart, locale, "short") : "–"}</td>
              <td className={td}>{r.ageMonths === null ? "–" : n(r.ageMonths)}</td>
              <td className={td}>{n(r.subscriptions)}</td>
              <td className={td}>{n(r.devices)}</td>
              <td className={td}>
                {r.monthlyAmount !== null && r.currency ? (
                  <span className="flex flex-col items-end">
                    <span>{fmtAmount(r.monthlyAmount, r.currency, locale)}</span>
                    {Object.entries(r.otherAmounts).map(([c, v]) => <span key={c}>{fmtAmount(v, c, locale)}</span>)}
                  </span>
                ) : <span className="text-p4a-muted" title={t.noPayingAmount}>–</span>}
              </td>
              <td className={td}>{r.clv !== null && r.clvCurrency ? fmtAmount(r.clv, r.clvCurrency, locale) : "–"}</td>
              <td className="h-10 whitespace-nowrap px-2">
                {r.paymentState ? <Badge tone={payment[r.paymentState] ?? "neutral"}>{(t as Record<string, string>)[`pay_${r.paymentState}`] ?? r.paymentState}</Badge> : "–"}
              </td>
              <td className="h-10 px-2"><RecordLink url={r.contactUrl} label={t.openContact.replace("{id}", r.contactId ?? "")} /></td>
            </tr>
          ))}
        </tbody>
      </Scroll>
      <div className="flex flex-wrap items-center justify-between gap-4 text-small" data-testid="active-pager">
        <p className="text-p4a-muted">
          {t.listRange.replace("{first}", n(first)).replace("{last}", n(Math.min(list.total, page * pageSize))).replace("{total}", n(list.total))}
        </p>
        <nav aria-label={t.listCard} className="flex items-center gap-2 print:hidden">
          {page > 1
            ? <Link href={href({ page: page === 2 ? null : String(page - 1) })} prefetch={false} scroll={false} className="inline-flex h-8 items-center rounded-button border border-p4a-border px-3 font-semibold text-p4a-deepblue hover:bg-p4a-bgblue" data-testid="active-prev">{t.previousPage}</Link>
            : null}
          <span className="tabular text-p4a-muted">{t.pageOf.replace("{page}", n(page)).replace("{pages}", n(pages))}</span>
          {page < pages
            ? <Link href={href({ page: String(page + 1) })} prefetch={false} scroll={false} className="inline-flex h-8 items-center rounded-button border border-p4a-border px-3 font-semibold text-p4a-deepblue hover:bg-p4a-bgblue" data-testid="active-next">{t.nextPage}</Link>
            : null}
        </nav>
      </div>
    </div>
  );
}
