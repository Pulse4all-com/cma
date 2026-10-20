/**
 * Attempts per deal (addition 0008y; 19 October 2026): Reports → Attempts per deal and Attempts per agent. How many
 * outbound CRM calls a deal gets before the customer is reached, how often the first attempt reaches them, whether
 * more attempts win more deals, and how long the open deals have waited since their last attempt. The figures come
 * from the database (cma.attempts_per_deal_page, cma.attempts_per_person_page); this module mirrors their definitions
 * for the mock and for verify/reports.mjs, and arranges the rows for the screen. Pure, with no runtime imports beyond
 * time.ts and reports.ts, so the verifier runs it under Node's type stripping.
 *
 * The definitions (README, Data model: attempts per deal), one place in the database (cma.attempts_per_deal_of):
 *   deal         scope lead: a deal of a counted lead pipeline; scope counted: of any counted deal pipeline; never an
 *                order pipeline; not deleted, created on or after intake.start_date; its date in the tenant's zone
 *   attempt      an outbound CRM call associated with the deal or its contacts, its effective start at or after the
 *                creation minus speed_to_lead.pre_window_minutes and at or before the close (now while open)
 *   connected    the outcome counts as connected, or the linked telephony call was answered
 *   outcome      won or lost by the stage, else open, or unknown for a closed stage without one
 *   since last   an open deal's business days in its market since its last attempt, else its creation; none for
 *                an unknown market; bucketed by attempts.since_last_buckets_business_days
 * Ids, codes, counts, links and times only: no name, address or phone number of a customer exists here.
 */
import type {
  AttemptBucket, AttemptFigures, AttemptFilter, AttemptGroup, AttemptGroupRow, AttemptListRow, AttemptOutcome, AttemptPerson, AttemptScope,
  DateKey, Instant, SinceLastBucket,
} from "./data/types";
// With their extensions, so verify/reports.mjs can run this module under Node's type stripping
import { round1, timeInZone } from "./reports.ts";
import { addDays, dateKeyInZone, startOfWeek } from "./time.ts";

export const ATTEMPT_GROUPS: readonly AttemptGroup[] = ["day", "week", "market", "pipeline"];
export const ATTEMPT_SCOPES: readonly AttemptScope[] = ["lead", "counted"];

export function parseAttemptGroup(value: unknown): AttemptGroup | null {
  return typeof value === "string" && (ATTEMPT_GROUPS as readonly string[]).includes(value) ? (value as AttemptGroup) : null;
}

export function nextAttemptGroup(group: AttemptGroup): AttemptGroup {
  return ATTEMPT_GROUPS[(ATTEMPT_GROUPS.indexOf(group) + 1) % ATTEMPT_GROUPS.length]!;
}

/** Attempts per agent: performance.team, and the tenant's reports.per_person holding attempts (cma.assert_per_person) */
export const ATTEMPTS_PER_AGENT_PERMISSION = "performance.team";
export const ATTEMPTS_PER_AGENT_KEY = "attempts";

const PIPELINE_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[^\s:]{1,100}$/;

/**
 * The filters from a query, as cma.attempts_filters_check and cma.attempts_scope_check take them: a market is a
 * two-letter code or "unknown", a pipeline a connection id and a pipeline id joined by ':', the scope lead (the
 * default) or counted; empty means all. `problem` names a value the database would refuse; that filter is then
 * left out (the scope then lead)
 */
export function parseAttemptFilter(market: unknown, pipeline: unknown, scope: unknown):
  { filter: AttemptFilter; problem: null | "market" | "pipeline" | "scope" } {
  const filter: AttemptFilter = { market: null, pipeline: null, scope: "lead" };
  let problem: null | "market" | "pipeline" | "scope" = null;
  const text = (v: unknown) => (typeof v === "string" && v.trim() !== "" ? v.trim() : null);
  const m = text(market);
  if (m !== null) {
    if (/^([A-Z]{2}|unknown)$/.test(m)) filter.market = m;
    else problem = "market";
  }
  const p = text(pipeline);
  if (p !== null) {
    if (PIPELINE_RE.test(p)) filter.pipeline = p;
    else problem ??= "pipeline";
  }
  const s = text(scope);
  if (s !== null) {
    if ((ATTEMPT_SCOPES as readonly string[]).includes(s)) filter.scope = s as AttemptScope;
    else problem ??= "scope";
  }
  return { filter, problem };
}

