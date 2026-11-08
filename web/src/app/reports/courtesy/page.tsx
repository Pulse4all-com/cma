import Link from "next/link";
import type { Route } from "next";
import { CallsTile, DeltaLine, previousLabel } from "@/components/CallsParts";
import { CohortSwitch } from "@/components/CohortParts";
import { CourtesyFilters } from "@/components/CourtesyFilters";
import { CourtesyCohorts, CourtesyList, CourtesyMarkets, CourtesyOutcomes, CourtesyPeople, CourtesyPeriods } from "@/components/CourtesyParts";
import { FunnelDateLine, FunnelIntro } from "@/components/FunnelParts";
import { PeriodBar } from "@/components/PeriodBar";
import { NoReportPermission } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import {
  COURTESY_GROUPS, COURTESY_PERIODS, courtesyGroupOf, courtesyPeriodOf, courtesyQuery, fillCourtesyHint, nextOf, parseCourtesyFilter,
} from "@/lib/courtesy";
import { data, dataIsMock } from "@/lib/data";
import { holdsAny } from "@/lib/nav";
import { resolvePeriod } from "@/lib/period";
import { fmtCount, MAX_REPORT_DAYS, REPORT_PERMISSIONS } from "@/lib/reports";
import { dateKeyInZone, fmtDate } from "@/lib/time";
import { metricsMore } from "@/lib/metrics";
import { resolve } from "../../access";

/**
 * Courtesy (Customers, addition 0009a, brief B31, Martin, 6 November 2026; docs/definitions.md, Courtesy terms): every First or
 * Repeat store order (courtesy.order_kinds) from courtesy.start_date gets a courtesy call from day courtesy.due_days. Two kinds of
 * figure, each saying which in its hint, and every figure counts courtesy orders (addition 0009d, brief B34): now (every
 * courtesy order since the start date: the orders due and not courtesy completed, Unreachable, the flag after
 * courtesy.alert_attempts attempts without a Conversation, No contact, and the order list with each order's state and the
 * contact's record link) and the period, on two bases each block names: by completion date the courtesy orders completed in
 * the period, placed on any date (the tile, with the previous period like for like, and their outcomes; per person, for
 * performance.team only, by name, never ranked); by order date the orders placed in the period, of which due and of which
 * courtesy completed, with their state now (per market and per day, week or month (G); the order cohorts per week or month
 * (O) at the ages of courtesy.ages_days). Per market also counts the orders completed in the period, each in its own market,
 * with a total row, so its last column adds up to the tile; Per week has no such column. The hints name the tenant's
 * completed tags (settings.completedTags). Narrowed by
 * market (K), segment and state (S), in the database. Not set up (no start date): the page says so and shows no count; a tenant
 * without a store says "No store connected", never 0. Shown to people holding reports.view or performance.team, as Reviews; the
 * database checks again on every read. Ids, codes, counts, dates and links only: never a customer's name, email, phone or address.
 */
