/**
 * Attempts per deal (addition 0008y; for sales since 0008z, 20 October 2026): Reports → Attempts per deal and Attempts per
 * agent. How many attempts a sales deal gets, how often and how soon they lead to a conversation, Closed Won against Closed
 * Lost on attempts and speed to lead (Kira), and how long the open deals have waited since their last attempt. The figures
 * come from the database (cma.attempts_per_deal_page, cma.attempts_per_person_page, cma.attempts_of_deal); this module
 * mirrors their definitions for the mock and for verify/reports.mjs, and arranges the rows for the screen. Pure, with no
 * runtime imports beyond time.ts and reports.ts, so the verifier runs it under Node's type stripping.
 *
 * The definitions (README, Data model: attempts per deal), one place in the database (cma.sales_deals_of,
 * cma.deal_attempts_of, cma.attempts_per_deal_of):
 *   deal         a deal of a counted lead pipeline, never of an order pipeline; not deleted, created on or after
 *                intake.start_date; its date in the tenant's zone
 *   window       from the creation minus speed_to_lead.pre_window_minutes to the earliest of the close (won or lost),
 *                the first order of the deal's contacts after its creation (a won order deal at its close, a store order
 *                at its creation) and now
 *   attempt      telephony (attempts.source, the default): an outbound telephony call on a counted line whose CRM call is
 *                associated with the deal or its contacts; crm: every outbound CRM call; in the window
 *   conversation (0008zc; docs/definitions.md) the linked telephony call is connected (cma.is_connected), has at least
 *                calls.conversation_min_talk_seconds of talk time and carries no tag meaning not reached
 *                (cma.is_conversation); the CRM call's outcome decides nothing, and a call without a telephony call is none
 *   speed        business seconds from the creation to the first attempt (0007d's business time); called before the next
 *                business noon as 0007d
 *   outcome      won by the stage; else ordered (the window ended at an order); else lost by the stage; else unknown
 *                (closed) or open
 *   since last   an open deal's business days in its market since its last attempt, else its creation; none for an
 *                unknown market; bucketed by attempts.since_last_buckets_business_days
 * Ids, codes, counts, links and times only: no name, address or phone number of a customer exists here.
 */
import type {
  AttemptAttempted, AttemptBucket, AttemptFigures, AttemptFilter, AttemptGroup, AttemptGroupRow, AttemptListRow, AttemptOutcome,
  AttemptOutcomeFilter, AttemptOutcomeRow, AttemptPerson, AttemptSource, AttemptSpeedBucket, AttemptWindowEnd, DateKey, DealAttempt, Instant,
  SinceLastBucket,
} from "./data/types";
import type { Copy } from "./copy";
// With their extensions, so verify/reports.mjs can run this module under Node's type stripping
import { round1, timeInZone } from "./reports.ts";
import { addDays, dateKeyInZone, startOfWeek } from "./time.ts";

export const ATTEMPT_GROUPS: readonly AttemptGroup[] = ["day", "week", "market", "pipeline"];
export const ATTEMPT_ATTEMPTED: readonly AttemptAttempted[] = ["all", "none", "some"];
export const ATTEMPT_OUTCOMES: readonly AttemptOutcomeFilter[] = ["all", "open", "won", "lost", "ordered"];

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

export type AttemptFilterProblem = null | "market" | "pipeline" | "attempted" | "outcome";

/**
 * The filters from a query, as cma.attempts_filters_check and cma.attempts_choices_check take them: a market is a
 * two-letter code or "unknown", a pipeline a connection id and a pipeline id joined by ':', attempted all (the default),
 * none or some, the outcome all (the default), open, won, lost or ordered; empty means all. `problem` names a value the
 * database would refuse; that filter is then left out
 */
