import { Suspense, type ReactNode } from "react";
import Link from "next/link";
import type { Route } from "next";
import { ActiveFilters } from "@/components/ActiveFilters";
import { Bars, FLOW_BG, FlowChart, Legend, LineChart, type LineSeries } from "@/components/ActiveCharts";
import {
  type ActivePageCopy, ActiveTile, type ActiveHref, ChangeLine, CohortHeatmap, ComparisonTable, CustomerList, DataNote, LinkSwitch, MARKET_SORTS, type MarketSort,
  MarketsTable, monthEndText, PanelTitle, PlaceholderCard, sortMarkets,
} from "@/components/ActiveParts";
import { PrintWhenReady, Streamed } from "@/components/ActivePending";
import { fmtAmount, fmtNumber } from "@/components/FlashParts";
import { NoReportPermission } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, LinkButton, Notice, PageTitle } from "@/components/primitives";
import {
  ACTIVE_CHANNELS, ACTIVE_COHORT_SPLITS, ACTIVE_GROUPINGS, ACTIVE_PAGE_SIZE, ACTIVE_PANEL_HEIGHT, ACTIVE_PARTS, ACTIVE_RANGES, ACTIVE_SLOTS, type ActiveCohortSplitChoice,
  type ActivePanel, type ActiveSplit, activeGroupingOf, activeQuery, activeRangeOf, activeSortOf, cohortLabel, cohortShare, fromMonthOf, matureCohorts, monthLabel,
  monthsBack, parseActiveFilter,
} from "@/lib/active";
import { CmaDbError, data, dataIsMock, requestDbTrace, streamed } from "@/lib/data";
import type { ActiveCurve, ActiveReport, ActiveTake } from "@/lib/data";
import { activeCopy, type Copy } from "@/lib/copy";
import type { Principal } from "@/lib/auth/identity";
import { flashHref } from "@/lib/flash";
import { metricsMore } from "@/lib/metrics";
import { holdsAny } from "@/lib/nav";
import { fmtCount, fmtShare, REPORT_PERMISSIONS } from "@/lib/reports";
import { dateKeyInZone, fmtDate } from "@/lib/time";
import { resolve } from "../../access";

/**
 * Active (Customers, addition 0009l, brief B35 with addenda A and B, Martin, 11 November 2026; docs/definitions.md, Active
 * customer terms): the state and the movement of the customer base, the page the sales director opens first. The
 * population is Flash's, unchanged: an Active customer is a store customer with a subscription in a device-holding
 * status, Total subscriptions the subscriptions in one; the live headline equals Flash's for every market and segment.
 * The history is read from a stored take the scheduler refreshes (decision D13: "History as of"); the tiles' present is
 * live. Amounts are per currency and never added across currencies; the indicative euro line shows only while
 * reports.fx_eur_rates holds a rate for every currency shown. Narrowed by market (K), segment and Direct / Indirect, in
 * the database. Shown to people holding reports.view or performance.team; the database checks again on every read. Team
 * figures only: ids, statuses, codes, amounts and links, never a customer's name, email, phone or address.
 *
 * Three layers (decision D15), the server's streaming alone:
 *   the frame          no figure is read: the title row, the filters (their lists are tenant catalogs from the per-instance
 *                      cache), every panel's title, hint and status badge, the placeholder cards of the unit economics, and
 *                      an outline of each data panel at the panel's own height (ACTIVE_PANEL_HEIGHT), so nothing moves
 *   above the fold     one read (cma.active_top): the tiles, the churn count beside the placeholders, the hero chart
 *   below the fold     one read (cma.active_rest): inflow and outflow, the recurring amount, the markets, the two segments
 *                      compared, survival, Customer age, Direct / Indirect, the cohorts, the subscription mix
 *   the list           its own read (cma.active_rows), keyset paging
 * Each read is its own transaction, started before anything waits; the parts stand in document order, so the frame and
 * the top arrive first and a slow read below never holds up the tiles. Every toggle is a link; a small client component
 * marks the clicked link and keeps the Print button waiting for the last part (decision D14). The address keys are
 * range, grouping, market, segment, channel, split, amount, survival, cohort, msort, mdir, sort, dir, after, before, page.
 */
