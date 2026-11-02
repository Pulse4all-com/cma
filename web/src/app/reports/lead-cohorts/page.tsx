import type { Route } from "next";
import { CohortChart, CohortSwitch, CohortTable } from "@/components/CohortParts";
import { FunnelFilters } from "@/components/FunnelFilters";
import { FunnelDateLine, FunnelIntro } from "@/components/FunnelParts";
import { PeriodBar } from "@/components/PeriodBar";
import { NoReportPermission } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock, type CohortMeasure, type CohortPeriod, type CohortSplit } from "@/lib/data";
import {
  CHART_COHORTS, COHORT_MEASURES, COHORT_PERIODS, COHORT_SPLITS, cohortChartLines, cohortTableRows, nextCohortMeasure, nextCohortPeriod, nextCohortSplit,
  parseCohortMeasure, parseCohortPeriod, parseCohortSplit,
} from "@/lib/cohorts";
import { funnelClientCopy, funnelFilterQuery, parseFunnelFilter } from "@/lib/funnel";
import { holdsAny } from "@/lib/nav";
import { resolvePeriod } from "@/lib/period";
import { MAX_REPORT_DAYS, REPORT_PERMISSIONS } from "@/lib/reports";
import { addDays, dateKeyInZone, fmtDate, startOfWeek } from "@/lib/time";
import { resolve } from "../../access";

/** Without a range in the address the page opens on the last twelve ISO weeks up to today (within the 92 days) */
const DEFAULT_WEEKS = 12;

/**
 * Lead cohorts (Report, addition 0008zm, 30 October 2026; KPIs 1 and 12): the lead deals grouped by the ISO week or the month
 * they were created (G), followed at the ages of cohorts.lead_ages_days. The table shows the cohorts newest first, one column
 * per age with the share attempted, with a conversation, ordered or lost by then (V; the count in the cell's title), a dash
 * with its reason where not every deal is that old yet, then the median days to order and the deals not called yet now; a
 * split (B) lists each cohort's markets or source channels under it. The chart draws the share ordered by age for the newest
 * eight cohorts. The period bar picks the creation dates (at most 92 days; the twelve weeks up to today when none is given), a
 * cohort the dates cut is marked; narrowed by market (K), lead pipeline (P) and source (S), as the Funnel. Address keys:
 * range, from, to, market, pipeline, source, period, split and measure. Shown to people holding reports.view or
 * performance.team; the database checks again on every read. Counts only, no deal list.
 */
