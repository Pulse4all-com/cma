/**
 * Customers → Subscriptions in mock mode (addition 0009zh): the database's rules (216_subscriptions_page.sql over the
 * takes of 210 and 212) on a fictional subscription base, so the page and the API answer as they will on Postgres. Every
 * date is relative to today (backlog CMA-113's lesson): the stores' first events, the subscriptions' starts, moves and
 * renewals are counted back from the current month, so any month has a whole history. Pulse4all Subscriptions has three
 * stores (GB, NL, DE); Pulse4all Invest has none (set up false). Ids, codes, counts, months and amounts only.
 */
import type { Principal } from "@/lib/auth/identity";
import { CmaDbError } from "@/lib/data/errors";
import type {
  DateKey, SubscriptionMoveKind, SubscriptionRow, SubscriptionRowsList, SubscriptionRowsPage, SubscriptionsChurnCard, SubscriptionsFilter,
  SubscriptionsInterval, SubscriptionsPage, SubscriptionsPageQuery, SubscriptionsRowsQuery, SubscriptionsMixRow,
} from "@/lib/data/types";
import { addMonths, monthOf, monthsBetween, SUBSCRIPTIONS_INTERVALS, SUBSCRIPTIONS_MEASURES, SUBSCRIPTIONS_PAGE_ROWS, SUBSCRIPTIONS_SORTS } from "@/lib/subscriptions";
import { dateKeyInZone } from "@/lib/time";

const MOCK_TENANT_2 = "00000000-0000-7000-8000-000000000002";
const REPORT = ["reports.view", "performance.team"];
const HOLDING = ["active", "failed"];
const ACTIVE = ["active"];
const ENDED = ["canceled", "expired"];
const PROPOSITIONS = ["hs1", "frx"];
const DEVICE_BOUNDS = [1, 2, 3];
const AGE_BOUNDS = [12, 24, 36, 48, 60];
const FX = { as_of: "2026-11-01", GBP: 1.15 };
const STORES = [
  { connectionId: "00000000-0000-7000-8000-00000005b001", handle: "mock-gb", market: "GB", currency: "GBP", back: 30, migrated: true },
  { connectionId: "00000000-0000-7000-8000-00000005b002", handle: "mock-nl", market: "NL", currency: "EUR", back: 28, migrated: false },
  { connectionId: "00000000-0000-7000-8000-00000005b003", handle: "mock-de", market: "DE", currency: "EUR", back: 20, migrated: false },
] as const;

/** FNV-1a, 32 bits: the mock's dice */
function hash(text: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i += 1) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}

const DAY = 86_400_000;
const monthStart = (m: DateKey) => Date.parse(`${m}T00:00:00Z`);

interface MockSub {
  id: string; sourceId: string; number: string; store: (typeof STORES)[number]; createdAt: number; migrated: boolean;
  interval: SubscriptionsInterval; months: number; perCycle: number; deviceUnits: number | null; propositions: string[]; models: string[];
  instrument: string | null; moves: { at: number; to: string }[]; contact: string | null;
}

interface Base { subs: MockSub[]; month: DateKey; now: number; amountsFrom: number; computedAt: string }