export function parseAttemptFilter(market: unknown, pipeline: unknown, attempted: unknown, outcome: unknown):
  { filter: AttemptFilter; problem: AttemptFilterProblem } {
  const filter: AttemptFilter = { market: null, pipeline: null, attempted: "all", outcome: "all" };
  let problem: AttemptFilterProblem = null;
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
  const a = text(attempted);
  if (a !== null) {
    if ((ATTEMPT_ATTEMPTED as readonly string[]).includes(a)) filter.attempted = a as AttemptAttempted;
    else problem ??= "attempted";
  }
  const o = text(outcome);
  if (o !== null) {
    if ((ATTEMPT_OUTCOMES as readonly string[]).includes(o)) filter.outcome = o as AttemptOutcomeFilter;
    else problem ??= "outcome";
  }
  return { filter, problem };
}

/** The filter as query parameters (keys market, pipeline, attempted, outcome); the defaults left out */
export function attemptFilterQuery(filter: AttemptFilter): Record<string, string> {
  const out: Record<string, string> = {};
  if (filter.market) out.market = filter.market;
  if (filter.pipeline) out.pipeline = filter.pipeline;
  if (filter.attempted !== "all") out.attempted = filter.attempted;
  if (filter.outcome !== "all") out.outcome = filter.outcome;
  return out;
}

// ---- The mock's fixture and the definitions -----------------------------------------------------------

/** A CRM call with a deal or one of its contacts (cma.deal_calls_of), at its effective start (the linked telephony call's, else the CRM's) */
export interface AttemptCallFixture {
  id: string;
  at: Instant;
  /** The CRM call's direction */
  direction: "outbound" | "inbound";
  /** A current link to a telephony call with a start, not deleted */
  linked: boolean;
  /** The linked telephony call's line counts (a line not yet in the catalog counts); true when absent */
  lineCounted?: boolean;
  /** The outcome's label from the catalog; null without an outcome. It describes the call and decides nothing (0008zc) */
  outcome: string | null;
  /** The linked telephony call is connected: outbound and answered (cma.is_connected at telephony.connected_min_seconds 0) */
  connected: boolean;
  /** Ended - answered of the linked telephony call; null without one, unanswered or not ended */
  talkSeconds: number | null;
  /** The linked telephony call carries a current tag meaning not reached (cma.call_not_reached_of) */
  notReached?: boolean;
  /** The person behind the telephony user, else the CRM call's owner; null when nobody */
  agentName: string | null;
}

/** A first-order candidate of a deal's current contacts: a won order deal (at its close) or a store order (at its creation) */
export interface AttemptOrderFixture {
  createdAt: Instant;
  at: Instant;
}

/** One deal as the mock holds it, with the calls the database would find for it (before the pre-window) and its contacts' orders */
export interface AttemptDealFixture {
  dealId: string;
  connectionId: string;
  dealSourceId: string;
  pipelineId: string;
  pipelineLabel: string;
  stageLabel: string | null;
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
  orders: AttemptOrderFixture[];
}

/** A deal as cma.attempts_per_deal_of returns it */
export interface AttemptRecord {
  dealId: string;
  connectionId: string;
  dealSourceId: string;
  recordUrl: string | null;
  pipelineId: string;
  pipelineLabel: string;
  stageLabel: string | null;
  market: string;
  ownerRef: string | null;
  ownerUserId: string | null;
  createdAt: Instant;
  date: DateKey;
  week: DateKey;
  localTime: string;
  isClosed: boolean;
  closedAt: Instant | null;
  orderedAt: Instant | null;
  windowEndReason: AttemptWindowEnd;
  outcome: AttemptOutcome;
  attempts: number;
  conversationAttempts: number;
  firstConversationAttempt: number | null;
  talkSecondsTotal: number;
  talkSecondsConversation: number;
  firstAttemptAt: Instant | null;
  speedToLeadSeconds: number | null;
  calledBeforeNextNoon: boolean | null;
  lastAttemptAt: Instant | null;
  businessDaysSinceLast: number | null;
  sinceLastFrom: number | null;
  sinceLastTo: number | null;
  sinceLastBucket: string | null;
  attemptsWithoutOutcome: number;
  loggedWithoutAircall: number;
}

/** Whether a market works on a date: office hours that weekday and no holiday (the market's or every market's) */
export type WorkingDay = (market: string, date: DateKey) => boolean;

