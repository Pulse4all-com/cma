/**
 * Customers → Subscriptions (addition 0009zh, brief B39 continued, Part B39d; docs/definitions.md, Subscription terms):
 * the pure logic of the page. The database computes every figure from the subscription facts' stored takes
 * (cma.subscriptions_page, cma.subscription_rows); this module holds what the screen, the API's parameter checks, the
 * file, the mock and verify:subscriptions share: the address keys and their parsing, the default month range, the list's
 * measures and sort keys, the file's columns and name, the rates' arithmetic and the database's answer in the API's
 * words. No runtime imports beyond types: server and client components alike use it.
 */
import type {
  DateKey, SubscriptionMoveKind, SubscriptionRow, SubscriptionRowsList, SubscriptionRowsPage, SubscriptionsChurnCard, SubscriptionsFilter,
  SubscriptionsInterval, SubscriptionsMeasure, SubscriptionsPage, SubscriptionsRateParts, SubscriptionsSort, SubscriptionsSourceCounts,
} from "@/lib/data";

export const SUBSCRIPTIONS_PATH = "/reports/subscriptions";
/** The page's address keys (D.1): the four filters, the month range, the movements' view, and the list's measure, sort, direction and page */
export const SUBSCRIPTIONS_ADDRESS = {
  market: "market", store: "store", proposition: "proposition", interval: "interval", from: "from", to: "to", view: "view",
  measure: "measure", sort: "sort", dir: "dir", page: "page",
} as const;
export const SUBSCRIPTIONS_INTERVALS: readonly SubscriptionsInterval[] = ["monthly", "quarterly", "yearly", "other", "unknown"];
/** The list's measures, the tiles' populations; total (the Total subscriptions) first and the default */
export const SUBSCRIPTIONS_MEASURES: readonly SubscriptionsMeasure[] = ["total", "active", "failed", "paused", "unmapped", "all"];
/** The list's sort keys, the first the default (descending) */
export const SUBSCRIPTIONS_SORTS: readonly SubscriptionsSort[] = [
  "monthly_amount", "subscription", "market", "status", "payment_state", "interval", "device_units",
];
/** The movements' view: counts, or the monthly amounts per currency */
export const SUBSCRIPTIONS_VIEWS = ["counts", "amounts"] as const;
export type SubscriptionsView = (typeof SUBSCRIPTIONS_VIEWS)[number];
/** Rows a page of the list shows */
export const SUBSCRIPTIONS_PAGE_ROWS = 50;
/** The default range: the last twelve complete months and the current one */
export const SUBSCRIPTIONS_DEFAULT_MONTHS = 13;
/**
 * The most months an address may ask for: customers.history_months' largest value (120) complete months and the current
 * one. The tenant's own limit (customers.history_months complete months and the current one) is the database's to apply
 * (CMA04), and the page offers only the months it allows
 */
export const SUBSCRIPTIONS_MAX_MONTHS = 121;
/** The movement kinds in the bridge's order: the start, what adds, what moves out, the end (C.4) */
export const SUBSCRIPTIONS_BRIDGE: readonly SubscriptionMoveKind[] = [
  "start", "new", "migrated", "reactivated", "resumed", "paused", "churned", "moved_to_failed", "end",
];
/** The amount movements beside the status moves: the monthly amount rose or fell without one */
export const SUBSCRIPTIONS_AMOUNT_KINDS: readonly SubscriptionMoveKind[] = ["expansion", "contraction"];
/** The kinds that reduce the base (shown with a minus sign) */
export const SUBSCRIPTIONS_OUTFLOW: ReadonlySet<SubscriptionMoveKind> = new Set(["paused", "churned", "moved_to_failed", "contraction"]);
/** The mix's breakdowns, in the page's order */
export const SUBSCRIPTIONS_MIX = ["proposition", "model", "interval", "deviceBand", "ageBand", "instrument", "paymentState"] as const;
export type SubscriptionsMixKey = (typeof SUBSCRIPTIONS_MIX)[number];

const MARKET = /^([A-Z]{2}|unknown)$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const PROPOSITION = /^[a-z][a-z0-9_]{0,39}$/;
const MONTH = /^(19|2\d)\d{2}-(0[1-9]|1[0-2])$/;

