/**
 * First orders (addition 0008u; brief N19-A part 2, 18 October 2026): Reports → First orders and Orders per
 * person. Of the new first orders, which came in by self-service and which through the call center. The figures
 * come from the database (cma.first_orders_report, first_orders_amounts, first_orders_list,
 * first_orders_per_person); this module mirrors their definitions for the mock and for verify/reports.mjs, and
 * arranges the rows for the screen. Pure, with no runtime imports beyond time.ts and reports.ts, so the
 * verifier runs it under Node's type stripping.
 *
 * The definitions (README, Data model: first orders), one place in the database (cma.first_orders_of):
 *   order deal     a won deal in a counted order pipeline; T its creation time
 *   kind           no_contact, renewal (the linked store order), repeat (an earlier won order deal of the
 *                  contact), not_first (the store counts earlier orders), else first; only first orders are
 *                  attributed
 *   evidence       in [T - attribution.window_days, T): a lead deal of the contact, a connected call with it, an
 *                  agent's email to it, a call from the order's phone number (any contact), an unconnected call;
 *                  and the contact created at least attribution.known_contact_minutes before T
 *   level          the first evidence in attribution.level_order that holds, else self_service
 *   attribution    call_center when the level is in attribution.assisted_levels, else self_service
 *   credited       the owner of the latest touch of an assisted kind, through the linked accounts
 * Ids, codes, counts, amounts and times only: no name, address or phone number exists here.
 */
import type {
  AttributionSettings, DateKey, FirstOrderAmount, FirstOrderAttribution, FirstOrderEvidence, FirstOrderFigures, FirstOrderFilter,
  FirstOrderGroup, FirstOrderLevel, FirstOrderListRow, FirstOrderRow, Instant, OrderPerson,
} from "./data/types";
// With their extensions, so verify/reports.mjs can run this module under Node's type stripping
import { round1, timeInZone } from "./reports.ts";
import { dateKeyInZone, startOfWeek } from "./time.ts";

export const FIRST_ORDER_GROUPS: readonly FirstOrderGroup[] = ["day", "week", "market", "level"];

export function parseFirstOrderGroup(value: unknown): FirstOrderGroup | null {
  return typeof value === "string" && (FIRST_ORDER_GROUPS as readonly string[]).includes(value) ? (value as FirstOrderGroup) : null;
}

export function nextFirstOrderGroup(group: FirstOrderGroup): FirstOrderGroup {
  return FIRST_ORDER_GROUPS[(FIRST_ORDER_GROUPS.indexOf(group) + 1) % FIRST_ORDER_GROUPS.length]!;
}

/** The six kinds of evidence, in the catalog's default order */
export const EVIDENCE: readonly FirstOrderEvidence[] = ["lead_deal", "conversation", "email", "phone_match", "attempt", "known_contact"];
export const LEVELS: readonly FirstOrderLevel[] = [...EVIDENCE, "self_service"];

/** Orders per person: performance.team, and the tenant's reports.per_person holding orders (cma.assert_per_person) */
export const ORDERS_PER_PERSON_PERMISSION = "performance.team";
export const ORDERS_PER_PERSON_KEY = "orders";

/**
 * The report's filters from a query, as cma.first_orders_filters_check takes them: a market is a two-letter code
 * or "unknown", a level one of the six or self_service; empty means all. `problem` names a value the database
 * would refuse; that filter is then left out
 */
export function parseFirstOrderFilter(market: unknown, level: unknown): { filter: FirstOrderFilter; problem: null | "market" | "level" } {
  const filter: FirstOrderFilter = { market: null, level: null };
  let problem: null | "market" | "level" = null;
  const text = (v: unknown) => (typeof v === "string" && v.trim() !== "" ? v.trim() : null);
  const m = text(market);
  if (m !== null) {
    if (/^([A-Z]{2}|unknown)$/.test(m)) filter.market = m;
    else problem = "market";
  }
  const l = text(level);
  if (l !== null) {
    if ((LEVELS as readonly string[]).includes(l)) filter.level = l as FirstOrderLevel;
    else problem ??= "level";
  }
  return { filter, problem };
}

export function firstOrderFilterQuery(filter: FirstOrderFilter): Record<string, string> {
  const out: Record<string, string> = {};
  if (filter.market) out.market = filter.market;
  if (filter.level) out.level = filter.level;
  return out;
}

/** The levels in the tenant's order, the ones its level order leaves out after them, self_service last */
export function levelsInOrder(s: Pick<AttributionSettings, "levelOrder">): FirstOrderLevel[] {
  return [...s.levelOrder, ...EVIDENCE.filter((e) => !s.levelOrder.includes(e)), "self_service"];
}

