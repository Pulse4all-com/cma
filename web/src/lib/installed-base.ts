/**
 * Assets → Installed base as the "now" view (addition 0009f; Martin, 8 November 2026, D1 to D7): what the page decides on
 * its own, pure (no database, no React). The address: the market (K), the page filters f_model (D) and f_status (S), the
 * open panel (one at a time, as address state so Back, Forward and a shared link work), the serial search, the list's
 * sort and page. The donut's slices (the smallest models grouped as Other above five), the SVG arcs, the per-market stacks
 * in the donut's colours (the style guide's series order, 7.7, assigned by position from the data: never a model name
 * in code), a breakdown's chart (a donut at five categories or fewer, else bars sorted by size), and the lists' shape (50
 * rows, three columns kept for the files). The figures themselves come from the stored current take (lib/flash
 * narrowDocument) and the records from cma.flash_rows.
 */
import { FLASH_ADDRESS, flashHref, overviewOf, parseMarket, parseSort, type FlashDocRow, type FlashOverviewDef } from "@/lib/flash";

export const INSTALLED_BASE_PATH = "/reports/installed-base" as const;
export const INSTALLED_BASE_KEY = "installed_base" as const;
/** Rows a list page shows on Assets → Installed base (D5); the files keep every row up to the tenant's flash.file_max_rows */
export const INSTALLED_BASE_PAGE_ROWS = 50;
/** The columns the page's lists leave out (D5: References, Missing references and Subscription linked); their files keep them */
export const INSTALLED_BASE_HIDDEN_COLUMNS: readonly string[] = ["refs", "missing_refs", "link"];
/** The dims the page narrows the whole document by (D3): the model and the operational status; the market is the page's own (K) */
export const INSTALLED_BASE_PAGE_FILTERS: readonly string[] = ["model", "status"];
/** The most slices a donut shows before the smallest models are grouped as Other (D2) */
export const DONUT_MAX_SLICES = 5;
/** The key of the grouped slice; never a model's key (a catalog key is lower-case letters, digits and _, and never starts with a dash) */
export const OTHER_KEY = "-other";

/** The panels (D4), one open at a time: the two breakdowns from the take, the three lists read on demand */
export type InstalledBasePanel = "breakdown" | "subscription" | "records" | "past_due" | "unlinked";
export const INSTALLED_BASE_PANELS: readonly InstalledBasePanel[] = ["breakdown", "subscription", "records", "past_due", "unlinked"];
/** The panels that read a list (cma.flash_rows); the breakdowns render from the document already read */
export const LIST_PANELS: readonly InstalledBasePanel[] = ["records", "past_due", "unlinked"];

/** The address keys of the page beyond Flash's: the open panel and the serial searched */
export const INSTALLED_BASE_ADDRESS = { panel: "panel", serial: "serial" } as const;

export function parsePanel(value: unknown): InstalledBasePanel | null {
  return typeof value === "string" && (INSTALLED_BASE_PANELS as readonly string[]).includes(value) ? (value as InstalledBasePanel) : null;
}

/** The serial searched (D7): trimmed, 1 to 100 characters; anything else is no search */
export function parseSerial(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const v = value.trim();
  return v.length >= 1 && v.length <= 100 ? v : null;
}

/**
 * The list filters a list panel adds to the page's filters (D6): the records none, the devices past due the measure
 * components_past_due (a device with at least one item past due), the devices in the field without a linked subscription
 * the database's rule (without_subscription_ref: the data-quality check's devices, one implementation)
 */
export function panelListFilters(panel: InstalledBasePanel): Record<string, string> {
  if (panel === "past_due") return { measure: "components_past_due" };
  if (panel === "unlinked") return { without_subscription_ref: "true" };
  return {};
}

/** The breakdown set a breakdown panel shows */
export function panelSet(panel: InstalledBasePanel, def: FlashOverviewDef): readonly string[] | null {
  if (panel === "breakdown") return def.sets.find((s) => s.includes("status") && s.includes("warehouse")) ?? null;
  if (panel === "subscription") return def.sets.find((s) => s.includes("subscription_status")) ?? null;
  return null;
}

/** A link on the page: its address keys, in one place */
export function installedBaseHref(query: Record<string, string>): string {
  return flashHref(INSTALLED_BASE_PATH, query);
}

/** The page's state from its address (the overview is fixed: the installed base) */
export interface InstalledBaseState {
  def: FlashOverviewDef;
  market: string | null;
  marketProblem: boolean;
  /** Every list filter of the address: the page filters among them (model, status), the market, a measure, the list's own */
  filters: Record<string, string>;
  /** The page filters alone (D3): what narrows the document */
  pageFilters: Record<string, string>;
  panel: InstalledBasePanel | null;
  serial: string | null;
  sort: string;
  descending: boolean;
  pageNo: number;
  /** The address keys every link keeps: the market and the page filters */
  base: Record<string, string>;
}

