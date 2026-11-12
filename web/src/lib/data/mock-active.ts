/**
 * Mock mode's Customers → Active (addition 0009l, brief B35 with addendum A): an invented customer base, computed in
 * memory the way db/172_active_customers.sql computes it (lib/active mirrors its pure functions), so every panel of the
 * page shows without a database. Tenant one (Pulse4all Subscriptions) holds three stores (NL and DE in euros, GB in
 * pounds), 360 store customers in the segments B2B and B2C (and some without one), their subscriptions created over 30
 * months (the British store's older ones all on one day: subscriptions moved into the subscription app carry the date
 * they moved), a share ended, a few paused or failed, and an acquisition channel for the customers that started after
 * the attribution's history began. Tenant two (Pulse4all Invest) has no store: "Not set up", never zeros. Ids are
 * invented, links point to an example host, and no row carries a name, email, phone or address.
 */
import type { Principal } from "@/lib/auth/identity";
import { CmaDbError } from "@/lib/data/errors";
import { ACTIVE_CHANNELS, ACTIVE_SLOTS, billingOf, curveOf, monthsBack, retentionAt, spellsOf, unitFactor } from "@/lib/active";
import { dateKeyInZone } from "@/lib/time";
import type {
  ActiveAmount, ActiveChannel, ActiveClv, ActiveCohort, ActiveCohortSplit, ActiveComparisonRow, ActiveCurve, ActiveFilter, ActiveGroupStat, ActiveGrouping,
  ActiveList, ActiveListRow, ActiveMeasure, ActiveMonth, ActiveNow, ActiveReport, ActiveRowsRequest,
} from "./types";

const MOCK_TENANT_2 = "00000000-0000-7000-8000-000000000002";
const REPORT = ["reports.view", "performance.team"];
const ZONE = "Europe/Amsterdam";
const SEGMENTS = ["B2B", "B2C"];
const AGES = [3, 6, 12, 24, 36];
const BANDS = [12, 24, 36, 48, 60];
const HISTORY_MONTHS = 60;
const HOLDING = ["active", "failed"];
const FX = { asOf: "2026-11-01", rates: { GBP: 1.15 } as Record<string, number> };
const STORES = [
  { store: "mock-nl", market: "NL", currency: "EUR", customers: 180 },
  { store: "mock-gb", market: "GB", currency: "GBP", customers: 110 },
  { store: "mock-de", market: "DE", currency: "EUR", customers: 70 },
] as const;
const MODELS: Record<string, string> = { aed_plus: "AED Plus", aed_3: "AED 3" };
const DAY = 86_400_000;

interface Sub { id: string; start: number; end: number | null; status: string; amount: number; currency: string; interval: string; count: number; devices: number; model: string }
interface Customer {
  id: string; store: string; market: string; segment: string; channel: ActiveChannel; level: string | null; reason: string | null;
  start: number; clv: number; currency: string; devices: number; contact: string | null; subs: Sub[];
}

/** A small deterministic generator, so the mock shows the same base on every render */
function rng(seed: number): () => number {
  let s = seed >>> 0;
  return () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    return s / 4294967296;
  };
}

const key = (t: number) => new Date(t).toISOString().slice(0, 10);
const monthOf = (t: number) => `${key(t).slice(0, 7)}-01`;
const monthIndex = (k: string) => Number(k.slice(0, 4)) * 12 + Number(k.slice(5, 7)) - 1;
const monthKey = (i: number) => `${Math.floor(i / 12)}-${String((i % 12) + 1).padStart(2, "0")}-01`;
const monthStart = (i: number) => Date.UTC(Math.floor(i / 12), i % 12, 1);
/** Whole months from a to b as PostgreSQL's age() counts them */
function wholeMonths(a: number, b: number): number {
  const x = new Date(a);
  const y = new Date(b);
  const m = (y.getUTCFullYear() - x.getUTCFullYear()) * 12 + y.getUTCMonth() - x.getUTCMonth() - (y.getUTCDate() < x.getUTCDate() ? 1 : 0);
  return Math.max(0, m);
}
function addMonths(t: number, n: number): number {
  const d = new Date(t);
  return Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + n, d.getUTCDate(), d.getUTCHours());
}
const round2 = (x: number) => Math.round(x * 100) / 100;
const round4 = (x: number) => Math.round(x * 1e4) / 1e4;
function median(values: number[]): number | null {
  if (values.length === 0) return null;
  const v = [...values].sort((a, b) => a - b);
  return v.length % 2 === 1 ? v[(v.length - 1) / 2]! : (v[v.length / 2 - 1]! + v[v.length / 2]!) / 2;
}

