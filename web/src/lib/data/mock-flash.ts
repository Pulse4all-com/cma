/**
 * Mock mode's Reports → Flash (addition 0008zn; brief B21, 5.4): an invented fixture, computed in memory the way
 * db/122_flash.sql computes it, so every state of the page shows without a database. Tenant one (Pulse4all
 * Subscriptions) holds two stores in two currencies (GB in GBP, NL in EUR), subscriptions, devices, orders, renewals,
 * churn, open deals, tickets and tasks, reviews and every data-quality check of 0008zn with findings; its snapshots run
 * daily from 21 days ago with one date missing (6 days ago), and two watch findings are open. Tenant two (Pulse4all
 * Invest) has a CRM only, so every other overview says its source is not set up, never zero. Ids are invented, links
 * point to example hosts, and no row carries a name, email, phone or address.
 */
import type { Principal } from "@/lib/auth/identity";
import { CmaDbError } from "@/lib/data/errors";
import { FLASH_FROZEN_LIST, FLASH_OVERVIEWS, frozenFilters, overviewOf, withLabels, type FlashKey, type FlashOverviewDef } from "@/lib/flash";
import { addDays, dateKeyInZone } from "@/lib/time";
import type {
  DataQualityRowsView, FlashCardView, FlashDocRowView, FlashDocumentView, FlashFileRead, FlashHeadlineView, FlashPageView, FlashRowsRequest,
  FlashRowsView, FlashSnapshotsView, FlashSourceKey, FlashSourcesView, FlashWatchItem,
} from "./types";

const MOCK_TENANT_2 = "00000000-0000-7000-8000-000000000002";
const REPORT = ["reports.view", "performance.team"];
const DQ = ["reports.view", "tenant.configure"];
const FILE_MAX = 50_000;
const CONN = {
  shopGb: "00000000-0000-7000-8000-00000000f001", shopNl: "00000000-0000-7000-8000-00000000f002", subsGb: "00000000-0000-7000-8000-00000000f003",
  subsNl: "00000000-0000-7000-8000-00000000f004", register: "00000000-0000-7000-8000-00000000f005", crm: "00000000-0000-7000-8000-00000000f006",
  reviews: "00000000-0000-7000-8000-00000000f007",
};
const CRM_URL = "https://crm.example/record";
/** The ended statuses (flash.ended_subscription_statuses, its default): churn and field_device_on_ended_subscription */
const ENDED = ["canceled", "expired"];
// the fixture's required references (set, so the required-reference checks have findings; Pulse4all's own are empty
// until NetSuite holds its customers and devices, Decision log, 3 Nov 2026)
const REQUIRED_CONTACT_REFS: readonly string[] = ["netsuite"];
const REQUIRED_DEVICE_REFS: readonly string[] = ["ns_internal_id"];

type Rec = Record<string, unknown> & { id: string; market: string; since: string };

function assertAny(me: Principal, permissions: string[]): void {
  if (!permissions.some((p) => me.permissions.includes(p))) throw new CmaDbError("CMA06", "not permitted");
}

function todayOf(me: Principal): string {
  return dateKeyInZone(new Date(), me.timeZone);
}

function sourcesOf(me: Principal, today: string): FlashSourcesView {
  const invest = me.tenantId === MOCK_TENANT_2;
  const at = (minutesAgo: number) => new Date(Date.parse(`${today}T12:00:00Z`) - minutesAgo * 60_000).toISOString();
  return {
    commerce: invest ? { setUp: false, adapters: [], lastReadAt: null } : { setUp: true, adapters: ["shopify"], lastReadAt: at(3) },
    subscriptions: invest ? { setUp: false, adapters: [], lastReadAt: null } : { setUp: true, adapters: ["juo"], lastReadAt: at(7) },
    assets: invest ? { setUp: false, adapters: [], lastReadAt: null } : { setUp: true, adapters: ["airtable"], lastReadAt: at(15) },
    crm: { setUp: true, adapters: ["hubspot"], lastReadAt: at(2) },
    reviews: invest ? { setUp: false, adapters: [], lastReadAt: null } : { setUp: true, adapters: ["etrusted"], lastReadAt: at(40) },
  };
}

function setUp(me: Principal, today: string, def: FlashOverviewDef): boolean {
  return def.source === null || Boolean(sourcesOf(me, today)[def.source as FlashSourceKey]?.setUp);
}

// ---- the records ---------------------------------------------------------------------------------

interface Fixture {
  customers: Rec[]; subscriptions: Rec[]; installed_base: Rec[]; churn: Rec[]; orders: Rec[]; payments: Rec[]; open_deals: Rec[]; open_tickets: Rec[];
  open_tasks: Rec[]; reviews: Rec[]; data_quality: Rec[];
}

