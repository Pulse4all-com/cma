/**
 * Customers → Payments (addition 0009zy; Martin, 25 November 2026): the payment state of the subscription base over months
 * and what is at risk, built on Customers → Subscriptions' payment parts (its Failed rate, its mix by payment state and
 * payment instrument, its list's Payment state column) and its components (SubscriptionsReport: SectionTitle, Switch,
 * Tile, Scroll, Note, the chart's LineChart and Legend). One read from the subscription facts' stored takes
 * (cma.payments_page: the tiles, the months, the rates, the stores' starts, the cross table and the list's first page); a
 * further page of the list is its own read (cma.payment_rows). Server components, plain SVG and CSS, Pulse4all-Style
 * 7.3 (cards), 7.6 (tables: numbers right-aligned in tabular figures, every header with its hint, the header row on top of
 * its scroll container) and 7.7 (charts: every mark with a title naming its value, the table beside the chart holding
 * the same figures). Team figures only; ids, codes, counts, months, amounts and links only: never a customer's name,
 * email, phone or address.
 */
import Link from "next/link";
import { Legend, LineChart, type LineSeries } from "@/components/ActiveCharts";
import { LinkMark } from "@/components/ActivePending";
import { fmtAmount } from "@/components/FlashParts";
import { RecordLink } from "@/components/RecordLink";
import { fmtRate, monthName, Scroll, Switch, Tile, type SubscriptionsHref } from "@/components/SubscriptionsReport";
import { monthLabel } from "@/lib/active";
import type { Copy, Locale, PaymentsCopy, SubscriptionsCopy } from "@/lib/copy";
import type { PaymentRowsPage, PaymentsListState, PaymentsPage, PaymentsSort, PaymentState } from "@/lib/data";
import { failedRateOf, PAYMENT_STATES, PAYMENTS_LIST_STATES, PAYMENTS_PAGE_ROWS } from "@/lib/payments";
import { fmtCount, fmtShare } from "@/lib/reports";
import { fmtDate, fmtDateTimeShort } from "@/lib/time";

type T = PaymentsCopy;
type S = SubscriptionsCopy;

const th = "h-10 px-2 py-1 align-bottom font-semibold leading-tight";
const td = "h-10 whitespace-nowrap px-2";
const tdN = "h-10 whitespace-nowrap px-2 tabular text-right";
const row = "border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50";
const link = "font-semibold text-p4a-deepblue underline-offset-2 hover:underline";

/** A payment state in the page's words (Subscriptions' own: pay_*) */
export const payWord = (state: string, s: S): string => (s as Record<string, string>)[`pay_${state}`] ?? state;
const statusWord = (status: string, s: S) => (s as Record<string, string>)[`status_${status.replace(/-/g, "_")}`] ?? status;
const instrumentWord = (code: string, s: S) => (code === "unknown" ? s.unknown : code);
const listStateWord = (v: PaymentsListState, t: T, s: S) => (v === "at_risk" ? t.state_at_risk : v === "all" ? t.state_all : payWord(v, s));

/**
 * The seven tiles: each of the five payment states with its share of the page's base (a link to the list of that state;
 * Awaiting payment with its overdue), the Amount at risk per currency with its subscriptions and the indicative euros, and
 * the last complete month's Failed rate (Subscriptions' own figure)
 */
