import { NoReportPermission } from "@/components/ReportParts";
import { PlaceholderBody } from "@/components/PlaceholderPage";
import { Shell } from "@/components/Shell";
import { SubscriptionsFilters } from "@/components/SubscriptionsFilters";
import {
  Card, Movements, Mix, Note, Notice, PendingPart, piNoteNeeded, Rates, Refreshed, SectionTitle, SubscriptionList, SubscriptionsTiles, Survival, Switch,
  type SubscriptionsHref,
} from "@/components/SubscriptionsReport";
import { LinkButton, PageTitle } from "@/components/primitives";
import { subscriptionsCopy } from "@/lib/copy";
import { CmaDbError, data, dataIsMock, requestDbTrace, type SubscriptionRowsPage, type SubscriptionsPageQuery } from "@/lib/data";
import { holdsAny } from "@/lib/nav";
import { DATA_QUALITY_PERMISSIONS, REPORT_PERMISSIONS } from "@/lib/reports";
import {
  addMonths, measureOf, monthAddress, monthOf, monthsBetween, parseSubscriptionsFilter, sortOf, SUBSCRIPTIONS_MAX_MONTHS, SUBSCRIPTIONS_PATH,
  subscriptionsQuery, SUBSCRIPTIONS_VIEWS, type SubscriptionsView,
} from "@/lib/subscriptions";
import { dateKeyInZone, fmtDate } from "@/lib/time";
import { monthName } from "@/components/SubscriptionsReport";
import type { Route } from "next";
import { resolve } from "@/app/access";

/**
 * Customers → Subscriptions (addition 0009zh, brief B39 continued, Part B39d; Martin, 20 and 21 November 2026): how the
 * subscription base moves over months, while Flash keeps the stock per market and day (Decision log, 21 Nov 2026).
 * reports.view or performance.team, the wide layout, team figures only, ids and links only. One read from the
 * subscription facts' stored takes (cma.subscriptions_page): the tiles, the movements and rates per month, the stores'
 * starts, renewal survival, the mix and the list's page (a further page in the same read). Changes in the period and Who ended them need a take of the events that does not exist yet:
 * they stand as Pending parts. The address keys are market, store, proposition, interval, from, to, view, measure, sort,
 * dir and page. While no subscriptions connection is set up the placeholder stays.
 */
