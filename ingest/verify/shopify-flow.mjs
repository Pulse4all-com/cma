/**
 * Verifier: the Shopify adapter and the outbox worker end to end (brief B10), against a local
 * PostgreSQL with db/00…57 and a fake Shopify Admin API (token grant and GraphQL, with a cost bucket)
 * and a fake HubSpot (contact search, batch read and batch update). Everything is invented: tenants,
 * shops, ids, secrets, emails (example.com), names, addresses and numbers in the +44 20 0000 xxxx range.
 *
 *   CMA_DB_HOST=/tmp CMA_DB_PORT=5432 CMA_DB_NAME=cma CMA_DB_USER=cma-ingest@local.iam \
 *   INGEST_FLOW_ADMIN_USER=martin@pulse4all.com node verify/shopify-flow.mjs [--provoke]
 *
 * Logins as in verify/flow.mjs. Two throwaway tenants per run (shopify-<run>-one, -two); the service
 * and the jobs run in this process; at the end this run's connections are set inactive.
 *
 * Proves: the route (unknown key, another adapter's key, a missing, malformed or wrong HMAC, a
 * tampered body, another tenant's secret: 404 or 401, nothing written, nothing asked of Shopify);
 * another shop's delivery and an unhandled topic ignored without a read; a duplicate delivery written
 * once; a customer read back with its keyed phone hash (the store's market as default region) and
 * matched to its HubSpot contact by email (one search), written back through the outbox; orders first,
 * repeat and renewal (the renewal setting) with their prior count, lines past the first page, the
 * landing page reduced to host, path and UTM, the order's phone hashed before the customer's; an order
 * the search does not hold yet written as unknown and corrected by its next read; a guest order;
 * cancellation and deletion; a customer known by its contact refs or an earlier write-back matched
 * without a search; Email and Phone withheld (null, nothing fails, the match by the ref properties);
 * no contact and two contacts counted, nothing written; the token minted once per shop, again when it
 * nears its expiry; a store without its row refused for the sweep; the outbox job: if_empty keeps an
 * agent's value, slot fills 1 then 2 and stops when both are taken, the totals only with slot 1,
 * always writes only a difference, a field disabled after the enqueue never written, only configured
 * properties read and written, a 429 failing with backoff and then sent, a contact gone failing; a
 * burst of 200 order deliveries answered within Shopify's five seconds, the rest read by the sweep
 * within the cost bucket; reconcile (a change the webhooks missed), the subscription check (a deleted
 * subscription recreated, none left); the backfill resuming after a failure; tenant isolation; and no
 * email, phone number, name, address, note, token or secret in the database rows or the logs.
 */
import http from "node:http";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { createHmac, randomBytes, randomUUID } from "node:crypto";
import pg from "pg";
import { expect, verdict, PROVOKE } from "./lib.mjs";

console.log(`verify/shopify-flow.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

for (const v of ["CMA_DB_HOST", "CMA_DB_USER"]) {
  if (!process.env[v]) {
    console.error(`${v} is required (a local PostgreSQL with db/00…57; see the header)`);
    process.exit(2);
  }
}
const ADMIN = process.env.INGEST_FLOW_ADMIN_USER ?? "martin@pulse4all.com";
const RUN = randomBytes(4).toString("hex");
const SLUG1 = `shopify-${RUN}-one`;
const SLUG2 = `shopify-${RUN}-two`;
const SHOP_A = `flow-${RUN}-a.myshopify.com`;
const SHOP_N = `flow-${RUN}-n.myshopify.com`; // a connection without its store row
const SHOP_X = `flow-${RUN}-x.myshopify.com`; // tenant two
const HANDLE_A = `flow-${RUN}-a`;
const SECRET_A = "fixture-shopify-client-secret-a-0001";
const SECRET_X = "fixture-shopify-client-secret-x-0002";
const CLIENT_A = "fixtureclientida0001";
const CLIENT_X = "fixtureclientidx0002";
const HS_TOKEN = "fixture-hubspot-token-0001";
const PEPPER1 = "fixture-pepper-shopify-one-000000";
const PEPPER2 = "fixture-pepper-shopify-two-000000";
const H = (pepper, e164) => createHmac("sha256", pepper).update(e164).digest("hex");

// ---- Secrets, as files (INGEST_SECRETS_DIR) ------------------------------------------------------
const secretsDir = mkdtempSync(path.join(tmpdir(), "shopify-flow-"));
const putSecret = (name, value) => writeFileSync(path.join(secretsDir, name), value);
putSecret(`ingest-shopify-${RUN}-a-signing`, SECRET_A);
putSecret(`ingest-shopify-${RUN}-x-signing`, SECRET_X);
putSecret(`ingest-hubspot-${RUN}-token`, HS_TOKEN);
putSecret(`ingest-hash-pepper-${SLUG1}`, PEPPER1);
putSecret(`ingest-hash-pepper-${SLUG2}`, PEPPER2);

// ---- Invented people ----------------------------------------------------------------------------
// Shopify customer ids; their emails and numbers (never stored); the HubSpot contacts they match
const C = { c1: "7100000001", c2: "7100000002", c3: "7100000003", c4: "7100000004", c5: "7100000005", c6: "7100000006", c7: "7100000007", c8: "7100000008" };
const EMAIL = { c1: "Test1@Example.com", c2: "test2@example.com", c3: "withheld@example.com", c4: "nobody@example.com", c5: "twice@example.com", c6: "full@example.com", c7: "known@example.com", c8: "later@example.com" };
const PHONE = { c1: "+44 20 0000 0101", c2: "+44 20 0000 0102", c3: "+44 20 0000 0103", c4: "+44 20 0000 0104", c5: "+44 20 0000 0105", c6: "+44 20 0000 0106", c7: "+44 20 0000 0107", c8: "+44 20 0000 0108" };
const ORDER_PHONE = "020 0000 0201"; // national format, GB: the order's own phone
const GUEST_PHONE = "020 0000 0202";
const NAME = "Invented Customer";
const STREET = "1 Invented Street";
const NOTE = "free text that must not be stored";

// ---- The fake Shopify and HubSpot -----------------------------------------------------------------
const nowIso = (offsetS = 0) => new Date(Date.now() + offsetS * 1000).toISOString();
const fake = {
  requests: [], mints: {}, tokens: new Map(), expiresIn: 86399, throttled: 0, gqlDown: false, listFailAfter: null,
  bucket: {}, restore: 2000, max: 1000,
  withhold: { email: false, phone: false }, countLag: new Set(),
  shops: { [SHOP_A]: { client: CLIENT_A, secret: SECRET_A }, [SHOP_N]: { client: CLIENT_A, secret: SECRET_A }, [SHOP_X]: { client: CLIENT_X, secret: SECRET_X } },
  customers: {}, orders: {}, subscriptions: {},
  hs: { contacts: {}, searches: [], reads: [], updates: [], update429: false },
};
const shopOf = (o) => o.shop ?? SHOP_A;
function addCustomer(key, o = {}) {
  const id = C[key];
  fake.customers[id] = { id, shop: SHOP_A, state: "ENABLED", locale: "en-GB", email: EMAIL[key], phone: PHONE[key], createdAt: nowIso(-86400), updatedAt: nowIso(-60), ...o };
  return id;
}
let orderSeq = 0;
function addOrder(id, o = {}) {
  orderSeq += 1;
  const lines = o.lineCount ?? 2;
  fake.orders[id] = {
    id, shop: SHOP_A, name: `#F${orderSeq}`, createdAt: nowIso(-3600 + orderSeq), updatedAt: nowIso(-3600 + orderSeq), processedAt: nowIso(-3600 + orderSeq),
    cancelledAt: null, cancelReason: null, test: false, currencyCode: "GBP", phone: null, sourceName: "web", appId: "580111",
    tags: ["aed", "aed"], total: "120.00", customerId: null,
    landingPage: "https://shop.example.com/products/aed?utm_source=google&utm_medium=cpc&gclid=abc&email=someone%40example.com",
    referrerUrl: "https://www.google.com/search?q=aed+price", utm: { source: "google", medium: "cpc", campaign: "autumn", term: null, content: null },
    lines: Array.from({ length: lines }, (_, i) => ({ id: `${id}${String(i + 1).padStart(2, "0")}`, sku: `SKU-${i + 1}`, quantity: 1, product: "8000000001", variant: `8100000${i + 1}`, price: "60.00" })),
    ...o,
  };
  return id;
}
const gidOf = (type, id) => `gid://shopify/${type}/${id}`;
function customerNode(c) {
  if (!c) return null;
  const orders = Object.values(fake.orders).filter((o) => o.customerId === c.id && !o.deleted);
  return {
    id: gidOf("Customer", c.id), state: c.state, locale: c.locale, numberOfOrders: String(c.numberOfOrders ?? orders.length),
    amountSpent: { amount: orders.reduce((s, o) => s + Number(o.total), 0).toFixed(2), currencyCode: "GBP" },
    createdAt: c.createdAt, updatedAt: c.updatedAt,
    defaultEmailAddress: fake.withhold.email ? null : { emailAddress: c.email },
    defaultPhoneNumber: fake.withhold.phone || !c.phone ? null : { phoneNumber: c.phone },
    firstName: "Invented", lastName: "Customer", defaultAddress: { address1: STREET },
  };
}
function orderNode(o, first = 10) {
  if (!o || o.deleted) return null;
  const lineNode = (l) => ({ id: gidOf("LineItem", l.id), sku: l.sku, quantity: l.quantity, product: { id: gidOf("Product", l.product) }, variant: { id: gidOf("ProductVariant", l.variant) },
    originalUnitPriceSet: { shopMoney: { amount: l.price, currencyCode: "GBP" } }, name: "Invented product" });
  const money = (a) => ({ shopMoney: { amount: a, currencyCode: "GBP" } });
  return {
    id: gidOf("Order", o.id), name: o.name, createdAt: o.createdAt, processedAt: o.processedAt, updatedAt: o.updatedAt, cancelledAt: o.cancelledAt, cancelReason: o.cancelReason,
    test: o.test, currencyCode: o.currencyCode, phone: fake.withhold.phone ? null : o.phone, email: fake.withhold.email ? null : "order@example.com",
    sourceName: o.sourceName, app: o.appId ? { id: gidOf("App", o.appId) } : null, tags: o.tags,
    displayFinancialStatus: "PAID", displayFulfillmentStatus: "UNFULFILLED",
    totalPriceSet: money(o.total), subtotalPriceSet: money("100.00"), totalTaxSet: money("20.00"), totalDiscountsSet: money("0.00"), totalRefundedSet: money("0.00"),
    customerJourneySummary: { firstVisit: { landingPage: o.landingPage, referrerUrl: o.referrerUrl, utmParameters: o.utm }, lastVisit: null },
    customer: o.customerId ? customerNode(fake.customers[o.customerId]) : null,
    lineItems: { nodes: o.lines.slice(0, first).map(lineNode), pageInfo: { hasNextPage: o.lines.length > first, endCursor: o.lines.length > first ? `c${first}` : null } },
    shippingAddress: { address1: STREET, name: NAME }, note: NOTE,
    _lineNode: lineNode,
  };
}
const strip = (n) => { if (n) delete n._lineNode; return n; };
const COSTS = { CmaOrders: (v) => 80 * v.ids.length, CmaCustomers: (v) => 4 * v.ids.length, CmaPriorCounts: (v) => Object.keys(v).length + 1,
  CmaOrderLines: () => 502, CmaList: () => 103, CmaSubscriptions: () => 102, CmaSubscribe: () => 10 };
