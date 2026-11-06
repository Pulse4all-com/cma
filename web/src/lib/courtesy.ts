/**
 * Customers → Courtesy (addition 0009a, brief B31, Martin, 6 November 2026; docs/definitions.md, Courtesy terms): every
 * First or Repeat store order gets a courtesy call from its due day. The figures come from the database
 * (cma.courtesy_page over cma.courtesy_orders_of); this module mirrors their definitions for the mock and for
 * verify/reports.mjs (on 151's own scenario), parses the page's address and arranges the figures for the screen. Pure, with
 * no runtime imports beyond time.ts, funnel.ts, maintenance.ts, reports.ts and email.ts, so the verifier runs it under
 * Node's type stripping.
 *
 * The definitions (150_courtesy.sql):
 *   courtesy order    a store order, not a test, not deleted, not cancelled, of a kind in courtesy.order_kinds, whose business
 *                     date (its creation in its market's zone) is on or after courtesy.start_date; its contact the CRM
 *                     contact its store customer is linked to; without one it counts as No contact only, with no state
 *   due date          the business date + courtesy.due_days calendar days, due from that date's start in the zone
 *   completed call    a call on the contact (either direction, a counted line, linked through the call link), at or after
 *                     the order's creation, with a current tag meaning courtesy_completed_positive, _neutral or _negative;
 *                     the order's completion is the first such call
 *   attempt           an Attempt (outbound) on the contact from the start of the due date up to and including the completion
 *   state, now        not_due, due_no_attempt, attempted, not_reached (courtesy.alert_attempts attempts, none a
 *                     Conversation: the flag), completed
 * Ids, codes, counts and times only: never a customer's name, email, phone or address.
 */
import type {
  CourtesyCalls, CourtesyCohort, CourtesyCounts, CourtesyFilter, CourtesyFlag, CourtesyGroup, CourtesyOutcome, CourtesyPeriod, CourtesyReport,
  CourtesyState, CourtesyStateFilter, DateKey, Instant,
} from "./data/types";
// With their extensions, so verify/reports.mjs can run this module under Node's type stripping
import { isoWeekLabel } from "./cohorts.ts";
import { zonedInstant } from "./email.ts";
import { inPeriod, type FunnelPrevious } from "./funnel.ts";
import { addMonths, monthOf } from "./maintenance.ts";
import { timeInZone } from "./reports.ts";
import { addDays, dateKeyInZone, isDateKey, startOfWeek } from "./time.ts";

export const COURTESY_STATES: readonly CourtesyState[] = ["not_due", "due_no_attempt", "attempted", "not_reached", "completed"];
/** The state filter's choices in the select's order: the flag first, then due without completion and its parts */
export const COURTESY_STATE_FILTERS: readonly CourtesyStateFilter[] = ["not_reached", "due", "due_no_attempt", "attempted", "not_due", "completed", "no_contact"];
export const COURTESY_GROUPS: readonly CourtesyGroup[] = ["day", "week", "month"];
export const COURTESY_PERIODS: readonly CourtesyPeriod[] = ["week", "month"];
export const COURTESY_OUTCOMES: readonly CourtesyOutcome[] = ["positive", "neutral", "negative"];
/** The five tenant settings (Configuration, Exports, next to the follow-up settings) */
export const COURTESY_SETTING_KEYS = ["courtesy.start_date", "courtesy.order_kinds", "courtesy.due_days", "courtesy.alert_attempts", "courtesy.ages_days"] as const;
export type CourtesySettingKey = (typeof COURTESY_SETTING_KEYS)[number];

// ---- The address ---------------------------------------------------------------------------------------------------

/** The grouping per market and period (G): day, week or month; week when left out or unknown */
export function courtesyGroupOf(value: unknown): CourtesyGroup {
  return COURTESY_GROUPS.includes(value as CourtesyGroup) ? (value as CourtesyGroup) : "week";
}

/** The order cohorts' period (O): week or month; week when left out or unknown */
export function courtesyPeriodOf(value: unknown): CourtesyPeriod {
  return COURTESY_PERIODS.includes(value as CourtesyPeriod) ? (value as CourtesyPeriod) : "week";
}

/** The option after the current one, for a switch's key */
export function nextOf<T>(options: readonly T[], current: T): T {
  return options[(options.indexOf(current) + 1) % options.length]!;
}

