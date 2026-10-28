/**
 * The Juo adapter for a store's subscriptions (addition 0008zl, brief B20) as the jobs see it. Polling only and read
 * only: Juo has no webhook topic for a failed renewal, so the server answers 404 on /juo/<key> (kind poll), and nothing
 * is ever written to Juo. One connection per store: its account id the store's own domain (<handle>.myshopify.com, Juo's
 * X-Tenant-ID), its token secret name the store's key (ingest-juo-<handle>-key), and the tenant's commerce store of that
 * handle configured (cma.ingest_subscription_store; without one every read fails store_not_configured before a request).
 *
 *   pollDue, pollSubscriptions   the job ingest-poll-subscriptions (every 5 minutes): when due on
 *                         juo_poll_interval_minutes (default 5; cursor juo:cadence), the events of the store's
 *                         subscriptions that occurred after the cursor juo:events less five minutes (without a cursor,
 *                         the last 24 hours), stored as they come (an event held already is left as it is), then every
 *                         subscription those events touched read again and upserted; both cursors move to the run's start
 *   reconcileObjects, reconcile   the job ingest-reconcile (03:30): the full read of subscription, every subscription of the
 *                         store, upserted as the pages come, then the final step in slices (core/slices.mjs, SLICE_SIZE
 *                         ids each, cma.ingest_mark_subscriptions_missing): a subscription the read no longer returned
 *                         gets source_deleted_at. A read that returns none fails empty_snapshot instead of marking every
 *                         subscription missing; a read that fails before the final step marks nothing
 *   backfillObjects, backfill, dryRun   the job ingest-backfill: --object subscription [--dry-run] (the same full read,
 *                         no --from) and --object subscription_event --from <date> [--dry-run] (the events from that date
 *                         to the run's start, oldest first, resumable from backfill:subscription_event; at its end the
 *                         poll's cursor juo:events moves to the run's start unless it stands later). The dry run reads and
 *                         counts and writes nothing: fetched, mapped, the statuses, the event types seen, reasons dropped,
 *                         customers without a match among the store's customers
 *   skipReason            a connection without a token secret name is not read: the jobs skip it with one log line (code
 *                         key_not_set) and no run; the backfill refuses it
 *
 * The run's counts (sync_run): fetched (events and subscriptions read), inserted, updated, unchanged and stale
 * (subscriptions), upserted (inserted and updated), events_new (events stored for the first time), skipped (events of
 * another type or unreadable, and unreadable subscriptions), customers_unmatched (subscriptions written whose customer id
 * the store's customers do not hold), reason_dropped (a reason left out), missing_now and slice_max_ms (a full read's
 * final step). The log line adds the details (events read, kept, skipped, by Juo's type; subscriptions read; the
 * instrument types known) and the requests per endpoint. It names fields, types and codes, never a value, a key or an id
 * of a customer.
 */
import { info, warn } from "../../core/log.mjs";
import { SourceError } from "../../core/http.mjs";
import { slicesOf } from "../../core/slices.mjs";
import { juoSettings, tenantIdOf } from "./client.mjs";
import { clientFor, eventsQuery } from "./read.mjs";
import { OBJECT_SUBSCRIPTION, OBJECT_EVENT, subscriptionItem, eventItem, eventSubscriptionOf, customerIdOf } from "./map.mjs";

export const EVENTS_STREAM = "juo:events";
export const CADENCE_STREAM = "juo:cadence";
export const BACKFILL_EVENTS_STREAM = `backfill:${OBJECT_EVENT}`;
export const OVERLAP_MS = 5 * 60_000;
/** The first poll's window, without a cursor (the backfill of events moves the cursor to its own start) */
export const FIRST_POLL_MS = 24 * 60 * 60_000;
/** The final step's slices: at most this many subscription ids a call (the database takes 5,000) */
export const SLICE_SIZE = 1000;
const SLACK_MS = 2 * 60_000;
/** The counts a run adds to sync_run's five */
export const RUN_COUNTS = ["inserted", "updated", "unchanged", "missing_now", "events_new", "customers_unmatched", "reason_dropped"];

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
  subscriptionsRead: 0, subscriptionsUnreadable: 0, instrumentKnown: 0 });

/** sync_run's counts of a subscriptions run, every key written as 0 to start with. */
function startCounts(counts) {
  for (const k of RUN_COUNTS) counts[k] = Number(counts[k] ?? 0);
  return counts;
}

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
 * One page of events: mapped (each id once, its later copy), the kept ones stored, the counts and details added.
 * touched gathers the subscriptions of every event read, kept or not (the poll reads them again). Answers the page's
 * latest occurrence (ms).
 */