/** The fictional base, built once per month and zone (deterministic) */
const cache = new Map<string, Base>();
function baseOf(me: Principal): Base {
  const now = Date.now();
  const today = dateKeyInZone(new Date(now), me.timeZone);
  const month = monthOf(today);
  const key = `${month}|${me.timeZone}`;
  const hit = cache.get(key);
  if (hit) return { ...hit, now };
  const subs: MockSub[] = [];
  for (const st of STORES) {
    const first = addMonths(month, -st.back);
    const count = st.market === "GB" ? 260 : st.market === "NL" ? 160 : 110;
    for (let i = 0; i < count; i += 1) {
      const h = hash(`${st.handle}:${i}`);
      const h2 = hash(`${st.handle}:${i}:b`);
      // a GB subscription among the first sixty was migrated into the app in its first month
      const migrated = st.migrated && i < 60;
      const startMonth = migrated ? first : addMonths(first, h % (st.back + 1));
      const createdAt = Math.min(now - DAY, monthStart(startMonth) + (h2 % 27) * DAY + 9 * 3_600_000);
      const k = h % 100;
      const interval: SubscriptionsInterval = k < 78 ? "monthly" : k < 84 ? "quarterly" : k < 96 ? "yearly" : "other";
      const months = interval === "monthly" ? 1 : interval === "quarterly" ? 3 : interval === "yearly" ? 12 : 6;
      const moves: { at: number; to: string }[] = [{ at: createdAt, to: "active" }];
      const life = now - createdAt;
      const fate = (h2 >>> 8) % 100;
      if (fate < 22 && life > 40 * DAY) {
        const at = createdAt + 30 * DAY + ((h2 >>> 4) % Math.max(1, Math.floor((life - 31 * DAY) / DAY))) * DAY;
        moves.push({ at, to: fate < 15 ? "canceled" : fate < 18 ? "expired" : "failed" });
      } else if (fate < 30 && life > 70 * DAY) {
        const at = createdAt + 35 * DAY + ((h2 >>> 4) % 20) * DAY;
        moves.push({ at, to: "paused" });
        if (fate < 26) moves.push({ at: at + 30 * DAY, to: "active" });
      } else if (fate < 33 && life > 70 * DAY) {
        const at = createdAt + 32 * DAY;
        moves.push({ at, to: "failed" }, { at: at + 9 * DAY, to: "active" });
      }
      const unmapped = (h >>> 12) % 29 === 0;
      const pk = (h >>> 16) % 10;
      subs.push({
        id: `00000000-0000-7000-8000-${(0x5c0000 + subs.length).toString(16).padStart(12, "0")}`,
        sourceId: `${8_100_000 + subs.length * 7}`, number: `#${st.market}${10_000 + i}`, store: st, createdAt, migrated, interval, months,
        perCycle: (29 + ((h >>> 20) % 4) * 10) * months * (interval === "yearly" ? 0.9 : 1),
        deviceUnits: unmapped ? null : 1 + ((h >>> 24) % 3 === 0 ? 1 : 0),
        propositions: pk < 6 ? ["hs1"] : pk < 8 ? ["frx"] : pk < 9 ? ["hs1", "frx"] : [],
        models: unmapped ? [] : [pk < 8 ? "hs1" : "frx"],
        instrument: ["card", "card", "card", "paypal", "sepa_direct_debit", st.market === "GB" ? "bacs_direct_debit" : "card", null][(h >>> 5) % 7] ?? null,
        moves, contact: (h >>> 9) % 5 === 0 ? null : `${70_000_000 + subs.length * 13}`,
      });
    }
  }
  const prev = addMonths(month, -1);
  const built: Base = { subs, month, now, amountsFrom: monthStart(prev) + 19 * DAY, computedAt: new Date(now - 7 * 60_000).toISOString() };
  cache.set(key, built);
  return built;
}

const statusAt = (s: MockSub, t: number): string | null => {
  let st: string | null = null;
  for (const m of s.moves) if (m.at <= t) st = m.to; else break;
  return st;
};
const lastMove = (s: MockSub) => s.moves[s.moves.length - 1] ?? { at: s.createdAt, to: "active" };
const statusNow = (s: MockSub) => lastMove(s).to;
const monthly = (s: MockSub) => Math.round((s.perCycle / s.months) * 100) / 100;
const paymentState = (s: MockSub): string => {
  const st = statusNow(s);
  if (st === "failed") return "failed";
  if (st === "paused") return "paused";
  if (ENDED.includes(st)) return "canceled";
  const k = hash(`${s.id}:ps`) % 100;
  return k < 4 ? "in_retry" : k < 6 ? "charged_back" : k < 8 && s.store.market !== "DE" ? "awaiting_payment" : "paid";
};
const renewals = (s: MockSub, now: number) => {
  const end = ENDED.includes(statusNow(s)) || statusNow(s) === "failed" ? lastMove(s).at : now;
  return Math.max(0, Math.floor((end - s.createdAt) / (s.months * 30.44 * DAY)));
};
const ageMonths = (from: number, now: number) => {
  const a = new Date(from); const b = new Date(now);
  let m = (b.getUTCFullYear() - a.getUTCFullYear()) * 12 + (b.getUTCMonth() - a.getUTCMonth());
  if (b.getUTCDate() < a.getUTCDate()) m -= 1;
  return Math.max(0, m);
};
const TOP_BOUND = DEVICE_BOUNDS[DEVICE_BOUNDS.length - 1] ?? 3;
const countBand = (n: number | null) => (n === null ? "unmapped" : n === 0 ? "0" : n >= TOP_BOUND ? `${TOP_BOUND}+` : String(n));
const DEVICE_BANDS = ["0", "1", "2", "3+"];
const AGE_BANDS = ["<12", "12-24", "24-36", "36-48", "48-60", "60+"];
const ageBand = (m: number) => (m < (AGE_BOUNDS[0] ?? 12) ? "<12" : m >= 60 ? "60+" : `${Math.floor(m / 12) * 12}-${Math.floor(m / 12) * 12 + 12}`);

