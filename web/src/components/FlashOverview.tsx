/**
 * One Flash overview as a page, shared by Reports → Flash (every overview, chosen by o) and Assets → Installed base (the
 * installed base's overview alone, addition 0008zw): the address both read (the overview, the market (K), As of (A), the
 * period), the state the reads may correct (the tenant's today adopted on a refusal), the top line's controls, the
 * notices, and the overview's document and first page of records read in one transaction (getFlashView), with the
 * per-market bars, the breakdowns, the records and their files. Moved out of the Flash page so both pages render the
 * same data path, filters, As of and files; every link and control keeps the page it is rendered on (lib/flash
 * FlashPath). Team figures only, for reports.view or performance.team (the pages check it; the database again on every
 * read). Ids, statuses, codes, amounts and the CRM's links only: never a name, email, phone or address.
 */
import Link from "next/link";
import type { Route } from "next";
import { FlashAsOf, FlashMarket } from "@/components/FlashControls";
import {
  BandTable, BreakdownTable, DataQualityTable, FlashStrip, fmtNumber, MarketBars, OverviewHeading, RowsTable, SourcesLine, TotalsRow,
} from "@/components/FlashParts";
import { PeriodBar } from "@/components/PeriodBar";
import { Shell } from "@/components/Shell";
import { Card, LinkButton, Notice, PageTitle } from "@/components/primitives";
import type { Principal } from "@/lib/auth/identity";
import type { Copy } from "@/lib/copy";
import { CmaDbError, data, dataIsMock, type FlashDocumentView, type FlashRowsView, type HoursRange } from "@/lib/data";
import {
  bandDimOf, breakdownSets, FLASH_FROZEN_LIST, FLASH_PAGE_ROWS, filtersShown, filtersText, flashHref, frozenFilters, listUnavailable, metricKey, overviewOf,
  parseAsOf, parseFilters, parseMarket, parseSort, type FlashKey, type FlashOverviewDef, type FlashPath,
} from "@/lib/flash";
import { metricsMore } from "@/lib/metrics";
import type { ShellPage } from "@/lib/nav";
import { resolvePeriod, type Range } from "@/lib/period";
import { addDays, dateKeyInZone, fmtDate, fmtDateTime } from "@/lib/time";

type Query = Record<string, string | string[] | undefined>;

/**
 * The address of a Flash page and what the reads may correct. As of is a business date before the tenant's today, and a
 * flow's period ends that today at the latest. The reader's today stands for it until the database answers: for a reader
 * ahead of the tenant's zone, As of or the period's end can be the tenant's today or later, which the database refuses
 * (CMA04). The page then asks the database for the tenant's today (the snapshots' read, whose period ends there), caps
 * the period at it, drops an As of that is not before it (asOfProblem: the notice) and reads again: never an error page
 */
export interface FlashState {
  one: (k: string) => string | undefined;
  /** The overview shown: o's on Reports → Flash (none: the landing), the page's own elsewhere */
  def: FlashOverviewDef | null;
  market: string | null;
  marketProblem: boolean;
  /** The flows' period: the period bar's range (today when none, as every report), never past today, nor past As of */
  range: Range;
  period: HoursRange;
  invalid: null | "order" | "length";
  today: string;
  asOf: string | null;
  asOfProblem: boolean;
  from: string;
  to: string;
  /** The address keys every link keeps: the market, As of, the period */
  base: Record<string, string>;
  /** The tenant's today adopted after a refusal (CMA04), the period capped at it and an As of not before it dropped */
  adoptTenantToday: () => Promise<void>;
}

