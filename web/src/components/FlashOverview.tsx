/**
 * One Flash overview as a page, shared by Reports → Flash (every overview, chosen by o) and Assets → Installed base (the
 * installed base's overview alone, addition 0008zw): the address both read (the overview, the market (K), As of (A), the
 * period), the state the reads may correct (the tenant's today adopted on a refusal), the top line's controls, the
 * notices, and the overview's document (getFlashView without its list: the first paint) with the per-market bars and the
 * breakdowns, then its first page of records with their file and pager, read on their own and streamed in a boundary of
 * their own (addition 0008zy), the read started with the document's (addition 0008zz). The Installed base's Model filter narrows the document and the records (addition 0008zy). Moved out of the Flash page so both pages render the
 * same data path, filters, As of and files; every link and control keeps the page it is rendered on (lib/flash
 * FlashPath). Team figures only, for reports.view or performance.team (the pages check it; the database again on every
 * read). Ids, statuses, codes, amounts and the CRM's links only: never a name, email, phone or address.
 */
import Link from "next/link";
import type { Route } from "next";
import { Suspense } from "react";
import { FlashAsOf, FlashMarket, FlashModel } from "@/components/FlashControls";
import {
  BandTable, BreakdownTable, DataQualityTable, FlashStrip, fmtNumber, MarketBars, OverviewHeading, RowsTable, SourcesLine, TotalsRow,
} from "@/components/FlashParts";
import { PeriodBar } from "@/components/PeriodBar";
import { Shell } from "@/components/Shell";
import { Card, LinkButton, Notice, PageTitle } from "@/components/primitives";
import type { Principal } from "@/lib/auth/identity";
import type { Copy } from "@/lib/copy";
import { CmaDbError, data, dataIsMock, requestDbTrace, streamed, type FlashDocumentView, type FlashRowsView, type HoursRange } from "@/lib/data";
import {
  bandDimOf, breakdownSets, documentFilterOf, FLASH_DOCUMENT_FILTERS, FLASH_FROZEN_LIST, FLASH_PAGE_ROWS, filterDocument, filtersShown, filtersText, flashHref, shownSetOf,
  frozenFilters, listUnavailable, metricKey, modelChoicesOf, overviewOf, parseAsOf, parseFilters, parseMarket, parseSort, type FlashKey, type FlashOverviewDef,
  type FlashPath,
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
 * which day that is), the market, the Installed base's model (addition 0008zy) and, for a flow, the period bar. keep: the
 * page filter's address key (f_model), which As of and the market keep
 */