/** The filter as query parameters; the default scope is left out */
export function attemptFilterQuery(filter: AttemptFilter): Record<string, string> {
  const out: Record<string, string> = {};
  if (filter.market) out.market = filter.market;
  if (filter.pipeline) out.pipeline = filter.pipeline;
  if (filter.scope !== "lead") out.scope = filter.scope;
  return out;
}

// ---- The mock's fixture and the definitions -----------------------------------------------------------

/** A CRM call with a deal or one of its contacts, at its effective start (the linked telephony call's, else the CRM's) */
export interface AttemptCallFixture {
  id: string;
  at: Instant;
  direction: "outbound" | "inbound";
  /** The outcome counts as connected, or the linked telephony call was answered */
  connected: boolean;
}

/** One deal as the mock holds it, with the calls the database would find for it (lead_calls_of before the pre-window) */
export interface AttemptDealFixture {
  connectionId: string;
  dealSourceId: string;
  pipelineId: string;
  pipelineLabel: string;
  isLead: boolean;
  isOrder: boolean;
  isCounted: boolean;
  /** 0007d's market ("unknown" when none) and its zone (null for unknown) */
  market: string;
  zone: string | null;
  ownerRef: string | null;
  createdAt: Instant;
  isClosed: boolean;
  closedAt: Instant | null;
  /** The stage's outcome, when it has one */
  stageOutcome: "won" | "lost" | null;
  recordUrl: string | null;
  calls: AttemptCallFixture[];
}

/** A deal as cma.attempts_per_deal_of returns it */
export interface AttemptRecord {
  connectionId: string;
  dealSourceId: string;
  recordUrl: string | null;
  pipelineId: string;
  pipelineLabel: string;
  isLead: boolean;
  market: string;
  ownerRef: string | null;
  ownerUserId: string | null;
  createdAt: Instant;
  date: DateKey;
  week: DateKey;
  localTime: string;
  isClosed: boolean;
  closedAt: Instant | null;
  outcome: AttemptOutcome;
  attempts: number;
  connected: number;
  firstConnectedAttempt: number | null;
  firstAttemptAt: Instant | null;
  lastAttemptAt: Instant | null;
  businessDaysSinceLast: number | null;
  sinceLastFrom: number | null;
  sinceLastTo: number | null;
  sinceLastBucket: string | null;
}

/** Whether a market works on a date: office hours that weekday and no holiday (the market's or every market's) */
export type WorkingDay = (market: string, date: DateKey) => boolean;

/**
 * Working days in a market between two instants, as cma.business_days_of counts them: the dates after `from`'s local
 * date up to `to`'s that are working days; 0 when `to` is on `from`'s date or earlier; null without a zone
 */
export function businessDays(market: string, zone: string | null, from: Instant, to: Instant, working: WorkingDay): number | null {
  if (zone === null) return null;
  const a = dateKeyInZone(from, zone);
  const b = dateKeyInZone(to, zone);
  let n = 0;
  for (let d = addDays(a, 1); d <= b; d = addDays(d, 1)) if (working(market, d)) n += 1;
  return n;
}

/** The bucket of a number of days against increasing edges ("1,2,5"), as cma.age_bucket_of places it */
export function ageBucket(days: number | null, edges: string): { from: number; to: number | null } | null {
  if (days === null) return null;
  let prev = 0;
  for (const e of edges.replace(/\s/g, "").split(",").filter((x) => /^\d+$/.test(x)).map(Number).sort((x, y) => x - y)) {
    if (days <= e) return { from: prev, to: e };
    prev = e;
  }
  return { from: prev, to: null };
}