function assertFilter(me: Principal, f: SubscriptionsFilter, from: DateKey, to: DateKey, month: DateKey): void {
  if (!REPORT.some((p) => me.permissions.includes(p))) throw new CmaDbError("CMA06", "not permitted");
  if (f.market !== null && !/^([A-Z]{2}|unknown)$/.test(f.market)) throw new CmaDbError("CMA04", "market is a market code or unknown");
  if (f.store !== null && !STORES.some((s) => s.connectionId === f.store)) throw new CmaDbError("CMA04", "store is a subscriptions connection of the tenant");
  if (f.proposition !== null && f.proposition !== "none" && !PROPOSITIONS.includes(f.proposition)) throw new CmaDbError("CMA04", "proposition is a code of subscriptions.propositions or none");
  if (f.interval !== null && !(SUBSCRIPTIONS_INTERVALS as readonly string[]).includes(f.interval)) throw new CmaDbError("CMA04", "interval is not a group");
  if (from > to || to > month || monthsBetween(from, to).length > 61) throw new CmaDbError("CMA04", "from and to are months, from at most to, to at most this month");
}

const setUp = (me: Principal) => me.tenantId !== MOCK_TENANT_2;

function scope(b: Base, f: SubscriptionsFilter): MockSub[] {
  return b.subs.filter((s) => (f.market === null || s.store.market === f.market) && (f.store === null || s.store.connectionId === f.store)
    && (f.proposition === null || (f.proposition === "none" ? s.propositions.length === 0 : s.propositions.includes(f.proposition)))
    && (f.interval === null || s.interval === f.interval));
}

function rowOf(s: MockSub, now: number): SubscriptionRow {
  return {
    subscriptionId: s.id, sourceId: s.sourceId, number: s.number, store: s.store.handle, market: s.store.market, status: statusNow(s), paymentState: paymentState(s),
    interval: s.interval, currency: s.store.currency, monthlyAmount: monthly(s), deviceUnits: s.deviceUnits,
    ageMonths: ageMonths(s.createdAt, now),
    propositions: s.propositions, instrument: s.instrument, contactId: s.contact,
    contactUrl: s.contact ? `https://app-eu1.hubspot.com/contacts/00000000/record/0-1/${s.contact}` : null,
  };
}