function fixtureOf(me: Principal, today: string): Fixture {
  const market = (i: number) => (i % 3 === 0 ? "NL" : "GB");
  const store = (m: string) => (m === "GB" ? "p4a-gb" : "p4a-nl");
  const currency = (m: string) => (m === "GB" ? "GBP" : "EUR");
  const day = (back: number) => addDays(today, -back);
  const stamp = (d: string, minute: number) => `${d}T${String(8 + (minute % 10)).padStart(2, "0")}:${String(minute % 60).padStart(2, "0")}:00Z`;
  const statuses = ["active", "active", "active", "active", "active", "paused", "canceled", "expired", "failed", "active"];

  const subscriptions: Rec[] = [];
  for (let i = 1; i <= 72; i += 1) {
    const m = market(i);
    const status = statuses[i % statuses.length] as string;
    const retry = status === "active" && i % 11 === 0;
    subscriptions.push({
      id: `s-71${String(i).padStart(4, "0")}`, subscription_id: `s-71${String(i).padStart(4, "0")}`, market: m, store: store(m), since: day(60 - (i % 40)),
      customer_id: `c-71${String(i % 60 + 1).padStart(4, "0")}`, contact_id: i % 4 === 0 ? null : `43${String(i % 60 + 1).padStart(8, "0")}`,
      contact_url: i % 4 === 0 ? null : `${CRM_URL}/contact/43${String(i % 60 + 1).padStart(8, "0")}`, status,
      payment_state: status === "active" ? (retry ? "in_retry" : "paid") : status === "expired" ? "canceled" : status, amount_per_cycle: 15 + (i % 4) * 5,
      currency: currency(m), billing_interval: "month", billing_interval_count: 1,
      next_billing_at: status === "active" ? stamp(day(-((i % 28) + 1)), i) : null, retry_since: retry ? stamp(day(3), i) : null, last_attempt: retry ? 2 : null,
      devices: i % 6 === 0 ? 0 : 1, is_active: status === "active",
    });
  }
  const customers: Rec[] = [];
  for (let i = 1; i <= 60; i += 1) {
    const m = market(i);
    const id = `c-71${String(i).padStart(4, "0")}`;
    const own = subscriptions.filter((s) => s.customer_id === id);
    const linked = i % 5 !== 0;
    const held = linked && i % 9 !== 0;
    const refs = held && i % 7 !== 0 ? { netsuite: `NS-${50000 + i}` } : {};
    customers.push({
      id, customer_id: id, market: m, store: store(m), since: day(60 - (i % 45)), contact_id: linked ? `43${String(i).padStart(8, "0")}` : null,
      contact_url: linked ? `${CRM_URL}/contact/43${String(i).padStart(8, "0")}` : null, contact_held: held, refs, missing_refs: held && i % 7 === 0 ? ["netsuite"] : [],
      lifetime_orders: 1 + (i % 6), total_spent: 40 + (i % 9) * 35, currency: currency(m),
      active_subscriptions: own.filter((s) => s.is_active).length, paused_subscriptions: own.filter((s) => s.status === "paused").length,
      devices: own.reduce((n, s) => n + Number(s.devices), 0), order_ids: [`#${3000 + i}`], orders_held: 1 + (i % 6),
      subscription_ids: own.map((s) => s.subscription_id),
    });
  }
  const devices: Rec[] = [];
  for (let i = 1; i <= 48; i += 1) {
    const m = i % 4 === 0 ? "NL" : "GB";
    const stock = i % 8 === 0;
    const sub = subscriptions[(i * 5) % subscriptions.length] as Rec;
    const link = stock ? "none" : i % 13 === 0 ? "not_found" : "linked";
    devices.push({
      id: `rec${String(900 + i)}`, serial: `SN-${80000 + i}`, device_id: `rec${String(900 + i)}`, model: i % 3 === 0 ? "aed_3" : "aed_plus", market: m,
      since: day(70 - (i % 50)), status: stock ? "in_stock" : "installed", in_field: !stock, in_stock: stock, warehouse: stock ? "wh-utrecht" : "none",
      refs: i % 10 === 0 ? {} : { ns_internal_id: String(700000 + i) }, missing_refs: i % 10 === 0 ? ["ns_internal_id"] : [],
      customer_id: stock ? null : sub.customer_id, subscription_id: stock ? null : link === "not_found" ? `s-79${i}` : sub.subscription_id, link,
      subscription_status: link === "linked" ? sub.status : null, subscription_payment_state: link === "linked" ? sub.payment_state : null,
      past_due_items: i % 9 === 0 ? 1 : 0, items_due_3m: i % 5 === 0 ? 1 : 0, next_due_on: addDays(today, (i * 23) % 400 - 30),
    });
  }
  const churn: Rec[] = subscriptions.filter((s) => ENDED.includes(String(s.status))).map((s, k) => {
    const d = day((k * 3) % 40);
    return { id: String(s.subscription_id), subscription_id: s.subscription_id, store: s.store, market: s.market, customer_id: s.customer_id,
      churned_at: stamp(d, k), business_date: d, since: d, reason: ["too-expensive", "moving", "none", "no-longer-needed"][k % 4], cycles: 3 + (k % 20) };
  });
  const orders: Rec[] = [];
  for (let k = 1; k <= 180; k += 1) {
    const m = market(k);
    const d = day(k % 45);
    const units = 1 + (k % 3);
    orders.push({
      id: `o-${6100000 + k}`, order_number: `#${4000 + k}`, order_id: String(6100000 + k), store: store(m), market: m, created_at: stamp(d, k), business_date: d, since: d,
      kind: ["first", "repeat", "renewal"][k % 3], financial_status: ["paid", "paid", "pending", "refunded", "partially_refunded"][k % 5],
      fulfillment_status: k % 4 === 0 ? "unfulfilled" : "fulfilled", skus: k % 2 === 0 ? ["AED-PLUS-SUB"] : ["PADS-ADULT", "BATTERY-AED"].slice(0, 1 + (k % 2)),
      units, total: 30 + (k % 7) * 12.5, currency: currency(m), customer_id: `c-71${String(k % 60 + 1).padStart(4, "0")}`,
    });
  }
  const payments: Rec[] = [
    ...orders.map((o) => ({ ...o, id: `p-${o.id}`, kind: "order", status: o.financial_status, record_ref: o.order_number, cycle: null, source_id: o.order_id, at: o.created_at,
      amount: o.total })),
    ...subscriptions.filter((s) => s.status === "active" || s.status === "failed").flatMap((s, k) => [0, 1].map((n) => {
      const d = day((k * 7 + n * 13) % 45);
      const failed = (k + n) % 8 === 0;
      return { id: `r-${s.subscription_id}-${n}`, kind: "renewal", status: failed ? "renew_failed" : "renewed", record_ref: s.subscription_id, cycle: 4 + n,
        source_id: `ev-${s.subscription_id}-${n}`, store: s.store, market: s.market, at: stamp(d, k), business_date: d, since: d, amount: null, currency: null };
    })),
  ];
  const ages = (k: number) => (k * 17) % 60;
  const open_deals: Rec[] = Array.from({ length: 26 }, (_, i) => {
    const m = market(i + 1);
    return { id: `d-${i}`, record_id: String(5100000 + i), record_url: `${CRM_URL}/deal/${5100000 + i}`, pipeline: i % 4 === 0 ? "pl-invest" : "pl-sales",
      stage: ["st-new", "st-quote", "st-negotiation"][i % 3], market: m, owner_ref: `own-${i % 6}`, owner_linked: i % 6 !== 5, created_at: stamp(day(ages(i)), i),
      age_days: ages(i), since: day(ages(i)) };
  });
  const open_tickets: Rec[] = Array.from({ length: 14 }, (_, i) => {
    const m = market(i + 2);
    return { id: `t-${i}`, record_id: String(5200000 + i), record_url: `${CRM_URL}/ticket/${5200000 + i}`, queue: i % 3 === 0 ? "tp-service" : "tp-support",
      stage: i % 2 ? "ts-waiting" : "ts-new", market: m, owner_ref: i % 5 === 0 ? null : `own-${i % 6}`, owner_linked: i % 5 !== 0,
      created_at: stamp(day(ages(i) % 20), i), age_days: ages(i) % 20, since: day(ages(i) % 20) };
  });
  const open_tasks: Rec[] = Array.from({ length: 30 }, (_, i) => {
    const m = market(i);
    const due = addDays(today, (i % 9) - 4);
    return { id: `k-${i}`, task_id: String(5300000 + i), task_url: `${CRM_URL}/task/${5300000 + i}`, type: i % 3 === 0 ? "CALL" : "EMAIL",
      status: i % 4 === 0 ? "WAITING" : "NOT_STARTED", market: m, owner_ref: `own-${i % 6}`, owner_linked: i % 6 !== 5, due_at: stamp(due, i), overdue: due < today,
      record_type: i % 2 ? "deal" : "ticket", record_id: String(i % 2 ? 5100000 + (i % 26) : 5200000 + (i % 14)),
      record_url: `${CRM_URL}/${i % 2 ? "deal" : "ticket"}/${i % 2 ? 5100000 + (i % 26) : 5200000 + (i % 14)}`, since: day(10) };
  });
  const reviews: Rec[] = Array.from({ length: 64 }, (_, i) => {
    const d = day(i % 45);
    const stars = i % 9 === 0 ? 1 : i % 7 === 0 ? 2 : i % 3 === 0 ? 4 : 5;
    return { id: `rv-${i}`, review_id: `rev-${8800 + i}`, review_url: null, channel: i % 3 === 0 ? "chl-nl" : "chl-gb", market: i % 3 === 0 ? "NL" : "GB",
      rating: stars, stars, negative: stars <= 2, submitted_at: stamp(d, i), business_date: d, since: d, link_level: ["order", "contact", "none"][i % 3] };
  });
  const dq: Rec[] = [];
  const finding = (check: string, object_type: string, object_id: string, value: string | null, m: string, fix_in: string, fix_adapter: string | null,
    related?: { type: string; id: string; url: string | null }) => dq.push({
    id: `${check}:${object_id}`, check, object_type, object_id, value, market: m, fix_in, fix_adapter, since: day(30 - (dq.length % 25)),
    record_url: object_type === "commerce_customer" ? null : object_type === "contact" ? `${CRM_URL}/contact/${object_id}` : null,
    related_type: related?.type ?? null, related_id: related?.id ?? null, related_url: related?.url ?? null,
  });
  // the required-reference checks find nothing while their setting is empty, as cma.data_quality_of
  for (const c of REQUIRED_CONTACT_REFS.length > 0 ? customers : []) {
    if (c.contact_id && !c.contact_held) finding("customer_required_ref_missing", "commerce_customer", c.id, "contact_not_held", c.market, "cma", null,
      { type: "contact", id: String(c.contact_id), url: String(c.contact_url) });
    else if ((c.missing_refs as string[]).length) finding("customer_required_ref_missing", "commerce_customer", c.id, "netsuite", c.market, "crm", "hubspot",
      { type: "contact", id: String(c.contact_id), url: String(c.contact_url) });
  }
  for (const d of devices) {
    if (REQUIRED_DEVICE_REFS.length > 0 && (d.missing_refs as string[]).length) finding("device_required_ref_missing", "device", String(d.device_id), "ns_internal_id", d.market, "assets", "airtable");
    if (d.link === "not_found") finding("device_subscription_ref_unknown", "device", String(d.device_id), null, d.market, "assets", "airtable",
      { type: "subscription", id: String(d.subscription_id), url: null });
    if (d.link === "linked" && ENDED.includes(String(d.subscription_status))) {
      finding("field_device_on_ended_subscription", "device", String(d.device_id), String(d.subscription_status), d.market, "assets", "airtable",
        { type: "subscription", id: String(d.subscription_id), url: null });
    }
  }
  for (const s of subscriptions) {
    if (s.is_active && s.devices === 0) finding("active_subscription_without_device", "subscription", s.id, "active", s.market, "assets", "airtable");
  }
  for (const s of subscriptions.filter((_, k) => k % 17 === 3)) {
    finding("subscription_customer_unmatched", "subscription", s.id, null, s.market, "commerce", "shopify");
  }
  for (let i = 0; i < 4; i += 1) finding("deal_without_contact", "deal", String(5100100 + i), null, market(i), "crm", "hubspot");
  for (let i = 0; i < 3; i += 1) finding("device_serial_missing", "device", `rec${990 + i}`, null, "GB", "assets", "airtable");
  return { customers, subscriptions, installed_base: devices, churn, orders, payments, open_deals, open_tickets, open_tasks, reviews, data_quality: dq };
}

