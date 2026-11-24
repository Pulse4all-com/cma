/**
 * Customers → Subscriptions (addition 0009zh, brief B39 continued, Part B39d): the page for how the subscription base
 * moves over months, while Flash keeps the stock per market and day (Decision log, 21 Nov 2026). One read from the
 * subscription facts' stored takes (cma.subscriptions_page: the tiles, the months, the rates, the stores' starts,
 * survival, the mix and the list's first page); a further page of the list is its own read (cma.subscription_rows).
 * Server components, plain SVG and CSS, Pulse4all-Style 7.3 (cards), 7.5 (badges), 7.6 (tables: numbers right-aligned in
 * tabular figures, every header with its hint, the header row on top of its scroll container) and 7.7 (charts: the series
 * order, every mark with a title naming its value, the table beside the chart holding the same figures). Team figures
 * only; ids, codes, counts, months, amounts and links only: never a customer's name, email, phone or address.
 */
import Link from "next/link";
import type { Route } from "next";
import type { ReactNode } from "react";
import { Bars, Legend, LineChart, type LineSeries } from "@/components/ActiveCharts";
import { fmtAmount } from "@/components/FlashParts";
import { HeaderHint } from "@/components/HeaderHint";
import { HintLabel } from "@/components/HintLabel";
import { LinkMark } from "@/components/ActivePending";
import { RecordLink } from "@/components/RecordLink";
import { StatusBadge } from "@/components/StatusBadge";
import { Badge, Card, Notice } from "@/components/primitives";
import { heatColour, monthLabel } from "@/lib/active";
import type { Copy, Locale, SubscriptionsCopy } from "@/lib/copy";
import type {
  DateKey, SubscriptionMoveKind, SubscriptionRowsPage, SubscriptionsInterval, SubscriptionsMeasure, SubscriptionsPage, SubscriptionsSort,
  SubscriptionsSourceCounts,
} from "@/lib/data";
import { flashHref } from "@/lib/flash";
import { fmtCount, fmtRate1, fmtShare } from "@/lib/reports";
import {
  monthEnd, rateOf, ratesOf, SUBSCRIPTIONS_AMOUNT_KINDS, SUBSCRIPTIONS_BRIDGE, SUBSCRIPTIONS_MEASURES, SUBSCRIPTIONS_OUTFLOW, SUBSCRIPTIONS_PAGE_ROWS,
  survivalShare,
} from "@/lib/subscriptions";
import { fmtDate, fmtDateTimeShort } from "@/lib/time";

type T = SubscriptionsCopy;
export type SubscriptionsHref = (change: Record<string, string | null>) => { pathname: Route; query: Record<string, string> };

const th = "h-10 px-2 py-1 align-bottom font-semibold leading-tight";
const tdN = "h-10 whitespace-nowrap px-2 tabular text-right";
// a number table's cell style is set once on the table (the cells carry no class of their own: a 61-month range draws thousands)
const cellStyle = "[&_td]:h-10 [&_td]:whitespace-nowrap [&_td]:px-2 [&_td]:tabular [&_td]:text-right";
const row = "border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50";
const link = "font-semibold text-p4a-deepblue underline-offset-2 hover:underline";

/** A month key's short name: "Oct 2026" */
export function monthName(month: DateKey, locale: Locale): string {
  return monthLabel(month, locale, true);
}

/** A section's title with its hint (the figure's definition) and its definition status */
export function SectionTitle({ label, hint, status = "Proposed", copy, children }: {
  label: string; hint: string; status?: "Proposed" | "Pending"; copy: Copy; children?: ReactNode;
}) {
  return (
    <div className="mb-4 flex flex-wrap items-center gap-3" data-hint-anchor="" data-panel-title="">
      <h2 className="text-panel font-semibold text-p4a-heading">
        <HintLabel label={label}><HeaderHint label={copy.hints.about.replace("{label}", label)} text={hint} /></HintLabel>
      </h2>
      <StatusBadge status={status} copy={copy} />
      {children ? <div className="ml-auto flex flex-wrap items-center gap-4 print:hidden">{children}</div> : null}
    </div>
  );
}