/** First orders via the call center as a share of all first orders, 0 to 1; null without one */
export function callCenterShare(f: Pick<FirstOrderFigures, "callCenter" | "firstOrders">): number | null {
  return f.firstOrders === 0 ? null : f.callCenter / f.firstOrders;
}

// ---- The mock's fixture and the definitions -----------------------------------------------------------

/** A touch before an order: a lead deal, a call (connected or not), an agent's email, a call from the order's phone */
export interface OrderTouch {
  kind: Exclude<FirstOrderEvidence, "known_contact">;
  at: Instant;
  /** The linked-account system of the owner: '<adapter>_owner' or '<adapter>_user' */
  system: string;
  ownerRef: string | null;
}

/** One won order deal as the mock holds it, with what the database would find around it */
export interface OrderDealFixture {
  connectionId: string;
  dealSourceId: string;
  createdAt: Instant;
  /** 0007d's deal market ("unknown" when none) and its zone (the tenant's for unknown) */
  market: string;
  zone: string;
  contact: string | null;
  /** The contact has an earlier won order deal */
  earlierOrderDeal: boolean;
  /** The linked store order's kind; null without a linked order */
  storeOrderKind: "first" | "repeat" | "renewal" | "unknown" | null;
  currency: string | null;
  amount: number | null;
  phoneHashed: boolean;
  contactCreatedAt: Instant | null;
  touches: OrderTouch[];
  recordUrl: string | null;
}

export type OrderKind = "first" | "repeat" | "renewal" | "not_first" | "no_contact";

/** An order deal as cma.first_orders_of returns it */
export interface FirstOrderRecord {
  connectionId: string;
  dealSourceId: string;
  createdAt: Instant;
  market: string;
  zone: string;
  date: DateKey;
  week: DateKey;
  localTime: string;
  kind: OrderKind;
  currency: string | null;
  amount: number | null;
  phoneHashed: boolean;
  hasOrder: boolean;
  evidence: Record<FirstOrderEvidence, boolean> | null;
  level: FirstOrderLevel | null;
  attribution: FirstOrderAttribution | null;
  firstTouchAt: Instant | null;
  daysFromFirstTouch: number | null;
  creditedSystem: string | null;
  creditedOwnerRef: string | null;
  creditedUserId: string | null;
  recordUrl: string | null;
}

/** Whose an owner id is: the person holding the linked account, or null (not linked) */
export type OrderPersonOf = (system: string, ownerRef: string | null) => { userId: string; name: string } | null;

const round2 = (x: number) => Math.round(x * 100) / 100;

/** The order deals as cma.first_orders_of classifies and attributes them */
export function firstOrderRecords(deals: readonly OrderDealFixture[], s: AttributionSettings, personOf: OrderPersonOf): FirstOrderRecord[] {
  const windowMs = s.windowDays * 86_400_000;
  return deals.map((d) => {
    const t = Date.parse(d.createdAt);
    const kind: OrderKind = d.contact === null ? "no_contact" : d.storeOrderKind === "renewal" ? "renewal" : d.earlierOrderDeal ? "repeat"
      : d.storeOrderKind === "repeat" ? "not_first" : "first";
    const base = {
      connectionId: d.connectionId, dealSourceId: d.dealSourceId, createdAt: d.createdAt, market: d.market, zone: d.zone,
      date: dateKeyInZone(d.createdAt, d.zone), week: startOfWeek(dateKeyInZone(d.createdAt, d.zone)), localTime: timeInZone(d.createdAt, d.zone),
      kind, currency: d.currency, amount: d.amount, phoneHashed: d.phoneHashed, hasOrder: d.storeOrderKind !== null, recordUrl: d.recordUrl,
    };
    if (kind !== "first") {
      return { ...base, evidence: null, level: null, attribution: null, firstTouchAt: null, daysFromFirstTouch: null, creditedSystem: null,
        creditedOwnerRef: null, creditedUserId: null };
    }
    const inWindow = d.touches.filter((x) => Date.parse(x.at) >= t - windowMs && Date.parse(x.at) < t && (x.kind !== "phone_match" || d.phoneHashed));
    const evidence = Object.fromEntries(EVIDENCE.map((e) => [e, inWindow.some((x) => x.kind === e)])) as Record<FirstOrderEvidence, boolean>;
    evidence.known_contact = d.contactCreatedAt !== null && Date.parse(d.contactCreatedAt) <= t - s.knownContactMinutes * 60_000;
    const level: FirstOrderLevel = s.levelOrder.find((e) => evidence[e]) ?? "self_service";
    const attribution: FirstOrderAttribution = level !== "self_service" && s.assistedLevels.includes(level) ? "call_center" : "self_service";
    const sorted = [...inWindow].sort((a, b) => a.at.localeCompare(b.at));
    const first = sorted[0];
    const assisted = [...inWindow].filter((x) => s.assistedLevels.includes(x.kind))
      .sort((a, b) => b.at.localeCompare(a.at) || a.kind.localeCompare(b.kind) || (a.ownerRef ?? "").localeCompare(b.ownerRef ?? ""));
    const credit = assisted[0];
    return {
      ...base, evidence, level, attribution, firstTouchAt: first?.at ?? null,
      daysFromFirstTouch: first ? round2((t - Date.parse(first.at)) / 86_400_000) : null,
      creditedSystem: credit?.system ?? null, creditedOwnerRef: credit?.ownerRef ?? null,
      creditedUserId: credit ? personOf(credit.system, credit.ownerRef)?.userId ?? null : null,
    };
  });
}