// ---- the figures, as cma.flash_compute_of gives them --------------------------------------------

type Measures = FlashDocRowView["measures"];

/**
 * The customers' figures as cma.flash_compute_of gives them: with_required_refs left out while no contact reference
 * is required (a measure that does not apply, never 0 or all)
 */
export function mockCustomersFigures(rs: readonly Record<string, unknown>[], contactRefsRequired: boolean): Measures {
  const n = (f: (r: Record<string, unknown>) => boolean) => rs.filter(f).length;
  return {
    customers_held: rs.length, active_customers: n((r) => Number(r.active_subscriptions) > 0),
    paused_customers: n((r) => Number(r.active_subscriptions) === 0 && Number(r.paused_subscriptions) > 0), linked_to_contact: n((r) => r.contact_id !== null),
    ...(contactRefsRequired
      ? { with_required_refs: n((r) => r.contact_id !== null && r.contact_held === true && (r.missing_refs as string[]).length === 0) }
      : {}),
  };
}

function measuresOf(def: FlashOverviewDef, rs: readonly Rec[]): Measures {
  const n = (f: (r: Rec) => boolean) => rs.filter(f).length;
  const per = (field: string, f: (r: Rec) => boolean = () => true) => {
    const out: Record<string, number> = {};
    for (const r of rs.filter(f)) {
      const c = r.currency as string | null;
      const v = r[field] as number | null;
      if (c && typeof v === "number") out[c] = Math.round(((out[c] ?? 0) + v) * 100) / 100;
    }
    return out;
  };
  const sum = (field: string) => rs.reduce((s, r) => s + (Number(r[field]) || 0), 0);
  const ages = rs.map((r) => Number(r.age_days)).sort((a, b) => a - b);
  const median = ages.length ? (ages.length % 2 ? ages[(ages.length - 1) / 2]! : ((ages[ages.length / 2 - 1]! + ages[ages.length / 2]!) / 2)) : null;
  switch (def.key) {
    case "customers": return mockCustomersFigures(rs, REQUIRED_CONTACT_REFS.length > 0);
    case "subscriptions": return { subscriptions: rs.length, active_subscriptions: n((r) => r.is_active === true), paused_subscriptions: n((r) => r.status === "paused"),
      amount_per_cycle: per("amount_per_cycle", (r) => r.is_active === true) };
    case "installed_base": return { devices: rs.length, in_field: n((r) => r.in_field === true), in_stock: n((r) => r.in_stock === true),
      components_past_due: sum("past_due_items"), items_due_3m: sum("items_due_3m") };
    case "churn": return { churned: rs.length };
    case "orders": return { orders: rs.length, units: sum("units"), amount: per("total") };
    case "payments": return { orders: n((r) => r.kind === "order"), amount: per("amount", (r) => r.kind === "order"),
      renewals: n((r) => r.kind === "renewal" && r.status === "renewed"), failed_renewals: n((r) => r.kind === "renewal" && r.status === "renew_failed") };
    case "open_deals": return { open_deals: rs.length, median_age_days: median, oldest_age_days: ages.length ? ages[ages.length - 1]! : null };
    case "open_tickets": return { open_tickets: rs.length, median_age_days: median, oldest_age_days: ages.length ? ages[ages.length - 1]! : null };
    case "open_tasks": return { open_tasks: rs.length, overdue: n((r) => r.overdue === true) };
    case "reviews": return { reviews: rs.length, rating_sum: sum("rating"), negative: n((r) => r.negative === true) };
    case "data_quality": return { findings: rs.length };
  }
}