/** The invented base as of now: built once per call from fixed seeds and today's date */
function buildBase(now: number): Customer[] {
  const r = rng(172);
  const customers: Customer[] = [];
  const attributionStart = now - 300 * DAY;
  for (const s of STORES) {
    for (let i = 1; i <= s.customers; i++) {
      // the British store's subscription history starts 540 days back (as the dev seed's second store: the app was connected
      // then), inside the page's default 24 months, so the hero chart has a history start to mark
      const firstStartDays = s.market === "GB" ? (r() < 0.45 ? 540 : Math.min(540, 15 + Math.floor(r() * 900))) : 15 + Math.floor(r() * 900);
      const start = now - firstStartDays * DAY;
      const seg = r();
      const segment = seg < 0.2 ? "B2B" : seg < 0.8 ? "B2C" : "unknown";
      const contact = r() < 0.85 ? `mock-contact-${s.market.toLowerCase()}-${i}` : null;
      const subs: Sub[] = [];
      const yearly = r() < 0.08;
      const base = segment === "B2B" ? 45 + Math.floor(r() * 40) : 22 + Math.floor(r() * 18);
      const fate = r();
      // seven of ten still hold; of the rest most ended, a few came back after a gap
      const end = fate < 0.72 ? null : start + Math.floor((0.15 + r() * 0.8) * (now - start));
      const status = end !== null ? (r() < 0.8 ? "canceled" : "expired") : fate < 0.04 ? "failed" : "active";
      subs.push({
        id: `mock-sub-${s.market.toLowerCase()}-${i}-1`, start: start + 2 * DAY, end, status, amount: yearly ? base * 10 : base, currency: s.currency,
        interval: yearly ? "year" : "month", count: 1, devices: r() < 0.85 ? 1 : 2, model: r() < 0.7 ? "aed_plus" : "aed_3",
      });
      if (end !== null && r() < 0.25 && now - end > 60 * DAY) {
        subs.push({
          id: `mock-sub-${s.market.toLowerCase()}-${i}-2`, start: end + 45 * DAY, end: null, status: "active", amount: base, currency: s.currency,
          interval: "month", count: 1, devices: 1, model: "aed_3",
        });
      } else if (end === null && segment === "B2B" && r() < 0.4) {
        subs.push({
          id: `mock-sub-${s.market.toLowerCase()}-${i}-2`, start: start + 90 * DAY > now ? start + 5 * DAY : start + 90 * DAY, end: null, status: "active",
          amount: base, currency: s.currency, interval: "month", count: 1, devices: 1, model: "aed_plus",
        });
      }
      let channel: ActiveChannel = "unknown";
      let level: string | null = null;
      let reason: string | null = contact === null ? "no_contact" : start < attributionStart ? "before_history" : null;
      if (reason === null) {
        const c = r();
        if (c < 0.45) { channel = "indirect"; level = c < 0.25 ? "lead_deal" : "conversation"; }
        else if (c < 0.85) { channel = "direct"; level = c < 0.6 ? "self_service" : "known_contact"; }
        else reason = c < 0.93 ? "no_order_deal" : "order_not_matched";
      }
      customers.push({
        id: `mock-cust-${s.market.toLowerCase()}-${i}`, store: s.store, market: s.market, segment, channel, level, reason, start,
        clv: round2((segment === "B2B" ? 60 : 30) * Math.max(1, wholeMonths(start, now)) * (0.6 + r() * 0.6)), currency: s.currency,
        devices: subs.filter((x) => x.end === null).reduce((n, x) => n + x.devices, 0), contact, subs,
      });
    }
  }
  return customers;
}

const holding = (s: Sub) => s.end === null && HOLDING.includes(s.status);
const monthly = (s: Sub) => s.amount * (unitFactor(s.interval, s.count) ?? 0);
const isActive = (c: Customer) => c.subs.some(holding);
const matches = (c: Customer, f: ActiveFilter) =>
  (f.market === null || c.market === f.market) && (f.segment === null || c.segment === f.segment) && (f.channel === null || c.channel === f.channel);