const SEGMENT_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$/;

/**
 * The filters from the address, as cma.courtesy_page checks them: a market's code or unknown (K), a segment's code or unknown,
 * a state filter (S). An empty value is no filter; anything else malformed is dropped and named in problem
 */
export function parseCourtesyFilter(market: unknown, segment: unknown, state: unknown): { filter: CourtesyFilter; problem: "market" | "segment" | "state" | null } {
  const text = (v: unknown) => (typeof v === "string" && v !== "" ? v : null);
  const m = text(market);
  const s = text(segment);
  const st = text(state);
  let problem: "market" | "segment" | "state" | null = null;
  const filter: CourtesyFilter = { market: null, segment: null, state: null };
  if (m !== null) {
    if (/^([A-Z]{2}|unknown)$/.test(m)) filter.market = m;
    else problem = "market";
  }
  if (s !== null) {
    if (SEGMENT_RE.test(s)) filter.segment = s;
    else problem ??= "segment";
  }
  if (st !== null) {
    if (COURTESY_STATE_FILTERS.includes(st as CourtesyStateFilter)) filter.state = st as CourtesyStateFilter;
    else problem ??= "state";
  }
  return { filter, problem };
}

/** The filters as the address keeps them */
export function courtesyQuery(filter: CourtesyFilter): Record<string, string> {
  const q: Record<string, string> = {};
  if (filter.market) q.market = filter.market;
  if (filter.segment) q.segment = filter.segment;
  if (filter.state) q.state = filter.state;
  return q;
}

/** Whether an order's state matches the state filter (cma.courtesy_state_matches) */
export function courtesyStateMatches(state: CourtesyState | null, f: CourtesyStateFilter | null): boolean {
  if (f === null) return true;
  if (f === "no_contact") return state === null;
  if (f === "due") return state === "due_no_attempt" || state === "attempted" || state === "not_reached";
  return state === f;
}

// ---- The settings, as cma.check_tenant_setting applies them --------------------------------------------------------

/**
 * A setting's value as the database keeps it, or null when it would be refused: the start date YYYY-MM-DD or empty (not set
 * up); one to three of first, repeat and renewal, each once (spaces dropped); 1 to 60 days; 1 to 20 attempts; one to six
 * increasing whole numbers of days, each at most 90 (spaces dropped)
 */
export function parseCourtesySetting(key: CourtesySettingKey, text: string): string | null {
  const t = text.trim();
  switch (key) {
    case "courtesy.start_date":
      return t === "" || (isDateKey(t) && !Number.isNaN(Date.parse(`${t}T00:00:00Z`)) && new Date(`${t}T00:00:00Z`).toISOString().startsWith(t)) ? t : null;
    case "courtesy.order_kinds": {
      const v = t.replace(/\s+/g, "");
      const items = v.split(",");
      return /^(first|repeat|renewal)(,(first|repeat|renewal)){0,2}$/.test(v) && new Set(items).size === items.length ? v : null;
    }
    case "courtesy.due_days":
    case "courtesy.alert_attempts": {
      if (!/^\d{1,2}$/.test(t)) return null;
      const n = Number(t);
      return n >= 1 && n <= (key === "courtesy.due_days" ? 60 : 20) ? String(n) : null;
    }
    case "courtesy.ages_days": {
      const v = t.replace(/\s+/g, "");
      if (!/^[1-9][0-9]{0,3}(,[1-9][0-9]{0,3}){0,5}$/.test(v)) return null;
      const ages = v.split(",").map(Number);
      for (let i = 1; i < ages.length; i++) if (ages[i]! <= ages[i - 1]!) return null;
      return Math.max(...ages) <= 90 ? v : null;
    }
  }
}

// ---- The mirror of cma.courtesy_orders_of --------------------------------------------------------------------------

/** The tenant's settings as the read takes them */
export interface CourtesySettings {
  /** courtesy.start_date; null while unset (not set up) */
  startDate: DateKey | null;
  orderKinds: string[];
  dueDays: number;
  alertAttempts: number;
  ages: number[];
  /** telephony.connected_min_seconds and calls.conversation_min_talk_seconds (Connected, Conversation) */
  connectedMinSeconds: number;
  conversationMinSeconds: number;
  /** crm.customer_segments, in its spelling */
  segments: string[];
}