/** A switch of links (the movements' view, the list's measure): the current option marked */
export function Switch<V extends string>({ label, options, current, href, testId }: {
  label: string; options: { value: V; label: string }[]; current: V; href: (value: V) => { pathname: Route; query: Record<string, string> }; testId: string;
}) {
  return (
    <div className="flex items-center gap-2 text-small font-semibold">
      <span className="text-p4a-muted">{label}</span>
      <nav aria-label={label} className="flex flex-wrap gap-1" data-testid={testId}>
        {options.map((o) => (
          <Link key={o.value} href={href(o.value)} prefetch={false} scroll={false} aria-current={o.value === current ? "page" : undefined}
            className={["inline-flex h-8 items-center rounded-button border px-3 font-semibold",
              o.value === current ? "border-p4a-deepblue bg-p4a-deepblue text-white" : "border-p4a-border text-p4a-deepblue hover:bg-p4a-bgblue"].join(" ")}>
            {o.label}<LinkMark />
          </Link>
        ))}
      </nav>
    </div>
  );
}

/** A headline tile: its label with the hint, the figure, what stands under it */
function Tile({ testId, label, hint, copy, value, children }: { testId: string; label: string; hint: string; copy: Copy; value: ReactNode; children?: ReactNode }) {
  return (
    <div className="flex min-w-0 flex-col rounded-card border border-p4a-border bg-white p-5" data-tile="" data-testid={testId}>
      <p className="text-caption text-p4a-grey" data-hint-anchor="">
        <HintLabel label={label}><HeaderHint label={copy.hints.about.replace("{label}", label)} text={hint} /></HintLabel>
      </p>
      <div className="tabular mt-1 text-title font-bold text-p4a-heading">{value}</div>
      <div className="mt-1 flex flex-col gap-1 text-small text-p4a-muted">{children}</div>
    </div>
  );
}

/** A Churn rate or Failed rate with one decimal ("2.7%"): the rates are small, a whole percent hides most of them */
export const fmtRate = (share: number | null, locale: Locale): string => (share === null ? "–" : fmtRate1(share * 100, locale));

const statusWord = (status: string, t: T) => (t as Record<string, string>)[`status_${status.replace(/-/g, "_")}`] ?? status;
const payWord = (state: string | null, t: T) => (t as Record<string, string>)[`pay_${state ?? "unknown"}`] ?? state ?? t.pay_unknown;
const intervalWord = (i: string, t: T) => (t as Record<string, string>)[`interval_${i}`] ?? i;

/**
 * The six tiles (D.2): Total subscriptions with its split per holding status, Paused, the Monthly recurring amount per
 * currency (and the indicative euros), the last complete month's Churn rate (its churned count linked to Flash's Churn
 * for that month) and Failed rate, and the Device units with the subscriptions whose variant is not mapped (linked to
 * Data quality for a viewer who may open it, dataQuality: reports.view or tenant.configure; plain text otherwise). Under
 * Total subscriptions, Paused and the amount, the subscription app's own figure of the day (Source figures, addition
 * 0009zg) once one is stored: until then nothing stands there, never a zero
 */