/** What the definition reads besides the deals: the settings and 0007d's business time, as the mock or a verifier has them */
export interface AttemptOptions {
  source: AttemptSource;
  preWindowMinutes: number;
  conversationMinTalkSeconds: number;
  sinceLastBuckets: string;
  now: Instant;
  tenantZone: string;
  working: WorkingDay;
  ownerUserOf: (ownerRef: string | null) => string | null;
  /** cma.business_seconds_of: office seconds in a market between two instants (0 when the second is not later); null for an unknown market */
  businessSeconds: (market: string, from: Instant, to: Instant) => number | null;
  /** cma.next_business_noon_of: 12:00 on the first working day after the instant's local date; null for an unknown market */
  nextNoon: (market: string, at: Instant) => Instant | null;
}

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

const ms = (x: Instant) => Date.parse(x);

/** The window of a deal as of `now` (cma.sales_deals_of): the first order, where the window ends and why, the outcome */
export function attemptWindow(d: AttemptDealFixture, now: Instant): { orderedAt: Instant | null; end: number; reason: AttemptWindowEnd; outcome: AttemptOutcome } {
  const t = ms(now);
  const orders = d.orders.filter((o) => ms(o.createdAt) >= ms(d.createdAt) && ms(o.at) <= t).map((o) => o.at).sort();
  const orderedAt = orders[0] ?? null;
  const closedEnd = d.isClosed ? Math.min(d.closedAt ? ms(d.closedAt) : t, t) : null;
  const end = Math.min(closedEnd ?? Infinity, orderedAt ? ms(orderedAt) : Infinity, t);
  const reason: AttemptWindowEnd = closedEnd !== null && (orderedAt === null || closedEnd <= ms(orderedAt)) ? "closed" : orderedAt !== null ? "ordered" : "open";
  const outcome: AttemptOutcome = d.stageOutcome === "won" ? "won" : reason === "ordered" ? "ordered" : d.stageOutcome === "lost" ? "lost"
    : d.isClosed ? "unknown" : "open";
  return { orderedAt, end, reason, outcome };
}

/**
 * A deal's calls in its window that are attempts, numbered in order of their start (then the CRM call's id), each a conversation
 * or not (cma.deal_attempts_of): from the linked telephony call only, connected with at least the threshold of talk time and no
 * tag meaning not reached
 */
export function dealAttemptCalls(d: AttemptDealFixture, o: Pick<AttemptOptions, "source" | "preWindowMinutes" | "conversationMinTalkSeconds">, end: number):
  { attempts: (AttemptCallFixture & { n: number; conversation: boolean })[]; withoutAircall: number } {
  const inWindow = d.calls.filter((c) => ms(c.at) >= ms(d.createdAt) - o.preWindowMinutes * 60_000 && ms(c.at) <= end);
  const attempts = inWindow
    .filter((c) => (o.source === "crm" ? c.direction === "outbound" : c.linked && c.direction === "outbound" && c.lineCounted !== false))
    .sort((x, y) => x.at.localeCompare(y.at) || x.id.localeCompare(y.id))
    .map((c, i) => {
      const conversation = c.linked && c.connected && c.talkSeconds !== null && c.talkSeconds >= o.conversationMinTalkSeconds && !c.notReached;
      return { ...c, n: i + 1, conversation };
    });
  return { attempts, withoutAircall: inWindow.filter((c) => c.direction === "outbound" && !c.linked).length };
}

