import { CallsTile, DeltaLine, previousLabel } from "@/components/CallsParts";
import { FunnelFilters } from "@/components/FunnelFilters";
import {
  DataQualityBars, DealsPerPersonTable, FunnelDateLine, FunnelGroupSwitch, FunnelIntro, LostGroupTable, LostList, LostPeriodTable, PipelineTable, ReasonBars,
  StageCard,
} from "@/components/FunnelParts";
import { PeriodBar } from "@/components/PeriodBar";
import { NoReportPermission } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock, type FunnelGroup } from "@/lib/data";
import {
  DEALS_PER_PERSON_KEY, DEALS_PER_PERSON_PERMISSION, fmtDays, funnelClientCopy, funnelFilterQuery, parseFunnelFilter, parseFunnelGroup, periodKeys,
  stagesByPipeline,
} from "@/lib/funnel";
import { holdsAny } from "@/lib/nav";
import { resolvePeriod } from "@/lib/period";
import { fmtCount, fmtShare, MAX_REPORT_DAYS, REPORT_PERMISSIONS } from "@/lib/reports";
import { dateKeyInZone, fmtDate } from "@/lib/time";
import { resolve } from "../../access";

/**
 * Funnel (Report, addition 0008zb, 20 October 2026; backlog CMA-043, CMA-048; Kira's KPI 4, KPI 11's lost reason): how the
 * sales deals move through their stages and why they are lost, in two sections. Only the lead pipelines count, never a
 * pipeline of orders (0008z's sales deals). The funnel: the deals created, won and lost with the win rate by close date and
 * the median days to won and to lost as tiles, each with its change against the previous period like for like; per stage
 * that reads its times (HubSpot's calculated stage properties, switched per stage on Configuration, Sources) the deals that
 * entered it in the period, still there, moved on, the days in the stage and how many reached won; the figures per
 * pipeline, each linking to Attempts per deal for the same deals. Lost reasons: the lost deals by close date per reason
 * (an enumeration property only, never free text), the data-quality reasons apart, no reason as its own row, per market and
 * per source with the top 3, per week or day (G), and the lost deals without a reason with their links. Narrowed by market
 * (K), lead pipeline (P) and source (S); the address keys are market, pipeline, source and group. Deals per person (won,
 * lost and the amount won per currency, never added up, never ranked) only for performance.team while the tenant's
 * reports.per_person holds deals (off for Pulse4all until Yordi agrees). Shown to people holding reports.view or
 * performance.team; the database checks again on every read. Ids, codes, counts, links and times only.
 */
