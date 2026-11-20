/**
 * The Juo adapter for a store's subscriptions (addition 0008zl, brief B20; addition 0009za, brief B39 Part A) as the jobs
 * see it. Polling only and read only: Juo has no webhook topic for a failed renewal, so the server answers 404 on
 * /juo/<key> (kind poll), and nothing is ever written to Juo (the client's allow-list, client.mjs). One connection per
 * store: its account id the store's own domain (<handle>.myshopify.com, Juo's X-Tenant-ID), its token secret name the
 * store's key (ingest-juo-<handle>-key), and the tenant's commerce store of that handle configured
 * (cma.ingest_subscription_store; without one every read fails store_not_configured before a request).
 *
 * The events come in two families (read.mjs), each its own query: subscription (the events of the store's
 * subscriptions; Juo's renewal notices are never requested) and billing (chargebacks, refunds, invoice renewals, orders
 * the app could not place). A subscription is always read with its lines (canceled ones included), stored as a set per subscription.
 *
 *   pollDue, pollSubscriptions   the job ingest-poll-subscriptions (every 5 minutes): when due on
 *                         subscriptions_poll_interval_minutes (default 5; cursor juo:cadence), the events of both families
 *                         that occurred after the cursor juo:events less five minutes (without a cursor, the last 24
 *                         hours), stored as they come (an event held already is left as it is), then every subscription
 *                         those events touched (a billing event that names its subscription included) read again with its
 *                         lines and upserted; both cursors move to the run's start
 *   reconcileObjects, reconcile   the job ingest-reconcile (03:30): subscription, the full read of every subscription of
 *                         the store with its lines, upserted as the pages come, then the final step in slices
 *                         (core/slices.mjs, SLICE_SIZE ids each, cma.ingest_mark_subscriptions_missing): a subscription the
 *                         read no longer returned gets source_deleted_at; then subscription_product, the store's catalog
 *                         (every page of GET /products) as one full set (a variant the read no longer holds marked
 *                         missing). A read that returns none fails empty_snapshot instead of marking everything missing;
 *                         a read that fails before its final step marks nothing
 *   backfillObjects, backfill, dryRun   the job ingest-backfill: --object subscription and subscription_product (the same
 *                         full reads, no --from), subscription_event and billing_event [--from <date>] (one family's
 *                         events from that date to the run's start, oldest first, resumable from backfill:<object>; at
 *                         its end the poll's cursor juo:events moves to the run's start unless it stands later). Without
 *                         --from an events backfill starts at the tenant's subscriptions.history_start_date, or reads all
 *                         of the app's history when it is empty (from HISTORY_FLOOR, 1 January 2000); either may lie
 *                         before intake.start_date. A --from before a history start that is set is refused
 *                         (from_before_history_start). The dry run reads and counts and writes nothing (see dryRun)
 *   skipReason            a connection without a token secret name is not read: the jobs skip it with one log line (code
 *                         key_not_set) and no run; the backfill refuses it
 *
 * The run's counts (sync_run): fetched (events, subscriptions and products read), inserted, updated, unchanged and stale
 * (subscriptions; variants on a catalog read), upserted (inserted and updated), events_new (events stored for the first
 * time), billing_events_new, lines_new, lines_missing, variants_new, changes_observed (cma.subscription_change rows
 * written), skipped (events of another type, duplicates or unreadable, and unreadable subscriptions), duplicate_skipped
 * (the subscription family's copy of a chargeback or refund), customers_unmatched (subscriptions written whose customer
 * id the store's customers do not hold), reason_dropped (a reason left out), return_code_dropped (a chargeback's reason
 * out of the code form), instrument_unknown (an instrument type the mapping does not know, stored as other),
 * catalog_text_dropped (a title or SKU with an @ or a control character), missing_now and slice_max_ms (a full read's
 * final step). The log line adds the details (events read, kept, skipped, by Juo's type when it is a type name, else
 * "unknown"; subscriptions and lines read; the instrument types known and the names of those not known) and the
 * requests per endpoint. It names fields, types and codes, never a value, a key or an id of a customer.
 */