function amountsOf(customers: Customer[]): Record<string, ActiveAmount> {
  const out: Record<string, { amount: number; customers: Set<string> }> = {};
  for (const c of customers) {
    for (const s of c.subs.filter(holding)) {
      const a = (out[s.currency] ??= { amount: 0, customers: new Set() });
      if (s.status === "active") a.amount += monthly(s);
      a.customers.add(c.id);
    }
  }
  return Object.fromEntries(Object.entries(out).map(([cur, a]) => [cur, { amount: round2(a.amount), customers: a.customers.size, average: a.customers.size > 0 ? round2(a.amount / a.customers.size) : null }]));
}

function clvOf(customers: Customer[], now: number): Record<string, ActiveClv> {
  const by: Record<string, Customer[]> = {};
  for (const c of customers) (by[c.currency] ??= []).push(c);
  return Object.fromEntries(Object.entries(by).map(([cur, list]) => [cur, {
    average: round2(list.reduce((n, c) => n + c.clv, 0) / list.length), median: round2(median(list.map((c) => c.clv)) ?? 0),
    perMonth: round2(list.reduce((n, c) => n + c.clv / Math.max(1, wholeMonths(c.start, now)), 0) / list.length), customers: list.length,
  }]));
}

function statOf(all: Customer[], now: number, spells: { key: string; start: number; end: number | null }[]): ActiveGroupStat {
  const active = all.filter(isActive);
  const ids = new Set(all.map((c) => c.id));
  const bySegment: Record<string, number> = {};
  for (const c of active) bySegment[c.segment] = (bySegment[c.segment] ?? 0) + 1;
  const indirect = active.filter((c) => c.channel === "indirect").length;
  const direct = active.filter((c) => c.channel === "direct").length;
  const own = spells.filter((s) => ids.has(s.key));
  const subs = active.reduce((n, c) => n + c.subs.filter(holding).length, 0);
  const devices = active.reduce((n, c) => n + c.devices, 0);
  const m = median(active.map((c) => wholeMonths(c.start, now)));
  return {
    customers: active.length, bySegment, subscriptions: subs, devices, amounts: amountsOf(active), medianAge: m === null ? null : Math.round(m * 10) / 10,
    clv: clvOf(active, now),
    churned30d: all.reduce((n, c) => n + c.subs.filter((s) => s.end !== null && s.end > now - 30 * DAY).length, 0),
    net30d: own.filter((s) => s.start > now - 30 * DAY).length - own.filter((s) => s.end !== null && s.end > now - 30 * DAY).length,
    indirect, direct, unknownChannel: active.length - indirect - direct, indirectShare: indirect + direct > 0 ? round4(indirect / (indirect + direct)) : null,
    subscriptionsPerCustomer: active.length > 0 ? round2(subs / active.length) : null, devicesPerCustomer: active.length > 0 ? round2(devices / active.length) : null,
  };
}

function curveFor(spells: { start: number; end: number | null }[], now: number, value?: string): ActiveCurve {
  return curveOf(spells.map((s) => wholeMonths(s.start, s.end ?? now)), spells.map((s) => s.end !== null), value);
}

function assertAllowed(me: Principal): void {
  if (!REPORT.some((p) => me.permissions.includes(p))) throw new CmaDbError("CMA06", "not permitted");
}