export function installedBaseState(sp: Record<string, string | string[] | undefined>,
  parseFilters: (def: FlashOverviewDef, read: (key: string) => string | undefined) => Record<string, string>): InstalledBaseState {
  const def = overviewOf(INSTALLED_BASE_KEY)!;
  const one = (k: string): string | undefined => { const v = sp[k]; return Array.isArray(v) ? v[0] : v; };
  const market = parseMarket(one(FLASH_ADDRESS.market));
  const filters = parseFilters(def, one);
  if (market) filters.market = market;
  const pageFilters = Object.fromEntries(Object.entries(filters).filter(([k]) => INSTALLED_BASE_PAGE_FILTERS.includes(k)));
  const { sort, descending } = parseSort(def, one(FLASH_ADDRESS.sort), one(FLASH_ADDRESS.dir));
  const pageNo = Math.max(1, Math.min(10_000, Number.parseInt(one(FLASH_ADDRESS.page) ?? "1", 10) || 1));
  const base: Record<string, string> = { ...(market ? { market } : {}),
    ...Object.fromEntries(Object.entries(pageFilters).map(([k, v]) => [`${FLASH_ADDRESS.filterPrefix}${k}`, v])) };
  return {
    def, market, marketProblem: one(FLASH_ADDRESS.market) !== undefined && one(FLASH_ADDRESS.market) !== "" && market === null,
    filters, pageFilters, panel: parsePanel(one(INSTALLED_BASE_ADDRESS.panel)), serial: parseSerial(one(INSTALLED_BASE_ADDRESS.serial)),
    sort, descending, pageNo, base,
  };
}

// ---- The donut and the stacks -------------------------------------------------------------------------------------------

/** The style guide's series order (7.7): Deep Blue, Leaf Green, Light Blue, Denim, Soft Rose, Inkt; as text colour tokens (fill="currentColor") */
export const SERIES_CLASSES: readonly string[] = ["text-p4a-deepblue", "text-p4a-green", "text-p4a-lightblue", "text-p4a-denim", "text-p4a-rose", "text-p4a-inkt"];

export function seriesClass(colour: number): string {
  return SERIES_CLASSES[Math.max(0, Math.min(SERIES_CLASSES.length - 1, colour))]!;
}

export interface Slice {
  /** The model's key, or OTHER_KEY for the grouped smallest models */
  key: string;
  /** The model keys the slice holds (one, or the grouped ones) */
  keys: string[];
  value: number;
  /** The slice's share of the total, 0 to 1 (0 when the total is 0) */
  share: number;
  /** The index in the series order, 0 first */
  colour: number;
}

/**
 * The donut's slices from the split's parts (lib/flash splitOf: every model of the register's order with zeros, then any
 * other above 0), in that order with the colours assigned by position; above max parts the smallest are grouped as Other,
 * last, in the colour after the kept ones. Ties keep the order given. The total is the parts' sum (In the field)
 */
export function donutSlices(parts: readonly { key: string; value: number }[], max = DONUT_MAX_SLICES): { slices: Slice[]; total: number } {
  const total = parts.reduce((n, p) => n + p.value, 0);
  const share = (v: number) => (total > 0 ? v / total : 0);
  if (parts.length <= max) {
    return { total, slices: parts.map((p, i) => ({ key: p.key, keys: [p.key], value: p.value, share: share(p.value), colour: i })) };
  }
  // the kept ones: the largest, ties by their order; the rest grouped
  const ranked = parts.map((p, i) => ({ ...p, i })).sort((a, b) => b.value - a.value || a.i - b.i);
  const keptIndex = new Set(ranked.slice(0, max - 1).map((p) => p.i));
  const kept = parts.filter((_, i) => keptIndex.has(i));
  const rest = parts.filter((_, i) => !keptIndex.has(i));
  const slices: Slice[] = kept.map((p, i) => ({ key: p.key, keys: [p.key], value: p.value, share: share(p.value), colour: i }));
  const otherValue = rest.reduce((n, p) => n + p.value, 0);
  slices.push({ key: OTHER_KEY, keys: rest.map((p) => p.key), value: otherValue, share: share(otherValue), colour: kept.length });
  return { total, slices };
}

/** The SVG path of a ring sector from one angle to another (radians from twelve o'clock, clockwise); a full ring as two halves */
export function arcPath(cx: number, cy: number, outer: number, inner: number, start: number, end: number): string {
  const full = end - start >= Math.PI * 2 - 1e-9;
  if (full) return `${arcPath(cx, cy, outer, inner, start, start + Math.PI)} ${arcPath(cx, cy, outer, inner, start + Math.PI, start + Math.PI * 2)}`;
  const pt = (r: number, a: number) => [cx + r * Math.sin(a), cy - r * Math.cos(a)] as const;
  const [x1, y1] = pt(outer, start);
  const [x2, y2] = pt(outer, end);
  const [x3, y3] = pt(inner, end);
  const [x4, y4] = pt(inner, start);
  const large = end - start > Math.PI ? 1 : 0;
  const f = (n: number) => n.toFixed(2);
  return `M${f(x1)},${f(y1)} A${outer},${outer} 0 ${large} 1 ${f(x2)},${f(y2)} L${f(x3)},${f(y3)} A${inner},${inner} 0 ${large} 0 ${f(x4)},${f(y4)} Z`;
}

