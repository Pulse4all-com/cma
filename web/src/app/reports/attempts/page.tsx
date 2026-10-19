import { AttemptFilters } from "@/components/AttemptFilters";
import {
  AttemptDateLine, AttemptGroupSwitch, AttemptGroupTable, AttemptIntro, AttemptListTable, BucketBars, ReachBars, SinceLastBars, WonBars,
} from "@/components/AttemptParts";
import { CallsTile, DeltaLine, previousLabel } from "@/components/CallsParts";
import { PeriodBar } from "@/components/PeriodBar";
import { NoReportPermission } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { attemptFilterQuery, firstReachShare, fmtAttempts, parseAttemptFilter, parseAttemptGroup } from "@/lib/attempts";
import { data, dataIsMock, type AttemptFigures, type AttemptGroup } from "@/lib/data";
import { holdsAny } from "@/lib/nav";
import { resolvePeriod } from "@/lib/period";
import { fmtCount, fmtShare, MAX_REPORT_DAYS, REPORT_PERMISSIONS } from "@/lib/reports";
import { dateKeyInZone } from "@/lib/time";
import { resolve } from "../../access";

/**
 * Attempts per deal (Report, addition 0008y, 19 October 2026; backlog CMA-046): how many outbound CRM calls the deals of
 * a period got before the customer was reached, per day, ISO week, market or pipeline (G), narrowed by market (K),
 * pipeline (P) and which deals count (S: the lead pipelines, the default, or every counted pipeline; an order pipeline
 * never). Five tiles: the deals, those attempted, the attempts per deal (average and median), those reached on the first
 * attempt and the open deals never attempted, each with its change against the previous period like for like (before the
 * attempts history "No history to compare yet"); a change with a better direction in Leaf Green or #B8433C text, a
 * volume's in Muted (Pulse4all-Style 7.7). Then horizontal bars with their values: deals by number of attempts, reach per
 * attempt, the won rate by number of attempts, and the open deals by business days since their last attempt (one
 * neutral hue); the figures per group; and the deals themselves, open first and the longest waiting first (capped by
 * follow_up.list_rows), each with its link to the customer records. Shown to people holding reports.view or
 * performance.team; the database checks again on every read. Every tile, bar card and header explains itself in a hint
 * with the tenant's values filled in. Ids, codes, counts, links and times only.
 */