function bucketOf(shop) {
  const b = fake.bucket[shop] ?? (fake.bucket[shop] = { available: fake.max, at: Date.now() });
  b.available = Math.min(fake.max, b.available + ((Date.now() - b.at) / 1000) * fake.restore);
  b.at = Date.now();
  return b;
}
function graphql(shop, op, query, v) {
  const b = bucketOf(shop);
  const cost = (COSTS[op] ?? (() => 10))(v);
  const throttleStatus = () => ({ maximumAvailable: fake.max, currentlyAvailable: Math.floor(b.available), restoreRate: fake.restore });
  if (b.available < cost) {
    fake.throttled += 1;
    return { errors: [{ message: "Throttled", extensions: { code: "THROTTLED" } }], extensions: { cost: { requestedQueryCost: cost, actualQueryCost: null, throttleStatus: throttleStatus() } } };
  }
  b.available -= cost / 2;
  const ext = { cost: { requestedQueryCost: cost, actualQueryCost: cost / 2, throttleStatus: throttleStatus() } };
  const withheld = [];
  if (fake.withhold.email) withheld.push({ message: "Access denied for emailAddress field.", path: ["nodes", 0, "defaultEmailAddress"], extensions: { code: "ACCESS_DENIED" } });
  const idOfGid = (g) => String(g).split("/").pop();
  if (op === "CmaOrders") {
    return { data: { nodes: v.ids.map((g) => { const o = fake.orders[idOfGid(g)]; return o && shopOf(o) === shop ? strip(orderNode(o)) : null; }) }, errors: withheld.length ? withheld : undefined, extensions: ext };
  }
  if (op === "CmaCustomers") {
    return { data: { nodes: v.ids.map((g) => { const c = fake.customers[idOfGid(g)]; return c && shopOf(c) === shop && !c.deleted ? customerNode(c) : null; }) }, errors: withheld.length ? withheld : undefined, extensions: ext };
  }
  if (op === "CmaPriorCounts") {
    const data = {};
    for (const [k, q] of Object.entries(v)) {
      const m = /^customer_id:(\d+) AND created_at:>='([^']+)'$/.exec(q);
      const n = m ? Object.values(fake.orders).filter((o) => o.customerId === m[1] && !o.deleted && !fake.countLag.has(o.id) && Date.parse(o.createdAt) >= Date.parse(m[2])).length : 0;
      data[`c${k.slice(1)}`] = { count: n, precision: "EXACT" };
    }
    return { data, extensions: ext };
  }
  if (op === "CmaOrderLines") {
    const o = fake.orders[idOfGid(v.id)];
    const from = Number(String(v.after ?? "c0").slice(1));
    const node = orderNode(o, 1000);
    const part = o.lines.slice(from, from + 100).map(node._lineNode);
    return { data: { node: { lineItems: { nodes: part, pageInfo: { hasNextPage: o.lines.length > from + 100, endCursor: `c${from + 100}` } } } }, extensions: ext };
  }
  if (op === "CmaList") {
    const root = /\b(customers|orders)\(/.exec(query)[1];
    const field = /(created_at|updated_at):>='([^']+)' AND \1:<='([^']+)'/.exec(v.q);
    const key = field[1] === "created_at" ? "createdAt" : "updatedAt";
    const all = Object.values(root === "orders" ? fake.orders : fake.customers)
      .filter((x) => shopOf(x) === shop && !x.deleted && Date.parse(x[key]) >= Date.parse(field[2]) && Date.parse(x[key]) <= Date.parse(field[3]))
      .sort((a, b) => Date.parse(a[key]) - Date.parse(b[key]) || a.id.localeCompare(b.id));
    const from = Number(String(v.after ?? "p0").slice(1));
    if (fake.listFailAfter !== null && from >= fake.listFailAfter) return { errors: [{ message: "Internal error", extensions: { code: "INTERNAL_SERVER_ERROR" } }] };
    const part = all.slice(from, from + 100);
    return { data: { [root]: { nodes: part.map((x) => ({ id: gidOf(root === "orders" ? "Order" : "Customer", x.id), createdAt: x.createdAt, updatedAt: x.updatedAt })),
      pageInfo: { hasNextPage: all.length > from + 100, endCursor: `p${from + 100}` } } }, extensions: ext };
  }
  if (op === "CmaSubscriptions") {
    return { data: { webhookSubscriptions: { nodes: Object.values(fake.subscriptions).filter((s) => s.shop === shop).map(({ id, topic, uri }) => ({ id, topic, uri })) } }, extensions: ext };
  }
  if (op === "CmaSubscribe") {
    const id = `gid://shopify/WebhookSubscription/${Object.keys(fake.subscriptions).length + 9900000001}`;
    fake.subscriptions[id] = { id, shop, topic: v.topic, uri: v.uri };
    return { data: { webhookSubscriptionCreate: { webhookSubscription: { id, topic: v.topic, uri: v.uri }, userErrors: [] } }, extensions: ext };
  }
  return { errors: [{ message: "unknown operation" }] };
}
function hubspot(req, body, res) {
  const json = (status, b) => { res.writeHead(status, { "content-type": "application/json" }); res.end(JSON.stringify(b)); };
  if (req.headers.authorization !== `Bearer ${HS_TOKEN}`) return json(401, { message: "unauthorized" });
  const url = new URL(req.url, "http://x");
  const contacts = fake.hs.contacts;
  if (url.pathname === "/crm/v3/objects/contacts/search") {
    fake.hs.searches.push({ t: Date.now(), body });
    const match = (c) => (body.filterGroups ?? []).some((g) => g.filters.every((f) => (f.propertyName === "email" ? String(c[f.propertyName] ?? "").toLowerCase() === String(f.value).toLowerCase() : String(c[f.propertyName] ?? "") === String(f.value))));
    const results = Object.entries(contacts).filter(([, c]) => !c.deleted && match(c)).slice(0, body.limit ?? 10).map(([id]) => ({ id, properties: { hs_object_id: id } }));
    return json(200, { total: results.length, results });
  }
  if (url.pathname === "/crm/v3/objects/contacts/batch/read") {
    fake.hs.reads.push({ t: Date.now(), properties: body.properties, ids: body.inputs.map((i) => i.id) });
    const found = body.inputs.filter((i) => contacts[i.id] && !contacts[i.id].deleted);
    const missing = body.inputs.filter((i) => !found.includes(i)).map((i) => i.id);
    const results = found.map((i) => ({ id: i.id, properties: Object.fromEntries(body.properties.map((p) => [p, contacts[i.id][p] ?? null])) }));
    return json(missing.length ? 207 : 200, { status: "COMPLETE", results, ...(missing.length ? { errors: [{ status: "error", category: "OBJECT_NOT_FOUND", context: { ids: missing } }] } : {}) });
  }
  if (url.pathname === "/crm/v3/objects/contacts/batch/update") {
    if (fake.hs.update429) return json(429, { status: "error", message: "rate limited" });
    fake.hs.updates.push({ t: Date.now(), inputs: body.inputs });
    const results = [];
    const missing = [];
    for (const i of body.inputs) {
      if (!contacts[i.id] || contacts[i.id].deleted) {
        missing.push(i.id);
        continue;
      }
      Object.assign(contacts[i.id], i.properties);
      results.push({ id: i.id, properties: i.properties });
    }
    return json(missing.length ? 207 : 200, { status: "COMPLETE", results, ...(missing.length ? { errors: [{ status: "error", category: "OBJECT_NOT_FOUND", context: { ids: missing } }] } : {}) });
  }
  return json(404, { message: "not found" });
}
const fakeServer = http.createServer((req, res) => {
  let data = "";
  req.on("data", (c) => { data += c; });
  req.on("end", () => {
    const json = (status, body) => { res.writeHead(status, { "content-type": "application/json" }); res.end(JSON.stringify(body)); };
    if (req.url.startsWith("/crm/")) return hubspot(req, data ? JSON.parse(data) : {}, res);
    const m = /^\/shop\/([^/]+)(\/.*)$/.exec(req.url.split("?")[0]);
    if (!m || !fake.shops[m[1]]) return json(404, { errors: "Not Found" });
    const [, shop, p] = m;
    fake.requests.push({ shop, path: p, t: Date.now(), body: data });
    if (p === "/admin/oauth/access_token") {
      const f = new URLSearchParams(data);
      if (req.headers["content-type"] !== "application/x-www-form-urlencoded" || f.get("grant_type") !== "client_credentials"
          || f.get("client_id") !== fake.shops[shop].client || f.get("client_secret") !== fake.shops[shop].secret) {
        return json(400, { error: "invalid_client" });
      }
      fake.mints[shop] = (fake.mints[shop] ?? 0) + 1;
      const token = `shpat_fixture_${shop.split(".")[0]}_${fake.mints[shop]}`;
      fake.tokens.set(token, shop);
      return json(200, { access_token: token, scope: "read_customers,read_orders", expires_in: fake.expiresIn });
    }
    const g = /^\/admin\/api\/(\d{4}-\d{2})\/graphql\.json$/.exec(p);
    if (!g) return json(404, { errors: "Not Found" });
    fake.requests.at(-1).version = g[1];
    if (fake.tokens.get(req.headers["x-shopify-access-token"]) !== shop) return json(401, { errors: "[API] Invalid API key or access token" });
    if (fake.gqlDown) return json(503, { errors: "Service unavailable" });
    const { query, variables } = JSON.parse(data);
    const op = /^(?:query|mutation) (\w+)/.exec(query.trim())?.[1];
    fake.requests.at(-1).op = op;
    return json(200, graphql(shop, op, query, variables ?? {}));
  });
});
await new Promise((r) => fakeServer.listen(0, "127.0.0.1", r));
const FAKE = `http://127.0.0.1:${fakeServer.address().port}`;