function rowsOf(b: Base, q: Pick<SubscriptionsRowsQuery, keyof SubscriptionsFilter | "measure" | "sort" | "descending" | "page" | "file">): SubscriptionRowsPage {
  if (!(SUBSCRIPTIONS_MEASURES as readonly string[]).includes(q.measure)) throw new CmaDbError("CMA04", "not a measure");
  if (!(SUBSCRIPTIONS_SORTS as readonly string[]).includes(q.sort)) throw new CmaDbError("CMA04", "not a sort key");
  if (!q.file && (!Number.isInteger(q.page) || q.page < 1 || q.page > 99999)) throw new CmaDbError("CMA04", "page is a whole number from 1");
  const states = ["paid", "in_retry", "charged_back", "awaiting_payment", "failed", "paused", "canceled"];
  const xs = scope(b, q).filter((s) => {
    const st = statusNow(s);
    return q.measure === "total" ? HOLDING.includes(st) : q.measure === "active" ? ACTIVE.includes(st) : q.measure === "failed" ? st === "failed"
      : q.measure === "paused" ? st === "paused" : q.measure === "unmapped" ? HOLDING.includes(st) && s.deviceUnits === null : true;
  }).map((s) => rowOf(s, b.now));
  const key = (r: SubscriptionRow): number | string => {
    switch (q.sort) {
      case "monthly_amount": return `${r.currency ?? ""}|${String(Math.round((r.monthlyAmount ?? -1) * 100) + 1e9).padStart(12, "0")}`;
      case "subscription": return r.sourceId;
      case "market": return r.market;
      case "status": return r.status;
      case "payment_state": return states.indexOf(r.paymentState ?? "") + 1 || 99;
      case "interval": return r.interval;
      default: return r.deviceUnits ?? -1;
    }
  };
  const dir = q.descending ? -1 : 1;
  xs.sort((a, c) => {
    const ka = key(a); const kc = key(c);
    if (ka !== kc) return (ka < kc ? -1 : 1) * dir;
    return (a.sourceId < c.sourceId ? -1 : a.sourceId > c.sourceId ? 1 : 0) * dir;
  });
  const size = q.file ? 50_000 : SUBSCRIPTIONS_PAGE_ROWS;
  const page = q.file ? 1 : q.page;
  return { page, pageSize: size, total: xs.length, measure: q.measure, sort: q.sort, descending: q.descending, rows: xs.slice((page - 1) * size, page * size) };
}

/** Per store and month: the base at the start and end and the moves by kind, as the month take holds them */
function monthRows(b: Base, f: SubscriptionsFilter) {
  const stores = STORES.filter((s) => (f.market === null || s.market === f.market) && (f.store === null || s.connectionId === f.store));
  const out: { market: string; store: string; month: DateKey; complete: boolean; counts: Partial<Record<SubscriptionMoveKind, number>>; amounts: Record<string, Partial<Record<SubscriptionMoveKind, number>>> }[] = [];
  for (const st of stores) {
    const first = addMonths(b.month, -st.back);
    const rateStart = st.migrated ? addMonths(first, 1) : addMonths(first, 1);
    const subs = b.subs.filter((s) => s.store === st);
    for (const m of monthsBetween(first, b.month)) {
      const t0 = monthStart(m);
      const t1 = Math.min(monthStart(addMonths(m, 1)), b.now);
      const counts: Partial<Record<SubscriptionMoveKind, number>> = {};
      const amounts: Record<string, Partial<Record<SubscriptionMoveKind, number>>> = {};
      const add = (k: SubscriptionMoveKind, s: MockSub, at: number) => {
        counts[k] = (counts[k] ?? 0) + 1;
        if (at >= b.amountsFrom) {
          const a = (amounts[st.currency] ??= {});
          a[k] = Math.round(((a[k] ?? 0) + monthly(s)) * 100) / 100;
        }
      };
      for (const s of subs) {
        const before = statusAt(s, t0 - 1);
        if (before !== null && HOLDING.includes(before)) add("start", s, t0);
        const after = statusAt(s, t1 - 1);
        if (after !== null && HOLDING.includes(after)) add("end", s, t1);
        let prev: string | null = null;
        for (const mv of s.moves) {
          if (mv.at >= t0 && mv.at < t1) {
            const kind: SubscriptionMoveKind | null = prev === null ? (s.migrated ? "migrated" : "new")
              : ENDED.includes(mv.to) ? "churned" : mv.to === "failed" ? "moved_to_failed" : mv.to === "paused" ? "paused"
                : mv.to === "active" && prev === "paused" ? "resumed" : mv.to === "active" ? "reactivated" : null;
            if (kind) add(kind, s, mv.at);
          }
          prev = mv.to;
        }
      }
      out.push({ market: st.market, store: st.connectionId, month: m, complete: m < b.month && m >= rateStart, counts, amounts });
    }
  }
  return { rows: out, stores };
}

