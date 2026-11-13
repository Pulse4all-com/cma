import { randomUUID } from "node:crypto";
import { Suspense } from "react";
import Link from "next/link";
import type { Route } from "next";
import { FlashLiveFigure } from "@/components/FlashControls";
import { FlashNotices, FlashOverview, FlashTop, flashState, tenantTodayRefused } from "@/components/FlashOverview";
import { HeaderHint } from "@/components/HeaderHint";
import { HintLabel } from "@/components/HintLabel";
import { changeText, FlashCard, fmtNumber, SourcesLine, WatchStrip } from "@/components/FlashParts";
import { NoReportPermission } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock, requestDbTrace, streamed, type FlashHeadlineView, type FlashPageView, type FlashStoredCard } from "@/lib/data";
import { FLASH_OVERVIEWS, definitionChanged, periodComplete, splitKeyLabel, splitLabelsOf, splitLine } from "@/lib/flash";
import { holdsAny } from "@/lib/nav";
import { REPORT_PERMISSIONS } from "@/lib/reports";
import { fmtDate, fmtDateTime } from "@/lib/time";
import { resolve } from "../../access";

/**
 * Reports → Flash (addition 0008zn; brief B21, decisions of 1 November 2026): ten overviews (Active customers, Active
 * subscriptions, Installed base, Churn, Orders, Payments, Open deals, Open tickets, Open tasks, Reviews) and Data quality,
 * one click (or key: 1 to 9, 0, Q) each, now from the sources or as of a business date with a snapshot (A), per market
 * (K), the flows over the period bar, on screen and as a file (X). The landing reads the stored figures in one call
 * (cma.flash_page) and, since addition 0009p, its cards on the server, in one transaction beside that call: the stock
 * overviews from their stored current takes first (cma.flash_cards_now, with their Refreshed at), then each card without
 * a stored figure (data quality, the flows over the period, a stock overview without a readable take), live, one
 * statement after the other. A card whose answer is in when the page's read is, is drawn with the page; one still on
 * its way streams in; no card fetches from the browser. An overview reads its document and its first page of
 * records in one transaction (getFlashView, components/FlashOverview, which Assets → Installed base renders too since
 * addition 0008zw). Every figure's hint names its definition and its status. Team figures only, for reports.view or
 * performance.team; the database checks again on every read. Ids, statuses, codes, amounts and the CRM's links only:
 * never a name, email, phone or address. The address keys are o, market, asOf, range, from, to, sort, dir, page, measure
 * and f_<dim>.
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
  // the address and what the reads may correct (components/FlashOverview flashState): on a refusal the tenant's today is
  // adopted (today = (await data().getFlashSnapshots(me, null, null)).to;), the period capped and As of dropped
  const st = flashState(me, sp);
  const def = st.def;

  // ---- an overview: components/FlashOverview ------------------------------------------------------------------------
  if (def) return <FlashOverview me={me} copy={copy} st={st} def={def} path="/reports/flash" active="flash" title={t.title} />;

  // ---- the landing -----------------------------------------------------------------------------------------------
  // the cards, in one transaction side by side with the page's read (live only: As of a date the snapshots hold every
  // figure): the stored cards first, then each card without a stored figure, handed over as its statement returns. One
  // connection for the cards whatever the takes' state, so a landing holds two at most beside the identity's (three for
  // a moment when the tenant's today is adopted below: the first cards' transaction ends at its first refused flow)
  const readCards = () => (st.asOf === null ? streamed(() => data().getFlashCardReads(me, st.market, st.from, st.to)) : null);
  let cards = readCards();
  let page: FlashPageView;
  try {
    page = await data().getFlashPage(me, st.market, st.asOf, st.from, st.to);
  } catch (e) {
    if (!tenantTodayRefused(e)) throw e;
    await st.adoptTenantToday();
    // the period was the server's today, not the tenant's: the cards are asked again over the adopted one
    cards = readCards();
    page = await data().getFlashPage(me, st.market, st.asOf, st.from, st.to);
  }
  const { asOf, base, from, to, today } = st;
  const sourceLabel = (s: string | null) => (s ? String(t[`source_${s}` as keyof typeof t]) : "");
  // stored where the overview's current take may be read: drawn with the page. A read that fails leaves every card to
  // its live figure, which then fails too and shows the dash: never a figure that was not read
  const stored = new Map((cards ? await cards.stored.catch(() => [] as FlashStoredCard[]) : []).filter((c) => c.stored).map((c) => [c.overview, c]));
  // a live card whose answer is already there when the page's read is (the cards' transaction ran beside it) is drawn
  // with the page; one still on its way streams in behind its calm line. Nothing waits here: the turn of the event
  // loop only lets the answers that are in be seen
  const ready = new Map<string, FlashHeadlineView | "failed" | null>();
  if (cards) {
    const reads = cards;
    const turn = new Promise<"late">((r) => { setTimeout(() => r("late"), 0); });
    await Promise.all(FLASH_OVERVIEWS.filter((o) => !stored.has(o.key)).map(async (o) => {
      const v = await Promise.race([reads.live(o.key).catch(() => "failed" as const), turn]);
      if (v !== "late") ready.set(o.key, v);
    }));
  }
  // the request's whole database cost, once the cards' transaction is over (local verification only: null in prod)
  const traced = cards !== null && requestDbTrace() !== null;
  return (
    <Shell copy={copy} me={me} active="flash" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted" data-hint-anchor="">
        <HintLabel label={t.intro}><HeaderHint label={copy.hints.about.replace("{label}", t.asOf)} text={t.asOfHint} /></HintLabel>
      </p>
      <FlashTop st={st} path="/reports/flash" copy={copy} markets={page.markets} firstSnapshot={page.firstSnapshotDate} showPeriod tenantToday={page.today} />
      <SourcesLine sources={page.sources} timeZone={me.timeZone} locale={locale} t={t} />
      <FlashNotices st={st} copy={copy} />
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
            // a flow read now compares only a complete period: its end passed in the tenant's zone and every source feeding
            // it read after that end (Decision log, 4 Nov 2026); As of a date, the snapshots' stored figures are compared as stored
            const open = asOf === null && !periodComplete(o.key, o.kind === "flow" ? to : null, page.today || today, page.timeZone || me.timeZone, page.sources);
            // the figure compared with was counted by an earlier definition (addition 0008zu): marked under the change
            const definitionEarlier = previousOnText ? t.definitionEarlier.replace("{date}", previousOnText) : null;
            // As of a date, the stored headline's split: per device-holding status (none for a snapshot before 0008zu), the
            // orders per order kind in the reader's language (none for a snapshot without those rows, 0008zw), In the field
            // per model by the register's name the database gives with it (0008zy)
            const storedSplit = splitLine(card?.split ?? null, (x) => fmtNumber(x, locale, 0), (k, x) => x.label ?? splitKeyLabel(o.key, k, t));
            const figure = asOf ? (
              <>
                <span className="tabular text-title font-bold text-p4a-heading" data-testid={`flash-value-${o.key}`}>
                  {card?.value === null || card?.value === undefined ? "–" : fmtNumber(card.value, locale, 1)}
                </span>
                {storedSplit ? <span className="tabular text-small text-p4a-body" data-testid={`flash-split-${o.key}`}>{storedSplit}</span> : null}
              </>
            ) : (
              (() => {
                const props = {
                  overview: o.key, market: st.market, from: o.kind === "flow" ? from : null, to: o.kind === "flow" ? to : null,
                  previous: card?.previous ?? null, previousDefinitionVersion: card?.previousDefinitionVersion ?? null, open, locale,
                  labels: { loading: t.loading, changeSince: t.changeSince, changeFlat: t.changeFlat, noCompare: t.noCompare, openPeriod: t.openPeriod, previousOnText,
                    definitionEarlier, splitLabels: splitLabelsOf(o.key, t) },
                };
                const s = stored.get(o.key);
                // a stored figure is drawn with the page and says its Refreshed at; a live one streams in behind its calm line
                const r0 = ready.get(o.key);
                return r0 !== undefined && setUp ? (
                  <FlashLiveFigure {...props} initial={r0 === null || r0 === "failed" ? "failed" : { value: r0.value, split: r0.split, version: r0.definitionVersion }} />
                ) : s ? (
                  <FlashLiveFigure {...props} initial={{ value: s.value, split: s.split, version: s.definitionVersion }}
                    labels={{ ...props.labels, refreshedHint: t.storedCardHint,
                      // weekday, date and time, as an overview's Refreshed at (docs/definitions.md): a take may be read up to
                      // three times flash.current_refresh_minutes after it was made, so the card says the day too
                      refreshedAt: s.refreshedAt ? t.refreshedAt.replace("{time}", fmtDateTime(s.refreshedAt, me.timeZone, locale)) : null }} />
                ) : (
                  // the wait has the figure's own shape (the value's line, then one line), so the row of cards keeps its height
                  <Suspense fallback={(
                    <div data-testid={`flash-live-${o.key}`} aria-busy="true">
                      <p className="text-title font-bold" aria-hidden="true"><span className="inline-block w-24 animate-pulse rounded-input bg-p4a-border">&nbsp;</span></p>
                      <p className="text-small text-p4a-muted">{t.loading}</p>
                    </div>
                  )}>
                    <StreamedFigure read={cards && setUp ? cards.live(o.key) : Promise.resolve(null)} props={props} />
                  </Suspense>
                );
              })()
            );
            return (
              <FlashCard key={o.key} def={o} setUp={setUp} sourceLabel={sourceLabel(o.source)} figure={figure} query={base} t={t}
                statusSettings={page.statusSettings} locale={locale}
                change={asOf ? changeText(card?.value ?? null, card?.previous ?? null, card?.previousOn ?? null, locale, t) : null}
                note={asOf && card && definitionChanged(card.definitionVersion, card.previousDefinitionVersion, card.previous) ? definitionEarlier : null} />
            );
          })}
        </div>
      ) : null}
      {dataIsMock ? <div className="mt-6"><Notice tone="info">{copy.shell.testData}</Notice></div> : null}
      {/* a boundary of its own on every render (the key): one already on the screen would hold a click back until the
          cards' transaction is over, and the verification would then time another page than prod's */}
      {traced && cards ? <Suspense key={randomUUID()} fallback={null}><CardsTrace done={cards.done} /></Suspense> : null}
    </Shell>
  );
}

/** The request's database cost once the cards' transaction is over, for verify/round-trips.mjs (the last meta written is the page's whole cost) */
async function CardsTrace({ done }: { done: Promise<void> }) {
  await done;
  const dbTrace = requestDbTrace();
  return dbTrace ? <meta name="cma-db" content={dbTrace} /> : null;
}

/** A live card's figure, read on the server and streamed into the card: the headline's value, split and definition; a failed read shows the dash */
async function StreamedFigure({ read, props }: { read: Promise<FlashHeadlineView | null>; props: Omit<Parameters<typeof FlashLiveFigure>[0], "initial"> }) {
  const h = await read.catch(() => null);
  return <FlashLiveFigure {...props} initial={h ? { value: h.value, split: h.split, version: h.definitionVersion } : "failed"} />;
}