export default async function SubscriptionsPage({ searchParams }: PageProps<"/reports/subscriptions">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = subscriptionsCopy[me.locale];
  const locale = me.locale;

  if (!holdsAny(me, REPORT_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="subscriptions">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={copy.reports.noPermissionTitle} body={copy.reports.noPermissionBody} />
      </Shell>
    );
  }

  const sp = await searchParams;
  const one = (k: string) => { const v = sp[k]; return Array.isArray(v) ? v[0] : v; };
  const currentMonth = monthOf(dateKeyInZone(new Date(), me.timeZone));
  const parsed = parseSubscriptionsFilter(one, currentMonth);
  const view: SubscriptionsView = (SUBSCRIPTIONS_VIEWS as readonly string[]).includes(one("view") ?? "") ? (one("view") as SubscriptionsView) : "counts";
  const measure = measureOf(one("measure")) ?? "total";
  const sort = sortOf(one("sort")) ?? "monthly_amount";
  const descending = one("dir") !== "asc";
  const pageNo = /^[1-9][0-9]{0,4}$/.test(one("page") ?? "") ? Number(one("page")) : 1;
  let problem = parsed.problem !== null || (one("measure") !== undefined && measureOf(one("measure")) === null) || (one("sort") !== undefined && sortOf(one("sort")) === null);

  let query: SubscriptionsPageQuery = { ...parsed.filter, from: parsed.from, to: parsed.to, measure, sort, descending, page: pageNo };
  // a well-formed filter the tenant does not hold (another tenant's store, a proposition no longer in the setting): the
  // page without the filters instead, and the notice says so
  let doc = await data().getSubscriptionsPage(me, query).catch((e: unknown) => {
    if (e instanceof CmaDbError && e.sqlState === "CMA04") return null;
    throw e;
  });
  if (doc === null) {
    problem = true;
    const fallback = parseSubscriptionsFilter(() => undefined, currentMonth);
    query = { market: null, store: null, proposition: null, interval: null, from: fallback.from, to: fallback.to, measure, sort, descending, page: 1 };
    doc = await data().getSubscriptionsPage(me, query);
  }
  const filter = { market: query.market, store: query.store, proposition: query.proposition, interval: query.interval };
  // the list's page comes with the one read (a further page too: no second transaction)
  const list: SubscriptionRowsPage | null = doc.list;
  // under CMA_DB_TRACE the request's whole cost (verify/round-trips.mjs reads it)
  const dbTrace = requestDbTrace();

  if (!doc.setUp) {
    return (
      <Shell copy={copy} me={me} active="subscriptions">
        <PageTitle>{t.title}</PageTitle>
        <PlaceholderBody intro={copy.placeholders.intro_subscriptions} fedBy={copy.placeholders.fedBy_subscriptions} flash="subscriptions" me={me} copy={copy} />
        {dbTrace ? <meta name="cma-db" content={dbTrace} /> : null}
      </Shell>
    );
  }

  const base: Record<string, string> = {
    ...subscriptionsQuery(filter), from: monthAddress(doc.from), to: monthAddress(doc.to),
    ...(view !== "counts" ? { view } : {}), ...(measure !== "total" ? { measure } : {}), ...(sort !== "monthly_amount" ? { sort } : {}), ...(!descending ? { dir: "asc" } : {}),
  };
  const href: SubscriptionsHref = (change) => {
    const q: Record<string, string> = { ...base };
    for (const [k, v] of Object.entries(change)) { if (v === null) delete q[k]; else q[k] = v; }
    return { pathname: SUBSCRIPTIONS_PATH as Route, query: q };
  };
  const keep = Object.fromEntries(Object.entries(base).filter(([k]) => ["view", "measure", "sort", "dir"].includes(k)));
  const fileQuery = new URLSearchParams({ ...subscriptionsQuery(filter), ...(measure !== "total" ? { measure } : {}), ...(sort !== "monthly_amount" ? { sort } : {}),
    ...(!descending ? { dir: "asc" } : {}) }).toString();
  const monthsQuery = new URLSearchParams({ ...subscriptionsQuery(filter), from: monthAddress(doc.from), to: monthAddress(doc.to), part: "months" }).toString();
  // the months a range may take: the tenant's customers.history_months complete months and the current one
  const months = monthsBetween(addMonths(currentMonth, -Math.max(1, Math.min(doc.settings.historyMonths || 60, SUBSCRIPTIONS_MAX_MONTHS - 1))), currentMonth).reverse()
    .map((m) => ({ value: monthAddress(m), label: monthName(m, locale) }));
  const amountsFrom = doc.take?.amountsFrom ? dateKeyInZone(new Date(doc.take.amountsFrom), doc.timeZone || me.timeZone) : null;

  return (
    <Shell copy={copy} me={me} active="subscriptions" wide>
      <div data-testid="subscriptions-page">
        <PageTitle aside={(
          <div className="flex items-center gap-4">
            <span className="text-small text-p4a-muted"><Refreshed page={doc} t={t} locale={locale} /></span>
            {doc.history ? (
              <span className="flex items-center gap-3 print:hidden">
                <LinkButton href={`/api/v1/reports/subscriptions/file${fileQuery ? `?${fileQuery}` : ""}`} download data-testid="subscriptions-download">{t.download}</LinkButton>
                <LinkButton href={`/api/v1/reports/subscriptions/file?${monthsQuery}`} download data-testid="subscriptions-download-months">{t.downloadMonths}</LinkButton>
              </span>
            ) : null}
          </div>
        )}>{t.title}</PageTitle>
        <p className="-mt-2 mb-6 max-w-4xl text-small text-p4a-muted">{t.intro}</p>

        <div className="mb-6 print:hidden">
          <SubscriptionsFilters filter={filter} from={doc.from} to={doc.to} markets={doc.filters.markets} stores={doc.filters.stores}
            propositions={doc.filters.propositions} intervals={doc.filters.intervals} months={months} keep={keep}
            t={{
              filtersLabel: t.filtersLabel, marketFilter: t.marketFilter, allMarkets: t.allMarkets, unknownMarket: t.unknownMarket, storeFilter: t.storeFilter,
              allStores: t.allStores, propositionFilter: t.propositionFilter, allPropositions: t.allPropositions, noProposition: t.noProposition,
              intervalFilter: t.intervalFilter, allIntervals: t.allIntervals, interval_monthly: t.interval_monthly, interval_quarterly: t.interval_quarterly,
              interval_yearly: t.interval_yearly, interval_other: t.interval_other, interval_unknown: t.interval_unknown, fromLabel: t.fromLabel, toLabel: t.toLabel,
            }} />
        </div>
        {problem ? <div className="mb-6"><Notice tone="warning">{t.filterIgnored}</Notice></div> : null}

        {!doc.history ? <div className="mb-6" data-testid="subscriptions-preparing"><Notice tone="info">{t.preparing}</Notice></div> : (
          <div className="flex flex-col gap-6">
            <SubscriptionsTiles page={doc} t={t} copy={copy} locale={locale} dataQuality={holdsAny(me, DATA_QUALITY_PERMISSIONS)} />
            {piNoteNeeded(filter) ? <Note testId="subscriptions-pi-note">{t.piNote}</Note> : null}

            <Card>
              <SectionTitle label={t.movementsTitle} hint={t.h_movements} copy={copy}>
                <Switch label={t.showAs} testId="subscriptions-view" current={view} options={SUBSCRIPTIONS_VIEWS.map((v) => ({ value: v, label: t[`view_${v}`] }))}
                  href={(v) => href({ view: v === "counts" ? null : v })} />
              </SectionTitle>
              {amountsFrom ? <Note testId="subscriptions-amounts-note">{t.amountsNote.replace("{date}", fmtDate(amountsFrom, locale, "medium"))}</Note> : null}
              <Movements page={doc} view={view} t={t} locale={locale} />
              <p className="mt-3 text-caption text-p4a-grey">{t.bridgeNote}</p>
            </Card>

            <Card>
              <SectionTitle label={t.ratesTitle} hint={t.h_rates} copy={copy} />
              <Rates page={doc} t={t} locale={locale} />
            </Card>

            <Card>
              <SectionTitle label={t.survivalTitle} hint={t.h_survival} copy={copy} />
              {doc.survival && doc.survival.migratedLeftOut > 0 ? (
                <Note testId="subscriptions-migrated-note">{t.migratedNote.replace("{n}", new Intl.NumberFormat(locale === "nl" ? "nl-NL" : "en-GB").format(doc.survival.migratedLeftOut))}</Note>
              ) : null}
              {filter.proposition !== null ? <Note testId="subscriptions-survival-pi-note">{t.survivalPiNote}</Note> : null}
              <Survival page={doc} t={t} locale={locale} />
            </Card>

            <Card>
              <SectionTitle label={t.mixTitle} hint={t.h_mix} copy={copy} />
              <Note testId="subscriptions-mix-note">{t.multiNote}</Note>
              <Mix page={doc} t={t} locale={locale} />
            </Card>

            <div className="grid grid-cols-1 gap-6 xl:grid-cols-2">
              <PendingPart title={t.changesTitle} fedBy={t.changesFedBy} t={t} copy={copy} testId="subscriptions-changes" />
              <PendingPart title={t.whoEndedTitle} fedBy={t.whoEndedFedBy} t={t} copy={copy} testId="subscriptions-who-ended" />
            </div>

            <Card>
              <SectionTitle label={t.listTitle} hint={t.h_list} copy={copy} />
              {list ? <SubscriptionList list={list} measure={measure} sort={sort} descending={descending} href={href} t={t} locale={locale} /> : null}
            </Card>
          </div>
        )}
        {dataIsMock ? <div className="mt-6"><Notice tone="info">{copy.shell.testData}</Notice></div> : null}
        {dbTrace ? <meta name="cma-db" content={dbTrace} /> : null}
      </div>
    </Shell>
  );
}