// ---- The service and the jobs, in this process ------------------------------------------------------
process.env.INGEST_SECRETS_DIR = secretsDir;
process.env.INGEST_SHOPIFY_API_BASE = `${FAKE}/shop/{shop}`;
process.env.INGEST_HUBSPOT_API_BASE = FAKE;
process.env.INGEST_PACE_FACTOR = "0.01";
delete process.env.INGEST_SHOPIFY_READBACK_BUDGET_MS;
const logs = [];
const { setLogSink } = await import("../src/core/log.mjs");
setLogSink((line) => logs.push(line));
const { createIngestServer } = await import("../src/server.mjs");
const { runSweep } = await import("../src/jobs/sweep.mjs");
const { runReconcile } = await import("../src/jobs/reconcile.mjs");
const { runBackfill } = await import("../src/jobs/backfill.mjs");
const { runOutbox } = await import("../src/jobs/outbox.mjs");
const { resetClients } = await import("../src/adapters/shopify/client.mjs");
const { closeDb } = await import("../src/core/db.mjs");
const service = createIngestServer();
await new Promise((r) => service.listen(0, "127.0.0.1", r));
const BASE = `http://127.0.0.1:${service.address().port}`;

// ---- Setup as the admin login --------------------------------------------------------------------
const admin = new pg.Client({ host: process.env.CMA_DB_HOST, port: Number(process.env.CMA_DB_PORT ?? 5432), database: process.env.CMA_DB_NAME ?? "cma",
  user: ADMIN, password: process.env.CMA_DB_PASSWORD || undefined });