/** Every grouping set's rows; the SKU set of orders counts lines per SKU */
function rowsOf(def: FlashOverviewDef, rs: readonly Rec[]): FlashDocRowView[] {
  const out: FlashDocRowView[] = [];
  for (const set of def.sets) {
    if (def.key === "orders" && set.includes("sku")) {
      const groups = new Map<string, Rec[]>();
      for (const r of rs) for (const sku of r.skus as string[]) {
        const k = `${r.market}|${sku}`;
        groups.set(k, [...(groups.get(k) ?? []), r]);
      }
      for (const [k, g] of [...groups].sort(([a], [b]) => a.localeCompare(b))) {
        const [m, sku] = k.split("|");
        out.push({ dims: { market: m!, sku: sku! }, measures: { orders: g.length, units: g.length } });
      }
      continue;
    }
    const groups = new Map<string, Rec[]>();
    for (const r of rs) {
      const k = JSON.stringify(set.map((d) => String(r[d === "check" ? "check" : d] ?? "none")));
      groups.set(k, [...(groups.get(k) ?? []), r]);
    }
    if (set.length === 0) {
      out.push({ dims: {}, measures: measuresOf(def, rs) });
      continue;
    }
    for (const [k, g] of [...groups].sort(([a], [b]) => a.localeCompare(b))) {
      const values = JSON.parse(k) as string[];
      out.push({ dims: Object.fromEntries(set.map((d, i) => [d, values[i]!])), measures: measuresOf(def, g) });
    }
  }
  return out;
}

const SNAPSHOT_FROM = 21;
const SNAPSHOT_MISSING = 6;