/** The sales deals as cma.attempts_per_deal_of computes them, as of `now` */
export function attemptRecords(deals: readonly AttemptDealFixture[], o: AttemptOptions): AttemptRecord[] {
  const now = ms(o.now);
  return deals
    .filter((d) => d.isCounted && d.isLead && !d.isOrder && ms(d.createdAt) <= now)
    .map((d) => {
      const w = attemptWindow(d, o.now);
      const { attempts, withoutAircall } = dealAttemptCalls(d, o, w.end);
      const first = attempts[0] ?? null;
      const last = attempts.at(-1)?.at ?? null;
      const firstConversation = attempts.find((a) => a.conversation)?.n ?? null;
      const noon = o.nextNoon(d.market, d.createdAt);
      const days = w.outcome === "open" ? businessDays(d.market, d.zone, last ?? d.createdAt, o.now, o.working) : null;
      const bucket = ageBucket(days, o.sinceLastBuckets);
      const date = dateKeyInZone(d.createdAt, o.tenantZone);
      return {
        dealId: d.dealId, connectionId: d.connectionId, dealSourceId: d.dealSourceId, recordUrl: d.recordUrl, pipelineId: d.pipelineId,
        pipelineLabel: d.pipelineLabel, stageLabel: d.stageLabel, market: d.market, ownerRef: d.ownerRef, ownerUserId: o.ownerUserOf(d.ownerRef),
        createdAt: d.createdAt, date, week: startOfWeek(date), localTime: timeInZone(d.createdAt, o.tenantZone), isClosed: d.isClosed,
        closedAt: d.closedAt, orderedAt: w.orderedAt, windowEndReason: w.reason, outcome: w.outcome,
        attempts: attempts.length, conversationAttempts: attempts.filter((a) => a.conversation).length, firstConversationAttempt: firstConversation,
        talkSecondsTotal: attempts.reduce((s, a) => s + (a.talkSeconds ?? 0), 0),
        talkSecondsConversation: attempts.filter((a) => a.conversation).reduce((s, a) => s + (a.talkSeconds ?? 0), 0),
        firstAttemptAt: first?.at ?? null, speedToLeadSeconds: first ? o.businessSeconds(d.market, d.createdAt, first.at) : null,
        calledBeforeNextNoon: first ? (noon === null ? null : ms(first.at) < ms(noon)) : noon !== null && now >= ms(noon) ? false : null,
        lastAttemptAt: last, businessDaysSinceLast: days, sinceLastFrom: bucket?.from ?? null, sinceLastTo: bucket?.to ?? null,
        sinceLastBucket: bucket ? bucketText(bucket.from, bucket.to) : null,
        attemptsWithoutOutcome: attempts.filter((a) => a.outcome === null).length, loggedWithoutAircall: withoutAircall,
      };
    });
}

/** One deal's attempts as cma.attempts_of_deal answers them; the agent's name only when `names` (per-person figures on, performance.team) */
export function dealAttempts(d: AttemptDealFixture, o: AttemptOptions, names: boolean): DealAttempt[] {
  const w = attemptWindow(d, o.now);
  return dealAttemptCalls(d, o, w.end).attempts.map((a) => ({
    n: a.n, startedAt: a.at, connected: a.linked && a.connected, talkSeconds: a.talkSeconds, conversation: a.conversation,
    outcomeLabel: a.outcome, agentName: names ? a.agentName : null,
  }));
}

/** The deals of business dates [from, to], cut on `to` at `until`'s time of day (the previous span), narrowed by the filter */
export function attemptsInPeriod(rows: readonly AttemptRecord[], from: DateKey, to: DateKey, filter: AttemptFilter,
  until: Instant | null = null, tenantZone = "Europe/Amsterdam"): AttemptRecord[] {
  return rows.filter((r) => r.date >= from && r.date <= to
    && (until === null || r.date < to || r.localTime <= timeInZone(until, tenantZone))
    && (filter.market === null || r.market === filter.market)
    && (filter.pipeline === null || `${r.connectionId}:${r.pipelineId}` === filter.pipeline)
    && (filter.attempted === "all" || (filter.attempted === "none") === (r.attempts === 0))
    && (filter.outcome === "all" || r.outcome === filter.outcome));
}

/** percentile_cont(0.5) of values; null without values */
function percentile(values: readonly number[]): number | null {
  if (values.length === 0) return null;
  const v = [...values].sort((a, b) => a - b);
  const mid = (v.length - 1) / 2;
  return (v[Math.floor(mid)]! + v[Math.ceil(mid)]!) / 2;
}