export default async function CourtesyPage({ searchParams }: PageProps<"/reports/courtesy">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.courtesy;

  if (!holdsAny(me, REPORT_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="courtesy">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={copy.reports.noPermissionTitle} body={copy.reports.noPermissionBody} />
      </Shell>
    );
  }

  const sp = await searchParams;
  const today = dateKeyInZone(new Date(), me.timeZone);
  const { range, period, invalid } = resolvePeriod(sp, today, MAX_REPORT_DAYS);
  const group = courtesyGroupOf(sp.group);
  const cohort = courtesyPeriodOf(sp.period);
  const { filter, problem } = parseCourtesyFilter(sp.market, sp.segment, sp.state);
  const report = await data().getCourtesy(me, period, cohort, group, filter);
  const periodQuery: Record<string, string> = range === "custom" && !invalid ? { range, from: period.from, to: period.to } : { range };
  const shapeQuery: Record<string, string> = { ...(group === "week" ? {} : { group }), ...(cohort === "week" ? {} : { period: cohort }) };
  const filterQuery = courtesyQuery(filter);
  const href = (q: Record<string, string>) => ({ pathname: "/reports/courtesy" as Route, query: q });

  const h = copy.hints;
  const n = (x: number) => fmtCount(x, me.locale);
  // every hint with the tenant's settings filled in (day 10, 3 attempts, the ages, the order kinds by their labels, and since
  // 0009d the tenant's completed tags by name, or the words saying none is mapped yet)
  const kindLabel: Record<string, string> = { first: copy.flash.kind_first, repeat: copy.flash.kind_repeat, renewal: copy.flash.kind_renewal };
  const kindNames = new Intl.ListFormat(me.locale === "nl" ? "nl-NL" : "en-GB", { type: "conjunction" })
    .format(report.settings.orderKinds.map((k) => kindLabel[k] ?? k));
  const tagNames = report.settings.completedTags.length > 0
    ? new Intl.ListFormat(me.locale === "nl" ? "nl-NL" : "en-GB", { type: "disjunction" }).format(report.settings.completedTags)
    : t.noCompletedTags;
  const hints: Record<string, string> = Object.fromEntries(Object.entries(h).filter(([k]) => k.startsWith("ct"))
    .map(([k, v]) => [k, fillCourtesyHint(v, report.settings, kindNames, tagNames)]));
  const fill = (text: string) => fillCourtesyHint(text, report.settings, kindNames, tagNames);
  const info = (label: string, text: string, key?: string) =>
    ({ about: h.about.replace("{label}", label), text, more: key ? metricsMore(me.permissions, key, h.howComputed) : undefined });
  const prevLabel = report.previousFrom !== null && report.previousTo !== null
    ? previousLabel(report.previousFrom, report.previousTo, report.previousPartial, copy, me.locale) : { text: "", dates: null, partial: false };
  const parts = [
    ...(filter.market ? [copy.funnel.activeMarket.replace("{market}", filter.market === "unknown" ? copy.reports.unknownMarket : filter.market)] : []),
    ...(filter.segment ? [`${t.segmentFilter}: ${filter.segment === "unknown" ? t.unknownSegment : filter.segment}`] : []),
  ];
  const history = report.startDate ? [t.historyFrom.replace("{date}", fmtDate(report.startDate, me.locale))] : [];
  const now = report.now;
  const showFigures = report.setUp && report.hasStore && now !== null && report.completed !== null && report.previous !== null;

  return (
    <Shell copy={copy} me={me} active="courtesy" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-2 max-w-3xl text-small text-p4a-muted">{fill(t.intro)}</p>
      <p className="mb-6 max-w-3xl text-small text-p4a-muted" data-testid="courtesy-note">{fill(t.note)}</p>

      <div className="flex flex-wrap items-start justify-between gap-x-6">
        <div>
          <PeriodBar pathname="/reports/courtesy" range={range} period={period} today={today} copy={copy} keep={{ ...shapeQuery, ...filterQuery }} />
        </div>
        <div className="mb-6">
          <CourtesyFilters markets={report.markets} segments={report.segments} filter={filter} keep={{ ...periodQuery, ...shapeQuery }} t={t}
            unknownMarket={copy.reports.unknownMarket} />
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
      {!report.hasStore ? (
        <div className="mb-6" data-testid="courtesy-no-store">
          <Notice tone="info">{t.noStore}</Notice>
        </div>
      ) : !report.setUp ? (
        <div className="mb-6" data-testid="courtesy-not-set-up">
          <Notice tone="info">
            {t.notSetUp}{" "}
            {holdsAny(me, "tenant.configure") ? <Link href="/configuration/exports" className="font-semibold text-p4a-deepblue underline">{t.configureLink}</Link> : null}
          </Notice>
        </div>
      ) : null}

      {showFigures ? (
        <>
          <div className="mb-6 flex flex-wrap items-end justify-between gap-4">
            <div className="flex flex-wrap items-end gap-6">
              <CohortSwitch label={t.groupBy} letter="g" testId="courtesy-group" current={group} next={nextOf(COURTESY_GROUPS, group)}
                options={COURTESY_GROUPS.map((g) => ({ value: g, label: t[g] }))}
                href={(g) => href({ ...periodQuery, ...filterQuery, ...(g === "week" ? {} : { group: g }), ...(cohort === "week" ? {} : { period: cohort }) })} />
              <CohortSwitch label={t.cohortBy} letter="o" testId="courtesy-cohort" current={cohort} next={nextOf(COURTESY_PERIODS, cohort)}
                options={COURTESY_PERIODS.map((p) => ({ value: p, label: t[p] }))}
                href={(p) => href({ ...periodQuery, ...filterQuery, ...(group === "week" ? {} : { group }), ...(p === "week" ? {} : { period: p }) })} />
            </div>
            <FunnelDateLine from={period.from} to={period.to} parts={parts} history={history} copy={copy} locale={me.locale} testId="courtesy" />
          </div>

          <div className="flex flex-col gap-6">
            <section className="grid grid-cols-2 gap-4 lg:grid-cols-4" aria-label={t.title} data-testid="courtesy-tiles">
              <CallsTile testId="courtesy-completed" label={t.completedOrders} value={n(report.completed!.orders)}
                info={info(t.completedOrders, hints.ctCompletedOrders!, "courtesy.completed_in_period")} detail={t.completedDetail}
                delta={<DeltaLine current={report.completed!.orders} previous={report.previous!.orders} compared={prevLabel} previousFrom={report.previousFrom}
                  historyStart={report.startDate} copy={copy} locale={me.locale} historyText={t.historyFrom} better="up" />} />
              <CallsTile testId="courtesy-due-open" label={t.dueOpen} value={n(now!.dueOpen)} info={info(t.dueOpen, hints.ctDueOpen!, "courtesy.due_open")}
                detail={fill(t.dueOpenDetail)} />
              <CallsTile testId="courtesy-unreachable" label={t.unreachable} value={n(now!.unreachable)} info={info(t.unreachable, hints.ctUnreachable!, "courtesy.unreachable")}
                detail={fill(t.unreachableDetail)} />
              <CallsTile testId="courtesy-no-contact" label={t.noContact} value={n(now!.noContact)} info={info(t.noContact, hints.ctNoContact!, "courtesy.no_contact")}
                detail={t.noContactDetail} />
            </section>

            {/* the outcome bar, then the tables of six columns at full width */}
            <Card title={t.outcomeCard}>
              <FunnelIntro text={t.outcomeIntro} label={t.outcomeCard} hint={hints.ctOutcomes!} copy={copy} />
              {report.completed!.orders === 0 ? <p className="text-body text-p4a-muted">{t.noCompleted}</p>
                : <CourtesyOutcomes completed={report.completed!} copy={copy} locale={me.locale} />}
            </Card>

            <Card title={t.marketCard}>
              <FunnelIntro text={t.marketIntro} label={t.marketCard} hint={hints.ctMarkets!} copy={copy} />
              {report.byMarket.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p>
                : <CourtesyMarkets rows={report.byMarket} total={report.marketsTotal} hints={hints} copy={copy} locale={me.locale} />}
            </Card>

            <Card title={group === "day" ? t.periodCardDay : group === "week" ? t.periodCardWeek : t.periodCardMonth}>
              <FunnelIntro text={t.periodIntro} label={group === "day" ? t.periodCardDay : group === "week" ? t.periodCardWeek : t.periodCardMonth}
                hint={hints.ctColPeriod!} copy={copy} />
              <CourtesyPeriods rows={report.byGroup} group={group} hints={hints} copy={copy} locale={me.locale} />
            </Card>

            <Card title={t.cohortCard}>
              <FunnelIntro text={t.cohortIntro} label={t.cohortCard} hint={hints.ctColAge!} copy={copy} />
              {report.cohorts.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p>
                : <CourtesyCohorts cohorts={report.cohorts} ages={report.settings.ages} hints={hints} copy={copy} locale={me.locale} />}
            </Card>

            {report.perPerson !== null ? (
              <Card title={t.personCard}>
                <FunnelIntro text={t.personIntro} label={t.personCard} hint={hints.ctColPerson!} copy={copy} />
                {report.perPerson.length === 0 ? <p className="text-body text-p4a-muted">{t.noCompleted}</p>
                  : <CourtesyPeople rows={report.perPerson} hints={hints} copy={copy} locale={me.locale} />}
              </Card>
            ) : null}

            <Card title={t.listCard}>
              <FunnelIntro text={t.listIntro.replace("{date}", report.startDate ? fmtDate(report.startDate, me.locale) : "")} label={t.listCard} hint={hints.ctColState!} copy={copy} />
              {report.list.total === 0 ? <p className="text-body text-p4a-muted">{t.emptyList}</p>
                : <CourtesyList list={report.list} hints={hints} copy={copy} locale={me.locale} timeZone={me.timeZone} />}
            </Card>
          </div>
        </>
      ) : null}

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