/** The business dates with a succeeded snapshot: 21 days back to yesterday, one missing; none for tenant two before 3 days ago */
function snapshotDates(me: Principal, today: string): string[] {
  const out: string[] = [];
  const first = me.tenantId === MOCK_TENANT_2 ? 3 : SNAPSHOT_FROM;
  for (let k = first; k >= 1; k -= 1) if (k !== SNAPSHOT_MISSING) out.push(addDays(today, -k));
  return out;
}

/** An overview's records as of a date (null for now): stock records held by then, flow records of the period */
function recordsOf(me: Principal, today: string, def: FlashOverviewDef, asOf: string | null, from: string | null, to: string | null): Rec[] {
  const all = fixtureOf(me, today)[def.key];
  if (def.kind === "flow") {
    const f = from ?? asOf ?? today;
    const t = to ?? asOf ?? today;
    return all.filter((r) => r.since >= f && r.since <= t);
  }
  return asOf ? all.filter((r) => r.since <= asOf) : all;
}

function assertParams(today: string, market: string | null, asOf: string | null, from: string | null, to: string | null): void {
  if (market !== null && !/^([A-Z]{2}|unknown)$/.test(market)) throw new CmaDbError("CMA04", "a market is a market's code or unknown");
  if (asOf !== null && asOf >= today) throw new CmaDbError("CMA04", "as of is a business date before today");
  if ((from !== null && from > today) || (to !== null && to > today) || (from !== null && to !== null && from > to)) {
    throw new CmaDbError("CMA04", "a period runs forward and ends today at the latest");
  }
}

function headlineOf(def: FlashOverviewDef, rows: readonly FlashDocRowView[], market: string | null): number | null {
  const row = rows.find((r) => (market ? r.dims.market === market && Object.keys(r.dims).length === 1 : Object.keys(r.dims).length === 0));
  const v = row?.measures[def.headline];
  return typeof v === "number" ? v : row || rows.length ? 0 : null;
}

function watchOf(me: Principal, today: string): FlashWatchItem[] {
  if (me.tenantId === MOCK_TENANT_2) return [];
  return [
    { kind: "jump", overview: "customers", dims: { market: "GB" }, measure: "active_customers", value: 41, previous: 33, threshold: 6.6,
      detail: { jump_pct: 20, jump_min: 10 }, snapshotDate: addDays(today, -1) },
    { kind: "dq_rise", overview: "data_quality", dims: { check: "device_required_ref_missing" }, measure: "findings", value: 5, previous: 2, threshold: 0.4,
      detail: { jump_pct: 20, jump_min: 10 }, snapshotDate: addDays(today, -2) },
    { kind: "snapshot_missing", overview: null, dims: {}, measure: null, value: 1, previous: null, threshold: null,
      detail: { missing_from: addDays(today, -SNAPSHOT_MISSING), missing_to: addDays(today, -SNAPSHOT_MISSING), days: 1 }, snapshotDate: addDays(today, -SNAPSHOT_MISSING + 1) },
  ];
}

function labelsOf(def: FlashOverviewDef): Record<string, Record<string, string>> {
  const all: Record<string, Record<string, string>> = {
    market: { GB: "United Kingdom", NL: "Netherlands" }, store: { "p4a-gb": "Shop GB", "p4a-nl": "Shop NL" },
    pipeline: { "pl-sales": "Sales", "pl-invest": "Invest" },
    // a stage keyed '<pipeline id>:<stage id>', as cma.flash_labels_of keys it; the Invest pipeline's negotiation stage
    // has no label, so the page and the files show its id (Decision log, 4 Nov 2026)
    stage: def.key === "open_tickets"
      ? { "tp-service:ts-new": "New", "tp-service:ts-waiting": "Waiting on us", "tp-support:ts-new": "New", "tp-support:ts-waiting": "Waiting on contact" }
      : { "pl-sales:st-new": "New", "pl-sales:st-quote": "Quote sent", "pl-sales:st-negotiation": "Negotiation", "pl-invest:st-new": "New", "pl-invest:st-quote": "Quote sent" },
    queue: { "tp-service": "Service", "tp-support": "Support" }, model: { aed_plus: "AED Plus", aed_3: "AED 3" },
    status: { installed: "Installed", in_stock: "In stock", NOT_STARTED: "Not started", WAITING: "Waiting" }, type: { CALL: "Call", EMAIL: "Email" },
    warehouse: { "wh-utrecht": "Utrecht" },
    check: {
      customer_required_ref_missing: "Store customers with an order whose CRM contact lacks a required reference, or is not held",
      device_required_ref_missing: "Devices lacking a required named id, with the ids missing",
      subscription_customer_unmatched: "Subscriptions whose customer id no customer of their store holds",
      active_subscription_without_device: "Active subscriptions no device in the register names",
      device_subscription_ref_unknown: "Devices in the field whose subscription reference names no subscription the Workspace holds",
      field_device_on_ended_subscription: "Devices in the field linked to a subscription in an ended status (flash.ended_subscription_statuses), with its status",
      deal_without_contact: "Lead deals without any contact",
      device_serial_missing: "Devices without a serial number",
    },
  };
  return Object.fromEntries(def.dims.filter((d) => all[d]).map((d) => [d, all[d]!]));
}

// ---- the reads ----------------------------------------------------------------------------------