/** A month key (YYYY-MM-01) moved by whole months */
export function addMonths(month: DateKey, n: number): DateKey {
  const y = Number(month.slice(0, 4));
  const m = Number(month.slice(5, 7)) - 1 + n;
  const yy = y + Math.floor(m / 12);
  const mm = ((m % 12) + 12) % 12;
  return `${String(yy).padStart(4, "0")}-${String(mm + 1).padStart(2, "0")}-01`;
}

/** The months from one month key to another, both included */
export function monthsBetween(from: DateKey, to: DateKey): DateKey[] {
  const out: DateKey[] = [];
  for (let m = from; m <= to && out.length < 1200; m = addMonths(m, 1)) out.push(m);
  return out;
}

/** The current month key in a time zone (pure: Intl alone) */
export function currentMonthIn(timeZone: string, now: Date = new Date()): DateKey {
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit" }).formatToParts(now);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "01";
  return `${get("year")}-${get("month")}-01`;
}

/** The month key of a day key */
export function monthOf(day: DateKey): DateKey {
  return `${day.slice(0, 7)}-01`;
}

/** The address's month (YYYY-MM) as a month key, or null when it is not one */
export function monthParam(value: unknown): DateKey | null {
  return typeof value === "string" && MONTH.test(value) ? `${value}-01` : null;
}

/** A month key as the address writes it (YYYY-MM) */
export function monthAddress(month: DateKey): string {
  return month.slice(0, 7);
}

/**
 * The filters and the range from an address (or an API query), with what was ignored: a market code or unknown, a store's
 * id, a proposition's code or none, an interval group; from and to as YYYY-MM, kept within the current month and the most
 * months a range may span, from at most to; left out: the last twelve complete months and the current one
 */
export function parseSubscriptionsFilter(get: (key: string) => unknown, currentMonth: DateKey, maxMonths = SUBSCRIPTIONS_MAX_MONTHS): {
  filter: SubscriptionsFilter; from: DateKey; to: DateKey; problem: null | "market" | "store" | "proposition" | "interval" | "from" | "to" | "range";
} {
  const one = (k: string) => { const v = get(k); return typeof v === "string" && v !== "" ? v : null; };
  const m = one(SUBSCRIPTIONS_ADDRESS.market);
  const s = one(SUBSCRIPTIONS_ADDRESS.store);
  const p = one(SUBSCRIPTIONS_ADDRESS.proposition);
  const i = one(SUBSCRIPTIONS_ADDRESS.interval);
  const f = one(SUBSCRIPTIONS_ADDRESS.from);
  const t = one(SUBSCRIPTIONS_ADDRESS.to);
  const filter: SubscriptionsFilter = {
    market: m !== null && MARKET.test(m) ? m : null,
    store: s !== null && UUID.test(s) ? s : null,
    proposition: p !== null && (p === "none" || PROPOSITION.test(p)) ? p : null,
    interval: i !== null && (SUBSCRIPTIONS_INTERVALS as readonly string[]).includes(i) ? (i as SubscriptionsInterval) : null,
  };
  let to = t === null ? currentMonth : monthParam(t);
  let from = f === null ? null : monthParam(f);
  let problem: ReturnType<typeof parseSubscriptionsFilter>["problem"] =
    m !== null && filter.market === null ? "market" : s !== null && filter.store === null ? "store"
      : p !== null && filter.proposition === null ? "proposition" : i !== null && filter.interval === null ? "interval"
        : f !== null && from === null ? "from" : t !== null && to === null ? "to" : null;
  if (to === null || to > currentMonth) { to = currentMonth; problem = problem ?? "to"; }
  if (from === null) from = addMonths(to, -(SUBSCRIPTIONS_DEFAULT_MONTHS - 1));
  if (from > to) { from = addMonths(to, -(SUBSCRIPTIONS_DEFAULT_MONTHS - 1)); problem = problem ?? "range"; }
  if (monthsBetween(from, to).length > maxMonths) { from = addMonths(to, -(maxMonths - 1)); problem = problem ?? "range"; }
  return { filter, from, to, problem };
}

