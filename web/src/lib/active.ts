/**
 * Customers → Active (addition 0009l, brief B35 with addendum A, Martin, 11 November 2026; docs/definitions.md, Active
 * customer terms): the pure logic of the page. The database computes every figure (cma.active_top, cma.active_rest, cma.active_rows);
 * this module holds what the screen, the API's parameter checks, the file and the mock share: the filter and its
 * address, the range and the cohort grouping, the list's sort keys, the placeholders with what will feed them, and the
 * arithmetic the charts need (a change line, a sparkline's path, the heatmap's colour scale, a split's whole percentages). It also
 * mirrors the database's pure functions (the unit factor per billing interval, the active spells of a set of holding
 * intervals, Kaplan–Meier in whole months, the month ends and the customer cohorts) so the mock can build a document
 * of the same shape and verify:active can prove them against a brute force. No runtime imports beyond types: server
 * and client components alike use it.
 */
import type {
  ActiveChannel, ActiveCohort, ActiveComparisonRow, ActiveCurve, ActiveCurvePoint, ActiveFilter, ActiveGrouping, ActiveMeasure, ActiveSlotKey, ActiveSort,
} from "@/lib/data";

/** The acquisition channels in the page's order: Indirect (the call center), Direct (self-service), Unknown */
export const ACTIVE_CHANNELS: readonly ActiveChannel[] = ["indirect", "direct", "unknown"];
export const ACTIVE_GROUPINGS: readonly ActiveGrouping[] = ["month", "quarter"];
/** The history's range in months; all: as far back as customers.history_months allows (the database caps it) */
export const ACTIVE_RANGES = ["12", "24", "36", "all"] as const;
export type ActiveRange = (typeof ACTIVE_RANGES)[number];
export const ACTIVE_DEFAULT_RANGE: ActiveRange = "24";
/** The list's sort keys (cma.active_rows), the first one the default, descending */
export const ACTIVE_SORTS: readonly ActiveSort[] = [
  "monthly_amount", "clv", "store_customer", "store", "market", "segment", "customer_start", "age_months", "subscriptions", "devices", "channel", "level",
];
export const ACTIVE_PAGE_SIZE = 50;

/**
 * The fixed heights of the page's data panels in pixels (decision D15 of addendum B): a panel's outline while its read is
 * on its way and its rendered body take the same height, at 1280 and at 1920 px alike, so nothing moves when the data
 * arrives (verify:layout compares the two). A table scrolls inside its panel under its header row. One panel differs
 * (ACTIVE_FITTING, Martin's review of 12 November 2026): the markets' table is as high as its rows and at most this
 * high, so no space is left under its totals row; the outline cannot know the markets' count before the read, so the
 * page under a short markets table moves up once, by the difference (open for Martin: docs/open-decisions.md). On
 * paper every panel takes its own height
 */
export const ACTIVE_PANEL_HEIGHT = {
  tiles: 372, churn: 40, hero: 404, flow: 344, amount: 344, markets: 384, comparison: 560, survival: 448, age: 328, channel: 328,
  cohortTable: 424, cohortCurves: 348, mix: 232, devices: 376, list: 656,
} as const;
export type ActivePanel = keyof typeof ACTIVE_PANEL_HEIGHT;
/** The streamed parts of the page (decisions D15 and D16): above the fold, the live present of the tiles, below the fold, the customer list */
export const ACTIVE_PARTS = ["top", "now", "rest", "list"] as const;
/** The panels that hold a table: the table's container scrolls inside the panel's fixed height (and can be reached with the keyboard) */
export const ACTIVE_SCROLLING: readonly ActivePanel[] = ["markets", "comparison", "cohortTable", "list"];
/** The table panel whose height follows its table (at most the panel's own): the markets, whose rows are few for a tenant with few markets */
export const ACTIVE_FITTING: readonly ActivePanel[] = ["markets"];
/** A cursor of the customer list: the CMA's own id of a customer, nothing else (it rides in the address) */
export const ACTIVE_CURSOR = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
/** The splits of the survival curves and of the cohorts' pooled retention */
export const ACTIVE_SPLITS = ["segment", "channel"] as const;
export type ActiveSplit = (typeof ACTIVE_SPLITS)[number];
export const ACTIVE_COHORT_SPLITS = ["none", "segment", "channel"] as const;
export type ActiveCohortSplitChoice = (typeof ACTIVE_COHORT_SPLITS)[number];

/**
 * The placeholders (decision D5): figures the Workspace cannot compute yet. Each reserves its slot, its catalog key and
 * its definition (Pending), and names the kinds of source that will feed it; none carries a number
 */
export const ACTIVE_SLOTS: readonly { key: ActiveSlotKey; metric: string; fedBy: readonly ("subscription_events" | "ad_spend" | "paid_hours" | "hourly_rate" | "this_page")[] }[] = [
  { key: "churn_rate", metric: "active.churn_rate", fedBy: ["subscription_events"] },
  { key: "cac", metric: "active.cac", fedBy: ["ad_spend", "paid_hours", "hourly_rate"] },
  { key: "cost_per_subscription", metric: "active.cost_per_subscription", fedBy: ["ad_spend", "paid_hours", "hourly_rate"] },
  { key: "clv_projected", metric: "active.clv_projected", fedBy: ["this_page", "subscription_events"] },
  { key: "clv_to_cac", metric: "active.clv_to_cac", fedBy: ["this_page", "ad_spend"] },
  { key: "payback_months", metric: "active.payback_months", fedBy: ["this_page", "ad_spend"] },
];

