/**
 * Lead cohorts (addition 0008zm, 30 October 2026; KPIs 1 and 12): Reports → Lead cohorts. The lead deals grouped by the
 * ISO week or the month of their creation and followed at the ages of cohorts.lead_ages_days: per age the share attempted,
 * with a conversation, ordered and lost. The figures come from the database (cma.lead_cohorts_report); this module mirrors
 * its definitions for the mock and for verify/reports.mjs, and arranges the rows for the screen. Pure, with no runtime
 * imports beyond reports.ts and time.ts, so the verifier runs it under Node's type stripping.
 *
 * The definitions (docs/definitions.md, Cohort terms; one place in the database, 120_lead_cohorts.sql):
 *   lead cohort     every lead deal (cma.lead_deals_of) created in one ISO week (from Monday) or one month, by the creation's
 *                   business date in the tenant's zone
 *   cohort age      n days after the creation (created_at + n days, as lead_to_order.max_days counts its days)
 *   mature          every deal of the cohort is n days old; until then the cohort's figures at n are null (a dash)
 *   attempted       the deal's first attempt at or before the age (Attempts per deal's attempts)
 *   conversation    the first attempt that is a Conversation, at or before the age
 *   ordered         lead to order: the first store order of the deal's contacts within lead_to_order.max_days, at or before
 *                   the age; null at an age above lead_to_order.max_days
 *   lost            the deal is lost (cma.sales_deals_of's outcome: no order ended its window first) and closed by the age
 *   not called yet  the deal is open and has no attempt, now
 * Counts only: no deal list, no name, address or phone number of a customer exists here.
 */
import type {
  CohortAge, CohortMeasure, CohortPeriod, CohortSplit, DateKey, FunnelFilter, Instant, LeadCohortRow, LeadCohortsReport,
} from "./data/types";
// With their extensions, so verify/reports.mjs can run this module under Node's type stripping
import { percentileCont, round1 } from "./reports.ts";
import { addDays, startOfWeek } from "./time.ts";

export const COHORT_PERIODS: readonly CohortPeriod[] = ["week", "month"];
export const COHORT_SPLITS: readonly CohortSplit[] = ["none", "market", "source"];
export const COHORT_MEASURES: readonly CohortMeasure[] = ["attempted", "conversation", "ordered", "lost"];

/** The setting that holds the ages, and lead to order's, which caps the largest */
export const LEAD_AGES_SETTING = "cohorts.lead_ages_days";
export const LEAD_TO_ORDER_SETTING = "lead_to_order.max_days";

/** The chart draws the newest cohorts only, one line each */
export const CHART_COHORTS = 8;

const DAY_MS = 86_400_000;

function choice<T extends string>(list: readonly T[], value: unknown): T | null {
  return typeof value === "string" && (list as readonly string[]).includes(value) ? (value as T) : null;
}

function next<T>(list: readonly T[], value: T): T {
  return list[(list.indexOf(value) + 1) % list.length]!;
}

export const parseCohortPeriod = (value: unknown) => choice(COHORT_PERIODS, value);
export const parseCohortSplit = (value: unknown) => choice(COHORT_SPLITS, value);
export const parseCohortMeasure = (value: unknown) => choice(COHORT_MEASURES, value);
export const nextCohortPeriod = (value: CohortPeriod) => next(COHORT_PERIODS, value);
export const nextCohortSplit = (value: CohortSplit) => next(COHORT_SPLITS, value);
export const nextCohortMeasure = (value: CohortMeasure) => next(COHORT_MEASURES, value);

/**
 * The ages as cma.check_tenant_setting takes them: spaces dropped, one to six increasing whole numbers from 1 to 9999,
 * comma-separated (cma.is_bucket_list), the largest at most `maxDays` when given. The normalised text, or null
 */
export function parseLeadAges(text: string, maxDays: number | null = null): string | null {
  const v = text.replace(/\s+/g, "");
  if (!/^[1-9][0-9]{0,3}(,[1-9][0-9]{0,3}){0,5}$/.test(v)) return null;
  const ages = v.split(",").map(Number);
  if (ages.some((a, i) => i > 0 && a <= ages[i - 1]!)) return null;
  if (maxDays !== null && ages.at(-1)! > maxDays) return null;
  return v;
}

/** The ages of a setting's value, in order; none for a value out of form */
export function leadAgesOf(value: string): number[] {
  const v = parseLeadAges(value);
  return v === null ? [] : v.split(",").map(Number);
}