export function SubscriptionsTiles({ page, t, copy, locale, dataQuality }: { page: SubscriptionsPage; t: T; copy: Copy; locale: Locale; dataQuality: boolean }) {
  const tiles = page.tiles;
  if (!tiles) return null;
  const sc = tiles.sourceCounts;
  const rates = tiles.rates;
  const { churn, failed } = ratesOf(rates);
  const month = rates ? monthName(rates.month, locale) : "";
  const flashChurn = rates ? flashHref("/reports/flash", {
    // range=custom: Flash's period bar (lib/period resolvePeriod) reads from and to with it alone, and opens on Today without it
    o: "churn", ...(page.filter.market ? { market: page.filter.market } : {}), range: "custom", from: rates.month, to: monthEnd(rates.month),
  }) : null;
  return (
    <div role="group" aria-label={t.tilesLabel} className="grid grid-cols-2 gap-4 md:grid-cols-3 xl:grid-cols-6" data-testid="subscriptions-tiles">
      <Tile testId="subscriptions-tile-total" label={t.tile_total} hint={t.h_total} copy={copy} value={fmtCount(tiles.total.value, locale)}>
        {Object.entries(tiles.total.byStatus).map(([s, n]) => (
          <span key={s} data-testid="subscriptions-tile-total-status" data-status={s}>{t.statusLine.replace("{status}", statusWord(s, t)).replace("{n}", fmtCount(n, locale))}</span>
        ))}
        {sc && sc.total !== null ? <SourceLine t={t} sc={sc} text={fmtCount(sc.total, locale)} stores={sc.stores} gaps={sc.totalGaps} link={dataQuality} locale={locale} testId="subscriptions-source-total" /> : null}
      </Tile>
      <Tile testId="subscriptions-tile-paused" label={t.tile_paused} hint={t.h_paused} copy={copy} value={fmtCount(tiles.paused, locale)}>
        {sc && sc.paused !== null ? <SourceLine t={t} sc={sc} text={fmtCount(sc.paused, locale)} stores={sc.stores} gaps={sc.pausedGaps} link={dataQuality} locale={locale} testId="subscriptions-source-paused" /> : null}
      </Tile>
      <Tile testId="subscriptions-tile-amount" label={t.tile_amount} hint={t.h_amount} copy={copy}
        value={tiles.amounts.length === 0 ? <span className="text-p4a-muted">{t.noAmount}</span> : (
          <span className="flex flex-col text-panel">
            {tiles.amounts.map((a) => <span key={a.currency} data-currency={a.currency}>{fmtAmount(a.amount, a.currency, locale)}</span>)}
          </span>
        )}>
        {sc ? sc.amounts.map((a) => (
          <SourceLine key={a.currency} t={t} sc={sc} text={fmtAmount(a.amount, a.currency, locale)} stores={a.stores} gaps={a.gaps} link={dataQuality}
            locale={locale} testId="subscriptions-source-amount" />
        )) : null}
        {tiles.eur ? <span data-testid="subscriptions-tile-eur">{t.eurLine.replace("{amount}", fmtAmount(tiles.eur.amount, "EUR", locale)).replace("{date}", tiles.eur.asOf ? fmtDate(tiles.eur.asOf, locale, "medium") : "–")}</span> : null}
      </Tile>
      <Tile testId="subscriptions-tile-churn" label={t.tile_churn} hint={t.h_churn} copy={copy}
        value={rates ? fmtRate(churn, locale) : <span className="text-p4a-muted">{t.noCompleteMonth}</span>}>
        {rates && flashChurn ? (
          <Link href={flashChurn as Route} className={link} title={t.openFlashChurn} data-testid="subscriptions-tile-churned">
            {t.churnedLine.replace("{n}", fmtCount(rates.churned, locale)).replace("{month}", month)}
          </Link>
        ) : null}
      </Tile>
      <Tile testId="subscriptions-tile-failed" label={t.tile_failed} hint={t.h_failed} copy={copy}
        value={rates ? fmtRate(failed, locale) : <span className="text-p4a-muted">{t.noCompleteMonth}</span>}>
        {rates ? <span>{t.failedLine.replace("{n}", fmtCount(rates.movedToFailed, locale)).replace("{month}", month)}</span> : null}
      </Tile>
      <Tile testId="subscriptions-tile-devices" label={t.tile_devices} hint={t.h_devices} copy={copy} value={fmtCount(tiles.devices.units, locale)}>
        {tiles.devices.unmapped > 0 && dataQuality ? (
          <Link href={flashHref("/reports/flash", { o: "data_quality", f_check: "subscription_variant_unmapped" }) as Route} className={link}
            title={t.openDataQuality} data-testid="subscriptions-tile-unmapped">
            {tiles.devices.unmapped === 1 ? t.unmappedOne : t.unmappedLine.replace("{n}", fmtCount(tiles.devices.unmapped, locale))}
          </Link>
        ) : tiles.devices.unmapped > 0 ? (
          <span data-testid="subscriptions-tile-unmapped">
            {tiles.devices.unmapped === 1 ? t.unmappedOne : t.unmappedLine.replace("{n}", fmtCount(tiles.devices.unmapped, locale))}
          </span>
        ) : null}
      </Tile>
    </div>
  );
}

/**
 * A tile's line with the subscription app's own figure (Source figures, read daily by B39b's job): its value and its day
 * (both days where the stores were read on two), the stores it covers where not every store in scope is among them,
 * and the number of its figures that are a Source figure gap one by one (figures among those Data quality lists): a link to Data
 * quality's check for a viewer who may open it (reports.view or tenant.configure), plain text otherwise
 */
function SourceLine({ t, sc, text, stores, gaps, link: toDq, locale, testId }: {
  t: T; sc: SubscriptionsSourceCounts; text: string; stores: number; gaps: number | null; link: boolean; locale: Locale; testId: string;
}) {
  const twoDays = Boolean(sc.from && sc.to && sc.from !== sc.to);
  const line = twoDays
    ? t.sourceLineDays.replace("{n}", text).replace("{from}", fmtDate(sc.from, locale, "medium")).replace("{to}", fmtDate(sc.to, locale, "medium"))
    : t.sourceLine.replace("{n}", text).replace("{date}", sc.to ? fmtDate(sc.to, locale, "medium") : "");
  const partial = stores < sc.inScope ? t.sourceStores.replace("{k}", fmtCount(stores, locale)).replace("{m}", fmtCount(sc.inScope, locale)) : null;
  const gapText = gaps ? t.sourceGap.replace("{n}", fmtCount(gaps, locale)) : null;
  return (
    <span className="flex flex-col" data-testid={testId}>
      <span>{line}{partial ? `, ${partial}` : ""}</span>
      {gapText && toDq ? (
        <Link href={flashHref("/reports/flash", { o: "data_quality", f_check: "source_figure_gap" }) as Route} className={link} title={t.openDataQuality}
          data-testid={`${testId}-gap`}>
          {gapText}
        </Link>
      ) : gapText ? <span data-testid={`${testId}-gap`}>{gapText}</span> : null}
    </span>
  );
}