/** The comparison's measures in the table's order, with their catalog key */
export const ACTIVE_MEASURE_METRIC: Readonly<Record<ActiveMeasure, string>> = {
  customers: "active.active_customers", share: "active.segment_difference", lifetime_median: "active.customer_lifetime_median",
  retention: "active.retention", median_age: "active.customer_age_median", clv_average: "active.clv_realised_average",
  clv_median: "active.clv_realised_median", clv_per_month: "active.clv_realised_per_month", average_monthly_amount: "active.average_monthly_amount",
  subscriptions_per_customer: "active.subscriptions_per_customer", devices_per_customer: "active.devices_per_customer",
  devices_from_share: "active.device_from_share", indirect_share: "active.acquisition_channel_share",
};

/** A difference with its sign, always written: +2, −2, 0 */
export function signed(text: string, value: number): string {
  return value > 0 ? `+${text}` : value < 0 ? `−${text.replace(/^[-−]/, "")}` : text;
}

const MARKET = /^([A-Z]{2}|unknown)$/;
const SEGMENT = /^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$/;

/** The filter from an address or a query: a market's code or unknown, a segment's code or unknown, a channel; what is out of its form is named */
export function parseActiveFilter(market: unknown, segment: unknown, channel: unknown): { filter: ActiveFilter; problem: null | "market" | "segment" | "channel" } {
  const one = (v: unknown) => (typeof v === "string" && v !== "" ? v : null);
  const m = one(market);
  const s = one(segment);
  const c = one(channel);
  const filter: ActiveFilter = {
    market: m !== null && MARKET.test(m) ? m : null,
    segment: s !== null && SEGMENT.test(s) ? s : null,
    channel: c !== null && (ACTIVE_CHANNELS as readonly string[]).includes(c) ? (c as ActiveChannel) : null,
  };
  const problem = m !== null && filter.market === null ? "market" : s !== null && filter.segment === null ? "segment" : c !== null && filter.channel === null ? "channel" : null;
  return { filter, problem };
}

/** The filter's part of an address: only what is chosen */
export function activeQuery(filter: ActiveFilter): Record<string, string> {
  return { ...(filter.market ? { market: filter.market } : {}), ...(filter.segment ? { segment: filter.segment } : {}), ...(filter.channel ? { channel: filter.channel } : {}) };
}

export function activeRangeOf(value: unknown): ActiveRange {
  return typeof value === "string" && (ACTIVE_RANGES as readonly string[]).includes(value) ? (value as ActiveRange) : ACTIVE_DEFAULT_RANGE;
}

export function activeGroupingOf(value: unknown): ActiveGrouping {
  return value === "quarter" ? "quarter" : "month";
}

export function activeSortOf(value: unknown): ActiveSort {
  return typeof value === "string" && (ACTIVE_SORTS as readonly string[]).includes(value) ? (value as ActiveSort) : "monthly_amount";
}

