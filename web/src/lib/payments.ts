/**
 * Customers → Payments (addition 0009zw; docs/definitions.md, Payment state, Amount at risk, Payments (rail page)): the
 * pure logic of the page. The database computes every figure from the subscription facts' stored takes
 * (cma.payments_page, cma.payment_rows); this module holds what the screen, the API's parameter checks, the file, the
 * mock and verify:payments share: the list's states and sort keys, the file's columns and name and the database's
 * answer in the API's words. The filters and the month range are Customers → Subscriptions' own (lib/subscriptions). No
 * runtime imports beyond types and lib/subscriptions: server and client components alike use it.
 */
import type {
  DateKey, PaymentRow, PaymentRowsList, PaymentRowsPage, PaymentsListState, PaymentsPage, PaymentsRateParts, PaymentsSort, PaymentState,
  SubscriptionsFilter, SubscriptionsInterval,
} from "@/lib/data";
import { SUBSCRIPTIONS_INTERVALS } from "@/lib/subscriptions";

export const PAYMENTS_PATH = "/reports/payments";
/** The five payment states on the page, in cma.payment_states()'s order (Paused and Canceled are not on it) */
export const PAYMENT_STATES: readonly PaymentState[] = ["paid", "in_retry", "charged_back", "awaiting_payment", "failed"];
/** The list's states: at_risk first and the default, then each payment state, then all */
export const PAYMENTS_LIST_STATES: readonly PaymentsListState[] = ["at_risk", "in_retry", "charged_back", "awaiting_payment", "failed", "paid", "all"];
/** The list's sort keys, the first the default (descending) */
export const PAYMENTS_SORTS: readonly PaymentsSort[] = ["amount_at_risk", "state_since", "subscription", "market", "payment_state"];
/** Rows a page of the list shows */
export const PAYMENTS_PAGE_ROWS = 50;

export function listStateOf(value: unknown): PaymentsListState | null {
  return typeof value === "string" && (PAYMENTS_LIST_STATES as readonly string[]).includes(value) ? (value as PaymentsListState) : null;
}

export function paymentsSortOf(value: unknown): PaymentsSort | null {
  return typeof value === "string" && (PAYMENTS_SORTS as readonly string[]).includes(value) ? (value as PaymentsSort) : null;
}

/** The Failed rate of a month's parts: null without a base (never a zero) */
export function failedRateOf(parts: PaymentsRateParts | null): number | null {
  if (!parts || parts.base === null || parts.base <= 0) return null;
  return parts.movedToFailed / parts.base;
}

/** The file's columns: ids, codes, times and amounts only, as the list's; the contact's id, never its link */
export const PAYMENTS_FILE_COLUMNS = [
  "source_id", "number", "store", "market", "status", "payment_state", "state_since", "overdue", "return_code", "instrument", "amount_at_risk",
  "monthly_amount", "currency", "contact_id",
] as const;
/** The months file's columns: per month the complete stores' Failed rate parts */
export const PAYMENTS_MONTHS_COLUMNS = ["month", "rate_base", "rate_moved_to_failed"] as const;

/** The file's name: payments-<part>-<market|all>[-<interval>][-<proposition>]-<YYYY-MM-DDTHHmm>.csv */
export function paymentsFileName(part: "records" | "months", filter: SubscriptionsFilter, stamp: string): string {
  const clean = (v: string | null) => (v ?? "all").toLowerCase().replace(/[^a-z0-9_-]/g, "");
  return `payments-${part}-${clean(filter.market)}${filter.interval ? `-${filter.interval}` : ""}${filter.proposition ? `-${clean(filter.proposition)}` : ""}-${stamp}.csv`;
}

// ---- the database's document in the API's words -------------------------------------------------------------------------

type J = Record<string, unknown>;
const num = (v: unknown): number => (v === null || v === undefined ? 0 : Number(v));
const numOrNull = (v: unknown): number | null => (v === null || v === undefined ? null : Number(v));
const str = (v: unknown): string | null => (v === null || v === undefined ? null : String(v));
const day = (v: unknown): DateKey | null => (v === null || v === undefined ? null : String(v).slice(0, 10));
const arr = (v: unknown): J[] => (Array.isArray(v) ? (v as J[]) : []);
const strings = (v: unknown) => (Array.isArray(v) ? (v as unknown[]).map(String) : []);

function partsOf(v: unknown): PaymentsRateParts | null {
  if (!v || typeof v !== "object") return null;
  const o = v as J;
  return { base: numOrNull(o.base), movedToFailed: num(o.moved_to_failed) };
}

export function paymentRowFromDb(r: J): PaymentRow {
  return {
    subscriptionId: String(r.subscription_id), sourceId: String(r.source_id), number: str(r.number), store: str(r.store), market: String(r.market ?? "unknown"),
    status: String(r.status), paymentState: String(r.payment_state) as PaymentState, stateSince: str(r.state_since),
    overdue: r.overdue === null || r.overdue === undefined ? null : r.overdue === true, returnCode: str(r.return_code), instrument: str(r.instrument),
    currency: str(r.currency), amountAtRisk: numOrNull(r.amount_at_risk), monthlyAmount: numOrNull(r.monthly_amount),
    contactId: str(r.contact_id), contactUrl: str(r.contact_url),
  };
}