/** A table inside its scroll container (Pulse4all-Style 7.6) */
function Scroll({ testId, label, children, fit = false, numbers = false }: { testId: string; label: string; children: ReactNode; fit?: boolean; numbers?: boolean }) {
  return (
    <div className="min-h-0 overflow-auto" data-testid={`${testId}-scroll`} role="region" aria-label={label} tabIndex={0}>
      <table className={`${fit ? "w-auto" : "w-full"} ${numbers ? cellStyle : ""} border-collapse text-body leading-table [&_thead]:sticky [&_thead]:top-0 [&_thead]:z-10 [&_thead_th]:bg-p4a-bgblue`} data-testid={testId}>{children}</table>
    </div>
  );
}

/** A quiet note above or under a part: what the figures leave out, in words */
export function Note({ children, testId }: { children: ReactNode; testId: string }) {
  return <p className="mb-4 rounded-button border-l-4 border-p4a-border bg-p4a-offwhite px-4 py-2 text-small text-p4a-muted" role="note" data-testid={testId}>{children}</p>;
}

/**
 * Movements by month (D.3.1): the bridge per month as a table, kinds down and months across, counts or the monthly
 * amounts per currency. Amounts are known from the take's amountsFrom (rule 12): a month before it shows a dash, never
 * a zero; the running month says "so far"
 */
export function Movements({ page, view, t, locale }: { page: SubscriptionsPage; view: "counts" | "amounts"; t: T; locale: Locale }) {
  const months = page.months;
  if (months.every((m) => m.counts === null)) return <p className="text-body text-p4a-muted">{t.noMonths}</p>;
  const kinds: SubscriptionMoveKind[] = [...SUBSCRIPTIONS_BRIDGE, ...SUBSCRIPTIONS_AMOUNT_KINDS];
  const currencies = [...new Set(months.flatMap((m) => Object.keys(m.amounts ?? {})))].sort();
  const head = (
    <thead>
      <tr>
        <th scope="col" className={`${th} text-left`}>{t.kindCol}</th>
        {months.map((m) => (
          <th key={m.month} scope="col" className={`${th} text-right`}>
            {monthName(m.month, locale)}{m.month === page.month ? <span className="block text-caption font-normal text-p4a-muted">{t.soFar}</span> : null}
          </th>
        ))}
      </tr>
    </thead>
  );
  const label = (k: SubscriptionMoveKind) => (
    <th scope="row" className={`h-10 whitespace-nowrap px-2 text-left font-normal ${k === "start" || k === "end" ? "font-semibold" : ""}`}>
      {k === "expansion" ? <span className="block text-caption text-p4a-muted">{t.amountChanges}</span> : null}
      {SUBSCRIPTIONS_OUTFLOW.has(k) ? "− " : k === "start" || k === "end" ? "" : "+ "}{t[`kind_${k}`]}
    </th>
  );
  if (view === "counts") {
    return (
      <Scroll testId="subscriptions-movements" label={t.movementsTitle} numbers>
        {head}
        <tbody>
          {kinds.map((k) => (
            <tr key={k} className={row} data-kind={k}>
              {label(k)}
              {months.map((m) => <td key={m.month}>{m.counts === null ? "–" : fmtCount(m.counts[k] ?? 0, locale)}</td>)}
            </tr>
          ))}
        </tbody>
      </Scroll>
    );
  }
  if (currencies.length === 0) return <p className="text-body text-p4a-muted" data-testid="subscriptions-amounts-none">{t.amountsNone}</p>;
  return (
    <div className="flex flex-col gap-6">
      {currencies.map((c) => (
        <div key={c}>
          <h3 className="mb-2 text-body font-semibold text-p4a-heading">{c}</h3>
          <Scroll testId={`subscriptions-amounts-${c}`} label={`${t.movementsTitle} ${c}`} numbers>
            {head}
            <tbody>
              {kinds.map((k) => (
                <tr key={k} className={row} data-kind={k}>
                  {label(k)}
                  {months.map((m) => {
                    const v = m.amounts?.[c]?.[k];
                    return <td key={m.month}>{m.amounts === null || m.amounts[c] === undefined ? "–" : fmtAmount(v ?? 0, c, locale)}</td>;
                  })}
                </tr>
              ))}
            </tbody>
          </Scroll>
        </div>
      ))}
    </div>
  );
}

