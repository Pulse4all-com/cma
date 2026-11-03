/**
 * Reports → Flash (addition 0008zn, brief B21, 1 November 2026): ten overviews and Data quality, one click each, live
 * from the mirrors or as of a business date with a snapshot, per market, on screen and as a file. The database computes
 * every figure (cma.flash_compute_of, one code path live and in the snapshot); this module holds what the page and the
 * routes decide on their own: the overviews' order and keys, the address keys, the sort whitelist (cma.flash_overviews,
 * which verify:flash compares with db/122_flash.sql), the As of parameter, the file names, the change arrows, a
 * definition's badge and the states of a source not set up. Pure: no database, no React.
 */

export type FlashKey =
  | "customers" | "subscriptions" | "installed_base" | "churn" | "orders" | "payments"
  | "open_deals" | "open_tickets" | "open_tasks" | "reviews" | "data_quality";
export type FlashKind = "stock" | "flow";
export type FlashSource = "commerce" | "subscriptions" | "assets" | "crm" | "reviews";

export interface FlashOverviewDef {
  key: FlashKey;
  /** The keyboard key that opens it: 1 to 9, 0, Q for Data quality */
  shortcut: string;
  kind: FlashKind;
  /** The source whose set-up it needs; null for Data quality */
  source: FlashSource | null;
  /** The breakdown's keys, the filters a list takes */
  dims: readonly string[];
  /** The grouping sets the database answers: [] the totals, then [market], then the breakdowns */
  sets: readonly (readonly string[])[];
  measures: readonly string[];
  /** The measures that count records: a list can be narrowed to the records behind one */
  countMeasures: readonly string[];
  /** The measures that are amounts per currency (an object of currency codes), never summed across currencies */
  amountMeasures: readonly string[];
  headline: string;
  /** The list's sort keys, the first the default */
  sorts: readonly string[];
  /** The list's default direction for the default sort */
  defaultDescending: boolean;
}

