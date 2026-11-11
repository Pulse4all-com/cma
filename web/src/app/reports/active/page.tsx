import Link from "next/link";
import type { Route } from "next";
import { ActiveFilters } from "@/components/ActiveFilters";
import { Bars, FLOW_BG, FlowChart, Legend, LineChart, type LineSeries } from "@/components/ActiveCharts";
import {
  ActiveTile, type ActiveHref, ChangeLine, CohortHeatmap, ComparisonTable, CustomerList, DataNote, LinkSwitch, MARKET_SORTS, type MarketSort,
  MarketsTable, monthEndText, PanelTitle, PlaceholderCard, sortMarkets,
} from "@/components/ActiveParts";
import { fmtAmount, fmtNumber } from "@/components/FlashParts";
import { PrintButton } from "@/components/PrintButton";
import { NoReportPermission } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, LinkButton, Notice, PageTitle } from "@/components/primitives";
import {
  ACTIVE_CHANNELS, ACTIVE_COHORT_SPLITS, ACTIVE_GROUPINGS, ACTIVE_PAGE_SIZE, ACTIVE_RANGES, ACTIVE_SLOTS, type ActiveCohortSplitChoice, type ActiveSplit,
  activeGroupingOf, activeQuery, activeRangeOf, activeSortOf, cohortLabel, cohortShare, fromMonthOf, matureCohorts, monthLabel, monthsBack, parseActiveFilter,
} from "@/lib/active";
import { data, dataIsMock } from "@/lib/data";
import type { ActiveCurve } from "@/lib/data";
import { flashHref } from "@/lib/flash";
import { metricsMore } from "@/lib/metrics";
import { holdsAny } from "@/lib/nav";
import { fmtCount, fmtShare, REPORT_PERMISSIONS } from "@/lib/reports";
import { dateKeyInZone, fmtDate } from "@/lib/time";
import { resolve } from "../../access";

/**
 * Active (Customers, addition 0009l, brief B35 with addendum A, Martin, 11 November 2026; docs/definitions.md, Active
 * customer terms): the state and the movement of the customer base, the page the sales director opens first. The
 * population is Flash's, unchanged: an Active customer is a store customer with a subscription in a device-holding
 * status, Total subscriptions the subscriptions in one; the live headline equals Flash's for every market and segment.
 * The history is reconstructed from the subscriptions' created and ended times, one series of month ends whose last
 * point is "now" (a past pause counts as holding: the hint says so). Top to bottom: the headline tiles with their change
 * against the previous month end and the one a year before; the placeholders of the unit economics (a slot, a
 * definition and its sources, never a number); the base over time; inflow and outflow with the Monthly recurring amount
 * per month end; the markets; the two segments compared; the survival curves; Customer age and Direct / Indirect; the
 * customer cohorts; the subscription mix; the customer list with its file. Amounts are per currency and never added
 * across currencies; the indicative euro line shows only while reports.fx_eur_rates holds a rate for every currency
 * shown. Narrowed by market (K), segment and Direct / Indirect, in the database; every toggle is a link (no script
 * beyond the filters and the print button). Shown to people holding reports.view or performance.team; the database
 * checks again on every read. Team figures only: ids, statuses, codes, amounts and links, never a customer's name,
 * email, phone or address. The address keys are range, grouping, market, segment, channel, split, amount, survival,
 * cohort, msort, mdir, sort, dir and page.
 */