/** A Flash page's state from its address; fixed: the overview a page shows whatever o says (Assets → Installed base) */
export function flashState(me: Principal, sp: Query, fixed?: FlashKey): FlashState {
  const one = (k: string): string | undefined => { const v = sp[k]; return Array.isArray(v) ? v[0] : v; };
  // the reader's today; the tenant's decides (below: the database's, on a refusal)
  const today = dateKeyInZone(new Date(), me.timeZone);
  const parsedAsOf = parseAsOf(one("asOf"), today);
  const market = parseMarket(one("market"));
  const { range, period, invalid } = resolvePeriod(sp, today, 366);
  const periodQuery: Record<string, string> = range === "custom" && !invalid ? { range, from: period.from, to: period.to } : { range };
  const st: FlashState = {
    one, def: overviewOf(fixed ?? one("o")), market, marketProblem: one("market") !== undefined && one("market") !== "" && market === null,
    range, period, invalid, today, asOf: parsedAsOf.asOf, asOfProblem: parsedAsOf.problem, from: today, to: today, base: {},
    adoptTenantToday: async () => {
      st.today = (await data().getFlashSnapshots(me, null, null)).to;
      if (st.asOf !== null && st.asOf >= st.today) {
        st.asOf = null;
        st.asOfProblem = true;
      }
      shape();
    },
  };
  function shape() {
    const cap = st.asOf ?? st.today;
    st.to = period.to > cap ? cap : period.to;
    st.from = period.from > st.to ? st.to : period.from;
    st.base = { ...(market ? { market } : {}), ...(st.asOf ? { asOf: st.asOf } : {}), ...periodQuery };
  }
  shape();
  return st;
}

/** The database refused the period or As of as past the tenant's today (CMA04) */
export const tenantTodayRefused = (e: unknown) => e instanceof CmaDbError && e.sqlState === "CMA04";

/** The address keys of the overview itself: o on Reports → Flash, none on a page of one overview */
function overviewKeys(path: FlashPath, def: FlashOverviewDef | null): Record<string, string> {
  return path === "/reports/flash" && def ? { o: def.key } : {};
}

/**
 * The top line: As of (the date control's last date is the day before the tenant's today, once the database has said
 * which day that is), the market and, for a flow, the period bar
 */
export function FlashTop({ st, path, copy, markets, firstSnapshot, showPeriod, tenantToday }: {
  st: FlashState; path: FlashPath; copy: Copy; markets: { code: string; name: string }[]; firstSnapshot: string | null; showPeriod: boolean;
  tenantToday: string | null;
}) {
  const t = copy.flash;
  const keys = overviewKeys(path, st.def);
  return (
    <div className="mb-4 flex flex-wrap items-end justify-between gap-6">
      <div className="flex flex-wrap items-end gap-6">
        <FlashAsOf asOf={st.asOf} min={firstSnapshot} max={addDays(tenantToday || st.today, -1)} query={{ ...st.base, ...keys }} labels={{ asOf: t.asOf, now: t.now }}
          path={path} />
        <FlashMarket market={st.market} markets={markets} query={{ ...st.base, ...keys }}
          labels={{ market: t.market, allMarkets: t.allMarkets, unknownMarket: t.unknownMarket }} path={path} />
      </div>
      {/* a flow's period: Reports → Flash's flows only (Assets → Installed base is a stock) */}
      {showPeriod && path === "/reports/flash" ? (
        <div className="flex flex-col gap-2">
          <span className="text-caption text-p4a-muted">{t.periodFlows}</span>
          <PeriodBar pathname="/reports/flash" range={st.range} period={st.period} today={st.today} copy={copy}
            keep={{ ...(st.market ? { market: st.market } : {}), ...(st.asOf ? { asOf: st.asOf } : {}), ...keys }} />
        </div>
      ) : null}
    </div>
  );
}

/** As of ignored, a filter ignored (a market or a period the page could not read) */
export function FlashNotices({ st, copy }: { st: FlashState; copy: Copy }) {
  const t = copy.flash;
  return (
    <>
      {st.asOfProblem ? <div className="mb-4"><Notice tone="warning">{t.asOfIgnored}</Notice></div> : null}
      {st.marketProblem || st.invalid ? <div className="mb-4"><Notice tone="warning">{t.filterIgnored}</Notice></div> : null}
    </>
  );
}

/**
 * An overview's page: its document and its first page of records in one transaction, now from the sources or as of a
 * business date with a snapshot, per market, the flows over the period bar; on Reports → Flash with the overviews' strip
 * and the way back to the landing, on a page of one overview (Assets → Installed base) under that page's own title
 */