/** A bucket in words as Follow-up writes it: "0–1", "5+" */
export function bucketText(from: number, to: number | null): string {
  return to === null ? `${from}+` : `${from}–${to}`;
}

/** The deals of a scope as cma.attempts_per_deal_of computes them, as of `now` */
export function attemptRecords(deals: readonly AttemptDealFixture[], o: {
  scope: AttemptScope; preWindowMinutes: number; sinceLastBuckets: string; now: Instant; tenantZone: string; working: WorkingDay;
  ownerUserOf: (ownerRef: string | null) => string | null;
}): AttemptRecord[] {
  const now = Date.parse(o.now);
  return deals
    .filter((d) => d.isCounted && !d.isOrder && (d.isLead || o.scope === "counted") && Date.parse(d.createdAt) <= now)
    .map((d) => {
      const created = Date.parse(d.createdAt);
      const upto = d.isClosed ? Math.min(d.closedAt ? Date.parse(d.closedAt) : now, now) : now;
      const attempts = d.calls
        .filter((c) => c.direction === "outbound" && Date.parse(c.at) >= created - o.preWindowMinutes * 60_000 && Date.parse(c.at) <= upto)
        .sort((x, y) => x.at.localeCompare(y.at) || x.id.localeCompare(y.id));
      const firstConnected = attempts.findIndex((c) => c.connected);
      const last = attempts.at(-1)?.at ?? null;
      const days = d.isClosed ? null : businessDays(d.market, d.zone, last ?? d.createdAt, o.now, o.working);
      const bucket = ageBucket(days, o.sinceLastBuckets);
      const date = dateKeyInZone(d.createdAt, o.tenantZone);
      return {
        connectionId: d.connectionId, dealSourceId: d.dealSourceId, recordUrl: d.recordUrl, pipelineId: d.pipelineId, pipelineLabel: d.pipelineLabel,
        isLead: d.isLead, market: d.market, ownerRef: d.ownerRef, ownerUserId: o.ownerUserOf(d.ownerRef), createdAt: d.createdAt,
        date, week: startOfWeek(date), localTime: timeInZone(d.createdAt, o.tenantZone), isClosed: d.isClosed, closedAt: d.closedAt,
        outcome: d.stageOutcome ?? (d.isClosed ? "unknown" : "open"),
        attempts: attempts.length, connected: attempts.filter((c) => c.connected).length,
        firstConnectedAttempt: firstConnected >= 0 ? firstConnected + 1 : null,
        firstAttemptAt: attempts[0]?.at ?? null, lastAttemptAt: last,
        businessDaysSinceLast: days, sinceLastFrom: bucket?.from ?? null, sinceLastTo: bucket?.to ?? null,
        sinceLastBucket: bucket ? bucketText(bucket.from, bucket.to) : null,
      };
    });
}

/** The deals of business dates [from, to], cut on `to` at `until`'s time of day (the previous span), narrowed by the filter */
export function attemptsInPeriod(rows: readonly AttemptRecord[], from: DateKey, to: DateKey, filter: Pick<AttemptFilter, "market" | "pipeline">,
  until: Instant | null = null, tenantZone = "Europe/Amsterdam"): AttemptRecord[] {
  return rows.filter((r) => r.date >= from && r.date <= to
    && (until === null || r.date < to || r.localTime <= timeInZone(until, tenantZone))
    && (filter.market === null || r.market === filter.market)
    && (filter.pipeline === null || `${r.connectionId}:${r.pipelineId}` === filter.pipeline));
}

/** percentile_cont(0.5), rounded to one decimal; null without values */
function median(values: readonly number[]): number | null {
  if (values.length === 0) return null;
  const v = [...values].sort((a, b) => a - b);
  const mid = (v.length - 1) / 2;
  return round1((v[Math.floor(mid)]! + v[Math.ceil(mid)]!) / 2);
}