/** The records of business dates [from, to] in each deal's zone, cut on `to` at `until`'s time of day (the previous span), narrowed by the filter */
export function firstOrdersInPeriod(rows: readonly FirstOrderRecord[], from: DateKey, to: DateKey, filter: FirstOrderFilter,
  until: Instant | null = null): FirstOrderRecord[] {
  return rows.filter((r) => r.date >= from && r.date <= to
    && (until === null || r.date < to || r.localTime <= timeInZone(until, r.zone))
    && (filter.market === null || r.market === filter.market)
    && (filter.level === null || r.level === filter.level));
}

/** The median as percentile_cont(0.5) gives it, to one decimal; null without values */
function median(values: readonly number[]): number | null {
  if (values.length === 0) return null;
  const v = [...values].sort((a, b) => a - b);
  const mid = (v.length - 1) / 2;
  return round1((v[Math.floor(mid)]! + v[Math.ceil(mid)]!) / 2);
}

/** The figures of a set of order deals, as cma.first_orders_figures_of aggregates them */
export function firstOrderFigures(rows: readonly FirstOrderRecord[]): FirstOrderFigures {
  const first = rows.filter((r) => r.kind === "first");
  return {
    firstOrders: first.length,
    callCenter: first.filter((r) => r.attribution === "call_center").length,
    selfService: first.filter((r) => r.attribution === "self_service").length,
    repeats: rows.filter((r) => r.kind === "repeat").length,
    renewals: rows.filter((r) => r.kind === "renewal").length,
    notFirst: rows.filter((r) => r.kind === "not_first").length,
    noContact: rows.filter((r) => r.kind === "no_contact").length,
    withTouch: first.filter((r) => r.firstTouchAt !== null).length,
    daysMedian: median(first.filter((r) => r.daysFromFirstTouch !== null).map((r) => r.daysFromFirstTouch!)),
  };
}

/** The figures per group of one grouping (a level groups first orders only), by key */
export function firstOrderGroups(rows: readonly FirstOrderRecord[], group: FirstOrderGroup): FirstOrderRow[] {
  const by = new Map<string, FirstOrderRecord[]>();
  for (const r of rows) {
    const key = group === "day" ? r.date : group === "week" ? r.week : group === "market" ? r.market : r.level;
    if (key === null) continue;
    by.set(key, [...(by.get(key) ?? []), r]);
  }
  return [...by.entries()].sort((a, b) => a[0].localeCompare(b[0])).map(([groupKey, list]) => ({ groupKey, ...firstOrderFigures(list) }));
}

/** First orders' amounts per currency (never summed across), in total or per market, with the call-center and self-service parts */
export function firstOrderAmounts(rows: readonly FirstOrderRecord[], perMarket: boolean): FirstOrderAmount[] {
  const by = new Map<string, FirstOrderAmount>();
  for (const r of rows) {
    if (r.kind !== "first") continue;
    const k = `${perMarket ? r.market : ""}|${r.currency ?? ""}`;
    const a = by.get(k) ?? { market: perMarket ? r.market : null, currency: r.currency, orders: 0, amount: null, callCenterAmount: 0, selfServiceAmount: 0 };
    a.orders += 1;
    if (r.amount !== null) {
      a.amount = round2((a.amount ?? 0) + r.amount);
      if (r.attribution === "call_center") a.callCenterAmount = round2(a.callCenterAmount + r.amount);
      else a.selfServiceAmount = round2(a.selfServiceAmount + r.amount);
    }
    by.set(k, a);
  }
  // by market, then currency with the orders without one last (as the database's 'none')
  return [...by.values()].sort((a, b) => (a.market ?? "").localeCompare(b.market ?? "") || Number(a.currency === null) - Number(b.currency === null)
    || (a.currency ?? "").localeCompare(b.currency ?? ""));
}