await admin.connect();
const q = async (text, values) => (await admin.query(text, values)).rows;
await q("set role cma_owner");
const [{ t1 }] = await q("select cma.create_tenant($1, 'Shopify flow one', 'Europe/Amsterdam') as t1", [SLUG1]);
const [{ t2 }] = await q("select cma.create_tenant($1, 'Shopify flow two', 'Europe/Amsterdam') as t2", [SLUG2]);
const adminOf = {};
for (const t of [t1, t2]) {
  const [{ id }] = await q("insert into cma.app_user (tenant_id, email, display_name) values ($1, 'flow-admin@example.invalid', 'Flow admin') returning id", [t]);
  await q("insert into cma.user_role (tenant_id, user_id, role_id) select $1, $2, id from cma.app_role where tenant_id = $1 and key = 'admin'", [t, id]);
  adminOf[t] = id;
}
async function asAdmin(tenant, fn) {
  await q("begin");
  await q("set local role cma_app");
  await q("select set_config('app.tenant_id', $1, true), set_config('app.user_id', $2, true), set_config('app.actor_label', 'verify:shopify-flow', true)", [tenant, adminOf[tenant]]);
  try {
    const r = await fn();
    await q("commit");
    return r;
  } catch (e) {
    await q("rollback");
    throw e;
  }
}
const conn = await asAdmin(t1, async () => {
  await q("select cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', null, null, 10)");
  const [h] = await q("select * from cma.upsert_connection('hubspot', 'HubSpot flow', $1, null, $2)", [`9${RUN.replace(/\D/g, "1").slice(0, 6)}`, `ingest-hubspot-${RUN}-token`]);
  const [a] = await q("select * from cma.upsert_connection('shopify', 'Shopify flow A', $1, $2, null)", [SHOP_A, `ingest-shopify-${RUN}-a-signing`]);
  const [n] = await q("select * from cma.upsert_connection('shopify', 'Shopify flow N', $1, $2, null)", [SHOP_N, `ingest-shopify-${RUN}-a-signing`]);
  const settings = (crm) => JSON.stringify({ client_id: CLIENT_A, api_version: "2026-10", shop_handle: HANDLE_A, crm_connection_id: crm });
  await q("select cma.set_connection_settings($1, $2::jsonb)", [a.connection_id, settings(h.connection_id)]);
  await q("select cma.set_connection_settings($1, $2::jsonb)", [n.connection_id, settings(h.connection_id)]);
  await q("select cma.upsert_commerce_store($1, $2, 'Flow store A', 'GB', 'GBP', 'Europe/London')", [a.connection_id, HANDLE_A]);
  const wb = [["commerce_ref", "contact_shopify_id_1", "slot", 1], ["commerce_ref", "contact_shopify_id_2", "slot", 2],
    ["commerce_store", "contact_shopify_store", "always", 1], ["commerce_orders", "contact_shopify_total_orders", "always", 1],
    ["commerce_spent", "contact_shopify_total_spent", "always", 1], ["country", "contact_country", "if_empty", 1],
    ["currency", "contact_currency", "if_empty", 1], ["language", "contact_language", "if_empty", 1]];
  for (const [field, prop, mode, slot] of wb) await q("select cma.set_writeback_field($1, $2, $3, $4, true, $5::smallint)", [h.connection_id, field, prop, mode, slot]);
  return { h: h.connection_id, a: a.connection_id, aKey: a.key, n: n.connection_id, nKey: n.key, hKey: h.key };
});
const connX = await asAdmin(t2, async () => {
  await q("select cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', null, null, 10)");
  const [x] = await q("select * from cma.upsert_connection('shopify', 'Shopify flow X', $1, $2, null)", [SHOP_X, `ingest-shopify-${RUN}-x-signing`]);
  await q("select cma.set_connection_settings($1, $2::jsonb)", [x.connection_id, JSON.stringify({ client_id: CLIENT_X, shop_handle: `flow-${RUN}-x` })]);
  await q("select cma.upsert_commerce_store($1, $2, 'Flow store X', 'GB', 'GBP', 'Europe/London')", [x.connection_id, `flow-${RUN}-x`]);
  return { x: x.connection_id, xKey: x.key };
});
// The HubSpot contacts (invented). H2 has an agent's country and another customer in slot 1; H6 both slots taken
Object.assign(fake.hs.contacts, {
  "5100000001": { email: "test1@example.com", contact_netsuite_id: "NS-1" },
  "5100000002": { email: "test2@example.com", contact_country: "NL", contact_shopify_id_1: "7199999999" },
  "5100000003": { email: "someone.else@example.com", contact_shopify_id_1: C.c3 },
  "5100000051": { email: "twice@example.com" }, "5100000052": { email: "TWICE@example.com" },
  "5100000006": { email: "full@example.com", contact_shopify_id_1: "7199999997", contact_shopify_id_2: "7199999998", contact_country: "GB" },
  "5100000007": { email: "other@example.com" },
  "5100000008": { email: "later@example.com" },
});
// C7's contact is held by the CMA with the customer id in its refs (0007's slots)
const [{ id: k7 }] = await q("insert into cma.crm_contact (tenant_id, connection_id, source_system, source_id) values ($1, $2, 'hubspot', '5100000007') returning id", [t1, conn.h]);
await q("insert into cma.crm_contact_ref (tenant_id, contact_id, system, external_id, slot) values ($1, $2, 'shopify', $3, 1)", [t1, k7, C.c7]);

// ---- Helpers -------------------------------------------------------------------------------------
const sign = (secret, body) => createHmac("sha256", secret).update(body).digest("base64");
async function deliver(key, topic, payload, { shop = SHOP_A, secret = SECRET_A, webhookId = randomUUID(), hmac, tamper = false, route = "shopify" } = {}) {
  const body = JSON.stringify(payload);
  const headers = { "content-type": "application/json", "x-shopify-topic": topic, "x-shopify-shop-domain": shop, "x-shopify-webhook-id": webhookId,
    "x-shopify-event-id": randomUUID(), "x-shopify-triggered-at": nowIso(), "x-shopify-api-version": "2026-10" };
  if (hmac !== null) headers["x-shopify-hmac-sha256"] = hmac ?? sign(secret, body);
  const started = Date.now();
  const res = await fetch(`${BASE}/${route}/${key}`, { method: "POST", headers, body: tamper ? body.replace("Invented", "Altered") : body });
  return { status: res.status, body: await res.text(), ms: Date.now() - started, webhookId };
}
const restCustomer = (key) => ({ id: Number(C[key]), admin_graphql_api_id: gidOf("Customer", C[key]), email: EMAIL[key], phone: PHONE[key], first_name: "Invented", last_name: "Customer",
  updated_at: fake.customers[C[key]]?.updatedAt ?? nowIso(), default_address: { address1: STREET } });
const restOrder = (id) => ({ id: Number(id), admin_graphql_api_id: gidOf("Order", id), email: "order@example.com", phone: fake.orders[id]?.phone ?? null, note: NOTE,
  updated_at: fake.orders[id]?.updatedAt ?? nowIso(), customer: { id: Number(fake.orders[id]?.customerId ?? 0), email: "order@example.com", first_name: "Invented" },
  shipping_address: { address1: STREET, phone: ORDER_PHONE } });
const count = async (table, c = conn.a) => Number((await q(`select count(*) as n from cma.${table} where connection_id = $1`, [c]))[0].n);
const eventsOf = async (c = conn.a) => q("select event_key, object_type, object_id, kind, status, error, raw from cma.ingest_event where connection_id = $1 order by recorded_at, event_key", [c]);
const customerRow = async (id, c = conn.a) => (await q("select state, locale, orders_count, amount_spent, amount_currency, phone_hash, source_deleted_at, raw from cma.commerce_customer where connection_id = $1 and source_id = $2", [c, id]))[0] ?? null;
const orderRow = async (id, c = conn.a) => (await q(`select order_name, customer_source_id, is_test, total_amount, source_name, app_ref, landing_host, landing_path, utm, referring_host, tags,
  prior_orders_count, prior_count_exact, order_kind, phone_hash, cancelled_at, cancel_reason, source_deleted_at, raw from cma.commerce_order where connection_id = $1 and source_id = $2`, [c, id]))[0] ?? null;