export function PaymentsTiles({ page, t, s, copy, locale, href }: { page: PaymentsPage; t: T; s: S; copy: Copy; locale: Locale; href: SubscriptionsHref }) {
  const tiles = page.tiles;
  if (!tiles) return null;
  const rates = tiles.rates;
  const failed = failedRateOf(rates);
  return (
    <div role="group" aria-label={s.tilesLabel} className="grid grid-cols-2 gap-4 md:grid-cols-4 2xl:grid-cols-7" data-testid="payments-tiles">
      {tiles.byState.map((b) => {
        const word = payWord(b.key, s);
        const share = tiles.total > 0 ? fmtShare(b.subscriptions / tiles.total, locale) : "–";
        const hint = t.h_state.replace("{state}", word) + (b.key === "awaiting_payment" ? ` ${t.h_awaiting}` : "");
        return (
          <Tile key={b.key} testId={`payments-tile-${b.key}`} label={word} hint={hint} copy={copy} value={fmtCount(b.subscriptions, locale)}>
            <span>{t.stateShare.replace("{share}", share).replace("{total}", fmtCount(tiles.total, locale))}</span>
            {b.key === "awaiting_payment" && tiles.overdue > 0 ? <span data-testid="payments-tile-overdue">{t.overdueLine.replace("{n}", fmtCount(tiles.overdue, locale))}</span> : null}
            {b.subscriptions > 0 ? (
              <Link href={href({ state: b.key, page: null })} prefetch={false} scroll={false} className={link} data-testid={`payments-tile-${b.key}-list`}>
                {t.openState}<LinkMark />
              </Link>
            ) : null}
          </Tile>
        );
      })}
      <Tile testId="payments-tile-at-risk" label={t.tile_atRisk} hint={t.h_atRisk} copy={copy}
        value={tiles.atRisk.amounts.length === 0 ? <span className="text-p4a-muted">{t.noAtRisk}</span> : (
          <span className="flex flex-col text-panel">
            {tiles.atRisk.amounts.map((a) => <span key={a.currency} data-currency={a.currency}>{fmtAmount(a.amount, a.currency, locale)}</span>)}
          </span>
        )}>
        {tiles.atRisk.subscriptions > 0 ? (
          <span>{tiles.atRisk.subscriptions === 1 ? t.atRiskOne : t.atRiskLine.replace("{n}", fmtCount(tiles.atRisk.subscriptions, locale))}</span>
        ) : null}
        {tiles.atRisk.eur ? (
          <span data-testid="payments-tile-eur">
            {s.eurLine.replace("{amount}", fmtAmount(tiles.atRisk.eur.amount, "EUR", locale)).replace("{date}", tiles.atRisk.eur.asOf ? fmtDate(tiles.atRisk.eur.asOf, locale, "medium") : "–")}
          </span>
        ) : null}
      </Tile>
      <Tile testId="payments-tile-failed" label={s.tile_failed} hint={t.h_failedRate} copy={copy}
        value={rates ? fmtRate(failed, locale) : <span className="text-p4a-muted">{s.noCompleteMonth}</span>}>
        {rates ? <span>{s.failedLine.replace("{n}", fmtCount(rates.movedToFailed, locale)).replace("{month}", monthName(rates.month, locale))}</span> : null}
      </Tile>
    </div>
  );
}

/**
 * Failed rate by month: one line per market (each store's start month marked), and the table beside it with the base and
 * the moved-to-failed count per market and complete month; Subscriptions' Rates without the Churn rate, read from the
 * same month take
 */