export function FlashTop({ st, path, copy, markets, firstSnapshot, showPeriod, tenantToday, keep = {}, models = null }: {
  st: FlashState; path: FlashPath; copy: Copy; markets: { code: string; name: string }[]; firstSnapshot: string | null; showPeriod: boolean;
  tenantToday: string | null; keep?: Record<string, string>;
  /** The Model filter's value and choices (the Installed base, addition 0008zy); none for another overview or the landing */
  models?: { value: string | null; choices: { key: string; name: string | null }[] } | null;
}) {
  const t = copy.flash;
  const keys = overviewKeys(path, st.def);
  return (
    <div className="mb-4 flex flex-wrap items-end justify-between gap-6">
      <div className="flex flex-wrap items-end gap-6">
        <FlashAsOf asOf={st.asOf} min={firstSnapshot} max={addDays(tenantToday || st.today, -1)} query={{ ...st.base, ...keys, ...keep }}
          labels={{ asOf: t.asOf, now: t.now }} path={path} />
        <FlashMarket market={st.market} markets={markets} query={{ ...st.base, ...keys, ...keep }}
          labels={{ market: t.market, allMarkets: t.allMarkets, unknownMarket: t.unknownMarket }} path={path} />
        {models ? (
          <FlashModel model={models.value} models={models.choices} query={{ ...st.base, ...keys }}
            labels={{ model: t.modelFilter, allModels: t.allModels, unknownModel: t.unknownModel }} path={path} />
        ) : null}
      </div>
      {/* a flow's period: Reports → Flash's flows only (Assets → Installed base is a stock) */}
      {showPeriod && path === "/reports/flash" ? (
        <div className="flex flex-col gap-2">
          <span className="text-caption text-p4a-muted">{t.periodFlows}</span>
          <PeriodBar pathname="/reports/flash" range={st.range} period={st.period} today={st.today} copy={copy}
            keep={{ ...(st.market ? { market: st.market } : {}), ...(st.asOf ? { asOf: st.asOf } : {}), ...keys, ...keep }} />
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

/** The plan of an overview's records: whether a list is read, for which date, with which filters, and which are dropped */
interface RowsPlan {
  withRows: boolean;
  rowsAsOf: string | null;
  rowFilters: Record<string, string>;
  dropped: string[];
}

/** The records' read as it ended: its list, or the error it raised (never a rejected promise: the boundary decides) */
interface RowsRead {
  rows: FlashRowsView | null;
  error: unknown;
}

/**
 * An overview's page in two parts (addition 0008zy): the document first (the heading, the tiles, the per-market bars
 * and the breakdowns: what the first paint shows), now from the sources or as of a business date with a snapshot, per
 * market, the flows over the period bar; then the first page of records, with its file and its pager, streamed in a
 * boundary of its own (FlashRecords) under a placeholder, from a read of its own. The records' read starts with the
 * document's, not after it (addition 0008zz), as a streamed part of the request: the first paint waits for the document
 * alone and its cost stays the document's (the Shell's meta); the boundary awaits the records. The Installed base's Model filter
 * (f_model) narrows the document (lib/flash filterDocument) and the records alike. On Reports → Flash with the overviews'
 * strip and the way back to the landing, on a page of one overview (Assets → Installed base) under that page's own title
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
  // the page filter (the Installed base's model, addition 0008zy): the whole document and the records, kept as f_model
  const pageFilter = documentFilterOf(def, filters);
  const { sort, descending } = parseSort(def, one("sort"), one("dir"));
  const pageNo = Math.max(1, Math.min(10_000, Number.parseInt(one("page") ?? "1", 10) || 1));
  // records: live for now and for a flow's period; a past month end's frozen list for customers, subscriptions and the
  // installed base, which takes the market, the status and its own measure only (the cell's other filters, the model
  // too, are named in a notice, never sent: the database refuses them); none else
  const rowsPlan = (): RowsPlan => {
    const monthEnd = st.asOf !== null && addDays(st.asOf, 1).slice(8, 10) === "01";
    const frozen = def.kind === "stock" && st.asOf !== null && FLASH_FROZEN_LIST[def.key] !== undefined && monthEnd;
    const split = frozen ? frozenFilters(def, filters) : { kept: filters, dropped: [] as string[] };
    return { withRows: def.kind === "flow" || st.asOf === null || frozen, rowsAsOf: def.kind === "stock" && st.asOf !== null ? st.asOf : null,
      rowFilters: split.kept, dropped: split.dropped };
  };
  // the records' read, started now, alongside the document's (addition 0008zz): a streamed part of the request, its
  // answer or its error held for the boundary. Read again with the document after the tenant's today is adopted
  const readRows = (): Promise<RowsRead> => {
    const plan = rowsPlan();
    if (!plan.withRows) return Promise.resolve({ rows: null, error: null });
    return streamed(() => data().getFlashRows(me, {
      overview: def.key, market: st.market, asOf: plan.rowsAsOf, from: def.kind === "flow" ? st.from : null, to: def.kind === "flow" ? st.to : null,
      filters: plan.rowFilters, sort: plan.rowsAsOf ? null : sort, descending, limit: FLASH_PAGE_ROWS, offset: (pageNo - 1) * FLASH_PAGE_ROWS,
    })).then((rows) => ({ rows, error: null }), (error: unknown) => ({ rows: null, error }));
  };
  let rowsRead = readRows();
  // the document alone (an object: the read fills it from its closure). Its refusals: no snapshot for the date (CMA02:
  // "missing"); As of or the period past the tenant's today (CMA04): the tenant's today adopted and read again
  const got: { doc: FlashDocumentView | null } = { doc: null };
  const readDocument = async (): Promise<void> => {
    got.doc = (await data().getFlashView(me, {
      overview: def.key, market: st.market, asOf: st.asOf, from: def.kind === "flow" ? st.from : null, to: def.kind === "flow" ? st.to : null,
      filters: {}, sort: null, descending, limit: FLASH_PAGE_ROWS, offset: 0, withRows: false, rowsAsOf: null,
    })).document;
  };
  let missing = false;
  try {
    await readDocument();
  } catch (e) {
    if (e instanceof CmaDbError && e.sqlState === "CMA02") missing = true;
    else if (!tenantTodayRefused(e)) throw e;
    else {
      await st.adoptTenantToday();
      // the records were asked for the refused date too: asked again for the adopted one, with the document
      rowsRead = readRows();
      try {
        await readDocument();
      } catch (e2) {
        if (e2 instanceof CmaDbError && e2.sqlState === "CMA02") missing = true;
        else throw e2;
      }
    }
  }
  const plan = rowsPlan();
  const doc = got.doc;
  // the document narrowed by the page filter: every tile, bar and breakdown of one model; what it cannot narrow is said so
  const narrowed = doc && pageFilter ? filterDocument(def, doc.totals, doc.rows, pageFilter.dim, pageFilter.value) : null;
  // (the narrowed rows hold the document's own measures, counts summed: the document's row type)
  const shown: FlashDocumentView | null = doc && narrowed ? { ...doc, totals: narrowed.totals, rows: narrowed.rows as FlashDocumentView["rows"] } : doc;
  const { base, asOf, from, to } = st;
  const keep: Record<string, string> = pageFilter ? { [`f_${pageFilter.dim}`]: pageFilter.value } : {};
  const query: Record<string, string> = { ...base, ...overviewKeys(path, def),
    ...Object.fromEntries(Object.entries(filters).filter(([k]) => k !== "market" && k !== "measure").map(([k, v]) => [`f_${k}`, v])),
    ...(filters.measure ? { measure: filters.measure } : {}), ...(one("sort") ? { sort } : {}), ...(one("dir") ? { dir: descending ? "desc" : "asc" } : {}) };
  // the breakdown's file follows the figures on screen: As of for a stock and a flow alike, the page filter, never the
  // list's other filters
  const breakdownQuery = new URLSearchParams({ overview: def.key, part: "breakdown", ...(st.market ? { market: st.market } : {}), ...(asOf ? { asOf } : {}),
    ...(def.kind === "flow" ? { from, to } : {}), ...keep });
  // the list's own filters: every filter but the market and the page filter, which the top line shows
  const listFilters = Object.fromEntries(Object.entries(plan.rowFilters).filter(([k]) => k !== "market" && k !== pageFilter?.dim));
  const hasFilters = Object.keys(filters).some((k) => k !== "market" && k !== pageFilter?.dim);
  const sourceLabel = def.source ? String(t[`source_${def.source}` as keyof typeof t]) : "";
  const link = (q: Record<string, string>) => flashHref(path, q) as Route;
  const modelChoices = doc && FLASH_DOCUMENT_FILTERS[def.key] === "model"
    ? { value: pageFilter?.value ?? null, choices: modelChoicesOf(doc.labels, doc.rows, doc.splitOrder) } : null;

  return (
    <Shell copy={copy} me={me} active={active} wide>
      <PageTitle>{title}</PageTitle>
      {own ? <FlashStrip active={def.key} query={base} t={t} /> : null}
      <FlashTop st={st} path={path} copy={copy}
        markets={Object.entries(doc?.labels.market ?? {}).filter(([code]) => code !== "unknown").map(([code, name]) => ({ code, name }))}
        firstSnapshot={doc?.firstSnapshotDate ?? null} showPeriod={def.kind === "flow"} tenantToday={doc?.today ?? null} keep={keep} models={modelChoices} />
      {doc ? <SourcesLine sources={doc.sources} timeZone={me.timeZone} locale={locale} t={t} /> : null}
      <FlashNotices st={st} copy={copy} />
      {own ? <p className="mb-6"><Link href={link(base)} className="font-semibold text-p4a-deepblue underline">{t.back}</Link></p> : null}

      {missing || !shown ? (
        <div data-testid="flash-snapshot-missing"><Notice tone="info">{t.noSnapshot}</Notice></div>
      ) : !shown.setUp ? (
        <Card>
          <OverviewHeading def={def} t={t} more={more(def.key)} statusSettings={shown.statusSettings} locale={locale} />
          <p className="text-body text-p4a-muted" data-testid="flash-not-set-up">{t.notSetUp.replace("{source}", sourceLabel)}</p>
        </Card>
      ) : (
        <div className="flex flex-col gap-6">
          <section aria-label={String(t[`o_${def.key}` as keyof typeof t])}>
            <OverviewHeading def={def} t={t} more={more(def.key)} statusSettings={shown.statusSettings} locale={locale} />
            {shown.days && shown.days.missing.length > 0 ? (
              <div className="mb-4"><Notice tone="info">{t.daysMissing.replace("{covered}", String(shown.days.covered))
                .replace("{missing}", shown.days.missing.map((d) => fmtDate(d, locale)).join(", "))}</Notice></div>
            ) : null}
            <TotalsRow def={def} doc={shown} locale={locale} t={t} unavailable={narrowed?.unavailableMeasures} filtered={narrowed !== null} />
            {def.key === "churn" && shown.activeAtEnd !== null ? (
              <p className="-mt-2 mb-4 text-small text-p4a-muted">{t.activeAtEnd.replace("{n}", fmtNumber(shown.activeAtEnd, locale))}</p>
            ) : null}
          </section>

          {def.key === "data_quality" ? (
            <Card title={t.dqTitle}>
              <p className="-mt-2 mb-1 max-w-3xl text-small text-p4a-muted">{t.dqIntro}</p>
              {shown.refreshedAt ? (
                <p className="mb-4 text-caption text-p4a-grey" data-testid="dq-refreshed-at">{t.refreshedAt.replace("{time}", fmtDateTime(shown.refreshedAt, me.timeZone, locale))}</p>
              ) : <div className="mb-3" />}
              <DataQualityTable doc={shown} query={query} locale={locale} t={t} />
            </Card>
          ) : (
            <>
              <Card title={t.perMarket}>
                <MarketBars def={def} doc={shown} locale={locale} t={t} />
              </Card>
              {breakdownSets(def).map((set) => {
                const cardTitle = (dims: readonly string[]) => `${t.breakdown}: ${dims.map((d) => String(t[`d_${d}` as keyof typeof t] ?? d)).join(", ")}`;
                // a set the page filter cannot narrow (a snapshot stored before it held the dim): said so, never unfiltered
                if (narrowed?.unavailableSets.includes(set.join("+"))) {
                  return (
                    <Card key={set.join("+")} title={cardTitle(set)}>
                      <p className="text-body text-p4a-muted" data-testid={`flash-set-unavailable-${set.join("-")}`}>{t.modelUnavailableSet}</p>
                    </Card>
                  );
                }
                // without a page filter, a snapshot stored before the set held the dim shows its rows as stored (shownSetOf)
                const stored = shownSetOf(def, shown.rows, set);
                // a band set (addition 0008zt): one row per band, of the market or summed over every market
                const band = bandDimOf(def, set);
                return band ? (
                  <Card key={set.join("+")} title={`${t.breakdown}: ${String(t[`d_${band}` as keyof typeof t] ?? band)}`}>
                    <BandTable def={def} doc={shown} set={set} query={query} locale={locale} t={t} path={path} />
                  </Card>
                ) : (
                  <Card key={set.join("+")} title={cardTitle(stored)}>
                    <BreakdownTable def={def} doc={shown} set={stored} query={query} locale={locale} t={t} path={path} />
                  </Card>
                );
              })}
            </>
          )}
          <div className="-mt-2 flex justify-end">
            <LinkButton href={`/api/v1/reports/flash/file?${breakdownQuery.toString()}`} download data-testid="flash-download-breakdown"
              title={t.downloadHint.replace("{n}", fmtNumber(shown.settings.fileMaxRows, locale))}>{t.downloadBreakdown}</LinkButton>
          </div>

          <section id="records" aria-label={t.rows}>
            <Card title={hasFilters ? t.rowsFor.replace("{filter}", filtersText(null, null, null, filtersShown(def.key, listFilters, shown.labels))) : t.rows}>
              {!plan.withRows ? (
                <Notice tone="info">{t.listsAtMonthEnd}</Notice>
              ) : (
                <Suspense fallback={<RecordsPlaceholder label={t.loading} />}>
                  <FlashRecords me={me} copy={copy} st={st} def={def} plan={plan} rowsRead={rowsRead} filters={filters} pageFilterDim={pageFilter?.dim ?? null}
                    sort={sort} descending={descending} pageNo={pageNo} path={path} query={query} hasFilters={hasFilters} labels={shown.labels}
                    fileMaxRows={shown.settings.fileMaxRows} />
                </Suspense>
              )}
            </Card>
          </section>
        </div>
      )}

      {dataIsMock ? <div className="mt-6"><Notice tone="info">{copy.shell.testData}</Notice></div> : null}
    </Shell>
  );
}

/** The records' place while they are read (7.3: calm blocks in the card, no spinner); its words for a screen reader */
function RecordsPlaceholder({ label }: { label: string }) {
  return (
    <div aria-busy="true" data-testid="flash-rows-loading">
      <span className="sr-only">{label}</span>
      <div className="mb-4 h-4 w-56 animate-pulse rounded-input bg-p4a-border" aria-hidden="true" />
      {[0, 1, 2, 3, 4, 5].map((i) => <div key={i} className="mb-2 h-8 animate-pulse rounded-input bg-p4a-bgblue" aria-hidden="true" />)}
    </div>
  );
}

/**
 * The first page of an overview's records, read on its own after the document (addition 0008zy) and streamed into the
 * records' card: the count, the way to clear the list's filters, the file (X), the table and the pager. A list that
 * cannot answer for this date or these filters (CMA02, CMA04) says so; any other refusal is the page's error. Under
 * CMA_DB_TRACE (mock sign-in only) it writes the request's database count after its read, so verify/round-trips.mjs
 * reads the total from the last meta and the first paint's from the Shell's
 */
async function FlashRecords({ me, copy, st, def, plan, rowsRead, filters, pageFilterDim, sort, descending, pageNo, path, query, hasFilters, labels, fileMaxRows }: {
  me: Principal; copy: Copy; st: FlashState; def: FlashOverviewDef; plan: RowsPlan; rowsRead: Promise<RowsRead>; filters: Record<string, string>; pageFilterDim: string | null;
  sort: string; descending: boolean; pageNo: number; path: FlashPath; query: Record<string, string>; hasFilters: boolean;
  labels: FlashDocumentView["labels"]; fileMaxRows: number;
}) {
  const t = copy.flash;
  const locale = me.locale;
  // the read started with the document's (FlashOverview): its list, or its refusal (a list the database cannot give
  // reads "not available"; any other error is the page's)
  const read = await rowsRead;
  const rows = read.rows;
  const unavailable = read.error !== null && read.error instanceof CmaDbError && listUnavailable(read.error.sqlState);
  if (read.error !== null && !unavailable) throw read.error;
  // the whole request's cost, the streamed records' read included (the Shell's meta holds the first paint's)
  const dbTrace = requestDbTrace();
  const trace = dbTrace ? <meta name="cma-db" content={dbTrace} /> : null;
  if (unavailable || !rows) {
    return <>{trace}<div data-testid="flash-rows-unavailable"><Notice tone="info">{t.rowsNotAvailable}</Notice></div></>;
  }
  const listQuery = { ...query, page: String(pageNo) };
  // the records' file asks what the list read: a frozen list's file only the filters it takes (the page filter among them
  // where the list took it)
  const fileQuery = new URLSearchParams({ overview: def.key, ...(st.market ? { market: st.market } : {}), ...(st.asOf && def.kind === "stock" ? { asOf: st.asOf } : {}),
    ...(def.kind === "flow" ? { from: st.from, to: st.to } : {}),
    ...Object.fromEntries(Object.entries(plan.rowFilters).filter(([k]) => k !== "market" && k !== "measure").map(([k, v]) => [`f_${k}`, v])),
    ...(plan.rowFilters.measure ? { measure: plan.rowFilters.measure } : {}), ...(plan.rowsAsOf ? {} : { sort, dir: descending ? "desc" : "asc" }) });
  // clearing the list's filters keeps the page filter (the Model select is its control)
  const cleared = Object.fromEntries(Object.entries(query).filter(([k]) => !(k.startsWith("f_") && k !== `f_${pageFilterDim}`) && k !== "measure"));
  const totalPages = Math.max(1, Math.ceil(rows.total / FLASH_PAGE_ROWS));
  const link = (q: Record<string, string>, hash = "") => `${flashHref(path, q)}${hash}` as Route;
  return (
    <>
      {trace}
      {plan.dropped.length > 0 ? (
        <div className="mb-4" data-testid="flash-frozen-filters"><Notice tone="info">
          {t.frozenFiltersDropped.replace("{filters}", plan.dropped.map((k) => k === "measure" ? String(t[`m_${filters.measure}` as keyof typeof t] ?? filters.measure)
            : String(t[`d_${k}` as keyof typeof t] ?? k)).join(", "))}
        </Notice></div>
      ) : null}
      <div className="mb-4 flex flex-wrap items-center justify-between gap-4 text-small">
        <span className="text-p4a-muted" data-testid="flash-rows-count">
          {t.rowsShown.replace("{shown}", fmtNumber(rows.rows.length, locale)).replace("{total}", fmtNumber(rows.total, locale))}
          {rows.mode === "snapshot" ? ` · ${t.frozenList}` : ""}
        </span>
        <span className="flex flex-wrap items-center gap-4">
          {hasFilters ? <Link href={link(cleared)} className="font-semibold text-p4a-deepblue underline">{t.clearFilter}</Link> : null}
          <LinkButton href={`/api/v1/reports/flash/file?${fileQuery.toString()}`} download shortcut="X" data-shortcut="x" data-testid="flash-download"
            title={t.downloadHint.replace("{n}", fmtNumber(fileMaxRows, locale))}>{t.download}</LinkButton>
        </span>
      </div>
      <RowsTable def={def} rows={rows} sort={plan.rowsAsOf ? null : sort} descending={descending} query={listQuery} locale={locale} timeZone={me.timeZone} t={t}
        path={path} labels={labels} />
      {totalPages > 1 ? (
        <div className="mt-4 flex items-center gap-4 text-small">
          {pageNo > 1 ? <Link href={link({ ...query, page: String(pageNo - 1) }, "#records")} className="font-semibold text-p4a-deepblue underline">{t.previousPage}</Link> : null}
          <span className="text-p4a-muted">{pageNo} / {totalPages}</span>
          {pageNo < totalPages ? <Link href={link({ ...query, page: String(pageNo + 1) }, "#records")} className="font-semibold text-p4a-deepblue underline">{t.nextPage}</Link> : null}
        </div>
      ) : null}
    </>
  );
}