export default async function LeadCohortsPage({ searchParams }: PageProps<"/reports/lead-cohorts">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.leadCohorts;

  if (!holdsAny(me, REPORT_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="lead-cohorts">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={copy.reports.noPermissionTitle} body={copy.reports.noPermissionBody} />
      </Shell>
    );
  }

  const query = await searchParams;
  const today = dateKeyInZone(new Date(), me.timeZone);
  const sp = typeof query.range === "string" ? query : { ...query, range: "custom", from: addDays(startOfWeek(today), -7 * (DEFAULT_WEEKS - 1)), to: today };
  const { range, period, invalid } = resolvePeriod(sp, today, MAX_REPORT_DAYS);
  const cohortPeriod: CohortPeriod = parseCohortPeriod(sp.period) ?? "week";
  const split: CohortSplit = parseCohortSplit(sp.split) ?? "none";
  const measure: CohortMeasure = parseCohortMeasure(sp.measure) ?? "attempted";
  const { filter, problem } = parseFunnelFilter(sp.market, sp.pipeline, sp.source);
  const report = await data().getLeadCohorts(me, period, cohortPeriod, split, filter);

  const periodQuery: Record<string, string> = range === "custom" && !invalid ? { range, from: period.from, to: period.to } : { range };
  const filterQuery = funnelFilterQuery(filter);
  const choices = { period: cohortPeriod, split, measure };
  const href = (change: Partial<typeof choices>) => ({
    pathname: "/reports/lead-cohorts" as Route, query: { ...periodQuery, ...filterQuery, ...choices, ...change },
  });

  const h = copy.hints;
  const hints: Record<string, string> = Object.fromEntries(Object.entries(h).filter(([k]) => k.startsWith("lc")));
  const measureLabels: Record<CohortMeasure, string> = { attempted: t.attempted, conversation: t.conversation, ordered: t.ordered, lost: t.lost };
  const measureHints: Record<CohortMeasure, string> = { attempted: h.lcAttempted, conversation: h.lcConversation, ordered: h.lcOrdered, lost: h.lcLost };
  const pipelineLabel = filter.pipeline ? report.pipelines.find((p) => p.key === filter.pipeline)?.label ?? filter.pipeline : null;
  const parts = [
    ...(filter.market ? [copy.funnel.activeMarket.replace("{market}", filter.market === "unknown" ? copy.reports.unknownMarket : filter.market)] : []),
    ...(pipelineLabel ? [copy.funnel.activePipeline.replace("{pipeline}", pipelineLabel)] : []),
    ...(filter.sourceChannel ? [copy.funnel.activeSource.replace("{source}", filter.sourceChannel)] : []),
  ];
  const history = report.historyStart ? [t.historyFrom.replace("{date}", fmtDate(report.historyStart, me.locale))] : [];
  const lines = cohortChartLines(report.cohorts);

  return (
    <Shell copy={copy} me={me} active="lead-cohorts" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>

      <div className="flex flex-wrap items-start justify-between gap-x-6">
        <div>
          <PeriodBar pathname="/reports/lead-cohorts" range={range} period={period} today={today} copy={copy} keep={{ ...filterQuery, ...choices }} />
        </div>
        <div className="mb-6">
          <FunnelFilters pathname="/reports/lead-cohorts" markets={report.markets} pipelines={report.pipelines} sourceChannels={report.sourceChannels}
            filter={filter} query={{ ...periodQuery, ...choices }} copy={funnelClientCopy(copy)} />
        </div>
      </div>

      {invalid ? (
        <div className="mb-6">
          <Notice tone="warning">{invalid === "length" ? copy.reports.tooLong : copy.myHours.invalidRange}</Notice>
        </div>
      ) : null}
      {problem ? (
        <div className="mb-6">
          <Notice tone="warning">{copy.funnel.filterIgnored}</Notice>
        </div>
      ) : null}

      <div className="mb-6 flex justify-end">
        <FunnelDateLine from={period.from} to={period.to} parts={parts} history={history} copy={copy} locale={me.locale} testId="cohorts" />
      </div>

      <div className="mb-6">
        <div className="flex flex-wrap items-end gap-6">
          <CohortSwitch label={t.periodBy} letter="g" testId="cohort-period" current={cohortPeriod} next={nextCohortPeriod(cohortPeriod)}
            options={COHORT_PERIODS.map((v) => ({ value: v, label: v === "week" ? t.week : t.month }))} href={(v) => href({ period: v })} />
          <CohortSwitch label={t.splitBy} letter="b" testId="cohort-split" current={split} next={nextCohortSplit(split)}
            options={COHORT_SPLITS.map((v) => ({ value: v, label: v === "none" ? t.splitNone : v === "market" ? t.splitMarket : t.splitSource }))}
            href={(v) => href({ split: v })} />
          <CohortSwitch label={t.measure} letter="v" testId="cohort-measure" current={measure} next={nextCohortMeasure(measure)}
            options={COHORT_MEASURES.map((v) => ({ value: v, label: measureLabels[v] }))} href={(v) => href({ measure: v })} />
        </div>
      </div>

      <div className="flex flex-col gap-6">
        <Card title={t.tableCard}>
          <FunnelIntro text={t.tableIntro} label={t.tableCard} hint={measureHints[measure]} copy={copy} />
          {report.cohorts.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
            <CohortTable rows={cohortTableRows(report)} ages={report.ages} measure={measure} split={split} leadToOrderDays={report.leadToOrderDays}
              hints={hints} measureHint={measureHints[measure]} copy={copy} locale={me.locale} />
          )}
        </Card>

        <Card title={t.chartCard}>
          <FunnelIntro text={t.chartIntro.replace("{n}", String(CHART_COHORTS))} label={t.chartCard} hint={h.lcChart} copy={copy} />
          {lines.every((l) => l.points.length === 0) ? <p className="text-body text-p4a-muted">{report.cohorts.length === 0 ? t.empty : t.chartEmpty}</p> : (
            <CohortChart lines={lines} ages={report.ages} copy={copy} locale={me.locale} />
          )}
        </Card>
      </div>

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