/** The eleven overviews in the page's order, as cma.flash_overviews() holds them (verify:flash compares the two) */
export const FLASH_OVERVIEWS: readonly FlashOverviewDef[] = [
  { key: "customers", shortcut: "1", kind: "stock", source: "commerce", dims: ["market", "store"], sets: [[], ["market"], ["market", "store"]],
    measures: ["customers_held", "active_customers", "paused_customers", "linked_to_contact", "with_required_refs"],
    countMeasures: ["customers_held", "active_customers", "paused_customers", "linked_to_contact", "with_required_refs"], amountMeasures: [],
    headline: "active_customers", sorts: ["lifetime_orders", "total_spent", "customer_id", "store", "market", "active_subscriptions", "devices"],
    defaultDescending: true },
  { key: "subscriptions", shortcut: "2", kind: "stock", source: "subscriptions", dims: ["market", "store", "status", "payment_state"],
    sets: [[], ["market"], ["market", "store", "status", "payment_state"]],
    measures: ["subscriptions", "active_subscriptions", "paused_subscriptions", "amount_per_cycle"],
    countMeasures: ["subscriptions", "active_subscriptions", "paused_subscriptions"], amountMeasures: ["amount_per_cycle"],
    headline: "active_subscriptions",
    sorts: ["subscription_id", "store", "market", "status", "payment_state", "amount_per_cycle", "next_billing_at", "retry_since", "devices"],
    defaultDescending: false },
  { key: "installed_base", shortcut: "3", kind: "stock", source: "assets", dims: ["market", "status", "model", "warehouse", "link"],
    sets: [[], ["market"], ["market", "status", "model", "warehouse", "link"]],
    measures: ["devices", "in_field", "in_stock", "components_past_due", "items_due_3m"],
    countMeasures: ["devices", "in_field", "in_stock", "components_past_due", "items_due_3m"], amountMeasures: [],
    headline: "in_field", sorts: ["serial", "model", "market", "status", "warehouse", "past_due_items", "next_due_on"], defaultDescending: false },
  { key: "churn", shortcut: "4", kind: "flow", source: "subscriptions", dims: ["market", "store", "reason"],
    sets: [[], ["market"], ["market", "store", "reason"]], measures: ["churned"], countMeasures: ["churned"], amountMeasures: [],
    headline: "churned", sorts: ["churned_at", "subscription_id", "store", "market", "reason", "cycles"], defaultDescending: true },
  { key: "orders", shortcut: "5", kind: "flow", source: "commerce", dims: ["market", "store", "kind", "sku"],
    sets: [[], ["market"], ["market", "store", "kind"], ["market", "sku"]], measures: ["orders", "units", "amount"], countMeasures: ["orders"],
    amountMeasures: ["amount"], headline: "orders", sorts: ["created_at", "order_number", "store", "market", "kind", "total"], defaultDescending: true },
  { key: "payments", shortcut: "6", kind: "flow", source: "commerce", dims: ["market", "store", "kind", "status"],
    sets: [[], ["market"], ["market", "store", "kind", "status"]], measures: ["orders", "amount", "renewals", "failed_renewals"],
    countMeasures: ["orders", "renewals", "failed_renewals"], amountMeasures: ["amount"], headline: "failed_renewals",
    sorts: ["at", "kind", "status", "amount", "store", "market"], defaultDescending: true },
  { key: "open_deals", shortcut: "7", kind: "stock", source: "crm", dims: ["market", "pipeline", "stage"],
    sets: [[], ["market"], ["market", "pipeline", "stage"]], measures: ["open_deals", "median_age_days", "oldest_age_days"],
    countMeasures: ["open_deals"], amountMeasures: [], headline: "open_deals",
    sorts: ["age_days", "created_at", "record_id", "pipeline", "stage", "market"], defaultDescending: true },
  { key: "open_tickets", shortcut: "8", kind: "stock", source: "crm", dims: ["market", "queue", "stage"],
    sets: [[], ["market"], ["market", "queue", "stage"]], measures: ["open_tickets", "median_age_days", "oldest_age_days"],
    countMeasures: ["open_tickets"], amountMeasures: [], headline: "open_tickets",
    sorts: ["age_days", "created_at", "record_id", "queue", "stage", "market"], defaultDescending: true },
  { key: "open_tasks", shortcut: "9", kind: "stock", source: "crm", dims: ["market", "type", "status"],
    sets: [[], ["market"], ["market", "type", "status"]], measures: ["open_tasks", "overdue"], countMeasures: ["open_tasks", "overdue"],
    amountMeasures: [], headline: "open_tasks", sorts: ["due_at", "task_id", "type", "status", "market"], defaultDescending: false },
  { key: "reviews", shortcut: "0", kind: "flow", source: "reviews", dims: ["market", "rating"], sets: [[], ["market"], ["market", "rating"]],
    measures: ["reviews", "rating_sum", "negative"], countMeasures: ["reviews", "negative"], amountMeasures: [], headline: "reviews",
    sorts: ["submitted_at", "rating", "market", "review_id"], defaultDescending: true },
  { key: "data_quality", shortcut: "Q", kind: "stock", source: null, dims: ["check", "market"],
    sets: [[], ["market"], ["check"], ["check", "market"]], measures: ["findings"], countMeasures: ["findings"], amountMeasures: [],
    headline: "findings", sorts: ["object_id", "check", "market"], defaultDescending: false },
];

/** The address keys of /reports/flash: the overview, the market (K), As of (A), the period, the list's sort and page, the
 * list's filters (f_<dim> and the measure) and, on Data quality, the check */
export const FLASH_ADDRESS = {
  overview: "o", market: "market", asOf: "asOf", from: "from", to: "to", sort: "sort", dir: "dir", page: "page", measure: "measure",
  check: "check", filterPrefix: "f_",
} as const;

/** Rows a list page shows; a file holds up to the tenant's flash.file_max_rows */
export const FLASH_PAGE_ROWS = 500;
/** The most rows one file holds when the tenant's setting is not known (decision 7: 50,000) */
export const FLASH_FILE_MAX_ROWS = 50_000;
/** The sources in the order the top line names them */
export const FLASH_SOURCES: readonly FlashSource[] = ["commerce", "subscriptions", "assets", "crm", "reviews"];

export function overviewOf(key: unknown): FlashOverviewDef | null {
  return typeof key === "string" ? FLASH_OVERVIEWS.find((o) => o.key === key) ?? null : null;
}