export default async function ActivePage({ searchParams }: PageProps<"/reports/active">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = activeCopy[me.locale];

  if (!holdsAny(me, REPORT_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="active">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={copy.reports.noPermissionTitle} body={copy.reports.noPermissionBody} />
      </Shell>
    );
  }

  const view = viewOf(await searchParams);
  const { range, grouping, filter, sort, descending, problem, href, keep, fileQuery } = view;
  const today = dateKeyInZone(new Date(), me.timeZone);
  const fromMonth = fromMonthOf(range, today);
  const { hints, more, copy: words, info } = wordsOf(me, copy);

  // The three reads, side by side, none awaited here: each part below waits for its own behind its own boundary.
  // streamed(): their cost is counted apart from the first paint's, which is the identity (and, on an instance's first
  // view, the two catalogs of the filters); each part writes the request's cost once its read is there
  const topRead = streamed(() => data().getActiveTop(me, fromMonth, filter));
  const restRead = streamed(() => data().getActiveRest(me, fromMonth, filter, grouping));
  const rowsRequest = { filter, sort, descending, after: view.after, before: view.before, limit: ACTIVE_PAGE_SIZE };
  // a cursor the list no longer knows (an old address, another sort): the first page instead
  const listRead = streamed(() => data().getActiveRows(me, rowsRequest).catch((e: unknown) =>
    e instanceof CmaDbError && e.sqlState === "CMA04" && (view.after || view.before)
      ? data().getActiveRows(me, { ...rowsRequest, after: null, before: null }) : Promise.reject(e)));
  for (const read of [topRead, restRead, listRead]) read.catch(() => undefined);   // a failed read is reported by the part that waits for it

  // the filters' lists: tenant catalogs from the per-instance cache (the segments of crm.customer_segments, the stores' markets)
  const [settingsList, markets] = await Promise.all([data().listSettings(me), data().getActiveMarkets(me)]);
  const segments = (settingsList.find((x) => x.key === "crm.customer_segments")?.value ?? "").split(",").map((x) => x.trim()).filter(Boolean);

  // What changes the figures (the range, the cohort grouping, the three filters): a change of one of them shows every
  // panel's outline at once. A panel's own choice and the list's sort and paging keep what is on the screen while the
  // clicked link shows its mark
  const figuresKey = [range, grouping, filter.market ?? "", filter.segment ?? "", filter.channel ?? ""].join("|");
  const viewKey = [figuresKey, view.bySegment, view.wantEur, view.survivalSplit, view.cohortSplit, view.msort, view.mdesc, sort, descending, view.after ?? "", view.before ?? ""].join("|");
  const ctx: Ctx = { me, t, hints, more, info, copy: words, view, viewKey };
  const layer = (id: ActivePanel, part: string) => ({ id, k: `${id}|${figuresKey}`, part, viewKey });
  const empty = (text: string) => <p className="text-body text-p4a-muted">{text}</p>;

  return (
    <Shell copy={copy} me={me} active="active" wide>
      <div data-print="report" data-testid="active-page">
        {/* ---- the frame ---- */}
        <PageTitle aside={(
          <div className="flex items-center gap-4">
            <span className="flex h-10 min-w-80 flex-col items-end justify-center text-small text-p4a-muted" data-testid="active-freshness">
              <Suspense key={`fresh|${figuresKey}`} fallback={<span className="h-4 w-64 animate-pulse rounded-input bg-p4a-border" aria-hidden="true" />}>
                <Freshness ctx={ctx} read={topRead} />
              </Suspense>
            </span>
            <span className="flex items-center gap-3 print:hidden">
              <LinkButton href={`/api/v1/reports/active/file${fileQuery ? `?${fileQuery}` : ""}`} download data-testid="active-download">{t.download}</LinkButton>
              <PrintWhenReady label={t.print} loading={t.loading} view={viewKey} parts={ACTIVE_PARTS} />
            </span>
          </div>
        )}>{t.title}</PageTitle>
        <p className="-mt-2 mb-6 max-w-4xl text-small text-p4a-muted">{t.intro}</p>

        <div className="mb-6 flex flex-wrap items-end justify-between gap-x-6 gap-y-4 print:hidden">
          <ActiveFilters markets={markets} segments={[...segments, "unknown"]} filter={filter} keep={keep} unknownMarket={copy.reports.unknownMarket}
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

        <div className="flex flex-col gap-6">
          {/* 3.2 the headline: above the fold */}
          <Layer {...layer("tiles", "top")} read={topRead}>{(top) => <Tiles ctx={ctx} top={top} />}</Layer>

          {/* 3.3 the unit economics: placeholders in the frame, never a number; the one real figure beside them */}
          <section aria-label={t.unitEconomics} data-testid="active-slots">
            <PanelTitle label={t.unitEconomics} hint={hints.mh_unit_economics!} status="Pending" copy={words} />
            <div className="grid grid-cols-3 gap-4 xl:grid-cols-6">
              {ACTIVE_SLOTS.map((s) => (
                <PlaceholderCard key={s.key} slot={s.key} info={info(t[`slot_${s.key}`], hints[`mh_slot_${s.key}`]!, s.metric)} copy={words} />
              ))}
            </div>
            <div className="mt-3 text-small">
              <Layer {...layer("churn", "top")} read={topRead} plain>{(top) => (top.unitEconomics ? (
                <p data-testid="active-churned">
                  <Link href={flashHref("/reports/flash", { o: "churn" }) as Route} className="font-semibold text-p4a-deepblue underline-offset-2 hover:underline" title={t.openChurn}>
                    {t.churned30dLine.replace("{n}", fmtCount(top.unitEconomics.churned30d, me.locale))}
                  </Link>
                </p>
              ) : null)}</Layer>
            </div>
          </section>

          {/* 3.4 the base over time: the hero, above the fold */}
          <Card>
            <PanelTitle label={t.baseCard} hint={hints.mh_base!} more={more("active.base_over_time")} copy={words}>
              <LinkSwitch label={t.splitBy} testId="active-split" current={view.bySegment ? "segment" : "none"}
                options={[{ value: "none", label: t.splitNone }, { value: "segment", label: t.segmentFilter }]} href={(v) => href({ split: v === "segment" ? "segment" : null })} />
            </PanelTitle>
            <Layer {...layer("hero", "top")} read={topRead} mark>{(top) => <Hero ctx={ctx} top={top} />}</Layer>
          </Card>

          {/* ---- below the fold: one read ---- */}
          {/* 3.5 inflow and outflow; the Monthly recurring amount per month end */}
          <div className="grid grid-cols-2 gap-6">
            <Card>
              <PanelTitle label={t.flowCard} hint={hints.mh_flow!} more={more("active.inflow")} copy={words} />
              <Layer {...layer("flow", "rest")} read={restRead}>{(rest) => <Flow ctx={ctx} rest={rest} />}</Layer>
            </Card>
            <Card>
              <PanelTitle label={t.amountCard} hint={hints.mh_monthly_amount!} more={more("active.monthly_recurring_amount")} copy={words}>
                <LinkSwitch label={t.showAs} testId="active-amount-switch" current={view.wantEur ? "eur" : "currency"}
                  options={[{ value: "currency", label: t.perCurrency }, { value: "eur", label: t.eurIndicative }]} href={(v) => href({ amount: v === "eur" ? "eur" : null })} />
              </PanelTitle>
              <Layer {...layer("amount", "rest")} read={restRead}>{(rest) => <AmountChart ctx={ctx} rest={rest} />}</Layer>
            </Card>
          </div>

          {/* 3.6 the markets */}
          <Card>
            <PanelTitle label={t.marketsCard} hint={hints.mh_markets!} more={more("active.by_market")} copy={words} />
            <Layer {...layer("markets", "rest")} read={restRead}>{(rest) => (rest.markets.length === 0 || !rest.marketsTotal ? empty(t.empty)
              : <MarketsTable rows={sortMarkets(rest.markets, view.msort, view.mdesc)} total={rest.marketsTotal} sort={view.msort} descending={view.mdesc} href={href} hints={hints}
                copy={words} locale={me.locale} segments={rest.settings.segments} />)}</Layer>
          </Card>

          {/* 3.7a the two segments compared */}
          <Card>
            <PanelTitle label={t.comparisonCard.replace("{a}", segments[0] ?? "–").replace("{b}", segments[1] ?? "–")} hint={hints.mh_comparison!}
              more={more("active.segment_difference")} copy={words} />
            <Layer {...layer("comparison", "rest")} read={restRead}>{(rest) => (!rest.comparison || rest.comparison.a === null || rest.comparison.b === null
              ? empty(t.noSegments) : <ComparisonTable comparison={rest.comparison} hints={hints} copy={words} locale={me.locale} />)}</Layer>
          </Card>

          {/* 3.7b survival */}
          <Card>
            <PanelTitle label={t.survivalCard} hint={hints.mh_survival!} more={more("active.customer_lifetime_median")} copy={words}>
              <LinkSwitch label={t.splitBy} testId="active-survival-split" current={view.survivalSplit}
                options={[{ value: "segment", label: t.segmentFilter }, { value: "channel", label: t.channel }]} href={(v) => href({ survival: v === "channel" ? "channel" : null })} />
            </PanelTitle>
            <Layer {...layer("survival", "rest")} read={restRead}>{(rest) => <Survival ctx={ctx} rest={rest} />}</Layer>
          </Card>

          {/* 3.7c Customer age; Direct / Indirect */}
          <div className="grid grid-cols-2 gap-6">
            <Card>
              <PanelTitle label={t.customerAge} hint={hints.mh_customer_age_bands!} more={more("active.customer_age_bands")} copy={words} />
              <Layer {...layer("age", "rest")} read={restRead}>{(rest) => <AgeBands ctx={ctx} rest={rest} />}</Layer>
            </Card>
            <Card>
              <PanelTitle label={t.channelCard} hint={hints.mh_channel!} more={more("active.acquisition_channel_share")} copy={words} />
              <Layer {...layer("channel", "rest")} read={restRead}>{(rest) => <Channels ctx={ctx} rest={rest} />}</Layer>
            </Card>
          </div>

          {/* 3.8 the customer cohorts */}
          <Card>
            <PanelTitle label={t.cohortsCard} hint={hints.mh_cohort!} more={more("active.cohort_retention")} copy={words}>
              <LinkSwitch label={t.splitBy} testId="active-cohort-split" current={view.cohortSplit}
                options={ACTIVE_COHORT_SPLITS.map((v) => ({ value: v, label: v === "none" ? t.splitNone : v === "segment" ? t.segmentFilter : t.channel }))}
                href={(v) => href({ cohort: v === "none" ? null : v })} />
            </PanelTitle>
            <div className="flex flex-col gap-6">
              <Layer {...layer("cohortTable", "rest")} read={restRead}>{(rest) => <CohortTable ctx={ctx} rest={rest} />}</Layer>
              <Layer {...layer("cohortCurves", "rest")} read={restRead}>{(rest) => <CohortCurves ctx={ctx} rest={rest} />}</Layer>
            </div>
          </Card>

          {/* 3.9 the subscription mix */}
          <section aria-label={t.mixCard} data-testid="active-mix">
            <PanelTitle label={t.mixCard} hint={hints.mh_mix!} more={more("active.subscription_mix")} copy={words} />
            <Layer {...layer("mix", "rest")} read={restRead} mark>{(rest) => <Mix ctx={ctx} rest={rest} />}</Layer>
          </section>

          {/* 3.10 the customer list: its own read */}
          <Card>
            <PanelTitle label={t.listCard} hint={hints.mh_list!} more={more("active.list")} copy={words} />
            <Layer {...layer("list", "list")} read={listRead} mark>{(list) => (
              !list.setUp ? empty(copy.flash.notSetUpShort)
                : !list.history ? empty(t.historyPreparing)
                  : list.total === 0 ? empty(t.emptyList)
                    : <CustomerList list={list} sort={sort} descending={descending} page={view.pageNo} pageSize={ACTIVE_PAGE_SIZE} href={href} hints={hints} copy={words} locale={me.locale} />
            )}</Layer>
          </Card>
        </div>

        {dataIsMock ? (
          <div className="mt-6 print:hidden">
            <Notice tone="info">{copy.shell.testData}</Notice>
          </div>
        ) : null}
      </div>
    </Shell>
  );
}

