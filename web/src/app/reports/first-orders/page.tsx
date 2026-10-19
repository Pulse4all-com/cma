import { CallsTile, DeltaLine, previousLabel } from "@/components/CallsParts";
import { FirstOrderFilters } from "@/components/FirstOrderFilters";
import {
  AmountsTable, AttributionColumns, FirstOrderDateLine, FirstOrderGroupSwitch, FirstOrderListTable, FirstOrderTable, LevelBars,
} from "@/components/FirstOrderParts";
import { PeriodBar } from "@/components/PeriodBar";
import { NoReportPermission, NotConnected } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, LinkButton, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock, type FirstOrderGroup, type FirstOrderLevel } from "@/lib/data";
import { callCenterShare, firstOrderFilterQuery, fmtDays, levelsInOrder, parseFirstOrderFilter, parseFirstOrderGroup } from "@/lib/first-orders";
import { holdsAny } from "@/lib/nav";
import { resolvePeriod } from "@/lib/period";
import { fillHint, fmtCount, fmtShare, MAX_REPORT_DAYS, REPORT_PERMISSIONS } from "@/lib/reports";
import { dateKeyInZone } from "@/lib/time";
import { resolve } from "../../access";

/**
 * First orders (Report, addition 0008u; brief N19-A part 2): of the new first orders of a period, which came in by
 * self-service and which through the call center, per day, ISO week, market or level (G), narrowed by market (K) and
 * level (V). Four tiles: the first orders (the repeat orders, renewals, store repeats and orders without a contact
 * counted apart), those via the call center and by self-service with their share, and the median days from the
 * first touch; the volumes with their change against the previous period in Muted text with an arrow, like for like
 * (before the first-orders history "No history to compare yet"). Then the columns per day or week (call center Deep
 * Blue, self-service Leaf Green), the levels as horizontal bars in the tenant's order, the figures per market with
 * the amounts per currency, the amounts per currency, and the first orders themselves (capped by
 * follow_up.list_rows), which download as a file in the tenant's export format (X). "History from …" and "Phone
 * matching from …" in Muted text under the date line. Shown to people holding reports.view or performance.team;
 * the database checks again on every read. A tenant without an order pipeline sees "No orders connected", never 0.
 * Ids, codes, counts, amounts and times only. Every tile and header explains itself in a hint with the tenant's
 * values filled in.
 */