/**
 * Churn rate and Failed rate by month (D.3.2): one line each per market (the churn rate solid, the failed rate dashed, in
 * the market's colour), each store's start month marked; the table beside holds the base and the counts
 */
export function Rates({ page, t, locale }: { page: SubscriptionsPage; t: T; locale: Locale }) {
  const months = page.months.map((m) => m.month);
  const markets = [...new Set(page.rates.map((r) => r.market))].sort();
  const pct = (v: number) => fmtRate(v, locale);
  const series: LineSeries[] = markets.flatMap((mk, i) => {
    const rs = page.rates.filter((r) => r.market === mk);
    const pts = (pick: (r: (typeof rs)[number]) => number) => rs.flatMap((r) => {
      const x = months.indexOf(r.month);
      const v = rateOf(pick(r), r.base);
      return x < 0 || v === null ? [] : [{ x, y: v, title: `${monthName(r.month, locale)}: ${pct(v)}` }];
    });
    return [
      { key: `${mk}-churn`, label: `${mk} ${t.churnRate}`, points: pts((r) => r.churned), colour: i },
      { key: `${mk}-failed`, label: `${mk} ${t.failedRate}`, points: pts((r) => r.movedToFailed), colour: i, dashed: true },
    ];
  });
  const highest = Math.max(0, ...series.flatMap((s) => s.points.map((p) => p.y)));
  // a round top whose quarters read as whole or half percents
  const top = [0.02, 0.04, 0.08, 0.1, 0.2, 0.4, 0.8, 1].find((v) => v >= highest) ?? 1;
  const markers = page.storeStarts.flatMap((s) => {
    const x = months.indexOf(s.rateStartMonth);
    return x < 0 ? [] : [{ x, title: t.rateStartLine.replace("{store}", s.handle ?? "").replace("{market}", s.market)
      .replace("{first}", monthName(s.firstEventMonth, locale)).replace("{start}", monthName(s.rateStartMonth, locale)) }];
  });
  return (
    <div className="flex flex-col gap-4">
      {page.rates.length === 0 ? <p className="text-body text-p4a-muted" data-testid="subscriptions-rates-none">{t.ratesNone}</p> : (
        <>
          <Legend label={t.ratesChartLabel} items={series.map((s) => ({ key: s.key, label: s.label, colour: s.colour ?? 0, dashed: s.dashed }))} />
          <LineChart series={series} xLabels={months.map((m, x) => ({ x, text: monthLabel(m, locale, x === 0 || m.slice(5, 7) === "01") }))}
            yFormat={pct} yTop={top} yLabel={t.shareAxis} label={t.ratesChartLabel} testId="subscriptions-rates-chart"
            markers={markers} />
          {/* months down, per market its base and both rates across (the counts in each cell's title) */}
          <Scroll testId="subscriptions-rates" label={t.ratesTitle} numbers>
            <thead>
              <tr>
                <th scope="col" rowSpan={2} className={`${th} text-left`}>{t.monthCol}</th>
                {markets.map((mk) => <th key={mk} scope="colgroup" colSpan={3} className={`${th} border-l border-p4a-border text-center`}>{mk}</th>)}
              </tr>
              <tr>
                {markets.flatMap((mk) => [
                  <th key={`${mk}-b`} scope="col" className={`${th} border-l border-p4a-border text-right`}>{t.baseCol}</th>,
                  <th key={`${mk}-c`} scope="col" className={`${th} text-right`}>{t.churnRate}</th>,
                  <th key={`${mk}-f`} scope="col" className={`${th} text-right`}>{t.failedRate}</th>,
                ])}
              </tr>
            </thead>
            <tbody>
              {months.filter((m) => page.rates.some((r) => r.month === m)).map((m) => (
                <tr key={m} className={row}>
                  <th scope="row" className="h-10 whitespace-nowrap px-2 text-left font-normal tabular">{monthName(m, locale)}</th>
                  {markets.flatMap((mk) => {
                    const r = page.rates.find((x) => x.market === mk && x.month === m);
                    if (!r) return [<td key={`${mk}-b`} className="border-l border-p4a-border text-p4a-muted">–</td>, <td key={`${mk}-c`} className="text-p4a-muted">–</td>, <td key={`${mk}-f`} className="text-p4a-muted">–</td>];
                    return [
                      <td key={`${mk}-b`} className="border-l border-p4a-border">{r.base === null ? "–" : fmtCount(r.base, locale)}</td>,
                      <td key={`${mk}-c`} title={`${t.churnedCol}: ${fmtCount(r.churned, locale)}`}>{fmtRate(rateOf(r.churned, r.base), locale)}</td>,
                      <td key={`${mk}-f`} title={`${t.failedCol}: ${fmtCount(r.movedToFailed, locale)}`}>{fmtRate(rateOf(r.movedToFailed, r.base), locale)}</td>,
                    ];
                  })}
                </tr>
              ))}
            </tbody>
          </Scroll>
        </>
      )}
      {page.storeStarts.length > 0 ? (
        <div data-testid="subscriptions-store-starts">
          <h3 className="mb-2 text-body font-semibold text-p4a-heading">{t.rateStarts}</h3>
          {page.ratesStartMonth ? (
            <p className="mb-1 text-small text-p4a-muted" data-testid="subscriptions-rates-floor">
              {t.ratesFloorLine.replace("{start}", monthName(page.ratesStartMonth, locale))}
            </p>
          ) : null}
          <ul className="flex flex-col gap-1 text-small text-p4a-muted">
            {page.storeStarts.map((s) => (
              <li key={s.connectionId}>
                {t.rateStartLine.replace("{store}", s.handle ?? "").replace("{market}", s.market).replace("{first}", monthName(s.firstEventMonth, locale))
                  .replace("{start}", monthName(s.rateStartMonth, locale))}
                {s.stragglers > 0 ? `; ${t.stragglersLine.replace("{n}", fmtCount(s.stragglers, locale))}` : ""}
              </li>
            ))}
          </ul>
        </div>
      ) : null}
    </div>
  );
}