type One = string | string[] | undefined;

/** The address read into the page's choices, and the links that change one of them (pure: the page and its parts share it) */
function viewOf(sp: Record<string, One>) {
  const one = (v: One) => (typeof v === "string" ? v : undefined);
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
  // the list's place: a cursor of the page before (after) or after (before) this one, as the database wrote it; the page's
  // number rides along for the words under the list only
  const cursor = (v: string | undefined) => (v && v.length <= 600 && /^[A-Za-z0-9+/]+={0,2}$/.test(v) ? v : null);
  const after = cursor(one(sp.after));
  const before = after ? null : cursor(one(sp.before));
  const pageNo = after || before ? Math.max(1, Math.min(100_000, Number.parseInt(one(sp.page) ?? "1", 10) || 1)) : 1;

  // the address: only what differs from the page's defaults, so a view can be shared; a toggle changes its own key
  const state: Record<string, string> = {
    ...(range === "24" ? {} : { range }), ...(grouping === "month" ? {} : { grouping }), ...activeQuery(filter),
    ...(bySegment ? { split: "segment" } : {}), ...(wantEur ? { amount: "eur" } : {}), ...(survivalSplit === "channel" ? { survival: "channel" } : {}),
    ...(cohortSplit === "none" ? {} : { cohort: cohortSplit }), ...(msort === "customers" && mdesc ? {} : { msort, mdir: mdesc ? "desc" : "asc" }),
    ...(sort === "monthly_amount" && descending ? {} : { sort, dir: descending ? "desc" : "asc" }),
    ...(after ? { after } : {}), ...(before ? { before } : {}), ...(pageNo > 1 ? { page: String(pageNo) } : {}),
  };
  const href: ActiveHref = (change) => {
    const q = { ...state };
    for (const [k, v] of Object.entries(change)) {
      if (v === null) delete q[k];
      else q[k] = v;
    }
    return { pathname: "/reports/active" as Route, query: q };
  };
  const keep = Object.fromEntries(Object.entries(state).filter(([k]) => !["market", "segment", "channel", "after", "before", "page"].includes(k)));
  const fileQuery = new URLSearchParams({ ...activeQuery(filter), sort, dir: descending ? "desc" : "asc" }).toString();
  return { range, grouping, filter, problem, bySegment, wantEur, survivalSplit, cohortSplit, msort, mdesc, sort, descending, after, before, pageNo, href, keep, fileQuery };
}
type ActiveView = ReturnType<typeof viewOf>;