export default async function FirstOrdersPage({ searchParams }: PageProps<"/reports/first-orders">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.firstOrders;

  if (!holdsAny(me, REPORT_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="first-orders">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={copy.reports.noPermissionTitle} body={copy.reports.noPermissionBody} />
      </Shell>
    );
  }

  const sp = await searchParams;
  const today = dateKeyInZone(new Date(), me.timeZone);
  const { range, period, invalid } = resolvePeriod(sp, today, MAX_REPORT_DAYS);
  const group: FirstOrderGroup = parseFirstOrderGroup(sp.group) ?? "day";
  const { filter, problem } = parseFirstOrderFilter(sp.market, sp.level);
  const report = await data().getFirstOrders(me, period, group, filter);
  const periodQuery: Record<string, string> =
    range === "custom" && !invalid ? { range, from: period.from, to: period.to } : { range };
  const prevLabel = previousLabel(report.previousFrom, report.previousTo, report.previousPartial, copy, me.locale);
  const levels = levelsInOrder(report.settings);

  const h = copy.hints;
  const n = (x: number) => fmtCount(x, me.locale);
  const words = (list: readonly FirstOrderLevel[]) => list.map((l) => t[`level_${l}`].toLowerCase()).join(", ");
  const fill = (text: string) => fillHint(text.replaceAll("{assisted}", words(report.settings.assistedLevels)).replaceAll("{levels}", words(report.settings.levelOrder)),
    { hours: h.officeHours, days: report.settings.windowDays, minutes: report.settings.knownContactMinutes }, me.locale);
  const info = (label: string, text: string) => ({ about: h.about.replace("{label}", label), text: fill(text) });
  const hints: Record<string, string> = Object.fromEntries(Object.entries(h).filter(([k]) => k.startsWith("fo")).map(([k, v]) => [k, fill(v)]));
  const levelHints = {
    lead_deal: hints.foLeadDeal!, conversation: hints.foConversation!, email: hints.foEmail!, phone_match: hints.foPhoneMatch!, attempt: hints.foAttempt!,
    known_contact: hints.foKnownContact!, self_service: hints.foNoEvidence!,
  } satisfies Record<FirstOrderLevel, string>;
  const delta = (current: number, previous: number) =>
    <DeltaLine current={current} previous={previous} compared={prevLabel} previousFrom={report.previousFrom} historyStart={report.historyStart}
      copy={copy} locale={me.locale} historyText={t.historyStarts} />;
  const total = report.total;
  const share = callCenterShare(total);
  const perGroup = group === "week" ? t.perWeek : t.perDay;
  const download = `/api/v1/reports/first-orders/export?${new URLSearchParams({ from: period.from, to: period.to, ...firstOrderFilterQuery(filter) }).toString()}`;

  return (
    <Shell copy={copy} me={me} active="first-orders" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>

      <div className="flex flex-wrap items-start justify-between gap-x-6">
        <div>
          <PeriodBar pathname="/reports/first-orders" range={range} period={period} today={today} copy={copy} keep={{ group, ...firstOrderFilterQuery(filter) }} />
        </div>
        {report.connected ? (
          <div className="mb-6">
            <FirstOrderFilters pathname="/reports/first-orders" markets={report.markets} levels={levels} filter={filter} query={{ ...periodQuery, group }} copy={copy} />
          </div>
        ) : null}
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

      <div className="mb-6 flex items-end justify-between gap-4">
        <FirstOrderGroupSwitch group={group} query={{ ...periodQuery, ...firstOrderFilterQuery(filter) }} copy={copy} />
        <div className="flex items-end gap-4">
          <FirstOrderDateLine from={period.from} to={period.to} market={filter.market} level={filter.level} historyStart={report.historyStart}
            phoneStart={report.phoneStart} copy={copy} locale={me.locale} />
          {report.connected && !invalid ? (
            <LinkButton href={download} download shortcut="X" data-shortcut="x" title={t.downloadHint} data-testid="first-order-download">{t.download}</LinkButton>
          ) : null}
        </div>
      </div>

      {!report.connected ? (
        <Card>
          <p className="text-body" data-testid="first-orders-not-connected">
            <NotConnected label={copy.reports.noOrders} hint={copy.reports.noOrdersHint} />
            <span className="ml-2 text-small text-p4a-muted">{copy.reports.noOrdersHint}</span>
          </p>
        </Card>
      ) : (
        <div className="flex flex-col gap-6">
          <section className="grid grid-cols-4 gap-4" aria-label={t.title} data-testid="first-order-tiles">
            <CallsTile testId="first-order-total" label={t.firstOrders} value={n(total.firstOrders)} info={info(t.firstOrders, h.foOrders)}
              detail={t.firstOrdersDetail.replace("{repeats}", n(total.repeats)).replace("{renewals}", n(total.renewals)).replace("{notFirst}", n(total.notFirst))
                .replace("{noContact}", n(total.noContact))}
              delta={delta(total.firstOrders, report.previous.firstOrders)} />
            <CallsTile testId="first-order-call-center" label={t.callCenter} value={n(total.callCenter)} info={info(t.callCenter, h.foCallCenter)}
              detail={t.shareDetail.replace("{pct}", fmtShare(share, me.locale))} delta={delta(total.callCenter, report.previous.callCenter)} />
            <CallsTile testId="first-order-self-service" label={t.selfService} value={n(total.selfService)} info={info(t.selfService, h.foSelfService)}
              detail={t.shareDetail.replace("{pct}", fmtShare(share === null ? null : 1 - share, me.locale))}
              delta={delta(total.selfService, report.previous.selfService)} />
            <CallsTile testId="first-order-days" label={t.days} value={fmtDays(total.daysMedian, me.locale)} info={info(t.days, h.foDays)}
              detail={total.withTouch === 0 ? t.daysNone : t.daysDetail.replace("{n}", n(total.withTouch))} />
          </section>

          {group === "day" || group === "week" ? (
            <Card title={`${t.chart}, ${perGroup}`}>
              {total.firstOrders === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
                <AttributionColumns rows={report.rows} group={group} from={period.from} to={period.to} last={today} copy={copy} locale={me.locale} />
              )}
            </Card>
          ) : (
            <Card title={t.byGroup}>
              {report.rows.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
                <FirstOrderTable rows={report.rows} dimension={group} amounts={group === "market" ? report.amountsByMarket : null} hints={hints}
                  testId="first-order-by-group" title={t.byGroup} copy={copy} locale={me.locale} />
              )}
            </Card>
          )}

          <Card title={t.levelsTitle}>
            <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted">{fill(t.levelsIntro)}</p>
            <LevelBars rows={report.byLevel} levels={levels} assisted={report.settings.assistedLevels} hints={levelHints} copy={copy} locale={me.locale} />
          </Card>

          <Card title={t.byMarket}>
            {report.byMarket.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
              <FirstOrderTable rows={report.byMarket} dimension="market" amounts={report.amountsByMarket} hints={hints} testId="first-order-by-market"
                title={t.byMarket} copy={copy} locale={me.locale} />
            )}
          </Card>

          <Card title={t.amountsTitle}>
            <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted">{t.amountsIntro}</p>
            {report.amounts.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
              <AmountsTable amounts={report.amounts} hints={hints} copy={copy} locale={me.locale} />
            )}
          </Card>

          <Card title={t.listTitle}>
            <div className="-mt-2 mb-4 flex flex-wrap items-baseline justify-between gap-4">
              <p className="max-w-3xl text-small text-p4a-muted">{t.listIntro}</p>
              {report.list.total > 0 ? (
                <p className="text-caption text-p4a-grey" data-testid="first-order-list-count">
                  {t.showing.replace("{shown}", n(report.list.rows.length)).replace("{total}", n(report.list.total))}
                </p>
              ) : null}
            </div>
            {report.list.rows.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
              <FirstOrderListTable rows={report.list.rows} levelOrder={report.settings.levelOrder} hints={hints} copy={copy} locale={me.locale} timeZone={me.timeZone} />
            )}
          </Card>
        </div>
      )}

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
