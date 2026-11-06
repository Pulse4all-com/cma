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
import { data, dataIsMock, type FlashPageView } from "@/lib/data";
import { FLASH_OVERVIEWS, definitionChanged, periodComplete, splitKeyLabel, splitLabelsOf, splitLine } from "@/lib/flash";
import { holdsAny } from "@/lib/nav";
import { REPORT_PERMISSIONS } from "@/lib/reports";
import { fmtDate } from "@/lib/time";
import { resolve } from "../../access";

/**
 * Reports → Flash (addition 0008zn; brief B21, decisions of 1 November 2026): ten overviews (Active customers, Active
 * subscriptions, Installed base, Churn, Orders, Payments, Open deals, Open tickets, Open tasks, Reviews) and Data quality,
 * one click (or key: 1 to 9, 0, Q) each, now from the sources or as of a business date with a snapshot (A), per market
 * (K), the flows over the period bar, on screen and as a file (X). The landing reads the stored figures in one call
 * (cma.flash_page) and each card's live headline after it painted; an overview reads its document and its first page of
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
  let page: FlashPageView;
  try {
    page = await data().getFlashPage(me, st.market, st.asOf, st.from, st.to);
  } catch (e) {
    if (!tenantTodayRefused(e)) throw e;
    await st.adoptTenantToday();
    page = await data().getFlashPage(me, st.market, st.asOf, st.from, st.to);
  }
  const { asOf, base, from, to, today } = st;
  const sourceLabel = (s: string | null) => (s ? String(t[`source_${s}` as keyof typeof t]) : "");
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
              <FlashLiveFigure overview={o.key} market={st.market} from={o.kind === "flow" ? from : null} to={o.kind === "flow" ? to : null}
                previous={card?.previous ?? null} previousDefinitionVersion={card?.previousDefinitionVersion ?? null} open={open} locale={locale}
                labels={{ loading: t.loading, changeSince: t.changeSince, changeFlat: t.changeFlat, noCompare: t.noCompare, openPeriod: t.openPeriod, previousOnText,
                  definitionEarlier, splitLabels: splitLabelsOf(o.key, t) }} />
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
    </Shell>
  );
}