/** The words and helpers every part uses: the shared words with the page's own beside them */
function wordsOf(me: Principal, shared: Copy) {
  const t = activeCopy[me.locale];
  const copy: ActivePageCopy = { ...shared, active: t };
  const hints = Object.fromEntries(Object.entries(t).filter(([k]) => k.startsWith("mh_"))) as Record<string, string>;
  const more = (key: string) => metricsMore(me.permissions, key, shared.hints.howComputed);
  const info = (label: string, text: string, key?: string) =>
    ({ about: shared.hints.about.replace("{label}", label), text, more: key ? metricsMore(me.permissions, key, shared.hints.howComputed) : undefined });
  return { t, hints, more, info, copy };
}
type Ctx = ReturnType<typeof wordsOf> & { me: Principal; view: ActiveView; viewKey: string };

/**
 * A data panel (decision D15): its outline while its read is on its way, its body once the read is there, both at the
 * panel's own height (ACTIVE_PANEL_HEIGHT), so nothing moves. Keyed on what changes the figures: a new filter shows the
 * outline at once. mark: the last panel of its part tells the page that the part is on the screen (the Print button
 * waits for all three). plain: a line of text, no box around the outline
 */
function Layer<T>({ id, k, part, viewKey, read, children, mark = false, plain = false }: {
  id: ActivePanel; k: string; part: string; viewKey: string; read: Promise<T>; children: (value: T) => ReactNode; mark?: boolean; plain?: boolean;
}) {
  const height = ACTIVE_PANEL_HEIGHT[id];
  return (
    <Suspense key={k} fallback={(
      <div data-panel-skeleton={id} style={{ height }} aria-busy="true"
        className={plain ? "flex items-center" : "animate-pulse rounded-input bg-p4a-bgblue"}>
        {plain ? <span className="h-3 w-48 animate-pulse rounded-input bg-p4a-border" aria-hidden="true" /> : null}
      </div>
    )}>
      <Body id={id} read={read} part={mark ? part : null} viewKey={viewKey}>{children}</Body>
    </Suspense>
  );
}

async function Body<T>({ id, read, part, viewKey, children }: { id: ActivePanel; read: Promise<T>; part: string | null; viewKey: string; children: (value: T) => ReactNode }) {
  const value = await read;
  const dbTrace = part ? requestDbTrace() : null;
  return (
    <div data-panel-body={id} style={{ height: ACTIVE_PANEL_HEIGHT[id] }} className="flex flex-col overflow-y-auto">
      {dbTrace ? <meta name="cma-db" content={dbTrace} /> : null}
      {children(value)}
      {part ? <Streamed part={part} view={viewKey} /> : null}
    </div>
  );
}

/** What a panel says in place of its figures: a source not set up, or no stored take yet (never zeros) */
function gap(ctx: Ctx, r: ActiveReport, needsHistory = true): ReactNode | null {
  if (!r.figures) {
    return (
      <div className="flex flex-col gap-3" data-testid="active-not-set-up">
        {!r.setUp.commerce ? <Notice tone="info">{ctx.t.notSetUpCommerce}</Notice> : null}
        {!r.setUp.subscriptions ? <Notice tone="info">{ctx.t.notSetUpSubscriptions}</Notice> : null}
      </div>
    );
  }
  if (needsHistory && !r.history) return <Notice tone="info"><span data-testid="active-history-preparing">{ctx.t.historyPreparingBody}</span></Notice>;
  return null;
}

/** A late or stale take, said above a panel's figures */
function late(ctx: Ctx, take: ActiveTake | null): ReactNode | null {
  if (!take?.late) return null;
  const time = clock(ctx.me, take.computedAt);
  return <DataNote testId="active-note-late">{ctx.t.historyLateBody.replace("{time}", time).replace("{minutes}", String(take.ageMinutes))}</DataNote>;
}

const clock = (me: Principal, at: string, style: "short" | "medium" = "short") =>
  new Intl.DateTimeFormat(me.locale === "nl" ? "nl-NL" : "en-GB", { timeStyle: style, timeZone: me.timeZone }).format(new Date(at));

/** The title row's two instants: Updated (this read) and History as of (the stored take), or that the history is being prepared */
async function Freshness({ ctx, read }: { ctx: Ctx; read: Promise<ActiveReport> }) {
  const top = await read;
  const { t, me } = ctx;
  const take = top.take;
  return (
    <>
      <span data-testid="active-updated">{t.updated.replace("{time}", clock(me, top.computedAt, "medium"))}</span>
      {!top.figures ? null : take === null
        ? <span data-testid="active-history" data-history="none">{t.historyPreparing}</span>
        : (
          <span data-testid="active-history" data-history={take.stale ? "stale" : take.late ? "late" : "fresh"} className={take.late ? "font-semibold text-p4a-heading" : undefined}>
            {(take.stale ? t.historyStale : take.late ? t.historyLate : t.historyAsOf).replace("{time}", clock(me, take.computedAt)).replace("{minutes}", String(take.ageMinutes))}
          </span>
        )}
    </>
  );
}

