import Link from "next/link";
import { CallsTile, DeltaLine, previousLabel } from "@/components/CallsParts";
import { FunnelFilters } from "@/components/FunnelFilters";
import { FunnelDateLine, FunnelGroupSwitch, FunnelIntro } from "@/components/FunnelParts";
import { PeriodBar } from "@/components/PeriodBar";
import { NoReportPermission } from "@/components/ReportParts";
import {
  ReviewChannels, ReviewDistribution, ReviewInviteEvents, ReviewLinkLevels, ReviewMarkets, ReviewMarketStates, ReviewPeriods,
} from "@/components/ReviewParts";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock, type FunnelGroup } from "@/lib/data";
import { funnelClientCopy, parseFunnelFilter, parseFunnelGroup } from "@/lib/funnel";
import { holdsAny } from "@/lib/nav";
import { resolvePeriod } from "@/lib/period";
import { fmtCount, fmtShare, MAX_REPORT_DAYS, REPORT_PERMISSIONS } from "@/lib/reports";
import { fmtRating, marketsWithoutChannel, reviewShare } from "@/lib/reviews";
import { dateKeyInZone, fmtDate } from "@/lib/time";
import { metricsMore } from "@/lib/metrics";
import { resolve } from "../../access";

/**
 * Reviews (Report, addition 0008ze, 25 October 2026; brief B18; KPI 3): the reviews the review platform holds of the
 * tenant's channels (polled hourly by the platform's adapter). A review counts when it is published and its
 * channel is counted (Configuration, Sources); its market is its channel's, its day the submission's in the tenant's zone.
 * Tiles for the reviews, the average rating, the negative reviews (at or below reviews.negative_max_rating) and the linked
 * reviews, each with its change against the previous period like for like; the reviews per whole star, per market, per day
 * or week (G), per channel, by link level (an order, a CRM contact found by email, none) and by invite event; and every
 * active market with its review-channel state (KPI 11: a market without a channel has no reviews to show). Narrowed by
 * market (K); the address keys are market and group. Team figures only: no figure per person exists. Shown to people
 * holding reports.view or performance.team, as every report's team figures; the database checks again on every read.
 * Counts, ratings, codes and channel names only, never a reviewer or a review's text.
 */