/** A count as a share of the cohort's created deals; null for a null count or an empty cohort */
export function cohortShare(count: number | null, created: number): number | null {
  return count === null || created === 0 ? null : count / created;
}

/** The figure of an age for a measure */
export function cohortValue(age: CohortAge, measure: CohortMeasure): number | null {
  return age[measure];
}

// ---- The definitions, for the mock and the verifier ---------------------------------------------------

/** One lead deal with its facts, as cma.lead_cohorts_of gives it (the mock and the verifier build these) */
export interface LeadCohortDeal {
  dealId: string;
  connectionId: string;
  pipelineId: string;
  pipelineLabel: string;
  /** 0007d's market ("unknown" when none) */
  market: string;
  sourceChannel: string | null;
  createdAt: Instant;
  /** The creation's business date in the tenant's zone */
  date: DateKey;
  firstAttemptAt: Instant | null;
  firstConversationAt: Instant | null;
  /** Lead to order's first store order (within lead_to_order.max_days) */
  orderCreatedAt: Instant | null;
  daysToOrder: number | null;
  /** The close of a lost deal */
  lostAt: Instant | null;
  notCalledYet: boolean;
}

/** The ISO week of a Monday's date as IYYY-Www (to_char 'IYYY-"W"IW') */
export function isoWeekLabel(monday: DateKey): string {
  const thursday = addDays(monday, 3);
  const year = Number(thursday.slice(0, 4));
  const week = 1 + Math.floor((Date.parse(`${thursday}T00:00:00Z`) - Date.parse(`${year}-01-01T00:00:00Z`)) / DAY_MS / 7);
  return `${year}-W${String(week).padStart(2, "0")}`;
}

/** The period's first day of a business date */
export function cohortKey(date: DateKey, period: CohortPeriod): DateKey {
  return period === "month" ? `${date.slice(0, 7)}-01` : startOfWeek(date);
}

/** The period's last day */
export function cohortEnd(key: DateKey, period: CohortPeriod): DateKey {
  if (period === "week") return addDays(key, 6);
  const y = Number(key.slice(0, 4));
  const m = Number(key.slice(5, 7));
  return addDays(m === 12 ? `${y + 1}-01-01` : `${y}-${String(m + 1).padStart(2, "0")}-01`, -1);
}

/** The end of an age: n days after the creation */
function ageEnd(createdAt: Instant, age: number): number {
  return Date.parse(createdAt) + age * DAY_MS;
}

const within = (at: Instant | null, createdAt: Instant, age: number) => at !== null && Date.parse(at) <= ageEnd(createdAt, age);

/** The figures of one cohort, or one group of it, as cma.lead_cohort_figures_from gives them */
export function leadCohortFigures(deals: readonly LeadCohortDeal[], ages: readonly number[], maxDays: number, now: Instant):
  Pick<LeadCohortRow, "created" | "notCalledYet" | "ordered" | "medianDaysToOrder" | "ages"> {
  const n = Date.parse(now);
  const days = deals.flatMap((d) => (d.daysToOrder === null ? [] : [d.daysToOrder]));
  const median = percentileCont(days, 0.5);
  return {
    created: deals.length,
    notCalledYet: deals.filter((d) => d.notCalledYet).length,
    ordered: deals.filter((d) => d.orderCreatedAt !== null).length,
    medianDaysToOrder: median === null ? null : round1(median),
    ages: ages.map((age): CohortAge => {
      const mature = deals.length > 0 && deals.every((d) => ageEnd(d.createdAt, age) <= n);
      const count = (pick: (d: LeadCohortDeal) => Instant | null) => (mature ? deals.filter((d) => within(pick(d), d.createdAt, age)).length : null);
      return {
        age, mature,
        attempted: count((d) => d.firstAttemptAt),
        conversation: count((d) => d.firstConversationAt),
        ordered: age <= maxDays ? count((d) => d.orderCreatedAt) : null,
        lost: count((d) => d.lostAt),
      };
    }),
  };
}

/**
 * Per cohort newest first, and with a split per market (unknown last) or source channel (none last) within it, as
 * cma.lead_cohorts_from gives them: the key, label, first and last day, group, whether the range cuts the period, figures
 */
