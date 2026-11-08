import { Suspense } from "react";
import { FlashChoice, FlashMarket, FlashModel } from "@/components/FlashControls";
import { OverviewHeading, SourcesLine, TotalsRow } from "@/components/FlashParts";
import {
  BreakdownPanel, breakdownFileQuery, listFileQuery, ListPanel, listOf, ListSkeleton, ModelDonut, MarketStacks, PanelTabs, SerialSearch, stacksOf, TitledCard,
  type ListRead,
} from "@/components/InstalledBase";
import { NoReportPermission } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock, streamed } from "@/lib/data";
import { FLASH_ADDRESS, metricKey, modelChoicesOf, narrowDocument, parseFilters, splitOf, splitOrderOf } from "@/lib/flash";
import { donutSlices, INSTALLED_BASE_ADDRESS, INSTALLED_BASE_PAGE_ROWS, INSTALLED_BASE_PATH, installedBaseState, LIST_PANELS, statusChoicesOf } from "@/lib/installed-base";
import { metricsMore } from "@/lib/metrics";
import { holdsAny } from "@/lib/nav";
import { REPORT_PERMISSIONS } from "@/lib/reports";
import { fmtDateTime } from "@/lib/time";
import { resolve } from "../../access";

/**
 * Assets → Installed base, the "now" view (addition 0009f; Martin, 8 November 2026, D1 to D7; a page of the Assets
 * group since 0008zw). No As of: Flash's Installed base tab keeps the history. The default view loads the stored current
 * take's figures alone (0009e: one document read, shown with Refreshed at, live when the take may not be read): the
 * filters (Market K, Model D, Operational status S), the tiles of today, In the field per model as a donut and per market
 * stacked per model. The records, the two breakdowns, the work lists (Devices past due; In the field without a linked
 * subscription) and the serial search load only when asked, as address state (panel=, serial=), one at a time, each a
 * server-rendered segment under a skeleton sized like its content; a list's read starts with the document's and streams
 * after the first paint (0008zz). Every filter applies to the tiles, the donut, Per market and every list (lib/flash
 * narrowDocument from the take's rows); what the take cannot give for a filter says so. Team figures only, for
 * reports.view or performance.team; the database checks again on every read. Serials, ids, statuses, codes and the
 * CRM's links only: never a name, email, phone or address.
 */