/**
 * The subscription app's own counts in mock mode: each store in scope read today, its count of holding and paused
 * subscriptions as the CMA's (the CMA's value at the read), with the GB store counting six more active subscriptions
 * than the CMA (one Source figure gap at the mock's tolerances, 1 % and 2, where the store holds fewer than 600), and its
 * amount per currency a little above the CMA's (within); none under a proposition or interval filter, as the database
 * answers
 */
function sourceCountsOf(b: Base, f: SubscriptionsFilter, h: MockSub[], t: MockSub[], amounts: { currency: string; amount: number }[], zone: string) {
  if (f.proposition !== null || f.interval !== null) return null;
  const stores = STORES.filter((s) => (f.market === null || s.market === f.market) && (f.store === null || s.connectionId === f.store));
  if (stores.length === 0) return null;
  const gb = stores.find((s) => s.market === "GB");
  const extra = gb ? 6 : 0;
  const gbActive = gb ? h.filter((s) => s.store.connectionId === gb.connectionId && statusNow(s) === "active").length : 0;
  const today = dateKeyInZone(new Date(b.now), zone);
  const paused = t.filter((s) => statusNow(s) === "paused").length;
  const storesOf = (c: string) => stores.filter((s) => s.currency === c).length;
  return {
    stores: stores.length, inScope: stores.length, from: today, to: today, fetchedAt: new Date(b.now - 3 * 3_600_000).toISOString(),
    total: h.length + extra, totalCma: h.length, totalGaps: gb && extra * 100 > gbActive + extra ? 1 : 0,
    paused, pausedCma: paused, pausedGaps: 0,
    amounts: amounts.map((a) => ({ currency: a.currency, amount: Math.round(a.amount * 1.002 * 100) / 100, cma: a.amount, stores: storesOf(a.currency), gaps: 0 })),
    tolerancePct: 1, toleranceMin: 2,
  };
}