const linesOf = async (id) => (await q("select line_source_id, sku, product_ref, variant_ref, quantity, unit_price from cma.commerce_order_line where connection_id = $1 and order_source_id = $2 order by line_source_id", [conn.a, id]));
const outbox = async () => q("select target_id, payload, reason, status, error, result from cma.outbox_action where connection_id = $1 order by id", [conn.h]);
const gql = (since, op = null, shop = SHOP_A) => fake.requests.filter((r) => r.t >= since && r.shop === shop && r.path.endsWith("graphql.json") && (!op || r.op === op));
const mark = () => Date.now();
const forceDue = (c = conn.a) => q("update cma.ingest_event set next_attempt_at = now() where connection_id = $1 and status = 'failed'", [c]);
const runs = async (c, job) => q("select stream, status, error, counts from cma.sync_run where connection_id = $1 and job = $2 order by started_at", [c, job]);
const processedLog = (since) => logs.map((l) => JSON.parse(l)).filter((l) => l.message === "processed" && l.adapter === "shopify" && Date.parse(l.time) >= since);
const sumCounts = (lines, k) => lines.reduce((s, l) => s + (l.upserts?.[k] ?? 0), 0);
const sorted = (o) => (o && typeof o === "object" ? Object.fromEntries(Object.entries(o).sort(([a], [b]) => a.localeCompare(b))) : o);

// ---- A. The route and its authentication ----------------------------------------------------------
addCustomer("c1");
const payload1 = restCustomer("c1");
expect("an unknown key → 404", (await deliver("k".repeat(32), "customers/create", payload1)).status, 404, 200);
expect("the HubSpot connection's key on /shopify → 404", (await deliver(conn.hKey, "customers/create", payload1)).status, 404, 200);
expect("the Shopify connection's key on /hubspot → 404", (await deliver(conn.aKey, "customers/create", payload1, { route: "hubspot" })).status, 404, 200);
expect("no HMAC header → 401", (await deliver(conn.aKey, "customers/create", payload1, { hmac: null })).status, 401, 200);
expect("an HMAC that is not a SHA-256 digest → 401", (await deliver(conn.aKey, "customers/create", payload1, { hmac: "abc" })).status, 401, 200);
expect("an HMAC with another secret → 401", (await deliver(conn.aKey, "customers/create", payload1, { secret: "another-secret" })).status, 401, 200);
expect("a body changed after signing → 401", (await deliver(conn.aKey, "customers/create", payload1, { tamper: true })).status, 401, 200);
expect("tenant two's secret on tenant one's key → 401", (await deliver(conn.aKey, "customers/create", payload1, { secret: SECRET_X })).status, 401, 200);
expect("refused requests wrote nothing and asked Shopify nothing", [await count("ingest_event"), fake.requests.length], [0, 0], [1, 1]);
expect("…and answered with an empty body", (await deliver(conn.aKey, "customers/create", payload1, { hmac: null })).body, "", "unauthorized");

// ---- B. Another shop, another topic -----------------------------------------------------------------
let t0 = mark();
const other = await deliver(conn.aKey, "customers/create", payload1, { shop: SHOP_X });
const product = await deliver(conn.aKey, "products/update", { id: 9000000001, title: "Invented product" });
expect("another shop's domain and an unhandled topic, correctly signed → 200", [other.status, product.status], [200, 200], [401, 401]);
const ignored = (await eventsOf()).filter((e) => e.status === "ignored").map((e) => `${e.raw.topic}:${e.raw.ignored}`).sort();
expect("…recorded as ignored (portal_mismatch, event_not_handled), nothing read", [ignored, gql(t0).length], [["customers/create:portal_mismatch", "products/update:event_not_handled"], 0], [[], 1]);

// ---- C. A customer: read back, hashed, matched, written back ------------------------------------------
t0 = mark();
const first = await deliver(conn.aKey, "customers/create", payload1);
expect("customers/create → 200", first.status, 200, 401);
let ev = (await eventsOf()).find((e) => e.event_key === `sh:${first.webhookId}`);
expect("…keyed sh:<X-Shopify-Webhook-Id>, processed, the topic and ids in raw only", [ev?.status, ev?.object_type, ev?.kind, Object.keys(ev?.raw ?? {}).sort()],
  ["processed", "commerce_customer", "created", ["apiVersion", "eventId", "topic", "triggeredAt", "webhookId"]], ["received", "commerce_customer", "created", []]);
let cu = await customerRow(C.c1);
expect("…the customer: state, locale, count, amount, currency", [cu?.state, cu?.locale, cu?.orders_count, cu?.amount_spent, cu?.amount_currency], ["ENABLED", "en-GB", 0, "0.00", "GBP"], []);
expect("…its phone as HMAC(pepper, E.164), the store's market as default region", cu?.phone_hash, H(PEPPER1, "+442000000101"), null);
expect("…one token minted for the shop by the client credentials grant, one GraphQL read at 2026-10", [fake.mints[SHOP_A], gql(t0).length, gql(t0)[0]?.version], [1, 1, "2026-10"], [2, 2, "2025-10"]);
expect("…one HubSpot search, by the email in lower case", [fake.hs.searches.length, fake.hs.searches[0]?.body.filterGroups[0].filters[0]], [1, { propertyName: "email", operator: "EQ", value: "test1@example.com" }], [0, null]);
let ob = await outbox();
expect("…a pending write-back for contact 5100000001 with the customer's values", [ob.length, ob[0]?.target_id, ob[0]?.status, sorted(ob[0]?.payload)],
  [1, "5100000001", "pending", sorted({ commerce_ref: C.c1, commerce_store: HANDLE_A, commerce_orders: 0, commerce_spent: 0, country: "GB", currency: "GBP", language: "en" })], [0, null, null, null]);
expect("…its reason the store connection and the customer id", ob[0]?.reason, `commerce_customer:${conn.a}:${C.c1}`, null);
t0 = mark();
const again = await deliver(conn.aKey, "customers/create", payload1, { webhookId: first.webhookId });
expect("the same delivery again (a Shopify retry) → 200, no new event, no read", [again.status, (await eventsOf()).length, gql(t0).length], [200, 3, 0], [500, 4, 1]);

// ---- D. Orders: first, repeat, renewal, lines, pages, the phone, lag, guest, cancel, delete -----------
await asAdmin(t1, () => q("select cma.set_tenant_setting('commerce.renewal_source_names', 'subscription_contract')"));
const O1 = addOrder("7300000001", { customerId: C.c1, phone: ORDER_PHONE, lineCount: 13 });
t0 = mark();
expect("orders/create (first order of C1, 13 lines) → 200", (await deliver(conn.aKey, "orders/create", restOrder(O1))).status, 200, 401);
let or = await orderRow(O1);
expect("…first, prior 0 exact", [or?.order_kind, or?.prior_orders_count, or?.prior_count_exact], ["first", 0, true], ["unknown", null, false]);
expect("…13 lines: the first ten and a page after them", [(await linesOf(O1)).length, gql(t0, "CmaOrderLines").length], [13, 1], [10, 0]);
expect("…a line: sku, product and variant ids, quantity, unit price", (await linesOf(O1))[0], { line_source_id: `${O1}01`, sku: "SKU-1", product_ref: "8000000001", variant_ref: "81000001", quantity: 1, unit_price: "60.00" }, {});
expect("…the landing page as host and path, UTM from the visit, the referrer's host only", [or?.landing_host, or?.landing_path, sorted(or?.utm), or?.referring_host],
  ["shop.example.com", "/products/aed", sorted({ source: "google", medium: "cpc", campaign: "autumn" }), "www.google.com"], []);