/**
 * Renewal survival (D.3.3): per interval group, start cohorts down and renewals across, the share that renewed at least
 * that many times in a single-hue scale with the value in the cell; a dash where the cohort is not mature for it
 */
export function Survival({ page, t, locale }: { page: SubscriptionsPage; t: T; locale: Locale }) {
  const groups = page.survival?.groups ?? [];
  if (groups.length === 0) return <p className="text-body text-p4a-muted" data-testid="subscriptions-survival-none">{t.survivalNone}</p>;
  return (
    <div className="flex flex-col gap-6">
      {groups.map((g) => {
        const n = Math.max(1, ...g.cohorts.flatMap((c) => c.cells.map((x) => x.renewal)));
        const renewals = Array.from({ length: n }, (_, i) => i + 1);
        return (
          <div key={g.interval} data-interval={g.interval}>
            <h3 className="mb-2 text-body font-semibold text-p4a-heading">{intervalWord(g.interval, t)}</h3>
            <Scroll testId={`subscriptions-survival-${g.interval}`} label={`${t.survivalTitle} ${intervalWord(g.interval, t)}`} fit numbers>
              <thead>
                <tr>
                  <th scope="col" rowSpan={2} className={`${th} text-left`}>{t.cohortCol}</th>
                  <th scope="col" rowSpan={2} className={`${th} text-right`}>{t.startedCol}</th>
                  <th scope="colgroup" colSpan={renewals.length} className={`${th} text-center`}>{t.renewalsHead}</th>
                </tr>
                <tr>
                  {renewals.map((r) => <th key={r} scope="col" className={`${th} w-14 text-right`} aria-label={t.renewalCol.replace("{n}", String(r))}>{r}</th>)}
                </tr>
              </thead>
              <tbody>
                {g.cohorts.map((c) => (
                  <tr key={c.cohort} className="border-b border-p4a-border">
                    <th scope="row" className="h-10 whitespace-nowrap px-2 text-left font-normal tabular">{monthName(c.cohort, locale)}</th>
                    <td>{fmtCount(c.started, locale)}</td>
                    {renewals.map((r) => {
                      const cell = c.cells.find((x) => x.renewal === r);
                      const share = survivalShare(c.started, cell);
                      const heat = heatColour(share);
                      if (share === null || !heat) return <td key={r} className="text-p4a-muted">–</td>;
                      return (
                        <td key={r} className={heat.text === "white" ? "text-white" : "text-p4a-inkt"} style={{ backgroundColor: heat.background }} data-heat={heat.percent}>
                          {fmtShare(share, locale)}
                        </td>
                      );
                    })}
                  </tr>
                ))}
              </tbody>
            </Scroll>
          </div>
        );
      })}
    </div>
  );
}