import { info, warn } from "../../core/log.mjs";
import { SourceError } from "../../core/http.mjs";
import { slicesOf } from "../../core/slices.mjs";
import { juoSettings, tenantIdOf } from "./client.mjs";
import { clientFor, eventsQuery } from "./read.mjs";
import {
  OBJECT_SUBSCRIPTION, OBJECT_PRODUCT, OBJECT_EVENT, OBJECT_BILLING, subscriptionItem, lineItems, productItems, eventItem, billingEventItem,
  isBillingEvent, eventSubscriptionOf, customerIdOf, eventTypeOf, TYPE_NAME,
} from "./map.mjs";

export const EVENTS_STREAM = "juo:events";
export const CADENCE_STREAM = "juo:cadence";
export const BACKFILL_EVENTS_STREAM = `backfill:${OBJECT_EVENT}`;
export const BACKFILL_BILLING_STREAM = `backfill:${OBJECT_BILLING}`;
export const OVERLAP_MS = 5 * 60_000;
/** The first poll's window, without a cursor (the backfill of events moves the cursor to its own start) */
export const FIRST_POLL_MS = 24 * 60 * 60_000;
/** All of the app's history: an events backfill without a start reads from here (Juo's stores began in 2025) */
export const HISTORY_FLOOR_MS = Date.UTC(2000, 0, 1);
/** The tenant setting that names an events backfill's start (addition 0009za) */
export const HISTORY_SETTING = "subscriptions.history_start_date";
/** The final step's slices: at most this many subscription ids a call (the database takes 5,000) */
export const SLICE_SIZE = 1000;
const SLACK_MS = 2 * 60_000;
/** The counts a run adds to sync_run's five */
export const RUN_COUNTS = ["inserted", "updated", "unchanged", "missing_now", "events_new", "customers_unmatched", "reason_dropped",
  "lines_new", "lines_missing", "variants_new", "billing_events_new", "changes_observed", "instrument_unknown", "duplicate_skipped",
  "return_code_dropped", "catalog_text_dropped"];
/** The events objects and their family and backfill cursor */
const EVENT_OBJECTS = {
  [OBJECT_EVENT]: { family: "subscription", stream: BACKFILL_EVENTS_STREAM },
  [OBJECT_BILLING]: { family: "billing", stream: BACKFILL_BILLING_STREAM },
};

/** A connection without a token secret name is not read (code key_not_set). */
export function skipReason(connection) {
  return connection?.tokenSecretName ? null : "key_not_set";
}

/** Whether the poll is due: no poll yet, or the connection's interval (less two minutes of the schedule's slack) has passed. */
export async function pollDue({ store, now = Date.now() }) {
  const s = juoSettings((await store.config())?.settings ?? {});
  const last = (await store.cursor(CADENCE_STREAM))?.at;
  return !Number.isFinite(last) || now - last >= s.intervalMinutes * 60_000 - SLACK_MS;
}

/** The detail counts a run logs next to sync_run's counts. */
export const emptyDetail = () => ({ eventsRead: 0, eventsKept: 0, eventsOtherType: 0, eventsUnreadable: 0, eventTypes: {},
  billingKept: 0, subscriptionsRead: 0, subscriptionsUnreadable: 0, linesRead: 0, linesUnreadable: 0, instrumentKnown: 0,
  instrumentUnknownTypes: {} });

/** sync_run's counts of a subscriptions run, every key written as 0 to start with. */
function startCounts(counts) {
  for (const k of RUN_COUNTS) counts[k] = Number(counts[k] ?? 0);
  return counts;
}

const bump = (o, k, n = 1) => {
  o[k] = (o[k] ?? 0) + n;
};

/**
 * What every read needs: the settings, the store's id (X-Tenant-ID; tenant_id_invalid otherwise) and the commerce
 * store of its handle (store_not_configured otherwise, before any request), and the API.
 */