/** A store order as the mock holds it, with its store, its market's zone and its customer's linked contact */
export interface CourtesyOrderSource {
  orderId: string;
  orderName: string;
  store: string;
  storeName: string | null;
  /** The store's market; null without a store row */
  market: string | null;
  /** The market's zone, else the store's, else the tenant's */
  zone: string;
  createdAt: Instant;
  kind: "first" | "repeat" | "renewal" | "unknown";
  isTest: boolean;
  deleted: boolean;
  cancelled: boolean;
  /** The CRM contact the store customer is linked to; null: No contact */
  contact: string | null;
  /** The contact's segment property as the CRM states it */
  contactSegment: string | null;
}

/** A call as the call link ties it to a contact (only linked calls of a CRM call associated with the contact) */
export interface CourtesyCallSource {
  callId: string;
  contact: string;
  direction: "inbound" | "outbound";
  startedAt: Instant;
  answered: boolean;
  talkSeconds: number | null;
  lineCounted: boolean;
  deleted: boolean;
  userRef: string | null;
  /** The call's current tags' meanings, with when each was set */
  tags: { meaning: string | null; taggedAt: Instant }[];
}

/** A telephony user linked to a person (app_user_external_id, <adapter>_user) */
export interface CourtesyPersonLink {
  userRef: string;
  userId: string;
  name: string;
}

/** One courtesy order as of an instant (cma.courtesy_order_row) */
export interface CourtesyOrderRow {
  orderId: string;
  orderName: string;
  store: string;
  storeName: string | null;
  market: string;
  zone: string;
  segment: string;
  createdAt: Instant;
  businessDate: DateKey;
  dueDate: DateKey;
  dueAt: Instant;
  hasContact: boolean;
  contact: string | null;
  attempts: number | null;
  conversation: boolean | null;
  lastAttemptAt: Instant | null;
  completedAt: Instant | null;
  completedDate: DateKey | null;
  completedTime: string | null;
  completedCallId: string | null;
  outcome: CourtesyOutcome | null;
  completedBy: string | null;
  state: CourtesyState | null;
}

/** A tag meaning as a courtesy outcome (cma.courtesy_outcome_of) */
export function courtesyOutcomeOf(meaning: string | null): CourtesyOutcome | null {
  return meaning === "courtesy_completed_positive" ? "positive" : meaning === "courtesy_completed_neutral" ? "neutral"
    : meaning === "courtesy_completed_negative" ? "negative" : null;
}

/** Conversation (cma.is_conversation): connected outbound or answered inbound, enough talk, no tag meaning not reached or incorrect data */
function isConversation(c: CourtesyCallSource, s: CourtesySettings): boolean {
  const connected = c.direction === "outbound" && c.answered && (s.connectedMinSeconds <= 0 || (c.talkSeconds ?? -1) >= s.connectedMinSeconds);
  const excluded = c.tags.some((t) => t.meaning === "not_reached" || t.meaning === "incorrect_data");
  return (connected || (c.direction === "inbound" && c.answered)) && (c.talkSeconds ?? -1) >= Math.max(0, s.conversationMinSeconds) && !excluded;
}

/** The courtesy outcome of a call's current tags: the tag set last (then by meaning) of those with a completed meaning */
function outcomeOfCall(c: CourtesyCallSource): CourtesyOutcome | null {
  const done = c.tags.filter((t) => courtesyOutcomeOf(t.meaning) !== null)
    .sort((a, b) => b.taggedAt.localeCompare(a.taggedAt) || (a.meaning ?? "").localeCompare(b.meaning ?? ""));
  return done.length === 0 ? null : courtesyOutcomeOf(done[0]!.meaning);
}

/** The segment as Flash counts it (cma.flash_segment_of): the setting's value it equals whatever its case, else unknown */
function segmentOf(value: string | null, segments: readonly string[]): string {
  const v = (value ?? "").trim().toLowerCase();
  return segments.find((x) => x.toLowerCase() === v && v !== "") ?? "unknown";
}

