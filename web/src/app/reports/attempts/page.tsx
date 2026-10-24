import { AttemptDealList } from "@/components/AttemptDealList";
import { AttemptFilters } from "@/components/AttemptFilters";
import {
  AttemptDateLine, AttemptGroupSwitch, AttemptGroupTable, AttemptIntro, BucketBars, fmtSpeed, OutcomesTable, QualityFigures, ReachBars, SinceLastBars,
  SpeedWonBars, WonBars,
} from "@/components/AttemptParts";
import { CallsTile, DeltaLine, previousLabel } from "@/components/CallsParts";
import { PeriodBar } from "@/components/PeriodBar";
import { NoReportPermission } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { attemptClientCopy, attemptedShare, attemptFilterQuery, fmtAttempts, parseAttemptFilter, parseAttemptGroup, conversationShare } from "@/lib/attempts";
import { data, dataIsMock, type AttemptGroup } from "@/lib/data";
import { holdsAny } from "@/lib/nav";
import { resolvePeriod } from "@/lib/period";
import { fmtCount, fmtShare, MAX_REPORT_DAYS, REPORT_PERMISSIONS } from "@/lib/reports";
import { dateKeyInZone } from "@/lib/time";
import { metricsMore } from "@/lib/metrics";
import { resolve } from "../../access";