export default async function FunnelPage({ searchParams }: PageProps<"/reports/funnel">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.funnel;

  if (!holdsAny(me, REPORT_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="funnel">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={copy.reports.noPermissionTitle} body={copy.reports.noPermissionBody} />
      </Shell>
    );
  }

  const sp = await searchParams;
  const today = dateKeyInZone(new Date(), me.timeZone);
  const { range, period, invalid } = resolvePeriod(sp, today, MAX_REPORT_DAYS);
  const group: FunnelGroup = parseFunnelGroup(sp.group) ?? "week";
  const { filter, problem } = parseFunnelFilter(sp.market, sp.pipeline, sp.source);
  const people = me.perPerson.includes(DEALS_PER_PERSON_KEY) && holdsAny(me, DEALS_PER_PERSON_PERMISSION);
  const [funnel, lost, perPerson] = await Promise.all([
    data().getFunnel(me, period, filter), data().getLostReasons(me, period, group, filter), people ? data().getDealsPerPerson(me, period, filter) : null,
  ]);
  const periodQuery: Record<string, string> =
    range === "custom" && !invalid ? { range, from: period.from, to: period.to } : { range };
  const filterQuery = funnelFilterQuery(filter);
  const prevLabel = previousLabel(funnel.previousFrom, funnel.previousTo, funnel.previousPartial, copy, me.locale);

  const h = copy.hints;
  const n = (x: number) => fmtCount(x, me.locale);
  const hints: Record<string, string> = Object.fromEntries(Object.entries(h).filter(([k]) => k.startsWith("fn")));
  const info = (label: string, text: string) => ({ about: h.about.replace("{label}", label), text });
  const cur = funnel.byPipeline.total.current;
  const prev = funnel.byPipeline.total.previous;
  const delta = (current: number | null, previous: number | null, better?: "up" | "down") =>
    <DeltaLine current={current} previous={previous} compared={prevLabel} previousFrom={funnel.previousFrom} historyStart={funnel.historyStart.deals}
      copy={copy} locale={me.locale} historyText={t.historyStarts} better={better} />;
  const pipelineLabel = filter.pipeline ? funnel.pipelines.find((p) => p.key === filter.pipeline)?.label ?? filter.pipeline : null;
  const parts = [
    ...(filter.market ? [t.activeMarket.replace("{market}", filter.market === "unknown" ? copy.reports.unknownMarket : filter.market)] : []),
    ...(pipelineLabel ? [t.activePipeline.replace("{pipeline}", pipelineLabel)] : []),
    ...(filter.sourceChannel ? [t.activeSource.replace("{source}", filter.sourceChannel)] : []),
  ];
  const history = [
    ...(funnel.historyStart.deals ? [t.historyFrom.replace("{date}", fmtDate(funnel.historyStart.deals, me.locale))] : []),
    ...(funnel.historyStart.stages ? [t.stagesFrom.replace("{date}", fmtDate(funnel.historyStart.stages, me.locale))] : []),
  ];
  const attemptsHref = (pipeline: string | null) => ({
    pathname: "/reports/attempts" as const,
    query: { ...periodQuery, ...(filter.market ? { market: filter.market } : {}), ...(pipeline ?? filter.pipeline ? { pipeline: (pipeline ?? filter.pipeline)! } : {}) },
  });
  const lc = lost.current;
  const lp = lost.previous;
  const share = (part: number, whole: number) => (whole === 0 ? null : part / whole);
  const ldelta = (current: number | null, previous: number | null, better?: "up" | "down") =>
    <DeltaLine current={current} previous={previous} compared={prevLabel} previousFrom={lost.previousFrom} historyStart={lost.historyStart}
      copy={copy} locale={me.locale} historyText={t.historyStarts} better={better} />;
  const reasonNotice = lost.reasonState === "none" ? t.reasonNone : lost.reasonState === "unchecked" ? t.reasonUnchecked
    : lost.reasonState === "refused" ? t.reasonRefused : null;

  return (
    <Shell copy={copy} me={me} active="funnel" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>

      <div className="flex flex-wrap items-start justify-between gap-x-6">
        <div>
          <PeriodBar pathname="/reports/funnel" range={range} period={period} today={today} copy={copy} keep={{ group, ...filterQuery }} />
        </div>
        <div className="mb-6">
          <FunnelFilters pathname="/reports/funnel" markets={funnel.markets} pipelines={funnel.pipelines} sourceChannels={funnel.sourceChannels} filter={filter}
            query={{ ...periodQuery, group }} copy={funnelClientCopy(copy)} />
        </div>
      </div>

      {invalid ? (
        <div className="mb-6">
          <Notice tone="warning">{invalid === "length" ? copy.reports.tooLong : copy.myHours.invalidRange}</Notice>
        </div>
      ) : null}
      {problem ? (
        <div className="mb-6">
          <Notice tone="warning">{t.filterIgnored}</Notice>
        </div>
      ) : null}

      <div className="mb-6 flex justify-end">
        <FunnelDateLine from={period.from} to={period.to} parts={parts} history={history} copy={copy} locale={me.locale} testId="funnel" />
      </div>

      <div className="flex flex-col gap-6">
        <section className="flex flex-col gap-6" aria-labelledby="funnel-section" data-testid="funnel-section">
          <h2 id="funnel-section" className="text-title font-semibold text-p4a-heading">{t.funnelTitle}</h2>
          <div className="grid grid-cols-2 gap-4 lg:grid-cols-3" data-testid="funnel-tiles">
            <CallsTile testId="funnel-created" label={t.created} value={n(cur.created)} info={info(t.created, h.fnCreated)} detail={t.createdDetail}
              delta={delta(cur.created, prev.created)} />
            <CallsTile testId="funnel-won" label={t.won} value={n(cur.won)} info={info(t.won, h.fnWon)} detail={t.wonDetail} delta={delta(cur.won, prev.won)} />
            <CallsTile testId="funnel-lost" label={t.lost} value={n(cur.lost)} info={info(t.lost, h.fnLost)} detail={t.lostDetail} delta={delta(cur.lost, prev.lost)} />
            <CallsTile testId="funnel-win-rate" label={t.winRate} value={fmtShare(cur.winRate, me.locale)} info={info(t.winRate, h.fnWinRate)}
              detail={t.winRateDetail.replace("{won}", n(cur.won)).replace("{closed}", n(cur.won + cur.lost))} delta={delta(cur.winRate, prev.winRate, "up")} />
            <CallsTile testId="funnel-days-won" label={t.daysToWon} value={fmtDays(cur.medianDaysToWon, me.locale, t)} info={info(t.daysToWon, h.fnDaysToWon)}
              detail={t.daysToWonDetail} delta={delta(cur.medianDaysToWon, prev.medianDaysToWon, "down")} />
            <CallsTile testId="funnel-days-lost" label={t.daysToLost} value={fmtDays(cur.medianDaysToLost, me.locale, t)} info={info(t.daysToLost, h.fnDaysToLost)}
              detail={t.daysToLostDetail} delta={delta(cur.medianDaysToLost, prev.medianDaysToLost)} />
          </div>

          <Card title={t.stagesCard}>
            <FunnelIntro text={t.stagesIntro} label={t.stagesCard} hint={h.fnStages} copy={copy} />
            {funnel.timedStages === 0 ? <div className="mb-4"><Notice tone="info">{t.noTimedStages}</Notice></div>
              : funnel.historyStart.stages === null ? <div className="mb-4"><Notice tone="info">{t.stagesNotYet}</Notice></div> : null}
            {funnel.stages.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
              <div className="flex flex-col gap-8">
                {stagesByPipeline(funnel.stages).map((p) => (
                  <div key={p.pipeline} className="flex flex-col gap-3">
                    <h3 className="text-body font-semibold text-p4a-heading">{p.label}</h3>
                    <StageCard stages={p.stages} hints={hints} copy={copy} locale={me.locale} />
                  </div>
                ))}
              </div>
            )}
          </Card>

          <Card title={t.pipelinesCard}>
            <FunnelIntro text={t.pipelinesIntro} label={t.pipelinesCard} hint={h.fnPipelines} copy={copy} />
            {funnel.byPipeline.rows.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
              <PipelineTable rows={funnel.byPipeline.rows} total={funnel.byPipeline.total} hints={hints} copy={copy} locale={me.locale} attemptsHref={attemptsHref} />
            )}
          </Card>
        </section>

        <section className="flex flex-col gap-6" aria-labelledby="lost-section" data-testid="lost-section" data-reason-state={lost.reasonState}>
          <div className="flex flex-wrap items-end justify-between gap-4">
            <h2 id="lost-section" className="text-title font-semibold text-p4a-heading">{t.lostTitle}</h2>
            <FunnelGroupSwitch pathname="/reports/funnel" group={group} query={{ ...periodQuery, ...filterQuery }} copy={copy} />
          </div>
          {reasonNotice ? <Notice tone={lost.reasonState === "refused" ? "warning" : "info"}>{reasonNotice}</Notice> : null}
          <div className="grid grid-cols-2 gap-4 lg:grid-cols-4" data-testid="lost-tiles">
            <CallsTile testId="lost-deals" label={t.lostDeals} value={n(lc.lost)} info={info(t.lostDeals, h.fnLostDeals)} detail={t.lostDealsDetail}
              delta={ldelta(lc.lost, lp.lost)} />
            <CallsTile testId="lost-with-reason" label={t.withReason} value={fmtShare(share(lc.withReason, lc.lost), me.locale)} info={info(t.withReason, h.fnWithReason)}
              detail={t.withReasonDetail.replace("{n}", n(lc.withReason)).replace("{lost}", n(lc.lost))}
              delta={ldelta(share(lc.withReason, lc.lost), share(lp.withReason, lp.lost), "up")} />
            <CallsTile testId="lost-no-reason" label={t.noReason} value={n(lc.noReason)} info={info(t.noReason, h.fnNoReason)}
              detail={t.noReasonDetail.replace("{pct}", fmtShare(share(lc.noReason, lc.lost), me.locale))} delta={ldelta(lc.noReason, lp.noReason, "down")} />
            <CallsTile testId="lost-dq" label={t.dataQuality} value={n(lc.dataQuality)} info={info(t.dataQuality, h.fnDataQuality)} detail={t.dataQualityDetail}
              delta={ldelta(lc.dataQuality, lp.dataQuality)} />
          </div>

          <div className="grid gap-6 xl:grid-cols-2">
            <Card title={t.reasonsCard}>
              <FunnelIntro text={t.reasonsIntro} label={t.reasonsCard} hint={h.fnReasons} copy={copy} />
              {lc.lost === 0 ? <p className="text-body text-p4a-muted">{t.noLost}</p>
                : <ReasonBars reasons={lost.reasons} noReason={lost.noReason} copy={copy} locale={me.locale} />}
            </Card>
            <Card title={t.dqCard}>
              <FunnelIntro text={t.dqIntro} label={t.dqCard} hint={h.fnDq} copy={copy} />
              <DataQualityBars reasons={lost.dataQualityReasons} copy={copy} locale={me.locale} />
            </Card>
          </div>

          <Card title={t.marketCard}>
            {lost.byMarket.length === 0 ? <p className="text-body text-p4a-muted">{t.noLost}</p>
              : <LostGroupTable rows={lost.byMarket} by="market" hints={hints} copy={copy} locale={me.locale} />}
          </Card>
          <Card title={t.sourceCard}>
            {lost.bySource.length === 0 ? <p className="text-body text-p4a-muted">{t.noLost}</p>
              : <LostGroupTable rows={lost.bySource} by="source" hints={hints} copy={copy} locale={me.locale} />}
          </Card>

          <Card title={group === "week" ? t.periodCardWeek : t.periodCardDay}>
            <LostPeriodTable rows={lost.byPeriod} reasons={lost.reasons} keys={periodKeys(period.from, period.to, group)} group={group} hints={hints} copy={copy}
              locale={me.locale} />
          </Card>

          <Card title={t.listTitle}>
            <div className="-mt-2 mb-4 flex flex-wrap items-baseline justify-between gap-4">
              <p className="max-w-3xl text-small text-p4a-muted">{t.listIntro}</p>
              {lost.list.total > 0 ? (
                <p className="text-caption text-p4a-grey" data-testid="lost-list-count">
                  {t.showing.replace("{shown}", n(lost.list.rows.length)).replace("{total}", n(lost.list.total))}
                </p>
              ) : null}
            </div>
            {lost.list.rows.length === 0 ? <p className="text-body text-p4a-muted">{t.listEmpty}</p> : (
              <LostList rows={lost.list.rows} hints={hints} copy={copy} locale={me.locale} timeZone={me.timeZone} />
            )}
          </Card>
        </section>

        {perPerson ? (
          <section className="flex flex-col gap-6" aria-labelledby="people-section" data-testid="people-section">
            <h2 id="people-section" className="text-title font-semibold text-p4a-heading">{t.personTitle}</h2>
            <Card>
              <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted">{t.personIntro}</p>
              {perPerson.total.won + perPerson.total.lost === 0 ? <p className="text-body text-p4a-muted">{t.personEmpty}</p> : (
                <DealsPerPersonTable rows={perPerson.rows} total={perPerson.total} hints={hints} copy={copy} locale={me.locale} />
              )}
            </Card>
          </section>
        ) : null}
      </div>

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