export function mockFlashPage(me: Principal, market: string | null, asOf: string | null, from: string | null, to: string | null): FlashPageView {
  assertAny(me, REPORT);
  const today = todayOf(me);
  assertParams(today, market, asOf, from, to);
  const dates = snapshotDates(me, today);
  const first = dates[0] ?? null;
  const last = dates[dates.length - 1] ?? null;
  if (asOf && !dates.includes(asOf)) {
    return { mode: "snapshot", asOf, market, from: null, to: null, snapshotMissing: true, nearestBefore: [...dates].reverse().find((d) => d < asOf) ?? null,
      nearestAfter: dates.find((d) => d > asOf) ?? null, sources: {}, overviews: [], markets: [], watch: [], firstSnapshotDate: first, lastSnapshotDate: last,
      today, timeZone: me.timeZone };
  }
  const f = from ?? asOf ?? today;
  const t = to ?? asOf ?? today;
  const len = Math.round((Date.parse(`${t}T00:00:00Z`) - Date.parse(`${f}T00:00:00Z`)) / 86_400_000) + 1;
  const overviews: FlashCardView[] = FLASH_OVERVIEWS.map((def) => {
    const up = setUp(me, today, def);
    let value: number | null = null;
    let previous: number | null = null;
    let previousOn: string | null = null;
    if (up) {
      if (asOf) value = headlineOf(def, rowsOf(def, recordsOf(me, today, def, asOf, def.kind === "flow" ? f : null, def.kind === "flow" ? t : null)), market);
      if (def.kind === "stock") {
        previousOn = [...dates].reverse().find((d) => d < (asOf ?? today)) ?? null;
        if (previousOn) previous = headlineOf(def, rowsOf(def, recordsOf(me, today, def, previousOn, null, null)), market);
      } else {
        const pf = addDays(f, -len);
        const pt = addDays(f, -1);
        const covered = dates.filter((d) => d >= pf && d <= pt).length;
        if (covered === len) {
          previousOn = pt;
          previous = headlineOf(def, rowsOf(def, recordsOf(me, today, def, null, pf, pt)), market);
        }
      }
    }
    return { key: def.key, kind: def.kind, source: def.source, setUp: up, headline: def.headline, value, previous, previousOn, definitionVersion: "0008zn" };
  });
  return {
    mode: asOf ? "snapshot" : "live", asOf: asOf ?? new Date().toISOString(), market, from: f, to: t, snapshotMissing: false, nearestBefore: null, nearestAfter: null,
    sources: sourcesOf(me, today), overviews, markets: [{ code: "GB", name: "United Kingdom" }, { code: "NL", name: "Netherlands" }], watch: watchOf(me, today),
    firstSnapshotDate: first, lastSnapshotDate: last, today, timeZone: me.timeZone,
  };
}

export function mockFlashOverview(me: Principal, overview: string, market: string | null, asOf: string | null, from: string | null,
  to: string | null): FlashDocumentView {
  assertAny(me, REPORT);
  const def = overviewOf(overview);
  if (!def) throw new CmaDbError("CMA04", "an unknown overview");
  const today = todayOf(me);
  assertParams(today, market, asOf, from, to);
  const dates = snapshotDates(me, today);
  if (asOf && def.kind === "stock" && !dates.includes(asOf)) throw new CmaDbError("CMA02", "no snapshot for this date");
  const f = def.kind === "flow" ? from ?? asOf ?? today : null;
  const t = def.kind === "flow" ? to ?? asOf ?? today : null;
  let days: FlashDocumentView["days"] = null;
  if (asOf && def.kind === "flow") {
    const all: string[] = [];
    for (let d = f!; d <= t!; d = addDays(d, 1)) all.push(d);
    const covered = all.filter((d) => dates.includes(d));
    if (covered.length === 0) throw new CmaDbError("CMA02", "no snapshot in this period");
    days = { covered: covered.length, missing: all.filter((d) => !dates.includes(d)) };
  }
  const up = setUp(me, today, def);
  const rs = up ? recordsOf(me, today, def, def.kind === "stock" ? asOf : null, f, t) : [];
  const all = up ? rowsOf(def, rs) : [];
  const total = all.find((r) => Object.keys(r.dims).length === 0)?.measures ?? null;
  const own = market ? all.find((r) => Object.keys(r.dims).length === 1 && r.dims.market === market)?.measures ?? null : null;
  const zero = (m: Measures | null) => (m ? Object.fromEntries(Object.entries(m).filter(([k]) => !k.endsWith("_age_days")).map(([k, v]) => [k, v !== null && typeof v === "object" ? {} : 0])) : null);
  const history: FlashDocumentView["history"] = [];
  if (def.key === "data_quality") {
    const checks = [...new Set(fixtureOf(me, today).data_quality.map((r) => String(r.check)))].sort();
    for (const d of dates.slice(-30)) {
      if (asOf && d > asOf) continue;
      for (const c of checks) {
        history.push({ date: d, check: c, findings: fixtureOf(me, today).data_quality.filter((r) => r.check === c && r.since <= d && (!market || r.market === market)).length });
      }
    }
  }
  let activeAtEnd: number | null = null;
  if (def.key === "churn" && up) {
    const subs = fixtureOf(me, today).subscriptions.filter((s) => s.is_active && (!market || s.market === market));
    activeAtEnd = t && (dates.includes(t) || t >= today) ? subs.filter((s) => s.since <= t).length : null;
  }
  const sources = sourcesOf(me, today);
  return {
    overview: def.key, kind: def.kind, mode: asOf ? "snapshot" : "live", asOf: asOf ?? new Date().toISOString(), asOfDate: asOf, market, from: f, to: t, setUp: up,
    source: def.source, sources, dims: [...def.dims], sets: def.sets.map((s) => [...s]), measures: [...def.measures], countMeasures: [...def.countMeasures],
    headline: def.headline, sorts: [...def.sorts], totals: market ? own ?? zero(total) : total,
    rows: all.filter((r) => Object.keys(r.dims).length > 0 && (!market || r.dims.market === market)), labels: labelsOf(def),
    settings: { fileMaxRows: FILE_MAX, negativeMaxRating: 2, requiredDeviceRefs: [...REQUIRED_DEVICE_REFS], requiredContactRefs: [...REQUIRED_CONTACT_REFS], activeSubscriptionStatuses: ["active"],
      endedSubscriptionStatuses: ENDED },
    definitionVersion: "0008zn", firstSnapshotDate: dates[0] ?? null, days, activeAtEnd, history, today, timeZone: me.timeZone,
  };
}