export default async function InstalledBasePage({ searchParams }: PageProps<"/reports/installed-base">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const title = copy.nav.installedBase;
  const t = copy.flash;
  const ib = copy.installedBase;
  const locale = me.locale;

  if (!holdsAny(me, REPORT_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="installed-base">
        <PageTitle>{title}</PageTitle>
        <NoReportPermission title={copy.reports.noPermissionTitle} body={copy.reports.noPermissionBody} />
      </Shell>
    );
  }

  const st = installedBaseState(await searchParams, parseFilters);
  const def = st.def;
  // the list a panel or the search asks for, read alongside the document (never before the first paint waits for it)
  const list = listOf(st, copy);
  const read: Promise<ListRead> | null = list
    ? streamed(() => data().getFlashRows(me, {
      overview: def.key, market: st.market, asOf: null, from: null, to: null, filters: list.filters, sort: st.sort, descending: st.descending,
      limit: INSTALLED_BASE_PAGE_ROWS, offset: (st.pageNo - 1) * INSTALLED_BASE_PAGE_ROWS,
    })).then((rows) => ({ rows, error: null }), (error: unknown) => ({ rows: null, error }))
    : null;
  // the document alone: now, from the stored current take when it may be read (0009e), the market's when one is chosen
  const doc = await data().getFlashOverview(me, def.key, st.market, null, null, null);
  // narrowed by the page filters (the model, the operational status): every tile, chart and breakdown of those values; what
  // the take cannot give for them is said so (narrowed.unavailableMeasures, unavailableSets), never a figure
  const narrowed = narrowDocument(def, doc.totals, doc.rows, st.pageFilters);
  const filtered = Object.keys(st.pageFilters).length > 0;
  const shown = { ...doc, totals: narrowed.totals, rows: narrowed.rows as typeof doc.rows };
  const more = metricsMore(me.permissions, metricKey(def.key, def.headline), t.howComputed);
  const markets = Object.entries(doc.labels.market ?? {}).filter(([code]) => code !== "unknown").map(([code, name]) => ({ code, name }));
  const marketName = (code: string) => (code === "unknown" ? t.unknownMarket : doc.labels.market?.[code] ?? code);
  // the donut: In the field per model from the set that carries the model with every measure (the split's rule, 0008zy),
  // of the market shown; the page filters narrow it too, and a Model filter leaves that model alone (one slice, not the
  // register's other models at 0)
  const split = (splitOf(def, narrowed.rows, null, splitOrderOf(def, doc.statusSettings, doc.splitOrder)) ?? [])
    .filter((x) => !st.pageFilters.model || x.key === st.pageFilters.model);
  const { slices, total } = donutSlices(split);
  const stacks = stacksOf(def, narrowed.rows, slices);
  const splitUnavailable = narrowed.unavailableMeasures.includes(def.headline);
  // the address every link keeps: the market and the page filters, then the open panel or the search, then the list's own
  // filters a breakdown cell set (f_<dim>) and the measure
  const panelKeys: Record<string, string> = st.serial ? { [INSTALLED_BASE_ADDRESS.serial]: st.serial } : st.panel ? { [INSTALLED_BASE_ADDRESS.panel]: st.panel } : {};
  const ownFilters = Object.fromEntries(Object.entries(st.filters).filter(([k]) => k !== "market" && k !== "measure" && !(k in st.pageFilters))
    .map(([k, v]) => [`${FLASH_ADDRESS.filterPrefix}${k}`, v]));
  const query: Record<string, string> = { ...st.base, ...panelKeys, ...ownFilters, ...(st.filters.measure ? { measure: st.filters.measure } : {}),
    ...(st.sort !== def.sorts[0] || st.descending !== def.defaultDescending ? { sort: st.sort, dir: st.descending ? "desc" : "asc" } : {}) };
  // a breakdown's cell opens the records with the row's filters
  const cellQuery: Record<string, string> = { ...st.base, [INSTALLED_BASE_ADDRESS.panel]: "records" };
  const panelOpen = st.serial ? null : st.panel;
  const storedFigures = Boolean(doc.refreshedAt);

  return (
    <Shell copy={copy} me={me} active="installed-base" wide>
      <PageTitle>{title}</PageTitle>
      <p className="-mt-4 mb-6 max-w-4xl text-body text-p4a-muted">{ib.intro}</p>
      <div className="mb-4 flex flex-wrap items-end justify-between gap-6">
        <div className="flex flex-wrap items-end gap-6">
          <FlashMarket market={st.market} markets={markets} query={{ ...st.base, ...panelKeys }} labels={{ market: t.market, allMarkets: t.allMarkets, unknownMarket: t.unknownMarket }}
            path={INSTALLED_BASE_PATH} />
          <FlashModel model={st.pageFilters.model ?? null} models={modelChoicesOf(doc.labels, doc.rows, doc.splitOrder)} query={{ ...st.base, ...panelKeys }}
            labels={{ model: t.modelFilter, allModels: t.allModels, unknownModel: t.unknownModel }} path={INSTALLED_BASE_PATH} />
          <FlashChoice dim="status" value={st.pageFilters.status ?? null} choices={statusChoicesOf(doc.labels, doc.rows)} query={{ ...st.base, ...panelKeys }}
            labels={{ label: ib.statusFilter, all: ib.allStatuses, unknown: ib.unknownStatus }} keycap="s" testId="ib-status" path={INSTALLED_BASE_PATH} />
        </div>
        <SerialSearch st={st} copy={copy} />
      </div>
      <SourcesLine sources={doc.sources} timeZone={me.timeZone} locale={locale} t={t} />
      {st.marketProblem ? <div className="mb-4"><Notice tone="warning">{t.filterIgnored}</Notice></div> : null}

      {!doc.setUp ? (
        <Card>
          <OverviewHeading def={def} t={t} more={more} statusSettings={doc.statusSettings} locale={locale} />
          <p className="text-body text-p4a-muted" data-testid="flash-not-set-up">{t.notSetUp.replace("{source}", String(t[`source_${def.source}` as keyof typeof t]))}</p>
        </Card>
      ) : (
        <div className="flex flex-col gap-6">
          <section aria-label={t.o_installed_base}>
            <OverviewHeading def={def} t={t} more={more} statusSettings={doc.statusSettings} locale={locale} />
            {doc.refreshedAt ? (
              <p className="-mt-2 mb-4 text-caption text-p4a-grey" data-testid="flash-refreshed-at" title={t.storedHint}>
                {t.refreshedAt.replace("{time}", fmtDateTime(doc.refreshedAt, me.timeZone, locale))}
              </p>
            ) : null}
            <TotalsRow def={def} doc={shown} locale={locale} t={t} unavailable={narrowed.unavailableMeasures} filtered={filtered} withSplit={false}
              unavailableText={ib.filterUnavailable} />
          </section>

          <div className="grid gap-6 xl:grid-cols-2">
            <TitledCard title={ib.splitTitle} hint={ib.splitHint} copy={copy} testId="ib-split-card">
              {splitUnavailable ? <p className="text-body text-p4a-muted" data-testid="ib-split-unavailable">{ib.filterUnavailable}</p>
                : <ModelDonut slices={slices} total={total} labels={doc.labels} locale={locale} copy={copy} />}
            </TitledCard>
            <TitledCard title={ib.perMarketTitle} hint={ib.perMarketHint} copy={copy} testId="ib-market-card">
              {splitUnavailable ? <p className="text-body text-p4a-muted">{ib.filterUnavailable}</p>
                : <MarketStacks stacks={stacks} labels={doc.labels} locale={locale} copy={copy} marketName={marketName} />}
            </TitledCard>
          </div>

          <PanelTabs st={st} copy={copy} />

          {panelOpen === "breakdown" || panelOpen === "subscription" ? (
            <BreakdownPanel panel={panelOpen} def={def} doc={doc} rows={narrowed.rows} query={cellQuery} fileQuery={breakdownFileQuery(st)} locale={locale} copy={copy}
              unavailable={narrowed.unavailableSets.includes((def.sets.find((s) => (panelOpen === "breakdown" ? s.includes("warehouse") : s.includes("subscription_status"))) ?? []).join("+"))} />
          ) : null}

          {list && read && (st.serial || (st.panel && LIST_PANELS.includes(st.panel))) ? (
            <section id="records" aria-label={list.title}>
              <Suspense fallback={<Card title={list.title}><ListSkeleton label={ib.loading} rows={Math.min(INSTALLED_BASE_PAGE_ROWS, 8)} /></Card>}>
                <ListPanel title={list.title} note={list.note} read={read} def={def} st={st} query={query} fileQuery={listFileQuery(st, list.filters)} labels={doc.labels}
                  fileMaxRows={doc.settings.fileMaxRows} storedFigures={storedFigures} me={{ locale, timeZone: me.timeZone }} copy={copy} />
              </Suspense>
            </section>
          ) : null}
        </div>
      )}

      {dataIsMock ? <div className="mt-6"><Notice tone="info">{copy.shell.testData}</Notice></div> : null}
    </Shell>
  );
}