/** The overview a key opens (1 to 9, 0, Q; case-insensitive), or null */
export function overviewOfShortcut(key: string): FlashOverviewDef | null {
  const k = key.length === 1 ? key.toUpperCase() : "";
  return FLASH_OVERVIEWS.find((o) => o.shortcut === k) ?? null;
}

const DATE = /^\d{4}-\d{2}-\d{2}$/;

/** A YYYY-MM-DD that is a real date */
export function isDate(value: unknown): value is string {
  if (typeof value !== "string" || !DATE.test(value)) return false;
  const d = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === value;
}

/**
 * As of from the address: absent, empty or "now" is now (null); a business date before the tenant's today is a snapshot's
 * date; anything else (today, a future date, no date) is a problem and reads as now
 */
export function parseAsOf(value: unknown, today: string): { asOf: string | null; problem: boolean } {
  if (value === undefined || value === null || value === "" || value === "now") return { asOf: null, problem: false };
  if (isDate(value) && value < today) return { asOf: value, problem: false };
  return { asOf: null, problem: true };
}

/** A market from the address: a two-letter code or unknown, else none */
export function parseMarket(value: unknown): string | null {
  return typeof value === "string" && /^([A-Z]{2}|unknown)$/.test(value) ? value : null;
}

/** A list's sort from the address: a key of the overview's whitelist, else its default; the direction asc or desc */
export function parseSort(def: FlashOverviewDef, sort: unknown, dir: unknown): { sort: string; descending: boolean } {
  const first = def.sorts[0] ?? "";
  const s = typeof sort === "string" && def.sorts.includes(sort) ? sort : first;
  const descending = dir === "desc" ? true : dir === "asc" ? false : s === first ? def.defaultDescending : false;
  return { sort: s, descending };
}

/** The list's filters from the address: f_<dim> for the overview's dims (1 to 100 characters) and measure for a count measure */
export function parseFilters(def: FlashOverviewDef, read: (key: string) => string | undefined): Record<string, string> {
  const out: Record<string, string> = {};
  for (const d of def.dims) {
    const v = read(`${FLASH_ADDRESS.filterPrefix}${d}`);
    // a market filter is a market's code or unknown, as the database checks it (CMA04 otherwise): anything else dropped
    if (typeof v === "string" && v.length >= 1 && v.length <= 100 && (d !== "market" || parseMarket(v) !== null)) out[d] = v;
  }
  const m = read(FLASH_ADDRESS.measure);
  if (typeof m === "string" && def.countMeasures.includes(m)) out.measure = m;
  return out;
}

/** The filters a breakdown cell opens: the row's dims and, for a count cell, its measure (null: the row's own link) */
export function cellFilters(dims: Record<string, string>, measure: string | null): Record<string, string> {
  return { ...dims, ...(measure ? { measure } : {}) };
}

/**
 * A past month end's frozen list (cma.flash_id_rows_of) per overview that keeps one: the record kind, the one count
 * measure it is, and whether it takes a status (the subscription's or the device's; a customer's list is all active)
 */
export const FLASH_FROZEN_LIST: Partial<Record<FlashKey, { kind: "customer" | "subscription" | "device"; measure: string; status: boolean }>> = {
  customers: { kind: "customer", measure: "active_customers", status: false },
  subscriptions: { kind: "subscription", measure: "active_subscriptions", status: true },
  installed_base: { kind: "device", measure: "devices", status: true },
};

/**
 * A list's filters split for a past month end's frozen list, which takes the market, the status (not for customers) and
 * its own count measure only, as the database does (CMA04 for anything else): kept, the filters the page and a file send
 * to it; dropped, those it cannot apply, which the page names in its "not available for this snapshot" notice
 */
export function frozenFilters(def: FlashOverviewDef, filters: Record<string, string>): { kept: Record<string, string>; dropped: string[] } {
  const frozen = FLASH_FROZEN_LIST[def.key];
  const kept: Record<string, string> = {};
  const dropped: string[] = [];
  for (const [k, v] of Object.entries(filters)) {
    const takes = frozen !== undefined
      && (k === "market" || (k === "status" && frozen.status) || (k === "measure" && v === frozen.measure));
    if (takes) kept[k] = v;
    else dropped.push(k);
  }
  return { kept, dropped: dropped.sort() };
}