/** The figures of a set of deals, as cma.attempts_figures_from aggregates them */
export function attemptFigures(rows: readonly AttemptRecord[]): AttemptFigures {
  const sum = rows.reduce((s, r) => s + r.attempts, 0);
  return {
    deals: rows.length,
    attempted: rows.filter((r) => r.attempts > 0).length,
    attempts: sum,
    avgAttempts: rows.length === 0 ? null : Math.round((sum / rows.length) * 100) / 100,
    medianAttempts: median(rows.map((r) => r.attempts)),
    firstReached: rows.filter((r) => r.firstConnectedAttempt === 1).length,
    connectedDeals: rows.filter((r) => r.connected > 0).length,
    openDeals: rows.filter((r) => !r.isClosed).length,
    openNeverAttempted: rows.filter((r) => !r.isClosed && r.attempts === 0).length,
    won: rows.filter((r) => r.outcome === "won").length,
    lost: rows.filter((r) => r.outcome === "lost").length,
  };
}

/** Per attempt bucket 0 to max ("max+"), as cma.attempts_buckets_from: deals, first connected there, won and lost */
export function attemptBuckets(rows: readonly AttemptRecord[], max: number): AttemptBucket[] {
  return Array.from({ length: max + 1 }, (_, b) => {
    const at = rows.filter((r) => Math.min(r.attempts, max) === b);
    return {
      bucket: b, label: b === max ? `${b}+` : String(b), deals: at.length,
      firstConnected: rows.filter((r) => r.firstConnectedAttempt !== null && Math.min(r.firstConnectedAttempt, max) === b).length,
      won: at.filter((r) => r.outcome === "won").length, lost: at.filter((r) => r.outcome === "lost").length,
    };
  });
}

/** The open deals by business days since the last attempt, every bucket of the edges listed; an unknown market apart */
export function sinceLastBuckets(rows: readonly AttemptRecord[], edges: string): { buckets: SinceLastBucket[]; noHours: number } {
  const e = edges.replace(/\s/g, "").split(",").filter((x) => /^\d+$/.test(x)).map(Number);
  const open = rows.filter((r) => !r.isClosed);
  const bounds: { from: number; to: number | null }[] = [...e.map((to, i) => ({ from: i === 0 ? 0 : e[i - 1]!, to })), { from: e.at(-1) ?? 0, to: null }];
  return {
    buckets: bounds.map((b) => ({ ...b, label: bucketText(b.from, b.to), deals: open.filter((r) => r.sinceLastFrom === b.from && r.sinceLastTo === b.to).length })),
    noHours: open.filter((r) => r.businessDaysSinceLast === null).length,
  };
}

/** The figures per group of one grouping, by key; pipelines by label */
export function attemptGroups(rows: readonly AttemptRecord[], group: AttemptGroup): AttemptGroupRow[] {
  const by = new Map<string, { label: string | null; rows: AttemptRecord[] }>();
  for (const r of rows) {
    const key = group === "day" ? r.date : group === "week" ? r.week : group === "market" ? r.market : `${r.connectionId}:${r.pipelineId}`;
    const g = by.get(key) ?? { label: group === "pipeline" ? r.pipelineLabel : null, rows: [] };
    g.rows.push(r);
    by.set(key, g);
  }
  return [...by.entries()]
    .sort((a, b) => (a[1].label ?? "").localeCompare(b[1].label ?? "") || a[0].localeCompare(b[0]))
    .map(([groupKey, g]) => ({ groupKey, label: g.label, ...attemptFigures(g.rows) }));
}

/**
 * The list: open deals first, the longest since the last attempt first (then the earlier last attempt or creation),
 * a market without business hours after them; then the closed deals, the newest close first; the first `limit`
 */