expect("…the source name, the app id, tags de-duplicated, amounts", [or?.source_name, or?.app_ref, or?.tags, or?.total_amount], ["web", "580111", ["aed"], "120.00"], []);
expect("…the order's own phone hashed first (national, GB default region)", or?.phone_hash, H(PEPPER1, "+442000000201"), H(PEPPER1, "+442000000101"));
expect("…the customer upserted with it (count 1) and no second search: the earlier write-back knows its contact", [(await customerRow(C.c1))?.orders_count, fake.hs.searches.length], [1, 1], [0, 2]);
ob = await outbox();
expect("…the newer write-back supersedes the pending one (totals 1 order, 120.00)", [ob.map((a) => a.status), ob.at(-1)?.payload.commerce_orders, ob.at(-1)?.payload.commerce_spent], [["superseded", "pending"], 1, 120], [["pending"], 0, 0]);
const O2 = addOrder("7300000002", { customerId: C.c1 });
await deliver(conn.aKey, "orders/create", restOrder(O2));
or = await orderRow(O2);
expect("a second order of C1 → repeat, prior 1, the customer's phone hashed (no order phone)", [or?.order_kind, or?.prior_orders_count, or?.phone_hash], ["repeat", 1, H(PEPPER1, "+442000000101")], ["first", 0, null]);
addCustomer("c2");
const O3 = addOrder("7300000003", { customerId: C.c2, sourceName: "subscription_contract", appId: "580222" });
await deliver(conn.aKey, "orders/create", restOrder(O3));
expect("an order of the renewal source name → renewal", (await orderRow(O3))?.order_kind, "renewal", "first");
const O4 = addOrder("7300000004", { customerId: C.c2 });
fake.countLag.add(O4);
await deliver(conn.aKey, "orders/create", restOrder(O4));
or = await orderRow(O4);
expect("an order the search does not hold yet → unknown, prior null", [or?.order_kind, or?.prior_orders_count], ["unknown", null], ["repeat", 1]);
fake.countLag.delete(O4);
fake.orders[O4].updatedAt = nowIso();
await deliver(conn.aKey, "orders/updated", restOrder(O4));
expect("…its next read (orders/updated) counts again → repeat", (await orderRow(O4))?.order_kind, "repeat", "unknown");
const O5 = addOrder("7300000005", { phone: GUEST_PHONE });
await deliver(conn.aKey, "orders/create", restOrder(O5));
or = await orderRow(O5);
expect("a guest order (no customer) → unknown, its phone hashed", [or?.order_kind, or?.customer_source_id, or?.phone_hash], ["unknown", null, H(PEPPER1, "+442000000202")], ["first", "0", null]);
Object.assign(fake.orders[O2], { cancelledAt: nowIso(), cancelReason: "CUSTOMER", updatedAt: nowIso() });
await deliver(conn.aKey, "orders/cancelled", restOrder(O2));
or = await orderRow(O2);
expect("orders/cancelled → cancelled at, with its reason", [Boolean(or?.cancelled_at), or?.cancel_reason], [true, "CUSTOMER"], [false, null]);
fake.orders[O5].deleted = true;
await deliver(conn.aKey, "orders/delete", { id: Number(O5) });
or = await orderRow(O5);
expect("orders/delete → deleted without a read, its hash cleared", [Boolean(or?.source_deleted_at), or?.phone_hash], [true, null], [false, H(PEPPER1, "+442000000202")]);

// ---- E. Known contacts, withheld fields, no match, two matches ------------------------------------------
addCustomer("c7");
let searches = fake.hs.searches.length;
await deliver(conn.aKey, "customers/create", restCustomer("c7"));
ob = await outbox();
expect("a customer whose id a held contact's refs hold → that contact, no search", [ob.at(-1)?.target_id, fake.hs.searches.length - searches], ["5100000007", 0], [null, 1]);
fake.withhold = { email: true, phone: true };
addCustomer("c3");
searches = fake.hs.searches.length;
t0 = mark();
const withheld = await deliver(conn.aKey, "customers/create", restCustomer("c3"));
cu = await customerRow(C.c3);
expect("Email and Phone withheld → 200, processed, no hash (nothing fails)", [withheld.status, (await eventsOf()).find((e) => e.event_key === `sh:${withheld.webhookId}`)?.status, cu?.phone_hash], [200, "processed", null], [200, "failed", "x"]);
const refSearch = fake.hs.searches.at(-1)?.body.filterGroups.map((g) => g.filters[0]);
expect("…the match by the commerce_ref properties instead (one search, both slots)", [fake.hs.searches.length - searches, refSearch], [1, [
  { propertyName: "contact_shopify_id_1", operator: "EQ", value: C.c3 }, { propertyName: "contact_shopify_id_2", operator: "EQ", value: C.c3 }]], [0, []]);
expect("…written back to the contact holding the id", (await outbox()).at(-1)?.target_id, "5100000003", null);
fake.withhold = { email: false, phone: false };
const before = (await outbox()).length;
t0 = mark();
addCustomer("c4");
addCustomer("c5");
await deliver(conn.aKey, "customers/create", restCustomer("c4"));
await deliver(conn.aKey, "customers/create", restCustomer("c5"));
expect("no contact for the email, and two contacts → nothing written back", (await outbox()).length - before, 0, 2);
expect("…counted as match_none and match_several in the processed log (no ids)", [sumCounts(processedLog(t0), "match_none"), sumCounts(processedLog(t0), "match_several")], [1, 1], [0, 0]);
addCustomer("c6");
await deliver(conn.aKey, "customers/create", restCustomer("c6"));
addCustomer("c2", { updatedAt: nowIso() });
await deliver(conn.aKey, "customers/update", restCustomer("c2"));

// ---- F. The token: cached for 24 hours, minted again near its expiry --------------------------------
expect("one token minted for every read of the shop so far", fake.mints[SHOP_A], 1, 2);
resetClients();
fake.expiresIn = 299; // less than the five-minute margin: never cached
addCustomer("c8");
await deliver(conn.aKey, "customers/create", restCustomer("c8"));
await deliver(conn.aKey, "customers/update", restCustomer("c8"));
expect("a token within five minutes of its expiry is minted again", fake.mints[SHOP_A], 3, 2);
fake.expiresIn = 86399;

// ---- G. A store without its row -------------------------------------------------------------------
const noStore = await deliver(conn.nKey, "customers/create", { ...restCustomer("c1") }, { shop: SHOP_N });
const nEvent = (await eventsOf(conn.n))[0];
expect("a connection without its store row: 200, the event failed store_not_configured for the sweep", [noStore.status, nEvent?.status, nEvent?.error], [200, "failed", "store_not_configured"], [200, "processed", null]);

// ---- H. The outbox job --------------------------------------------------------------------------------
await asAdmin(t1, () => q("select cma.set_writeback_field($1, 'currency', 'contact_currency', 'if_empty', false)", [conn.h]));
fake.hs.update429 = true;
t0 = mark();
const o1 = await runOutbox({ connectionId: conn.h });
ob = await outbox();
expect("HubSpot answering 429 on the batch update → the actions failed rate_limited, attempted again later", [o1.sent, ob.filter((a) => a.status === "failed").every((a) => a.error === "rate_limited"),
  (await q("select bool_and(next_attempt_at > now()) as later from cma.outbox_action where connection_id = $1 and status = 'failed'", [conn.h]))[0].later], [0, true, true], [7, false, false]);
fake.hs.update429 = false;
await q("update cma.outbox_action set next_attempt_at = now() where connection_id = $1 and status = 'failed'", [conn.h]);
const o2 = await runOutbox({ connectionId: conn.h });
const hs = fake.hs.contacts;
expect("…then sent", [o2.actionsFailed, (await outbox()).filter((a) => a.status === "sent").length], [0, 6], [6, 0]);
expect("H1 (empty): id in slot 1, store, totals, country and language; currency disabled after the enqueue never written",
  [hs["5100000001"].contact_shopify_id_1, hs["5100000001"].contact_shopify_store, hs["5100000001"].contact_shopify_total_orders, hs["5100000001"].contact_shopify_total_spent,
    hs["5100000001"].contact_country, hs["5100000001"].contact_language, hs["5100000001"].contact_currency],
  [C.c1, HANDLE_A, "2", "240", "GB", "en", undefined], [null, null, null, null, null, null, "GBP"]);