export function mockSubscriptionsPage(me: Principal, q: SubscriptionsPageQuery): SubscriptionsPage {
  const b = baseOf(me);
  const filter: SubscriptionsFilter = { market: q.market, store: q.store, proposition: q.proposition, interval: q.interval };
  assertFilter(me, filter, q.from, q.to, b.month);
  if (!setUp(me)) {
    return {
      setUp: false, history: false, take: null, timeZone: "", today: "", month: "", from: q.from, to: q.to, filter,
      settings: { holding: [], active: [], ended: [], deviceBands: [], ageBands: [], fx: null, propositions: [], historyMonths: 60 },
      filters: { markets: [], stores: [], propositions: [], intervals: [...SUBSCRIPTIONS_INTERVALS] }, tiles: null, months: [], rates: [], storeStarts: [],
      survival: null, mix: null, list: null,
    };
  }
  const t = scope(b, filter);
  const h = t.filter((s) => HOLDING.includes(statusNow(s)));
  const act = t.filter((s) => ACTIVE.includes(statusNow(s)));
  const currencies = [...new Set(act.map((s) => s.store.currency))].sort();
  const amounts = currencies.map((c) => {
    const xs = act.filter((s) => s.store.currency === c);
    return { currency: c, amount: Math.round(xs.reduce((n, s) => n + monthly(s), 0) * 100) / 100, subscriptions: xs.length };
  });
  const rates: Record<string, number> = { GBP: FX.GBP };
  const eurOf = (a: { currency: string; amount: number }) => (a.currency === "EUR" ? a.amount : rates[a.currency] !== undefined ? a.amount * (rates[a.currency] ?? 0) : null);
  const eurs = amounts.map(eurOf);
  const { rows: mrows, stores } = monthRows(b, { ...filter, proposition: null, interval: null });
  const completeMonths = mrows.filter((r) => r.complete && r.month <= q.to).map((r) => r.month).sort();
  const last = completeMonths.length > 0 ? completeMonths[completeMonths.length - 1] : null;
  const partsOf = (rs: typeof mrows) => rs.length === 0 ? null : {
    base: rs.reduce((n, r) => n + (r.counts.start ?? 0), 0), churned: rs.reduce((n, r) => n + (r.counts.churned ?? 0), 0),
    movedToFailed: rs.reduce((n, r) => n + (r.counts.moved_to_failed ?? 0), 0),
  };
  const mix = (key: (s: MockSub) => string[], label?: (k: string) => string | null): SubscriptionsMixRow[] => {
    const m = new Map<string, number>();
    for (const s of h) for (const k of key(s)) m.set(k, (m.get(k) ?? 0) + 1);
    return [...m.entries()].map(([k, n]) => ({ key: k, ...(label ? { label: label(k) } : {}), subscriptions: n }));
  };
  const byOrder = (order: string[]) => (a: SubscriptionsMixRow, c: SubscriptionsMixRow) => (order.indexOf(a.key) + 1 || 99) - (order.indexOf(c.key) + 1 || 99);
  const byCount = (a: SubscriptionsMixRow, c: SubscriptionsMixRow) => c.subscriptions - a.subscriptions || (a.key < c.key ? -1 : 1);
  const surv = t.filter((s) => !s.migrated);
  const groups = SUBSCRIPTIONS_INTERVALS.map((iv) => {
    const cohorts = monthsBetween(q.from, q.to).map((c) => {
      const xs = surv.filter((s) => s.interval === iv && monthOf(new Date(s.createdAt).toISOString().slice(0, 10)) === c);
      if (xs.length === 0) return null;
      const cells = [];
      for (let n = 1; n <= 24; n += 1) {
        const eligible = xs.filter((s) => s.createdAt + n * s.months * 30.44 * DAY <= b.now).length;
        if (eligible === 0 && n > 1) break;
        cells.push({ renewal: n, eligible, survived: xs.filter((s) => renewals(s, b.now) >= n).length });
      }
      return { cohort: c, started: xs.length, cells };
    }).filter((x): x is NonNullable<typeof x> => x !== null);
    return { interval: iv, cohorts };
  }).filter((g) => g.cohorts.length > 0);
  return {
    setUp: true, history: true, take: { computedAt: b.computedAt, businessDate: dateKeyInZone(new Date(b.computedAt), me.timeZone), amountsFrom: new Date(b.amountsFrom).toISOString() },
    timeZone: me.timeZone, today: dateKeyInZone(new Date(b.now), me.timeZone), month: b.month, from: q.from, to: q.to, filter,
    settings: { holding: HOLDING, active: ACTIVE, ended: ENDED, deviceBands: DEVICE_BANDS, ageBands: AGE_BANDS, fx: FX, propositions: PROPOSITIONS, historyMonths: 60 },
    filters: { markets: STORES.map((s) => s.market).sort(), stores: STORES.map((s) => ({ connectionId: s.connectionId, handle: s.handle, market: s.market })),
      propositions: [...PROPOSITIONS, "none"], intervals: [...SUBSCRIPTIONS_INTERVALS] },
    tiles: {
      total: { value: h.length, byStatus: Object.fromEntries(HOLDING.map((st) => [st, h.filter((s) => statusNow(s) === st).length])) },
      paused: t.filter((s) => statusNow(s) === "paused").length,
      amounts,
      eur: amounts.length > 0 && eurs.every((e) => e !== null) ? { amount: Math.round(eurs.reduce((n: number, e) => n + (e ?? 0), 0) * 100) / 100, asOf: FX.as_of } : null,
      rates: last ? { month: last, ...partsOf(mrows.filter((r) => r.month === last && r.complete))! } : null,
      devices: { units: h.reduce((n, s) => n + (s.deviceUnits ?? 0), 0), unmapped: h.filter((s) => s.deviceUnits === null).length },
      sourceCounts: sourceCountsOf(b, filter, h, t, amounts, me.timeZone),
    },
    months: monthsBetween(q.from, q.to).map((m) => {
      const rs = mrows.filter((r) => r.month === m);
      if (rs.length === 0) return { month: m, counts: null, amounts: null, complete: null };
      const counts: Partial<Record<SubscriptionMoveKind, number>> = {};
      const am: Record<string, Partial<Record<SubscriptionMoveKind, number>>> = {};
      for (const r of rs) {
        for (const [k, n] of Object.entries(r.counts)) counts[k as SubscriptionMoveKind] = (counts[k as SubscriptionMoveKind] ?? 0) + (n ?? 0);
        for (const [c, kinds] of Object.entries(r.amounts)) for (const [k, n] of Object.entries(kinds)) {
          const a = (am[c] ??= {});
          a[k as SubscriptionMoveKind] = Math.round(((a[k as SubscriptionMoveKind] ?? 0) + (n ?? 0)) * 100) / 100;
        }
      }
      return { month: m, counts, amounts: Object.keys(am).length > 0 ? am : null, complete: partsOf(rs.filter((r) => r.complete)) };
    }),
    rates: [...new Set(mrows.map((r) => r.market))].sort().flatMap((mk) => monthsBetween(q.from, q.to).flatMap((m) => {
      const rs = mrows.filter((r) => r.market === mk && r.month === m && r.complete);
      return rs.length === 0 ? [] : [{ market: mk, month: m, ...partsOf(rs)! }];
    })),
    storeStarts: stores.map((s) => ({ connectionId: s.connectionId, handle: s.handle, market: s.market, firstEventMonth: addMonths(b.month, -s.back),
      rateStartMonth: addMonths(b.month, -s.back + 1), stragglers: 0 })),
    survival: { groups, migratedLeftOut: t.filter((s) => s.migrated).length },
    mix: {
      proposition: mix((s) => (s.propositions.length ? s.propositions : ["none"])).sort(byCount),
      model: mix((s) => (s.models.length ? s.models : ["none"]), (k) => (k === "hs1" ? "HeartSine 350P" : k === "frx" ? "HeartStart FRx" : null)).sort(byCount),
      interval: mix((s) => [s.interval]).sort(byOrder([...SUBSCRIPTIONS_INTERVALS])),
      deviceBand: mix((s) => [countBand(s.deviceUnits)]).sort(byOrder(DEVICE_BANDS)),
      ageBand: mix((s) => [ageBand(ageMonths(s.createdAt, b.now))]).sort(byOrder(AGE_BANDS)),
      instrument: mix((s) => [s.instrument ?? "unknown"]).sort(byCount),
      paymentState: mix((s) => [paymentState(s)]).sort(byOrder(["paid", "in_retry", "charged_back", "awaiting_payment", "failed", "paused", "canceled"])),
    },
    list: rowsOf(b, { ...filter, measure: q.measure, sort: q.sort, descending: q.descending, page: q.page ?? 1 }),
  };
}