async function prepare({ connection, store, budget }) {
  const settings = (await store.config())?.settings ?? {};
  const s = juoSettings(settings);
  if (s.fallbacks.length) info("settings out of range, defaults used", { connection: connection.connectionId, settings: s.fallbacks });
  tenantIdOf(connection);
  const shop = await store.subscriptionStore();
  if (!shop?.storeConnectionId) {
    warn("juo store not configured: no commerce store of the tenant has the handle of the connection's account id",
      { connection: connection.connectionId, code: "store_not_configured" });
    throw new SourceError("store_not_configured");
  }
  return { api: clientFor(connection, settings, budget), s, shop };
}

/**
 * One page of events of either family: mapped (each id once, its later copy), the kept ones stored, the counts and
 * details added. touched gathers the subscriptions of every event read, kept or not (the poll reads them again). Answers
 * the page's latest occurrence (ms).
 */
async function ingestEvents({ store, page, counts, detail, touched }) {
  const items = new Map();
  const billing = new Map();
  let latest = null;
  for (const e of page) {
    detail.eventsRead += 1;
    bump(detail.eventTypes, eventTypeOf(e));
    const sub = eventSubscriptionOf(e);
    if (sub && touched) touched.add(sub);
    const at = Date.parse(e?.occurredAt);
    if (Number.isFinite(at)) latest = Math.max(latest ?? at, at);
    if (isBillingEvent(e)) {
      const m = billingEventItem(e);
      if (!m || m.skip) detail.eventsUnreadable += 1;
      else {
        if (m.returnCodeDropped) counts.return_code_dropped += 1;
        if (m.instrumentUnknown) {
          counts.instrument_unknown += 1;
          bump(detail.instrumentUnknownTypes, m.instrumentUnknown);
        }
        billing.set(m.item.sourceId, m.item);
      }
      continue;
    }
    const m = eventItem(e);
    if (!m) detail.eventsUnreadable += 1;
    else if (m.skip === "duplicate") counts.duplicate_skipped += 1;
    else if (m.skip) detail.eventsOtherType += 1;
    else {
      if (m.reasonDropped) counts.reason_dropped += 1;
      items.set(m.item.sourceId, m.item);
    }
  }
  counts.fetched += page.length;
  counts.skipped += page.length - items.size - billing.size;
  detail.eventsKept += items.size;
  detail.billingKept += billing.size;
  if (items.size) {
    const outcomes = await store.upsertSubscriptionEvents([...items.values()]);
    counts.events_new += outcomes.inserted ?? 0;
  }
  if (billing.size) {
    const outcomes = await store.upsertBillingEvents([...billing.values()]);
    counts.billing_events_new += outcomes.inserted ?? 0;
  }
  return latest;
}

/**
 * One page of subscriptions: mapped (each id once), upserted with the run, then the lines of those not stale as a set;
 * the counts and details added. Answers the ids written.
 */
async function ingestSubscriptions({ store, page, counts, detail, runId = null }) {
  const items = new Map();
  const lines = new Map();
  for (const s of page) {
    detail.subscriptionsRead += 1;
    const item = subscriptionItem(s);
    if (!item) {
      detail.subscriptionsUnreadable += 1;
      continue;
    }
    if (item.paymentInstrumentType) detail.instrumentKnown += 1;
    if (item.instrumentUnknown) {
      counts.instrument_unknown += 1;
      bump(detail.instrumentUnknownTypes, item.instrumentUnknown);
    }
    items.set(item.sourceId, item);
    const l = lineItems(s);
    detail.linesRead += l.lines.length;
    detail.linesUnreadable += l.unreadable;
    lines.set(item.sourceId, l.lines);
  }
  counts.fetched += page.length;
  counts.skipped += page.length - items.size;
  if (!items.size) return [];
  const rows = await store.upsertSubscriptions([...items.values()], runId);
  const written = [];
  for (const r of rows) {
    if (r.outcome === "inserted" || r.outcome === "updated" || r.outcome === "unchanged") {
      counts[r.outcome] += 1;
      written.push(r.sourceId);
    } else if (r.outcome === "stale") counts.stale += 1;
    if (r.customerMatched === false && r.outcome !== "stale") counts.customers_unmatched += 1;
    counts.changes_observed += Number(r.changesObserved ?? 0);
  }
  counts.upserted = counts.inserted + counts.updated;
  // a stale read's lines are as old as the read: only the subscriptions written take their lines
  if (written.length) {
    const l = await store.upsertSubscriptionLines(written, written.flatMap((id) => lines.get(id) ?? []), runId);
    counts.lines_new += l.inserted ?? 0;
    counts.lines_missing += l.missing_now ?? 0;
    counts.changes_observed += l.changes_observed ?? 0;
  }
  return [...items.keys()];
}