export function attemptList(rows: readonly AttemptRecord[], limit: number): { rows: AttemptListRow[]; total: number } {
  const sorted = [...rows].sort((a, b) => {
    if (a.isClosed !== b.isClosed) return a.isClosed ? 1 : -1;
    if (!a.isClosed) {
      const da = a.businessDaysSinceLast ?? -1;
      const db = b.businessDaysSinceLast ?? -1;
      if (da !== db) return db - da;
      return (a.lastAttemptAt ?? a.createdAt).localeCompare(b.lastAttemptAt ?? b.createdAt) || b.createdAt.localeCompare(a.createdAt)
        || a.dealSourceId.localeCompare(b.dealSourceId);
    }
    return (b.closedAt ?? b.createdAt).localeCompare(a.closedAt ?? a.createdAt) || b.createdAt.localeCompare(a.createdAt)
      || a.dealSourceId.localeCompare(b.dealSourceId);
  });
  return {
    total: rows.length,
    rows: sorted.slice(0, limit).map((r) => ({
      connectionId: r.connectionId, dealSourceId: r.dealSourceId, recordUrl: r.recordUrl, pipelineLabel: r.pipelineLabel, market: r.market,
      createdAt: r.createdAt, closedAt: r.closedAt, isClosed: r.isClosed, outcome: r.outcome, attempts: r.attempts, connected: r.connected,
      firstConnectedAttempt: r.firstConnectedAttempt, lastAttemptAt: r.lastAttemptAt, businessDaysSinceLast: r.businessDaysSinceLast,
      sinceLastBucket: r.sinceLastBucket,
    })),
  };
}

/**
 * Per deal owner, as cma.attempts_per_person_of: the deals each owns, by name and never ranked; the deals of owner ids
 * without a person (or without an owner) as one not-linked row with how many owner ids that is, never which; the total
 */
export function attemptsPerPerson(rows: readonly AttemptRecord[], nameOf: (userId: string) => string | null): { rows: AttemptPerson[]; total: AttemptPerson } {
  const make = (kind: AttemptPerson["kind"], userId: string | null, list: AttemptRecord[]): AttemptPerson => ({
    kind, userId, name: userId ? nameOf(userId) : null,
    unlinkedOwners: kind === "notLinked" ? new Set(list.map((r) => r.ownerRef).filter((x) => x !== null)).size : null,
    ...attemptFigures(list),
  });
  const people = new Map<string, AttemptRecord[]>();
  const unlinked: AttemptRecord[] = [];
  for (const r of rows) {
    if (r.ownerUserId && nameOf(r.ownerUserId) !== null) people.set(r.ownerUserId, [...(people.get(r.ownerUserId) ?? []), r]);
    else unlinked.push(r);
  }
  const out = [...people.entries()].map(([id, list]) => make("person", id, list))
    .sort((a, b) => (a.name ?? "").localeCompare(b.name ?? "") || (a.userId ?? "").localeCompare(b.userId ?? ""));
  if (unlinked.length > 0) out.push(make("notLinked", null, unlinked));
  return { rows: out, total: make("total", null, [...rows]) };
}

// ---- The screen ------------------------------------------------------------------------------------------

/** Deals reached on their first attempt as a share of the deals attempted, 0 to 1; null without an attempted deal */
export function firstReachShare(f: Pick<AttemptFigures, "firstReached" | "attempted">): number | null {
  return f.attempted === 0 ? null : f.firstReached / f.attempted;
}

/** Deals first connected on an attempt as a share of the deals attempted; null without an attempted deal */
export function reachShare(b: Pick<AttemptBucket, "firstConnected">, attempted: number): number | null {
  return attempted === 0 ? null : b.firstConnected / attempted;
}

/** Won of the closed deals with an outcome in a bucket; null without one */
export function wonRate(b: Pick<AttemptBucket, "won" | "lost">): number | null {
  return b.won + b.lost === 0 ? null : b.won / (b.won + b.lost);
}

/** Attempts with one decimal in the reader's language; a dash without */
export function fmtAttempts(value: number | null, locale: "en" | "nl"): string {
  if (value === null) return "–";
  return new Intl.NumberFormat(locale === "nl" ? "nl-NL" : "en-GB", { minimumFractionDigits: 1, maximumFractionDigits: 1 }).format(value);
}

/** The single hue of the time-since-last bars (Pulse4all-Style 7.7: one series, neutral, no red) */
export const SINCE_LAST_CLASS = "bg-p4a-lightblue";
/** The distribution, reach and won-rate bars: the series' first colour */
export const ATTEMPTS_BAR_CLASS = "bg-p4a-deepblue";