async function ingestEvents({ store, page, counts, detail, touched }) {
  const items = new Map();
  let latest = null;
  for (const e of page) {
    detail.eventsRead += 1;
    const juoType = typeof e?.type === "string" ? e.type.slice(0, 60) : "unknown";
    detail.eventTypes[juoType] = (detail.eventTypes[juoType] ?? 0) + 1;
    const sub = eventSubscriptionOf(e);
    if (sub && touched) touched.add(sub);
    const at = Date.parse(e?.occurredAt);
    if (Number.isFinite(at)) latest = Math.max(latest ?? at, at);
    const m = eventItem(e);
    if (!m) detail.eventsUnreadable += 1;
    else if (m.skip) detail.eventsOtherType += 1;
    else {
      if (m.reasonDropped) counts.reason_dropped += 1;
      items.set(m.item.sourceId, m.item);
    }
  }
  counts.fetched += page.length;
  counts.skipped += page.length - items.size;
  detail.eventsKept += items.size;
  if (items.size) {
    const outcomes = await store.upsertSubscriptionEvents([...items.values()]);
    counts.events_new += outcomes.inserted ?? 0;
  }
  return latest;
}

/** One page of subscriptions: mapped (each id once), upserted, the counts and details added; answers the ids written. */
async function ingestSubscriptions({ store, page, counts, detail }) {
  const items = new Map();
  for (const s of page) {
    detail.subscriptionsRead += 1;
    const item = subscriptionItem(s);
    if (!item) {
      detail.subscriptionsUnreadable += 1;
      continue;
    }
    if (item.paymentInstrumentType) detail.instrumentKnown += 1;
    items.set(item.sourceId, item);
  }
  counts.fetched += page.length;
  counts.skipped += page.length - items.size;
  if (!items.size) return [];
  const rows = await store.upsertSubscriptions([...items.values()]);
  for (const r of rows) {
    if (r.outcome === "inserted" || r.outcome === "updated" || r.outcome === "unchanged") counts[r.outcome] += 1;
    else if (r.outcome === "stale") counts.stale += 1;
    if (r.customerMatched === false && r.outcome !== "stale") counts.customers_unmatched += 1;
  }
  counts.upserted = counts.inserted + counts.updated;
  return [...items.keys()];
}

/** The poll of one connection: the events since the cursor less five minutes, then the subscriptions they touched. */
export async function pollSubscriptions({ connection, store, budget, now = Date.now(), counts }) {
  startCounts(counts);
  const { api } = await prepare({ connection, store, budget });
  const detail = emptyDetail();
  const cur = await store.cursor(EVENTS_STREAM);
  const since = (Number.isFinite(cur?.at) ? cur.at : now - FIRST_POLL_MS) - OVERLAP_MS;
  const touched = new Set();
  for await (const page of api.events(eventsQuery(since))) await ingestEvents({ store, page, counts, detail, touched });
  for await (const page of api.subscriptionsById([...touched].sort())) await ingestSubscriptions({ store, page, counts, detail });
  await store.setCursor(EVENTS_STREAM, { at: now });
  await store.setCursor(CADENCE_STREAM, { at: now });
  return { detail: { ...detail, touched: touched.size, since: new Date(since).toISOString() } };
}

/**
 * The full read of one connection's subscriptions (the nightly reconcile, a backfill): every page upserted as it comes,
 * then the final step in slices marks the subscriptions the read did not return. empty_snapshot when it returned none.
 */
