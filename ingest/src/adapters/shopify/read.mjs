/**
 * Shopify read-back (DESIGN §2, §4.3; additions 0008g and 0008h): the customers and orders named by
 * claimed events are read from the store's Admin GraphQL API (client.mjs) and turned into units for
 * the core to write, with the customer's CRM contact kept in the CMA (nothing is written to the CRM).
 *
 *   deletions  customers/delete and orders/delete: no read; the customer or order is marked deleted at
 *              the event's time (its hash cleared, 0008g); a deleted customer's contact link is cleared
 *   orders     nodes(ids) five at a time: the fields of DESIGN §4.3, the first ten line items (the
 *              rest paged a hundred at a time, at most 500), the visit that brought the order
 *              (landing page and referrer reduced to host, path and UTM), the app and source name
 *              (renewals), and the order's customer with the customer's own fields; then the prior
 *              order count per order, 25 ordersCount aliases a call (map.mjs priorCountOf)
 *   customers  nodes(ids) fifty at a time, unless an order of this batch already brought the customer
 *   the phone  the order's phone, else its customer's (the protected field Phone; null when the store
 *              withholds it, and nothing fails), hashed with the tenant's pepper and the store's market
 *              as the default region (the hash of calls, DESIGN §6.3), then dropped
 *   the match  every customer read (on its own or with an order) is matched to its CRM contact once
 *              per batch (match.mjs): the link set when exactly one contact answers, cleared when none
 *              or several do, left when the CRM still holds the linked contact
 *
 * Every call is paid from the shop's cost bucket. In a webhook the read never waits for points: what
 * the bucket or the CRM's search pace cannot pay now fails with throttled or paced and the sweep reads
 * it a minute later (a renewal run's burst of orders is answered at once and read by the sweep). After
 * a source error the rest of the batch is not tried: its events fail with the same code. A customer or
 * order the store no longer has (a null node) is ignored.
 */
import { getSecret } from "../../core/secrets.mjs";
import { SourceError } from "../../core/http.mjs";
import { shopifyClient, clientIdOf } from "./client.mjs";
import { OBJECT_TYPES, gid, idOf, customerFromNode, orderFromNode, priorCountOf } from "./map.mjs";
import { crmOf, matchCustomers } from "./match.mjs";

const ORDERS_PER_CALL = 5;
const CUSTOMERS_PER_CALL = 50;
const COUNTS_PER_CALL = 25;
const FIRST_LINES = 10;
const LINES_PER_PAGE = 100;
const MAX_LINES = 500;
// Cost estimates per call from Shopify's cost rules (an object 1, a connection 2 plus its size times
// a node); every answer's throttleStatus corrects the bucket
const COST = { order: 80, customer: 4, count: 1, lines: 2 + 5 * LINES_PER_PAGE };

const MONEY = "shopMoney { amount currencyCode }";
const VISIT = "landingPage referrerUrl utmParameters { source medium campaign term content }";
export const CUSTOMER_FIELDS = `id state locale numberOfOrders amountSpent { amount currencyCode } createdAt updatedAt
  defaultEmailAddress { emailAddress } defaultPhoneNumber { phoneNumber }`;
export const LINE_FIELDS = `id sku quantity product { id } variant { id } originalUnitPriceSet { ${MONEY} }`;
export const ORDER_FIELDS = `id name createdAt processedAt updatedAt cancelledAt cancelReason test currencyCode phone
  sourceName app { id } tags displayFinancialStatus displayFulfillmentStatus
  totalPriceSet { ${MONEY} } subtotalPriceSet { ${MONEY} } totalTaxSet { ${MONEY} } totalDiscountsSet { ${MONEY} } totalRefundedSet { ${MONEY} }
  customerJourneySummary { firstVisit { ${VISIT} } lastVisit { ${VISIT} } }
  customer { ${CUSTOMER_FIELDS} }
  lineItems(first: ${FIRST_LINES}) { nodes { ${LINE_FIELDS} } pageInfo { hasNextPage endCursor } }`;
export const ORDERS_QUERY = `query CmaOrders($ids: [ID!]!) { nodes(ids: $ids) { ... on Order { ${ORDER_FIELDS} } } }`;
export const CUSTOMERS_QUERY = `query CmaCustomers($ids: [ID!]!) { nodes(ids: $ids) { ... on Customer { ${CUSTOMER_FIELDS} } } }`;
export const LINES_QUERY = `query CmaOrderLines($id: ID!, $after: String) { node(id: $id) { ... on Order {
  lineItems(first: ${LINES_PER_PAGE}, after: $after) { nodes { ${LINE_FIELDS} } pageInfo { hasNextPage endCursor } } } } }`;

/** One query with an ordersCount alias per search string: c0, c1, … */
export function countsQuery(n) {
  const vars = Array.from({ length: n }, (_, i) => `$q${i}: String!`).join(", ");
  const fields = Array.from({ length: n }, (_, i) => `c${i}: ordersCount(query: $q${i}) { count precision }`).join(" ");
  return `query CmaPriorCounts(${vars}) { ${fields} }`;
}