export async function FlashOverview({ me, copy, st, def, path, active, title }: {
  me: Principal; copy: Copy; st: FlashState; def: FlashOverviewDef; path: FlashPath; active: ShellPage; title: string;
}) {
  const t = copy.flash;
  const locale = me.locale;
  const one = st.one;
  const own = path === "/reports/flash";
  const more = (overview: FlashKey) => metricsMore(me.permissions, metricKey(overview, overviewOf(overview)!.headline), t.howComputed);
  const filters = parseFilters(def, one);
  if (st.market) filters.market = st.market;
  const { sort, descending } = parseSort(def, one("sort"), one("dir"));
  const pageNo = Math.max(1, Math.min(10_000, Number.parseInt(one("page") ?? "1", 10) || 1));
  // records: live for now and for a flow's period; a past month end's frozen list for customers, subscriptions and the
  // installed base, which takes the market, the status and its own measure only (the cell's other filters are named in
  // a notice, never sent: the database refuses them); none else
  const rowsPlan = () => {
    const monthEnd = st.asOf !== null && addDays(st.asOf, 1).slice(8, 10) === "01";
    const frozen = def.kind === "stock" && st.asOf !== null && FLASH_FROZEN_LIST[def.key] !== undefined && monthEnd;
    const split = frozen ? frozenFilters(def, filters) : { kept: filters, dropped: [] as string[] };
    return { withRows: def.kind === "flow" || st.asOf === null || frozen, rowsAsOf: def.kind === "stock" && st.asOf !== null ? st.asOf : null,
      rowFilters: split.kept, dropped: split.dropped };
  };
  // the plan and what the reads gave (an object: the reads below fill it from their closures, the plan made again after
  // the tenant's today is adopted)
  const got: { plan: ReturnType<typeof rowsPlan>; doc: FlashDocumentView | null; rows: FlashRowsView | null } = { plan: rowsPlan(), doc: null, rows: null };
  let missing = false;
  // the list could not answer for this date or these filters (CMA02, CMA04): the overview shows, the list says so
  let rowsUnavailable = false;
  const read = (withRows: boolean) => data().getFlashView(me, {
    overview: def.key, market: st.market, asOf: st.asOf, from: def.kind === "flow" ? st.from : null, to: def.kind === "flow" ? st.to : null,
    filters: got.plan.rowFilters, sort: got.plan.rowsAsOf ? null : sort, descending, limit: FLASH_PAGE_ROWS, offset: (pageNo - 1) * FLASH_PAGE_ROWS, withRows,
    rowsAsOf: got.plan.rowsAsOf,
  });
  const take = async (withRows: boolean): Promise<void> => {
    const v = await read(withRows);
    got.doc = v.document;
    got.rows = v.rows;
  };
  // the document's own refusals: no snapshot for the date (CMA02, "missing"); As of or the period past the tenant's
  // today (CMA04): the tenant's today adopted and read again ("again")
  const retryRefused = async (): Promise<void> => {
    await st.adoptTenantToday();
    got.plan = rowsPlan();
    await take(got.plan.withRows);
  };
  const takeDocument = async (withRows: boolean): Promise<"ok" | "missing" | "again"> => {
    try {
      await take(withRows);
      return "ok";
    } catch (e) {
      if (e instanceof CmaDbError && e.sqlState === "CMA02") return "missing";
      if (!tenantTodayRefused(e)) throw e;
      await retryRefused();
      return "again";
    }
  };
  try {
    await take(got.plan.withRows);
  } catch (e) {
    if (!(e instanceof CmaDbError)) throw e;
    if (got.plan.withRows && listUnavailable(e.sqlState)) {
      // the list refused, or the document did: the document alone tells which
      const outcome = await takeDocument(false);
      missing = outcome === "missing";
      rowsUnavailable = outcome === "ok";
    } else if (e.sqlState === "CMA02") {
      missing = true;
    } else if (tenantTodayRefused(e)) {
      await retryRefused();
    } else {
      throw e;
    }
  }
  const { withRows, rowsAsOf, rowFilters, dropped } = got.plan;
  const { doc, rows } = got;
  const { base, asOf, from, to } = st;
  const query: Record<string, string> = { ...base, ...overviewKeys(path, def),
    ...Object.fromEntries(Object.entries(filters).filter(([k]) => k !== "market" && k !== "measure").map(([k, v]) => [`f_${k}`, v])),
    ...(filters.measure ? { measure: filters.measure } : {}), ...(one("sort") ? { sort } : {}), ...(one("dir") ? { dir: descending ? "desc" : "asc" } : {}) };
  const listQuery = { ...query, page: String(pageNo) };
  // the records' file asks what the list read: a frozen list's file only the filters it takes
  const fileQuery = new URLSearchParams({ overview: def.key, ...(st.market ? { market: st.market } : {}), ...(asOf && def.kind === "stock" ? { asOf } : {}),
    ...(def.kind === "flow" ? { from, to } : {}), ...Object.fromEntries(Object.entries(rowFilters).filter(([k]) => k !== "market" && k !== "measure").map(([k, v]) => [`f_${k}`, v])),
    ...(rowFilters.measure ? { measure: rowFilters.measure } : {}), ...(rowsAsOf ? {} : { sort, dir: descending ? "desc" : "asc" }) });
  // the breakdown's file follows the figures on screen: As of for a stock and a flow alike, never the list's filters
  const breakdownQuery = new URLSearchParams({ overview: def.key, part: "breakdown", ...(st.market ? { market: st.market } : {}), ...(asOf ? { asOf } : {}),
    ...(def.kind === "flow" ? { from, to } : {}) });
  const hasFilters = Object.keys(filters).some((k) => k !== "market");
  const totalPages = rows ? Math.max(1, Math.ceil(rows.total / FLASH_PAGE_ROWS)) : 1;
  const sourceLabel = def.source ? String(t[`source_${def.source}` as keyof typeof t]) : "";
  const link = (q: Record<string, string>, hash = "") => `${flashHref(path, q)}${hash}` as Route;

  return (
    <Shell copy={copy} me={me} active={active} wide>
      <PageTitle>{title}</PageTitle>
      {own ? <FlashStrip active={def.key} query={base} t={t} /> : null}
      <FlashTop st={st} path={path} copy={copy}
        markets={Object.entries(doc?.labels.market ?? {}).filter(([code]) => code !== "unknown").map(([code, name]) => ({ code, name }))}
        firstSnapshot={doc?.firstSnapshotDate ?? null} showPeriod={def.kind === "flow"} tenantToday={doc?.today ?? null} />
      {doc ? <SourcesLine sources={doc.sources} timeZone={me.timeZone} locale={locale} t={t} /> : null}
      <FlashNotices st={st} copy={copy} />
      {own ? <p className="mb-6"><Link href={link(base)} className="font-semibold text-p4a-deepblue underline">{t.back}</Link></p> : null}

      {missing || !doc ? (
        <div data-testid="flash-snapshot-missing"><Notice tone="info">{t.noSnapshot}</Notice></div>
      ) : !doc.setUp ? (
        <Card>
          <OverviewHeading def={def} t={t} more={more(def.key)} statusSettings={doc.statusSettings} locale={locale} />
          <p className="text-body text-p4a-muted" data-testid="flash-not-set-up">{t.notSetUp.replace("{source}", sourceLabel)}</p>
        </Card>
      ) : (
        <div className="flex flex-col gap-6">
          <section aria-label={String(t[`o_${def.key}` as keyof typeof t])}>
            <OverviewHeading def={def} t={t} more={more(def.key)} statusSettings={doc.statusSettings} locale={locale} />
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
              <p className="-mt-2 mb-1 max-w-3xl text-small text-p4a-muted">{t.dqIntro}</p>
              {doc.refreshedAt ? (
                <p className="mb-4 text-caption text-p4a-grey" data-testid="dq-refreshed-at">{t.refreshedAt.replace("{time}", fmtDateTime(doc.refreshedAt, me.timeZone, locale))}</p>
              ) : <div className="mb-3" />}
              <DataQualityTable doc={doc} query={query} locale={locale} t={t} />
            </Card>
          ) : (
            <>
              <Card title={t.perMarket}>
                <MarketBars def={def} doc={doc} locale={locale} t={t} />
              </Card>
              {breakdownSets(def).map((set) => {
                // a band set (addition 0008zt): one row per band, of the market or summed over every market
                const band = bandDimOf(def, set);
                return band ? (
                  <Card key={set.join("+")} title={`${t.breakdown}: ${String(t[`d_${band}` as keyof typeof t] ?? band)}`}>
                    <BandTable def={def} doc={doc} set={set} query={query} locale={locale} t={t} path={path} />
                  </Card>
                ) : (
                  <Card key={set.join("+")} title={`${t.breakdown}: ${set.map((d) => String(t[`d_${d}` as keyof typeof t] ?? d)).join(", ")}`}>
                    <BreakdownTable def={def} doc={doc} set={set} query={query} locale={locale} t={t} path={path} />
                  </Card>
                );
              })}
            </>
          )}
          <div className="-mt-2 flex justify-end">
            <LinkButton href={`/api/v1/reports/flash/file?${breakdownQuery.toString()}`} download data-testid="flash-download-breakdown"
              title={t.downloadHint.replace("{n}", fmtNumber(doc.settings.fileMaxRows, locale))}>{t.downloadBreakdown}</LinkButton>
          </div>

          <section id="records" aria-label={t.rows}>
            <Card title={hasFilters ? t.rowsFor.replace("{filter}", filtersText(null, null, null,
              filtersShown(def.key, Object.fromEntries(Object.entries(rowFilters).filter(([k]) => k !== "market")), doc.labels))) : t.rows}>
              {!withRows ? (
                <Notice tone="info">{t.listsAtMonthEnd}</Notice>
              ) : rowsUnavailable ? (
                <div data-testid="flash-rows-unavailable"><Notice tone="info">{t.rowsNotAvailable}</Notice></div>
              ) : rows ? (
                <>
                  {dropped.length > 0 ? (
                    <div className="mb-4" data-testid="flash-frozen-filters"><Notice tone="info">
                      {t.frozenFiltersDropped.replace("{filters}", dropped.map((k) => k === "measure" ? String(t[`m_${filters.measure}` as keyof typeof t] ?? filters.measure)
                        : String(t[`d_${k}` as keyof typeof t] ?? k)).join(", "))}
                    </Notice></div>
                  ) : null}
                  <div className="mb-4 flex flex-wrap items-center justify-between gap-4 text-small">
                    <span className="text-p4a-muted" data-testid="flash-rows-count">
                      {t.rowsShown.replace("{shown}", fmtNumber(rows.rows.length, locale)).replace("{total}", fmtNumber(rows.total, locale))}
                      {rows.mode === "snapshot" ? ` · ${t.frozenList}` : ""}
                    </span>
                    <span className="flex flex-wrap items-center gap-4">
                      {hasFilters ? <Link href={link(Object.fromEntries(Object.entries(query).filter(([k]) => !k.startsWith("f_") && k !== "measure")))}
                        className="font-semibold text-p4a-deepblue underline">{t.clearFilter}</Link> : null}
                      <LinkButton href={`/api/v1/reports/flash/file?${fileQuery.toString()}`} download shortcut="X" data-shortcut="x" data-testid="flash-download"
                        title={t.downloadHint.replace("{n}", fmtNumber(doc.settings.fileMaxRows, locale))}>{t.download}</LinkButton>
                    </span>
                  </div>
                  <RowsTable def={def} rows={rows} sort={rowsAsOf ? null : sort} descending={descending} query={listQuery} locale={locale} timeZone={me.timeZone} t={t}
                    path={path} />
                  {totalPages > 1 ? (
                    <div className="mt-4 flex items-center gap-4 text-small">
                      {pageNo > 1 ? <Link href={link({ ...query, page: String(pageNo - 1) }, "#records")} className="font-semibold text-p4a-deepblue underline">{t.previousPage}</Link> : null}
                      <span className="text-p4a-muted">{pageNo} / {totalPages}</span>
                      {pageNo < totalPages ? <Link href={link({ ...query, page: String(pageNo + 1) }, "#records")} className="font-semibold text-p4a-deepblue underline">{t.nextPage}</Link> : null}
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
