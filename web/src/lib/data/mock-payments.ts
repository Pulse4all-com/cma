/**
 * Customers → Payments in mock mode (addition 0009zw): the database's rules (246_payments_page.sql over the takes of 210,
 * 212 and 224) on the Subscriptions mock's fictional base, so the page and the API answer as they will on Postgres. The
 * subscriptions, their payment states, instruments, amounts and contacts are the Subscriptions mock's own
 * (mockSubscriptionRows); the since, the overdue flag, the return code and the amount at risk are drawn from the
 * subscription's id; the Failed rate's parts, the stores' starts and the floor are the Subscriptions mock's page's, as
 * 246 reads the same month take. Ids, codes, counts, months and amounts only.
 */
import type { Principal } from "@/lib/auth/identity";
import { CmaDbError } from "@/lib/data/errors";
import type {
  PaymentRow, PaymentRowsList, PaymentRowsPage, PaymentsPage, PaymentsPageQuery, PaymentsRowsQuery, PaymentState, SubscriptionRow, SubscriptionsFilter,
} from "@/lib/data/types";
import { mockSubscriptionRows, mockSubscriptionsPage } from "@/lib/data/mock-subscriptions";
import { PAYMENT_STATES, PAYMENTS_LIST_STATES, PAYMENTS_PAGE_ROWS, PAYMENTS_SORTS } from "@/lib/payments";

const DAY = 86_400_000;
const FX = { as_of: "2026-11-01", GBP: 1.15 } as Record<string, unknown>;

/** FNV-1a, 32 bits: the mock's dice */
function hash(text: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i += 1) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}

/** The Subscriptions mock's rows of the five payment states under the filters, with the take's payment columns */
function baseRows(me: Principal, f: SubscriptionsFilter): { rows: PaymentRow[]; computedAt: string | null; timeZone: string; setUp: boolean } {
  const all = mockSubscriptionRows(me, { ...f, measure: "all", sort: "subscription", descending: false, page: 1, file: true });
  if (!all.setUp) return { rows: [], computedAt: null, timeZone: "", setUp: false };
  const now = Date.now();
  const rows = all.rows
    .filter((r): r is SubscriptionRow & { paymentState: PaymentState } => (PAYMENT_STATES as readonly string[]).includes(r.paymentState ?? ""))
    .map((r): PaymentRow => {
      const h = hash(r.subscriptionId);
      const st = r.paymentState;
      const overdue = st === "awaiting_payment" ? h % 3 === 0 : null;
      const atRisk = st === "in_retry" || st === "failed" || st === "charged_back" || (st === "awaiting_payment" && overdue === true);
      return {
        subscriptionId: r.subscriptionId, sourceId: r.sourceId, number: r.number, store: r.store, market: r.market, status: r.status, paymentState: st,
        stateSince: new Date(now - ((h >>> 4) % (st === "paid" ? 60 : 45)) * DAY - ((h >>> 9) % 86_400) * 1000).toISOString(),
        overdue, returnCode: st === "charged_back" ? (["MD06", "AM04", "fraudulent"][(h >>> 7) % 3] ?? null) : st === "failed" && h % 2 === 0 ? "AM04" : null,
        instrument: r.instrument, currency: r.currency,
        amountAtRisk: atRisk && r.monthlyAmount !== null ? r.monthlyAmount : null, monthlyAmount: r.monthlyAmount,
        contactId: r.contactId, contactUrl: r.contactUrl,
      };
    });
  return { rows, computedAt: all.computedAt, timeZone: all.timeZone, setUp: true };
}

function assertList(state: string, sort: string, descending: unknown): void {
  if (!(PAYMENTS_LIST_STATES as readonly string[]).includes(state)) throw new CmaDbError("CMA04", "state is at_risk, a payment state or all");
  if (!(PAYMENTS_SORTS as readonly string[]).includes(sort)) throw new CmaDbError("CMA04", "not a sort key");
  if (typeof descending !== "boolean") throw new CmaDbError("CMA04", "descending is true or false");
}

function rowsOf(rows: PaymentRow[], q: Pick<PaymentsRowsQuery, "state" | "sort" | "descending" | "page" | "file">): PaymentRowsPage {
  if (!q.file && (!Number.isInteger(q.page) || q.page < 1 || q.page > 99999)) throw new CmaDbError("CMA04", "page is a whole number from 1");
  const xs = rows.filter((r) => (q.state === "at_risk" ? r.amountAtRisk !== null : q.state === "all" ? true : r.paymentState === q.state));
  const key = (r: PaymentRow): string | number => {
    switch (q.sort) {
      case "amount_at_risk": return `${r.currency ?? ""}|${String(Math.round((r.amountAtRisk ?? -1) * 100) + 1e9).padStart(12, "0")}`;
      case "state_since": return r.stateSince ?? "";
      case "subscription": return r.sourceId;
      case "market": return r.market;
      default: return PAYMENT_STATES.indexOf(r.paymentState) + 1 || 99;
    }
  };
  const dir = q.descending ? -1 : 1;
  xs.sort((a, c) => {
    const ka = key(a); const kc = key(c);
    if (ka !== kc) return (ka < kc ? -1 : 1) * dir;
    return (a.sourceId < c.sourceId ? -1 : a.sourceId > c.sourceId ? 1 : 0) * dir;
  });
  const size = q.file ? 50_000 : PAYMENTS_PAGE_ROWS;
  const page = q.file ? 1 : q.page;
  const out = xs.slice((page - 1) * size, page * size);
  return { page, pageSize: size, total: xs.length, state: q.state, sort: q.sort, descending: q.descending,
    rows: q.file ? out.map((r) => ({ ...r, contactUrl: null })) : out };
}