/** Every courtesy order since courtesy.start_date as of now (cma.courtesy_orders_of with no bounds); none while unset */
export function courtesyOrders(orders: readonly CourtesyOrderSource[], calls: readonly CourtesyCallSource[], people: readonly CourtesyPersonLink[],
  s: CourtesySettings, now: Instant): CourtesyOrderRow[] {
  if (s.startDate === null) return [];
  const start = s.startDate;
  const nowMs = Date.parse(now);
  const byContact = new Map<string, CourtesyCallSource[]>();
  for (const c of calls) {
    if (c.deleted || !c.lineCounted || Date.parse(c.startedAt) > nowMs) continue;
    const list = byContact.get(c.contact) ?? [];
    list.push(c);
    byContact.set(c.contact, list);
  }
  for (const list of byContact.values()) list.sort((a, b) => a.startedAt.localeCompare(b.startedAt) || a.callId.localeCompare(b.callId));
  const personOf = new Map(people.map((p) => [p.userRef, p.userId]));
  const out: CourtesyOrderRow[] = [];
  for (const o of orders) {
    if (o.isTest || o.deleted || o.cancelled || !s.orderKinds.includes(o.kind)) continue;
    const businessDate = dateKeyInZone(o.createdAt, o.zone);
    if (businessDate < start) continue;
    const dueDate = addDays(businessDate, s.dueDays);
    const dueMs = zonedInstant(dueDate, "00:00", o.zone);
    const base = {
      orderId: o.orderId, orderName: o.orderName, store: o.store, storeName: o.storeName, market: o.market ?? "unknown", zone: o.zone,
      createdAt: o.createdAt, businessDate, dueDate, dueAt: new Date(dueMs).toISOString(),
    };
    if (o.contact === null) {
      out.push({ ...base, segment: "unknown", hasContact: false, contact: null, attempts: null, conversation: null, lastAttemptAt: null, completedAt: null,
        completedDate: null, completedTime: null, completedCallId: null, outcome: null, completedBy: null, state: null });
      continue;
    }
    const own = byContact.get(o.contact) ?? [];
    const done = own.find((c) => outcomeOfCall(c) !== null && c.startedAt >= o.createdAt) ?? null;
    const endMs = done ? Date.parse(done.startedAt) : nowMs;
    const attempts = own.filter((c) => c.direction === "outbound" && Date.parse(c.startedAt) >= dueMs && Date.parse(c.startedAt) <= endMs);
    const conversation = attempts.some((c) => isConversation(c, s));
    const state: CourtesyState = done ? "completed" : nowMs < dueMs ? "not_due" : attempts.length === 0 ? "due_no_attempt"
      : attempts.length >= s.alertAttempts && !conversation ? "not_reached" : "attempted";
    out.push({
      ...base, segment: segmentOf(o.contactSegment, s.segments), hasContact: true, contact: o.contact, attempts: attempts.length, conversation,
      lastAttemptAt: attempts.length ? attempts[attempts.length - 1]!.startedAt : null,
      completedAt: done?.startedAt ?? null, completedDate: done ? dateKeyInZone(done.startedAt, o.zone) : null,
      completedTime: done ? timeInZone(done.startedAt, o.zone) : null, completedCallId: done?.callId ?? null, outcome: done ? outcomeOfCall(done) : null,
      completedBy: done?.userRef ? personOf.get(done.userRef) ?? null : null, state,
    });
  }
  return out.sort((a, b) => a.createdAt.localeCompare(b.createdAt) || a.orderId.localeCompare(b.orderId));
}

// ---- The mirror of cma.courtesy_page_of ----------------------------------------------------------------------------

const STATE_RANK: Record<string, number> = { not_reached: 1, due_no_attempt: 2, attempted: 3, not_due: 4, completed: 6 };

function calls(rows: readonly CourtesyOrderRow[]): CourtesyCalls {
  const ids = (o: CourtesyOutcome | null) => new Set(rows.filter((r) => r.completedCallId !== null && (o === null || r.outcome === o)).map((r) => r.completedCallId)).size;
  return { calls: ids(null), positive: ids("positive"), neutral: ids("neutral"), negative: ids("negative") };
}

function counts(rows: readonly CourtesyOrderRow[]): CourtesyCounts {
  return { orders: rows.filter((r) => r.hasContact).length, completed: rows.filter((r) => r.state === "completed").length,
    notReached: rows.filter((r) => r.state === "not_reached").length, noContact: rows.filter((r) => !r.hasContact).length };
}

