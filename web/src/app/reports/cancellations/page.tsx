import Link from "next/link";
import { CancellationList, CancellationMarkets, CancellationPeriods, CancellationReasons } from "@/components/CancellationParts";
import { CallsTile, DeltaLine, previousLabel } from "@/components/CallsParts";
import { FunnelFilters } from "@/components/FunnelFilters";
import { FunnelDateLine, FunnelGroupSwitch, FunnelIntro } from "@/components/FunnelParts";
import { PeriodBar } from "@/components/PeriodBar";
import { NoReportPermission } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, LinkButton, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock, type FunnelGroup } from "@/lib/data";
import { fmtDays, funnelClientCopy, parseFunnelFilter, parseFunnelGroup, periodKeys } from "@/lib/funnel";
import { holdsAny } from "@/lib/nav";
import { resolvePeriod } from "@/lib/period";
import { fmtCount, MAX_REPORT_DAYS, REPORT_PERMISSIONS } from "@/lib/reports";
import { dateKeyInZone, fmtDate } from "@/lib/time";
import { resolve } from "../../access";

/**
 * Cancellations (Report, addition 0008zb, 20 October 2026; backlog CMA-049 without CCL; KPI 4, churn): how many
 * cancellation requests come in per market per week. A request is a record of the kind the tenant's
 * reports.cancellation_kind names (Configuration, Sources: a kind with its rules, a pipeline, a category value or both),
 * of a counted pipeline, by its creation date. It counts the request (the ticket), never the contract: the shop and the
 * subscription system own the contract. Tiles for the requests, open now, closed and the median days to close, each with
 * its change against the previous period like for like; the requests per market, per week or day (G) and market, the
 * reasons where the kind's record type maps an enumeration property, and the newest requests with their links. Narrowed
 * by market (K); the address keys are market and group. Shown to people holding reports.view or performance.team; the
 * database checks again on every read. Ids, codes, counts, links and times only.
 */