/** The filters' part of an address: only what is chosen */
export function subscriptionsQuery(filter: SubscriptionsFilter): Record<string, string> {
  return {
    ...(filter.market ? { market: filter.market } : {}), ...(filter.store ? { store: filter.store } : {}),
    ...(filter.proposition ? { proposition: filter.proposition } : {}), ...(filter.interval ? { interval: filter.interval } : {}),
  };
}

export function measureOf(value: unknown): SubscriptionsMeasure | null {
  return typeof value === "string" && (SUBSCRIPTIONS_MEASURES as readonly string[]).includes(value) ? (value as SubscriptionsMeasure) : null;
}

export function sortOf(value: unknown): SubscriptionsSort | null {
  return typeof value === "string" && (SUBSCRIPTIONS_SORTS as readonly string[]).includes(value) ? (value as SubscriptionsSort) : null;
}

/** A share of a base: null without a base (never a zero) */
export function rateOf(part: number, base: number | null): number | null {
  return base === null || base <= 0 ? null : part / base;
}

/** The Churn rate and the Failed rate of a month's parts */
export function ratesOf(parts: SubscriptionsRateParts | null): { churn: number | null; failed: number | null } {
  if (!parts) return { churn: null, failed: null };
  return { churn: rateOf(parts.churned, parts.base), failed: rateOf(parts.movedToFailed, parts.base) };
}

/** The last day of a month key */
export function monthEnd(month: DateKey): DateKey {
  const d = new Date(Date.UTC(Number(month.slice(0, 4)), Number(month.slice(5, 7)), 0));
  return d.toISOString().slice(0, 10);
}

/** The file's columns: ids, codes, dates and amounts only, as the list's; the contact's id, never its link */
export const SUBSCRIPTIONS_FILE_COLUMNS = [
  "source_id", "number", "store", "market", "status", "payment_state", "interval", "monthly_amount", "currency", "device_units", "age_months",
  "propositions", "instrument", "contact_id",
] as const;
/** The months file's columns: per month the counts per kind and the complete stores' rate parts */
export const SUBSCRIPTIONS_MONTHS_COLUMNS = [
  "month", ...SUBSCRIPTIONS_BRIDGE, ...SUBSCRIPTIONS_AMOUNT_KINDS, "rate_base", "rate_churned", "rate_moved_to_failed",
] as const;

/** The file's name: subscriptions-<part>-<market|all>-<YYYY-MM-DDTHHmm>.csv */
export function subscriptionsFileName(part: "records" | "months", filter: SubscriptionsFilter, stamp: string): string {
  const clean = (v: string | null) => (v ?? "all").toLowerCase().replace(/[^a-z0-9_-]/g, "");
  return `subscriptions-${part}-${clean(filter.market)}${filter.interval ? `-${filter.interval}` : ""}${filter.proposition ? `-${clean(filter.proposition)}` : ""}-${stamp}.csv`;
}

// ---- the database's document in the API's words -------------------------------------------------------------------------

type J = Record<string, unknown>;
const num = (v: unknown): number => (v === null || v === undefined ? 0 : Number(v));
const numOrNull = (v: unknown): number | null => (v === null || v === undefined ? null : Number(v));
const str = (v: unknown): string | null => (v === null || v === undefined ? null : String(v));
const day = (v: unknown): DateKey | null => (v === null || v === undefined ? null : String(v).slice(0, 10));
const arr = (v: unknown): J[] => (Array.isArray(v) ? (v as J[]) : []);

function partsOf(v: unknown): SubscriptionsRateParts | null {
  if (!v || typeof v !== "object") return null;
  const o = v as J;
  return { base: numOrNull(o.base), churned: num(o.churned), movedToFailed: num(o.moved_to_failed) };
}

function kindsOf(v: unknown): Partial<Record<SubscriptionMoveKind, number>> | null {
  if (!v || typeof v !== "object") return null;
  return Object.fromEntries(Object.entries(v as J).map(([k, n]) => [k, Number(n)])) as Partial<Record<SubscriptionMoveKind, number>>;
}