export default async function ActivePage({ searchParams }: PageProps<"/reports/active">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.active;

  if (!holdsAny(me, REPORT_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="active">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={copy.reports.noPermissionTitle} body={copy.reports.noPermissionBody} />
      </Shell>
    );
  }

  const sp = await searchParams;
  const one = (v: string | string[] | undefined) => (typeof v === "string" ? v : undefined);
  const today = dateKeyInZone(new Date(), me.timeZone);
  const range = activeRangeOf(one(sp.range));
  const grouping = activeGroupingOf(one(sp.grouping));
  const { filter, problem } = parseActiveFilter(one(sp.market), one(sp.segment), one(sp.channel));
  const bySegment = one(sp.split) === "segment";
  const wantEur = one(sp.amount) === "eur";
  const survivalSplit: ActiveSplit = one(sp.survival) === "channel" ? "channel" : "segment";
  const cohortSplit: ActiveCohortSplitChoice = (ACTIVE_COHORT_SPLITS as readonly string[]).includes(one(sp.cohort) ?? "") ? (one(sp.cohort) as ActiveCohortSplitChoice) : "none";
  const msort: MarketSort = (MARKET_SORTS as readonly string[]).includes(one(sp.msort) ?? "") ? (one(sp.msort) as MarketSort) : "customers";
  const mdesc = one(sp.mdir) !== "asc";
  const sort = activeSortOf(one(sp.sort));
  const descending = one(sp.dir) !== "asc";
  const pageNo = Math.max(1, Math.min(100_000, Number.parseInt(one(sp.page) ?? "1", 10) || 1));

  // the page in two reads, side by side: the document and the list's page (at most two transactions)
  const [report, list] = await Promise.all([
    data().getActive(me, fromMonthOf(range, today), filter, grouping),
    data().getActiveRows(me, { filter, sort, descending, offset: (pageNo - 1) * ACTIVE_PAGE_SIZE, limit: ACTIVE_PAGE_SIZE }),
  ]);

  // the address: only what differs from the page's defaults, so a view can be shared; a toggle changes its own key
  const state: Record<string, string> = {
    ...(range === "24" ? {} : { range }), ...(grouping === "month" ? {} : { grouping }), ...activeQuery(filter),
    ...(bySegment ? { split: "segment" } : {}), ...(wantEur ? { amount: "eur" } : {}), ...(survivalSplit === "channel" ? { survival: "channel" } : {}),
    ...(cohortSplit === "none" ? {} : { cohort: cohortSplit }), ...(msort === "customers" && mdesc ? {} : { msort, mdir: mdesc ? "desc" : "asc" }),
    ...(sort === "monthly_amount" && descending ? {} : { sort, dir: descending ? "desc" : "asc" }), ...(pageNo > 1 ? { page: String(pageNo) } : {}),
  };
  const href: ActiveHref = (change) => {
    const q = { ...state };
    for (const [k, v] of Object.entries(change)) {
      if (v === null) delete q[k];
      else q[k] = v;
    }
    return { pathname: "/reports/active" as Route, query: q };
  };
  const keep = Object.fromEntries(Object.entries(state).filter(([k]) => !["market", "segment", "channel", "page"].includes(k)));
  const fileQuery = new URLSearchParams({ ...activeQuery(filter), sort, dir: descending ? "desc" : "asc" }).toString();

  const locale = me.locale;
  const n = (x: number) => fmtCount(x, locale);
  const pct = (x: number | null) => fmtShare(x, locale);
  const months = (x: number, digits = 0) => t.monthsValue.replace("{n}", fmtNumber(x, locale, digits));
  const segLabel = (s: string) => (s === "unknown" ? t.unknownSegment : s);
  const info = (label: string, text: string, key?: string) =>
    ({ about: copy.hints.about.replace("{label}", label), text, more: key ? metricsMore(me.permissions, key, copy.hints.howComputed) : undefined });
  const more = (key: string) => metricsMore(me.permissions, key, copy.hints.howComputed);
  const hints = Object.fromEntries(Object.entries(t).filter(([k]) => k.startsWith("mh_"))) as Record<string, string>;
  const updated = new Intl.DateTimeFormat(locale === "nl" ? "nl-NL" : "en-GB", { timeStyle: "medium", timeZone: me.timeZone }).format(new Date(report.computedAt));

  const tiles = report.tiles;
  const prevMonth = monthsBack(report.today, 1);
  const prevYear = monthsBack(report.today, 13);
  const whenMonth = monthEndText(prevMonth, locale, t);
  const whenYear = monthEndText(prevYear, locale, t);
  const segments = report.settings.segments;
  const segOrder = [...segments, "unknown"];
  const ageBounds = report.settings.ageMonths.slice(0, 3);

  // ---- the charts' series ---------------------------------------------------------------------------------------------
  const ms = report.months;
  // the months named under an axis: at most n of them, the year written on the first and wherever it changes
  const axisLabels = (most: number) => {
    const every = Math.max(1, Math.ceil(ms.length / most));
    const shown = ms.map((m, i) => ({ x: i, month: m.month })).filter((_, i) => i % every === 0);
    return shown.map((l, i) => ({ x: l.x, text: monthLabel(l.month, locale, i === 0 || shown[i - 1]!.month.slice(0, 4) !== l.month.slice(0, 4)) }));
  };
  const xLabels = axisLabels(12);
  const xLabelsHalf = axisLabels(6);
  const monthName = (m: string) => monthLabel(m, locale, true);
  const baseSeries: LineSeries[] = bySegment
    ? segOrder.filter((s) => ms.some((m) => (m.bySegment[s] ?? 0) > 0)).map((s, i) => ({
      key: `segment-${s}`, label: `${t.activeCustomers}, ${segLabel(s)}`, colour: [0, 2, 3, 5, 4][i % 5]!,
      points: ms.map((m, x) => ({ x, y: m.bySegment[s] ?? 0, title: `${monthName(m.month)}${m.isNow ? `, ${t.soFar}` : ""}: ${n(m.bySegment[s] ?? 0)}`, hollow: m.isNow })),
    }))
    : [{
      key: "customers", label: t.activeCustomers, colour: 0,
      points: ms.map((m, x) => ({ x, y: m.customers, title: `${monthName(m.month)}${m.isNow ? `, ${t.soFar}` : ""}: ${n(m.customers)}`, hollow: m.isNow, label: m.isNow ? t.soFar : undefined })),
    }];
  baseSeries.push({
    key: "subscriptions", label: t.totalSubscriptions, colour: 1,
    points: ms.map((m, x) => ({ x, y: m.subscriptions, title: `${monthName(m.month)}${m.isNow ? `, ${t.soFar}` : ""}: ${n(m.subscriptions)}`, hollow: m.isNow })),
  });
  const firstMonth = ms[0]?.month ?? report.fromMonth;
  const markers = (report.notes?.historyStarts ?? []).filter((h) => h.date >= firstMonth).map((h) => ({
    x: (Number(h.date.slice(0, 4)) - Number(firstMonth.slice(0, 4))) * 12 + Number(h.date.slice(5, 7)) - Number(firstMonth.slice(5, 7)) + (Number(h.date.slice(8, 10)) - 1) / 31,
    title: t.historyStartsHere.replace("{store}", h.store).replace("{date}", fmtDate(h.date, locale)),
  }));
  const currencies = [...new Set(ms.flatMap((m) => Object.keys(m.amounts)))].sort();
  const eurAvailable = tiles?.eur != null && ms.every((m) => m.eur !== null || Object.keys(m.amounts).length === 0);
  const showEur = wantEur && eurAvailable;
  const amountSeries: LineSeries[] = showEur
    ? [{ key: "eur", label: t.eurIndicative, colour: 0,
      points: ms.filter((m) => m.eur !== null).map((m) => ({ x: ms.indexOf(m), y: m.eur!, title: `${monthName(m.month)}: ${t.approx} ${fmtAmount(m.eur!, "EUR", locale)}`, hollow: m.isNow })) }]
    : currencies.map((c, i) => ({
      key: c, label: c, colour: i,
      points: ms.filter((m) => m.amounts[c] !== undefined).map((m) => ({ x: ms.indexOf(m), y: m.amounts[c]!, title: `${monthName(m.month)}: ${fmtAmount(m.amounts[c]!, c, locale)}`, hollow: m.isNow })),
    }));
  const channelLabel = (c: string) => (t as Record<string, string>)[`channel_${c}`] ?? c;
  const curveLabel = (c: ActiveCurve) => (survivalSplit === "segment" ? segLabel(c.value ?? "") : channelLabel(c.value ?? ""));
  const curves = report.survival ? report.survival[survivalSplit] : [];
  const longest = Math.max(1, ...curves.map((c) => c.longest ?? 0));
  const ageStep = longest > 48 ? 12 : longest > 24 ? 6 : 3;
  const survivalSeries: LineSeries[] = curves.map((c, i) => ({
    key: c.value ?? "all", label: curveLabel(c), colour: c.value === "unknown" ? 5 : i, dashed: c.value === "unknown",
    points: c.curve.map((p) => ({
      x: p.age, y: p.retained, title: `${months(p.age)}: ${pct(p.retained)} (${t.atRisk.replace("{n}", n(p.atRisk))})`,
      label: c.median !== null && p.age === c.median ? t.medianAt.replace("{n}", String(c.median)) : undefined,
    })),
  }));
  const cohortAges = report.settings.cohortAgesMonths;
  const cohortSeries: LineSeries[] = cohortSplit === "none"
    ? matureCohorts(report.cohorts, 6).map((c, i) => ({
      key: c.cohort, label: cohortLabel(c.cohort, grouping, locale), colour: i,
      points: c.ages.flatMap((a, x) => {
        const share = cohortShare(c, a);
        return share === null ? [] : [{ x, y: share, title: `${months(a.age)}: ${pct(share)} (${t.cohortCellTitle.replace("{n}", n(a.stillActive)).replace("{started}", n(c.started))})` }];
      }),
    }))
    : (report.cohortSplits?.[cohortSplit] ?? []).map((s, i) => ({
      key: s.value, label: cohortSplit === "segment" ? segLabel(s.value) : channelLabel(s.value), colour: s.value === "unknown" ? 5 : i, dashed: s.value === "unknown",
      points: s.ages.flatMap((a, x) => (a.started > 0 ? [{ x, y: a.stillActive / a.started,
        title: `${months(a.age)}: ${pct(a.stillActive / a.started)} (${t.cohortCellTitle.replace("{n}", n(a.stillActive)).replace("{started}", n(a.started))})` }] : [])),
    }));

  const notes = report.notes;
  const reasons = notes ? Object.entries(notes.unknownChannel.reasons).sort((a, b) => b[1] - a[1]) : [];
  const reconstruction = notes ? [
    notes.noEndedTime > 0 ? t.noteNoEndedTime.replace("{n}", n(notes.noEndedTime)) : null,
    notes.noCreatedTime > 0 ? t.noteNoCreatedTime.replace("{n}", n(notes.noCreatedTime)) : null,
    notes.unmatchedSubscriptions > 0 ? t.noteUnmatched.replace("{n}", n(notes.unmatchedSubscriptions)) : null,
    notes.reconstructionGap !== 0 ? t.noteGap.replace("{n}", n(Math.abs(notes.reconstructionGap))) : null,
  ].filter((x): x is string => x !== null) : [];

  return (
    <Shell copy={copy} me={me} active="active" wide>
      <div data-print="report" data-testid="active-page">
        <PageTitle aside={(
          <div className="flex items-center gap-4">
            <span className="text-small text-p4a-muted" data-testid="active-updated">{t.updated.replace("{time}", updated)}</span>
            <span className="flex items-center gap-3 print:hidden">
              <LinkButton href={`/api/v1/reports/active/file${fileQuery ? `?${fileQuery}` : ""}`} download data-testid="active-download">{t.download}</LinkButton>
              <PrintButton label={t.print} />
            </span>
          </div>
        )}>{t.title}</PageTitle>
        <p className="-mt-2 mb-6 max-w-4xl text-small text-p4a-muted">{t.intro}</p>

        <div className="mb-6 flex flex-wrap items-end justify-between gap-x-6 gap-y-4 print:hidden">
          <ActiveFilters markets={report.filters.markets} segments={report.filters.segments} filter={filter} keep={keep} unknownMarket={copy.reports.unknownMarket}
            t={{ marketFilter: t.marketFilter, allMarkets: t.allMarkets, segmentFilter: t.segmentFilter, allSegments: t.allSegments, unknownSegment: t.unknownSegment,
              channel: t.channel, allChannels: t.allChannels, channel_indirect: t.channel_indirect, channel_direct: t.channel_direct, channel_unknown: t.channel_unknown }} />
          <div className="flex flex-wrap items-end gap-6">
            <LinkSwitch label={t.rangeLabel} testId="active-range" current={range} options={ACTIVE_RANGES.map((v) => ({ value: v, label: v === "all" ? t.rangeAll : t.rangeMonths.replace("{n}", v) }))}
              href={(v) => href({ range: v === "24" ? null : v })} />
            <LinkSwitch label={t.cohortGrouping} testId="active-grouping" current={grouping} options={ACTIVE_GROUPINGS.map((v) => ({ value: v, label: t[`grouping_${v}`] }))}
              href={(v) => href({ grouping: v === "month" ? null : v })} />
          </div>
        </div>

        {problem ? <div className="mb-6"><Notice tone="warning">{copy.funnel.filterIgnored}</Notice></div> : null}
        {!report.figures ? (
          <div className="mb-6 flex flex-col gap-3" data-testid="active-not-set-up">
            {!report.setUp.commerce ? <Notice tone="info">{t.notSetUpCommerce}</Notice> : null}
            {!report.setUp.subscriptions ? <Notice tone="info">{t.notSetUpSubscriptions}</Notice> : null}
          </div>
        ) : null}

        {report.figures && tiles && report.unitEconomics && report.marketsTotal && report.comparison && report.survival && report.mix && notes ? (
          <div className="flex flex-col gap-6">
            {/* 3.2 the headline */}
            <section className="grid grid-cols-3 gap-4 xl:grid-cols-6" aria-label={t.headline} data-testid="active-tiles">
              <ActiveTile testId="active-tile-customers" label={t.activeCustomers} info={info(t.activeCustomers, hints.mh_active_customers!, "active.active_customers")}
                value={n(tiles.activeCustomers.value)}>
                <p data-testid="active-split-segment">{segOrder.map((s) => `${segLabel(s)} ${n(tiles.activeCustomers.bySegment[s] ?? 0)}`).join(" · ")}</p>
                <p data-testid="active-split-channel">
                  {ACTIVE_CHANNELS.map((c) => `${t[`channelShort_${c}`]} ${pct(tiles.activeCustomers.value > 0 ? tiles.activeCustomers.byChannel[c] / tiles.activeCustomers.value : null)}`).join(" · ")}
                </p>
                <ChangeLine value={tiles.activeCustomers.value} previous={tiles.activeCustomers.prevMonth} when={whenMonth} fmt={n} better="up" t={t} />
                <ChangeLine value={tiles.activeCustomers.value} previous={tiles.activeCustomers.prevYear} when={whenYear} fmt={n} better="up" t={t} />
              </ActiveTile>
              <ActiveTile testId="active-tile-subscriptions" label={t.totalSubscriptions} info={info(t.totalSubscriptions, hints.mh_total_subscriptions!, "active.total_subscriptions")}
                value={n(tiles.totalSubscriptions.value)}>
                <p>{Object.entries(tiles.totalSubscriptions.byStatus).sort(([a], [b]) => (a < b ? -1 : 1)).map(([s, v]) => `${s} ${n(v)}`).join(" · ")}</p>
                <ChangeLine value={tiles.totalSubscriptions.value} previous={tiles.totalSubscriptions.prevMonth} when={whenMonth} fmt={n} better="up" t={t} />
                <ChangeLine value={tiles.totalSubscriptions.value} previous={tiles.totalSubscriptions.prevYear} when={whenYear} fmt={n} better="up" t={t} />
              </ActiveTile>
              <ActiveTile testId="active-tile-amount" label={t.monthlyAmount} info={info(t.monthlyAmount, hints.mh_monthly_amount!, "active.monthly_recurring_amount")}
                value={tiles.amounts.length === 0 ? <span className="text-p4a-muted">–</span> : (
                  <span className="flex flex-col text-panel">{tiles.amounts.map((a) => <span key={a.currency} data-currency={a.currency}>{fmtAmount(a.amount, a.currency, locale)}</span>)}</span>
                )}>
                {tiles.eur ? (
                  <p data-testid="active-eur" title={t.eurTitle.replace("{date}", fmtDate(tiles.eur.asOf, locale))}>
                    {t.eurLine.replace("{amount}", fmtAmount(tiles.eur.amount, "EUR", locale)).replace("{date}", fmtDate(tiles.eur.asOf, locale, "short"))}
                  </p>
                ) : null}
                {tiles.amounts.map((a) => (
                  <div key={a.currency}>
                    <ChangeLine value={a.amount} previous={a.prevMonth} when={whenMonth} fmt={(x) => fmtAmount(x, a.currency, locale)} better="up" t={t} />
                    <ChangeLine value={a.amount} previous={a.prevYear} when={whenYear} fmt={(x) => fmtAmount(x, a.currency, locale)} better="up" t={t} />
                  </div>
                ))}
              </ActiveTile>
              <ActiveTile testId="active-tile-average" label={t.averageAmount} info={info(t.averageAmount, hints.mh_average_amount!, "active.average_monthly_amount")}
                value={tiles.amounts.length === 0 ? <span className="text-p4a-muted">–</span> : (
                  <span className="flex flex-col text-panel">
                    {tiles.amounts.map((a) => <span key={a.currency} data-currency={a.currency}>{a.average === null ? "–" : fmtAmount(a.average, a.currency, locale)}</span>)}
                  </span>
                )}>
                {tiles.amounts.map((a) => (
                  <div key={a.currency}>
                    <ChangeLine value={a.average} previous={a.averagePrevMonth} when={whenMonth} fmt={(x) => fmtAmount(x, a.currency, locale)} better="up" t={t} />
                    <ChangeLine value={a.average} previous={a.averagePrevYear} when={whenYear} fmt={(x) => fmtAmount(x, a.currency, locale)} better="up" t={t} />
                  </div>
                ))}
              </ActiveTile>
              <ActiveTile testId="active-tile-age" label={t.medianAge} info={info(t.medianAge, hints.mh_customer_age!, "active.customer_age_median")}
                value={tiles.customerAge.median === null ? <span className="text-p4a-muted">–</span>
                  : <span>{fmtNumber(tiles.customerAge.median, locale, 1)} <span className="text-small font-normal text-p4a-muted">{t.monthsUnit}</span></span>}>
                {tiles.customerAge.over[0] ? <p>{t.moreThan.replace("{n}", String(tiles.customerAge.over[0].months))} {pct(tiles.customerAge.over[0].share)}</p> : null}
                <ChangeLine value={tiles.customerAge.median} previous={tiles.customerAge.prevMonth} when={whenMonth} fmt={(x) => months(x, 1)} t={t} />
                <ChangeLine value={tiles.customerAge.median} previous={tiles.customerAge.prevYear} when={whenYear} fmt={(x) => months(x, 1)} t={t} />
              </ActiveTile>
              <ActiveTile testId="active-tile-lifetime" label={t.lifetimeMedian} info={info(t.lifetimeMedian, hints.mh_customer_lifetime!, "active.customer_lifetime_median")}
                value={tiles.lifetime.median !== null
                  ? <span>{fmtNumber(tiles.lifetime.median, locale, 0)} <span className="text-small font-normal text-p4a-muted">{t.monthsUnit}</span></span>
                  : <span className="text-panel" title={t.notReachedTitle} data-testid="active-not-reached">{t.notReachedShort}</span>}>
                {tiles.lifetime.median === null && tiles.lifetime.longest !== null ? <p>{t.moreThanMonths.replace("{n}", String(tiles.lifetime.longest))}</p> : null}
                <p>{t.clvAverage}</p>
                {Object.entries(tiles.clv).sort(([a], [b]) => (a < b ? -1 : 1)).map(([c, v]) => <p key={c} className="tabular" data-currency={c}>{fmtAmount(v.average, c, locale)}</p>)}
              </ActiveTile>
            </section>

            {/* 3.3 the unit economics: placeholders, never a number */}
            <section aria-label={t.unitEconomics} data-testid="active-slots">
              <PanelTitle label={t.unitEconomics} hint={hints.mh_unit_economics!} status="Pending" copy={copy} />
              <div className="grid grid-cols-3 gap-4 xl:grid-cols-6">
                {ACTIVE_SLOTS.map((s) => (
                  <PlaceholderCard key={s.key} slot={s.key} info={info(t[`slot_${s.key}`], hints[`mh_slot_${s.key}`]!, s.metric)} copy={copy}>
                    {s.key === "churn_rate" ? (
                      <p className="mt-auto border-t border-p4a-border pt-2 text-small" data-testid="active-churned">
                        <Link href={flashHref("/reports/flash", { o: "churn" }) as Route} className="font-semibold text-p4a-deepblue underline-offset-2 hover:underline" title={t.openChurn}>
                          {t.churned30dLine.replace("{n}", n(report.unitEconomics!.churned30d))}
                        </Link>
                      </p>
                    ) : null}
                  </PlaceholderCard>
                ))}
              </div>
            </section>

            {/* 3.4 the base over time */}
            <Card>
              <PanelTitle label={t.baseCard} hint={hints.mh_base!} more={more("active.base_over_time")} copy={copy}>
                <LinkSwitch label={t.splitBy} testId="active-split" current={bySegment ? "segment" : "none"}
                  options={[{ value: "none", label: t.splitNone }, { value: "segment", label: t.segmentFilter }]} href={(v) => href({ split: v === "segment" ? "segment" : null })} />
              </PanelTitle>
              {reconstruction.length > 0 ? <DataNote testId="active-note-history">{reconstruction.join(" ")}</DataNote> : null}
              {ms.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
                <div className="flex flex-col gap-4">
                  <LineChart series={baseSeries} xLabels={xLabels} yFormat={n} yLabel={t.axisCount} label={t.baseCard} testId="active-base-chart" markers={markers} height={320} />
                  <Legend label={t.baseCard} items={[...baseSeries.map((s, i) => ({ key: s.key, label: s.label, colour: s.colour ?? i })),
                    ...(markers.length > 0 ? [{ key: "marker", label: t.historyMarker, colour: 5, dashed: true }] : [])]} />
                </div>
              )}
            </Card>

            {/* 3.5 inflow and outflow; the Monthly recurring amount per month end */}
            <div className="grid grid-cols-2 gap-6">
              <Card>
                <PanelTitle label={t.flowCard} hint={hints.mh_flow!} more={more("active.inflow")} copy={copy} />
                {ms.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
                  <div className="flex flex-col gap-4">
                    <FlowChart label={t.flowCard} fmt={n} xLabels={xLabelsHalf} width={600} height={300} words={{ inflow: t.inflow, outflow: t.outflow, net: t.netChange, axis: t.axisCustomers }}
                      bars={ms.map((m) => ({ key: m.month, label: `${monthName(m.month)}${m.isNow ? `, ${t.soFar}` : ""}`,
                        up: ACTIVE_CHANNELS.map((c) => ({ key: c, value: m.inflowByChannel[c] ?? 0, label: channelLabel(c) })), down: m.outflow, net: m.net }))} />
                    <Legend label={t.flowCard} items={[
                      ...ACTIVE_CHANNELS.map((c, i) => ({ key: c, label: `${t.inflow}, ${channelLabel(c)}`, colour: i, bar: true, className: `${FLOW_BG[c]}${c === "unknown" ? " ring-1 ring-inset ring-p4a-grey" : ""}` })),
                      { key: "out", label: t.outflow, colour: 5, bar: true, className: "bg-p4a-inkt" }, { key: "net", label: t.netChange, colour: 1 },
                    ]} />
                  </div>
                )}
              </Card>
              <Card>
                <PanelTitle label={t.amountCard} hint={hints.mh_monthly_amount!} more={more("active.monthly_recurring_amount")} copy={copy}>
                  {eurAvailable ? (
                    <LinkSwitch label={t.showAs} testId="active-amount-switch" current={showEur ? "eur" : "currency"}
                      options={[{ value: "currency", label: t.perCurrency }, { value: "eur", label: t.eurIndicative }]} href={(v) => href({ amount: v === "eur" ? "eur" : null })} />
                  ) : null}
                </PanelTitle>
                {amountSeries.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
                  <div className="flex flex-col gap-4">
                    <LineChart series={amountSeries} xLabels={xLabelsHalf} yFormat={(v) => fmtNumber(v, locale, 0)} yLabel={showEur ? t.axisEur : t.axisAmount} label={t.amountCard} testId="active-amount-chart"
                      width={600} height={300} />
                    <Legend label={t.amountCard} items={amountSeries.map((s, i) => ({ key: s.key, label: s.label, colour: s.colour ?? i }))} />
                  </div>
                )}
              </Card>
            </div>

            {/* 3.6 the markets */}
            <Card>
              <PanelTitle label={t.marketsCard} hint={hints.mh_markets!} more={more("active.by_market")} copy={copy} />
              {report.markets.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p>
                : <MarketsTable rows={sortMarkets(report.markets, msort, mdesc)} total={report.marketsTotal} sort={msort} descending={mdesc} href={href} hints={hints} copy={copy}
                  locale={locale} segments={segments} />}
            </Card>

            {/* 3.7a the two segments compared */}
            <Card>
              <PanelTitle label={t.comparisonCard.replace("{a}", report.comparison.a ?? "–").replace("{b}", report.comparison.b ?? "–")} hint={hints.mh_comparison!}
                more={more("active.segment_difference")} copy={copy} />
              {report.comparison.a === null || report.comparison.b === null ? <p className="text-body text-p4a-muted">{t.noSegments}</p>
                : <ComparisonTable comparison={report.comparison} hints={hints} copy={copy} locale={locale} />}
            </Card>

            {/* 3.7b survival */}
            <Card>
              <PanelTitle label={t.survivalCard} hint={hints.mh_survival!} more={more("active.customer_lifetime_median")} copy={copy}>
                <LinkSwitch label={t.splitBy} testId="active-survival-split" current={survivalSplit}
                  options={[{ value: "segment", label: t.segmentFilter }, { value: "channel", label: t.channel }]} href={(v) => href({ survival: v === "channel" ? "channel" : null })} />
              </PanelTitle>
              {survivalSeries.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
                <div className="flex flex-col gap-4">
                  <LineChart series={survivalSeries} step yTop={1} yFormat={(v) => pct(v)} yLabel={t.axisRetained} xLabel={t.axisAge} label={t.survivalCard} testId="active-survival-chart"
                    xLabels={Array.from({ length: Math.floor(longest / ageStep) + 1 }, (_, i) => ({ x: i * ageStep, text: String(i * ageStep) }))} refY={{ y: 0.5, text: t.halfLine }} />
                  <Legend label={t.survivalCard} items={survivalSeries.map((s, i) => ({ key: s.key, label: s.label, colour: s.colour ?? i, dashed: s.dashed }))} />
                  <ul className="flex flex-wrap gap-x-8 gap-y-1 text-small text-p4a-muted" data-testid="active-medians">
                    {curves.map((c) => (
                      <li key={c.value}>{curveLabel(c)}: {c.median !== null ? t.medianIs.replace("{n}", String(c.median)) : t.notReached.replace("{n}", String(c.longest ?? 0))} ({t.spellsCount.replace("{n}", n(c.spells))})</li>
                    ))}
                  </ul>
                </div>
              )}
            </Card>

            {/* 3.7c Customer age; Direct / Indirect */}
            <div className="grid grid-cols-2 gap-6">
              <Card>
                <PanelTitle label={t.customerAge} hint={hints.mh_customer_age_bands!} more={more("active.customer_age_bands")} copy={copy} />
                <Bars testId="active-age-bands" label={t.customerAge}
                  rows={report.ageBands.map((b) => ({ key: b.band, label: t.bandMonths.replace("{band}", b.band), value: b.customers, text: n(b.customers), title: `${t.bandMonths.replace("{band}", b.band)}: ${n(b.customers)}` }))} />
                <dl className="mt-4 grid grid-cols-3 gap-4 border-t border-p4a-border pt-4" data-testid="active-age-over">
                  {tiles.customerAge.over.filter((o) => ageBounds.includes(o.months)).map((o) => (
                    <div key={o.months}>
                      <dt className="text-caption text-p4a-grey">{t.moreThan.replace("{n}", String(o.months))}</dt>
                      <dd className="tabular text-panel font-semibold text-p4a-heading">{n(o.customers)} <span className="text-small font-normal text-p4a-muted">{pct(o.share)}</span></dd>
                    </div>
                  ))}
                </dl>
              </Card>
              <Card>
                <PanelTitle label={t.channelCard} hint={hints.mh_channel!} more={more("active.acquisition_channel_share")} copy={copy} />
                <Bars testId="active-channels" label={t.channelCard}
                  rows={ACTIVE_CHANNELS.map((c) => ({ key: c, label: channelLabel(c), value: tiles.activeCustomers.byChannel[c], text: n(tiles.activeCustomers.byChannel[c]), title: `${channelLabel(c)}: ${n(tiles.activeCustomers.byChannel[c])}` }))} />
                {notes.unknownChannel.customers > 0 ? (
                  <DataNote testId="active-note-channel">
                    {t.noteUnknownChannel.replace("{n}", n(notes.unknownChannel.customers))}{" "}
                    {reasons.map(([k, v]) => `${(t as Record<string, string>)[`reason_${k}`] ?? k} ${n(v)}`).join(" · ")}
                    {report.settings.attribution.historyStart ? ` ${t.noteAttributionStart.replace("{date}", fmtDate(report.settings.attribution.historyStart, locale))}` : ` ${t.noteNoAttribution}`}
                  </DataNote>
                ) : null}
              </Card>
            </div>

            {/* 3.8 the customer cohorts */}
            <Card>
              <PanelTitle label={t.cohortsCard} hint={hints.mh_cohort!} more={more("active.cohort_retention")} copy={copy}>
                <LinkSwitch label={t.splitBy} testId="active-cohort-split" current={cohortSplit}
                  options={ACTIVE_COHORT_SPLITS.map((v) => ({ value: v, label: v === "none" ? t.splitNone : v === "segment" ? t.segmentFilter : t.channel }))}
                  href={(v) => href({ cohort: v === "none" ? null : v })} />
              </PanelTitle>
              {notes.dominantCohort ? (
                <DataNote testId="active-note-dominant">
                  {t.noteDominant.replace("{cohort}", cohortLabel(notes.dominantCohort.cohort, grouping, locale)).replace("{share}", pct(notes.dominantCohort.share))}
                </DataNote>
              ) : null}
              {report.cohorts.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
                <div className="flex flex-col gap-6">
                  <CohortHeatmap cohorts={report.cohorts} ages={cohortAges} grouping={grouping} hints={hints} copy={copy} locale={locale} />
                  {cohortSeries.some((s) => s.points.length > 0) ? (
                    <div className="flex flex-col gap-4">
                      <h3 className="text-body font-semibold text-p4a-heading">{cohortSplit === "none" ? t.cohortCurves : t.cohortCurvesSplit}</h3>
                      <LineChart series={cohortSeries} yTop={1} yFormat={(v) => pct(v)} yLabel={t.axisStillActive} xLabel={t.axisAge} label={t.cohortCurves} testId="active-cohort-chart"
                        xLabels={cohortAges.map((a, i) => ({ x: i, text: String(a) }))} />
                      <Legend label={t.cohortCurves} items={cohortSeries.map((s, i) => ({ key: s.key, label: s.label, colour: s.colour ?? i, dashed: s.dashed }))} />
                    </div>
                  ) : <p className="text-small text-p4a-muted">{t.noMatureCohort}</p>}
                </div>
              )}
            </Card>

            {/* 3.9 the subscription mix */}
            <section aria-label={t.mixCard} data-testid="active-mix">
              <PanelTitle label={t.mixCard} hint={hints.mh_mix!} more={more("active.subscription_mix")} copy={copy} />
              <div className="grid grid-cols-2 gap-4 xl:grid-cols-4">
                <Card title={t.mixBilling}>
                  <Bars testId="active-mix-billing" label={t.mixBilling}
                    rows={report.mix.billing.map((b) => ({ key: b.key, label: (t as Record<string, string>)[`billing_${b.key}`] ?? b.key, value: b.subscriptions, text: n(b.subscriptions), title: n(b.subscriptions) }))} />
                </Card>
                <Card title={t.mixDeviceBand}>
                  <Bars testId="active-mix-band" label={t.mixDeviceBand}
                    rows={report.mix.deviceBand.map((b) => ({ key: b.key, label: t.devicesBand.replace("{band}", b.key), value: b.subscriptions, text: n(b.subscriptions), title: n(b.subscriptions) }))} />
                </Card>
                <Card title={t.mixModel}>
                  {report.mix.model.length === 0 ? <p className="text-small text-p4a-muted">{t.noDevices}</p> : (
                    <Bars testId="active-mix-model" label={t.mixModel} colour="bg-p4a-denim"
                      rows={report.mix.model.map((b) => ({ key: b.key, label: b.label ?? b.key, value: b.devices, text: n(b.devices), title: `${b.label ?? b.key}: ${n(b.devices)}` }))} />
                  )}
                </Card>
                <Card title={t.mixPayment}>
                  <Bars testId="active-mix-payment" label={t.mixPayment} colour="bg-p4a-green"
                    rows={report.mix.paymentState.map((b) => {
                      const label = (t as Record<string, string>)[`pay_${b.key}`] ?? b.key;
                      return {
                        key: b.key, value: b.subscriptions, text: n(b.subscriptions), title: `${label}: ${n(b.subscriptions)}`,
                        label: b.key === "in_retry" || b.key === "failed"
                          ? <Link href={flashHref("/reports/flash", { o: "subscriptions", f_payment_state: b.key }) as Route} className="text-p4a-deepblue underline-offset-2 hover:underline" title={t.openFlashPayment.replace("{state}", label)}>{label}</Link>
                          : label,
                      };
                    })} />
                </Card>
              </div>
            </section>

            {/* 3.10 the customer list */}
            <Card>
              <PanelTitle label={t.listCard} hint={hints.mh_list!} more={more("active.list")} copy={copy} />
              {list.total === 0 ? <p className="text-body text-p4a-muted">{t.emptyList}</p>
                : <CustomerList list={list} sort={sort} descending={descending} page={pageNo} pageSize={ACTIVE_PAGE_SIZE} href={href} hints={hints} copy={copy} locale={locale} />}
            </Card>
          </div>
        ) : null}

        {dataIsMock ? (
          <div className="mt-6 print:hidden">
            <Notice tone="info">{copy.shell.testData}</Notice>
          </div>
        ) : null}
      </div>
    </Shell>
  );
}
