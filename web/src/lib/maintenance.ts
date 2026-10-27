/**
 * Maintenance (addition 0008zi): Reports → Maintenance. The tenant's asset register owns its devices (for Pulse4all
 * Subscriptions an Airtable base with NetSuite ids); the CMA mirrors them read-only from a snapshot of the register's
 * CSV export and forecasts what comes due. The figures come from the database (cma.maintenance_page,
 * cma.maintenance_rows); this module mirrors their definitions for the mock and for verify/reports.mjs, parses the
 * page's address and arranges the grid. Pure, with no runtime imports beyond time.ts, so the verifier runs it under
 * Node's type stripping.
 *
 * The definitions (docs/definitions.md, Asset terms; 112_assets.sql):
 *   tracked          a device whose device status has is_tracked and that the latest full snapshot still holds
 *   due item         a component the device carries, its model has a rule for, or of every kind while the model is
 *                    unknown; and the device itself at its end of life (component "device")
 *   due date         the recorded expiry (basis recorded), else the anchor date (the last shipment, else the first) plus
 *                    the rule's interval in months (basis rule), else none (basis unknown); end of life: its recorded date
 *   action date      the due date less the rule's lead days (none without a rule; none for end of life)
 *   overdue          the action date lies before the current month
 *   planned exchange per device in action-date order, an item joins the exchange before it while its action date lies
 *                    within assets.bundle_window_days of that exchange's first action date; counted once, in the month of
 *                    that first action date
 * Team figures only: no figure per person exists. Ids, codes, counts and dates only: never a customer's name.
 */
import type {
  DateKey, MaintenanceBasis, MaintenanceCell, MaintenanceFilter, MaintenanceReport, MaintenanceRow, MaintenanceRows, MaintenanceScope,
  MaintenanceView,
} from "./data/types";
// With its extension, so verify/reports.mjs can run this module under Node's type stripping
import { addDays } from "./time.ts";

export const MAINTENANCE_HORIZONS = [6, 12, 24] as const;
export const MAINTENANCE_DEFAULT_HORIZON = 12;
export const MAINTENANCE_SCOPES: readonly MaintenanceScope[] = ["field", "stock"];
export const MAINTENANCE_VIEWS: readonly MaintenanceView[] = ["exchanges", "components"];
/** The device list's rows on the page, and the file's at most */
export const MAINTENANCE_LIST_ROWS = 500;
export const MAINTENANCE_FILE_ROWS = 5000;
/** The component key of a device's own end of life */
export const END_OF_LIFE = "device";

const MONTH_RE = /^\d{4}-\d{2}-01$/;
const MARKET_RE = /^([A-Z]{2}|unknown)$/;
const MODEL_RE = /^[a-z0-9]+(_[a-z0-9]+)*$/;

// ---- dates -----------------------------------------------------------------------------------

/** The first day of a date's month */
export function monthOf(key: DateKey): DateKey {
  return `${key.slice(0, 7)}-01`;
}

/** A date plus whole months, the day kept or clamped to the month's last (Postgres's date + interval) */
export function addMonths(key: DateKey, months: number): DateKey {
  const [y, m, d] = key.split("-").map(Number) as [number, number, number];
  const total = y * 12 + (m - 1) + months;
  const year = Math.floor(total / 12);
  const month = total - year * 12 + 1;
  const last = new Date(Date.UTC(year, month, 0)).getUTCDate();
  return `${String(year).padStart(4, "0")}-${String(month).padStart(2, "0")}-${String(Math.min(d, last)).padStart(2, "0")}`;
}

