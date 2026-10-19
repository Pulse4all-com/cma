/**
 * Building blocks of Reports → First orders (addition 0008u; brief N19-A part 2): the grouping switch (G), the date
 * line with the history and the phone tier's start, the first orders per day or week as columns (call center Deep
 * Blue, self-service Leaf Green), the levels as horizontal bars, the figures per group or market with the amounts
 * per currency, the amounts per currency, and the list of first orders with their evidence as small badges.
 * Server components, plain SVG and CSS, no chart library; the figures come from the data layer and lib/first-orders
 * arranges them. Colours per docs/style/Pulse4all-Style.md 7.7 (no red, no donut; every mark carries its label in a
 * title); tables per 7.6, scrolling sideways inside their card at 1280 px. Ids, codes, counts, amounts and times
 * only: no name, address or phone number of a customer.
 */
import Link from "next/link";
import type { Copy, Locale } from "@/lib/copy";
import type { FirstOrderAmount, FirstOrderEvidence, FirstOrderGroup, FirstOrderLevel, FirstOrderListRow, FirstOrderRow } from "@/lib/data";
import { ATTRIBUTION_CLASS, ATTRIBUTION_FILL, EVIDENCE, FIRST_ORDER_GROUPS, fmtAmount, fmtDays, nextFirstOrderGroup } from "@/lib/first-orders";
import { barShare, fmtCount } from "@/lib/reports";
import { addDays, fmtDate, fmtDateTimeShort, startOfWeek } from "@/lib/time";
import { Legend, StackedColumns, type Column } from "./EmailParts";
import { HeaderHint } from "./HeaderHint";
import { RecordLink } from "./RecordLink";
import { Keycap } from "./primitives";