/** The page as cma.courtesy_page_of answers it; `rows` every courtesy order as of now (courtesyOrders) */
export function courtesyReport(rows: readonly CourtesyOrderRow[], opts: {
  from: DateKey; to: DateKey; period: CourtesyPeriod; group: CourtesyGroup; filter: CourtesyFilter; rows: number; perPerson: boolean; now: Instant;
  prev: FunnelPrevious; settings: CourtesySettings; hasStore: boolean; markets: readonly { code: string; name: string; sortOrder: number }[];
  people: readonly { userId: string; name: string }[];
}): CourtesyReport {
  const { from, to, period, group, filter, settings: s } = opts;
  const head = {
    from, to, period, group, filter, rows: opts.rows, setUp: s.startDate !== null, hasStore: opts.hasStore, startDate: s.startDate,
    settings: { dueDays: s.dueDays, alertAttempts: s.alertAttempts, ages: [...s.ages], orderKinds: [...s.orderKinds] },
    segments: [...s.segments, "unknown"],
  };
  if (s.startDate === null) {
    return { ...head, now: null, completed: null, previous: null, previousFrom: null, previousTo: null, previousPartial: false, byMarket: [], byGroup: [],
      cohorts: [], perPerson: null, list: { total: 0, rows: [] }, markets: [] };
  }
  const sortOf = new Map(opts.markets.map((m) => [m.code, m.sortOrder]));
  const nameOf = new Map(opts.markets.map((m) => [m.code, m.name]));
  const marketOrder = (a: string, b: string) => (a === "unknown" ? 1 : 0) - (b === "unknown" ? 1 : 0)
    || (sortOf.get(a) ?? Number.MAX_SAFE_INTEGER) - (sortOf.get(b) ?? Number.MAX_SAFE_INTEGER) || a.localeCompare(b);
  const f = rows.filter((r) => (filter.market === null || r.market === filter.market) && (filter.segment === null || r.segment === filter.segment));
  const doneIn = (r: CourtesyOrderRow) => r.completedCallId !== null && inPeriod(r.completedDate!, r.completedTime!, from, to, null);
  const donePrev = (r: CourtesyOrderRow) => r.completedCallId !== null
    && inPeriod(r.completedDate!, r.completedTime!, opts.prev.from, opts.prev.to, opts.prev.until === null ? null : timeInZone(opts.prev.until, r.zone));
  const p = f.filter((r) => r.businessDate >= from && r.businessDate <= to);
  const groupKey = (d: DateKey) => (group === "day" ? d : group === "month" ? monthOf(d) : startOfWeek(d));
  const keys: DateKey[] = [];
  for (let d = group === "week" ? startOfWeek(from) : group === "month" ? monthOf(from) : from; d <= to;
    d = group === "month" ? addMonths(d, 1) : addDays(d, group === "week" ? 7 : 1)) keys.push(d);
  const cohortKey = (d: DateKey) => (period === "month" ? monthOf(d) : startOfWeek(d));
  const withContact = p.filter((r) => r.hasContact);
  const cohortKeys = [...new Set(withContact.map((r) => cohortKey(r.businessDate)))].sort().reverse();
  const nowMs = Date.parse(opts.now);
  const cohorts: CourtesyCohort[] = cohortKeys.map((k) => {
    const c = withContact.filter((r) => cohortKey(r.businessDate) === k);
    const end = period === "month" ? addDays(addMonths(k, 1), -1) : addDays(k, 6);
    return {
      key: k, label: period === "month" ? k.slice(0, 7) : isoWeekLabel(k), start: k, end, partial: k < from || end > to, orders: c.length,
      ages: s.ages.map((age) => {
        const mature = c.length > 0 && c.every((r) => Date.parse(r.createdAt) + age * 86_400_000 <= nowMs);
        return { age, mature, completed: mature ? c.filter((r) => r.completedAt !== null && Date.parse(r.completedAt) <= Date.parse(r.createdAt) + age * 86_400_000).length : null };
      }),
    };
  });
  const people = new Map(opts.people.map((x) => [x.userId, x.name]));
  const perPerson = opts.perPerson
    ? [...new Set(f.filter(doneIn).map((r) => r.completedBy))].map((uid) => ({ userId: uid, name: uid === null ? null : people.get(uid) ?? null,
      ...calls(f.filter((r) => doneIn(r) && r.completedBy === uid)) }))
      .sort((a, b) => (a.userId === null ? 1 : 0) - (b.userId === null ? 1 : 0) || (a.name ?? "").localeCompare(b.name ?? "") || (a.userId ?? "").localeCompare(b.userId ?? ""))
    : null;
  const listed = f.filter((r) => courtesyStateMatches(r.state, filter.state))
    .sort((a, b) => (STATE_RANK[a.state ?? ""] ?? 5) - (STATE_RANK[b.state ?? ""] ?? 5) || a.dueDate.localeCompare(b.dueDate)
      || a.createdAt.localeCompare(b.createdAt) || a.orderId.localeCompare(b.orderId));
  const open = (st: CourtesyState | null) => st === "due_no_attempt" || st === "attempted" || st === "not_reached";
  return {
    ...head,
    now: {
      orders: f.filter((r) => r.hasContact).length, dueOpen: f.filter((r) => open(r.state)).length, notDue: f.filter((r) => r.state === "not_due").length,
      dueNoAttempt: f.filter((r) => r.state === "due_no_attempt").length, attempted: f.filter((r) => r.state === "attempted").length,
      notReached: f.filter((r) => r.state === "not_reached").length, completed: f.filter((r) => r.state === "completed").length,
      noContact: f.filter((r) => !r.hasContact).length,
    },
    completed: calls(f.filter(doneIn)), previous: calls(f.filter(donePrev)),
    previousFrom: opts.prev.from, previousTo: opts.prev.to, previousPartial: opts.prev.until !== null,
    byMarket: [...new Set(p.map((r) => r.market))].sort(marketOrder).map((m) => ({ market: m, name: nameOf.get(m) ?? null, ...counts(p.filter((r) => r.market === m)) })),
    byGroup: keys.map((key) => {
      const g = p.filter((r) => groupKey(r.businessDate) === key);
      return { key, ...counts(g), markets: [...new Set(g.map((r) => r.market))].sort(marketOrder).map((m) => ({ market: m, ...counts(g.filter((r) => r.market === m)) })) };
    }),
    cohorts, perPerson,
    list: {
      total: listed.length,
      rows: listed.slice(0, opts.rows).map((r) => ({
        orderId: r.orderId, orderName: r.orderName, store: r.store, storeName: r.storeName, market: r.market, segment: r.segment, createdAt: r.createdAt,
        businessDate: r.businessDate, dueDate: r.dueDate,
        daysPastDue: open(r.state) ? daysBetweenKeys(r.dueDate, dateKeyInZone(opts.now, r.zone)) : null,
        attempts: r.attempts, lastAttemptAt: r.lastAttemptAt, state: r.state, outcome: r.outcome, completedAt: r.completedAt, recordUrl: null,
      })),
    },
    markets: [...new Set(rows.map((r) => r.market))].sort(marketOrder),
  };
}