export function FailedRates({ page, t, s, locale }: { page: PaymentsPage; t: T; s: S; locale: Locale }) {
  const months = page.months.map((m) => m.month);
  const markets = [...new Set(page.rates.map((r) => r.market))].sort();
  const pct = (v: number) => fmtRate(v, locale);
  const series: LineSeries[] = markets.map((mk, i) => ({
    key: `${mk}-failed`, label: `${mk} ${s.failedRate}`, colour: i,
    points: page.rates.filter((r) => r.market === mk).flatMap((r) => {
      const x = months.indexOf(r.month);
      const v = failedRateOf(r);
      return x < 0 || v === null ? [] : [{ x, y: v, title: `${monthName(r.month, locale)}: ${pct(v)}` }];
    }),
  }));
  const highest = Math.max(0, ...series.flatMap((x) => x.points.map((p) => p.y)));
  const top = [0.02, 0.04, 0.08, 0.1, 0.2, 0.4, 0.8, 1].find((v) => v >= highest) ?? 1;
  const markers = page.storeStarts.flatMap((x) => {
    const i = months.indexOf(x.rateStartMonth);
    return i < 0 ? [] : [{ x: i, title: s.rateStartLine.replace("{store}", x.handle ?? "").replace("{market}", x.market)
      .replace("{first}", monthName(x.firstEventMonth, locale)).replace("{start}", monthName(x.rateStartMonth, locale)) }];
  });
  return (
    <div className="flex flex-col gap-4">
      {page.rates.length === 0 ? <p className="text-body text-p4a-muted" data-testid="payments-rates-none">{s.ratesNone}</p> : (
        <>
          <Legend label={t.ratesChartLabel} items={series.map((x) => ({ key: x.key, label: x.label, colour: x.colour ?? 0 }))} />
          <LineChart series={series} xLabels={months.map((m, x) => ({ x, text: monthLabel(m, locale, x === 0 || m.slice(5, 7) === "01") }))}
            yFormat={pct} yTop={top} yLabel={s.shareAxis} label={t.ratesChartLabel} testId="payments-rates-chart" markers={markers} />
          <Scroll testId="payments-rates" label={t.ratesTitle} numbers>
            <thead>
              <tr>
                <th scope="col" rowSpan={2} className={`${th} text-left`}>{s.monthCol}</th>
                {markets.map((mk) => <th key={mk} scope="colgroup" colSpan={3} className={`${th} border-l border-p4a-border text-center`}>{mk}</th>)}
              </tr>
              <tr>
                {markets.flatMap((mk) => [
                  <th key={`${mk}-b`} scope="col" className={`${th} border-l border-p4a-border text-right`}>{s.baseCol}</th>,
                  <th key={`${mk}-n`} scope="col" className={`${th} text-right`}>{s.failedCol}</th>,
                  <th key={`${mk}-f`} scope="col" className={`${th} text-right`}>{s.failedRate}</th>,
                ])}
              </tr>
            </thead>
            <tbody>
              {months.filter((m) => page.rates.some((r) => r.month === m)).map((m) => (
                <tr key={m} className={row}>
                  <th scope="row" className="h-10 whitespace-nowrap px-2 text-left font-normal tabular">{monthName(m, locale)}</th>
                  {markets.flatMap((mk) => {
                    const r = page.rates.find((x) => x.market === mk && x.month === m);
                    if (!r) return [<td key={`${mk}-b`} className="border-l border-p4a-border text-p4a-muted">–</td>, <td key={`${mk}-n`} className="text-p4a-muted">–</td>, <td key={`${mk}-f`} className="text-p4a-muted">–</td>];
                    return [
                      <td key={`${mk}-b`} className="border-l border-p4a-border">{r.base === null ? "–" : fmtCount(r.base, locale)}</td>,
                      <td key={`${mk}-n`}>{fmtCount(r.movedToFailed, locale)}</td>,
                      <td key={`${mk}-f`}>{fmtRate(failedRateOf(r), locale)}</td>,
                    ];
                  })}
                </tr>
              ))}
            </tbody>
          </Scroll>
        </>
      )}
      {page.storeStarts.length > 0 ? (
        <div data-testid="payments-store-starts">
          <h3 className="mb-2 text-body font-semibold text-p4a-heading">{s.rateStarts}</h3>
          {page.ratesStartMonth ? (
            <p className="mb-1 text-small text-p4a-muted">{s.ratesFloorLine.replace("{start}", monthName(page.ratesStartMonth, locale))}</p>
          ) : null}
          <ul className="flex flex-col gap-1 text-small text-p4a-muted">
            {page.storeStarts.map((x) => (
              <li key={x.connectionId}>
                {s.rateStartLine.replace("{store}", x.handle ?? "").replace("{market}", x.market).replace("{first}", monthName(x.firstEventMonth, locale))
                  .replace("{start}", monthName(x.rateStartMonth, locale))}
              </li>
            ))}
          </ul>
        </div>
      ) : null}
    </div>
  );
}

