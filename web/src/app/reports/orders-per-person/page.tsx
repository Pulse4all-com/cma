import { notFound } from "next/navigation";
import { FirstOrderFilters } from "@/components/FirstOrderFilters";
import { FirstOrderDateLine } from "@/components/FirstOrderParts";
import { OrdersPerPersonTable } from "@/components/OrdersPerPersonTable";
import { PeriodBar } from "@/components/PeriodBar";
import { NoReportPermission, NotConnected } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock, type FirstOrderLevel } from "@/lib/data";
import { firstOrderFilterQuery, levelsInOrder, ORDERS_PER_PERSON_KEY, ORDERS_PER_PERSON_PERMISSION, parseFirstOrderFilter } from "@/lib/first-orders";
import { holdsAny } from "@/lib/nav";
import { resolvePeriod } from "@/lib/period";
import { fillHint, MAX_REPORT_DAYS } from "@/lib/reports";
import { dateKeyInZone } from "@/lib/time";
import { resolve } from "../../access";

/**
 * Orders per person (Report, addition 0008u; brief N19-A part 2): the first orders that came in through the call
 * center, credited to the person behind the latest assisted touch before the order (a lead deal's owner, a call's
 * agent or telephony user, an email's sender), narrowed by market (K) and level (V). Sorted by name, never ranked;
 * owner ids without a person last as one row with how many they are, never which; then the total. There only while
 * the tenant's reports.per_person holds orders (off for Pulse4all until Yordi confirms it, README Open decisions):
 * otherwise the page is not found, as its rail item and its route are absent; for people holding performance.team;
 * the database checks both again on every read. A tenant without an order pipeline sees "No orders connected".
 */
export default async function OrdersPerPersonPage({ searchParams }: PageProps<"/reports/orders-per-person">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.ordersPerPerson;
  if (!me.perPerson.includes(ORDERS_PER_PERSON_KEY)) notFound();

  if (!holdsAny(me, ORDERS_PER_PERSON_PERMISSION)) {
    return (
      <Shell copy={copy} me={me} active="orders-per-person">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={t.noPermissionTitle} body={t.noPermissionBody} />
      </Shell>
    );
  }

  const sp = await searchParams;
  const today = dateKeyInZone(new Date(), me.timeZone);
  const { range, period, invalid } = resolvePeriod(sp, today, MAX_REPORT_DAYS);
  const { filter, problem } = parseFirstOrderFilter(sp.market, sp.level);
  const people = await data().getOrdersPerPerson(me, period, filter);
  const periodQuery: Record<string, string> =
    range === "custom" && !invalid ? { range, from: period.from, to: period.to } : { range };
  const h = copy.hints;
  const words = (list: readonly FirstOrderLevel[]) => list.map((l) => copy.firstOrders[`level_${l}`].toLowerCase()).join(", ");
  const hints: Record<string, string> = Object.fromEntries(Object.entries(h).filter(([k]) => k.startsWith("fo")).map(([k, v]) => [k,
    fillHint(v.replaceAll("{assisted}", words(people.settings.assistedLevels)).replaceAll("{levels}", words(people.settings.levelOrder)),
      { hours: h.officeHours, days: people.settings.windowDays, minutes: people.settings.knownContactMinutes }, me.locale)]));

  return (
    <Shell copy={copy} me={me} active="orders-per-person" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>

      <div className="flex flex-wrap items-start justify-between gap-x-6">
        <div>
          <PeriodBar pathname="/reports/orders-per-person" range={range} period={period} today={today} copy={copy} keep={firstOrderFilterQuery(filter)} />
        </div>
        {people.connected ? (
          <div className="mb-6">
            <FirstOrderFilters pathname="/reports/orders-per-person" markets={people.markets} levels={levelsInOrder(people.settings)} filter={filter}
              query={periodQuery} copy={copy} />
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
          <Notice tone="warning">{copy.firstOrders.filterIgnored}</Notice>
        </div>
      ) : null}

      <div className="mb-6 flex justify-end">
        <FirstOrderDateLine from={period.from} to={period.to} market={filter.market} level={filter.level} historyStart={null} phoneStart={null}
          copy={copy} locale={me.locale} history={false} />
      </div>

      <Card>
        {!people.connected ? (
          <p className="text-body" data-testid="orders-person-not-connected">
            <NotConnected label={copy.reports.noOrders} hint={copy.reports.noOrdersHint} />
            <span className="ml-2 text-small text-p4a-muted">{copy.reports.noOrdersHint}</span>
          </p>
        ) : people.rows.length === 0 ? (
          <p className="text-body text-p4a-muted">{t.empty}</p>
        ) : (
          <OrdersPerPersonTable rows={people.rows} total={people.total} hints={hints} copy={copy} locale={me.locale} />
        )}
      </Card>

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