expect("H2: an agent's country kept (if_empty), the id in slot 2, no store or totals (not slot 1)",
  [hs["5100000002"].contact_country, hs["5100000002"].contact_shopify_id_1, hs["5100000002"].contact_shopify_id_2, hs["5100000002"].contact_shopify_store, hs["5100000002"].contact_shopify_total_orders],
  ["NL", "7199999999", C.c2, undefined, undefined], ["GB", C.c2, null, HANDLE_A, "2"]);
expect("H6: both slots taken → no id, no totals; the result says slots_full",
  [hs["5100000006"].contact_shopify_id_1, hs["5100000006"].contact_shopify_id_2, hs["5100000006"].contact_shopify_total_orders, (await outbox()).find((a) => a.target_id === "5100000006")?.result?.ref],
  ["7199999997", "7199999998", undefined, "slots_full"], [C.c6, null, "0", "written"]);
expect("H3 (found by its ref): slot 1 already holds the id → present, totals written", [(await outbox()).find((a) => a.target_id === "5100000003")?.result?.ref, hs["5100000003"].contact_shopify_store], ["present", HANDLE_A], ["written", undefined]);
const allowed = ["contact_shopify_id_1", "contact_shopify_id_2", "contact_shopify_store", "contact_shopify_total_orders", "contact_shopify_total_spent", "contact_country", "contact_language"];
expect("only the enabled write-back properties read and written (never contact_netsuite_id or email)", [
  fake.hs.reads.every((r) => r.properties.every((p) => allowed.includes(p))),
  fake.hs.updates.every((u) => u.inputs.every((i) => Object.keys(i.properties).every((p) => allowed.includes(p)))),
  hs["5100000001"].contact_netsuite_id], [true, true, "NS-1"], [false, false, null]);
const writesBefore = fake.hs.updates.length;
const O6 = addOrder("7300000006", { customerId: C.c1 });
await deliver(conn.aKey, "orders/create", restOrder(O6));
await runOutbox({ connectionId: conn.h });
const lastWrite = fake.hs.updates.slice(writesBefore).flatMap((u) => u.inputs).find((i) => i.id === "5100000001");
expect("a third order of C1: always writes only the difference (totals), not what is unchanged", Object.keys(lastWrite?.properties ?? {}).sort(), ["contact_shopify_total_orders", "contact_shopify_total_spent"], ["contact_shopify_store"]);
hs["5100000008"].deleted = true;
const O7 = addOrder("7300000007", { customerId: C.c8 });
await deliver(conn.aKey, "orders/create", restOrder(O7));
await runOutbox({ connectionId: conn.h });
expect("a contact gone from HubSpot → failed contact_not_found", (await outbox()).findLast((a) => a.target_id === "5100000008")?.error, "contact_not_found", null);

// ---- I. A burst of 200 order deliveries (a renewal run) ------------------------------------------------
const BURST = 200;
const burstIds = [];
for (let i = 0; i < BURST; i += 1) {
  const cid = String(7400000000 + i);
  fake.customers[cid] = { id: cid, shop: SHOP_A, state: "ENABLED", locale: "en-GB", email: `renewal-${i}@example.com`, phone: `+44 20 0000 ${String(3000 + i)}`, createdAt: nowIso(-86400 * 30), updatedAt: nowIso(-60) };
  burstIds.push(addOrder(String(7500000000 + i), { customerId: cid, sourceName: "subscription_contract", lineCount: 1, landingPage: null, referrerUrl: null, utm: null }));
}
resetClients();
fake.bucket = {};
fake.throttled = 0;
const mintsBefore = fake.mints[SHOP_A];
t0 = mark();
const answers = await Promise.all(burstIds.map((id) => deliver(conn.aKey, "orders/create", restOrder(id))));
const times = answers.map((a) => a.ms).sort((a, b) => a - b);
console.log(`      burst: answered in ${times[0]} to ${times.at(-1)} ms (median ${times[Math.floor(BURST / 2)]}); token mints ${fake.mints[SHOP_A] - mintsBefore}; GraphQL throttled ${fake.throttled}`);
expect("a burst of 200 orders/create → 200 for every one", answers.every((a) => a.status === 200), true, false);
expect("…every answer inside Shopify's five seconds", times.at(-1) < 5000, true, false);
expect("…one token minted for the whole burst", fake.mints[SHOP_A] - mintsBefore, 1, 200);
const burstEvents = await q("select status, count(*)::int as n from cma.ingest_event where connection_id = $1 and object_id = any ($2) group by 1 order by 1", [conn.a, burstIds]);
console.log(`      burst events after the inline read-back: ${burstEvents.map((r) => `${r.status} ${r.n}`).join(", ")}`);
expect("…200 events recorded, each once", burstEvents.reduce((s, r) => s + r.n, 0), BURST, BURST + 1);
for (let i = 0; i < 20; i += 1) {
  const left = Number((await q("select count(*) as n from cma.ingest_event where connection_id = $1 and object_id = any ($2) and status <> 'processed'", [conn.a, burstIds]))[0].n);
  if (left === 0) break;
  await forceDue();
  await runSweep({ connectionId: conn.a });
}
const burstOrders = await q("select order_kind, count(*)::int as n from cma.commerce_order where connection_id = $1 and source_id = any ($2) group by 1", [conn.a, burstIds]);
expect("…after the sweep: every order stored once, all renewals", burstOrders, [{ order_kind: "renewal", n: BURST }], [{ order_kind: "renewal", n: BURST - 1 }]);
expect("…every event processed", Number((await q("select count(*) as n from cma.ingest_event where connection_id = $1 and object_id = any ($2) and status = 'processed'", [conn.a, burstIds]))[0].n), BURST, 0);
expect("…Shopify refused for cost at most a handful of calls (the bucket paces the reads)", fake.throttled <= 5, true, false);

// ---- J. Reconcile and the subscription check -------------------------------------------------------------
Object.assign(fake.orders[O1], { tags: ["aed", "renewed-by-hand"], updatedAt: nowIso(-5) });
const topics = ["CUSTOMERS_CREATE", "CUSTOMERS_UPDATE", "CUSTOMERS_DELETE", "ORDERS_CREATE", "ORDERS_UPDATED", "ORDERS_CANCELLED", "ORDERS_DELETE"];
topics.forEach((topic, i) => { fake.subscriptions[`gid://shopify/WebhookSubscription/${8800000001 + i}`] = { id: `gid://shopify/WebhookSubscription/${8800000001 + i}`, shop: SHOP_A, topic, uri: `https://ingest.example.com/shopify/${conn.aKey}` }; });
fake.subscriptions["gid://shopify/WebhookSubscription/8800000099"] = { id: "gid://shopify/WebhookSubscription/8800000099", shop: SHOP_A, topic: "ORDERS_CREATE", uri: "https://elsewhere.example.com/hook" };
delete fake.subscriptions["gid://shopify/WebhookSubscription/8800000005"]; // ORDERS_UPDATED, deleted by Shopify after failed deliveries
await runReconcile({ connectionId: conn.a, lookbackMinutes: 120 });
expect("reconcile: an order changed without a webhook is read back (its new tag)", (await orderRow(O1))?.tags, ["aed", "renewed-by-hand"], ["aed"]);
let rc = await runs(conn.a, "reconcile");
expect("…one succeeded run per object type", rc.map((r) => `${r.stream}:${r.status}`), ["commerce_customer:succeeded", "commerce_order:succeeded"], []);
let sc = await runs(conn.a, "subscriptions_check");
const recreated = Object.values(fake.subscriptions).filter((s) => s.topic === "ORDERS_UPDATED" && s.shop === SHOP_A);
expect("…the subscription check recreated ORDERS_UPDATED at the connection's address, run error subscriptions_recreated",
  [sc.at(-1)?.error, recreated.map((s) => s.uri)], ["subscriptions_recreated", [`https://ingest.example.com/shopify/${conn.aKey}`]], [null, []]);