/** The figures of a set of deals, as cma.attempts_figures_from aggregates them */
export function attemptFigures(rows: readonly AttemptRecord[]): AttemptFigures {
  const sum = rows.reduce((s, r) => s + r.attempts, 0);
  const median = percentile(rows.map((r) => r.attempts));
  const speed = percentile(rows.map((r) => r.speedToLeadSeconds).filter((x): x is number => x !== null));
  const total = (pick: (r: AttemptRecord) => number) => rows.reduce((s, r) => s + pick(r), 0);
  return {
    deals: rows.length,
    attempted: rows.filter((r) => r.attempts > 0).length,
    attempts: sum,
    avgAttempts: rows.length === 0 ? null : Math.round((sum / rows.length) * 100) / 100,
    medianAttempts: median === null ? null : round1(median),
    conversationDeals: rows.filter((r) => r.conversationAttempts > 0).length,
    firstConversation: rows.filter((r) => r.firstConversationAttempt === 1).length,
    conversationAttempts: total((r) => r.conversationAttempts),
    speedDeals: rows.filter((r) => r.speedToLeadSeconds !== null).length,
    medianSpeedSeconds: speed === null ? null : Math.round(speed),
    noonKnown: rows.filter((r) => r.calledBeforeNextNoon !== null).length,
    calledBeforeNoon: rows.filter((r) => r.calledBeforeNextNoon === true).length,
    openDeals: rows.filter((r) => r.outcome === "open").length,
    openNeverAttempted: rows.filter((r) => r.outcome === "open" && r.attempts === 0).length,
    won: rows.filter((r) => r.outcome === "won").length,
    lost: rows.filter((r) => r.outcome === "lost").length,
    ordered: rows.filter((r) => r.outcome === "ordered").length,
    unknown: rows.filter((r) => r.outcome === "unknown").length,
    talkSecondsTotal: total((r) => r.talkSecondsTotal),
    talkSecondsConversation: total((r) => r.talkSecondsConversation),
    attemptsWithoutOutcome: total((r) => r.attemptsWithoutOutcome),
    loggedWithoutAircall: total((r) => r.loggedWithoutAircall),
  };
}

/** Per attempt bucket 0 to max ("max+"), as cma.attempts_buckets_from: deals, their first conversation there, won and lost */
export function attemptBuckets(rows: readonly AttemptRecord[], max: number): AttemptBucket[] {
  return Array.from({ length: max + 1 }, (_, b) => {
    const at = rows.filter((r) => Math.min(r.attempts, max) === b);
    return {
      bucket: b, label: b === max ? `${b}+` : String(b), deals: at.length,
      firstConversation: rows.filter((r) => r.firstConversationAttempt !== null && Math.min(r.firstConversationAttempt, max) === b).length,
      won: at.filter((r) => r.outcome === "won").length, lost: at.filter((r) => r.outcome === "lost").length,
    };
  });
}

/** Won against lost, as cma.attempts_outcomes_from: one row each, the deals not decided counted apart */
export function attemptOutcomes(rows: readonly AttemptRecord[]): { rows: AttemptOutcomeRow[]; notDecided: number; open: number; ordered: number; unknown: number } {
  const row = (outcome: "won" | "lost"): AttemptOutcomeRow => {
    const mine = rows.filter((r) => r.outcome === outcome);
    const f = attemptFigures(mine);
    const withConversation = mine.filter((r) => r.conversationAttempts > 0);
    return {
      outcome, deals: f.deals, avgAttempts: f.avgAttempts, medianAttempts: f.medianAttempts, speedDeals: f.speedDeals, medianSpeedSeconds: f.medianSpeedSeconds,
      noonKnown: f.noonKnown, calledBeforeNoon: f.calledBeforeNoon, conversationDeals: f.conversationDeals,
      avgTalkConversationSeconds: withConversation.length === 0 ? null
        : Math.round(withConversation.reduce((s, r) => s + r.talkSecondsConversation, 0) / withConversation.length),
    };
  };
  const count = (o: AttemptOutcome) => rows.filter((r) => r.outcome === o).length;
  return { rows: [row("won"), row("lost")], notDecided: count("open") + count("ordered") + count("unknown"), open: count("open"), ordered: count("ordered"), unknown: count("unknown") };
}