/** The search for the orders a customer placed at or after an instant (this one included). */
export function atOrAfterSearch(customerId, createdAt) {
  return `customer_id:${customerId} AND created_at:>='${createdAt}'`;
}

function unit(events, status, error = null, writes = {}) {
  return { eventIds: events.map((e) => e.eventId), status, error, writes };
}

function chunks(list, size) {
  const out = [];
  for (let i = 0; i < list.length; i += size) out.push(list.slice(i, i + size));
  return out;
}

/** Events grouped by object; the newest event (by occurrence) decides whether it is read or deleted. */
function groupEvents(events) {
  const groups = new Map();
  for (const e of events) {
    const k = `${e.objectType}:${e.objectId}`;
    if (!groups.has(k)) groups.set(k, { objectType: e.objectType, objectId: e.objectId, events: [] });
    groups.get(k).events.push(e);
  }
  for (const g of groups.values()) {
    g.events.sort((a, b) => String(a.occurredAt).localeCompare(String(b.occurredAt)));
    g.latest = g.events.at(-1);
  }
  return [...groups.values()];
}

function codeOf(err) {
  return err instanceof SourceError ? err.code : typeof err?.code === "string" && /^[a-z][a-z0-9_]{0,59}$/.test(err.code) ? err.code : "readback_error";
}