/** Payment state by payment instrument: states down (the five, in their order), instruments across (the most used first), totals on both sides */
export function PaymentsCross({ page, t, s, locale }: { page: PaymentsPage; t: T; s: S; locale: Locale }) {
  const cells = page.cross ?? [];
  if (cells.length === 0) return <p className="text-body text-p4a-muted" data-testid="payments-cross-none">{s.noRows}</p>;
  const byInstrument = new Map<string, number>();
  for (const c of cells) byInstrument.set(c.instrument, (byInstrument.get(c.instrument) ?? 0) + c.subscriptions);
  const instruments = [...byInstrument.entries()]
    .sort(([a, na], [b, nb]) => (a === "unknown" ? 1 : 0) - (b === "unknown" ? 1 : 0) || nb - na || (a < b ? -1 : a > b ? 1 : 0)).map(([k]) => k);
  const states = PAYMENT_STATES.filter((st) => cells.some((c) => c.state === st));
  const cell = (st: PaymentState, ins: string) => cells.find((c) => c.state === st && c.instrument === ins)?.subscriptions ?? 0;
  const total = cells.reduce((n, c) => n + c.subscriptions, 0);
  return (
    <Scroll testId="payments-cross" label={t.crossTitle} numbers>
      <thead>
        <tr>
          <th scope="col" className={`${th} text-left`}>{t.stateCol}</th>
          {instruments.map((ins) => <th key={ins} scope="col" className={`${th} text-right`}>{instrumentWord(ins, s)}</th>)}
          <th scope="col" className={`${th} border-l border-p4a-border text-right`}>{t.totalCol}</th>
        </tr>
      </thead>
      <tbody>
        {states.map((st) => {
          const n = instruments.reduce((x, ins) => x + cell(st, ins), 0);
          return (
            <tr key={st} className={row} data-state={st}>
              <th scope="row" className="h-10 whitespace-nowrap px-2 text-left font-normal">{payWord(st, s)}</th>
              {instruments.map((ins) => {
                const v = cell(st, ins);
                return <td key={ins} title={`${payWord(st, s)}, ${instrumentWord(ins, s)}: ${fmtCount(v, locale)}`} className={v === 0 ? "text-p4a-muted" : undefined}>{fmtCount(v, locale)}</td>;
              })}
              <td className="border-l border-p4a-border font-semibold">{fmtCount(n, locale)}</td>
            </tr>
          );
        })}
        <tr className="border-b border-p4a-border bg-p4a-bgblue/40">
          <th scope="row" className="h-10 whitespace-nowrap px-2 text-left font-semibold">{t.totalCol}</th>
          {instruments.map((ins) => <td key={ins} className="font-semibold">{fmtCount(byInstrument.get(ins) ?? 0, locale)}</td>)}
          <td className="border-l border-p4a-border font-semibold">{fmtCount(total, locale)}</td>
        </tr>
      </tbody>
    </Scroll>
  );
}

const SORT_COLUMNS: { sort: PaymentsSort | null; col: string; words: "t" | "s"; right?: boolean }[] = [
  { sort: "subscription", col: "col_subscription", words: "s" }, { sort: null, col: "col_number", words: "s" }, { sort: null, col: "col_store", words: "s" },
  { sort: "market", col: "col_market", words: "s" }, { sort: null, col: "col_status", words: "s" }, { sort: "payment_state", col: "col_payment_state", words: "s" },
  { sort: "state_since", col: "col_since", words: "t" }, { sort: null, col: "col_overdue", words: "t" }, { sort: null, col: "col_return_code", words: "t" },
  { sort: null, col: "col_instrument", words: "t" }, { sort: "amount_at_risk", col: "col_amount_at_risk", words: "t", right: true },
  { sort: null, col: "col_monthly_amount", words: "s", right: true }, { sort: null, col: "col_contact", words: "s" },
];

/**
 * The list: one row per subscription of the chosen state (at risk by default), sorted on a whitelist by its column's
 * header, 50 a page. The app's id and number, codes, since when it holds its payment state, the return code, the amounts
 * in their currency and the contact's link; never a name or an email
 */