/** The mix of the Total subscriptions (D.3.4): each breakdown as bars with the count and share beside them */
export function Mix({ page, t, locale }: { page: SubscriptionsPage; t: T; locale: Locale }) {
  const mix = page.mix;
  if (!mix || !page.tiles) return null;
  const total = page.tiles.total.value;
  const keyWord = (dim: string, key: string, label?: string | null): string => {
    if (key === "none") return t.none;
    if (key === "unknown") return t.unknown;
    if (key === "unmapped") return t.unmapped;
    if (dim === "interval") return intervalWord(key, t);
    if (dim === "paymentState") return payWord(key, t);
    return label ?? key;
  };
  const dims = [
    ["proposition", mix.proposition], ["model", mix.model], ["interval", mix.interval], ["deviceBand", mix.deviceBand], ["ageBand", mix.ageBand],
    ["instrument", mix.instrument], ["paymentState", mix.paymentState],
  ] as const;
  return (
    <div className="grid grid-cols-1 gap-6 md:grid-cols-2 xl:grid-cols-3">
      {dims.map(([dim, rows]) => (
        <div key={dim} data-testid={`subscriptions-mix-${dim}`}>
          <h3 className="mb-2 text-body font-semibold text-p4a-heading">{t[`mix_${dim}`]}</h3>
          <Bars label={t[`mix_${dim}`]} testId={`subscriptions-mix-${dim}-bars`} rows={rows.map((r) => {
            const word = keyWord(dim, r.key, r.label);
            const share = total > 0 ? fmtShare(r.subscriptions / total, locale) : "–";
            return { key: r.key, label: word, value: r.subscriptions, text: `${fmtCount(r.subscriptions, locale)} · ${share}`,
              title: t.mixLine.replace("{label}", word).replace("{n}", fmtCount(r.subscriptions, locale)).replace("{share}", share) };
          })} />
        </div>
      ))}
    </div>
  );
}

/** A part the takes cannot answer yet (D.3.5, D.3.6): its title, the neutral badge, what will feed it and its status Pending; never a figure */
export function PendingPart({ title, fedBy, t, copy, testId }: { title: string; fedBy: string; t: T; copy: Copy; testId: string }) {
  return (
    <section className="flex flex-col gap-2 rounded-card border border-dashed border-p4a-border bg-white p-6" data-testid={testId} data-placeholder="">
      <SectionTitle label={title} hint={t.h_placeholder} status="Pending" copy={copy} />
      <p><Badge tone="neutral">{t.notConnected}</Badge></p>
      <p className="text-small text-p4a-muted">{fedBy}</p>
    </section>
  );
}

const SORT_COLUMNS: { sort: SubscriptionsSort | null; col: keyof T; right?: boolean }[] = [
  { sort: "subscription", col: "col_subscription" }, { sort: null, col: "col_number" }, { sort: null, col: "col_store" }, { sort: "market", col: "col_market" },
  { sort: "status", col: "col_status" }, { sort: "payment_state", col: "col_payment_state" }, { sort: "interval", col: "col_interval" },
  { sort: "monthly_amount", col: "col_monthly_amount", right: true }, { sort: "device_units", col: "col_device_units", right: true },
  { sort: null, col: "col_age", right: true }, { sort: null, col: "col_propositions" },
  { sort: null, col: "col_contact" },
];

/**
 * The list (D.3.7): one row per subscription of the measure (a tile's population), sorted on a whitelist by its column's
 * header, 50 a page. The app's id and number, codes, the monthly amount in its currency, device units, Subscription age,
 * propositions and the contact's link; never a name or an email. The original start (estimated) is not shown until the
 * hand check of migrated subscriptions (Decision log, 20 Nov 2026)
 */