/** The bounds of increasing edges ("5,15,60"): 0–5, 5–15, 15–60, 60+ */
function edgeBounds(edges: string): { from: number; to: number | null }[] {
  const e = edges.replace(/\s/g, "").split(",").filter((x) => /^\d+$/.test(x)).map(Number);
  return [...e.map((to, i) => ({ from: i === 0 ? 0 : e[i - 1]!, to })), { from: e.at(-1) ?? 0, to: null }];
}

/**
 * The win rate by speed to lead, as cma.attempts_speed_buckets_from: of the decided deals, the won and the lost per bucket of
 * business minutes (rounded up, so a speed at an edge falls in the bucket that ends there); the decided deals never attempted
 * and those attempted in a market without business hours apart
 */
export function attemptSpeedBuckets(rows: readonly AttemptRecord[], edges: string): { buckets: AttemptSpeedBucket[]; none: { won: number; lost: number }; noHours: number } {
  const decided = rows.filter((r) => r.outcome === "won" || r.outcome === "lost");
  const placed = decided.map((r) => ({ r, b: ageBucket(r.speedToLeadSeconds === null ? null : Math.ceil(r.speedToLeadSeconds / 60), edges) }));
  return {
    buckets: edgeBounds(edges).map((b) => {
      const at = placed.filter((p) => p.b !== null && p.b.from === b.from && p.b.to === b.to);
      return { ...b, label: bucketText(b.from, b.to), won: at.filter((p) => p.r.outcome === "won").length, lost: at.filter((p) => p.r.outcome === "lost").length };
    }),
    none: { won: decided.filter((r) => r.attempts === 0 && r.outcome === "won").length, lost: decided.filter((r) => r.attempts === 0 && r.outcome === "lost").length },
    noHours: decided.filter((r) => r.attempts > 0 && r.speedToLeadSeconds === null).length,
  };
}