/** A month's first day n months before a date's month (n may be 0), as YYYY-MM-01 */
export function monthsBack(today: string, n: number): string {
  const y = Number(today.slice(0, 4));
  const m = Number(today.slice(5, 7)) - 1 - n;
  const d = new Date(Date.UTC(y, m, 1));
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}-01`;
}

/** The history's first month for a range: the month that many months back; null for all (the database starts at its cap) */
export function fromMonthOf(range: ActiveRange, today: string): string | null {
  return range === "all" ? null : monthsBack(today, Number(range));
}

/** The next value of a list after the current one, round: what a switch's letter moves to */
export function nextIn<T>(list: readonly T[], current: T): T {
  return list[(list.indexOf(current) + 1) % list.length]!;
}

// ---- the database's pure functions, mirrored ----------------------------------------------------------------------------

/**
 * The factor that turns an amount per billing cycle into an amount per month (cma.active_month_factor_of): a day
 * 365.25/12, a week 365.25/84, a month 1, a year 1/12, each divided by the cycle's count; null without either
 */
export function unitFactor(interval: string | null, count: number | null): number | null {
  if (count === null || !Number.isFinite(count) || count < 1) return null;
  const per = interval === "day" ? 365.25 / 12 : interval === "week" ? 365.25 / 84 : interval === "month" ? 1 : interval === "year" ? 1 / 12 : null;
  return per === null ? null : per / count;
}

/** A subscription's billing interval in the mix's words (cma.active_billing_of) */
export function billingOf(interval: string | null, count: number | null): "monthly" | "yearly" | "other" | "unknown" {
  if (interval === null || count === null) return "unknown";
  if (interval === "month" && count === 1) return "monthly";
  if ((interval === "year" && count === 1) || (interval === "month" && count === 12)) return "yearly";
  return "other";
}

/** A holding interval [start, end): end null while it lasts; times as numbers (any unit, the same for all) */
export interface Interval { key: string; start: number | null; end: number | null }
export interface Spell { key: string; start: number; end: number | null }

/**
 * The active spells of a set of holding intervals (cma.active_spells_from): per key the maximal stretches in which at
 * least one of its intervals holds. +1 at every start and −1 at every end, a running sum per key in time order (a start
 * before an end of the same instant, so an interval that begins where another ends continues the spell); a spell runs
 * from the sum's 0 to 1 until its 1 to 0. An interval without a start, or ending at or before its start, is left out
 */
export function spellsOf(intervals: readonly Interval[]): Spell[] {
  const byKey = new Map<string, { at: number; d: 1 | -1 }[]>();
  for (const iv of intervals) {
    if (iv.start === null || (iv.end !== null && iv.end <= iv.start)) continue;
    const events = byKey.get(iv.key) ?? [];
    events.push({ at: iv.start, d: 1 });
    if (iv.end !== null) events.push({ at: iv.end, d: -1 });
    byKey.set(iv.key, events);
  }
  const spells: Spell[] = [];
  for (const [key, events] of [...byKey.entries()].sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))) {
    events.sort((a, b) => a.at - b.at || b.d - a.d);
    let n = 0;
    let open: number | null = null;
    for (const e of events) {
      n += e.d;
      if (e.d === 1 && n === 1) open = e.at;
      else if (e.d === -1 && n === 0 && open !== null) {
        spells.push({ key, start: open, end: e.at });
        open = null;
      }
    }
    if (open !== null) spells.push({ key, start: open, end: null });
  }
  return spells;
}

/**
 * Kaplan–Meier over spells in whole months (cma.active_km_from): lengths[i] a spell's length, or its age today while it
 * lasts; ended[i] whether it ended (an event at its length) or is still active (censored at its age). Per age from 0 to
 * the longest: the spells at risk (of at least that length), the events (the ended ones of exactly that length), the
 * survival (the product, over the ages up to and including it, of 1 − events / at risk), which is Retention (customer)
 * at that age
 */
export function kaplanMeier(lengths: readonly number[], ended: readonly boolean[]): ActiveCurvePoint[] {
  const valid = lengths.map((l, i) => ({ l, e: ended[i] === true })).filter((x) => Number.isInteger(x.l) && x.l >= 0);
  if (valid.length === 0) return [];
  const longest = Math.max(...valid.map((x) => x.l));
  const points: ActiveCurvePoint[] = [];
  let s = 1;
  for (let age = 0; age <= longest; age++) {
    const atRisk = valid.filter((x) => x.l >= age).length;
    const events = valid.filter((x) => x.e && x.l === age).length;
    if (atRisk > 0) s *= 1 - events / atRisk;
    points.push({ age, atRisk, events, survival: round6(s) });
  }
  return points;
}

const round6 = (x: number) => Math.round(x * 1e6) / 1e6;

/** A curve's summary (cma.active_km_json): the spells, the ended ones, the longest observed age, the median (the first age whose survival is at most 0.5; null: not reached) */
export function curveOf(lengths: readonly number[], ended: readonly boolean[], value?: string): ActiveCurve {
  const curve = kaplanMeier(lengths, ended);
  const median = curve.find((p) => p.survival <= 0.5)?.age ?? null;
  return {
    ...(value === undefined ? {} : { value }), spells: lengths.length, ended: ended.filter(Boolean).length,
    longest: curve.length > 0 ? curve[curve.length - 1]!.age : null, median, curve,
  };
}

/** Retention (customer) at an age: the curve's survival at it; null where no spell is that old */
export function retentionAt(curve: Pick<ActiveCurve, "curve">, months: number): number | null {
  const p = curve.curve.find((x) => x.age === months);
  return p && p.atRisk > 0 ? p.survival : null;
}

// ---- what the screen draws ----------------------------------------------------------------------------------------------

/** A figure's change against an earlier one: its direction, the difference and the share of the earlier figure; none without either */
export function changeAgainst(value: number | null | undefined, previous: number | null | undefined): { direction: "up" | "down" | "flat" | "none"; delta: number | null; pct: number | null } {
  if (value === null || value === undefined || previous === null || previous === undefined) return { direction: "none", delta: null, pct: null };
  const delta = value - previous;
  return { direction: delta > 0 ? "up" : delta < 0 ? "down" : "flat", delta, pct: previous !== 0 ? delta / Math.abs(previous) : null };
}

/** A cohort is Mature at an age once every customer in it is that old; its retention at that age is then a share of its size */
export function cohortShare(cohort: Pick<ActiveCohort, "started">, age: { stillActive: number; mature: boolean }): number | null {
  return age.mature && cohort.started > 0 ? age.stillActive / cohort.started : null;
}

/**
 * The newest cohorts a retention curve can be drawn for: those Mature at two ages or more (a cohort Mature at one age
 * is a lone dot, not a line)
 */
export function matureCohorts(cohorts: readonly ActiveCohort[], n: number): ActiveCohort[] {
  return cohorts.filter((c) => c.started > 0 && c.ages.filter((a) => a.mature).length >= 2).slice(0, n);
}

/**
 * A line's place in the series (Pulse4all-Style 7.7's palette without Soft Rose, too light as a line on white): Deep
 * Blue, Leaf Green, Denim, Inkt, Light Blue as indexes of the charts' series order; from the sixth line on the colours
 * come round again, dashed, so colour is never the only signal
 */
export const LINE_COLOURS = [0, 1, 3, 5, 2] as const;
export function lineStyle(i: number): { colour: number; dashed: boolean } {
  return { colour: LINE_COLOURS[i % LINE_COLOURS.length]!, dashed: i >= LINE_COLOURS.length };
}

/**
 * Whole percentages of a split that add up to 100 (the largest-remainder method): each part's share rounded down, the
 * points left over given to the parts with the largest remainders (the earlier part first on a tie). All zeros where
 * the parts sum to nothing; a negative or non-finite part counts as nothing
 */
export function wholePercents(parts: readonly number[]): number[] {
  const clean = parts.map((v) => (Number.isFinite(v) && v > 0 ? v : 0));
  const total = clean.reduce((a, b) => a + b, 0);
  if (total <= 0) return clean.map(() => 0);
  const exact = clean.map((v) => (v / total) * 100);
  const floor = exact.map((v) => Math.floor(v + 1e-9));
  let left = 100 - floor.reduce((a, b) => a + b, 0);
  const order = exact.map((v, i) => ({ i, rest: v - floor[i]! })).sort((a, b) => b.rest - a.rest || a.i - b.i);
  for (const o of order) {
    if (left <= 0) break;
    floor[o.i]! += 1;
    left -= 1;
  }
  return floor;
}

/**
 * A text with a count in it, in its singular or plural form: the template holds both as "one|many" ("{n} month|{n}
 * months"; a template without a bar has one form), the singular for exactly 1 (and −1). shown is what stands for {n}
 * (the formatted number); the count decides the form
 */
export function counted(template: string, n: number, shown?: string): string {
  const bar = template.indexOf("|");
  const form = bar < 0 ? template : Math.abs(n) === 1 ? template.slice(0, bar) : template.slice(bar + 1);
  return form.replace("{n}", shown ?? String(n));
}

/** A cohort's label: its month ("Mar 2026") or its quarter ("Q1 2026") */
export function cohortLabel(cohort: string, grouping: ActiveGrouping, locale: string): string {
  const y = Number(cohort.slice(0, 4));
  const m = Number(cohort.slice(5, 7));
  if (grouping === "quarter") return `Q${Math.floor((m - 1) / 3) + 1} ${y}`;
  return new Intl.DateTimeFormat(locale === "nl" ? "nl-NL" : "en-GB", { month: "short", year: "numeric", timeZone: "UTC" }).format(new Date(Date.UTC(y, m - 1, 1)));
}

/** A month's short label for an axis: "Nov" with the year on January and on the first point ("Jan 2026") */
export function monthLabel(month: string, locale: string, withYear: boolean): string {
  const d = new Date(Date.UTC(Number(month.slice(0, 4)), Number(month.slice(5, 7)) - 1, 1));
  return new Intl.DateTimeFormat(locale === "nl" ? "nl-NL" : "en-GB", withYear ? { month: "short", year: "numeric", timeZone: "UTC" } : { month: "short", timeZone: "UTC" }).format(d);
}

/**
 * The heatmap's colour for a share still active (Pulse4all-Style 7.7 and 7.8): one hue, from Background Blue (#EAF4FC,
 * 0 %) to Deep Blue (#265BA4, 100 %) by the share's value in whole percents, never lighter for a higher share. The text
 * is Inkt on the light part and white only where the background is at least as dark as Denim (#3B6FB3). Between the
 * two lies a band of blues on which neither Inkt nor white reaches a contrast of 4.5:1; a share whose colour would fall
 * in it takes the band's nearer edge (the lower half the light edge, the upper half the dark one), so every step reads
 * at 4.5:1 or more (verify:active proves each of the 101). The share and the count stand in every cell; the colour only
 * helps the eye
 */
export const HEAT_FROM = [0xea, 0xf4, 0xfc] as const;
export const HEAT_TO = [0x26, 0x5b, 0xa4] as const;
export const HEAT_INKT = [0x0b, 0x13, 0x3d] as const;
export const HEAT_DENIM = [0x3b, 0x6f, 0xb3] as const;
type Rgb = readonly [number, number, number];

/** The relative luminance of a colour (WCAG 2) */
export function luminance(rgb: Rgb): number {
  const [r, g, b] = rgb.map((v) => {
    const c = v / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  }) as [number, number, number];
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/** The contrast ratio of two colours (WCAG 2) */
export function contrast(a: Rgb, b: Rgb): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x) as [number, number];
  return (hi + 0.05) / (lo + 0.05);
}

const heatAt = (percent: number): Rgb => HEAT_FROM.map((from, i) => Math.round(from + ((HEAT_TO[i]! - from) * percent) / 100)) as unknown as Rgb;
const HEAT_WHITE: Rgb = [255, 255, 255];
/** The last whole percent whose colour still carries Inkt at 4.5:1, and the first one at least as dark as Denim */
export const HEAT_LIGHT_EDGE = Math.max(...Array.from({ length: 101 }, (_, p) => p).filter((p) => contrast(heatAt(p), HEAT_INKT) >= 4.5));
export const HEAT_DARK_EDGE = Math.min(...Array.from({ length: 101 }, (_, p) => p).filter((p) => luminance(heatAt(p)) <= luminance(HEAT_DENIM)));

export function heatColour(share: number | null): { percent: number; background: string; text: "inkt" | "white"; rgb: Rgb } | null {
  if (share === null || !Number.isFinite(share)) return null;
  const percent = Math.round(Math.min(1, Math.max(0, share)) * 100);
  const at = percent <= HEAT_LIGHT_EDGE || percent >= HEAT_DARK_EDGE ? percent : percent < (HEAT_LIGHT_EDGE + HEAT_DARK_EDGE) / 2 ? HEAT_LIGHT_EDGE : HEAT_DARK_EDGE;
  const rgb = heatAt(at);
  const white = luminance(rgb) <= luminance(HEAT_DENIM);
  return { percent, background: `rgb(${rgb[0]} ${rgb[1]} ${rgb[2]})`, text: white ? "white" : "inkt", rgb };
}
export const heatTextRgb = (text: "inkt" | "white"): Rgb => (text === "white" ? HEAT_WHITE : HEAT_INKT);

/** A sparkline's path in a w by h box (no axes): the values left to right, the lowest at the bottom, a flat line in the middle */
export function sparkPath(values: readonly number[], w: number, h: number, pad = 2): string {
  if (values.length === 0) return "";
  const lo = Math.min(...values);
  const hi = Math.max(...values);
  const x = (i: number) => (values.length === 1 ? w / 2 : pad + (i / (values.length - 1)) * (w - 2 * pad));
  const y = (v: number) => (hi === lo ? h / 2 : h - pad - ((v - lo) / (hi - lo)) * (h - 2 * pad));
  return values.map((v, i) => `${i === 0 ? "M" : "L"}${round1(x(i))} ${round1(y(v))}`).join(" ");
}

const round1 = (x: number) => Math.round(x * 10) / 10;

/** An axis from 0 (or below, for bars that go down) to a round top: the top, the bottom and the step between gridlines */
export function niceAxis(lowest: number, highest: number, ticks = 4): { top: number; bottom: number; step: number } {
  const span = Math.max(1, highest - Math.min(0, lowest));
  const raw = span / ticks;
  const mag = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 2.5, 5, 10].map((f) => f * mag).find((s) => s >= raw) ?? 10 * mag;
  const top = Math.max(step, Math.ceil(highest / step) * step);
  const bottom = lowest < 0 ? Math.floor(lowest / step) * step : 0;
  return { top, bottom, step };
}

/** The comparison's rows of one measure (retention has one per age, an amount one per currency), in the table's order */
export function comparisonRows(rows: readonly ActiveComparisonRow[], measure: ActiveMeasure): ActiveComparisonRow[] {
  return rows.filter((r) => r.measure === measure);
}

/** The file's name: active-customers-<market|all>-<segment|all>-<stamp>.csv, the channel after the segment when one is chosen */
export function activeFileName(filter: ActiveFilter, stamp: string): string {
  const part = (v: string | null) => (v ?? "all").toLowerCase().replace(/[^a-z0-9_-]/g, "");
  return `active-customers-${part(filter.market)}-${part(filter.segment)}${filter.channel ? `-${filter.channel}` : ""}-${stamp}.csv`;
}

/** The file's columns: ids, codes, dates and amounts only, as the list's */
export const ACTIVE_FILE_COLUMNS = [
  "store_customer", "store", "market", "segment", "channel", "level", "customer_start", "age_months", "subscriptions", "devices", "monthly_amount", "currency",
  "clv", "clv_currency", "payment_state", "contact_id",
] as const;

// ---- the database's document in the API's words -------------------------------------------------------------------------

/**
 * The fields whose value is an object keyed by data (a segment's code, a currency, a status, a channel, a reason): their
 * keys are kept as the database writes them; every other key turns from snake_case to camelCase (convention 3)
 */
const DATA_KEYED = new Set(["by_segment", "by_channel", "by_status", "inflow_by_channel", "amounts", "clv", "reasons", "other_amounts", "status_meanings"]);
/** A band's key of Devices per active customer as the database writes it: 0, a count, a range or the open last band (0, 2, 3-5, 11+) */
export const ACTIVE_DEVICE_BAND = /^(0|[1-9]\d{0,3})(-[1-9]\d{0,3}|\+)?$/;
/**
 * The bands of a list of bounds as the database names them (cma.flash_count_bands_of): 0, then from 1 to below the first
 * bound where it is above 1, each bound to below the next, and the last bound open-ended (1,2,3,6,11 reads 0, 1, 2, 3-5,
 * 6-10, 11+; 2,4 reads 0, 1, 2-3, 4+)
 */
export function deviceBandKeys(bounds: readonly number[]): string[] {
  const keys = ["0"];
  const span = (lo: number, hi: number) => (lo === hi ? String(lo) : `${lo}-${hi}`);
  if (bounds.length > 0 && bounds[0]! > 1) keys.push(span(1, bounds[0]! - 1));
  bounds.forEach((b, i) => keys.push(i === bounds.length - 1 ? `${b}+` : span(b, bounds[i + 1]! - 1)));
  return keys;
}
/** The band a count falls in (cma.flash_count_band_of) */
export function deviceBandOf(count: number, bounds: readonly number[]): string {
  const keys = deviceBandKeys(bounds);
  if (count <= 0 || bounds.length === 0) return "0";
  let at = bounds[0]! > 1 ? 1 : 0;                       // the band from 1 to below the first bound, where there is one
  for (let i = 0; i < bounds.length; i++) if (count >= bounds[i]!) at = (bounds[0]! > 1 ? 2 : 1) + i;
  return keys[at]!;
}
/** The count from which the page counts "customers with n or more devices": the bands' third bound, or the last of a shorter list */
export function deviceFromOf(bounds: readonly number[]): number {
  return bounds[Math.min(3, bounds.length) - 1] ?? 1;
}
/** The band asked for in an address (&band): a key in the bands' form, or null (the database refuses a key that is no band of the tenant's setting) */
export function activeBandOf(value: unknown): string | null {
  return typeof value === "string" && value.length <= 10 && ACTIVE_DEVICE_BAND.test(value) ? value : null;
}

const camel = (k: string) => k.replace(/_([a-z0-9])/g, (_, c: string) => c.toUpperCase());

function convert(value: unknown, keepKeys: boolean): unknown {
  if (Array.isArray(value)) return value.map((v) => convert(v, false));
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(Object.entries(value as Record<string, unknown>).map(([k, v]) => [keepKeys ? k : camel(k), convert(v, DATA_KEYED.has(k))]));
  }
  return value;
}

/**
 * A read's JSON (cma.active_top or cma.active_rest) as the page and the API hold it: camelCase keys, the data-keyed maps
 * as they are, the rates apart from their date. Each read answers its own part of the report; the part it leaves out is
 * empty here (null, [] or zero counts), never a guess
 */
export function activeFromDb(j: Record<string, unknown>): import("@/lib/data").ActiveReport {
  type R = import("@/lib/data").ActiveReport;
  const c = convert(j, false) as Record<string, unknown>;
  const settings = (c.settings ?? {}) as Record<string, unknown>;
  const fxRaw = ((j.settings as Record<string, unknown> | undefined)?.fx ?? null) as Record<string, unknown> | null;
  const statuses = (settings.statuses ?? {}) as Record<string, unknown>;
  const figures = c.figures === true;
  const notes = (c.notes ?? null) as Partial<import("@/lib/data").ActiveNotes> | null;
  return {
    ...(c as object),
    figures,
    history: c.history === true,
    take: (c.take as R["take"] | undefined) ?? null,
    grouping: (c.grouping as R["grouping"] | undefined) ?? "month",
    settings: {
      cohortAgesMonths: (settings.cohortAgesMonths as number[] | undefined) ?? [], ageMonths: (settings.ageMonths as number[] | undefined) ?? [],
      historyMonths: Number(settings.historyMonths ?? 0),
      fx: fxRaw && typeof fxRaw.as_of === "string"
        ? { asOf: fxRaw.as_of, rates: Object.fromEntries(Object.entries(fxRaw).filter(([k, v]) => k !== "as_of" && typeof v === "number")) as Record<string, number> }
        : null,
      segments: (settings.segments as string[] | undefined) ?? [],
      statuses: {
        active: (statuses.activeSubscriptionStatuses as string[] | undefined) ?? [], holding: (statuses.deviceHoldingStatuses as string[] | undefined) ?? [],
        ended: (statuses.endedSubscriptionStatuses as string[] | undefined) ?? [],
      },
      attribution: (settings.attribution as { assistedLevels: string[]; historyStart: string | null } | undefined) ?? { assistedLevels: [], historyStart: null },
    },
    filters: (c.filters as R["filters"] | undefined) ?? { markets: [], segments: [], channels: [...ACTIVE_CHANNELS] },
    tiles: figures ? ((c.tiles as import("@/lib/data").ActiveTiles | undefined) ?? null) : null,
    presentAt: typeof c.presentAt === "string" ? c.presentAt : null,
    unitEconomics: figures ? ((c.unitEconomics as R["unitEconomics"] | undefined) ?? null) : null,
    months: figures ? ((c.months as Partial<import("@/lib/data").ActiveMonth>[] | undefined) ?? []).map(monthOf) : [],
    markets: figures ? ((c.markets as import("@/lib/data").ActiveMarketRow[] | undefined) ?? []) : [],
    marketsTotal: figures ? ((c.marketsTotal as R["marketsTotal"] | undefined) ?? null) : null,
    comparison: figures ? ((c.comparison as R["comparison"] | undefined) ?? null) : null,
    survival: figures ? ((c.survival as R["survival"] | undefined) ?? null) : null,
    ageBands: figures ? ((c.ageBands as R["ageBands"] | undefined) ?? []) : [],
    ageOver: figures ? ((c.ageOver as R["ageOver"] | undefined) ?? []) : [],
    cohorts: figures ? ((c.cohorts as ActiveCohort[] | undefined) ?? []) : [],
    cohortSplits: figures ? ((c.cohortSplits as R["cohortSplits"] | undefined) ?? null) : null,
    mix: figures && c.mix ? mixFromDb(c.mix as Record<string, { key: string; name?: string | null; subscriptions?: number; devices?: number }[]>) : null,
    // a document stored before addition 0009r holds no such part: null until the next refresh writes it
    deviceCustomers: figures ? ((c.deviceCustomers as R["deviceCustomers"] | undefined) ?? null) : null,
    notes: figures && notes ? notesOf(notes) : null,
  } as R;
}

/** A month of a read with the other read's fields empty */
function monthOf(m: Partial<import("@/lib/data").ActiveMonth>): import("@/lib/data").ActiveMonth {
  return {
    month: m.month ?? "", isNow: m.isNow === true, customers: m.customers ?? 0, bySegment: m.bySegment ?? {}, subscriptions: m.subscriptions ?? 0, inflow: m.inflow ?? 0,
    inflowByChannel: m.inflowByChannel ?? {}, outflow: m.outflow ?? 0, net: m.net ?? 0, amounts: m.amounts ?? {}, eur: m.eur ?? null,
  };
}

function notesOf(n: Partial<import("@/lib/data").ActiveNotes>): import("@/lib/data").ActiveNotes {
  return {
    noEndedTime: n.noEndedTime ?? 0, noCreatedTime: n.noCreatedTime ?? 0, noAmount: n.noAmount ?? 0, unmatchedSubscriptions: n.unmatchedSubscriptions ?? 0,
    reconstructionGap: n.reconstructionGap ?? 0, historyStarts: n.historyStarts ?? [], unknownChannel: n.unknownChannel ?? { customers: 0, reasons: {} },
    dominantCohort: n.dominantCohort ?? null,
  };
}

/** The keys each read answers (decision D15): above the fold and below it; the rest of a report is shared (the head) */
const TOP_KEYS = ["tiles", "unitEconomics", "filters"] as const;
const REST_KEYS = ["markets", "marketsTotal", "comparison", "survival", "ageBands", "ageOver", "cohorts", "cohortSplits", "mix", "deviceCustomers"] as const;
const TOP_MONTH = ["customers", "bySegment", "subscriptions"] as const;
const TOP_NOTES = ["noEndedTime", "noCreatedTime", "unmatchedSubscriptions", "reconstructionGap", "historyStarts"] as const;

/** The two reads as one report (the API's answer): the top's part, the rest's part, the months and the notes of both side by side */
/** cma.active_now's answer: the live present of the four tiles that state it */
export function activeNowFromDb(j: Record<string, unknown>): import("@/lib/data").ActiveNow {
  const c = convert(j, false) as Record<string, unknown>;
  const figures = c.figures === true;
  return {
    figures, source: c.source === "take" ? "take" : "live", computedAt: String(c.computedAt ?? ""), tiles: figures ? ((c.tiles as import("@/lib/data").ActiveNow["tiles"] | undefined) ?? null) : null,
    now: figures ? ((c.now as import("@/lib/data").ActiveNow["now"] | undefined) ?? null) : null,
  };
}
/**
 * The stored answer with the live present in the places of the tiles that state it (decision D16): Active customers,
 * Total subscriptions, the Monthly recurring amount and the indicative euros; the take's own tiles (Customer age,
 * Customer lifetime, the realised value) stay. The series' running point follows (the current point is "now" and equals
 * the headline), and with it the note on the reconstruction's difference. Without a live present the stored answer as it is
 */
export function withActiveNow(top: import("@/lib/data").ActiveReport, now: import("@/lib/data").ActiveNow | null): import("@/lib/data").ActiveReport {
  if (!now || !now.figures || !now.tiles) return top;
  const stored = top.tiles;
  const point = now.now;
  const was = top.months.find((m) => m.isNow);
  return {
    ...top, presentAt: now.computedAt, presentSource: now.source,
    tiles: { customerAge: stored?.customerAge ?? null, lifetime: stored?.lifetime ?? null, clv: stored?.clv ?? null, ...now.tiles },
    months: point ? top.months.map((m) => (m.isNow ? { ...m, customers: point.customers, subscriptions: point.subscriptions, bySegment: point.bySegment } : m)) : top.months,
    notes: point && was && top.notes ? { ...top.notes, reconstructionGap: top.notes.reconstructionGap + was.customers - point.customers } : top.notes,
  };
}
/** The states of a take the mock can show (the page's ?take= in test data): none yet, marked stale, or late by its age */
export const ACTIVE_TAKE_STATES = ["none", "stale", "late"] as const;
export type ActiveTakeState = (typeof ACTIVE_TAKE_STATES)[number];
const takeIn = (take: import("@/lib/data").ActiveTake | null, state: ActiveTakeState): import("@/lib/data").ActiveTake | null => (take === null || state === "none" ? null
  : state === "stale" ? { ...take, stale: true, late: true }
    : { ...take, computedAt: new Date(new Date(take.computedAt).getTime() - 20 * 60_000).toISOString(), ageMinutes: 20, late: true });
/**
 * For test data alone: an answer of the report's reads as the database gives it in another state of the take, so the
 * states can be looked at and verified without a database. none: the head with the filters' choices and nothing else
 * (history false, no take, no figure: never zeros); stale and late: the same figures under a take that says so
 */
export function activeInTakeState(r: import("@/lib/data").ActiveReport, state: ActiveTakeState | null): import("@/lib/data").ActiveReport {
  if (state === null || !r.figures) return r;
  if (state === "none") {
    return { ...activeFromDb({ figures: true }), setUp: r.setUp, computedAt: r.computedAt, timeZone: r.timeZone, today: r.today, month: r.month, fromMonth: r.fromMonth,
      grouping: r.grouping, filter: r.filter, settings: r.settings, filters: r.filters, history: false, take: null, presentAt: null };
  }
  const take = takeIn(r.take, state);
  return { ...r, take, presentAt: r.presentAt === null ? null : take?.computedAt ?? null };
}
/** The live present in that state: without a take the split by acquisition channel is absent, and under a channel filter there is no present to state */
export function activeNowInTakeState(now: import("@/lib/data").ActiveNow, state: ActiveTakeState | null, channel: string | null): import("@/lib/data").ActiveNow {
  if (state !== "none" || !now.tiles) return now;
  return channel !== null ? { ...now, tiles: null } : { ...now, tiles: { ...now.tiles, activeCustomers: { ...now.tiles.activeCustomers, byChannel: null } } };
}
/** The list in that state: without a take no row and no total */
export function activeListInTakeState(list: import("@/lib/data").ActiveList, state: ActiveTakeState | null): import("@/lib/data").ActiveList {
  if (state === null || !list.setUp) return list;
  if (state === "none") return { ...list, history: false, take: null, total: null, rows: [], next: null, prev: null };
  return { ...list, take: takeIn(list.take, state) };
}
export function mergeActive(top: import("@/lib/data").ActiveReport, rest: import("@/lib/data").ActiveReport): import("@/lib/data").ActiveReport {
  const restPart = Object.fromEntries(REST_KEYS.map((k) => [k, rest[k]]));
  const byMonth = new Map(rest.months.map((m) => [m.month, m]));
  const months = top.months.map((m) => {
    const r = byMonth.get(m.month);
    return r ? { ...r, ...Object.fromEntries(TOP_MONTH.map((k) => [k, m[k]])), month: m.month, isNow: m.isNow } : m;
  });
  const notes = top.notes || rest.notes
    ? { ...notesOf({}), ...(rest.notes ?? {}), ...Object.fromEntries(TOP_NOTES.map((k) => [k, (top.notes ?? notesOf({}))[k]])) }
    : null;
  return { ...top, ...restPart, grouping: rest.grouping, history: top.history && rest.history, months: months as import("@/lib/data").ActiveMonth[],
    notes: notes as import("@/lib/data").ActiveNotes | null };
}

/** A whole report cut to what one read answers (the mock builds the whole and answers each read from it) */
export function activePartOf(report: import("@/lib/data").ActiveReport, part: "top" | "rest"): import("@/lib/data").ActiveReport {
  const empty = activeFromDb({ figures: report.figures });
  const blank = part === "top" ? REST_KEYS : TOP_KEYS;
  const kept = Object.fromEntries(blank.map((k) => [k, empty[k]]));
  const months = report.months.map((m) => {
    const e = monthOf({ month: m.month, isNow: m.isNow });
    const keep = part === "top" ? TOP_MONTH : (["inflow", "inflowByChannel", "outflow", "net", "amounts", "eur"] as const);
    return { ...e, ...Object.fromEntries(keep.map((k) => [k, m[k]])) };
  });
  const n = report.notes;
  const notes = n === null ? null
    : part === "top" ? { ...notesOf({}), ...Object.fromEntries(TOP_NOTES.map((k) => [k, n[k]])) }
      : { ...notesOf({}), noAmount: n.noAmount, unknownChannel: n.unknownChannel, dominantCohort: n.dominantCohort };
  return { ...report, ...kept, filters: part === "top" ? report.filters : empty.filters, months: months as import("@/lib/data").ActiveMonth[],
    notes: notes as import("@/lib/data").ActiveNotes | null };
}

function mixFromDb(m: Record<string, { key: string; name?: string | null; subscriptions?: number; devices?: number }[]>): NonNullable<import("@/lib/data").ActiveReport["mix"]> {
  const subs = (rows: { key: string; subscriptions?: number }[] | undefined) => (rows ?? []).map((r) => ({ key: r.key, subscriptions: r.subscriptions ?? 0 }));
  return {
    billing: subs(m.billing), deviceBand: subs(m.deviceBand), paymentState: subs(m.paymentState),
    // a model's label is the asset register's catalog label of the model, not a customer's
    model: (m.model ?? []).map((r) => ({ key: r.key, label: r.name ?? null, devices: r.devices ?? 0 })),
  };
}

/** cma.active_rows' JSON as the page and the API hold it */
export function activeRowsFromDb(j: Record<string, unknown>): import("@/lib/data").ActiveList {
  const c = convert(j, false) as Record<string, unknown>;
  return {
    setUp: c.setUp === true, history: c.history === true, take: (c.take as import("@/lib/data").ActiveTake | undefined) ?? null,
    timeZone: String(c.timeZone ?? ""), total: typeof c.total === "number" ? c.total : null,
    rows: (c.rows as import("@/lib/data").ActiveListRow[] | undefined) ?? [],
    next: typeof c.next === "string" ? c.next : null, prev: typeof c.prev === "string" ? c.prev : null,
  };
}