/** The poll of one connection: both families' events since the cursor less five minutes, then the subscriptions they touched. */
export async function pollSubscriptions({ connection, store, budget, now = Date.now(), counts, runId = null }) {
  startCounts(counts);
  const { api } = await prepare({ connection, store, budget });
  const detail = emptyDetail();
  const cur = await store.cursor(EVENTS_STREAM);
  const since = (Number.isFinite(cur?.at) ? cur.at : now - FIRST_POLL_MS) - OVERLAP_MS;
  const touched = new Set();
  for (const family of ["subscription", "billing"]) {
    for await (const page of api.events(eventsQuery(since, null, { family }))) await ingestEvents({ store, page, counts, detail, touched });
  }
  for await (const page of api.subscriptionsById([...touched].sort())) await ingestSubscriptions({ store, page, counts, detail, runId });
  await store.setCursor(EVENTS_STREAM, { at: now });
  await store.setCursor(CADENCE_STREAM, { at: now });
  return { detail: { ...detail, touched: touched.size, since: new Date(since).toISOString() } };
}

/**
 * The full read of one connection's subscriptions with their lines (the nightly reconcile, a backfill): every page
 * upserted as it comes, then the final step in slices marks the subscriptions the read did not return. empty_snapshot
 * when it returned none.
 */
async function fullRead({ connection, store, budget, counts, runId = null }) {
  startCounts(counts);
  const { api } = await prepare({ connection, store, budget });
  const detail = emptyDetail();
  const ids = new Set();
  for await (const page of api.subscriptions()) {
    for (const id of await ingestSubscriptions({ store, page, counts, detail, runId })) ids.add(id);
  }
  if (!ids.size) {
    warn("juo full read returned no subscription: nothing marked missing", { connection: connection.connectionId, code: "empty_snapshot",
      fetched: detail.subscriptionsRead });
    throw new SourceError("empty_snapshot");
  }
  const slices = slicesOf([...ids], SLICE_SIZE);
  counts.slice_max_ms = 0;
  for (const slice of slices) {
    const t0 = performance.now();
    const marked = await store.markSubscriptionsMissing(slice.ids, slice.from, slice.before);
    counts.slice_max_ms = Math.max(counts.slice_max_ms, Math.round(performance.now() - t0));
    counts.missing_now += Number(marked?.missing_now ?? 0);
  }
  return { ...detail, slices: slices.length };
}

/** Every variant of the store's catalog: { variants (each id once), products, unreadable, textDropped }. */
async function readCatalog(api) {
  const variants = new Map();
  const out = { products: 0, unreadable: 0, textDropped: 0 };
  for await (const page of api.products()) {
    for (const p of page) {
      out.products += 1;
      const r = productItems(p);
      out.unreadable += r.unreadable;
      out.textDropped += r.textDropped;
      for (const v of r.variants) variants.set(v.variantSourceId, v);
    }
  }
  return { ...out, variants };
}

/** The catalog read of one connection (the reconcile, a backfill): the full set in one call; empty_snapshot without a variant. */
async function catalogRead({ connection, store, budget, counts }) {
  startCounts(counts);
  const { api } = await prepare({ connection, store, budget });
  const c = await readCatalog(api);
  counts.fetched += c.products;
  counts.skipped += c.unreadable;
  counts.catalog_text_dropped += c.textDropped;
  if (!c.variants.size) {
    warn("juo catalog read returned no variant: nothing marked missing", { connection: connection.connectionId, code: "empty_snapshot",
      fetched: c.products });
    throw new SourceError("empty_snapshot");
  }
  const r = await store.upsertSubscriptionProducts([...c.variants.values()]);
  for (const k of ["inserted", "updated", "unchanged", "missing_now"]) counts[k] += Number(r?.[k] ?? 0);
  counts.variants_new += Number(r?.inserted ?? 0);
  counts.upserted = counts.inserted + counts.updated;
  return { products: c.products, variants: c.variants.size, unreadable: c.unreadable, textDropped: c.textDropped };
}