/** The subscription app's own counts beside the tiles: null without a figure (never zeros) */
export function sourceCountsFromDb(v: unknown): SubscriptionsSourceCounts | null {
  if (!v || typeof v !== "object") return null;
  const o = v as J;
  return {
    stores: num(o.stores), inScope: num(o.in_scope), from: day(o.from) ?? "", to: day(o.to) ?? "", fetchedAt: str(o.fetched_at),
    total: numOrNull(o.total), totalCma: numOrNull(o.total_cma), totalGaps: numOrNull(o.total_gaps),
    paused: numOrNull(o.paused), pausedCma: numOrNull(o.paused_cma), pausedGaps: numOrNull(o.paused_gaps),
    amounts: arr(o.amounts).map((a) => ({ currency: String(a.currency), amount: num(a.amount), cma: numOrNull(a.cma), stores: num(a.stores), gaps: numOrNull(a.gaps) })),
    tolerancePct: num(o.tolerance_pct), toleranceMin: num(o.tolerance_min),
  };
}

export function subscriptionRowFromDb(r: J): SubscriptionRow {
  return {
    subscriptionId: String(r.subscription_id), sourceId: String(r.source_id), number: str(r.number), store: str(r.store), market: String(r.market ?? "unknown"),
    status: String(r.status), paymentState: str(r.payment_state), interval: String(r.interval ?? "unknown") as SubscriptionsInterval, currency: str(r.currency),
    monthlyAmount: numOrNull(r.monthly_amount), deviceUnits: numOrNull(r.device_units), ageMonths: numOrNull(r.age_months),
    propositions: Array.isArray(r.propositions) ? (r.propositions as unknown[]).map(String) : [], instrument: str(r.instrument),
    contactId: str(r.contact_id), contactUrl: str(r.contact_url),
  };
}

export function subscriptionRowsPageFromDb(j: J): SubscriptionRowsPage {
  return {
    page: num(j.page ?? 1), pageSize: num(j.page_size ?? SUBSCRIPTIONS_PAGE_ROWS), total: num(j.total), measure: (str(j.measure) ?? "total") as SubscriptionsMeasure,
    sort: (str(j.sort) ?? "monthly_amount") as SubscriptionsSort, descending: j.descending !== false, rows: arr(j.rows).map(subscriptionRowFromDb),
  };
}

export function subscriptionRowsFromDb(j: J): SubscriptionRowsList {
  if (j.set_up === false) {
    return { setUp: false, history: false, timeZone: "", computedAt: null, page: 1, pageSize: SUBSCRIPTIONS_PAGE_ROWS, total: 0, measure: "total", sort: "monthly_amount", descending: true, rows: [] };
  }
  return { setUp: true, history: j.history === true, timeZone: String(j.time_zone ?? ""), computedAt: str(j.computed_at), ...subscriptionRowsPageFromDb(j) };
}

export function churnCardFromDb(v: unknown): SubscriptionsChurnCard {
  if (!v || typeof v !== "object") return null;
  const o = v as J;
  if (o.month === null || o.month === undefined) return null;
  return { month: String(o.month).slice(0, 10), base: numOrNull(o.base), churned: num(o.churned), movedToFailed: num(o.moved_to_failed) };
}

const EMPTY_SETTINGS: SubscriptionsPage["settings"] = { holding: [], active: [], ended: [], deviceBands: [], ageBands: [], fx: null, propositions: [], historyMonths: 60 };