/**
 * Whether a list read's refusal means the records are not available rather than an error: CMA02 (no list kept for the
 * date, or one the retention removed) and CMA04 (a filter the list cannot apply). The page then shows the overview with
 * its "not available" notice in place of the list, never an error page
 */
export function listUnavailable(sqlState: string | null | undefined): boolean {
  return sqlState === "CMA02" || sqlState === "CMA04";
}

/**
 * The stamp a file's name carries: a snapshot's date (YYYY-MM-DD), or for now the instant in the tenant's zone
 * (YYYY-MM-DDTHHmm)
 */
export function asOfStamp(asOf: string | null, now: Date, timeZone: string): string {
  if (asOf) return asOf;
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit",
    hourCycle: "h23" }).formatToParts(now);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "00";
  return `${get("year")}-${get("month")}-${get("day")}T${get("hour")}${get("minute")}`;
}

/**
 * A file's name: flash-<overview>-<market|all>-<YYYY-MM-DD or YYYY-MM-DDTHHmm>.csv; the breakdown's ends -breakdown. Only
 * codes, a date and an hour: never a filter's value beyond the market
 */
export function flashFileName(overview: FlashKey, market: string | null, stamp: string, part: "rows" | "breakdown" = "rows"): string {
  const m = parseMarket(market) ?? "all";
  const s = /^\d{4}-\d{2}-\d{2}(T\d{4})?$/.test(stamp) ? stamp : "unknown";
  return `flash-${overview}-${m}-${s}${part === "breakdown" ? "-breakdown" : ""}.csv`;
}

/** A figure's change against the one to compare with: its direction and its size; none when either is missing */
export function changeOf(value: number | null | undefined, previous: number | null | undefined): { direction: "up" | "down" | "flat" | "none"; delta: number | null } {
  if (typeof value !== "number" || typeof previous !== "number" || !Number.isFinite(value) || !Number.isFinite(previous)) {
    return { direction: "none", delta: null };
  }
  const delta = Math.round((value - previous) * 100) / 100;
  return { direction: delta > 0 ? "up" : delta < 0 ? "down" : "flat", delta };
}

/** The arrow a change shows (Muted text: never a colour that judges a move as good or bad) */
export function changeArrow(direction: "up" | "down" | "flat" | "none"): string {
  return direction === "up" ? "↑" : direction === "down" ? "↓" : direction === "flat" ? "→" : "";
}

export type DefinitionStatus = "Decided" | "Proposed" | "Pending" | "Retired";