/** A record as the API answers it: the fixture's own fields (its key, its date and its active flag) left out */
function publicOf(r: Rec): Record<string, unknown> {
  return Object.fromEntries(Object.entries(r).filter(([k]) => k !== "id" && k !== "since" && k !== "is_active"));
}

function compare(a: unknown, b: unknown): number {
  if (a === b) return 0;
  if (a === null || a === undefined) return 1;
  if (b === null || b === undefined) return -1;
  if (typeof a === "number" && typeof b === "number") return a - b;
  return String(a).localeCompare(String(b));
}

/** The list's sort key's field on a record (as cma.flash_order_by names it) */
const SORT_FIELD: Record<string, string> = { "customers:customer_id": "customer_id", "data_quality:check": "check", "payments:at": "at" };

export function mockFlashRows(me: Principal, request: FlashRowsRequest): FlashRowsView {
  assertAny(me, REPORT);
  const def = overviewOf(request.overview);
  if (!def) throw new CmaDbError("CMA04", "an unknown overview");
  const today = todayOf(me);
  assertParams(today, request.filters.market ?? null, request.asOf, request.from, request.to);
  if (request.limit < 1 || request.limit > FILE_MAX || request.offset < 0) throw new CmaDbError("CMA04", "a list reads 1 to 50,000 rows");
  for (const k of Object.keys(request.filters)) if (k !== "measure" && !def.dims.includes(k)) throw new CmaDbError("CMA04", "filters are the overview's dims");
  if (request.sort && !def.sorts.includes(request.sort) && !request.asOf) throw new CmaDbError("CMA04", "a sort key of the overview");
  const base = { overview: def.key, from: def.kind === "flow" ? request.from ?? today : null, to: def.kind === "flow" ? request.to ?? today : null,
    sort: request.sort, descending: request.descending, limit: request.limit, offset: request.offset, filters: request.filters,
    setUp: setUp(me, today, def), timeZone: me.timeZone };
  if (request.asOf) {
    // a past month end's frozen list only, filtered as cma.flash_id_rows_of filters it: market, status (not for
    // customers) and the list's own measure, CMA04 for any other filter
    const frozen = FLASH_FROZEN_LIST[def.key];
    if (!frozen) throw new CmaDbError("CMA02", "a list of a past date exists for customers, subscriptions and installed_base, at a month end");
    if (frozenFilters(def, request.filters).dropped.length > 0) throw new CmaDbError("CMA04", "a past month end's list is filtered by market and status only");
    const monthEnd = addDays(request.asOf, 1).slice(8, 10) === "01";
    if (!monthEnd || !snapshotDates(me, today).includes(request.asOf)) throw new CmaDbError("CMA02", "no frozen list for this date: lists are kept for month ends");
    const rs = recordsOf(me, today, def, request.asOf, null, null)
      .filter((r) => def.key !== "customers" || Number(r.active_subscriptions) > 0)
      .filter((r) => def.key !== "subscriptions" || r.is_active === true)
      .filter((r) => !request.filters.market || r.market === request.filters.market)
      .map((r) => ({ source_id: String(r.customer_id ?? r.subscription_id ?? r.device_id), market: r.market, state: String(r.status ?? "active"), snapshot_date: request.asOf }))
      .filter((r) => !request.filters.status || r.state === request.filters.status);
    rs.sort((a, b) => compare(a.source_id, b.source_id));
    return { ...base, mode: "snapshot", asOf: request.asOf, total: rs.length, rows: rs.slice(request.offset, request.offset + request.limit) };
  }
  if (!setUp(me, today, def)) return { ...base, mode: "live", asOf: new Date().toISOString(), total: 0, rows: [] };
  let rs = recordsOf(me, today, def, null, base.from, base.to);
  for (const [k, v] of Object.entries(request.filters)) {
    if (k === "measure") continue;
    rs = def.key === "orders" && k === "sku" ? rs.filter((r) => (r.skus as string[]).includes(v)) : rs.filter((r) => String(r[k] ?? "none") === v);
  }
  const m = request.filters.measure;
  // a measure that does not apply has no records (CMA04, as cma.flash_rows answers)
  if (def.key === "customers" && m === "with_required_refs" && REQUIRED_CONTACT_REFS.length === 0) {
    throw new CmaDbError("CMA04", "with_required_refs does not apply: commerce.required_contact_refs is empty");
  }
  const keep: Record<string, (r: Rec) => boolean> = {
    active_customers: (r) => Number(r.active_subscriptions) > 0, paused_customers: (r) => Number(r.active_subscriptions) === 0 && Number(r.paused_subscriptions) > 0,
    linked_to_contact: (r) => r.contact_id !== null, with_required_refs: (r) => r.contact_held === true && (r.missing_refs as string[]).length === 0,
    active_subscriptions: (r) => r.is_active === true, paused_subscriptions: (r) => r.status === "paused", in_field: (r) => r.in_field === true,
    in_stock: (r) => r.in_stock === true, components_past_due: (r) => Number(r.past_due_items) > 0, items_due_3m: (r) => Number(r.items_due_3m) > 0,
    renewals: (r) => r.kind === "renewal" && r.status === "renewed", failed_renewals: (r) => r.kind === "renewal" && r.status === "renew_failed",
    overdue: (r) => r.overdue === true, negative: (r) => r.negative === true,
  };
  if (m && keep[m]) rs = rs.filter(keep[m]!);
  if (m === "orders" && def.key === "payments") rs = rs.filter((r) => r.kind === "order");
  const sort = request.sort ?? def.sorts[0] ?? "";
  const field = SORT_FIELD[`${def.key}:${sort}`] ?? (sort === "total_spent" ? "total_spent" : sort);
  const amount = ["total_spent", "amount_per_cycle", "total", "amount"].includes(sort);
  rs = [...rs].sort((a, b) => {
    if (amount) {
      const c = compare(a.currency, b.currency);
      if (c !== 0) return c;
    }
    const v = compare(a[field], b[field]);
    if (v !== 0) return a[field] === null || a[field] === undefined || b[field] === null || b[field] === undefined ? v : request.descending ? -v : v;
    return compare(a.id, b.id);
  });
  // a pipeline's and a stage's label beside its id, as the data layer adds it to the database's rows
  const rows = withLabels(def.key, rs.slice(request.offset, request.offset + request.limit).map(publicOf), labelsOf(def));
  return { ...base, mode: "live", asOf: new Date().toISOString(), sort, total: rs.length, rows };
}