export function mockPaymentsPage(me: Principal, q: PaymentsPageQuery): PaymentsPage {
  assertList(q.state, q.sort, q.descending);
  // the filters, the permission and the set-up are the Subscriptions mock's (246 calls 216's checks)
  const s = mockSubscriptionsPage(me, { ...q, measure: "total", sort: "monthly_amount", descending: true, page: 1 });
  const filter: SubscriptionsFilter = { market: q.market, store: q.store, proposition: q.proposition, interval: q.interval };
  if (!s.setUp) {
    return { setUp: false, history: false, take: null, timeZone: "", today: "", month: "", from: q.from, to: q.to, filter,
      settings: { states: [...PAYMENT_STATES], fx: null, propositions: [], historyMonths: 60 }, filters: s.filters, tiles: null, months: [], rates: [],
      storeStarts: [], ratesStartMonth: null, cross: null, list: null };
  }
  const base = baseRows(me, filter);
  const rows = base.rows;
  const risk = new Map<string, { amount: number; subscriptions: number }>();
  for (const r of rows) {
    if (r.amountAtRisk === null || r.currency === null) continue;
    const x = risk.get(r.currency) ?? { amount: 0, subscriptions: 0 };
    x.amount = Math.round((x.amount + r.amountAtRisk) * 100) / 100; x.subscriptions += 1;
    risk.set(r.currency, x);
  }
  const amounts = [...risk.entries()].sort(([a], [b]) => (a < b ? -1 : 1)).map(([currency, x]) => ({ currency, ...x }));
  const rate = (c: string) => (c === "EUR" ? 1 : typeof FX[c] === "number" ? (FX[c] as number) : null);
  const eur = amounts.length > 0 && amounts.every((a) => rate(a.currency) !== null)
    ? { amount: Math.round(amounts.reduce((n, a) => n + a.amount * (rate(a.currency) ?? 0), 0) * 100) / 100, asOf: String(FX.as_of) } : null;
  const cross = new Map<string, number>();
  for (const r of rows) cross.set(`${r.paymentState}|${r.instrument ?? "unknown"}`, (cross.get(`${r.paymentState}|${r.instrument ?? "unknown"}`) ?? 0) + 1);
  return {
    setUp: true, history: true, take: s.take ? { computedAt: s.take.computedAt, businessDate: s.take.businessDate } : null,
    timeZone: s.timeZone, today: s.today, month: s.month, from: s.from, to: s.to, filter,
    settings: { states: [...PAYMENT_STATES], fx: FX, propositions: s.settings.propositions, historyMonths: s.settings.historyMonths },
    filters: s.filters,
    tiles: {
      total: rows.length,
      byState: PAYMENT_STATES.map((key) => ({ key, subscriptions: rows.filter((r) => r.paymentState === key).length })),
      overdue: rows.filter((r) => r.paymentState === "awaiting_payment" && r.overdue === true).length,
      atRisk: { subscriptions: rows.filter((r) => r.amountAtRisk !== null).length, amounts, eur },
      rates: s.tiles?.rates ? { month: s.tiles.rates.month, base: s.tiles.rates.base, movedToFailed: s.tiles.rates.movedToFailed } : null,
    },
    months: s.months.map((m) => ({ month: m.month, complete: m.complete ? { base: m.complete.base, movedToFailed: m.complete.movedToFailed } : null })),
    rates: s.rates.map((r) => ({ market: r.market, month: r.month, base: r.base, movedToFailed: r.movedToFailed })),
    storeStarts: s.storeStarts, ratesStartMonth: s.ratesStartMonth,
    cross: [...cross.entries()].map(([k, n]) => {
      const [state, instrument] = k.split("|");
      return { state: state as PaymentState, instrument: instrument ?? "unknown", subscriptions: n };
    }).sort((a, b) => PAYMENT_STATES.indexOf(a.state) - PAYMENT_STATES.indexOf(b.state) || (a.instrument < b.instrument ? -1 : a.instrument > b.instrument ? 1 : 0)),
    list: rowsOf(rows, { state: q.state, sort: q.sort, descending: q.descending, page: q.page ?? 1, file: false }),
  };
}

export function mockPaymentRows(me: Principal, q: PaymentsRowsQuery): PaymentRowsList {
  assertList(q.state, q.sort, q.descending);
  const base = baseRows(me, q);
  if (!base.setUp) {
    return { setUp: false, history: false, timeZone: "", computedAt: null, page: 1, pageSize: PAYMENTS_PAGE_ROWS, total: 0, state: q.state, sort: q.sort,
      descending: q.descending, rows: [] };
  }
  return { setUp: true, history: true, timeZone: base.timeZone, computedAt: base.computedAt, ...rowsOf(base.rows, q) };
}