/** The open deals by business days since the last attempt, every bucket of the edges listed; an unknown market apart */
export function sinceLastBuckets(rows: readonly AttemptRecord[], edges: string): { buckets: SinceLastBucket[]; noHours: number } {
  const open = rows.filter((r) => r.outcome === "open");
  return {
    buckets: edgeBounds(edges).map((b) => ({ ...b, label: bucketText(b.from, b.to), deals: open.filter((r) => r.sinceLastFrom === b.from && r.sinceLastTo === b.to).length })),
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

/** Where a decided deal's window ended: its close or its first order */
const endedAt = (r: AttemptRecord) => (r.windowEndReason === "closed" ? r.closedAt : r.windowEndReason === "ordered" ? r.orderedAt : null);

/**
 * The list: open deals first, the longest since the last attempt first (then the earlier last attempt or creation), a
 * market without business hours after them; then the decided deals (closed or ordered), the newest end of the window
 * first; the first `limit`
 */
export function attemptList(rows: readonly AttemptRecord[], limit: number): { rows: AttemptListRow[]; total: number } {
  const sorted = [...rows].sort((a, b) => {
    const ao = a.outcome === "open";
    const bo = b.outcome === "open";
    if (ao !== bo) return ao ? -1 : 1;
    if (ao) {
      const da = a.businessDaysSinceLast ?? -1;
      const db = b.businessDaysSinceLast ?? -1;
      if (da !== db) return db - da;
      return (a.lastAttemptAt ?? a.createdAt).localeCompare(b.lastAttemptAt ?? b.createdAt) || b.createdAt.localeCompare(a.createdAt)
        || a.dealSourceId.localeCompare(b.dealSourceId);
    }
    return (endedAt(b) ?? b.createdAt).localeCompare(endedAt(a) ?? a.createdAt) || b.createdAt.localeCompare(a.createdAt)
      || a.dealSourceId.localeCompare(b.dealSourceId);
  });
  return {
    total: rows.length,
    rows: sorted.slice(0, limit).map((r) => ({
      dealId: r.dealId, connectionId: r.connectionId, dealSourceId: r.dealSourceId, recordUrl: r.recordUrl, pipelineLabel: r.pipelineLabel,
      stageLabel: r.stageLabel, market: r.market, createdAt: r.createdAt, closedAt: r.closedAt, orderedAt: r.orderedAt, windowEndReason: r.windowEndReason,
      outcome: r.outcome, attempts: r.attempts, conversationAttempts: r.conversationAttempts, firstConversationAttempt: r.firstConversationAttempt,
      talkSecondsTotal: r.talkSecondsTotal, talkSecondsConversation: r.talkSecondsConversation, firstAttemptAt: r.firstAttemptAt,
      speedToLeadSeconds: r.speedToLeadSeconds, calledBeforeNextNoon: r.calledBeforeNextNoon, lastAttemptAt: r.lastAttemptAt,
      businessDaysSinceLast: r.businessDaysSinceLast, sinceLastBucket: r.sinceLastBucket, loggedWithoutAircall: r.loggedWithoutAircall,
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

const share = (part: number, whole: number) => (whole === 0 ? null : part / whole);

/** Deals attempted at least once as a share of the deals; null without a deal */
export function attemptedShare(f: Pick<AttemptFigures, "attempted" | "deals">): number | null {
  return share(f.attempted, f.deals);
}

/** Deals with at least one conversation as a share of the deals; null without a deal */
export function conversationShare(f: Pick<AttemptFigures, "conversationDeals" | "deals">): number | null {
  return share(f.conversationDeals, f.deals);
}

/** Deals whose first attempt was a conversation as a share of the deals attempted, 0 to 1; null without an attempted deal */
export function firstConversationShare(f: Pick<AttemptFigures, "firstConversation" | "attempted">): number | null {
  return share(f.firstConversation, f.attempted);
}

/** Deals whose first conversation was an attempt's as a share of the deals attempted; null without an attempted deal */
export function firstConversationOnShare(b: Pick<AttemptBucket, "firstConversation">, attempted: number): number | null {
  return share(b.firstConversation, attempted);
}

/** Called before the next business noon, of the deals whose answer is known; null without one */
export function noonShare(f: Pick<AttemptFigures, "calledBeforeNoon" | "noonKnown">): number | null {
  return share(f.calledBeforeNoon, f.noonKnown);
}

/** Attempts without an outcome as a share of the attempts (the data prerequisite: agents set the outcome); null without an attempt */
export function withoutOutcomeShare(f: Pick<AttemptFigures, "attemptsWithoutOutcome" | "attempts">): number | null {
  return share(f.attemptsWithoutOutcome, f.attempts);
}

/** Won of the decided deals in a bucket; null without one */
export function wonRate(b: Pick<AttemptBucket, "won" | "lost">): number | null {
  return share(b.won, b.won + b.lost);
}

/** Attempts with one decimal in the reader's language; a dash without */
export function fmtAttempts(value: number | null, locale: "en" | "nl"): string {
  if (value === null) return "–";
  return new Intl.NumberFormat(locale === "nl" ? "nl-NL" : "en-GB", { minimumFractionDigits: 1, maximumFractionDigits: 1 }).format(value);
}

/** Business seconds as business minutes for fmtBusinessMinutes (one decimal under an hour); null stays null */
export function speedMinutes(seconds: number | null): number | null {
  return seconds === null ? null : Math.round(seconds / 6) / 10;
}

/** The words the Attempts pages' client parts use (the filters, the deal list); never the whole copy, which would travel in the page's payload */
export type AttemptClientCopy = { attempts: Copy["attempts"]; hints: Pick<Copy["hints"], "about">; reports: Pick<Copy["reports"], "unknownMarket"> };
export function attemptClientCopy(copy: Copy): AttemptClientCopy {
  return { attempts: copy.attempts, hints: { about: copy.hints.about }, reports: { unknownMarket: copy.reports.unknownMarket } };
}

/** The single hue of the time-since-last bars (Pulse4all-Style 7.7: one series, neutral, no red) */
export const SINCE_LAST_CLASS = "bg-p4a-lightblue";
/** The distribution, reach and won-rate bars: the series' first colour */
export const ATTEMPTS_BAR_CLASS = "bg-p4a-deepblue";