const daysBetweenKeys = (a: DateKey, b: DateKey) => Math.round((Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`)) / 86_400_000);

// ---- The screen ----------------------------------------------------------------------------------------------------

/** A part of a whole as a share; null without a whole */
export function courtesyShare(part: number, whole: number): number | null {
  return whole === 0 ? null : part / whole;
}

/**
 * A hint with the tenant's settings filled in: {dueDays}, {alertAttempts}, {ages} and {orderKinds} (courtesy.order_kinds, named
 * by `kindNames`, the order kinds' labels in the reader's language joined; the codes joined when left out)
 */
export function fillCourtesyHint(text: string, settings: CourtesyReport["settings"], kindNames?: string): string {
  return text.replace(/\{dueDays\}/g, String(settings.dueDays)).replace(/\{alertAttempts\}/g, String(settings.alertAttempts))
    .replace(/\{ages\}/g, settings.ages.join(", ")).replace(/\{orderKinds\}/g, kindNames ?? settings.orderKinds.join(", "));
}

/**
 * Welcome's Needs attention line (addition 0009a): the courtesy orders Not reached from the follow-up snapshot, shown only
 * while courtesy is set up and the count is above 0, to monitoring.live or performance.team; null otherwise
 */
export function courtesyAttention(flag: CourtesyFlag, permissions: readonly string[]): { count: number; alertAttempts: number; href: string } | null {
  if (!permissions.includes("monitoring.live") && !permissions.includes("performance.team")) return null;
  if (flag.courtesyNotReached === null || flag.courtesyAlertAttempts === null || flag.courtesyNotReached <= 0) return null;
  return { count: flag.courtesyNotReached, alertAttempts: flag.courtesyAlertAttempts, href: "/reports/courtesy?state=not_reached" };
}