/** The live present of the tiles for the mock (cma.active_now): the same four tiles as the stored answer's, of this moment */
export function mockActiveNow(me: Principal, filter: ActiveFilter): ActiveNow {
  const r = mockActive(me, null, filter, "month");
  const t = r.tiles;
  const point = r.months.find((m) => m.isNow);
  return {
    figures: r.figures, computedAt: new Date().toISOString(),
    tiles: t ? { activeCustomers: t.activeCustomers, totalSubscriptions: t.totalSubscriptions, amounts: t.amounts, eur: t.eur } : null,
    now: t ? { customers: t.activeCustomers.value, subscriptions: t.totalSubscriptions.value, bySegment: point?.bySegment ?? t.activeCustomers.bySegment } : null,
  };
}
/** Customers → Active for the mock: the document cma.active_top and cma.active_rest answer together, computed from the invented base */
export function mockActive(me: Principal, fromMonth: string | null, filter: ActiveFilter, grouping: ActiveGrouping): ActiveReport {
  assertAllowed(me);
  const now = Date.now();
  const today = dateKeyInZone(new Date(now), ZONE);
  const month = `${today.slice(0, 7)}-01`;
  const cap = monthsBack(today, HISTORY_MONTHS);
  const from = fromMonth === null || fromMonth < cap ? cap : fromMonth > month ? month : fromMonth;
  // the mock's take is always of this moment: never stale, never late
  const take = { computedAt: new Date(now).toISOString(), businessDate: today, stale: false, ageMinutes: 0, late: false };
  const head = {
    computedAt: new Date(now).toISOString(), timeZone: ZONE, today, month, fromMonth: from, grouping, filter,
    settings: {
      cohortAgesMonths: AGES, ageMonths: BANDS, historyMonths: HISTORY_MONTHS, fx: FX, segments: SEGMENTS,
      statuses: { active: ["active"], holding: HOLDING, ended: ["canceled", "expired"] },
      attribution: { assistedLevels: ["lead_deal", "conversation", "email", "phone_match"], historyStart: key(now - 300 * DAY) },
    },
  };
  if (me.tenantId === MOCK_TENANT_2) {
    return {
      ...head, setUp: { commerce: false, subscriptions: false }, figures: false, history: false, take: null, presentAt: null, ageOver: [], filters: { markets: [], segments: [...SEGMENTS, "unknown"], channels: [...ACTIVE_CHANNELS] },
      tiles: null, unitEconomics: null, months: [], markets: [], marketsTotal: null, comparison: null, survival: null, ageBands: [], cohorts: [], cohortSplits: null,
      mix: null, notes: null,
    };
  }
  const base = buildBase(now);
  const all = base.filter((c) => matches(c, filter));
  const active = all.filter(isActive);
  const byId = new Map(all.map((c) => [c.id, c]));
  const spells = spellsOf(all.flatMap((c) => c.subs.map((s) => ({ key: c.id, start: s.start, end: s.end }))));
  const subsAll = all.flatMap((c) => c.subs.map((s) => ({ c, s })));

  // the month ends: everything started before a month's end less everything ended before it
  const nowIdx = monthIndex(month);
  const firstIdx = spells.length > 0 ? Math.min(...spells.map((s) => monthIndex(monthOf(s.start)))) : nowIdx;
  const months: ActiveMonth[] = [];
  const atEnd = (i: number) => (i === nowIdx ? now : monthStart(i + 1));
  const holdsAt = (x: { start: number; end: number | null }, i: number) => x.start < atEnd(i) && (x.end === null || x.end >= atEnd(i));
  const eurOf = (amounts: Record<string, number>) => {
    const cur = Object.keys(amounts);
    return cur.length > 0 && cur.every((c) => c === "EUR" || FX.rates[c] !== undefined) ? round2(cur.reduce((n, c) => n + amounts[c]! * (c === "EUR" ? 1 : FX.rates[c]!), 0)) : null;
  };
  for (let i = firstIdx; i <= nowIdx; i++) {
    const held = spells.filter((s) => holdsAt(s, i));
    const bySegment: Record<string, number> = {};
    for (const s of held) { const seg = byId.get(s.key)!.segment; bySegment[seg] = (bySegment[seg] ?? 0) + 1; }
    const started = spells.filter((s) => monthIndex(monthOf(s.start)) === i);
    const inflowByChannel: Record<string, number> = { indirect: 0, direct: 0, unknown: 0 };
    for (const s of started) inflowByChannel[byId.get(s.key)!.channel]! += 1;
    const outflow = spells.filter((s) => s.end !== null && monthIndex(monthOf(s.end)) === i).length;
    const amounts: Record<string, number> = {};
    for (const { s } of subsAll) {
      if (holdsAt(s, i) && (s.end !== null || s.status === "active")) amounts[s.currency] = round2((amounts[s.currency] ?? 0) + monthly(s));
    }
    months.push({
      month: monthKey(i), isNow: i === nowIdx, customers: held.length, bySegment, subscriptions: subsAll.filter(({ s }) => holdsAt(s, i)).length,
      inflow: started.length, inflowByChannel, outflow, net: started.length - outflow, amounts, eur: eurOf(amounts),
    });
  }
  const at = (m: string) => months.find((x) => x.month === m) ?? null;
  const prev = at(monthsBack(today, 1));
  const year = at(monthsBack(today, 13));

  const total = statOf(all, now, spells);
  const marketKeys = [...new Set(all.map((c) => c.market))];
  const markets = marketKeys.map((mk) => {
    const list = all.filter((c) => c.market === mk);
    const ids = new Set(list.map((c) => c.id));
    const st = statOf(list, now, spells);
    const spark: number[] = [];
    for (let i = Math.max(firstIdx, nowIdx - 12); i <= nowIdx; i++) spark.push(spells.filter((s) => ids.has(s.key) && holdsAt(s, i)).length);
    return { ...st, market: mk, share: total.customers > 0 ? round4(st.customers / total.customers) : null, spark };
  }).sort((a, b) => b.customers - a.customers || (a.market < b.market ? -1 : 1));

  // the curves: over all spells, per segment and per channel
  const curveAll = curveFor(spells, now);
  const segmentKeys = [...SEGMENTS, "unknown"].filter((k) => spells.some((s) => byId.get(s.key)!.segment === k));
  const survival = {
    all: curveAll,
    segment: segmentKeys.map((k) => curveFor(spells.filter((s) => byId.get(s.key)!.segment === k), now, k)),
    channel: ACTIVE_CHANNELS.filter((k) => spells.some((s) => byId.get(s.key)!.channel === k)).map((k) => curveFor(spells.filter((s) => byId.get(s.key)!.channel === k), now, k)),
  };

  // the comparison: the first two segments side by side, unknown beside
  const segStat = Object.fromEntries([...SEGMENTS, "unknown"].map((k) => [k, statOf(all.filter((c) => c.segment === k), now, spells)]));
  const segCurve = (k: string) => survival.segment.find((c) => c.value === k) ?? null;
  const rows: ActiveComparisonRow[] = [];
  const push = (measure: ActiveMeasure, pick: (k: string) => number | null, extra: Partial<ActiveComparisonRow> = {}) => {
    const a = pick("B2B");
    const b = pick("B2C");
    rows.push({
      measure, months: null, currency: null, a, b, unknown: pick("unknown"), difference: a !== null && b !== null ? round4(a - b) : null,
      ratio: a !== null && b !== null && a > 0 && b > 0 ? round2(a / b) : null, aLongest: null, bLongest: null, unknownLongest: null, ...extra,
    });
  };
  push("customers", (k) => segStat[k]!.customers);
  push("share", (k) => (total.customers > 0 ? round4(segStat[k]!.customers / total.customers) : null));
  push("lifetime_median", (k) => segCurve(k)?.median ?? null, { aLongest: segCurve("B2B")?.longest ?? null, bLongest: segCurve("B2C")?.longest ?? null, unknownLongest: segCurve("unknown")?.longest ?? null });
  for (const m of BANDS.slice(0, 3)) push("retention", (k) => { const c = segCurve(k); return c ? retentionAt(c, m) : null; }, { months: m });
  push("median_age", (k) => segStat[k]!.medianAge);
  const currencies = [...new Set(active.map((c) => c.currency))].sort();
  for (const cur of currencies) push("clv_average", (k) => segStat[k]!.clv[cur]?.average ?? null, { currency: cur });
  for (const cur of currencies) push("clv_median", (k) => segStat[k]!.clv[cur]?.median ?? null, { currency: cur });
  for (const cur of currencies) push("clv_per_month", (k) => segStat[k]!.clv[cur]?.perMonth ?? null, { currency: cur });
  for (const cur of currencies) push("average_monthly_amount", (k) => segStat[k]!.amounts[cur]?.average ?? null, { currency: cur });
  push("subscriptions_per_customer", (k) => segStat[k]!.subscriptionsPerCustomer);
  push("devices_per_customer", (k) => segStat[k]!.devicesPerCustomer);
  push("indirect_share", (k) => segStat[k]!.indirectShare);

  // the cohorts: the customers by the month or quarter of their start, at each age still in a spell or not
  const cohortOf = (t: number) => {
    const k = monthOf(t);
    return grouping === "quarter" ? `${k.slice(0, 4)}-${String(Math.floor((Number(k.slice(5, 7)) - 1) / 3) * 3 + 1).padStart(2, "0")}-01` : k;
  };
  const withSpells = all.filter((c) => spells.some((s) => s.key === c.id));
  const stillAt = (c: Customer, age: number) => {
    const t = addMonths(c.start, age);
    return t <= now && spells.some((s) => s.key === c.id && s.start <= t && (s.end === null || s.end > t));
  };
  const fromCohort = grouping === "quarter" ? cohortOf(Date.UTC(Number(from.slice(0, 4)), Number(from.slice(5, 7)) - 1, 1)) : from;
  const inRange = withSpells.filter((c) => cohortOf(c.start) >= fromCohort);
  const cohortKeys = [...new Set(inRange.map((c) => cohortOf(c.start)))].sort().reverse();
  const cohorts: ActiveCohort[] = cohortKeys.map((ck) => {
    const list = inRange.filter((c) => cohortOf(c.start) === ck);
    return {
      cohort: ck, started: list.length, share: inRange.length > 0 ? round4(list.length / inRange.length) : null,
      ages: AGES.map((age) => ({ age, stillActive: list.filter((c) => stillAt(c, age)).length, mature: list.every((c) => addMonths(c.start, age) <= now) })),
    };
  });
  const splitOf = (pick: (c: Customer) => string, order: readonly string[]): ActiveCohortSplit[] =>
    order.filter((v) => inRange.some((c) => pick(c) === v)).map((v) => {
      const list = inRange.filter((c) => pick(c) === v);
      return { value: v, started: list.length, ages: AGES.map((age) => {
        // pooled over the customers old enough: a cohort row of one customer is Mature when that customer is
        const old = list.filter((c) => addMonths(c.start, age) <= now);
        return { age, started: old.length, stillActive: old.filter((c) => stillAt(c, age)).length };
      }) };
    });
  const dominant = cohorts.length > 0 ? cohorts.reduce((a, b) => (b.started > a.started ? b : a)) : null;

  const ages = active.map((c) => wholeMonths(c.start, now));
  const bandOf = (m: number) => {
    const i = BANDS.findIndex((b) => m < b);
    return i === 0 ? `<${BANDS[0]}` : i === -1 ? `${BANDS[BANDS.length - 1]}+` : `${BANDS[i - 1]}-${BANDS[i]}`;
  };
  const bandWords = [`<${BANDS[0]}`, ...BANDS.slice(0, -1).map((b, i) => `${b}-${BANDS[i + 1]}`), `${BANDS[BANDS.length - 1]}+`];
  const holdingSubs = active.flatMap((c) => c.subs.filter(holding));
  const count = <T,>(list: T[], pick: (x: T) => string) => list.reduce<Record<string, number>>((o, x) => { o[pick(x)] = (o[pick(x)] ?? 0) + 1; return o; }, {});
  const billing = count(holdingSubs, (s) => billingOf(s.interval, s.count));
  const band = count(holdingSubs, (s) => (s.devices >= 3 ? "3+" : String(s.devices)));
  const model = holdingSubs.reduce<Record<string, number>>((o, s) => { o[s.model] = (o[s.model] ?? 0) + s.devices; return o; }, {});
  const inRetry = new Set(holdingSubs.filter((s, i) => s.status === "active" && i % 40 === 7).map((s) => s.id));
  const amountsNow = Object.fromEntries(Object.entries(total.amounts).map(([c, a]) => [c, a.amount]));
  const eurNow = eurOf(amountsNow);
  const reasons = count(active.filter((c) => c.channel === "unknown" && c.reason !== null), (c) => c.reason!);
  const medianAt = (i: number) => {
    const held = spells.filter((s) => holdsAt(s, i));
    const m = median(held.map((s) => wholeMonths(byId.get(s.key)!.start, monthStart(i + 1) - DAY)));
    return m === null ? null : Math.round(m * 10) / 10;
  };

  // the running month's row carries the present (the headline), as the database writes it
  const last = months[months.length - 1];
  if (last) {
    last.customers = total.customers;
    last.bySegment = total.bySegment;
    last.subscriptions = total.subscriptions;
    last.amounts = amountsNow;
    last.eur = eurNow;
  }

  return {
    ...head, setUp: { commerce: true, subscriptions: true }, figures: true, history: true, take, presentAt: take.computedAt,
    filters: { markets: [...new Set(base.map((c) => c.market))].sort(), segments: [...SEGMENTS, "unknown"], channels: [...ACTIVE_CHANNELS] },
    tiles: {
      activeCustomers: {
        value: total.customers, bySegment: total.bySegment, byChannel: { indirect: total.indirect, direct: total.direct, unknown: total.unknownChannel },
        prevMonth: prev?.customers ?? null, prevYear: year?.customers ?? null,
      },
      totalSubscriptions: { value: total.subscriptions, byStatus: count(holdingSubs, (s) => s.status), prevMonth: prev?.subscriptions ?? null, prevYear: year?.subscriptions ?? null },
      amounts: Object.entries(total.amounts).sort().map(([currency, a]) => ({
        currency, ...a, prevMonth: prev?.amounts[currency] ?? null, prevYear: year?.amounts[currency] ?? null,
        averagePrevMonth: prev && prev.customers > 0 && prev.amounts[currency] !== undefined ? round2(prev.amounts[currency]! / Math.max(1, a.customers)) : null,
        averagePrevYear: null,
      })),
      eur: eurNow === null ? null : { amount: eurNow, asOf: FX.asOf, prevMonth: prev?.eur ?? null, prevYear: year?.eur ?? null },
      customerAge: {
        median: total.medianAge,
        over: BANDS.slice(0, 3).map((m) => ({ months: m, customers: ages.filter((a) => a >= m).length, share: ages.length > 0 ? round4(ages.filter((a) => a >= m).length / ages.length) : null })),
        prevMonth: prev ? medianAt(nowIdx - 1) : null, prevYear: year ? medianAt(nowIdx - 13) : null,
      },
      lifetime: { spells: curveAll.spells, ended: curveAll.ended, longest: curveAll.longest, median: curveAll.median },
      clv: total.clv,
    },
    unitEconomics: { churned30d: total.churned30d, slots: ACTIVE_SLOTS.map((s) => ({ key: s.key, status: "pending" as const })) },
    months: months.filter((m) => m.month >= from),
    markets,
    marketsTotal: { ...total, share: total.customers > 0 ? 1 : null },
    comparison: { a: SEGMENTS[0]!, b: SEGMENTS[1]!, rows },
    survival,
    ageBands: bandWords.map((b) => ({ band: b, customers: ages.filter((a) => bandOf(a) === b).length })),
    ageOver: BANDS.slice(0, 3).map((m) => ({ months: m, customers: ages.filter((a) => a >= m).length, share: ages.length > 0 ? round4(ages.filter((a) => a >= m).length / ages.length) : null })),
    cohorts,
    cohortSplits: { segment: splitOf((c) => c.segment, [...SEGMENTS, "unknown"]), channel: splitOf((c) => c.channel, ACTIVE_CHANNELS) },
    mix: {
      billing: ["monthly", "yearly", "other", "unknown"].filter((k) => billing[k]).map((k) => ({ key: k, subscriptions: billing[k]! })),
      deviceBand: ["0", "1", "2", "3+"].map((k) => ({ key: k, subscriptions: band[k] ?? 0 })),
      model: Object.entries(model).sort((a, b) => b[1] - a[1]).map(([k, n]) => ({ key: k, label: MODELS[k] ?? null, devices: n })),
      paymentState: [
        { key: "paid", subscriptions: holdingSubs.filter((s) => s.status === "active" && !inRetry.has(s.id)).length },
        { key: "in_retry", subscriptions: inRetry.size },
        { key: "failed", subscriptions: holdingSubs.filter((s) => s.status === "failed").length },
        { key: "paused", subscriptions: Math.round(all.length * 0.02) },
      ],
    },
    notes: {
      noEndedTime: filter.market === null || filter.market === "GB" ? 3 : 0, noCreatedTime: 0, noAmount: 0, unmatchedSubscriptions: filter.market === null ? 2 : 0,
      reconstructionGap: 0,
      historyStarts: STORES.filter((s) => all.some((c) => c.store === s.store)).map((s) => ({
        store: s.store, market: s.market, date: key(Math.min(...all.filter((c) => c.store === s.store).flatMap((c) => c.subs.map((x) => x.start)))),
      })),
      unknownChannel: { customers: total.unknownChannel, reasons },
      dominantCohort: dominant && inRange.length > 0 && dominant.started / inRange.length > 0.4 ? { cohort: dominant.cohort, share: round4(dominant.started / inRange.length) } : null,
    },
  };
}