/**
 * The start of an events backfill when the run names none: the tenant's subscriptions.history_start_date, or all of the
 * app's history when it is empty. A start before a history start that is set is refused (from_before_history_start).
 * Answers the start in ms.
 */
async function eventsStart(store, fromMs) {
  const set = String((await store.settings())[HISTORY_SETTING] ?? "").trim();
  const floor = set ? (await store.tenantStartOf(set)).getTime() : null;
  if (Number.isFinite(fromMs) && floor !== null && fromMs < floor) throw new SourceError("from_before_history_start");
  return Number.isFinite(fromMs) ? fromMs : floor ?? HISTORY_FLOOR_MS;
}

/**
 * The backfill of one connection's events of one family (object subscription_event or billing_event) from fromMs (null:
 * all history, HISTORY_FLOOR) to untilMs, oldest first, resumable (cursor backfill:<object> = { from, value, done }:
 * value the latest occurrence stored); a finished one with the same start reads nothing. At its end the poll's cursor
 * moves to untilMs unless it stands later, so the poll carries on where the backfill ended.
 */
async function backfillEvents({ connection, store, budget, object, fromMs, untilMs, counts }) {
  startCounts(counts);
  const { family, stream } = EVENT_OBJECTS[object];
  const from = await eventsStart(store, fromMs);
  const cur = await store.cursor(stream);
  if (cur && cur.from === from && cur.done) return emptyDetail();
  const resumeAt = cur && cur.from === from && Number.isFinite(cur.value) ? cur.value : from;
  const { api } = await prepare({ connection, store, budget });
  const detail = emptyDetail();
  for await (const page of api.events(eventsQuery(resumeAt, untilMs, { inclusive: true, family }))) {
    const latest = await ingestEvents({ store, page, counts, detail, touched: null });
    if (Number.isFinite(latest)) await store.setCursor(stream, { from, value: latest, done: false });
  }
  await store.setCursor(stream, { from, done: true });
  const poll = await store.cursor(EVENTS_STREAM);
  if (!Number.isFinite(poll?.at) || poll.at < untilMs) await store.setCursor(EVENTS_STREAM, { at: untilMs });
  return { ...detail, from: new Date(from).toISOString() };
}

export const RECONCILE_OBJECTS = [OBJECT_SUBSCRIPTION, OBJECT_PRODUCT];
export const BACKFILL_OBJECTS = [OBJECT_SUBSCRIPTION, OBJECT_PRODUCT, OBJECT_EVENT, OBJECT_BILLING];

export async function reconcile({ connection, store, budget, object, counts, runId = null }) {
  if (object === OBJECT_SUBSCRIPTION) {
    const detail = await fullRead({ connection, store, budget, counts, runId });
    info("reconcile: subscription full read", { connection: connection.connectionId, ...detail });
    return undefined;
  }
  if (object === OBJECT_PRODUCT) {
    const detail = await catalogRead({ connection, store, budget, counts });
    info("reconcile: catalog read", { connection: connection.connectionId, ...detail });
    return undefined;
  }
  throw new SourceError("object_not_reconciled");
}

export async function backfill({ connection, store, budget, object, fromMs, untilMs, counts, runId = null }) {
  if (object === OBJECT_SUBSCRIPTION) {
    const detail = await fullRead({ connection, store, budget, counts, runId });
    info("backfill: subscription full read", { connection: connection.connectionId, ...detail });
    return undefined;
  }
  if (object === OBJECT_PRODUCT) {
    const detail = await catalogRead({ connection, store, budget, counts });
    info("backfill: catalog read", { connection: connection.connectionId, ...detail });
    return undefined;
  }
  if (EVENT_OBJECTS[object]) {
    const detail = await backfillEvents({ connection, store, budget, object, fromMs, untilMs, counts });
    info(object === OBJECT_EVENT ? "backfill: subscription events" : "backfill: billing events", { connection: connection.connectionId, ...detail });
    return undefined;
  }
  throw new SourceError("object_not_backfilled");
}