export function mockFlashHeadline(me: Principal, overview: string, market: string | null, from: string | null, to: string | null): FlashHeadlineView {
  assertAny(me, REPORT);
  const def = overviewOf(overview);
  if (!def) throw new CmaDbError("CMA04", "an unknown overview");
  const today = todayOf(me);
  assertParams(today, market, null, from, to);
  const up = setUp(me, today, def);
  const f = def.kind === "flow" ? from ?? today : null;
  const t = def.kind === "flow" ? to ?? today : null;
  return { overview: def.key, headline: def.headline, market, asOf: new Date().toISOString(), from: f, to: t, setUp: up,
    value: up ? headlineOf(def, rowsOf(def, recordsOf(me, today, def, null, f, t)), market) : null };
}

export function mockFlashSnapshots(me: Principal, from: string | null, to: string | null): FlashSnapshotsView {
  assertAny(me, REPORT);
  const today = todayOf(me);
  const t = to ?? today;
  const f = from ?? addDays(t, -90);
  if (f > t) throw new CmaDbError("CMA04", "a period runs forward");
  const dates = snapshotDates(me, today);
  // the date the job missed has a run row of its own (status missed, no figures), as the take records it
  const missed = me.tenantId === MOCK_TENANT_2 ? null : addDays(today, -SNAPSHOT_MISSING);
  const runs = [...dates.map((d, i, all) => ({ date: d, status: "succeeded" as "succeeded" | "missed",
      missedBefore: i > 0 && addDays(all[i - 1]!, 1) !== d ? 1 : 0, finishedAt: `${addDays(d, 1)}T00:31:${String(10 + (i % 40)).padStart(2, "0")}Z`, error: null })),
    ...(missed ? [{ date: missed, status: "missed" as const, missedBefore: 0, finishedAt: `${addDays(missed, 2)}T00:31:00Z`, error: null }] : [])]
    .sort((a, b) => compare(a.date, b.date));
  return {
    from: f, to: t, firstSnapshotDate: dates[0] ?? null, lastSnapshotDate: dates[dates.length - 1] ?? null, watch: watchOf(me, today),
    dates: runs.filter((r) => r.date >= f && r.date <= t),
  };
}

export function mockDataQualityRows(me: Principal, request: { check: string; market: string | null; limit: number; offset: number }): DataQualityRowsView {
  assertAny(me, DQ);
  if (!/^[a-z][a-z0-9_]{0,59}$/.test(request.check)) throw new CmaDbError("CMA04", "no data-quality check");
  if (request.limit < 1 || request.limit > FILE_MAX || request.offset < 0) throw new CmaDbError("CMA04", "a list reads 1 to 50,000 rows");
  const today = todayOf(me);
  const rs = fixtureOf(me, today).data_quality.filter((r) => r.check === request.check && (!request.market || r.market === request.market))
    .sort((a, b) => compare(a.object_id, b.object_id));
  return { check: request.check, description: null, market: request.market, limit: request.limit, offset: request.offset, total: rs.length,
    rows: rs.slice(request.offset, request.offset + request.limit).map((r) => ({ ...publicOf(r), connection_id: CONN.crm })) };
}

/**
 * The file read or bulk read of records: checked as cma.flash_file_record checks it (data quality's readers with
 * tenant.configure too; the filters the overview's dims and measure, each 1 to 100 characters without an @; the dates
 * ended); nothing to keep in mock mode
 */
export function mockRecordFlashFile(me: Principal, read: FlashFileRead): void {
  const def = overviewOf(read.overview);
  assertAny(me, def?.key === "data_quality" ? [...REPORT, "tenant.configure"] : REPORT);
  if (!def || (read.part !== "rows" && read.part !== "breakdown") || read.rows < 0) throw new CmaDbError("CMA04", "an invalid file read");
  for (const [k, v] of Object.entries(read.filters)) {
    if ((k !== "measure" && !def.dims.includes(k)) || (k === "measure" && !def.countMeasures.includes(v)) || v.length < 1 || v.length > 100 || v.includes("@")) {
      throw new CmaDbError("CMA04", "a file record's filters are the overview's dims and measure");
    }
  }
  assertParams(todayOf(me), read.market, read.asOf, read.from, read.to);
}

export type { FlashKey };