async function fullRead({ connection, store, budget, counts }) {
  startCounts(counts);
  const { api } = await prepare({ connection, store, budget });
  const detail = emptyDetail();
  const ids = new Set();
  for await (const page of api.subscriptions()) {
    for (const id of await ingestSubscriptions({ store, page, counts, detail })) ids.add(id);
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

/**
 * The backfill of one connection's events from fromMs to untilMs, oldest first, resumable (cursor backfill:subscription_event
 * = { from, value, done }: value the latest occurrence stored); a finished one with the same start reads nothing. At its
 * end the poll's cursor moves to untilMs unless it stands later, so the poll carries on where the backfill ended.
 */
async function backfillEvents({ connection, store, budget, fromMs, untilMs, counts }) {
  startCounts(counts);
  const from = Number.isFinite(fromMs) ? fromMs : null;
  if (from === null) throw new SourceError("from_not_set");
  const cur = await store.cursor(BACKFILL_EVENTS_STREAM);
  if (cur && cur.from === from && cur.done) return emptyDetail();
  const resumeAt = cur && cur.from === from && Number.isFinite(cur.value) ? cur.value : from;
  const { api } = await prepare({ connection, store, budget });
  const detail = emptyDetail();
  for await (const page of api.events(eventsQuery(resumeAt, untilMs, { inclusive: true }))) {
    const latest = await ingestEvents({ store, page, counts, detail, touched: null });
    if (Number.isFinite(latest)) await store.setCursor(BACKFILL_EVENTS_STREAM, { from, value: latest, done: false });
  }
  await store.setCursor(BACKFILL_EVENTS_STREAM, { from, done: true });
  const poll = await store.cursor(EVENTS_STREAM);
  if (!Number.isFinite(poll?.at) || poll.at < untilMs) await store.setCursor(EVENTS_STREAM, { at: untilMs });
  return detail;
}

export const RECONCILE_OBJECTS = [OBJECT_SUBSCRIPTION];
export const BACKFILL_OBJECTS = [OBJECT_SUBSCRIPTION, OBJECT_EVENT];

export async function reconcile({ connection, store, budget, object, counts }) {
  if (object !== OBJECT_SUBSCRIPTION) throw new SourceError("object_not_reconciled");
  const detail = await fullRead({ connection, store, budget, counts });
  info("reconcile: subscriptions", { connection: connection.connectionId, ...detail });
  return undefined;
}

export async function backfill({ connection, store, budget, object, fromMs, untilMs, counts }) {
  if (object === OBJECT_SUBSCRIPTION) {
    const detail = await fullRead({ connection, store, budget, counts });
    info("backfill: subscriptions", { connection: connection.connectionId, ...detail });
    return undefined;
  }
  if (object === OBJECT_EVENT) {
    const detail = await backfillEvents({ connection, store, budget, fromMs, untilMs, counts });
    info("backfill: subscription events", { connection: connection.connectionId, ...detail });
    return undefined;
  }
  throw new SourceError("object_not_backfilled");
}

/**
 * The dry run of a backfill: the same read, nothing written (no upsert, no run, no cursor). subscription: fetched,
 * mapped, unreadable, the statuses, the instrument types known, customers without a match among the store's customers
 * (and subscriptions without a customer id). subscription_event (from fromMs to untilMs): fetched, mapped (kept),
 * otherType, unreadable, the event types seen (Juo's, with counts) and kept (the CMA's), reasons dropped, customers
 * without a match.
 */
export async function dryRun({ connection, store, budget, object, fromMs, untilMs = Date.now() }) {
  if (object !== OBJECT_SUBSCRIPTION && object !== OBJECT_EVENT) throw new SourceError("object_not_backfilled");
  const { api, shop } = await prepare({ connection, store, budget });
  const customers = new Set();
  if (object === OBJECT_SUBSCRIPTION) {
    const out = { fetched: 0, mapped: 0, unreadable: 0, statuses: {}, instrumentKnown: 0, withoutCustomer: 0, customersUnmatched: 0 };
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
        out.statuses[item.status] = (out.statuses[item.status] ?? 0) + 1;
        if (item.paymentInstrumentType) out.instrumentKnown += 1;
        if (item.customerSourceId) customers.add(item.customerSourceId);
        else out.withoutCustomer += 1;
      }
    }
    const held = await store.storeCustomersHeld(shop.storeConnectionId, [...customers]);
    out.customersUnmatched = [...customers].filter((id) => !held.has(id)).length;
    return out;
  }
  if (!Number.isFinite(fromMs)) throw new SourceError("from_not_set");
  const out = { fetched: 0, mapped: 0, otherType: 0, unreadable: 0, eventTypes: {}, kept: {}, reasonDropped: 0, customersUnmatched: 0,
    from: new Date(fromMs).toISOString() };
  for await (const page of api.events(eventsQuery(fromMs, untilMs, { inclusive: true }))) {
    for (const e of page) {
      out.fetched += 1;
      const juoType = typeof e?.type === "string" ? e.type.slice(0, 60) : "unknown";
      out.eventTypes[juoType] = (out.eventTypes[juoType] ?? 0) + 1;
      const customer = customerIdOf(e?.customerId);
      if (customer) customers.add(customer);
      const m = eventItem(e);
      if (!m) out.unreadable += 1;
      else if (m.skip) out.otherType += 1;
      else {
        out.mapped += 1;
        out.kept[m.item.eventType] = (out.kept[m.item.eventType] ?? 0) + 1;
        if (m.reasonDropped) out.reasonDropped += 1;
      }
    }
  }
  const held = await store.storeCustomersHeld(shop.storeConnectionId, [...customers]);
  out.customersUnmatched = [...customers].filter((id) => !held.has(id)).length;
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
  /** subscription is always read whole: its backfill takes no --from */
  wholeObjects: [OBJECT_SUBSCRIPTION],
  /** subscription: all of it; subscription_event: --from, else intake.start_date (the runner's default) */
  backfillFrom: async (object) => (object === OBJECT_SUBSCRIPTION ? { allHistory: true } : null),
  dryRun,
};