/** A histogram's band of lines per subscription: 1, 2, 3, 4-5, 6+ (0 for none) */
const lineBand = (n) => (n <= 3 ? String(n) : n <= 5 ? "4-5" : "6+");

/**
 * The dry run of a backfill: the same read, nothing written (no upsert, no run, no cursor).
 *   subscription           fetched, mapped, unreadable, the statuses, the instrument types known (instrumentKnown) and by
 *                          name (instrumentTypes, Juo's type names with counts), customers without a match among the
 *                          store's customers (and subscriptions without a customer id), lines, linesUnreadable,
 *                          linesPerSubscription (current lines: 0, 1, 2, 3, 4-5, 6+), minCyclesSet and maxCyclesSet
 *                          (subscriptions whose billing policy or lines state one)
 *   subscription_product   products, variants, unreadable, textDropped, and the top 20 variants by active lines (the
 *                          subscriptions read too: lines not canceled of active subscriptions) with their SKU and titles
 *   subscription_event     (from fromMs, else the history start, to untilMs) fetched, mapped (kept), otherType,
 *                          duplicates, unreadable, the event types seen (Juo's, with counts) and kept (the CMA's), reasons
 *                          dropped, customers without a match, firstEventAt
 *   billing_event          (alike) fetched, mapped, unreadable, billingKinds, returnCodes (codes with counts),
 *                          returnCodeDropped, instrumentTypes (names), instrumentUnknown, withSubscription, firstEventAt
 */