await runReconcile({ connectionId: conn.a, lookbackMinutes: 120 });
sc = await runs(conn.a, "subscriptions_check");
expect("…a second check finds all seven: succeeded", [sc.at(-1)?.status, sc.at(-1)?.error], ["succeeded", null], ["failed", "subscriptions_recreated"]);
const readsBefore = gql(0, "CmaOrders").length;
await runReconcile({ connectionId: conn.a, lookbackMinutes: 120 });
expect("…an unchanged order is not read a second time", gql(0, "CmaOrders").length - readsBefore, 0, 1);
for (const k of Object.keys(fake.subscriptions)) if (fake.subscriptions[k].uri.includes(conn.aKey)) delete fake.subscriptions[k];
await runReconcile({ connectionId: conn.a, lookbackMinutes: 120 });
sc = await runs(conn.a, "subscriptions_check");
expect("…none left for this connection → subscriptions_missing (the script recreates them)", sc.at(-1)?.error, "subscriptions_missing", null);

// ---- K. Backfill, resumable --------------------------------------------------------------------------------
const old = [];
for (let i = 0; i < 150; i += 1) {
  const id = String(7600000000 + i);
  old.push(addOrder(id, { customerId: C.c1, createdAt: new Date(Date.now() - (10 - i / 20) * 86400_000).toISOString(), updatedAt: new Date(Date.now() - (10 - i / 20) * 86400_000).toISOString(), lineCount: 1 }));
}
const fromDate = new Date(Date.now() - 11 * 86400_000).toISOString().slice(0, 10);
fake.listFailAfter = 100;
const bf1 = await runBackfill({ connectionId: conn.a, object: "commerce_order", from: fromDate });
const cur1 = (await q("select cursor from cma.sync_cursor where connection_id = $1 and stream = 'backfill:commerce_order'", [conn.a]))[0]?.cursor;
const stored1 = Number((await q("select count(*) as n from cma.commerce_order where connection_id = $1 and source_id = any ($2)", [conn.a, old]))[0].n);
expect("backfill: the listing failing on its second page → the run fails, the first page kept", [bf1.error, stored1, cur1?.done], ["graphql_error", 100, false], [null, 150, true]);
fake.listFailAfter = null;
const bf2 = await runBackfill({ connectionId: conn.a, object: "commerce_order", from: fromDate });
const stored2 = Number((await q("select count(*) as n from cma.commerce_order where connection_id = $1 and source_id = any ($2)", [conn.a, old]))[0].n);
expect("…a second run continues from the cursor and finishes", [bf2.error, stored2], [null, 150], ["graphql_error", 100]);
t0 = mark();
const bf3 = await runBackfill({ connectionId: conn.a, object: "commerce_order", from: fromDate });
expect("…a third run with the same start does nothing", [bf3.error, gql(t0).length], [null, 0], [null, 1]);
expect("…backfill of another object is refused", await runBackfill({ connectionId: conn.a, object: "deal" }).then(() => "ran", (e) => e.constructor.name), "UsageError", "ran");

// ---- L. Tenant isolation ------------------------------------------------------------------------------------
fake.customers["7700000001"] = { id: "7700000001", shop: SHOP_X, state: "ENABLED", locale: "nb-NO", email: "test1@example.com", phone: "+44 20 0000 0109", createdAt: nowIso(-60), updatedAt: nowIso(-30) };
const rx = await deliver(connX.xKey, "customers/create", { id: 7700000001, email: "test1@example.com" }, { shop: SHOP_X, secret: SECRET_X });
const rowX = (await q("select tenant_id, phone_hash, locale from cma.commerce_customer where connection_id = $1 and source_id = '7700000001'", [connX.x]))[0];
expect("tenant two's shop with its own secret → its row in tenant two, hashed with its own pepper", [rx.status, rowX?.tenant_id, rowX?.phone_hash], [200, t2, H(PEPPER2, "+442000000109")], [401, t1, H(PEPPER1, "+442000000109")]);
expect("…no write-back without a CRM connection on that store", Number((await q("select count(*) as n from cma.outbox_action where tenant_id = $1", [t2]))[0].n), 0, 1);
expect("tenant one sees none of tenant two's customers or events", await asAdmin(t1, async () => [
  Number((await q("select count(*) as n from cma.commerce_customer where connection_id = $1", [connX.x]))[0].n),
  Number((await q("select count(*) as n from cma.ingest_event where connection_id = $1", [connX.x]))[0].n)]), [0, 0], [1, 1]);

// ---- M. What was written and logged ---------------------------------------------------------------------------
const tenants = [t1, t2];
const dbText = JSON.stringify(await q(`select row_to_json(x)::text as r from cma.commerce_customer x where tenant_id = any ($1)
  union all select row_to_json(x)::text from cma.commerce_order x where tenant_id = any ($1)
  union all select row_to_json(x)::text from cma.commerce_order_line x where tenant_id = any ($1)
  union all select row_to_json(x)::text from cma.ingest_event x where tenant_id = any ($1)
  union all select row_to_json(x)::text from cma.outbox_action x where tenant_id = any ($1)
  union all select row_to_json(x)::text from cma.sync_cursor x where tenant_id = any ($1)
  union all select row_to_json(x)::text from cma.sync_run x where tenant_id = any ($1)
  union all select row_to_json(x)::text from cma.integration_connection x where tenant_id = any ($1)
  union all select row_to_json(x)::text from cma.audit_log x where tenant_id = any ($1)`, [tenants]));
const emails = [...Object.values(EMAIL), "order@example.com", "someone@example.com", "someone%40example.com", "renewal-0@example.com", "renewal-199@example.com"]
  .flatMap((e) => [e, e.toLowerCase()]);
const numbers = [...Object.values(PHONE), ORDER_PHONE, GUEST_PHONE, "+44 20 0000 3000", "+44 20 0000 3199", "+44 20 0000 0109"]
  .flatMap((n) => [n, n.replace(/\D/g, ""), `+${n.replace(/\D/g, "").replace(/^0/, "44")}`, n.replace(/\D/g, "").replace(/^(44|0)/, "")]);
expect("no fixture email in any database row of the flow (audit log included)", emails.filter((e) => dbText.includes(e)), [], emails);
expect("no fixture phone number, in any form, in any database row", numbers.filter((n) => dbText.includes(n)), [], numbers);
expect("no name, address, note, client secret or token in the database", /Invented|Invented Street|must not be stored|shpat_fixture|fixture-shopify-client-secret|fixture-hubspot-token/.test(dbText), false, true);
const logText = logs.join("\n");
expect("the logs hold no email, number, name, token or secret", [emails.some((e) => logText.includes(e)), numbers.some((n) => logText.includes(n)), /Invented|shpat_fixture|fixture-shopify-client-secret|fixture-hubspot-token/.test(logText)],
  [false, false, false], [true, true, true]);
expect("the logs hold the webhook, processed, outbox, sweep, reconcile and backfill lines", ["webhook", "processed", "outbox", "sweep", "reconcile", "backfill"].every((m) => logs.some((l) => JSON.parse(l).message === m)), true, false);

// This run's connections stop being served (a later run's unfiltered jobs leave them alone)
for (const c of [conn.a, conn.n, conn.h]) await asAdmin(t1, () => q("select cma.set_connection_status($1, 'inactive')", [c]));
await asAdmin(t2, () => q("select cma.set_connection_status($1, 'inactive')", [connX.x]));
await admin.end();
await new Promise((r) => service.close(r));
await new Promise((r) => fakeServer.close(r));
await closeDb();
rmSync(secretsDir, { recursive: true, force: true });
verdict();