/** The read-back of claimed events → units. */
export async function readBack({ connection, config, events, store, budget }) {
  const units = [];
  const toRead = { commerce_order: [], commerce_customer: [] };
  for (const g of groupEvents(events)) {
    if (!OBJECT_TYPES.includes(g.objectType) || !idOf(g.objectId)) {
      units.push(unit(g.events, "ignored"));
    } else if (g.latest.kind === "deleted") {
      const item = { sourceId: g.objectId, deletedAt: g.latest.occurredAt };
      units.push(unit(g.events, "processed", null, g.objectType === "commerce_order" ? { commerceOrders: [item] }
        : { commerceCustomers: [item], contactLinks: [{ customerId: g.objectId, crmConnectionId: null, contactId: null }] }));
    } else {
      toRead[g.objectType].push(g);
    }
  }
  const pending = [...toRead.commerce_order, ...toRead.commerce_customer];
  if (!pending.length) return units;
  const failAll = (code) => [...units, ...pending.map((g) => unit(g.events, "failed", code))];

  const settings = config?.settings ?? {};
  const storeRow = config?.store ?? null;
  if (!storeRow) return failAll("store_not_configured");
  let api;
  try {
    clientIdOf(settings);
    api = shopifyClient(connection, settings, budget);
  } catch (err) {
    return failAll(codeOf(err));
  }
  let pepper;
  try {
    pepper = await getSecret(`ingest-hash-pepper-${await store.tenantSlug()}`);
  } catch {
    return failAll("pepper_unavailable");
  }

  const failed = new Map(); // group → code
  let stopped = null; // after a source error the rest of the batch is not tried
  const fail = (groups, code) => { for (const g of groups) if (!failed.has(g)) failed.set(g, code); };

  // Orders, with their customers
  const orders = new Map(); // order id → node (null: the store does not have it)
  for (const part of chunks(toRead.commerce_order, ORDERS_PER_CALL)) {
    if (stopped) {
      fail(part, stopped);
      continue;
    }
    try {
      const data = await api.query(ORDERS_QUERY, { ids: part.map((g) => gid("commerce_order", g.objectId)) }, COST.order * part.length);
      const nodes = Array.isArray(data?.nodes) ? data.nodes : [];
      part.forEach((g, i) => orders.set(g.objectId, nodes[i] && idOf(nodes[i].id) === g.objectId ? nodes[i] : null));
    } catch (err) {
      stopped = codeOf(err);
      fail(part, stopped);
    }
  }

  // The prior order count of every order read that has a customer
  const prior = new Map(); // order id → { prior, exact }
  const counted = toRead.commerce_order.filter((g) => !failed.has(g) && orders.get(g.objectId)?.customer?.id);
  for (const part of chunks(counted, COUNTS_PER_CALL)) {
    if (stopped) {
      fail(part, stopped);
      continue;
    }
    const vars = Object.fromEntries(part.map((g, i) => {
      const o = orders.get(g.objectId);
      return [`q${i}`, atOrAfterSearch(idOf(o.customer.id), o.createdAt)];
    }));
    try {
      const data = await api.query(countsQuery(part.length), vars, 1 + COST.count * part.length);
      part.forEach((g, i) => prior.set(g.objectId, priorCountOf(orders.get(g.objectId).customer.numberOfOrders, data?.[`c${i}`])));
    } catch (err) {
      stopped = codeOf(err);
      fail(part, stopped);
    }
  }

  // Lines beyond the first page
  const lines = new Map(); // order id → every line node
  for (const g of toRead.commerce_order) {
    const o = orders.get(g.objectId);
    if (failed.has(g) || !o) continue;
    const all = [...(o.lineItems?.nodes ?? [])];
    let info = o.lineItems?.pageInfo;
    try {
      while (info?.hasNextPage && all.length < MAX_LINES) {
        if (stopped) throw new SourceError(stopped);
        const data = await api.query(LINES_QUERY, { id: gid("commerce_order", g.objectId), after: info.endCursor }, COST.lines);
        const page = data?.node?.lineItems;
        all.push(...(page?.nodes ?? []));
        info = page?.pageInfo;
      }
      lines.set(g.objectId, all.slice(0, MAX_LINES));
    } catch (err) {
      stopped = stopped ?? codeOf(err);
      fail([g], codeOf(err));
    }
  }

  // Customers not already brought by an order of this batch
  const customers = new Map(); // customer id → node (null: the store does not have it)
  for (const g of toRead.commerce_order) {
    const c = orders.get(g.objectId)?.customer;
    if (!failed.has(g) && idOf(c?.id)) customers.set(idOf(c.id), c);
  }
  const customerGroups = toRead.commerce_customer.filter((g) => !customers.has(g.objectId));
  for (const part of chunks(customerGroups, CUSTOMERS_PER_CALL)) {
    if (stopped) {
      fail(part, stopped);
      continue;
    }
    try {
      const data = await api.query(CUSTOMERS_QUERY, { ids: part.map((g) => gid("commerce_customer", g.objectId)) }, COST.customer * part.length);
      const nodes = Array.isArray(data?.nodes) ? data.nodes : [];
      part.forEach((g, i) => customers.set(g.objectId, nodes[i] && idOf(nodes[i].id) === g.objectId ? nodes[i] : null));
    } catch (err) {
      stopped = codeOf(err);
      fail(part, stopped);
    }
  }

  // The match, once per customer of the batch: the links checked in one read, then each customer
  const customerOf = (g) => (g.objectType === "commerce_order" ? idOf(orders.get(g.objectId)?.customer?.id) : g.objectId);
  const toMatch = new Map(); // customer id → node
  for (const g of pending) {
    const cid = customerOf(g);
    const node = cid ? customers.get(cid) : null;
    if (!failed.has(g) && node) toMatch.set(cid, node);
  }
  let matches = new Map(); // customer id → { outcome, link }
  let matchError = null;
  let gone = 0;
  if (toMatch.size) {
    try {
      const side = await crmOf(store, settings, connection.adapter);
      ({ matches, gone } = await matchCustomers({ connection, store, side, nodes: toMatch, budget }));
    } catch (err) {
      matchError = `crm_${codeOf(err)}`.slice(0, 60);
    }
  }

  // The units
  const region = storeRow.market ?? null;
  const tallied = new Set();
  for (const g of pending) {
    if (failed.has(g)) {
      units.push(unit(g.events, "failed", failed.get(g)));
      continue;
    }
    const cid = customerOf(g);
    const node = g.objectType === "commerce_order" ? orders.get(g.objectId) : customers.get(g.objectId);
    if (!node) {
      units.push(unit(g.events, "ignored"));
      continue;
    }
    const m = cid ? matches.get(cid) : null;
    // the batch's own reads failed (the CMA's links or the CRM side), or this customer's lookup did
    if ((cid && toMatch.has(cid) && matchError) || m?.outcome === "error") {
      units.push(unit(g.events, "failed", matchError ?? `crm_${m.code}`.slice(0, 60)));
      continue;
    }
    const writes = {};
    const customerNode = cid ? customers.get(cid) : null;
    const customerItem = customerNode ? customerFromNode(customerNode, { pepper, region }) : null;
    if (customerItem) writes.commerceCustomers = [customerItem];
    if (g.objectType === "commerce_order") {
      const item = orderFromNode(node, { pepper, region, prior: prior.get(g.objectId), lines: lines.get(g.objectId) ?? null });
      if (!item) {
        units.push(unit(g.events, "failed", "bad_order"));
        continue;
      }
      writes.commerceOrders = [item];
    } else if (!customerItem) {
      units.push(unit(g.events, "failed", "bad_customer"));
      continue;
    }
    if (m) {
      if (!tallied.has(cid)) {
        writes.tally = { [`match_${m.outcome}`]: 1 };
        if (m.link) writes.contactLinks = [{ customerId: cid, ...m.link }];
      }
      tallied.add(cid);
    }
    units.push(unit(g.events, "processed", null, writes));
  }
  if (gone && units.length) {
    const first = units.find((u) => u.status === "processed" && u.writes?.tally);
    if (first) first.writes.tally.match_contact_gone = gone;
  }
  pepper = null;
  return units;
}