/** A figure's definition status from the metric catalog (its first word), Proposed when the catalog does not say */
export function definitionStatus(status: unknown): DefinitionStatus {
  const s = typeof status === "string" ? status.trim().split(/[\s(:,]/)[0] : "";
  return s === "Decided" || s === "Proposed" || s === "Pending" || s === "Retired" ? s : "Proposed";
}

/** The badge's tone of a definition status: Decided success, Proposed info, Pending warning, Retired neutral */
export function statusTone(status: DefinitionStatus): "success" | "info" | "warning" | "neutral" {
  return status === "Decided" ? "success" : status === "Proposed" ? "info" : status === "Pending" ? "warning" : "neutral";
}

/** The metric catalog key of an overview's measure */
export function metricKey(overview: FlashKey, measure: string): string {
  return `flash.${overview}.${measure}`;
}

export interface FlashSourceState {
  set_up: boolean;
  adapters: string[];
  last_read_at: string | null;
}

/** The sources an overview's top line names: its own first, then the others that are set up; data quality names every set-up one */
export function sourcesLine(sources: Partial<Record<FlashSource, FlashSourceState>> | null | undefined, own: FlashSource | null): { source: FlashSource; setUp: boolean; lastReadAt: string | null }[] {
  const out: { source: FlashSource; setUp: boolean; lastReadAt: string | null }[] = [];
  for (const s of own ? [own, ...FLASH_SOURCES.filter((x) => x !== own)] : FLASH_SOURCES) {
    const st = sources?.[s];
    if (!st) continue;
    if (s === own || st.set_up) out.push({ source: s, setUp: Boolean(st.set_up), lastReadAt: st.last_read_at ?? null });
  }
  return out;
}

/** Whether an overview's figures show: false when its source is not set up (the page says so in place of figures, never zeros) */
export function showsFigures(def: FlashOverviewDef, setUp: boolean): boolean {
  return def.source === null || setUp;
}

/** An amount measure as rows per currency, sorted by currency: never one sum across currencies */
export function amountsOf(value: unknown): { currency: string; amount: number }[] {
  if (!value || typeof value !== "object" || Array.isArray(value)) return [];
  return Object.entries(value as Record<string, unknown>)
    .filter(([c, v]) => /^[A-Z]{3}$/.test(c) && typeof v === "number" && Number.isFinite(v))
    .map(([currency, amount]) => ({ currency, amount: amount as number }))
    .sort((a, b) => a.currency.localeCompare(b.currency));
}

/**
 * Rows sorted by an amount within currency: currency first (ascending, none last), then the amount in the direction asked,
 * then the id; as the database sorts a list by total spent or an amount
 */
export function sortWithinCurrency<T>(rows: readonly T[], amount: (r: T) => number | null, currency: (r: T) => string | null, id: (r: T) => string,
  descending: boolean): T[] {
  return [...rows].sort((a, b) => {
    const ca = currency(a);
    const cb = currency(b);
    if (ca !== cb) return ca === null ? 1 : cb === null ? -1 : ca.localeCompare(cb);
    const xa = amount(a);
    const xb = amount(b);
    if (xa !== xb) {
      if (xa === null) return 1;
      if (xb === null) return -1;
      return descending ? xb - xa : xa - xb;
    }
    return id(a).localeCompare(id(b));
  });
}

/** The rows of a document that belong to a grouping set (exactly its keys) */
export function rowsOfSet<R extends { dims: Record<string, string> }>(rows: readonly R[], set: readonly string[]): R[] {
  const want = [...set].sort().join(",");
  return rows.filter((r) => Object.keys(r.dims).sort().join(",") === want);
}

/** The breakdown sets an overview's table shows: every set with more than the market */
export function breakdownSets(def: FlashOverviewDef): (readonly string[])[] {
  return def.sets.filter((s) => s.length > 1 || (s.length === 1 && s[0] !== "market"));
}

/** A share of the largest value for an inline bar, 0 to 1 */
export function barShare(value: number, max: number): number {
  return max > 0 && value > 0 ? Math.min(1, value / max) : 0;
}

/** The average rating of reviews from the stored sum and count (two decimals), null without reviews */
export function averageRating(ratingSum: number | null | undefined, reviews: number | null | undefined): number | null {
  return typeof ratingSum === "number" && typeof reviews === "number" && reviews > 0 ? Math.round((ratingSum / reviews) * 100) / 100 : null;
}

/** How a file writes a column's value (lib/csv FlashFileColumn) */
export type FlashColumnKind = "text" | "number" | "date" | "instant" | "flag" | "list" | "refs";

/**
 * Each overview's list columns in their order, as cma.flash_rows answers them (verify:flash compares the keys with
 * db/122_flash.sql's lists), and how a file writes each. The connection's id is left out of the screen and the file: a
 * store, a channel or a pipeline names it. So are the links outside the CRM (FLASH_LINKS_LEFT_OUT): the Workspace links to
 * the CRM and the telephony system only (CLAUDE.md; the register gets no link, as on Maintenance)
 */
export const FLASH_LIST_COLUMNS: Record<FlashKey, readonly { key: string; kind: FlashColumnKind }[]> = {
  customers: [
    { key: "customer_id", kind: "text" }, { key: "store", kind: "text" }, { key: "market", kind: "text" }, { key: "contact_id", kind: "text" },
    { key: "contact_url", kind: "text" }, { key: "contact_held", kind: "flag" }, { key: "refs", kind: "refs" }, { key: "missing_refs", kind: "list" },
    { key: "lifetime_orders", kind: "number" }, { key: "total_spent", kind: "number" }, { key: "currency", kind: "text" },
    { key: "active_subscriptions", kind: "number" }, { key: "paused_subscriptions", kind: "number" }, { key: "devices", kind: "number" },
    { key: "order_ids", kind: "list" }, { key: "orders_held", kind: "number" }, { key: "subscription_ids", kind: "list" },
  ],
  subscriptions: [
    { key: "subscription_id", kind: "text" }, { key: "store", kind: "text" }, { key: "market", kind: "text" }, { key: "customer_id", kind: "text" },
    { key: "contact_id", kind: "text" }, { key: "contact_url", kind: "text" }, { key: "status", kind: "text" }, { key: "payment_state", kind: "text" },
    { key: "amount_per_cycle", kind: "number" }, { key: "currency", kind: "text" }, { key: "billing_interval", kind: "text" },
    { key: "billing_interval_count", kind: "number" }, { key: "next_billing_at", kind: "instant" }, { key: "retry_since", kind: "instant" },
    { key: "last_attempt", kind: "number" }, { key: "devices", kind: "number" },
  ],
  installed_base: [
    { key: "serial", kind: "text" }, { key: "device_id", kind: "text" }, { key: "model", kind: "text" }, { key: "market", kind: "text" },
    { key: "status", kind: "text" }, { key: "in_field", kind: "flag" }, { key: "in_stock", kind: "flag" }, { key: "warehouse", kind: "text" },
    { key: "refs", kind: "refs" }, { key: "missing_refs", kind: "list" }, { key: "customer_id", kind: "text" }, { key: "subscription_id", kind: "text" },
    { key: "link", kind: "text" }, { key: "subscription_status", kind: "text" }, { key: "subscription_payment_state", kind: "text" },
    { key: "past_due_items", kind: "number" }, { key: "items_due_3m", kind: "number" }, { key: "next_due_on", kind: "date" },
  ],
  churn: [
    { key: "subscription_id", kind: "text" }, { key: "store", kind: "text" }, { key: "market", kind: "text" }, { key: "customer_id", kind: "text" },
    { key: "churned_at", kind: "instant" }, { key: "business_date", kind: "date" }, { key: "reason", kind: "text" }, { key: "cycles", kind: "number" },
  ],
  orders: [
    { key: "order_number", kind: "text" }, { key: "order_id", kind: "text" }, { key: "store", kind: "text" }, { key: "market", kind: "text" },
    { key: "created_at", kind: "instant" }, { key: "business_date", kind: "date" }, { key: "kind", kind: "text" }, { key: "financial_status", kind: "text" },
    { key: "fulfillment_status", kind: "text" }, { key: "skus", kind: "list" }, { key: "units", kind: "number" }, { key: "total", kind: "number" },
    { key: "currency", kind: "text" }, { key: "customer_id", kind: "text" },
  ],
  payments: [
    { key: "kind", kind: "text" }, { key: "status", kind: "text" }, { key: "record_ref", kind: "text" }, { key: "cycle", kind: "number" },
    { key: "source_id", kind: "text" }, { key: "store", kind: "text" }, { key: "market", kind: "text" }, { key: "at", kind: "instant" },
    { key: "business_date", kind: "date" }, { key: "amount", kind: "number" }, { key: "currency", kind: "text" },
  ],
  open_deals: [
    { key: "record_id", kind: "text" }, { key: "record_url", kind: "text" }, { key: "pipeline", kind: "text" }, { key: "stage", kind: "text" },
    { key: "market", kind: "text" }, { key: "owner_ref", kind: "text" }, { key: "owner_linked", kind: "flag" }, { key: "created_at", kind: "instant" },
    { key: "age_days", kind: "number" },
  ],
  open_tickets: [
    { key: "record_id", kind: "text" }, { key: "record_url", kind: "text" }, { key: "queue", kind: "text" }, { key: "stage", kind: "text" },
    { key: "market", kind: "text" }, { key: "owner_ref", kind: "text" }, { key: "owner_linked", kind: "flag" }, { key: "created_at", kind: "instant" },
    { key: "age_days", kind: "number" },
  ],
  open_tasks: [
    { key: "task_id", kind: "text" }, { key: "task_url", kind: "text" }, { key: "type", kind: "text" }, { key: "status", kind: "text" },
    { key: "market", kind: "text" }, { key: "owner_ref", kind: "text" }, { key: "owner_linked", kind: "flag" }, { key: "due_at", kind: "instant" },
    { key: "overdue", kind: "flag" }, { key: "record_type", kind: "text" }, { key: "record_id", kind: "text" }, { key: "record_url", kind: "text" },
  ],
  reviews: [
    { key: "review_id", kind: "text" }, { key: "channel", kind: "text" }, { key: "market", kind: "text" },
    { key: "rating", kind: "number" }, { key: "stars", kind: "number" }, { key: "negative", kind: "flag" }, { key: "submitted_at", kind: "instant" },
    { key: "business_date", kind: "date" }, { key: "link_level", kind: "text" },
  ],
  data_quality: [
    { key: "check", kind: "text" }, { key: "object_type", kind: "text" }, { key: "object_id", kind: "text" }, { key: "value", kind: "text" },
    { key: "market", kind: "text" }, { key: "fix_in", kind: "text" }, { key: "fix_adapter", kind: "text" }, { key: "record_url", kind: "text" },
    { key: "related_type", kind: "text" }, { key: "related_id", kind: "text" }, { key: "related_url", kind: "text" },
  ],
};

/** A past month end's frozen list's columns (cma.flash_id_rows_of): the id, the market and the state as frozen */
export const FLASH_FROZEN_COLUMNS: readonly { key: string; kind: FlashColumnKind }[] = [
  { key: "source_id", kind: "text" }, { key: "market", kind: "text" }, { key: "state", kind: "text" },
];

/** A file's filters column: the market, the period and the list's filters as key=value, "all" without any */
export function filtersText(market: string | null, from: string | null, to: string | null, filters: Record<string, string>): string {
  const parts: string[] = [];
  if (market) parts.push(`market=${market}`);
  if (from) parts.push(`from=${from}`);
  if (to) parts.push(`to=${to}`);
  for (const [k, v] of Object.entries(filters).sort(([a], [b]) => a.localeCompare(b))) if (k !== "market" || !market) parts.push(`${k}=${v}`);
  return parts.length ? parts.join("; ") : "all";
}

/**
 * The measures the database leaves out of every row while their setting is empty, per overview, with that setting
 * (cma.flash_compute_of; Decision log, 3 Nov 2026, "Definitions: a Flash measure that does not apply is left out,
 * never 0"): a measure a row leaves out is not applicable, live and in a snapshot taken then. The page shows it as not
 * applicable without a link to records, a file leaves its cell empty, never 0 or all
 */
export const FLASH_CONDITIONAL_MEASURES: Partial<Record<FlashKey, Readonly<Record<string, string>>>> = {
  customers: { with_required_refs: "commerce.required_contact_refs" },
};

/** Whether a row's measure is not applicable: a conditional measure the row leaves out (no row: not this question) */
export function measureNotApplicable(overview: FlashKey, measures: Readonly<Record<string, unknown>> | null | undefined, measure: string): boolean {
  return measures != null && FLASH_CONDITIONAL_MEASURES[overview]?.[measure] !== undefined && !(measure in measures);
}

/** A document's row: a grouping set's dims and its measures (a number, or an amount per currency) */
export interface FlashDocRow {
  dims: Record<string, string>;
  measures: Record<string, unknown>;
}

/** The currencies an amount measure holds across rows, sorted */
export function currenciesOf(rows: readonly FlashDocRow[], measure: string): string[] {
  const set = new Set<string>();
  for (const r of rows) for (const a of amountsOf(r.measures[measure])) set.add(a.currency);
  return [...set].sort();
}

/**
 * The breakdown file's columns: the set (totals, market or the breakdown's keys), every dim, then each measure; an amount
 * one column per currency (<measure>_<CUR>), never one sum across currencies
 */
export function breakdownColumns(def: FlashOverviewDef, rows: readonly FlashDocRow[]): { key: string; kind: FlashColumnKind }[] {
  const out: { key: string; kind: FlashColumnKind }[] = [{ key: "set", kind: "text" }, ...def.dims.map((d) => ({ key: d, kind: "text" as const }))];
  for (const m of def.measures) {
    if (def.amountMeasures.includes(m)) for (const c of currenciesOf(rows, m)) out.push({ key: `${m}_${c}`, kind: "number" });
    else out.push({ key: m, kind: "number" });
  }
  return out;
}

/** The breakdown file's lines: one per row of the document, its set named by its keys ("totals" for none) */
export function breakdownRows(def: FlashOverviewDef, rows: readonly FlashDocRow[]): Record<string, unknown>[] {
  return rows.map((r) => {
    const keys = Object.keys(r.dims);
    const line: Record<string, unknown> = { set: keys.length === 0 ? "totals" : def.dims.filter((d) => keys.includes(d)).join("+") };
    for (const d of def.dims) line[d] = r.dims[d] ?? null;
    for (const m of def.measures) {
      if (def.amountMeasures.includes(m)) for (const a of amountsOf(r.measures[m])) line[`${m}_${a.currency}`] = a.amount;
      // a measure the row leaves out (not applicable) is an empty cell, never 0
      else line[m] = typeof r.measures[m] === "number" ? r.measures[m] : null;
    }
    return line;
  });
}

/** The links cma.flash_rows answers that the screen and the file leave out: the register's and the review platform's */
export const FLASH_LINKS_LEFT_OUT: Partial<Record<FlashKey, readonly string[]>> = { installed_base: ["record_url"], reviews: ["review_url"] };

/** The record types whose link is the CRM's (a data-quality finding's link shows for these only) */
const CRM_TYPES = new Set(["contact", "deal", "ticket", "task", "crm_call", "owner", "pipeline", "form"]);

/** A data-quality row as the screen and the file show it: a record's link only for a CRM record, the related one only for a contact */
export function dataQualityRowShown(row: Record<string, unknown>): Record<string, unknown> {
  return {
    ...row,
    record_url: CRM_TYPES.has(String(row.object_type)) ? row.record_url ?? null : null,
    related_url: row.related_type === "contact" ? row.related_url ?? null : null,
  };
}

/**
 * Each figure's definition status, as docs/definitions.md holds it (every Flash term Proposed for Kira, 1 November 2026)
 * and the metric catalog's notes repeat it ("Definition status: …"; verify:flash compares the two). A card and a hint
 * show it, so a Proposed figure is visibly Proposed
 */
export const FLASH_DEFINITION_STATUS: Readonly<Record<FlashKey, DefinitionStatus>> = {
  customers: "Proposed", subscriptions: "Proposed", installed_base: "Proposed", churn: "Proposed", orders: "Proposed", payments: "Proposed",
  open_deals: "Proposed", open_tickets: "Proposed", open_tasks: "Proposed", reviews: "Proposed", data_quality: "Proposed",
};

/** Where a data-quality check's findings are fixed */
export type FlashFixIn = "crm" | "commerce" | "subscriptions" | "assets" | "cma";

/**
 * Where a check's findings are fixed, as cma.data_quality_fix_in(check, value) answers it for the check's usual value
 * (verify:flash compares the lists with db/122_flash.sql): a finding's own row in the list carries the database's answer,
 * which for customer_required_ref_missing is the Workspace when the contact is not held
 */
export const FLASH_FIX_IN: Readonly<Record<Exclude<FlashFixIn, "cma" | "subscriptions">, readonly string[]>> = {
  crm: ["customer_required_ref_missing", "deal_without_contact", "deal_contact_incomplete", "crm_call_without_contact", "commerce_unmatched", "commerce_ambiguous",
    "contact_slots_full", "contact_country_differs", "contact_country_fallback", "ticket_no_owner", "ticket_no_market", "telephony_call_unlinked"],
  commerce: ["customer_in_two_stores", "subscription_customer_unmatched"],
  assets: ["device_serial_missing", "device_serial_duplicate", "device_model_unmapped", "device_status_unmapped", "device_market_unmapped",
    "device_customer_ref_invalid", "component_due_unknown", "field_device_without_subscription_ref", "device_required_ref_missing",
    "active_subscription_without_device", "device_subscription_ref_unknown", "field_device_on_ended_subscription"],
};

/** Where a check's findings are fixed; the Workspace for every other check */
export function fixInOf(check: string): FlashFixIn {
  for (const [k, list] of Object.entries(FLASH_FIX_IN) as [FlashFixIn, readonly string[]][]) if (list.includes(check)) return k;
  return "cma";
}