export function PaymentList({ list, state, sort, descending, href, t, s, locale, timeZone }: {
  list: PaymentRowsPage; state: PaymentsListState; sort: PaymentsSort; descending: boolean; href: SubscriptionsHref; t: T; s: S; locale: Locale; timeZone: string;
}) {
  const pages = Math.max(1, Math.ceil(list.total / PAYMENTS_PAGE_ROWS));
  return (
    <div className="flex flex-col gap-4" data-testid="payments-list">
      <Switch label={s.measureLabel} testId="payments-state" current={state}
        options={PAYMENTS_LIST_STATES.map((v) => ({ value: v, label: listStateWord(v, t, s) }))}
        href={(v) => href({ state: v === "at_risk" ? null : v, page: null })} />
      <p className="text-caption text-p4a-grey" data-testid="payments-list-count">
        {s.listOf.replace("{shown}", fmtCount(list.rows.length, locale)).replace("{total}", fmtCount(list.total, locale))}
      </p>
      {list.rows.length === 0 ? <p className="text-body text-p4a-muted" data-testid="payments-list-empty">{t.noRows}</p> : (
        <Scroll testId="payments-rows" label={t.listTitle}>
          <thead>
            <tr>
              {SORT_COLUMNS.map((c) => {
                const label = (c.words === "t" ? (t as Record<string, string>)[c.col] : (s as Record<string, string>)[c.col]) ?? c.col;
                const active = c.sort !== null && c.sort === sort;
                return (
                  <th key={c.col} scope="col" className={`${th} ${c.right ? "text-right" : "text-left"}`} aria-sort={active ? (descending ? "descending" : "ascending") : undefined}>
                    {c.sort ? (
                      <Link href={href({ sort: c.sort === "amount_at_risk" ? null : c.sort, dir: active && descending ? "asc" : "desc", page: null })}
                        prefetch={false} scroll={false} className="text-p4a-deepblue underline-offset-2 hover:underline" title={s.sortBy.replace("{column}", label)}>
                        {label}{active ? (descending ? " ↓" : " ↑") : ""}<LinkMark />
                      </Link>
                    ) : label}
                  </th>
                );
              })}
            </tr>
          </thead>
          <tbody>
            {list.rows.map((r) => (
              <tr key={r.subscriptionId} className={row} data-testid="payments-row" data-state={r.paymentState}>
                <td className={`${td} tabular`}>{r.sourceId}</td>
                <td className={`${td} tabular`}>{r.number ?? "–"}</td>
                <td className={td}>{r.store ?? "–"}</td>
                <td className={td}>{r.market}</td>
                <td className={td}>{statusWord(r.status, s)}</td>
                <td className={td}>{payWord(r.paymentState, s)}</td>
                <td className={`${td} tabular`}>{r.stateSince ? fmtDateTimeShort(r.stateSince, timeZone, locale) : "–"}</td>
                <td className={td}>{r.overdue === null ? "–" : r.overdue ? t.yes : t.no}</td>
                <td className={`${td} tabular`}>{r.returnCode ?? "–"}</td>
                <td className={td}>{r.instrument ?? s.unknown}</td>
                <td className={tdN}>{r.amountAtRisk === null || r.currency === null ? "–" : fmtAmount(r.amountAtRisk, r.currency, locale)}</td>
                <td className={tdN}>{r.monthlyAmount === null || r.currency === null ? "–" : fmtAmount(r.monthlyAmount, r.currency, locale)}</td>
                <td className="h-10 px-2"><RecordLink url={r.contactUrl} label={s.openContact} /></td>
              </tr>
            ))}
          </tbody>
        </Scroll>
      )}
      {pages > 1 ? (
        <nav className="flex items-center justify-between gap-2 text-small" aria-label={s.pageOf.replace("{page}", String(list.page)).replace("{pages}", String(pages))}>
          {list.page > 1 ? (
            <Link href={href({ page: list.page - 1 === 1 ? null : String(list.page - 1) })} prefetch={false} scroll={false} data-testid="payments-previous"
              className="inline-flex h-10 items-center rounded-button border border-p4a-deepblue bg-white px-4 font-semibold text-p4a-deepblue">{s.previous}<LinkMark /></Link>
          ) : <span />}
          <span className="text-p4a-muted">{s.pageOf.replace("{page}", fmtCount(list.page, locale)).replace("{pages}", fmtCount(pages, locale))}</span>
          {list.page < pages ? (
            <Link href={href({ page: String(list.page + 1) })} prefetch={false} scroll={false} data-testid="payments-next"
              className="inline-flex h-10 items-center rounded-button border border-p4a-deepblue bg-white px-4 font-semibold text-p4a-deepblue">{s.next}<LinkMark /></Link>
          ) : <span />}
        </nav>
      ) : null}
    </div>
  );
}

/** Refreshed at: the take's moment in the tenant's zone */
export function PaymentsRefreshed({ page, s, locale }: { page: PaymentsPage; s: S; locale: Locale }) {
  if (!page.take) return null;
  return <span data-testid="payments-refreshed">{s.refreshedAt.replace("{time}", fmtDateTimeShort(page.take.computedAt, page.timeZone, locale))}</span>;
}