/**
 * Attempts per deal (Report, addition 0008y, 19 October 2026; for sales since 0008z, 20 October 2026; backlog CMA-046):
 * how the sales deals of a period are called. Only the lead pipelines count, never a pipeline of orders. An attempt is an
 * outbound telephony call on the deal or its contacts (attempts.source telephony, the default) or every outbound call
 * logged in the customer records (crm), from the deal's creation (less the pre-window) until it is won or lost or the
 * customer orders another way. Grouped per day, ISO week, market or pipeline (G), narrowed by market (K), lead pipeline
 * (P), attempted (A: every deal, none yet, at least one) and outcome (O: open, won, lost, ordered); the address keys are
 * market, pipeline, attempted and outcome. Six tiles, each with its change against the previous period like for like:
 * the deals, the share attempted, the attempts per deal (average and median), the share with a conversation, the
 * median speed to lead and the open deals with no attempt yet. Then how complete the calls are, won against lost, the
 * win rate by attempts and by speed to lead, the deals by number of attempts, the first conversation per attempt and the open deals by
 * time since their last attempt, as horizontal bars with their values (Pulse4all-Style 7.7, no donut); the figures per
 * group; and the deals, each opening with Enter to its attempts (Esc closes). Shown to people holding reports.view or
 * performance.team; the database checks again on every read. Every figure explains itself in a hint with the tenant's
 * values filled in. Ids, codes, counts, links and times only.
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
  const { filter, problem } = parseAttemptFilter(sp.market, sp.pipeline, sp.attempted, sp.outcome);
  const report = await data().getAttempts(me, period, group, filter);
  const periodQuery: Record<string, string> =
    range === "custom" && !invalid ? { range, from: period.from, to: period.to } : { range };
  const prevLabel = previousLabel(report.previousFrom, report.previousTo, report.previousPartial, copy, me.locale);

  const h = copy.hints;
  const n = (x: number) => fmtCount(x, me.locale);
  const s = report.settings;
  const attempt = s.source === "crm" ? h.atAttemptCrm : h.atAttemptTelephony;
  const fill = (text: string) => text.replaceAll("{attempt}", attempt).replaceAll("{window}", n(s.preWindowMinutes)).replaceAll("{max}", n(s.maxBucket))
    .replaceAll("{buckets}", s.sinceLastBuckets.split(",").join(", ")).replaceAll("{seconds}", n(s.conversationMinTalkSeconds))
    .replaceAll("{speedBuckets}", s.speedBuckets.split(",").join(", "));
  // key: the figure's entry in the metric catalog; the link shows only to a holder of tenant.configure
  const info = (label: string, text: string, key?: string) =>
    ({ about: h.about.replace("{label}", label), text: fill(text), more: key ? metricsMore(me.permissions, key, h.howComputed) : undefined });
  const hints: Record<string, string> = Object.fromEntries(Object.entries(h).filter(([k]) => k.startsWith("at")).map(([k, v]) => [k, fill(v)]));
  const cur = report.current;
  const prev = report.previous;
  const delta = (current: number | null, previous: number | null, better?: "up" | "down") =>
    <DeltaLine current={current} previous={previous} compared={prevLabel} previousFrom={report.previousFrom} historyStart={report.historyStart}
      copy={copy} locale={me.locale} historyText={t.historyStarts} better={better} />;
  const pipelineLabel = filter.pipeline ? report.pipelines.find((p) => p.key === filter.pipeline)?.label ?? filter.pipeline : null;
  const note = (s.source === "crm" ? t.noteCrm : t.noteTelephony).replace("{seconds}", n(s.conversationMinTalkSeconds));
  const filterQuery = attemptFilterQuery(filter);

  return (
    <Shell copy={copy} me={me} active="attempts" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-2 max-w-3xl text-small text-p4a-muted">{t.intro}</p>
      <p className="mb-6 max-w-3xl text-small text-p4a-muted" data-testid="attempts-note" data-source={s.source}>{note}</p>

      <div className="flex flex-wrap items-start justify-between gap-x-6">
        <div>
          <PeriodBar pathname="/reports/attempts" range={range} period={period} today={today} copy={copy} keep={{ group, ...filterQuery }} />
        </div>
        <div className="mb-6">
          <AttemptFilters pathname="/reports/attempts" markets={report.markets} pipelines={report.pipelines} filter={filter} query={{ ...periodQuery, group }} copy={attemptClientCopy(copy)} />
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
        <AttemptGroupSwitch group={group} query={{ ...periodQuery, ...filterQuery }} copy={copy} />
        <AttemptDateLine from={period.from} to={period.to} market={filter.market} pipelineLabel={pipelineLabel} attempted={filter.attempted}
          outcome={filter.outcome} historyStart={report.historyStart} copy={copy} locale={me.locale} />
      </div>

      <div className="flex flex-col gap-6">
        <section className="grid grid-cols-2 gap-4 lg:grid-cols-3" aria-label={t.title} data-testid="attempts-tiles">
          <CallsTile testId="attempts-deals" label={t.deals} value={n(cur.deals)} info={info(t.deals, h.atDeals, "attempts.deals")} detail={t.dealsDetail}
            delta={delta(cur.deals, prev.deals)} />
          <CallsTile testId="attempts-attempted" label={t.attempted} value={fmtShare(attemptedShare(cur), me.locale)} info={info(t.attempted, h.atAttempted, "attempts.attempted_share")}
            detail={t.attemptedDetail.replace("{n}", n(cur.attempted)).replace("{deals}", n(cur.deals))} delta={delta(attemptedShare(cur), attemptedShare(prev), "up")} />
          <CallsTile testId="attempts-per-deal" label={t.perDeal} value={fmtAttempts(cur.avgAttempts, me.locale)} info={info(t.perDeal, h.atPerDeal, "attempts.per_deal")}
            detail={t.perDealDetail.replace("{median}", fmtAttempts(cur.medianAttempts, me.locale)).replace("{attempts}", n(cur.attempts))}
            delta={delta(cur.avgAttempts, prev.avgAttempts)} />
          <CallsTile testId="attempts-conversation" label={t.conversation} value={fmtShare(conversationShare(cur), me.locale)} info={info(t.conversation, h.atConversation, "attempts.conversation_share")}
            detail={t.conversationDetail.replace("{n}", n(cur.conversationDeals)).replace("{deals}", n(cur.deals)).replace("{first}", n(cur.firstConversation))}
            delta={delta(conversationShare(cur), conversationShare(prev), "up")} />
          <CallsTile testId="attempts-speed" label={t.speed} value={fmtSpeed(cur.medianSpeedSeconds, me.locale)} info={info(t.speed, h.atSpeed, "attempts.median_speed_to_lead")}
            detail={t.speedDetail.replace("{n}", n(cur.speedDeals))} delta={delta(cur.medianSpeedSeconds, prev.medianSpeedSeconds, "down")} />
          <CallsTile testId="attempts-open-never" label={t.openNever} value={n(cur.openNeverAttempted)} info={info(t.openNever, h.atOpenNever, "attempts.open_never_attempted")}
            detail={t.openNeverDetail.replace("{open}", n(cur.openDeals))} delta={delta(cur.openNeverAttempted, prev.openNeverAttempted, "down")} />
        </section>

        <Card title={t.qualityTitle}>
          <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted">{t.qualityIntro}</p>
          <QualityFigures figures={cur} hints={hints} copy={copy} locale={me.locale} />
        </Card>

        <Card title={t.outcomesTitle}>
          <AttemptIntro text={t.outcomesIntro} label={t.outcomesTitle} hint={fill(h.atOutcomes)} copy={copy} />
          <OutcomesTable outcomes={report.outcomes} hints={hints} copy={copy} locale={me.locale} />
        </Card>

        <div className="grid gap-6 xl:grid-cols-2">
          <Card title={t.wonTitle}>
            <AttemptIntro text={t.wonIntro} label={t.wonTitle} hint={fill(h.atWon)} copy={copy} />
            {cur.won + cur.lost === 0 ? <p className="text-body text-p4a-muted">{t.noClosed}</p> : <WonBars buckets={report.buckets} copy={copy} locale={me.locale} />}
          </Card>
          <Card title={t.speedTitle}>
            <AttemptIntro text={t.speedIntro} label={t.speedTitle} hint={fill(h.atSpeedWon)} copy={copy} />
            {cur.won + cur.lost === 0 ? <p className="text-body text-p4a-muted">{t.noClosed}</p> : <SpeedWonBars speed={report.speedBuckets} copy={copy} locale={me.locale} />}
          </Card>
          <Card title={t.bucketsTitle}>
            <AttemptIntro text={t.bucketsIntro} label={t.bucketsTitle} hint={fill(h.atBuckets)} copy={copy} />
            {cur.deals === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : <BucketBars buckets={report.buckets} copy={copy} locale={me.locale} />}
          </Card>
          <Card title={t.conversationTitle}>
            <AttemptIntro text={t.conversationIntro} label={t.conversationTitle} hint={fill(h.atFirstConversationShare)} copy={copy} />
            {cur.attempted === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p>
              : <ReachBars buckets={report.buckets} attempted={cur.attempted} copy={copy} locale={me.locale} />}
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
            <AttemptDealList rows={report.list.rows} hints={hints} copy={attemptClientCopy(copy)} locale={me.locale} timeZone={me.timeZone} />
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