/** The customer list for the mock (cma.active_rows): the active customers under the filter, sorted and paged */
export function mockActiveRows(me: Principal, request: ActiveRowsRequest): ActiveList {
  assertAllowed(me);
  const now = Date.now();
  if (me.tenantId === MOCK_TENANT_2) return { setUp: false, history: false, take: null, timeZone: ZONE, total: 0, rows: [], next: null, prev: null };
  const rows: ActiveListRow[] = buildBase(now).filter((c) => matches(c, request.filter) && isActive(c)).map((c) => {
    const subs = c.subs.filter(holding);
    const paying = subs.filter((s) => s.status === "active");
    return {
      storeCustomer: c.id, store: c.store, market: c.market, segment: c.segment, customerStart: key(c.start), ageMonths: wholeMonths(c.start, now),
      subscriptions: subs.length, devices: c.devices, currency: paying.length > 0 ? c.currency : null,
      monthlyAmount: paying.length > 0 ? round2(paying.reduce((n, s) => n + monthly(s), 0)) : null, otherAmounts: {}, clv: c.clv, clvCurrency: c.currency,
      paymentState: subs.some((s) => s.status === "failed") ? "failed" : "paid", channel: c.channel, level: c.level, contactId: c.contact,
      contactUrl: c.contact ? `https://crm.example/record/contact/${c.contact}` : null,
    };
  });
  const dir = request.descending ? -1 : 1;
  const num: Partial<Record<ActiveRowsRequest["sort"], (r: ActiveListRow) => number | null>> = {
    monthly_amount: (r) => r.monthlyAmount, clv: (r) => r.clv, age_months: (r) => r.ageMonths, subscriptions: (r) => r.subscriptions, devices: (r) => r.devices,
    customer_start: (r) => (r.customerStart ? Date.parse(r.customerStart) : null),
  };
  const txt: Partial<Record<ActiveRowsRequest["sort"], (r: ActiveListRow) => string | null>> = {
    store_customer: (r) => r.storeCustomer, store: (r) => r.store, market: (r) => r.market, segment: (r) => r.segment, channel: (r) => r.channel, level: (r) => r.level,
  };
  const cur = (r: ActiveListRow) => (request.sort === "monthly_amount" ? r.currency : request.sort === "clv" ? r.clvCurrency : null);
  const nullsLast = <T,>(a: T | null, b: T | null, cmp: (x: T, y: T) => number) => (a === null ? (b === null ? 0 : 1) : b === null ? -1 : cmp(a, b));
  rows.sort((a, b) =>
    nullsLast(cur(a), cur(b), (x, y) => (x < y ? -1 : x > y ? 1 : 0))
    || nullsLast(num[request.sort]?.(a) ?? null, num[request.sort]?.(b) ?? null, (x, y) => (x - y) * dir)
    || nullsLast(txt[request.sort]?.(a) ?? null, txt[request.sort]?.(b) ?? null, (x, y) => (x < y ? -1 : x > y ? 1 : 0) * dir)
    || (a.storeCustomer < b.storeCustomer ? -1 : 1));
  const take = { computedAt: new Date(now).toISOString(), businessDate: key(now), stale: false, ageMinutes: 0, late: false };
  if (request.file) return { setUp: true, history: true, take, timeZone: ZONE, total: rows.length, rows, next: null, prev: null };
  // keyset paging as the database's: a cursor names a row and nothing else (in the database the customer's own id; here an
  // id made of the row's place in the sorted list), the page continues after it or ends before it
  const MOCK_ID = "00000000-0000-4000-8000-";
  const at = (cursor: string | null | undefined) => {
    if (!cursor) return null;
    const i = cursor.startsWith(MOCK_ID) ? Number.parseInt(cursor.slice(MOCK_ID.length), 16) : Number.NaN;
    if (!Number.isInteger(i) || i < 0 || i >= rows.length) throw new CmaDbError("CMA04", "a cursor is the next or prev of a page of this list");
    return i;
  };
  const cursorOf = (i: number) => MOCK_ID + i.toString(16).padStart(12, "0");
  const after = at(request.after);
  const before = at(request.before);
  const start = before !== null ? Math.max(0, before - request.limit) : after !== null ? after + 1 : 0;
  const end = before !== null ? before : Math.min(rows.length, start + request.limit);
  return {
    setUp: true, history: true, take, timeZone: ZONE, total: rows.length, rows: rows.slice(start, end),
    next: end < rows.length && end > start ? cursorOf(end - 1) : null, prev: start > 0 && end > start ? cursorOf(start) : null,
  };
}