export function subscriptionsPageFromDb(j: J, query: { from: DateKey; to: DateKey; filter: SubscriptionsFilter }): SubscriptionsPage {
  if (j.set_up === false) {
    return {
      setUp: false, history: false, take: null, timeZone: "", today: "", month: "", from: query.from, to: query.to, filter: query.filter, settings: EMPTY_SETTINGS,
      filters: { markets: [], stores: [], propositions: [], intervals: [...SUBSCRIPTIONS_INTERVALS] }, tiles: null, months: [], rates: [], storeStarts: [],
      survival: null, mix: null, list: null,
    };
  }
  const take = j.take as J | null;
  const settings = (j.settings ?? {}) as J;
  const filters = (j.filters ?? {}) as J;
  const tiles = j.tiles as J | null;
  const survival = j.survival as J | null;
  const mix = j.mix as J | null;
  const mixRows = (v: unknown) => arr(v).map((r) => ({ key: String(r.key), ...(r.label !== undefined ? { label: str(r.label) } : {}), subscriptions: num(r.subscriptions) }));
  const strings = (v: unknown) => (Array.isArray(v) ? (v as unknown[]).map(String) : []);
  return {
    setUp: true, history: j.history === true,
    take: take ? { computedAt: String(take.computed_at), businessDate: String(take.business_date).slice(0, 10), amountsFrom: str(take.amounts_from) } : null,
    timeZone: String(j.time_zone ?? ""), today: day(j.today) ?? "", month: day(j.month) ?? "", from: day(j.from) ?? query.from, to: day(j.to) ?? query.to,
    filter: query.filter,
    settings: {
      holding: strings(settings.holding), active: strings(settings.active), ended: strings(settings.ended), deviceBands: strings(settings.device_bands),
      ageBands: strings(settings.age_bands), fx: (settings.fx as Record<string, unknown> | null) ?? null, propositions: strings(settings.propositions),
      historyMonths: num(settings.history_months ?? 60),
    },
    filters: {
      markets: strings(filters.markets),
      stores: arr(filters.stores).map((s) => ({ connectionId: String(s.connection_id), handle: String(s.handle ?? ""), market: String(s.market ?? "unknown") })),
      propositions: strings(filters.propositions), intervals: strings(filters.intervals) as SubscriptionsInterval[],
    },
    tiles: tiles ? {
      total: { value: num((tiles.total as J)?.value), byStatus: Object.fromEntries(Object.entries(((tiles.total as J)?.by_status ?? {}) as J).map(([k, v]) => [k, Number(v)])) },
      paused: num(tiles.paused),
      amounts: arr(tiles.amounts).map((a) => ({ currency: String(a.currency), amount: num(a.amount), subscriptions: num(a.subscriptions) })),
      eur: tiles.eur ? { amount: num((tiles.eur as J).amount), asOf: str((tiles.eur as J).as_of) } : null,
      rates: tiles.rates ? { month: String((tiles.rates as J).month).slice(0, 10), ...partsOf(tiles.rates)! } : null,
      devices: { units: num((tiles.devices as J)?.units), unmapped: num((tiles.devices as J)?.unmapped) },
      sourceCounts: sourceCountsFromDb(tiles.source_counts),
    } : null,
    months: arr(j.months).map((m) => ({ month: String(m.month).slice(0, 10), counts: kindsOf(m.counts),
      amounts: m.amounts && typeof m.amounts === "object"
        ? Object.fromEntries(Object.entries(m.amounts as J).map(([c, k]) => [c, kindsOf(k) ?? {}])) : null,
      complete: partsOf(m.complete) })),
    rates: arr(j.rates).map((r) => ({ market: String(r.market), month: String(r.month).slice(0, 10), ...partsOf(r)! })),
    storeStarts: arr(j.store_starts).map((s) => ({ connectionId: String(s.connection_id), handle: str(s.handle), market: String(s.market),
      firstEventMonth: String(s.first_event_month).slice(0, 10), rateStartMonth: String(s.rate_start_month).slice(0, 10), stragglers: num(s.stragglers) })),
    survival: survival ? {
      groups: arr(survival.groups).map((g) => ({ interval: String(g.interval) as SubscriptionsInterval,
        cohorts: arr(g.cohorts).map((c) => ({ cohort: String(c.cohort).slice(0, 10), started: num(c.started),
          cells: arr(c.cells).map((x) => ({ renewal: num(x.renewal), eligible: num(x.eligible), survived: num(x.survived) })) })) })),
      migratedLeftOut: num(survival.migrated_left_out),
    } : null,
    mix: mix ? {
      proposition: mixRows(mix.proposition), model: mixRows(mix.model), interval: mixRows(mix.interval), deviceBand: mixRows(mix.device_band),
      ageBand: mixRows(mix.age_band), instrument: mixRows(mix.instrument), paymentState: mixRows(mix.payment_state),
    } : null,
    list: j.list ? subscriptionRowsPageFromDb(j.list as J) : null,
  };
}

/** A survival cell is mature when every subscription the cohort started is due its renewal of that number (C.6): else the page shows a dash */
export function survivalShare(started: number, cell: { eligible: number; survived: number } | undefined): number | null {
  if (!cell || started <= 0 || cell.eligible < started) return null;
  return cell.survived / started;
}