// ---- above the fold --------------------------------------------------------------------------------------------------

function Tiles({ ctx, top }: { ctx: Ctx; top: ActiveReport }) {
  const { t, hints, info, me } = ctx;
  const locale = me.locale;
  const tiles = top.tiles;
  const g = gap(ctx, top, false);
  if (g || !tiles) return g ?? null;
  const n = (x: number) => fmtCount(x, locale);
  const pct = (x: number | null) => fmtShare(x, locale);
  const months = (x: number, digits = 0) => t.monthsValue.replace("{n}", fmtNumber(x, locale, digits));
  const whenMonth = monthEndText(monthsBack(top.today, 1), locale, t);
  const whenYear = monthEndText(monthsBack(top.today, 13), locale, t);
  const segOrder = [...top.settings.segments, "unknown"];
  const segLabel = (s: string) => (s === "unknown" ? t.unknownSegment : s);
  const dash = <span className="text-p4a-muted">–</span>;
  return (
    <section className="grid h-full grid-cols-3 gap-4 xl:grid-cols-6 [&>div]:overflow-y-auto" aria-label={t.headline} data-testid="active-tiles">
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
        value={tiles.amounts.length === 0 ? dash : (
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
        value={tiles.amounts.length === 0 ? dash : (
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
      {/* the two tiles of the stored take: absent figures while the history is being prepared, never zeros */}
      <ActiveTile testId="active-tile-age" label={t.medianAge} info={info(t.medianAge, hints.mh_customer_age!, "active.customer_age_median")}
        value={!tiles.customerAge || tiles.customerAge.median === null ? dash
          : <span>{fmtNumber(tiles.customerAge.median, locale, 1)} <span className="text-small font-normal text-p4a-muted">{t.monthsUnit}</span></span>}>
        {!tiles.customerAge ? <p>{t.historyPreparing}</p> : (
          <>
            {tiles.customerAge.over[0] ? <p>{t.moreThan.replace("{n}", String(tiles.customerAge.over[0].months))} {pct(tiles.customerAge.over[0].share)}</p> : null}
            <ChangeLine value={tiles.customerAge.median} previous={tiles.customerAge.prevMonth} when={whenMonth} fmt={(x) => months(x, 1)} t={t} />
            <ChangeLine value={tiles.customerAge.median} previous={tiles.customerAge.prevYear} when={whenYear} fmt={(x) => months(x, 1)} t={t} />
          </>
        )}
      </ActiveTile>
      <ActiveTile testId="active-tile-lifetime" label={t.lifetimeMedian} info={info(t.lifetimeMedian, hints.mh_customer_lifetime!, "active.customer_lifetime_median")}
        value={!tiles.lifetime ? dash : tiles.lifetime.median !== null
          ? <span>{fmtNumber(tiles.lifetime.median, locale, 0)} <span className="text-small font-normal text-p4a-muted">{t.monthsUnit}</span></span>
          : <span className="text-panel" title={t.notReachedTitle} data-testid="active-not-reached">{t.notReachedShort}</span>}>
        {!tiles.lifetime ? <p>{t.historyPreparing}</p> : (
          <>
            {tiles.lifetime.median === null && tiles.lifetime.longest !== null ? <p>{t.moreThanMonths.replace("{n}", String(tiles.lifetime.longest))}</p> : null}
            <p>{t.clvAverage}</p>
            {Object.entries(tiles.clv ?? {}).sort(([a], [b]) => (a < b ? -1 : 1)).map(([c, v]) => <p key={c} className="tabular" data-currency={c}>{fmtAmount(v.average, c, locale)}</p>)}
          </>
        )}
      </ActiveTile>
    </section>
  );
}

/** The months named under an axis: at most n of them, the year written on the first and wherever it changes */
function axisLabels(ms: { month: string }[], most: number, locale: string) {
  const every = Math.max(1, Math.ceil(ms.length / most));
  const shown = ms.map((m, i) => ({ x: i, month: m.month })).filter((_, i) => i % every === 0);
  return shown.map((l, i) => ({ x: l.x, text: monthLabel(l.month, locale, i === 0 || shown[i - 1]!.month.slice(0, 4) !== l.month.slice(0, 4)) }));
}

/** A chart with its legend inside a panel's fixed height: the notes first, the chart taking what is left, the legend last */
function Fit({ notes, legend, children }: { notes?: ReactNode; legend?: ReactNode; children: ReactNode }) {
  return (
    <div className="flex min-h-0 flex-1 flex-col gap-3">
      {notes}
      <div className="min-h-0 flex-1 [&>svg]:h-full [&>svg]:w-full">{children}</div>
      {legend}
    </div>
  );
}

function Hero({ ctx, top }: { ctx: Ctx; top: ActiveReport }) {
  const { t, me, view } = ctx;
  const locale = me.locale;
  const g = gap(ctx, top);
  if (g) return g;
  const n = (x: number) => fmtCount(x, locale);
  const ms = top.months;
  const notes = top.notes;
  const segOrder = [...top.settings.segments, "unknown"];
  const segLabel = (s: string) => (s === "unknown" ? t.unknownSegment : s);
  const monthName = (m: string) => monthLabel(m, locale, true);
  const title = (m: ActiveReport["months"][number], v: number) => `${monthName(m.month)}${m.isNow ? `, ${t.soFar}` : ""}: ${n(v)}`;
  const series: LineSeries[] = view.bySegment
    ? segOrder.filter((s) => ms.some((m) => (m.bySegment[s] ?? 0) > 0)).map((s, i) => ({
      key: `segment-${s}`, label: `${t.activeCustomers}, ${segLabel(s)}`, colour: [0, 2, 3, 5, 4][i % 5]!,
      points: ms.map((m, x) => ({ x, y: m.bySegment[s] ?? 0, title: title(m, m.bySegment[s] ?? 0), hollow: m.isNow })),
    }))
    : [{
      key: "customers", label: t.activeCustomers, colour: 0,
      points: ms.map((m, x) => ({ x, y: m.customers, title: title(m, m.customers), hollow: m.isNow, label: m.isNow ? t.soFar : undefined })),
    }];
  series.push({ key: "subscriptions", label: t.totalSubscriptions, colour: 1, points: ms.map((m, x) => ({ x, y: m.subscriptions, title: title(m, m.subscriptions), hollow: m.isNow })) });
  const firstMonth = ms[0]?.month ?? top.fromMonth;
  const markers = (notes?.historyStarts ?? []).filter((h) => h.date >= firstMonth).map((h) => ({
    x: (Number(h.date.slice(0, 4)) - Number(firstMonth.slice(0, 4))) * 12 + Number(h.date.slice(5, 7)) - Number(firstMonth.slice(5, 7)) + (Number(h.date.slice(8, 10)) - 1) / 31,
    title: t.historyStartsHere.replace("{store}", h.store).replace("{date}", fmtDate(h.date, locale)),
  }));
  const reconstruction = notes ? [
    notes.noEndedTime > 0 ? t.noteNoEndedTime.replace("{n}", n(notes.noEndedTime)) : null,
    notes.noCreatedTime > 0 ? t.noteNoCreatedTime.replace("{n}", n(notes.noCreatedTime)) : null,
    notes.unmatchedSubscriptions > 0 ? t.noteUnmatched.replace("{n}", n(notes.unmatchedSubscriptions)) : null,
    notes.reconstructionGap !== 0 ? t.noteGap.replace("{n}", n(Math.abs(notes.reconstructionGap))) : null,
  ].filter((x): x is string => x !== null) : [];
  if (ms.length === 0) return <p className="text-body text-p4a-muted">{t.empty}</p>;
  return (
    <Fit
      notes={<>{late(ctx, top.take)}{reconstruction.length > 0 ? <DataNote testId="active-note-history">{reconstruction.join(" ")}</DataNote> : null}</>}
      legend={<Legend label={t.baseCard} items={[...series.map((s, i) => ({ key: s.key, label: s.label, colour: s.colour ?? i })),
        ...(markers.length > 0 ? [{ key: "marker", label: t.historyMarker, colour: 5, dashed: true }] : [])]} />}>
      <LineChart series={series} xLabels={axisLabels(ms, 12, locale)} yFormat={n} yLabel={t.axisCount} label={t.baseCard} testId="active-base-chart" markers={markers} height={320} />
    </Fit>
  );
}

// ---- below the fold --------------------------------------------------------------------------------------------------

function Flow({ ctx, rest }: { ctx: Ctx; rest: ActiveReport }) {
  const { t, me } = ctx;
  const g = gap(ctx, rest);
  if (g) return g;
  const ms = rest.months;
  if (ms.length === 0) return <p className="text-body text-p4a-muted">{t.empty}</p>;
  const channelLabel = (c: string) => (t as Record<string, string>)[`channel_${c}`] ?? c;
  return (
    <Fit legend={<Legend label={t.flowCard} items={[
      ...ACTIVE_CHANNELS.map((c, i) => ({ key: c, label: `${t.inflow}, ${channelLabel(c)}`, colour: i, bar: true, className: `${FLOW_BG[c]}${c === "unknown" ? " ring-1 ring-inset ring-p4a-grey" : ""}` })),
      { key: "out", label: t.outflow, colour: 5, bar: true, className: "bg-p4a-inkt" }, { key: "net", label: t.netChange, colour: 1 },
    ]} />}>
      <FlowChart label={t.flowCard} fmt={(x) => fmtCount(x, me.locale)} xLabels={axisLabels(ms, 6, me.locale)} width={600} height={300}
        words={{ inflow: t.inflow, outflow: t.outflow, net: t.netChange, axis: t.axisCustomers }}
        bars={ms.map((m) => ({ key: m.month, label: `${monthLabel(m.month, me.locale, true)}${m.isNow ? `, ${t.soFar}` : ""}`,
          up: ACTIVE_CHANNELS.map((c) => ({ key: c, value: m.inflowByChannel[c] ?? 0, label: channelLabel(c) })), down: m.outflow, net: m.net }))} />
    </Fit>
  );
}

function AmountChart({ ctx, rest }: { ctx: Ctx; rest: ActiveReport }) {
  const { t, me, view } = ctx;
  const locale = me.locale;
  const g = gap(ctx, rest);
  if (g) return g;
  const ms = rest.months;
  const monthName = (m: string) => monthLabel(m, locale, true);
  const currencies = [...new Set(ms.flatMap((m) => Object.keys(m.amounts)))].sort();
  // the indicative euros only while a rate exists for every currency shown, in every month drawn
  const eurAvailable = rest.settings.fx !== null && ms.length > 0 && ms.every((m) => m.eur !== null || Object.keys(m.amounts).length === 0);
  const showEur = view.wantEur && eurAvailable;
  const series: LineSeries[] = showEur
    ? [{ key: "eur", label: t.eurIndicative, colour: 0,
      points: ms.filter((m) => m.eur !== null).map((m) => ({ x: ms.indexOf(m), y: m.eur!, title: `${monthName(m.month)}: ${t.approx} ${fmtAmount(m.eur!, "EUR", locale)}`, hollow: m.isNow })) }]
    : currencies.map((c, i) => ({
      key: c, label: c, colour: i,
      points: ms.filter((m) => m.amounts[c] !== undefined).map((m) => ({ x: ms.indexOf(m), y: m.amounts[c]!, title: `${monthName(m.month)}: ${fmtAmount(m.amounts[c]!, c, locale)}`, hollow: m.isNow })),
    }));
  if (series.length === 0) return <p className="text-body text-p4a-muted">{t.empty}</p>;
  return (
    <Fit notes={view.wantEur && !eurAvailable ? <DataNote testId="active-note-eur">{t.eurNotAvailable}</DataNote> : undefined}
      legend={<Legend label={t.amountCard} items={series.map((s, i) => ({ key: s.key, label: s.label, colour: s.colour ?? i }))} />}>
      <LineChart series={series} xLabels={axisLabels(ms, 6, locale)} yFormat={(v) => fmtNumber(v, locale, 0)} yLabel={showEur ? t.axisEur : t.axisAmount} label={t.amountCard}
        testId="active-amount-chart" width={600} height={300} />
    </Fit>
  );
}

function Survival({ ctx, rest }: { ctx: Ctx; rest: ActiveReport }) {
  const { t, me, view } = ctx;
  const locale = me.locale;
  const g = gap(ctx, rest);
  if (g) return g;
  const n = (x: number) => fmtCount(x, locale);
  const pct = (x: number | null) => fmtShare(x, locale);
  const segLabel = (s: string) => (s === "unknown" ? t.unknownSegment : s);
  const channelLabel = (c: string) => (t as Record<string, string>)[`channel_${c}`] ?? c;
  const curveLabel = (c: ActiveCurve) => (view.survivalSplit === "segment" ? segLabel(c.value ?? "") : channelLabel(c.value ?? ""));
  const curves = rest.survival ? rest.survival[view.survivalSplit] : [];
  const longest = Math.max(1, ...curves.map((c) => c.longest ?? 0));
  const ageStep = longest > 48 ? 12 : longest > 24 ? 6 : 3;
  const series: LineSeries[] = curves.map((c, i) => ({
    key: c.value ?? "all", label: curveLabel(c), colour: c.value === "unknown" ? 5 : i, dashed: c.value === "unknown",
    points: c.curve.map((p) => ({
      x: p.age, y: p.survival, title: `${t.monthsValue.replace("{n}", fmtNumber(p.age, locale, 0))}: ${pct(p.survival)} (${t.atRisk.replace("{n}", n(p.atRisk))})`,
      label: c.median !== null && p.age === c.median ? t.medianAt.replace("{n}", String(c.median)) : undefined,
    })),
  }));
  if (series.length === 0) return <p className="text-body text-p4a-muted">{t.empty}</p>;
  return (
    <Fit legend={(
      <div className="flex flex-col gap-2">
        <Legend label={t.survivalCard} items={series.map((s, i) => ({ key: s.key, label: s.label, colour: s.colour ?? i, dashed: s.dashed }))} />
        <ul className="flex flex-wrap gap-x-8 gap-y-1 text-small text-p4a-muted" data-testid="active-medians">
          {curves.map((c) => (
            <li key={c.value}>{curveLabel(c)}: {c.median !== null ? t.medianIs.replace("{n}", String(c.median)) : t.notReached.replace("{n}", String(c.longest ?? 0))} ({t.spellsCount.replace("{n}", n(c.spells))})</li>
          ))}
        </ul>
      </div>
    )}>
      <LineChart series={series} step yTop={1} yFormat={(v) => pct(v)} yLabel={t.axisRetained} xLabel={t.axisAge} label={t.survivalCard} testId="active-survival-chart"
        xLabels={Array.from({ length: Math.floor(longest / ageStep) + 1 }, (_, i) => ({ x: i * ageStep, text: String(i * ageStep) }))} refY={{ y: 0.5, text: t.halfLine }} />
    </Fit>
  );
}

function AgeBands({ ctx, rest }: { ctx: Ctx; rest: ActiveReport }) {
  const { t, me } = ctx;
  const g = gap(ctx, rest);
  if (g) return g;
  const n = (x: number) => fmtCount(x, me.locale);
  return (
    <>
      <Bars testId="active-age-bands" label={t.customerAge}
        rows={rest.ageBands.map((b) => ({ key: b.band, label: t.bandMonths.replace("{band}", b.band), value: b.customers, text: n(b.customers), title: `${t.bandMonths.replace("{band}", b.band)}: ${n(b.customers)}` }))} />
      <dl className="mt-4 grid grid-cols-3 gap-4 border-t border-p4a-border pt-4" data-testid="active-age-over">
        {rest.ageOver.map((o) => (
          <div key={o.months}>
            <dt className="text-caption text-p4a-grey">{t.moreThan.replace("{n}", String(o.months))}</dt>
            <dd className="tabular text-panel font-semibold text-p4a-heading">{n(o.customers)} <span className="text-small font-normal text-p4a-muted">{fmtShare(o.share, me.locale)}</span></dd>
          </div>
        ))}
      </dl>
    </>
  );
}

function Channels({ ctx, rest }: { ctx: Ctx; rest: ActiveReport }) {
  const { t, me } = ctx;
  const g = gap(ctx, rest);
  if (g || !rest.marketsTotal) return g ?? null;
  const n = (x: number) => fmtCount(x, me.locale);
  const channelLabel = (c: string) => (t as Record<string, string>)[`channel_${c}`] ?? c;
  const total = rest.marketsTotal;
  const by = { indirect: total.indirect, direct: total.direct, unknown: total.unknownChannel };
  const notes = rest.notes;
  const reasons = notes ? Object.entries(notes.unknownChannel.reasons).sort((a, b) => b[1] - a[1]) : [];
  return (
    <>
      <Bars testId="active-channels" label={t.channelCard}
        rows={ACTIVE_CHANNELS.map((c) => ({ key: c, label: channelLabel(c), value: by[c], text: n(by[c]), title: `${channelLabel(c)}: ${n(by[c])}` }))} />
      {notes && notes.unknownChannel.customers > 0 ? (
        <DataNote testId="active-note-channel">
          {t.noteUnknownChannel.replace("{n}", n(notes.unknownChannel.customers))}{" "}
          {reasons.map(([k, v]) => `${(t as Record<string, string>)[`reason_${k}`] ?? k} ${n(v)}`).join(" · ")}
          {rest.settings.attribution.historyStart ? ` ${t.noteAttributionStart.replace("{date}", fmtDate(rest.settings.attribution.historyStart, me.locale))}` : ` ${t.noteNoAttribution}`}
        </DataNote>
      ) : null}
    </>
  );
}

function CohortTable({ ctx, rest }: { ctx: Ctx; rest: ActiveReport }) {
  const { t, me, hints, copy } = ctx;
  const g = gap(ctx, rest);
  if (g) return g;
  if (rest.cohorts.length === 0) return <p className="text-body text-p4a-muted">{t.empty}</p>;
  const dominant = rest.notes?.dominantCohort ?? null;
  return (
    <>
      {dominant ? (
        <DataNote testId="active-note-dominant">
          {t.noteDominant.replace("{cohort}", cohortLabel(dominant.cohort, rest.grouping, me.locale)).replace("{share}", fmtShare(dominant.share, me.locale))}
        </DataNote>
      ) : null}
      <CohortHeatmap cohorts={rest.cohorts} ages={rest.settings.cohortAgesMonths} grouping={rest.grouping} hints={hints} copy={copy} locale={me.locale} />
    </>
  );
}

function CohortCurves({ ctx, rest }: { ctx: Ctx; rest: ActiveReport }) {
  const { t, me, view } = ctx;
  const locale = me.locale;
  if (!rest.figures || !rest.history || rest.cohorts.length === 0) return null;
  const n = (x: number) => fmtCount(x, locale);
  const pct = (x: number | null) => fmtShare(x, locale);
  const months = (x: number) => t.monthsValue.replace("{n}", fmtNumber(x, locale, 0));
  const segLabel = (s: string) => (s === "unknown" ? t.unknownSegment : s);
  const channelLabel = (c: string) => (t as Record<string, string>)[`channel_${c}`] ?? c;
  const ages = rest.settings.cohortAgesMonths;
  const series: LineSeries[] = view.cohortSplit === "none"
    ? matureCohorts(rest.cohorts, 6).map((c, i) => ({
      key: c.cohort, label: cohortLabel(c.cohort, rest.grouping, locale), colour: i,
      points: c.ages.flatMap((a, x) => {
        const share = cohortShare(c, a);
        return share === null ? [] : [{ x, y: share, title: `${months(a.age)}: ${pct(share)} (${t.cohortCellTitle.replace("{n}", n(a.stillActive)).replace("{started}", n(c.started))})` }];
      }),
    }))
    : (rest.cohortSplits?.[view.cohortSplit] ?? []).map((s, i) => ({
      key: s.value, label: view.cohortSplit === "segment" ? segLabel(s.value) : channelLabel(s.value), colour: s.value === "unknown" ? 5 : i, dashed: s.value === "unknown",
      points: s.ages.flatMap((a, x) => (a.started > 0 ? [{ x, y: a.stillActive / a.started,
        title: `${months(a.age)}: ${pct(a.stillActive / a.started)} (${t.cohortCellTitle.replace("{n}", n(a.stillActive)).replace("{started}", n(a.started))})` }] : [])),
    }));
  if (!series.some((s) => s.points.length > 0)) return <p className="text-small text-p4a-muted">{t.noMatureCohort}</p>;
  return (
    <Fit notes={<h3 className="text-body font-semibold text-p4a-heading">{view.cohortSplit === "none" ? t.cohortCurves : t.cohortCurvesSplit}</h3>}
      legend={<Legend label={t.cohortCurves} items={series.map((s, i) => ({ key: s.key, label: s.label, colour: s.colour ?? i, dashed: s.dashed }))} />}>
      <LineChart series={series} yTop={1} yFormat={(v) => pct(v)} yLabel={t.axisStillActive} xLabel={t.axisAge} label={t.cohortCurves} testId="active-cohort-chart"
        xLabels={ages.map((a, i) => ({ x: i, text: String(a) }))} />
    </Fit>
  );
}

function Mix({ ctx, rest }: { ctx: Ctx; rest: ActiveReport }) {
  const { t, me } = ctx;
  const g = gap(ctx, rest);
  if (g || !rest.mix) return g ?? null;
  const n = (x: number) => fmtCount(x, me.locale);
  const word = (prefix: string, key: string) => (t as Record<string, string>)[`${prefix}_${key}`] ?? key;
  return (
    <div className="grid h-full grid-cols-2 gap-4 xl:grid-cols-4 [&>section]:overflow-y-auto">
      <Card title={t.mixBilling}>
        <Bars testId="active-mix-billing" label={t.mixBilling}
          rows={rest.mix.billing.map((b) => ({ key: b.key, label: word("billing", b.key), value: b.subscriptions, text: n(b.subscriptions), title: n(b.subscriptions) }))} />
      </Card>
      <Card title={t.mixDeviceBand}>
        <Bars testId="active-mix-band" label={t.mixDeviceBand}
          rows={rest.mix.deviceBand.map((b) => ({ key: b.key, label: t.devicesBand.replace("{band}", b.key), value: b.subscriptions, text: n(b.subscriptions), title: n(b.subscriptions) }))} />
      </Card>
      <Card title={t.mixModel}>
        {rest.mix.model.length === 0 ? <p className="text-small text-p4a-muted">{t.noDevices}</p> : (
          <Bars testId="active-mix-model" label={t.mixModel} colour="bg-p4a-denim"
            rows={rest.mix.model.map((b) => ({ key: b.key, label: b.label ?? b.key, value: b.devices, text: n(b.devices), title: `${b.label ?? b.key}: ${n(b.devices)}` }))} />
        )}
      </Card>
      <Card title={t.mixPayment}>
        <Bars testId="active-mix-payment" label={t.mixPayment} colour="bg-p4a-green"
          rows={rest.mix.paymentState.map((b) => {
            const label = word("pay", b.key);
            return {
              key: b.key, value: b.subscriptions, text: n(b.subscriptions), title: `${label}: ${n(b.subscriptions)}`,
              label: b.key === "in_retry" || b.key === "failed"
                ? <Link href={flashHref("/reports/flash", { o: "subscriptions", f_payment_state: b.key }) as Route} className="text-p4a-deepblue underline-offset-2 hover:underline" title={t.openFlashPayment.replace("{state}", label)}>{label}</Link>
                : label,
            };
          })} />
      </Card>
    </div>
  );
}