export function mockSubscriptionRows(me: Principal, q: SubscriptionsRowsQuery): SubscriptionRowsList {
  const b = baseOf(me);
  assertFilter(me, q, b.month, b.month, b.month);
  if (!setUp(me)) return { setUp: false, history: false, timeZone: "", computedAt: null, page: 1, pageSize: SUBSCRIPTIONS_PAGE_ROWS, total: 0, measure: q.measure, sort: q.sort, descending: q.descending, rows: [] };
  return { setUp: true, history: true, timeZone: me.timeZone, computedAt: b.computedAt, ...rowsOf(b, q) };
}

/** Customers → Active's Churn rate card in mock mode (cma.subscriptions_churn_card) */
export function mockSubscriptionsChurnCard(me: Principal, market: string | null): SubscriptionsChurnCard {
  if (!setUp(me)) return null;
  const b = baseOf(me);
  const { rows } = monthRows(b, { market, store: null, proposition: null, interval: null });
  const done = rows.filter((r) => r.complete).map((r) => r.month).sort();
  if (done.length === 0) return null;
  const last = done[done.length - 1] ?? "";
  const rs = rows.filter((r) => r.month === last && r.complete);
  return { month: last, base: rs.reduce((n, r) => n + (r.counts.start ?? 0), 0), churned: rs.reduce((n, r) => n + (r.counts.churned ?? 0), 0),
    movedToFailed: rs.reduce((n, r) => n + (r.counts.moved_to_failed ?? 0), 0) };
}
