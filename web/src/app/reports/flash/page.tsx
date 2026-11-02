import Link from "next/link";
import type { Route } from "next";
import { FlashAsOf, FlashLiveFigure, FlashMarket } from "@/components/FlashControls";
import { HeaderHint } from "@/components/HeaderHint";
import { HintLabel } from "@/components/HintLabel";
import {
  BreakdownTable, changeText, DataQualityTable, FlashCard, FlashStrip, fmtNumber, MarketBars, OverviewHeading, RowsTable, SourcesLine, TotalsRow, WatchStrip,
} from "@/components/FlashParts";
import { PeriodBar } from "@/components/PeriodBar";
import { NoReportPermission } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, LinkButton, Notice, PageTitle } from "@/components/primitives";
import { CmaDbError, data, dataIsMock, type FlashDocumentView, type FlashPageView, type FlashRowsView } from "@/lib/data";
import {
  breakdownSets, FLASH_OVERVIEWS, FLASH_PAGE_ROWS, filtersText, metricKey, overviewOf, parseAsOf, parseFilters, parseMarket, parseSort,
  type FlashOverviewDef,
} from "@/lib/flash";
import { metricsMore } from "@/lib/metrics";
import { holdsAny } from "@/lib/nav";
import { resolvePeriod } from "@/lib/period";
import { REPORT_PERMISSIONS } from "@/lib/reports";
import { addDays, dateKeyInZone, fmtDate } from "@/lib/time";
import { resolve } from "../../access";

/**
 * Reports → Flash (addition 0008zn; brief B21, decisions of 1 November 2026): ten overviews (Active customers, Active
 * subscriptions, Installed base, Churn, Orders, Payments, Open deals, Open tickets, Open tasks, Reviews) and Data quality,
 * one click (or key: 1 to 9, 0, Q) each, now from the sources or as of a business date with a snapshot (A), per market
 * (K), the flows over the period bar, on screen and as a file (X). The landing reads the stored figures in one call
 * (cma.flash_page) and each card's live headline after it painted; an overview reads its document and its first page of
 * records in one transaction (getFlashView). Every figure's hint names its definition and its status. Team figures
 * only, for reports.view or performance.team; the database checks again on every read. Ids, statuses, codes, amounts and
 * the CRM's links only: never a name, email, phone or address. The address keys are o, market, asOf, range, from, to,
 * sort, dir, page, measure and f_<dim>.
 */