export function SubscriptionList({ list, measure, sort, descending, href, t, locale }: {
  list: SubscriptionRowsPage; measure: SubscriptionsMeasure; sort: SubscriptionsSort; descending: boolean; href: SubscriptionsHref; t: T; locale: Locale;
}) {
  const pages = Math.max(1, Math.ceil(list.total / SUBSCRIPTIONS_PAGE_ROWS));
  return (
    <div className="flex flex-col gap-4" data-testid="subscriptions-list">
      <Switch label={t.measureLabel} testId="subscriptions-measure" current={measure}
        options={SUBSCRIPTIONS_MEASURES.map((m) => ({ value: m, label: t[`measure_${m}`] }))}
        href={(m) => href({ measure: m === "total" ? null : m, page: null })} />
      <p className="text-caption text-p4a-grey" data-testid="subscriptions-list-count">
        {t.listOf.replace("{shown}", fmtCount(list.rows.length, locale)).replace("{total}", fmtCount(list.total, locale))}
      </p>
      {list.rows.length === 0 ? <p className="text-body text-p4a-muted" data-testid="subscriptions-list-empty">{t.noRows}</p> : (
        <Scroll testId="subscriptions-rows" label={t.listTitle}>
          <thead>
            <tr>
              {SORT_COLUMNS.map((c) => {
                const label = t[c.col] as string;
                const active = c.sort !== null && c.sort === sort;
                return (
                  <th key={String(c.col)} scope="col" className={`${th} ${c.right ? "text-right" : "text-left"}`} aria-sort={active ? (descending ? "descending" : "ascending") : undefined}>
                    {c.sort ? (
                      <Link href={href({ sort: c.sort === "monthly_amount" ? null : c.sort, dir: active && descending ? "asc" : "desc", page: null })}
                        prefetch={false} scroll={false} className="text-p4a-deepblue underline-offset-2 hover:underline" title={t.sortBy.replace("{column}", label)}>
                        {label}{active ? (descending ? " ↓" : " ↑") : ""}<LinkMark />
                      </Link>
                    ) : label}
                  </th>
                );
              })}
            </tr>
          </thead>
          <tbody>
            {list.rows.map((r) => (
              <tr key={r.subscriptionId} className={row} data-testid="subscriptions-row">
                <td className="h-10 whitespace-nowrap px-2 tabular">{r.sourceId}</td>
                <td className="h-10 whitespace-nowrap px-2 tabular">{r.number ?? "–"}</td>
                <td className="h-10 whitespace-nowrap px-2">{r.store ?? "–"}</td>
                <td className="h-10 whitespace-nowrap px-2">{r.market}</td>
                <td className="h-10 whitespace-nowrap px-2">{statusWord(r.status, t)}</td>
                <td className="h-10 whitespace-nowrap px-2">{payWord(r.paymentState, t)}</td>
                <td className="h-10 whitespace-nowrap px-2">{intervalWord(r.interval, t)}</td>
                <td className={tdN}>{r.monthlyAmount === null || r.currency === null ? "–" : fmtAmount(r.monthlyAmount, r.currency, locale)}</td>
                <td className={tdN}>{r.deviceUnits === null ? t.unmapped : fmtCount(r.deviceUnits, locale)}</td>
                <td className={tdN}>{r.ageMonths === null ? "–" : fmtCount(r.ageMonths, locale)}</td>
                <td className="h-10 whitespace-nowrap px-2">{r.propositions.length > 0 ? r.propositions.join(", ") : "–"}</td>
                <td className="h-10 px-2"><RecordLink url={r.contactUrl} label={t.openContact} /></td>
              </tr>
            ))}
          </tbody>
        </Scroll>
      )}
      {pages > 1 ? (
        <nav className="flex items-center justify-between gap-2 text-small" aria-label={t.pageOf.replace("{page}", String(list.page)).replace("{pages}", String(pages))}>
          {list.page > 1 ? (
            <Link href={href({ page: list.page - 1 === 1 ? null : String(list.page - 1) })} prefetch={false} scroll={false} data-testid="subscriptions-previous"
              className="inline-flex h-10 items-center rounded-button border border-p4a-deepblue bg-white px-4 font-semibold text-p4a-deepblue">{t.previous}<LinkMark /></Link>
          ) : <span />}
          <span className="text-p4a-muted">{t.pageOf.replace("{page}", fmtCount(list.page, locale)).replace("{pages}", fmtCount(pages, locale))}</span>
          {list.page < pages ? (
            <Link href={href({ page: String(list.page + 1) })} prefetch={false} scroll={false} data-testid="subscriptions-next"
              className="inline-flex h-10 items-center rounded-button border border-p4a-deepblue bg-white px-4 font-semibold text-p4a-deepblue">{t.next}<LinkMark /></Link>
          ) : <span />}
        </nav>
      ) : null}
    </div>
  );
}

/** Refreshed at: the take's moment in the tenant's zone */
export function Refreshed({ page, t, locale }: { page: SubscriptionsPage; t: T; locale: Locale }) {
  if (!page.take) return null;
  return <span data-testid="subscriptions-refreshed">{t.refreshedAt.replace("{time}", fmtDateTimeShort(page.take.computedAt, page.timeZone, locale))}</span>;
}

/** The notice above the parts that the proposition and interval filters do not narrow */
export function piNoteNeeded(filter: { proposition: string | null; interval: SubscriptionsInterval | null }): boolean {
  return filter.proposition !== null || filter.interval !== null;
}

export { Card, Notice };
