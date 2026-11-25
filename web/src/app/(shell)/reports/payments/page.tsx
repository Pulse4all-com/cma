import Link from "next/link";
import { NoReportPermission } from "@/components/ReportParts";
import { PlaceholderBody } from "@/components/PlaceholderPage";
import { Shell } from "@/components/Shell";
import { SubscriptionsFilters } from "@/components/SubscriptionsFilters";
import { Card, monthName, Note, Notice, PendingPart, SectionTitle, type SubscriptionsHref } from "@/components/SubscriptionsReport";
import { FailedRates, PaymentList, PaymentsCross, PaymentsRefreshed, PaymentsTiles } from "@/components/PaymentsReport";
import { LinkButton, PageTitle } from "@/components/primitives";
import { paymentsCopy, subscriptionsCopy } from "@/lib/copy";
import { CmaDbError, data, dataIsMock, requestDbTrace, type PaymentsPageQuery } from "@/lib/data";
import { flashHref } from "@/lib/flash";
import { holdsAny } from "@/lib/nav";
import { listStateOf, PAYMENTS_PATH, paymentsSortOf } from "@/lib/payments";
import { REPORT_PERMISSIONS } from "@/lib/reports";
import {
  addMonths, monthAddress, monthOf, monthsBetween, parseSubscriptionsFilter, SUBSCRIPTIONS_MAX_MONTHS, subscriptionsQuery,
} from "@/lib/subscriptions";
import { dateKeyInZone } from "@/lib/time";
import type { Route } from "next";
import { resolve } from "@/app/access";

/**
 * Customers → Payments (addition 0009zw; Martin, 25 November 2026): the payment state of the subscription base over
 * months and what is at risk, built on Customers → Subscriptions' payment parts and filters, while Flash's Payments
 * overview keeps the financial status of orders and the renewals per market and day. reports.view or performance.team,
 * the wide layout, team figures only, ids and links only. One read from the subscription facts' stored takes
 * (cma.payments_page): the tiles per payment state with the Amount at risk and the Failed rate, the Failed rate by month,
 * the table by payment instrument and the list's page (a further page in the same read). Renewals, chargebacks and
 * refunds by month need a take of the events that does not exist yet: they stand as a Pending part. The address keys
 * are market, store, proposition, interval, from, to, state, sort, dir and page. While no subscriptions connection is
 * set up the placeholder stays.
 */