export default async function FlashPage({ searchParams }: PageProps<"/reports/flash">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.flash;
  const locale = me.locale;

  if (!holdsAny(me, REPORT_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="flash">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={copy.reports.noPermissionTitle} body={copy.reports.noPermissionBody} />
      </Shell>
    );
  }

  const sp = await searchParams;
  const one = (k: string): string | undefined => { const v = sp[k]; return Array.isArray(v) ? v[0] : v; };
  const today = dateKeyInZone(new Date(), me.timeZone);
  const def = overviewOf(one("o"));
  const market = parseMarket(one("market"));
  const marketProblem = one("market") !== undefined && one("market") !== "" && market === null;
  const parsedAsOf = parseAsOf(one("asOf"), today);
  const asOf = parsedAsOf.asOf;
  // the flows' period: the period bar's range (today when none, as every report), never past today, nor past As of
  const { range, period, invalid } = resolvePeriod(sp, today, 366);
  const cap = asOf ?? today;
  const to = period.to > cap ? cap : period.to;
  const from = period.from > to ? to : period.from;
  const periodQuery: Record<string, string> = range === "custom" && !invalid ? { range, from: period.from, to: period.to } : { range };
  const base: Record<string, string> = { ...(market ? { market } : {}), ...(asOf ? { asOf } : {}), ...periodQuery };
  const more = (overview: string) => metricsMore(me.permissions, metricKey(overview as FlashOverviewDef["key"], overviewOf(overview)!.headline), t.howComputed);

  const top = (markets: { code: string; name: string }[], firstSnapshot: string | null, showPeriod: boolean) => (
    <div className="mb-4 flex flex-wrap items-end justify-between gap-6">
      <div className="flex flex-wrap items-end gap-6">
        <FlashAsOf asOf={asOf} min={firstSnapshot} max={addDays(today, -1)} query={{ ...base, ...(def ? { o: def.key } : {}) }} labels={{ asOf: t.asOf, now: t.now }} />
        <FlashMarket market={market} markets={markets} query={{ ...base, ...(def ? { o: def.key } : {}) }}
          labels={{ market: t.market, allMarkets: t.allMarkets, unknownMarket: t.unknownMarket }} />
      </div>
      {showPeriod ? (
        <div className="flex flex-col gap-2">
          <span className="text-caption text-p4a-muted">{t.periodFlows}</span>
          <PeriodBar pathname="/reports/flash" range={range} period={period} today={today} copy={copy}
            keep={{ ...(market ? { market } : {}), ...(asOf ? { asOf } : {}), ...(def ? { o: def.key } : {}) }} />
        </div>
      ) : null}
    </div>
  );

  const notices = (
    <>
      {parsedAsOf.problem ? <div className="mb-4"><Notice tone="warning">{t.asOfIgnored}</Notice></div> : null}
      {marketProblem || invalid ? <div className="mb-4"><Notice tone="warning">{t.filterIgnored}</Notice></div> : null}
    </>
  );

  // ---- the landing -----------------------------------------------------------------------------------------------
  if (!def) {
    const page: FlashPageView = await data().getFlashPage(me, market, asOf, from, to);
    const sourceLabel = (s: string | null) => (s ? String(t[`source_${s}` as keyof typeof t]) : "");
    return (
      <Shell copy={copy} me={me} active="flash" wide>
        <PageTitle>{t.title}</PageTitle>
        <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted" data-hint-anchor="">
          <HintLabel label={t.intro}><HeaderHint label={copy.hints.about.replace("{label}", t.asOf)} text={t.asOfHint} /></HintLabel>
        </p>
        {top(page.markets, page.firstSnapshotDate, true)}
        <SourcesLine sources={page.sources} timeZone={me.timeZone} locale={locale} t={t} />
        {notices}
        {page.snapshotMissing ? (
          <div className="mb-6" data-testid="flash-snapshot-missing">
            <Notice tone="info">
              {t.noSnapshot}.{" "}
              {t.nearest.replace("{before}", page.nearestBefore ? fmtDate(page.nearestBefore, locale) : t.nearestNone)
                .replace("{after}", page.nearestAfter ? fmtDate(page.nearestAfter, locale) : t.nearestNone)}.{" "}
              {page.nearestBefore ? <Link href={`/reports/flash?${new URLSearchParams({ ...base, asOf: page.nearestBefore })}` as Route} className="font-semibold text-p4a-deepblue underline">{fmtDate(page.nearestBefore, locale)}</Link> : null}
              {page.nearestBefore && page.nearestAfter ? " · " : null}
              {page.nearestAfter ? <Link href={`/reports/flash?${new URLSearchParams({ ...base, asOf: page.nearestAfter })}` as Route} className="font-semibold text-p4a-deepblue underline">{fmtDate(page.nearestAfter, locale)}</Link> : null}
            </Notice>
          </div>
        ) : null}
        {page.firstSnapshotDate === null ? (
          <div className="mb-6" data-testid="flash-no-snapshots"><Notice tone="info">{t.noSnapshotsYet}</Notice></div>
        ) : asOf && asOf < page.firstSnapshotDate ? (
          <div className="mb-6"><Notice tone="info">{t.snapshotsStart.replace("{date}", fmtDate(page.firstSnapshotDate, locale))}</Notice></div>
        ) : null}
        <WatchStrip items={page.watch} query={base} t={t} copy={copy} locale={locale} />
        {!page.snapshotMissing ? (
          <div className="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-4" data-testid="flash-cards">
            {FLASH_OVERVIEWS.map((o) => {
              const card = page.overviews.find((c) => c.key === o.key);
              const setUp = card?.setUp ?? false;
              const previousOnText = card?.previousOn ? fmtDate(card.previousOn, locale) : null;
              const figure = asOf ? (
                <span className="tabular text-title font-bold text-p4a-heading" data-testid={`flash-value-${o.key}`}>
                  {card?.value === null || card?.value === undefined ? "–" : fmtNumber(card.value, locale, 1)}
                </span>
              ) : (
                <FlashLiveFigure overview={o.key} market={market} from={o.kind === "flow" ? from : null} to={o.kind === "flow" ? to : null}
                  previous={card?.previous ?? null} locale={locale}
                  labels={{ loading: t.loading, changeSince: t.changeSince, changeFlat: t.changeFlat, noCompare: t.noCompare, previousOnText }} />
              );
              return (
                <FlashCard key={o.key} def={o} setUp={setUp} sourceLabel={sourceLabel(o.source)} figure={figure} query={base} t={t}
                  change={asOf ? changeText(card?.value ?? null, card?.previous ?? null, card?.previousOn ?? null, locale, t) : null} />
              );
            })}
          </div>
        ) : null}
        {dataIsMock ? <div className="mt-6"><Notice tone="info">{copy.shell.testData}</Notice></div> : null}
      </Shell>
    );
  }

  // ---- an overview -----------------------------------------------------------------------------------------------
  const filters = parseFilters(def, one);
  if (market) filters.market = market;
  const { sort, descending } = parseSort(def, one("sort"), one("dir"));
  const pageNo = Math.max(1, Math.min(10_000, Number.parseInt(one("page") ?? "1", 10) || 1));
  const monthEnd = asOf !== null && addDays(asOf, 1).slice(8, 10) === "01";
  const frozenKind = def.key === "customers" || def.key === "subscriptions" || def.key === "installed_base";
  // records: live for now and for a flow's period; a past month end's frozen list for those three; none else
  const withRows = def.kind === "flow" || asOf === null || (monthEnd && frozenKind);
  const rowsAsOf = def.kind === "stock" && asOf !== null ? asOf : null;
  let doc: FlashDocumentView | null = null;
  let rows: FlashRowsView | null = null;
  let missing = false;
  try {
    const v = await data().getFlashView(me, {
      overview: def.key, market, asOf, from: def.kind === "flow" ? from : null, to: def.kind === "flow" ? to : null,
      filters, sort: rowsAsOf ? null : sort, descending, limit: FLASH_PAGE_ROWS, offset: (pageNo - 1) * FLASH_PAGE_ROWS, withRows, rowsAsOf,
    });
    doc = v.document;
    rows = v.rows;
  } catch (e) {
    if (!(e instanceof CmaDbError && e.sqlState === "CMA02")) throw e;
    missing = true;
  }
  const query: Record<string, string> = { ...base, o: def.key,
    ...Object.fromEntries(Object.entries(filters).filter(([k]) => k !== "market" && k !== "measure").map(([k, v]) => [`f_${k}`, v])),
    ...(filters.measure ? { measure: filters.measure } : {}), ...(one("sort") ? { sort } : {}), ...(one("dir") ? { dir: descending ? "desc" : "asc" } : {}) };
  const listQuery = { ...query, page: String(pageNo) };
  const fileQuery = new URLSearchParams({ overview: def.key, ...(market ? { market } : {}), ...(asOf && def.kind === "stock" ? { asOf } : {}),
    ...(def.kind === "flow" ? { from, to } : {}), ...Object.fromEntries(Object.entries(filters).filter(([k]) => k !== "market" && k !== "measure").map(([k, v]) => [`f_${k}`, v])),
    ...(filters.measure ? { measure: filters.measure } : {}), ...(rowsAsOf ? {} : { sort, dir: descending ? "desc" : "asc" }) });
  // the breakdown's file follows the figures on screen: As of for a stock and a flow alike, never the list's filters
  const breakdownQuery = new URLSearchParams({ overview: def.key, part: "breakdown", ...(market ? { market } : {}), ...(asOf ? { asOf } : {}),
    ...(def.kind === "flow" ? { from, to } : {}) });
  const hasFilters = Object.keys(filters).some((k) => k !== "market");
  const totalPages = rows ? Math.max(1, Math.ceil(rows.total / FLASH_PAGE_ROWS)) : 1;
  const sourceLabel = def.source ? String(t[`source_${def.source}` as keyof typeof t]) : "";

  return (
    <Shell copy={copy} me={me} active="flash" wide>
      <PageTitle>{t.title}</PageTitle>
      <FlashStrip active={def.key} query={base} t={t} />
      {top(Object.entries(doc?.labels.market ?? {}).filter(([code]) => code !== "unknown").map(([code, name]) => ({ code, name })), doc?.firstSnapshotDate ?? null,
        def.kind === "flow")}
      {doc ? <SourcesLine sources={doc.sources} timeZone={me.timeZone} locale={locale} t={t} /> : null}
      {notices}
      <p className="mb-6"><Link href={`/reports/flash?${new URLSearchParams(base)}` as Route} className="font-semibold text-p4a-deepblue underline">{t.back}</Link></p>

      {missing || !doc ? (
        <div data-testid="flash-snapshot-missing"><Notice tone="info">{t.noSnapshot}</Notice></div>
      ) : !doc.setUp ? (
        <Card>
          <OverviewHeading def={def} t={t} more={more(def.key)} />
          <p className="text-body text-p4a-muted" data-testid="flash-not-set-up">{t.notSetUp.replace("{source}", sourceLabel)}</p>
        </Card>
      ) : (
        <div className="flex flex-col gap-6">
          <section aria-label={String(t[`o_${def.key}` as keyof typeof t])}>
            <OverviewHeading def={def} t={t} more={more(def.key)} />
            {doc.days && doc.days.missing.length > 0 ? (
              <div className="mb-4"><Notice tone="info">{t.daysMissing.replace("{covered}", String(doc.days.covered))
                .replace("{missing}", doc.days.missing.map((d) => fmtDate(d, locale)).join(", "))}</Notice></div>
            ) : null}
            <TotalsRow def={def} doc={doc} locale={locale} t={t} />
            {def.key === "churn" && doc.activeAtEnd !== null ? (
              <p className="-mt-2 mb-4 text-small text-p4a-muted">{t.activeAtEnd.replace("{n}", fmtNumber(doc.activeAtEnd, locale))}</p>
            ) : null}
          </section>

          {def.key === "data_quality" ? (
            <Card title={t.dqTitle}>
              <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted">{t.dqIntro}</p>
              <DataQualityTable doc={doc} query={query} locale={locale} t={t} />
            </Card>
          ) : (
            <>
              <Card title={t.perMarket}>
                <MarketBars def={def} doc={doc} locale={locale} t={t} />
              </Card>
              {breakdownSets(def).map((set) => (
                <Card key={set.join("+")} title={`${t.breakdown}: ${set.map((d) => String(t[`d_${d}` as keyof typeof t] ?? d)).join(", ")}`}>
                  <BreakdownTable def={def} doc={doc} set={set} query={query} locale={locale} t={t} />
                </Card>
              ))}
            </>
          )}
          <div className="-mt-2 flex justify-end">
            <LinkButton href={`/api/v1/reports/flash/file?${breakdownQuery.toString()}`} download data-testid="flash-download-breakdown"
              title={t.downloadHint.replace("{n}", fmtNumber(doc.settings.fileMaxRows, locale))}>{t.downloadBreakdown}</LinkButton>
          </div>

          <section id="records" aria-label={t.rows}>
            <Card title={hasFilters ? t.rowsFor.replace("{filter}", filtersText(null, null, null, Object.fromEntries(Object.entries(filters).filter(([k]) => k !== "market")))) : t.rows}>
              {!withRows ? (
                <Notice tone="info">{t.listsAtMonthEnd}</Notice>
              ) : rows ? (
                <>
                  <div className="mb-4 flex flex-wrap items-center justify-between gap-4 text-small">
                    <span className="text-p4a-muted" data-testid="flash-rows-count">
                      {t.rowsShown.replace("{shown}", fmtNumber(rows.rows.length, locale)).replace("{total}", fmtNumber(rows.total, locale))}
                      {rows.mode === "snapshot" ? ` · ${t.frozenList}` : ""}
                    </span>
                    <span className="flex flex-wrap items-center gap-4">
                      {hasFilters ? <Link href={`/reports/flash?${new URLSearchParams(Object.fromEntries(Object.entries(query).filter(([k]) => !k.startsWith("f_") && k !== "measure")))}` as Route}
                        className="font-semibold text-p4a-deepblue underline">{t.clearFilter}</Link> : null}
                      <LinkButton href={`/api/v1/reports/flash/file?${fileQuery.toString()}`} download shortcut="X" data-shortcut="x" data-testid="flash-download"
                        title={t.downloadHint.replace("{n}", fmtNumber(doc.settings.fileMaxRows, locale))}>{t.download}</LinkButton>
                    </span>
                  </div>
                  <RowsTable def={def} rows={rows} sort={rowsAsOf ? null : sort} descending={descending} query={listQuery} locale={locale} timeZone={me.timeZone} t={t} />
                  {totalPages > 1 ? (
                    <div className="mt-4 flex items-center gap-4 text-small">
                      {pageNo > 1 ? <Link href={`/reports/flash?${new URLSearchParams({ ...query, page: String(pageNo - 1) })}#records` as Route} className="font-semibold text-p4a-deepblue underline">{t.previousPage}</Link> : null}
                      <span className="text-p4a-muted">{pageNo} / {totalPages}</span>
                      {pageNo < totalPages ? <Link href={`/reports/flash?${new URLSearchParams({ ...query, page: String(pageNo + 1) })}#records` as Route} className="font-semibold text-p4a-deepblue underline">{t.nextPage}</Link> : null}
                    </div>
                  ) : null}
                </>
              ) : null}
            </Card>
          </section>
        </div>
      )}

      {dataIsMock ? <div className="mt-6"><Notice tone="info">{copy.shell.testData}</Notice></div> : null}
    </Shell>
  );
}