export function paymentRowsPageFromDb(j: J): PaymentRowsPage {
  return {
    page: num(j.page ?? 1), pageSize: num(j.page_size ?? PAYMENTS_PAGE_ROWS), total: num(j.total), state: (str(j.state) ?? "at_risk") as PaymentsListState,
    sort: (str(j.sort) ?? "amount_at_risk") as PaymentsSort, descending: j.descending !== false, rows: arr(j.rows).map(paymentRowFromDb),
  };
}

export function paymentRowsFromDb(j: J): PaymentRowsList {
  if (j.set_up === false) {
    return { setUp: false, history: false, timeZone: "", computedAt: null, page: 1, pageSize: PAYMENTS_PAGE_ROWS, total: 0, state: "at_risk", sort: "amount_at_risk", descending: true, rows: [] };
  }
  return { setUp: true, history: j.history === true, timeZone: String(j.time_zone ?? ""), computedAt: str(j.computed_at), ...paymentRowsPageFromDb(j) };
}

export function paymentsPageFromDb(j: J, query: { from: DateKey; to: DateKey; filter: SubscriptionsFilter }): PaymentsPage {
  if (j.set_up === false) {
    return {
      setUp: false, history: false, take: null, timeZone: "", today: "", month: "", from: query.from, to: query.to, filter: query.filter,
      settings: { states: [...PAYMENT_STATES], fx: null, propositions: [], historyMonths: 60 },
      filters: { markets: [], stores: [], propositions: [], intervals: [...SUBSCRIPTIONS_INTERVALS] }, tiles: null, months: [], rates: [], storeStarts: [],
      ratesStartMonth: null, cross: null, list: null,
    };
  }
  const take = j.take as J | null;
  const settings = (j.settings ?? {}) as J;
  const filters = (j.filters ?? {}) as J;
  const tiles = j.tiles as J | null;
  const atRisk = (tiles?.at_risk ?? {}) as J;
  return {
    setUp: true, history: j.history === true,
    take: take ? { computedAt: String(take.computed_at), businessDate: String(take.business_date).slice(0, 10) } : null,
    timeZone: String(j.time_zone ?? ""), today: day(j.today) ?? "", month: day(j.month) ?? "", from: day(j.from) ?? query.from, to: day(j.to) ?? query.to,
    filter: query.filter,
    settings: {
      states: strings(settings.states) as PaymentState[], fx: (settings.fx as Record<string, unknown> | null) ?? null, propositions: strings(settings.propositions),
      historyMonths: num(settings.history_months ?? 60),
    },
    filters: {
      markets: strings(filters.markets),
      stores: arr(filters.stores).map((s) => ({ connectionId: String(s.connection_id), handle: String(s.handle ?? ""), market: String(s.market ?? "unknown") })),
      propositions: strings(filters.propositions), intervals: strings(filters.intervals) as SubscriptionsInterval[],
    },
    tiles: tiles ? {
      total: num(tiles.total),
      byState: arr(tiles.by_state).map((b) => ({ key: String(b.key) as PaymentState, subscriptions: num(b.subscriptions) })),
      overdue: num(tiles.overdue),
      atRisk: {
        subscriptions: num(atRisk.subscriptions),
        amounts: arr(atRisk.amounts).map((a) => ({ currency: String(a.currency), amount: num(a.amount), subscriptions: num(a.subscriptions) })),
        eur: atRisk.eur ? { amount: num((atRisk.eur as J).amount), asOf: str((atRisk.eur as J).as_of) } : null,
      },
      rates: tiles.rates ? { month: String((tiles.rates as J).month).slice(0, 10), ...partsOf(tiles.rates)! } : null,
    } : null,
    months: arr(j.months).map((m) => ({ month: String(m.month).slice(0, 10), complete: partsOf(m.complete) })),
    rates: arr(j.rates).map((r) => ({ market: String(r.market), month: String(r.month).slice(0, 10), ...partsOf(r)! })),
    storeStarts: arr(j.store_starts).map((s) => ({ connectionId: String(s.connection_id), handle: str(s.handle), market: String(s.market),
      firstEventMonth: String(s.first_event_month).slice(0, 10), rateStartMonth: String(s.rate_start_month).slice(0, 10), stragglers: num(s.stragglers) })),
    ratesStartMonth: typeof j.rates_start_month === "string" ? j.rates_start_month.slice(0, 10) : null,
    cross: Array.isArray(j.cross)
      ? arr(j.cross).map((c) => ({ state: String(c.state) as PaymentState, instrument: String(c.instrument), subscriptions: num(c.subscriptions) }))
      : null,
    list: j.list ? paymentRowsPageFromDb(j.list as J) : null,
  };
}