export default async function ReviewsPage({ searchParams }: PageProps<"/reports/reviews">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.reviews;

  if (!holdsAny(me, REPORT_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="reviews">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={copy.reports.noPermissionTitle} body={copy.reports.noPermissionBody} />
      </Shell>
    );
  }

  const sp = await searchParams;
  const today = dateKeyInZone(new Date(), me.timeZone);
  const { range, period, invalid } = resolvePeriod(sp, today, MAX_REPORT_DAYS);
  const group: FunnelGroup = parseFunnelGroup(sp.group) ?? "week";
  const { filter, problem } = parseFunnelFilter(sp.market, null, null);
  const report = await data().getReviews(me, period, group, filter.market);
  const periodQuery: Record<string, string> =
    range === "custom" && !invalid ? { range, from: period.from, to: period.to } : { range };
  const marketQuery: Record<string, string> = filter.market ? { market: filter.market } : {};
  const prevLabel = previousLabel(report.previousFrom, report.previousTo, report.previousPartial, copy, me.locale);

  const h = copy.hints;
  const n = (x: number) => fmtCount(x, me.locale);
  const hints: Record<string, string> = Object.fromEntries(Object.entries(h).filter(([k]) => k.startsWith("rv")));
  // key: the figure's entry in the metric catalog; the link shows only to a holder of tenant.configure
  const info = (label: string, text: string, key?: string) =>
    ({ about: h.about.replace("{label}", label), text, more: key ? metricsMore(me.permissions, key, h.howComputed) : undefined });
  const cur = report.current;
  const prev = report.previous;
  const delta = (current: number | null, previous: number | null, better?: "up" | "down") =>
    <DeltaLine current={current} previous={previous} compared={prevLabel} previousFrom={report.previousFrom} historyStart={report.historyStart}
      copy={copy} locale={me.locale} historyText={t.historyStarts} better={better} />;
  const parts = filter.market ? [copy.funnel.activeMarket.replace("{market}", filter.market === "unknown" ? copy.reports.unknownMarket : filter.market)] : [];
  const history = report.historyStart ? [t.historyFrom.replace("{date}", fmtDate(report.historyStart, me.locale))] : [];
  const linked = cur.linkedOrder + cur.linkedContact;
  const missing = marketsWithoutChannel(report.marketStates);
  const negativeLabel = t.negative.replace("{rating}", String(report.negativeMaxRating));

  return (
    <Shell copy={copy} me={me} active="reviews" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-2 max-w-3xl text-small text-p4a-muted">{t.intro}</p>
      <p className="mb-6 max-w-3xl text-small text-p4a-muted" data-testid="reviews-note">{t.note}</p>

      <div className="flex flex-wrap items-start justify-between gap-x-6">
        <div>
          <PeriodBar pathname="/reports/reviews" range={range} period={period} today={today} copy={copy} keep={{ group, ...marketQuery }} />
        </div>
        <div className="mb-6">
          <FunnelFilters pathname="/reports/reviews" markets={report.markets} pipelines={[]} sourceChannels={[]} filter={filter}
            query={{ ...periodQuery, group }} copy={funnelClientCopy(copy)} marketOnly />
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
      {!report.isSetUp ? (
        <div className="mb-6" data-testid="reviews-not-set-up">
          <Notice tone="info">
            {t.notSetUp}{" "}
            {holdsAny(me, "tenant.configure") ? <Link href="/configuration/sources" className="font-semibold text-p4a-deepblue underline">{t.configureLink}</Link> : null}
          </Notice>
        </div>
      ) : missing.length > 0 ? (
        <div className="mb-6" data-testid="reviews-missing-channels">
          <Notice tone="info">{t.marketsWithoutChannel.replace("{markets}", missing.join(", "))}</Notice>
        </div>
      ) : null}

      <div className="mb-6 flex flex-wrap items-end justify-between gap-4">
        <FunnelGroupSwitch pathname="/reports/reviews" group={group} query={{ ...periodQuery, ...marketQuery }} copy={copy} />
        <FunnelDateLine from={period.from} to={period.to} parts={parts} history={history} copy={copy} locale={me.locale} testId="reviews" />
      </div>

      <div className="flex flex-col gap-6">
        <section className="grid grid-cols-2 gap-4 lg:grid-cols-4" aria-label={t.title} data-testid="reviews-tiles">
          <CallsTile testId="reviews-count" label={t.reviews} value={n(cur.reviews)} info={info(t.reviews, h.rvReviews, "reviews.count")} detail={t.reviewsDetail}
            delta={delta(cur.reviews, prev.reviews)} />
          <CallsTile testId="reviews-average" label={t.average} value={fmtRating(cur.averageRating, me.locale)} info={info(t.average, h.rvAverage, "reviews.average_rating")}
            detail={t.averageDetail} delta={delta(cur.averageRating, prev.averageRating)} />
          <CallsTile testId="reviews-negative" label={negativeLabel} value={n(cur.negative)} info={info(negativeLabel, h.rvNegative, "reviews.negative")}
            detail={t.negativeDetail.replace("{share}", fmtShare(reviewShare(cur.negative, cur.reviews), me.locale))} delta={delta(cur.negative, prev.negative, "down")} />
          <CallsTile testId="reviews-linked" label={t.linked} value={n(linked)} info={info(t.linked, h.rvLinked, "reviews.linked")}
            detail={t.linkedDetail.replace("{share}", fmtShare(reviewShare(linked, cur.reviews), me.locale))} delta={delta(linked, prev.linkedOrder + prev.linkedContact)} />
        </section>

        {/* the bars side by side; the tables of six columns at full width, the states (four) next to the invitation events */}
        <div className="grid gap-6 xl:grid-cols-2">
          <Card title={t.distributionCard}>
            <FunnelIntro text={t.distributionIntro} label={t.distributionCard} hint={h.rvDistribution} copy={copy} />
            {cur.reviews === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : <ReviewDistribution rows={report.distribution} copy={copy} locale={me.locale} />}
          </Card>
          <Card title={t.linkCard}>
            <FunnelIntro text={t.linkIntro} label={t.linkCard} hint={h.rvLinks} copy={copy} />
            {cur.reviews === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : <ReviewLinkLevels rows={report.linkLevels} copy={copy} locale={me.locale} />}
          </Card>
        </div>

        <Card title={t.marketCard}>
          <FunnelIntro text={t.marketIntro} label={t.marketCard} hint={h.rvMarkets} copy={copy} />
          {report.byMarket.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p>
            : <ReviewMarkets rows={report.byMarket} hints={hints} copy={copy} locale={me.locale} />}
        </Card>

        <Card title={group === "week" ? t.periodCardWeek : t.periodCardDay}>
          <ReviewPeriods rows={report.byPeriod} group={group} hints={hints} copy={copy} locale={me.locale} />
        </Card>

        <Card title={t.channelCard}>
          <FunnelIntro text={t.channelIntro} label={t.channelCard} hint={h.rvChannels} copy={copy} />
          {report.byChannel.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p>
            : <ReviewChannels rows={report.byChannel} hints={hints} copy={copy} locale={me.locale} />}
        </Card>

        <div className="grid gap-6 xl:grid-cols-2">
          <Card title={t.eventCard}>
            <FunnelIntro text={t.eventIntro} label={t.eventCard} hint={h.rvEvents} copy={copy} />
            {cur.reviews === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : <ReviewInviteEvents rows={report.inviteEvents} copy={copy} locale={me.locale} />}
          </Card>
          <Card title={t.statesCard}>
            <FunnelIntro text={t.statesIntro} label={t.statesCard} hint={h.rvStates} copy={copy} />
            {report.marketStates.length === 0 ? <p className="text-body text-p4a-muted">{t.noMarkets}</p>
              : <ReviewMarketStates rows={report.marketStates} hints={hints} copy={copy} locale={me.locale} />}
          </Card>
        </div>
      </div>

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