export default async function CancellationsPage({ searchParams }: PageProps<"/reports/cancellations">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.cancellations;

  if (!holdsAny(me, REPORT_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="cancellations">
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
  const report = await data().getCancellations(me, period, group, filter.market);
  const periodQuery: Record<string, string> =
    range === "custom" && !invalid ? { range, from: period.from, to: period.to } : { range };
  const marketQuery: Record<string, string> = filter.market ? { market: filter.market } : {};
  const prevLabel = previousLabel(report.previousFrom, report.previousTo, report.previousPartial, copy, me.locale);

  const h = copy.hints;
  const n = (x: number) => fmtCount(x, me.locale);
  const hints: Record<string, string> = Object.fromEntries(Object.entries(h).filter(([k]) => k.startsWith("cn")));
  const info = (label: string, text: string) => ({ about: h.about.replace("{label}", label), text });
  const cur = report.current;
  const prev = report.previous;
  const delta = (current: number | null, previous: number | null, better?: "up" | "down") =>
    <DeltaLine current={current} previous={previous} compared={prevLabel} previousFrom={report.previousFrom} historyStart={report.historyStart}
      copy={copy} locale={me.locale} historyText={t.historyStarts} better={better} />;
  const reasonLabels = new Map(report.reasons.flatMap((x) => (x.value !== null && x.label !== null ? [[x.value, x.label] as [string, string]] : [])));
  const kindNotice = report.kind === null ? t.noKind : report.kind.status === "archived" ? t.kindArchived.replace("{kind}", report.kind.label) : null;
  const reasonNotice = report.kind === null ? null : report.reasonState === "none" ? t.reasonNone : report.reasonState === "unchecked" ? t.reasonUnchecked
    : report.reasonState === "refused" ? t.reasonRefused : null;
  const parts = filter.market ? [copy.funnel.activeMarket.replace("{market}", filter.market === "unknown" ? copy.reports.unknownMarket : filter.market)] : [];
  const history = report.historyStart ? [t.historyFrom.replace("{date}", fmtDate(report.historyStart, me.locale))] : [];

  return (
    <Shell copy={copy} me={me} active="cancellations" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-2 max-w-3xl text-small text-p4a-muted">{t.intro}</p>
      <p className="mb-6 max-w-3xl text-small text-p4a-muted" data-testid="cancellations-note">
        {report.kind ? t.note.replace("{kind}", report.kind.label) : t.noteNoKind}
      </p>

      <div className="flex flex-wrap items-start justify-between gap-x-6">
        <div>
          <PeriodBar pathname="/reports/cancellations" range={range} period={period} today={today} copy={copy} keep={{ group, ...marketQuery }} />
        </div>
        <div className="mb-6">
          <FunnelFilters pathname="/reports/cancellations" markets={report.markets} pipelines={[]} sourceChannels={[]} filter={filter}
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
      {kindNotice ? (
        <div className="mb-6" data-testid="cancellations-kind-notice">
          <Notice tone="info">
            {kindNotice}{" "}
            {holdsAny(me, "tenant.configure") ? <Link href="/configuration/sources" className="font-semibold text-p4a-deepblue underline">{t.configureLink}</Link> : null}
          </Notice>
        </div>
      ) : null}

      <div className="mb-6 flex flex-wrap items-end justify-between gap-4">
        <FunnelGroupSwitch pathname="/reports/cancellations" group={group} query={{ ...periodQuery, ...marketQuery }} copy={copy} />
        <FunnelDateLine from={period.from} to={period.to} parts={parts} history={history} copy={copy} locale={me.locale} testId="cancellations" />
      </div>

      <div className="flex flex-col gap-6">
        <section className="grid grid-cols-2 gap-4 lg:grid-cols-4" aria-label={t.title} data-testid="cancellations-tiles">
          <CallsTile testId="cancellations-requests" label={t.requests} value={n(cur.requests)} info={info(t.requests, h.cnRequests)} detail={t.requestsDetail}
            delta={delta(cur.requests, prev.requests)} />
          <CallsTile testId="cancellations-open" label={t.open} value={n(cur.open)} info={info(t.open, h.cnOpen)} detail={t.openDetail} delta={delta(cur.open, prev.open)} />
          <CallsTile testId="cancellations-closed" label={t.closed} value={n(cur.closed)} info={info(t.closed, h.cnClosed)} detail={t.closedDetail}
            delta={delta(cur.closed, prev.closed)} />
          <CallsTile testId="cancellations-days" label={t.daysToClose} value={fmtDays(cur.medianDaysToClose, me.locale, copy.funnel)} info={info(t.daysToClose, h.cnDays)}
            detail={t.daysToCloseDetail} delta={delta(cur.medianDaysToClose, prev.medianDaysToClose, "down")} />
        </section>

        <div className="grid gap-6 xl:grid-cols-2">
          <Card title={t.marketCard}>
            <FunnelIntro text={t.marketIntro} label={t.marketCard} hint={h.cnMarkets} copy={copy} />
            {report.byMarket.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p>
              : <CancellationMarkets rows={report.byMarket} hints={hints} copy={copy} locale={me.locale} />}
          </Card>
          <Card title={t.reasonsCard}>
            <FunnelIntro text={t.reasonsIntro} label={t.reasonsCard} hint={h.cnReasons} copy={copy} />
            {reasonNotice ? <div className="mb-4"><Notice tone={report.reasonState === "refused" ? "warning" : "info"}>{reasonNotice}</Notice></div> : null}
            {cur.requests === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p>
              : <CancellationReasons reasons={report.reasons} total={cur.requests} copy={copy} locale={me.locale} />}
          </Card>
        </div>

        <Card title={group === "week" ? t.periodCardWeek : t.periodCardDay}>
          <div className="-mt-2 mb-4 flex justify-end">
            <LinkButton href={`/api/v1/reports/cancellations/export?${new URLSearchParams({ from: period.from, to: period.to, group, ...marketQuery }).toString()}`}
              download shortcut="X" data-shortcut="x" title={t.downloadHint} data-testid="cancellations-download">{t.download}</LinkButton>
          </div>
          <CancellationPeriods byPeriod={report.byPeriod} keys={periodKeys(period.from, period.to, group)} group={group} hints={hints} copy={copy} locale={me.locale} />
        </Card>

        <Card title={t.listTitle}>
          <div className="-mt-2 mb-4 flex flex-wrap items-baseline justify-between gap-4">
            <p className="max-w-3xl text-small text-p4a-muted">{t.listIntro}</p>
            {report.list.total > 0 ? (
              <p className="text-caption text-p4a-grey" data-testid="cancellations-list-count">
                {copy.funnel.showing.replace("{shown}", n(report.list.rows.length)).replace("{total}", n(report.list.total))}
              </p>
            ) : null}
          </div>
          {report.list.rows.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
            <CancellationList rows={report.list.rows} reasonLabels={reasonLabels} hints={hints} copy={copy} locale={me.locale} timeZone={me.timeZone} />
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