/** Each slice's arc for a donut of the given size and ring thickness; a slice of 0 draws nothing (an empty path) */
export function donutArcs(slices: readonly Slice[], size = 176, thickness = 30): { slice: Slice; d: string }[] {
  const total = slices.reduce((n, s) => n + s.value, 0);
  const c = size / 2;
  const outer = size / 2;
  const inner = outer - thickness;
  let angle = 0;
  return slices.map((slice) => {
    if (total <= 0 || slice.value <= 0) return { slice, d: "" };
    const sweep = (slice.value / total) * Math.PI * 2;
    const d = arcPath(c, c, outer, inner, angle, angle + sweep);
    angle += sweep;
    return { slice, d };
  });
}

export interface MarketStack {
  market: string;
  total: number;
  parts: { key: string; value: number; colour: number }[];
}

/**
 * In the field per market, stacked per model in the donut's colours (D2): from the rows of the set that carries the
 * model with every measure ([market, status, model, warehouse, link]), the measure summed per market and model, each
 * model's part in its slice's colour (a grouped model in Other's). The markets in the order of the rows' first sight,
 * which is the document's (sorted by dims); a market without the measure has no stack
 */
export function marketStacks(rows: readonly FlashDocRow[], set: readonly string[], measure: string, slices: readonly Slice[]): MarketStack[] {
  const colourOf = new Map<string, number>();
  for (const s of slices) for (const k of s.keys) colourOf.set(k, s.colour);
  const keyOf = (model: string) => slices.find((s) => s.keys.includes(model))?.key ?? model;
  const byMarket = new Map<string, Map<string, number>>();
  for (const r of rows) {
    const keys = Object.keys(r.dims);
    if (keys.length !== set.length || !set.every((d) => d in r.dims)) continue;
    const v = r.measures[measure];
    if (typeof v !== "number" || typeof r.dims.market !== "string" || typeof r.dims.model !== "string") continue;
    const m = byMarket.get(r.dims.market) ?? new Map<string, number>();
    const k = keyOf(r.dims.model);
    m.set(k, (m.get(k) ?? 0) + v);
    byMarket.set(r.dims.market, m);
  }
  return [...byMarket].map(([market, parts]) => ({
    market,
    total: [...parts.values()].reduce((n, v) => n + v, 0),
    // the parts in the slices' order, so every market stacks its models alike
    parts: slices.filter((s) => parts.has(s.key)).map((s) => ({ key: s.key, value: parts.get(s.key) ?? 0, colour: s.colour })),
  }));
}

/** A breakdown's chart of its totals (D4): one figure per value of a dim, bars sorted by size, or a donut at five categories or fewer */
export interface BreakdownChart {
  kind: "donut" | "bars";
  dim: string;
  measure: string;
  items: { key: string; value: number; share: number; colour: number }[];
  total: number;
}

export function breakdownChart(rows: readonly FlashDocRow[], set: readonly string[], dim: string, measure: string): BreakdownChart {
  const sums = new Map<string, number>();
  for (const r of rows) {
    const keys = Object.keys(r.dims);
    if (keys.length !== set.length || !set.every((d) => d in r.dims)) continue;
    const v = r.measures[measure];
    const k = r.dims[dim];
    if (typeof v !== "number" || typeof k !== "string") continue;
    sums.set(k, (sums.get(k) ?? 0) + v);
  }
  const total = [...sums.values()].reduce((n, v) => n + v, 0);
  const ranked = [...sums].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
  const kind: BreakdownChart["kind"] = ranked.length <= DONUT_MAX_SLICES ? "donut" : "bars";
  return { kind, dim, measure, total,
    items: ranked.map(([key, value], i) => ({ key, value, share: total > 0 ? value / total : 0, colour: kind === "donut" ? i : 0 })) };
}

/** A share of the largest for a bar's width, 0 to 1 */
export function widthShare(value: number, max: number): number {
  return max > 0 && value > 0 ? Math.min(1, value / max) : 0;
}

/** The operational status filter's choices (D3): the catalog's statuses from the document's labels and rows, by name; unknown last */
export function statusChoicesOf(labels: Readonly<Record<string, Readonly<Record<string, string>>>> | null | undefined,
  rows: readonly FlashDocRow[]): { key: string; name: string | null }[] {
  const names = labels?.status ?? {};
  const keys = new Set<string>(Object.keys(names));
  for (const r of rows) if (typeof r.dims.status === "string") keys.add(r.dims.status);
  return [...keys].sort((a, b) => (a === "unknown" ? 1 : 0) - (b === "unknown" ? 1 : 0) || (names[a] ?? a).localeCompare(names[b] ?? b) || a.localeCompare(b))
    .map((key) => ({ key, name: key === "unknown" ? null : names[key] ?? null }));
}