export function leadCohortRows(deals: readonly LeadCohortDeal[], o: {
  period: CohortPeriod; split: CohortSplit; ages: readonly number[]; maxDays: number; from: DateKey; to: DateKey; now: Instant;
}): LeadCohortRow[] {
  const groups = new Map<string, { key: DateKey; group: string | null; deals: LeadCohortDeal[] }>();
  for (const d of deals) {
    const key = cohortKey(d.date, o.period);
    const group = o.split === "market" ? d.market : o.split === "source" ? d.sourceChannel : null;
    const id = `${key}|${group ?? ""}|${group === null ? 0 : 1}`;
    if (!groups.has(id)) groups.set(id, { key, group, deals: [] });
    groups.get(id)!.deals.push(d);
  }
  const rank = (g: string | null) => (g === null ? 2 : o.split === "market" && g === "unknown" ? 1 : 0);
  return [...groups.values()]
    .sort((a, b) => (a.key < b.key ? 1 : a.key > b.key ? -1 : 0) || rank(a.group) - rank(b.group)
      || (a.group ?? "").localeCompare(b.group ?? ""))
    .map((g) => {
      const end = cohortEnd(g.key, o.period);
      return {
        key: g.key, label: o.period === "month" ? g.key.slice(0, 7) : isoWeekLabel(g.key), start: g.key, end, group: g.group,
        partial: g.key < o.from || end > o.to, ...leadCohortFigures(g.deals, o.ages, o.maxDays, o.now),
      };
    });
}

/** The report from the deals of the range without the filters, as cma.lead_cohorts_report_of answers it */
export function leadCohortsReport(all: readonly LeadCohortDeal[], o: {
  from: DateKey; to: DateKey; period: CohortPeriod; split: CohortSplit; filter: FunnelFilter; ages: readonly number[]; maxDays: number;
  historyStart: DateKey | null; now: Instant;
}): LeadCohortsReport {
  const kept = all.filter((d) => (o.filter.pipeline === null || `${d.connectionId}:${d.pipelineId}` === o.filter.pipeline)
    && (o.filter.market === null || d.market === o.filter.market)
    && (o.filter.sourceChannel === null || d.sourceChannel === o.filter.sourceChannel));
  const base = { ages: o.ages, maxDays: o.maxDays, from: o.from, to: o.to, now: o.now, period: o.period };
  return {
    from: o.from, to: o.to, period: o.period, split: o.split, filter: o.filter, ages: [...o.ages], leadToOrderDays: o.maxDays,
    historyStart: o.historyStart,
    cohorts: leadCohortRows(kept, { ...base, split: "none" }),
    rows: o.split === "none" ? [] : leadCohortRows(kept, { ...base, split: o.split }),
    markets: [...new Set(all.map((d) => d.market))].sort((a, b) => (a === "unknown" ? 1 : 0) - (b === "unknown" ? 1 : 0) || (a < b ? -1 : a > b ? 1 : 0)),
    pipelines: [...new Map(all.map((d) => [`${d.connectionId}:${d.pipelineId}`, d.pipelineLabel])).entries()]
      .map(([key, label]) => ({ key, label })).sort((a, b) => a.label.localeCompare(b.label) || a.key.localeCompare(b.key)),
    sourceChannels: [...new Set(all.flatMap((d) => (d.sourceChannel === null ? [] : [d.sourceChannel])))].sort(),
  };
}

// ---- The screen -------------------------------------------------------------------------------------------

/** One cohort's line in the chart: the ordered share and count at each age it has reached (an age not reached has no point) */
export interface CohortLine {
  key: DateKey;
  label: string;
  created: number;
  points: { age: number; share: number; count: number }[];
}

/** The chart's lines: the newest cohorts (at most CHART_COHORTS), newest first, each with its cumulative ordered share by age */
export function cohortChartLines(cohorts: readonly LeadCohortRow[], limit = CHART_COHORTS): CohortLine[] {
  return cohorts.slice(0, limit).map((c) => ({
    key: c.key, label: c.label, created: c.created,
    points: c.ages.flatMap((a) => {
      const share = cohortShare(a.ordered, c.created);
      return share === null || a.ordered === null ? [] : [{ age: a.age, share, count: a.ordered }];
    }),
  }));
}

/** The table's rows: without a split the cohorts; with one, each cohort's groups under it, in the report's order */
export function cohortTableRows(report: Pick<LeadCohortsReport, "split" | "cohorts" | "rows">): { cohort: LeadCohortRow; groups: LeadCohortRow[] }[] {
  return report.cohorts.map((c) => ({ cohort: c, groups: report.split === "none" ? [] : report.rows.filter((r) => r.key === c.key) }));
}