export default async function PaymentsPage({ searchParams }: PageProps<"/reports/payments">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = paymentsCopy[me.locale];
  const s = subscriptionsCopy[me.locale];
  const locale = me.locale;

  if (!holdsAny(me, REPORT_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="payments">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={copy.reports.noPermissionTitle} body={copy.reports.noPermissionBody} />
      </Shell>
    );
  }

  const sp = await searchParams;
  const one = (k: string) => { const v = sp[k]; return Array.isArray(v) ? v[0] : v; };
  const currentMonth = monthOf(dateKeyInZone(new Date(), me.timeZone));
  const parsed = parseSubscriptionsFilter(one, currentMonth);
  const state = listStateOf(one("state")) ?? "at_risk";
  const sort = paymentsSortOf(one("sort")) ?? "amount_at_risk";
  const descending = one("dir") !== "asc";
  const pageNo = /^[1-9][0-9]{0,4}$/.test(one("page") ?? "") ? Number(one("page")) : 1;
  let problem = parsed.problem !== null || (one("state") !== undefined && listStateOf(one("state")) === null)
    || (one("sort") !== undefined && paymentsSortOf(one("sort")) === null);

  let query: PaymentsPageQuery = { ...parsed.filter, from: parsed.from, to: parsed.to, state, sort, descending, page: pageNo };
  // a well-formed filter the tenant does not hold (another tenant's store, a proposition no longer in the setting): the
  // page without the filters instead, and the notice says so
  let doc = await data().getPaymentsPage(me, query).catch((e: unknown) => {
    if (e instanceof CmaDbError && e.sqlState === "CMA04") return null;
    throw e;
  });
  if (doc === null) {
    problem = true;
    const fallback = parseSubscriptionsFilter(() => undefined, currentMonth);
    query = { market: null, store: null, proposition: null, interval: null, from: fallback.from, to: fallback.to, state, sort, descending, page: 1 };
    doc = await data().getPaymentsPage(me, query);
  }
  const filter = { market: query.market, store: query.store, proposition: query.proposition, interval: query.interval };
  // under CMA_DB_TRACE the request's whole cost (verify/round-trips.mjs reads it)
  const dbTrace = requestDbTrace();

  if (!doc.setUp) {
    return (
      <Shell copy={copy} me={me} active="payments">
        <PageTitle>{t.title}</PageTitle>
        <PlaceholderBody intro={copy.placeholders.intro_payments} fedBy={copy.placeholders.fedBy_payments} flash="payments" me={me} copy={copy} />
        {dbTrace ? <meta name="cma-db" content={dbTrace} /> : null}
      </Shell>
    );
  }

  const base: Record<string, string> = {
    ...subscriptionsQuery(filter), from: monthAddress(doc.from), to: monthAddress(doc.to),
    ...(state !== "at_risk" ? { state } : {}), ...(sort !== "amount_at_risk" ? { sort } : {}), ...(!descending ? { dir: "asc" } : {}),
  };
  const href: SubscriptionsHref = (change) => {
    const q: Record<string, string> = { ...base };
    for (const [k, v] of Object.entries(change)) { if (v === null) delete q[k]; else q[k] = v; }
    return { pathname: PAYMENTS_PATH as Route, query: q };
  };
  const keep = Object.fromEntries(Object.entries(base).filter(([k]) => ["state", "sort", "dir"].includes(k)));
  const fileQuery = new URLSearchParams({ ...subscriptionsQuery(filter), ...(state !== "at_risk" ? { state } : {}), ...(sort !== "amount_at_risk" ? { sort } : {}),
    ...(!descending ? { dir: "asc" } : {}) }).toString();
  const monthsQuery = new URLSearchParams({ ...subscriptionsQuery(filter), from: monthAddress(doc.from), to: monthAddress(doc.to), part: "months" }).toString();
  // the months a range may take: the tenant's customers.history_months complete months and the current one
  const months = monthsBetween(addMonths(currentMonth, -Math.max(1, Math.min(doc.settings.historyMonths || 60, SUBSCRIPTIONS_MAX_MONTHS - 1))), currentMonth).reverse()
    .map((m) => ({ value: monthAddress(m), label: monthName(m, locale) }));
  // Flash's Payments overview over this month to today (its period bar reads from and to with range=custom, at most 366
  // days, so never the page's whole range)
  const flashPayments = flashHref("/reports/flash", { o: "payments", ...(filter.market ? { market: filter.market } : {}), range: "custom", from: doc.month, to: doc.today });

  return (
    <Shell copy={copy} me={me} active="payments" wide>
      <div data-testid="payments-page">
        <PageTitle aside={(
          <div className="flex items-center gap-4">
            <span className="text-small text-p4a-muted"><PaymentsRefreshed page={doc} s={s} locale={locale} /></span>
            {doc.history ? (
              <span className="flex items-center gap-3 print:hidden">
                <LinkButton href={`/api/v1/reports/payments/file${fileQuery ? `?${fileQuery}` : ""}`} download data-testid="payments-download">{s.download}</LinkButton>
                <LinkButton href={`/api/v1/reports/payments/file?${monthsQuery}`} download data-testid="payments-download-months">{s.downloadMonths}</LinkButton>
              </span>
            ) : null}
          </div>
        )}>{t.title}</PageTitle>
        <p className="-mt-2 mb-6 max-w-4xl text-small text-p4a-muted">
          {t.intro}{" "}
          <Link href={flashPayments as Route} className="font-semibold text-p4a-deepblue underline-offset-2 hover:underline print:hidden" data-testid="payments-open-flash">{t.openFlash}</Link>
        </p>

        <div className="mb-6 print:hidden">
          <SubscriptionsFilters filter={filter} from={doc.from} to={doc.to} markets={doc.filters.markets} stores={doc.filters.stores}
            propositions={doc.filters.propositions} intervals={doc.filters.intervals} months={months} keep={keep} path={PAYMENTS_PATH}
            t={{
              filtersLabel: s.filtersLabel, marketFilter: s.marketFilter, allMarkets: s.allMarkets, unknownMarket: s.unknownMarket, storeFilter: s.storeFilter,
              allStores: s.allStores, propositionFilter: s.propositionFilter, allPropositions: s.allPropositions, noProposition: s.noProposition,
              intervalFilter: s.intervalFilter, allIntervals: s.allIntervals, interval_monthly: s.interval_monthly, interval_quarterly: s.interval_quarterly,
              interval_yearly: s.interval_yearly, interval_other: s.interval_other, interval_unknown: s.interval_unknown, fromLabel: s.fromLabel, toLabel: s.toLabel,
            }} />
        </div>
        {problem ? <div className="mb-6"><Notice tone="warning">{s.filterIgnored}</Notice></div> : null}

        {!doc.history ? <div className="mb-6" data-testid="payments-preparing"><Notice tone="info">{s.preparing}</Notice></div> : (
          <div className="flex flex-col gap-6">
            <PaymentsTiles page={doc} t={t} s={s} copy={copy} locale={locale} href={href} />
            {filter.proposition !== null || filter.interval !== null ? <Note testId="payments-pi-note">{t.piNote}</Note> : null}

            <Card>
              <SectionTitle label={t.ratesTitle} hint={t.h_rates} copy={copy} />
              <FailedRates page={doc} t={t} s={s} locale={locale} />
            </Card>

            <div className="grid grid-cols-1 gap-6 xl:grid-cols-2">
              <Card>
                <SectionTitle label={t.crossTitle} hint={t.h_cross} copy={copy} />
                <PaymentsCross page={doc} t={t} s={s} locale={locale} />
              </Card>
              <PendingPart title={t.flowsTitle} fedBy={t.flowsFedBy} t={s} copy={copy} testId="payments-flows" />
            </div>

            <Card>
              <SectionTitle label={t.listTitle} hint={t.h_list} copy={copy} />
              {doc.list ? <PaymentList list={doc.list} state={state} sort={sort} descending={descending} href={href} t={t} s={s} locale={locale}
                timeZone={doc.timeZone || me.timeZone} /> : null}
            </Card>
          </div>
        )}
        {dataIsMock ? <div className="mt-6"><Notice tone="info">{copy.shell.testData}</Notice></div> : null}
        {dbTrace ? <meta name="cma-db" content={dbTrace} /> : null}
      </div>
    </Shell>
  );
}