/** The list: first orders, newest first, the first `limit`, with the total */
export function firstOrderList(rows: readonly FirstOrderRecord[], limit: number): { rows: FirstOrderListRow[]; total: number } {
  const first = rows.filter((r) => r.kind === "first").sort((a, b) => b.createdAt.localeCompare(a.createdAt) || a.dealSourceId.localeCompare(b.dealSourceId));
  return {
    total: first.length,
    rows: first.slice(0, limit).map((r) => ({
      connectionId: r.connectionId, dealSourceId: r.dealSourceId, market: r.market, createdAt: r.createdAt, level: r.level!, attribution: r.attribution!,
      evidence: r.evidence!, phoneHashed: r.phoneHashed, hasOrder: r.hasOrder, currency: r.currency, amount: r.amount,
      daysFromFirstTouch: r.daysFromFirstTouch, recordUrl: r.recordUrl,
    })),
  };
}

/**
 * Per credited person, as cma.first_orders_per_person: the first orders via the call center whose latest assisted
 * touch was theirs; owner ids without a person as one not-linked row with how many, never which; by name, then
 * the not-linked row, then the total
 */
export function ordersPerPerson(rows: readonly FirstOrderRecord[], nameOf: (userId: string) => string | null): { rows: OrderPerson[]; total: OrderPerson } {
  const credited = rows.filter((r) => r.kind === "first" && r.attribution === "call_center");
  const make = (kind: OrderPerson["kind"], userId: string | null, list: FirstOrderRecord[]): OrderPerson => ({
    kind, userId, name: userId ? nameOf(userId) : null,
    unlinkedOwners: kind === "notLinked" ? new Set(list.map((r) => r.creditedOwnerRef).filter((x) => x !== null)).size : null,
    orders: list.length,
    leadDeal: list.filter((r) => r.level === "lead_deal").length,
    conversation: list.filter((r) => r.level === "conversation").length,
    email: list.filter((r) => r.level === "email").length,
    phoneMatch: list.filter((r) => r.level === "phone_match").length,
    otherLevels: list.filter((r) => !["lead_deal", "conversation", "email", "phone_match"].includes(r.level ?? "")).length,
    daysMedian: median(list.filter((r) => r.daysFromFirstTouch !== null).map((r) => r.daysFromFirstTouch!)),
  });
  const people = new Map<string, FirstOrderRecord[]>();
  const unlinked: FirstOrderRecord[] = [];
  for (const r of credited) {
    if (r.creditedUserId) people.set(r.creditedUserId, [...(people.get(r.creditedUserId) ?? []), r]);
    else unlinked.push(r);
  }
  const out = [...people.entries()].map(([id, list]) => make("person", id, list))
    .sort((a, b) => (a.name ?? "").localeCompare(b.name ?? "") || (a.userId ?? "").localeCompare(b.userId ?? ""));
  if (unlinked.length > 0) out.push(make("notLinked", null, unlinked));
  return { rows: out, total: make("total", null, credited) };
}

// ---- The screen ------------------------------------------------------------------------------------------

/** Call center Deep Blue, self-service Leaf Green (docs/style/Pulse4all-Style.md 7.7, the series' first two) */
export const ATTRIBUTION_CLASS: Record<FirstOrderAttribution, string> = { call_center: "bg-p4a-deepblue", self_service: "bg-p4a-green" };
export const ATTRIBUTION_FILL: Record<FirstOrderAttribution, string> = { call_center: "fill-p4a-deepblue", self_service: "fill-p4a-green" };

/** An amount in its currency, in the reader's language; a dash without one */
export function fmtAmount(amount: number | null, currency: string | null, locale: "en" | "nl"): string {
  if (amount === null) return "–";
  const lang = locale === "nl" ? "nl-NL" : "en-GB";
  if (!currency) return new Intl.NumberFormat(lang, { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(amount);
  return new Intl.NumberFormat(lang, { style: "currency", currency, currencyDisplay: "code" }).format(amount);
}

/** Days with one decimal in the reader's language; a dash without */
export function fmtDays(days: number | null, locale: "en" | "nl"): string {
  if (days === null) return "–";
  return new Intl.NumberFormat(locale === "nl" ? "nl-NL" : "en-GB", { minimumFractionDigits: 1, maximumFractionDigits: 1 }).format(days);
}