export default async function AttemptsPage({ searchParams }: PageProps<"/reports/attempts">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.attempts;

  if (!holdsAny(me, REPORT_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="attempts">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={copy.reports.noPermissionTitle} body={copy.reports.noPermissionBody} />
      </Shell>
    );
  }

  const sp = await searchParams;
  const today = dateKeyInZone(new Date(), me.timeZone);
  const { range, period, invalid } = resolvePeriod(sp, today, MAX_REPORT_DAYS);
  const group: AttemptGroup = parseAttemptGroup(sp.group) ?? "day";
  const { filter, problem } = parseAttemptFilter(sp.market, sp.pipeline, sp.scope);
  const report = await data().getAttempts(me, period, group, filter);
  const periodQuery: Record<string, string> =
    range === "custom" && !invalid ? { range, from: period.from, to: period.to } : { range };
  const prevLabel = previousLabel(report.previousFrom, report.previousTo, report.previousPartial, copy, me.locale);

  const h = copy.hints;
  const n = (x: number) => fmtCount(x, me.locale);
  const s = report.settings;
  const fill = (text: string) => text.replaceAll("{window}", n(s.preWindowMinutes)).replaceAll("{max}", n(s.maxBucket))
    .replaceAll("{buckets}", s.sinceLastBuckets.split(",").join(", "));
  const info = (label: string, text: string) => ({ about: h.about.replace("{label}", label), text: fill(text) });
  const hints: Record<string, string> = Object.fromEntries(Object.entries(h).filter(([k]) => k.startsWith("at")).map(([k, v]) => [k, fill(v)]));
  const cur = report.current;
  const prev = report.previous;
  const attemptedShare = (f: AttemptFigures) => (f.deals === 0 ? null : f.attempted / f.deals);
  const delta = (current: number | null, previous: number | null, better?: "up" | "down") =>
    <DeltaLine current={current} previous={previous} compared={prevLabel} previousFrom={report.previousFrom} historyStart={report.historyStart}
      copy={copy} locale={me.locale} historyText={t.historyStarts} better={better} />;
  const pipelineLabel = filter.pipeline ? report.pipelines.find((p) => p.key === filter.pipeline)?.label ?? filter.pipeline : null;
  const firstReach = firstReachShare(cur);

  return (
    <Shell copy={copy} me={me} active="attempts" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-2 max-w-3xl text-small text-p4a-muted">{t.intro}</p>
      <p className="mb-6 max-w-3xl text-small text-p4a-muted" data-testid="attempts-double-note">{t.doubleNote}</p>

      <div className="flex flex-wrap items-start justify-between gap-x-6">
        <div>
          <PeriodBar pathname="/reports/attempts" range={range} period={period} today={today} copy={copy} keep={{ group, ...attemptFilterQuery(filter) }} />
        </div>
        <div className="mb-6">
          <AttemptFilters pathname="/reports/attempts" markets={report.markets} pipelines={report.pipelines} filter={filter} query={{ ...periodQuery, group }} copy={copy} />
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

      <div className="mb-6 flex flex-wrap items-end justify-between gap-4">
        <AttemptGroupSwitch group={group} query={{ ...periodQuery, ...attemptFilterQuery(filter) }} copy={copy} />
        <AttemptDateLine from={period.from} to={period.to} market={filter.market} pipelineLabel={pipelineLabel} counted={filter.scope === "counted"}
          historyStart={report.historyStart} copy={copy} locale={me.locale} />
      </div>

      <div className="flex flex-col gap-6">
        <section className="grid grid-cols-3 gap-4 xl:grid-cols-5" aria-label={t.title} data-testid="attempts-tiles">
          <CallsTile testId="attempts-deals" label={t.deals} value={n(cur.deals)} info={info(t.deals, h.atDeals)} detail={t.dealsDetail}
            delta={delta(cur.deals, prev.deals)} />
          <CallsTile testId="attempts-attempted" label={t.attempted} value={n(cur.attempted)} info={info(t.attempted, h.atAttempted)}
            detail={t.attemptedDetail.replace("{pct}", fmtShare(attemptedShare(cur), me.locale))}
            delta={delta(attemptedShare(cur), attemptedShare(prev), "up")} />
          <CallsTile testId="attempts-per-deal" label={t.perDeal} value={fmtAttempts(cur.avgAttempts, me.locale)} info={info(t.perDeal, h.atPerDeal)}
            detail={t.perDealDetail.replace("{median}", fmtAttempts(cur.medianAttempts, me.locale)).replace("{attempts}", n(cur.attempts))}
            delta={delta(cur.avgAttempts, prev.avgAttempts)} />
          <CallsTile testId="attempts-first-reach" label={t.firstReach} value={fmtShare(firstReach, me.locale)} info={info(t.firstReach, h.atFirstReach)}
            detail={t.firstReachDetail.replace("{n}", n(cur.firstReached)).replace("{attempted}", n(cur.attempted))}
            delta={delta(firstReach, firstReachShare(prev), "up")} />
          <CallsTile testId="attempts-open-never" label={t.openNever} value={n(cur.openNeverAttempted)} info={info(t.openNever, h.atOpenNever)}
            detail={t.openNeverDetail.replace("{open}", n(cur.openDeals))} delta={delta(cur.openNeverAttempted, prev.openNeverAttempted, "down")} />
        </section>

        <div className="grid gap-6 xl:grid-cols-2">
          <Card title={t.bucketsTitle}>
            <AttemptIntro text={t.bucketsIntro} label={t.bucketsTitle} hint={fill(h.atBuckets)} copy={copy} />
            {cur.deals === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : <BucketBars buckets={report.buckets} copy={copy} locale={me.locale} />}
          </Card>
          <Card title={t.reachTitle}>
            <AttemptIntro text={t.reachIntro} label={t.reachTitle} hint={fill(h.atReach)} copy={copy} />
            {cur.attempted === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p>
              : <ReachBars buckets={report.buckets} attempted={cur.attempted} copy={copy} locale={me.locale} />}
          </Card>
          <Card title={t.wonTitle}>
            <AttemptIntro text={t.wonIntro} label={t.wonTitle} hint={fill(h.atWon)} copy={copy} />
            {cur.won + cur.lost === 0 ? <p className="text-body text-p4a-muted">{t.noClosed}</p> : <WonBars buckets={report.buckets} copy={copy} locale={me.locale} />}
          </Card>
          <Card title={t.sinceTitle}>
            <AttemptIntro text={t.sinceIntro} label={t.sinceTitle} hint={fill(h.atSince)} copy={copy} />
            {cur.openDeals === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p>
              : <SinceLastBars buckets={report.sinceLast.buckets} noHours={report.sinceLast.noHours} copy={copy} locale={me.locale} />}
          </Card>
        </div>

        <Card title={t.byGroup}>
          {report.groups.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
            <AttemptGroupTable rows={report.groups} group={group} hints={hints} copy={copy} locale={me.locale} />
          )}
        </Card>

        <Card title={t.listTitle}>
          <div className="-mt-2 mb-4 flex flex-wrap items-baseline justify-between gap-4">
            <p className="max-w-3xl text-small text-p4a-muted">{t.listIntro}</p>
            {report.list.total > 0 ? (
              <p className="text-caption text-p4a-grey" data-testid="attempts-list-count">
                {t.showing.replace("{shown}", n(report.list.rows.length)).replace("{total}", n(report.list.total))}
              </p>
            ) : null}
          </div>
          {report.list.rows.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
            <AttemptListTable rows={report.list.rows} hints={hints} copy={copy} locale={me.locale} timeZone={me.timeZone} />
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