export async function dryRun({ connection, store, budget, object, fromMs, untilMs = Date.now() }) {
  if (!BACKFILL_OBJECTS.includes(object)) throw new SourceError("object_not_backfilled");
  const from = EVENT_OBJECTS[object] ? await eventsStart(store, fromMs) : null;
  const { api, shop } = await prepare({ connection, store, budget });
  const customers = new Set();
  const unmatched = async () => {
    const held = await store.storeCustomersHeld(shop.storeConnectionId, [...customers]);
    return [...customers].filter((id) => !held.has(id)).length;
  };
  if (object === OBJECT_SUBSCRIPTION) {
    const out = { fetched: 0, mapped: 0, unreadable: 0, statuses: {}, instrumentKnown: 0, instrumentTypes: {}, withoutCustomer: 0,
      customersUnmatched: 0, lines: 0, linesUnreadable: 0, linesPerSubscription: {}, minCyclesSet: 0, maxCyclesSet: 0 };
    const seen = new Set();
    for await (const page of api.subscriptions()) {
      for (const s of page) {
        out.fetched += 1;
        const item = subscriptionItem(s);
        if (!item) {
          out.unreadable += 1;
          continue;
        }
        if (seen.has(item.sourceId)) continue;
        seen.add(item.sourceId);
        out.mapped += 1;
        bump(out.statuses, item.status);
        if (item.paymentInstrumentType) {
          out.instrumentKnown += 1;
          const name = typeof s.paymentMethod?.instrument?.type === "string" && TYPE_NAME.test(s.paymentMethod.instrument.type)
            ? s.paymentMethod.instrument.type : "unnamed";
          bump(out.instrumentTypes, name);
        }
        if (item.customerSourceId) customers.add(item.customerSourceId);
        else out.withoutCustomer += 1;
        const l = lineItems(s);
        out.lines += l.lines.length;
        out.linesUnreadable += l.unreadable;
        bump(out.linesPerSubscription, lineBand(item.lineCount ?? 0));
        if (item.minCycles !== undefined) out.minCyclesSet += 1;
        if (item.maxCycles !== undefined) out.maxCyclesSet += 1;
      }
    }
    out.customersUnmatched = await unmatched();
    return out;
  }
  if (object === OBJECT_PRODUCT) {
    const c = await readCatalog(api);
    const active = new Map();
    for await (const page of api.subscriptions()) {
      for (const s of page) {
        if (subscriptionItem(s)?.status !== "active") continue;
        for (const l of lineItems(s).lines) if (!l.canceledAt && l.variantSourceId) active.set(l.variantSourceId, (active.get(l.variantSourceId) ?? 0) + 1);
      }
    }
    // a Map counts with set and get (bump writes properties, which a Map's size and entries never see: #299's finding 1)
    const top = [...active].sort(([a, x], [b, y]) => y - x || (a < b ? -1 : 1)).slice(0, 20)
      .map(([variant, lines]) => ({ variant, lines, sku: c.variants.get(variant)?.sku ?? null, product: c.variants.get(variant)?.productTitle ?? null,
        title: c.variants.get(variant)?.variantTitle ?? null }));
    return { products: c.products, variants: c.variants.size, unreadable: c.unreadable, textDropped: c.textDropped,
      variantsOnActiveLines: active.size, variantsNotInCatalog: [...active.keys()].filter((v) => !c.variants.has(v)).length, top };
  }
  const { family } = EVENT_OBJECTS[object];
  const out = object === OBJECT_EVENT
    ? { fetched: 0, mapped: 0, otherType: 0, duplicates: 0, unreadable: 0, eventTypes: {}, kept: {}, reasonDropped: 0, customersUnmatched: 0 }
    : { fetched: 0, mapped: 0, unreadable: 0, billingKinds: {}, returnCodes: {}, returnCodeDropped: 0, instrumentTypes: {}, instrumentUnknown: 0,
      withSubscription: 0 };
  out.from = new Date(from).toISOString();
  out.firstEventAt = null;
  for await (const page of api.events(eventsQuery(from, untilMs, { inclusive: true, family }))) {
    for (const e of page) {
      out.fetched += 1;
      const at = Date.parse(e?.occurredAt);
      if (Number.isFinite(at) && (out.firstEventAt === null || at < Date.parse(out.firstEventAt))) out.firstEventAt = new Date(at).toISOString();
      if (object === OBJECT_EVENT) {
        bump(out.eventTypes, eventTypeOf(e));
        const customer = customerIdOf(e?.customerId);
        if (customer) customers.add(customer);
        const m = eventItem(e);
        if (!m) out.unreadable += 1;
        else if (m.skip === "duplicate") out.duplicates += 1;
        else if (m.skip) out.otherType += 1;
        else {
          out.mapped += 1;
          bump(out.kept, m.item.eventType);
          if (m.reasonDropped) out.reasonDropped += 1;
        }
      } else {
        const m = billingEventItem(e);
        if (!m || m.skip) {
          out.unreadable += 1;
          continue;
        }
        out.mapped += 1;
        bump(out.billingKinds, m.item.kind);
        if (m.item.returnCode) bump(out.returnCodes, m.item.returnCode);
        if (m.returnCodeDropped) out.returnCodeDropped += 1;
        if (m.item.instrumentType) bump(out.instrumentTypes, m.instrumentUnknown ?? m.item.instrumentType);
        if (m.instrumentUnknown) out.instrumentUnknown += 1;
        if (m.item.subscriptionSourceId) out.withSubscription += 1;
      }
    }
  }
  if (object === OBJECT_EVENT) out.customersUnmatched = await unmatched();
  return out;
}

export const juo = {
  name: "juo",
  kind: "poll",
  holdsRecords: false,
  rates: {},
  skipReason,
  pollDue,
  pollSubscriptions,
  reconcileObjects: RECONCILE_OBJECTS,
  reconcile,
  backfillObjects: BACKFILL_OBJECTS,
  backfill,
  /** subscription and subscription_product are always read whole: their backfill takes no --from */
  wholeObjects: [OBJECT_SUBSCRIPTION, OBJECT_PRODUCT],
  /**
   * subscription and subscription_product: all of it; subscription_event and billing_event without --from: the tenant's
   * subscriptions.history_start_date, else all of the app's history (never intake.start_date)
   */
  backfillFrom: async (object, store) => {
    if (!EVENT_OBJECTS[object]) return { allHistory: true };
    const v = String((await store.settings())[HISTORY_SETTING] ?? "").trim();
    return v || { allHistory: true };
  },
  dryRun,
};
