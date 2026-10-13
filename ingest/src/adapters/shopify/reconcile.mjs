/**
 * Shopify reconcile, backfill and the subscription check (DESIGN §2, §5; VENDOR_SETUP §3.4).
 *
 *   reconcile      per object type, the customers or orders updated in the look-back (26 hours by
 *                  default): customers(query: "updated_at:>='<since>'") and orders(query: …), sorted
 *                  by UPDATED_AT, 100 a page, ids and updatedAt only; each becomes a synthetic event
 *                  (sync:<type>:<id>:<updatedAt>) on the webhook's read-back, so an unchanged object
 *                  is read once however often a job lists it. Shopify's search matches a date at day
 *                  level for some filters, so what a page lists before the look-back is dropped here
 *   backfill       --object commerce_customer or commerce_order from intake.start_date (or --from),
 *                  created_at:>= sorted by CREATED_AT, resumable: after every page the cursor
 *                  backfill:<type> = { from, value, done } holds the last creation time listed, and a
 *                  run with the same start lists again from there. Without the scope read_all_orders
 *                  Shopify lists the orders of the last 60 days only (VENDOR_SETUP §3.2)
 *   subscriptions  the nightly check (sync_run job subscriptions_check): webhookSubscriptions of the
 *                  shop, those whose uri ends in /shopify/<connection key> are this connection's. All
 *                  seven topics there → nothing. Some missing (Shopify deletes a subscription after 8
 *                  failed deliveries over 4 hours) → created again with the address of a remaining
 *                  one, and the run's error is subscriptions_recreated (so it is seen); none left →
 *                  subscriptions_missing (run docs/ingest/shopify-subscribe.mjs: the job does not know
 *                  the public address); a create refused → subscriptions_recreate_failed
 *
 * Jobs wait for the shop's cost bucket (client.mjs) instead of failing.
 */
import { SourceError } from "../../core/http.mjs";
import { shopifyClient } from "./client.mjs";
import { OBJECT_TYPES, SUBSCRIPTION_TOPICS, idOf } from "./map.mjs";

export const RECONCILE_OBJECTS = OBJECT_TYPES;
export const BACKFILL_OBJECTS = OBJECT_TYPES;
const PER_PAGE = 100;
const LIST_COST = 3 + PER_PAGE;
const ROOT = { commerce_customer: "customers", commerce_order: "orders" };

export function listQuery(objectType, sortKey) {
  return `query CmaList($q: String!, $after: String) { ${ROOT[objectType]}(first: ${PER_PAGE}, after: $after, query: $q, sortKey: ${sortKey}) {
    nodes { id createdAt updatedAt } pageInfo { hasNextPage endCursor } } }`;
}
export const SUBSCRIPTIONS_QUERY = "query CmaSubscriptions { webhookSubscriptions(first: 100) { nodes { id topic uri } } }";
export const SUBSCRIPTION_CREATE = `mutation CmaSubscribe($topic: WebhookSubscriptionTopic!, $uri: String!) {
  webhookSubscriptionCreate(topic: $topic, webhookSubscription: { uri: $uri }) { webhookSubscription { id topic uri } userErrors { field message } } }`;

/** Every page of a listing: yields [{ node }] arrays. */
async function* pages(api, objectType, sortKey, search) {
  let after = null;
  for (let n = 0; n < 10_000; n += 1) {
    const data = await api.query(listQuery(objectType, sortKey), { q: search, after }, LIST_COST);
    const conn = data?.[ROOT[objectType]];
    const nodes = Array.isArray(conn?.nodes) ? conn.nodes : [];
    if (nodes.length) yield nodes;
    if (!conn?.pageInfo?.hasNextPage || !conn.pageInfo.endCursor) break;
    after = conn.pageInfo.endCursor;
  }
}

function iso(ms) {
  return new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
}

/** Reconcile of one object type over the look-back → process(items). */
export async function reconcile({ connection, store, budget, object, sinceMs, untilMs, process }) {
  if (!OBJECT_TYPES.includes(object)) throw new SourceError("object_not_reconciled");
  const settings = (await store.config())?.settings ?? {};
  const api = shopifyClient(connection, settings, budget);
  for await (const nodes of pages(api, object, "UPDATED_AT", `updated_at:>='${iso(sinceMs)}' AND updated_at:<='${iso(untilMs)}'`)) {
    const items = nodes.filter((n) => idOf(n?.id) && Date.parse(n.updatedAt) >= sinceMs)
      .map((n) => ({ id: idOf(n.id), version: n.updatedAt }));
    if (items.length) await process(object, items);
  }
  return undefined;
}

/** The backfill of one object type from fromMs up to untilMs (the run's start), resumable. */
export async function backfill({ connection, store, budget, object, fromMs, untilMs, process }) {
  if (!OBJECT_TYPES.includes(object)) throw new SourceError("object_not_backfilled");
  const settings = (await store.config())?.settings ?? {};
  const stream = `backfill:${object}`;
  const cur = await store.cursor(stream);
  if (cur?.from === fromMs && cur.done) return undefined;
  const start = cur?.from === fromMs && Number.isFinite(cur.value) ? Math.max(fromMs, cur.value) : fromMs;
  const api = shopifyClient(connection, settings, budget);
  let last = start;
  for await (const nodes of pages(api, object, "CREATED_AT", `created_at:>='${iso(start)}' AND created_at:<='${iso(untilMs)}'`)) {
    const items = nodes.filter((n) => idOf(n?.id)).map((n) => ({ id: idOf(n.id), version: n.updatedAt }));
    if (items.length) await process(object, items);
    const newest = Math.max(...nodes.map((n) => Date.parse(n.createdAt)).filter(Number.isFinite));
    if (Number.isFinite(newest)) last = Math.max(last, newest);
    await store.setCursor(stream, { from: fromMs, value: last, done: false });
  }
  await store.setCursor(stream, { from: fromMs, value: last, done: true });
  return undefined;
}

/**
 * The subscription check: null when the seven topics point at this connection, else an error code
 * (after recreating what it could). counts: the run's counts (fetched = subscriptions listed,
 * upserted = recreated).
 */
export async function checkSubscriptions({ connection, store, budget, counts }) {
  const settings = (await store.config())?.settings ?? {};
  const key = await store.connectionKey();
  const api = shopifyClient(connection, settings, budget);
  const data = await api.query(SUBSCRIPTIONS_QUERY, {}, 2 + 100);
  const all = Array.isArray(data?.webhookSubscriptions?.nodes) ? data.webhookSubscriptions.nodes : [];
  if (counts) counts.fetched += all.length;
  const mine = all.filter((s) => {
    try {
      return key && new URL(String(s?.uri ?? "")).pathname.replace(/\/+$/, "").endsWith(`/shopify/${key}`);
    } catch {
      return false;
    }
  });
  const present = new Set(mine.map((s) => String(s.topic)));
  const missing = SUBSCRIPTION_TOPICS.filter((t) => !present.has(t));
  if (!missing.length) return null;
  if (!mine.length) return "subscriptions_missing";
  const uri = String(mine[0].uri);
  for (const topic of missing) {
    let r;
    try {
      r = await api.query(SUBSCRIPTION_CREATE, { topic, uri }, 10);
    } catch {
      return "subscriptions_recreate_failed";
    }
    if (!r?.webhookSubscriptionCreate?.webhookSubscription?.id || (r.webhookSubscriptionCreate.userErrors ?? []).length) return "subscriptions_recreate_failed";
    if (counts) counts.upserted += 1;
  }
  return "subscriptions_recreated";
}