/** Whole days between two dates (b - a) */
function daysBetween(a: DateKey, b: DateKey): number {
  return Math.round((Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`)) / 86400000);
}

/** A month as "Nov 2026" / "nov 2026" */
export function fmtMonth(key: DateKey, locale: "en" | "nl"): string {
  return new Intl.DateTimeFormat(locale === "nl" ? "nl-NL" : "en-GB", { month: "short", year: "numeric", timeZone: "UTC" })
    .format(new Date(`${key}T00:00:00Z`)).replace(".", "");
}

// ---- the page's address ------------------------------------------------------------------------

/** The months a horizon may start in: the current month and the 12 after it */
export function fromMonthChoices(currentMonth: DateKey): DateKey[] {
  return Array.from({ length: 13 }, (_, i) => addMonths(currentMonth, i));
}

export function parseHorizon(value: string | string[] | undefined | null): number | null {
  const v = Array.isArray(value) ? value[0] : value;
  return MAINTENANCE_HORIZONS.find((h) => String(h) === v) ?? null;
}

export function parseScope(value: string | string[] | undefined | null): MaintenanceScope | null | "invalid" {
  const v = Array.isArray(value) ? value[0] : value;
  if (v === undefined || v === null || v === "") return null;
  return (MAINTENANCE_SCOPES as readonly string[]).includes(v) ? (v as MaintenanceScope) : "invalid";
}

export function parseView(value: string | string[] | undefined | null): MaintenanceView | null {
  const v = Array.isArray(value) ? value[0] : value;
  return (MAINTENANCE_VIEWS as readonly string[]).includes(v ?? "") ? (v as MaintenanceView) : null;
}

/** The view after this one (G) */
export function nextView(view: MaintenanceView): MaintenanceView {
  return view === "exchanges" ? "components" : "exchanges";
}

/**
 * The page's filter from its address: from (the first day of a month, the current one up to 12 later), months (6, 12 or
 * 24), market (a code or unknown), model (a key or unknown) and scope (field or stock). A value out of line falls back to
 * the default and is reported, so the page says the filter was ignored
 */
export function parseMaintenanceFilter(sp: Record<string, string | string[] | undefined>, currentMonth: DateKey): { filter: MaintenanceFilter; problem: boolean } {
  const one = (k: string) => { const v = sp[k]; return Array.isArray(v) ? v[0] : v; };
  let problem = false;
  const from = one("from");
  const choices = fromMonthChoices(currentMonth);
  const fromMonth = from && choices.includes(from) ? from : currentMonth;
  if (from && fromMonth !== from) problem = true;
  const months = parseHorizon(one("months"));
  if (one("months") && months === null) problem = true;
  const market = one("market");
  const model = one("model");
  const scope = parseScope(one("scope"));
  if (market && !MARKET_RE.test(market)) problem = true;
  if (model && !(MODEL_RE.test(model) && model.length <= 40)) problem = true;
  if (scope === "invalid") problem = true;
  return {
    filter: {
      fromMonth, months: months ?? MAINTENANCE_DEFAULT_HORIZON,
      market: market && MARKET_RE.test(market) ? market : null,
      model: model && MODEL_RE.test(model) && model.length <= 40 ? model : null,
      scope: scope === "invalid" ? null : scope,
    },
    problem,
  };
}

/** The filter as address keys, the defaults left out */
export function maintenanceQuery(filter: MaintenanceFilter, currentMonth: DateKey): Record<string, string> {
  const q: Record<string, string> = {};
  if (filter.fromMonth !== currentMonth) q.from = filter.fromMonth;
  if (filter.months !== MAINTENANCE_DEFAULT_HORIZON) q.months = String(filter.months);
  if (filter.market) q.market = filter.market;
  if (filter.model) q.model = filter.model;
  if (filter.scope) q.scope = filter.scope;
  return q;
}

/** A device-list bucket: overdue, unknown or the first day of a month of the horizon; null otherwise */
export function parseBucket(value: string | string[] | undefined | null, buckets: readonly string[]): string | null {
  const v = Array.isArray(value) ? value[0] : value;
  if (!v) return null;
  return v === "unknown" || buckets.includes(v) ? v : null;
}

/** Whether a bucket the routes take is well formed: overdue, unknown, all or the first day of a month */
export function bucketProblem(value: string | null): boolean {
  return !value || !(["overdue", "unknown", "all"].includes(value) || MONTH_RE.test(value));
}

// ---- the mirror: due items, the page, the device list -------------------------------------------

/** A device as the mock holds it: the register's facts after the mapping, and its current components */
export interface MaintenanceDevice {
  id: string;
  connectionId: string;
  sourceId: string;
  serial: string | null;
  model: string | null;
  market: string | null;
  status: string | null;
  customerRef: string | null;
  subscriptionRef: string | null;
  firstShippedOn: DateKey | null;
  lastShippedOn: DateKey | null;
  endOfLifeOn: DateKey | null;
  /** Missing from the latest full snapshot */
  missing: boolean;
  components: { kind: string; serial: string | null; expiresOn: DateKey | null }[];
  /** The CRM contact of the customer reference's commerce customer (0008h), when there is exactly one */
  crmContactId: string | null;
}

/** The tenant's catalogs and setting the forecast reads */
export interface MaintenanceCatalog {
  models: { key: string; name: string; sortOrder: number }[];
  kinds: { key: string; name: string; sortOrder: number; active: boolean }[];
  rules: { model: string; component: string; intervalMonths: number; leadDays: number }[];
  statuses: { key: string; name: string; isInField: boolean; isInStock: boolean; isTracked: boolean }[];
  markets: { code: string; sortOrder: number }[];
  windowDays: number;
}

/** A due item (cma.maintenance_items_of); market and model as stored, null when unmapped */
export interface DueItem {
  deviceId: string;
  sourceId: string;
  serial: string | null;
  model: string | null;
  market: string | null;
  status: string;
  isInField: boolean;
  isInStock: boolean;
  component: string;
  componentOrder: number;
  dueOn: DateKey | null;
  basis: MaintenanceBasis;
  actionOn: DateKey | null;
  overdue: boolean;
  exchangeKey: string | null;
  exchangeOn: DateKey | null;
}

const LAST = 2147483647;

/** Every due item of the tracked devices as of today (cma.maintenance_items_of), in device and action-date order */
export function maintenanceItems(devices: readonly MaintenanceDevice[], cat: MaintenanceCatalog, today: DateKey): DueItem[] {
  const window = Math.max(0, cat.windowDays);
  const monthStart = monthOf(today);
  const out: DueItem[] = [];
  const kinds = cat.kinds.filter((k) => k.active);
  for (const d of devices) {
    const st = cat.statuses.find((s) => s.key === d.status);
    if (!st || !st.isTracked || d.missing) continue;
    const anchor = d.lastShippedOn ?? d.firstShippedOn;
    const items: Omit<DueItem, "overdue" | "exchangeKey" | "exchangeOn">[] = [];
    for (const k of kinds) {
      const c = d.components.find((x) => x.kind === k.key);
      const rule = cat.rules.find((r) => r.model === d.model && r.component === k.key);
      if (!c && !rule && d.model !== null) continue;
      const recorded = c?.expiresOn ?? null;
      const byRule = rule && anchor ? addMonths(anchor, rule.intervalMonths) : null;
      const dueOn = recorded ?? byRule;
      items.push({ deviceId: d.id, sourceId: d.sourceId, serial: d.serial, model: d.model, market: d.market, status: st.key, isInField: st.isInField,
        isInStock: st.isInStock, component: k.key, componentOrder: k.sortOrder, dueOn,
        basis: recorded ? "recorded" : byRule ? "rule" : "unknown", actionOn: dueOn ? addDays(dueOn, -(rule?.leadDays ?? 0)) : null });
    }
    if (d.endOfLifeOn) {
      items.push({ deviceId: d.id, sourceId: d.sourceId, serial: d.serial, model: d.model, market: d.market, status: st.key, isInField: st.isInField,
        isInStock: st.isInStock, component: END_OF_LIFE, componentOrder: LAST, dueOn: d.endOfLifeOn, basis: "recorded", actionOn: d.endOfLifeOn });
    }
    items.sort((a, b) => (a.actionOn === null ? 1 : 0) - (b.actionOn === null ? 1 : 0) || (a.actionOn ?? "").localeCompare(b.actionOn ?? "")
      || a.componentOrder - b.componentOrder || a.component.localeCompare(b.component));
    let start: DateKey | null = null;
    for (const it of items) {
      if (it.actionOn === null) { out.push({ ...it, overdue: false, exchangeKey: null, exchangeOn: null }); continue; }
      if (start === null || daysBetween(start, it.actionOn) > window) start = it.actionOn;
      out.push({ ...it, overdue: it.actionOn < monthStart, exchangeKey: `${d.id}:${start}`, exchangeOn: start });
    }
  }
  return out;
}

/** An item with its bucket and its exchange's bucket (cma.maintenance_bucketed_of), after the filters */
interface Bucketed extends DueItem {
  m: string;
  mo: string;
  bucket: string | null;
  exchangeBucket: string | null;
}

function bucketed(items: readonly DueItem[], filter: MaintenanceFilter, today: DateKey): Bucketed[] {
  const monthStart = monthOf(today);
  const until = addMonths(filter.fromMonth, filter.months);
  const within = (k: DateKey | null) => k !== null && k >= filter.fromMonth && k < until;
  return items
    .filter((i) => filter.scope === null || (filter.scope === "field" && i.isInField) || (filter.scope === "stock" && i.isInStock))
    .filter((i) => filter.market === null || (i.market ?? "unknown") === filter.market)
    .filter((i) => filter.model === null || (i.model ?? "unknown") === filter.model)
    .map((i) => ({
      ...i, m: i.market ?? "unknown", mo: i.model ?? "unknown",
      bucket: i.overdue ? "overdue" : within(i.actionOn) ? monthOf(i.actionOn!) : null,
      exchangeBucket: i.exchangeOn !== null && i.exchangeOn < monthStart ? "overdue" : within(i.exchangeOn) ? monthOf(i.exchangeOn!) : null,
    }));
}

/** The order of markets and models: unknown last, then the catalog's sort order, then the code or key */
function orderBy(cat: MaintenanceCatalog) {
  const ms = new Map(cat.markets.map((m) => [m.code, m.sortOrder]));
  const ds = new Map(cat.models.map((m) => [m.key, m.sortOrder]));
  const big = Number.MAX_SAFE_INTEGER;
  return {
    market: (a: string, b: string) => (a === "unknown" ? 1 : 0) - (b === "unknown" ? 1 : 0) || (ms.get(a) ?? big) - (ms.get(b) ?? big) || (a < b ? -1 : a > b ? 1 : 0),
    model: (a: string, b: string) => (a === "unknown" ? 1 : 0) - (b === "unknown" ? 1 : 0) || (ds.get(a) ?? big) - (ds.get(b) ?? big) || (a < b ? -1 : a > b ? 1 : 0),
  };
}

const countBy = (keys: string[]) => keys.reduce<Record<string, number>>((o, k) => ({ ...o, [k]: (o[k] ?? 0) + 1 }), {});

/** The page as cma.maintenance_page_of answers it */
export function maintenanceReport(devices: readonly MaintenanceDevice[], cat: MaintenanceCatalog, filter: MaintenanceFilter, today: DateKey,
                                  isSetUp: boolean): MaintenanceReport {
  const b = bucketed(maintenanceItems(devices, cat, today), filter, today);
  const order = orderBy(cat);
  const keyOf = (bucket: string, m: string, mo: string) => `${bucket}|${m}|${mo}`;
  const keys = new Map<string, { bucket: string; market: string; model: string }>();
  for (const i of b) {
    if (i.bucket !== null) keys.set(keyOf(i.bucket, i.m, i.mo), { bucket: i.bucket, market: i.m, model: i.mo });
    if (i.exchangeBucket !== null) keys.set(keyOf(i.exchangeBucket, i.m, i.mo), { bucket: i.exchangeBucket, market: i.m, model: i.mo });
  }
  const cells: MaintenanceCell[] = [...keys.values()].map((k) => {
    const own = b.filter((i) => i.bucket === k.bucket && i.m === k.market && i.mo === k.model);
    const comps = own.filter((i) => i.component !== END_OF_LIFE);
    return {
      ...k, components: countBy(comps.map((i) => i.component)), componentItems: comps.length,
      endOfLife: own.filter((i) => i.component === END_OF_LIFE).length,
      exchanges: new Set(b.filter((i) => i.exchangeBucket === k.bucket && i.m === k.market && i.mo === k.model).map((i) => i.exchangeKey)).size,
    };
  }).sort((x, y) => (x.bucket === "overdue" ? 0 : 1) - (y.bucket === "overdue" ? 0 : 1) || (x.bucket < y.bucket ? -1 : x.bucket > y.bucket ? 1 : 0)
    || order.market(x.market, y.market) || order.model(x.model, y.model));
  const unknownItems = b.filter((i) => i.basis === "unknown");
  const unknownKeys = [...new Map(unknownItems.map((i) => [`${i.m}|${i.mo}`, { market: i.m, model: i.mo }])).values()]
    .sort((x, y) => order.market(x.market, y.market) || order.model(x.model, y.model));
  const tracked = devices.filter((d) => !d.missing && cat.statuses.some((s) => s.key === d.status && s.isTracked));
  const flags = (d: MaintenanceDevice) => cat.statuses.find((s) => s.key === d.status)!;
  const scoped = tracked.filter((d) => (filter.scope === null || (filter.scope === "field" && flags(d).isInField) || (filter.scope === "stock" && flags(d).isInStock))
    && (filter.market === null || (d.market ?? "unknown") === filter.market) && (filter.model === null || (d.model ?? "unknown") === filter.model));
  return {
    filter, currentMonth: monthOf(today), bundleWindowDays: Math.max(0, cat.windowDays), isSetUp,
    buckets: ["overdue", ...Array.from({ length: filter.months }, (_, g) => addMonths(filter.fromMonth, g))],
    componentKinds: cat.kinds.filter((k) => k.active).sort((x, y) => x.sortOrder - y.sortOrder || x.key.localeCompare(y.key)).map((k) => ({ key: k.key, name: k.name })),
    cells,
    unknown: unknownKeys.map((k) => {
      const own = unknownItems.filter((i) => i.m === k.market && i.mo === k.model);
      return { ...k, components: countBy(own.map((i) => i.component)), items: own.length };
    }),
    unknownItems: unknownItems.length,
    devices: scoped.length,
    markets: [...new Set(tracked.map((d) => d.market ?? "unknown"))].sort(order.market),
    models: [...new Set(tracked.map((d) => d.model ?? "unknown"))].sort(order.model)
      .map((key) => ({ key, name: cat.models.find((m) => m.key === key)?.name ?? null })),
  };
}

/** The device list of one cell as cma.maintenance_rows_of answers it */
export function maintenanceRows(devices: readonly MaintenanceDevice[], cat: MaintenanceCatalog, filter: MaintenanceFilter, today: DateKey, bucket: string,
                                view: MaintenanceView, limit: number): MaintenanceRows {
  const b = bucketed(maintenanceItems(devices, cat, today), filter, today).map((i) => ({
    ...i, rowBucket: i.basis === "unknown" ? "unknown" : view === "exchanges" ? i.exchangeBucket : i.bucket,
  }));
  const chosen = b.filter((i) => (bucket === "unknown" ? i.rowBucket === "unknown" : bucket === "all" ? i.rowBucket !== null && i.rowBucket !== "unknown" : i.rowBucket === bucket));
  const groups = new Map<string, typeof chosen>();
  for (const i of chosen) {
    const grp = view === "exchanges" && i.rowBucket !== "unknown" ? i.exchangeKey : "";
    const k = `${i.rowBucket}|${i.deviceId}|${grp}`;
    groups.set(k, [...(groups.get(k) ?? []), i]);
  }
  const minOf = (xs: (DateKey | null)[]) => xs.filter((x): x is DateKey => x !== null).sort()[0] ?? null;
  const rows = [...groups.entries()].map(([k, items]) => {
    const d = devices.find((x) => x.id === items[0]!.deviceId)!;
    const st = cat.statuses.find((s) => s.key === d.status);
    const sorted = [...items].sort((x, y) => x.componentOrder - y.componentOrder || x.component.localeCompare(y.component));
    const row: MaintenanceRow = {
      bucket: items[0]!.rowBucket!, deviceId: d.id, sourceId: d.sourceId, serial: d.serial, model: d.model ?? "unknown",
      modelName: cat.models.find((m) => m.key === d.model)?.name ?? null, market: d.market ?? "unknown", deviceStatus: d.status, deviceStatusName: st?.name ?? null,
      components: sorted.map((i) => i.component), dueOn: minOf(items.map((i) => i.dueOn)),
      bases: [...new Set(items.map((i) => i.basis))].sort() as MaintenanceBasis[], actionOn: minOf(items.map((i) => i.actionOn)),
      exchangeOn: minOf(items.map((i) => i.exchangeOn)), customerRef: d.customerRef, subscriptionRef: d.subscriptionRef, crmContactId: d.crmContactId,
      contactUrl: null, deviceUrl: null,
    };
    return { row, grp: k.split("|")[2] ?? "", rawMarket: d.market, rawModel: d.model };
  });
  const cmp = (a: string | null, b2: string | null) => (a === null ? (b2 === null ? 0 : 1) : b2 === null ? -1 : a < b2 ? -1 : a > b2 ? 1 : 0);
  rows.sort((x, y) => cmp(x.row.actionOn, y.row.actionOn) || (x.row.market === "unknown" ? 1 : 0) - (y.row.market === "unknown" ? 1 : 0)
    || cmp(x.rawMarket, y.rawMarket) || cmp(x.rawModel, y.rawModel) || cmp(x.row.serial, y.row.serial) || cmp(x.row.sourceId, y.row.sourceId) || cmp(x.grp, y.grp));
  return { total: rows.length, rows: rows.slice(0, limit).map((r) => r.row) };
}

// ---- the grid -----------------------------------------------------------------------------------

/** A cell's figure in the view: its planned exchanges, or its due components and devices at end of life */
export function cellValue(cell: MaintenanceCell | undefined, view: MaintenanceView): number {
  if (!cell) return 0;
  return view === "exchanges" ? cell.exchanges : cell.componentItems + cell.endOfLife;
}

export interface MaintenanceGridRow {
  market: string;
  model: string;
  modelName: string | null;
  cells: Record<string, MaintenanceCell | undefined>;
  total: number;
}

/**
 * The grid: one row per market and model holding a cell (in the filters' order: unknown last), the buckets as columns,
 * each row's total, and the total per bucket and overall
 */
export function maintenanceGrid(report: MaintenanceReport, view: MaintenanceView): { rows: MaintenanceGridRow[]; totals: Record<string, number>; total: number } {
  const mi = (m: string) => { const i = report.markets.indexOf(m); return i === -1 ? Number.MAX_SAFE_INTEGER : i; };
  const di = (m: string) => { const i = report.models.findIndex((x) => x.key === m); return i === -1 ? Number.MAX_SAFE_INTEGER : i; };
  const pairs = [...new Map(report.cells.map((c) => [`${c.market}|${c.model}`, { market: c.market, model: c.model }])).values()]
    .sort((a, b) => mi(a.market) - mi(b.market) || a.market.localeCompare(b.market) || di(a.model) - di(b.model) || a.model.localeCompare(b.model));
  const rows = pairs.map((p) => {
    const cells = Object.fromEntries(report.buckets.map((bk) => [bk, report.cells.find((c) => c.bucket === bk && c.market === p.market && c.model === p.model)]));
    return { ...p, modelName: report.models.find((m) => m.key === p.model)?.name ?? null, cells,
      total: report.buckets.reduce((s, bk) => s + cellValue(cells[bk], view), 0) };
  });
  const totals = Object.fromEntries(report.buckets.map((bk) => [bk, rows.reduce((s, r) => s + cellValue(r.cells[bk], view), 0)]));
  return { rows, totals, total: rows.reduce((s, r) => s + r.total, 0) };
}

/** A cell's title: its items per kind, the devices at end of life and the planned exchanges, in the reader's words */
export function cellTitle(cell: MaintenanceCell | undefined, kinds: readonly { key: string; name: string }[], labels: { endOfLife: string; exchanges: string }): string {
  if (!cell) return "";
  const parts = kinds.filter((k) => (cell.components[k.key] ?? 0) > 0).map((k) => `${k.name} ${cell.components[k.key]}`);
  if (cell.endOfLife > 0) parts.push(`${labels.endOfLife} ${cell.endOfLife}`);
  parts.push(`${labels.exchanges} ${cell.exchanges}`);
  return parts.join(" · ");
}