/** Day, week, market or level as links; G moves to the next */
export function FirstOrderGroupSwitch({ group, query, copy }: { group: FirstOrderGroup; query: Record<string, string>; copy: Copy }) {
  const t = copy.firstOrders;
  const labels: Record<FirstOrderGroup, string> = { day: t.day, week: t.week, market: t.market, level: t.level };
  const next = nextFirstOrderGroup(group);
  return (
    <div className="flex flex-col gap-2 text-small font-semibold">
      <span className="flex items-center gap-2">
        {t.groupBy} <Keycap>G</Keycap>
      </span>
      <nav aria-label={t.groupBy} className="flex gap-2">
        {FIRST_ORDER_GROUPS.map((g) => (
          <Link
            key={g}
            href={{ pathname: "/reports/first-orders", query: { ...query, group: g } }}
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

/** The page's date line: the period and the active filters; under it the history's and the phone tier's start in Muted */
export function FirstOrderDateLine({ from, to, market, level, historyStart, phoneStart, copy, locale, history = true }: {
  from: string; to: string; market: string | null; level: FirstOrderLevel | null; historyStart: string | null; phoneStart: string | null;
  copy: Copy; locale: Locale;
  /** The history's and the phone tier's start under the date line (the report page; not Orders per person) */
  history?: boolean;
}) {
  const t = copy.firstOrders;
  const parts = [
    `${fmtDate(from, locale)}${from !== to ? ` – ${fmtDate(to, locale)}` : ""}`,
    ...(market ? [t.activeMarket.replace("{market}", market === "unknown" ? copy.reports.unknownMarket : market)] : []),
    ...(level ? [t.activeLevel.replace("{level}", t[`level_${level}`])] : []),
  ];
  return (
    <div className="text-right">
      <p className="text-caption text-p4a-grey" data-testid="first-order-date-line">{parts.join(" · ")}</p>
      {history ? (
        <p className="mt-1 text-caption text-p4a-muted" data-testid="first-order-history">
          {[historyStart ? t.historyFrom.replace("{date}", fmtDate(historyStart, locale)) : null,
            phoneStart ? t.phoneFrom.replace("{date}", fmtDate(phoneStart, locale)) : t.phoneNone].filter(Boolean).join(" · ")}
        </p>
      ) : null}
    </div>
  );
}

/** First orders per date (or week): call center Deep Blue, self-service Leaf Green, stacked; every date of the period up to today */
export function AttributionColumns({ rows, group, from, to, last, copy, locale }: {
  rows: FirstOrderRow[]; group: "day" | "week"; from: string; to: string; last: string; copy: Copy; locale: Locale;
}) {
  const t = copy.firstOrders;
  const end = to < last ? to : last;
  const keys: string[] = [];
  for (let d = group === "day" ? from : startOfWeek(from); d <= end; d = addDays(d, group === "day" ? 1 : 7)) keys.push(d);
  const known = new Map(rows.map((r) => [r.groupKey, r]));
  const columns: Column[] = keys.map((k) => ({
    key: k, parts: [
      { key: "call_center", label: t.legendCallCenter, value: known.get(k)?.callCenter ?? 0, fill: ATTRIBUTION_FILL.call_center },
      { key: "self_service", label: t.legendSelfService, value: known.get(k)?.selfService ?? 0, fill: ATTRIBUTION_FILL.self_service },
    ],
  }));
  return (
    <>
      <Legend items={[{ key: "call_center", label: t.legendCallCenter, className: ATTRIBUTION_CLASS.call_center },
        { key: "self_service", label: t.legendSelfService, className: ATTRIBUTION_CLASS.self_service }]} label={t.legend} testId="first-order-legend" />
      <StackedColumns columns={columns} group={group} label={t.chart} testId="first-order-chart" copy={copy} locale={locale} />
    </>
  );
}

/** The levels as horizontal bars in the tenant's order: an assisted level Deep Blue, another Leaf Green; each label with its hint */
export function LevelBars({ rows, levels, assisted, hints, copy, locale }: {
  rows: FirstOrderRow[]; levels: FirstOrderLevel[]; assisted: FirstOrderEvidence[]; hints: Record<FirstOrderLevel, string>; copy: Copy; locale: Locale;
}) {
  const t = copy.firstOrders;
  const n = (x: number) => fmtCount(x, locale);
  const count = (l: FirstOrderLevel) => rows.find((r) => r.groupKey === l)?.firstOrders ?? 0;
  const largest = Math.max(0, ...levels.map(count));
  return (
    <ul className="flex flex-col gap-3" data-testid="first-order-levels">
      {levels.map((l) => {
        const v = count(l);
        const isAssisted = l !== "self_service" && assisted.includes(l);
        return (
          <li key={l} className="grid grid-cols-[13rem_1fr_4rem] items-center gap-4" data-level={l}>
            <span className="flex items-center text-small font-semibold text-p4a-body">
              {t[`level_${l}`]}
              <HeaderHint label={copy.hints.about.replace("{label}", t[`level_${l}`])} text={hints[l]} />
            </span>
            <span className="block h-3 overflow-hidden rounded-full bg-p4a-neutral-surface" title={`${t[`level_${l}`]}: ${n(v)}`}>
              <span className={`block h-3 rounded-full ${isAssisted ? ATTRIBUTION_CLASS.call_center : ATTRIBUTION_CLASS.self_service}`}
                style={{ width: `${(barShare(v, largest) * 100).toFixed(1)}%` }} />
            </span>
            <span className="tabular text-right text-body">{n(v)}</span>
          </li>
        );
      })}
    </ul>
  );
}

// headers may wrap over two lines (bottom-aligned), so the per-market table fits its card at 1280 px more often
const th = "h-10 px-2 py-1 align-bottom font-semibold";
const td = "h-10 whitespace-nowrap px-2 tabular text-right";
const row = "border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50";

/** The amounts of one market (or of everything) per currency, each in its own currency, on separate lines */
function amountLines(list: FirstOrderAmount[], copy: Copy, locale: Locale) {
  if (list.length === 0) return "–";
  return (
    <span className="flex flex-col items-end">
      {list.map((a) => <span key={a.currency ?? "none"}>{a.currency === null ? copy.firstOrders.noCurrency : fmtAmount(a.amount, a.currency, locale)}</span>)}
    </span>
  );
}

/** The figures per group (a date, a Monday, a market or a level) or per market, with the amounts per currency per market */
export function FirstOrderTable({ rows, dimension, amounts, hints, testId, title, copy, locale }: {
  rows: FirstOrderRow[]; dimension: FirstOrderGroup; amounts: FirstOrderAmount[] | null; hints: Record<string, string>; testId: string; title: string;
  copy: Copy; locale: Locale;
}) {
  const t = copy.firstOrders;
  const n = (x: number) => fmtCount(x, locale);
  const hint = (label: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} />;
  const first = { day: t.day, week: t.week, market: t.market, level: t.level }[dimension];
  const labelOf = (k: string) => dimension === "day" ? fmtDate(k, locale, "compact") : dimension === "week" ? t.weekLabel.replace("{week}", fmtDate(k, locale, "short"))
    : dimension === "market" ? (k === "unknown" ? copy.reports.unknownMarket : k) : t[`level_${k as FirstOrderLevel}`];
  const showKinds = dimension !== "level";
  return (
    <div className="overflow-x-auto" data-testid={`${testId}-scroll`} role="region" aria-label={title} tabIndex={0}>
      <table className="w-full border-collapse text-body leading-table" data-testid={testId}>
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            <th className={th}>{first}{hint(first, dimension === "market" ? hints.foMarket! : dimension === "level" ? hints.foLevel! : hints.foGroup!)}</th>
            <th className={`${th} text-right`}>{t.orders}{hint(t.orders, hints.foOrders!)}</th>
            <th className={`${th} text-right`}>{t.callCenterCol}{hint(t.callCenterCol, hints.foCallCenter!)}</th>
            <th className={`${th} text-right`}>{t.selfServiceCol}{hint(t.selfServiceCol, hints.foSelfService!)}</th>
            {showKinds ? (
              <>
                <th className={`${th} text-right`}>{t.repeats}{hint(t.repeats, hints.foRepeats!)}</th>
                <th className={`${th} text-right`}>{t.renewals}{hint(t.renewals, hints.foRenewals!)}</th>
                <th className={`${th} text-right`}>{t.notFirst}{hint(t.notFirst, hints.foNotFirst!)}</th>
                <th className={`${th} text-right`}>{t.noContact}{hint(t.noContact, hints.foNoContact!)}</th>
              </>
            ) : null}
            <th className={`${th} text-right`}>{t.days}{hint(t.days, hints.foDays!)}</th>
            {amounts ? <th className={`${th} text-right`}>{t.amount}{hint(t.amount, hints.foAmount!)}</th> : null}
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.groupKey} className={row}>
              <td className="h-10 whitespace-nowrap px-2 font-semibold">{labelOf(r.groupKey)}</td>
              <td className={td}>{n(r.firstOrders)}</td>
              <td className={td}>{n(r.callCenter)}</td>
              <td className={td}>{n(r.selfService)}</td>
              {showKinds ? (
                <>
                  <td className={td}>{n(r.repeats)}</td>
                  <td className={td}>{n(r.renewals)}</td>
                  <td className={td}>{n(r.notFirst)}</td>
                  <td className={td}>{n(r.noContact)}</td>
                </>
              ) : null}
              <td className={td}>{fmtDays(r.daysMedian, locale)}</td>
              {amounts ? <td className={`${td} py-1.5`}>{amountLines(amounts.filter((a) => a.market === r.groupKey), copy, locale)}</td> : null}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/** The amounts per currency: never added across currencies */
export function AmountsTable({ amounts, hints, copy, locale }: { amounts: FirstOrderAmount[]; hints: Record<string, string>; copy: Copy; locale: Locale }) {
  const t = copy.firstOrders;
  const n = (x: number) => fmtCount(x, locale);
  const hint = (label: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} />;
  return (
    <div className="overflow-x-auto" data-testid="first-order-amounts-scroll" role="region" aria-label={t.amountsTitle} tabIndex={0}>
      <table className="w-full border-collapse text-body leading-table" data-testid="first-order-amounts">
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            <th className={th}>{t.currency}{hint(t.currency, hints.foCurrency!)}</th>
            <th className={`${th} text-right`}>{t.orders}{hint(t.orders, hints.foOrders!)}</th>
            <th className={`${th} text-right`}>{t.amount}{hint(t.amount, hints.foAmount!)}</th>
            <th className={`${th} text-right`}>{t.callCenterCol}{hint(t.callCenterCol, hints.foCallCenterAmount!)}</th>
            <th className={`${th} text-right`}>{t.selfServiceCol}{hint(t.selfServiceCol, hints.foSelfServiceAmount!)}</th>
          </tr>
        </thead>
        <tbody>
          {amounts.map((a) => (
            <tr key={a.currency ?? "none"} className={row}>
              <td className="h-10 whitespace-nowrap px-2 font-semibold">{a.currency ?? t.noCurrency}</td>
              <td className={td}>{n(a.orders)}</td>
              <td className={td}>{a.currency === null ? "–" : fmtAmount(a.amount, a.currency, locale)}</td>
              <td className={td}>{a.currency === null ? "–" : fmtAmount(a.callCenterAmount, a.currency, locale)}</td>
              <td className={td}>{a.currency === null ? "–" : fmtAmount(a.selfServiceAmount, a.currency, locale)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/** The first orders of the period, newest first: the deal, market, when, level, the evidence as small badges, days, amount, the link */
export function FirstOrderListTable({ rows, levelOrder, hints, copy, locale, timeZone }: {
  rows: FirstOrderListRow[]; levelOrder: FirstOrderEvidence[]; hints: Record<string, string>; copy: Copy; locale: Locale; timeZone: string;
}) {
  const t = copy.firstOrders;
  const hint = (label: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} />;
  const order = [...levelOrder, ...EVIDENCE.filter((e) => !levelOrder.includes(e))];
  return (
    <div className="relative overflow-x-auto" data-testid="first-order-list-scroll" role="region" aria-label={t.listTitle} tabIndex={0}>
      <table className="w-full border-collapse text-body leading-table" data-testid="first-order-list">
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            <th className={th}>{t.deal}{hint(t.deal, hints.foDeal!)}</th>
            <th className={th}>{t.market}{hint(t.market, hints.foMarket!)}</th>
            <th className={`${th} text-right`}>{t.orderedAt}{hint(t.orderedAt, hints.foOrderedAt!)}</th>
            <th className={th}>{t.level}{hint(t.level, hints.foLevel!)}</th>
            <th className={th}>{t.evidence}{hint(t.evidence, hints.foEvidence!)}</th>
            <th className={`${th} text-right`}>{t.daysCol}{hint(t.daysCol, hints.foDaysCol!)}</th>
            <th className={`${th} text-right`}>{t.amount}{hint(t.amount, hints.foAmount!)}</th>
            <th className={th}><span className="sr-only">{t.open}</span></th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => {
            const found = order.filter((e) => r.evidence[e]);
            return (
              <tr key={`${r.connectionId}:${r.dealSourceId}`} className={row} data-testid="first-order-row">
                <td className="h-10 whitespace-nowrap px-2 font-semibold tabular">{r.dealSourceId}</td>
                <td className="h-10 whitespace-nowrap px-2">{r.market === "unknown" ? copy.reports.unknownMarket : r.market}</td>
                <td className={td}>{fmtDateTimeShort(r.createdAt, timeZone, locale)}</td>
                <td className="h-10 whitespace-nowrap px-2">
                  <span className="inline-flex items-center gap-2">
                    <span aria-hidden="true" className={`inline-block h-2.5 w-2.5 rounded-full ${ATTRIBUTION_CLASS[r.attribution]}`} />
                    {t[`level_${r.level}`]}
                  </span>
                </td>
                <td className="h-10 px-2">
                  {found.length === 0 ? <span className="text-small text-p4a-muted">{t.noEvidence}</span> : (
                    <span className="flex gap-1 whitespace-nowrap">
                      {found.map((e) => (
                        <span key={e} className="inline-block rounded-button border border-p4a-border bg-p4a-offwhite px-2 py-0.5 text-caption text-p4a-body" data-evidence={e}>
                          {t[`ev_${e}`]}
                        </span>
                      ))}
                    </span>
                  )}
                </td>
                <td className={td}>{fmtDays(r.daysFromFirstTouch, locale)}</td>
                <td className={td}>{r.currency === null ? "–" : fmtAmount(r.amount, r.currency, locale)}</td>
                <td className="h-10 px-2 text-right"><RecordLink url={r.recordUrl} label={`${t.open} ${r.dealSourceId}`} /></td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
