/**
 * The webhook subscriptions of one Shopify store connection (PROD_RUNBOOK 9.7; VENDOR_SETUP §3.4;
 * brief B10), through the Admin GraphQL API.
 *
 *   node docs/ingest/shopify-subscribe.mjs --project <gcp project> --shop <handle>.myshopify.com \
 *        --client-id <id> --secret-name <client secret name> --url <full webhook url> [--api-version 2026-10]
 *   node docs/ingest/shopify-subscribe.mjs … --list [--url <full webhook url>]
 *   node docs/ingest/shopify-subscribe.mjs … --delete <subscription id>
 *   node docs/ingest/shopify-subscribe.mjs … --source-names [--days <1-60>]
 *
 * Reads the app's client secret from Secret Manager with your own gcloud login (held in memory, never
 * printed), mints a store token by the client credentials grant (POST https://<shop>/admin/oauth/
 * access_token, form-encoded; the token lives 24 hours and is used for this run only, never printed),
 * then:
 *
 *   create (default)  webhookSubscriptionCreate for each of the seven topics (CUSTOMERS_CREATE,
 *                     CUSTOMERS_UPDATE, CUSTOMERS_DELETE, ORDERS_CREATE, ORDERS_UPDATED, ORDERS_CANCELLED,
 *                     ORDERS_DELETE) with uri = --url; a topic already subscribed at that address is
 *                     listed as existing and not created twice (a rerun is safe). Prints ids and topics only
 *   --list            every subscription of the shop: id, topic and address (* marks --url's)
 *   --delete <id>     webhookSubscriptionDelete (a numeric id or the gid --list prints)
 *   --source-names    the sales channels (sourceName) and apps (app id and name) of the shop's orders of
 *                     the last --days days (default 30, at most 60), with their counts, newest 1,000
 *                     orders at most: what the renewal settings name (PROD_RUNBOOK 9.6). No customer data
 *
 * --url must be https://<host>/shopify/<connection key> without a query (no personal data in the path).
 * INGEST_SHOPIFY_API_BASE (a URL with {shop}; https, or http on localhost) replaces https://<shop> for
 * a fake API in the verifier (ingest/verify/shopify-scripts.mjs).
 */
import { execFileSync } from "node:child_process";

const TOPICS = ["CUSTOMERS_CREATE", "CUSTOMERS_UPDATE", "CUSTOMERS_DELETE", "ORDERS_CREATE", "ORDERS_UPDATED", "ORDERS_CANCELLED", "ORDERS_DELETE"];
const usage = [
  "usage: node docs/ingest/shopify-subscribe.mjs --project <gcp project> --shop <handle>.myshopify.com --client-id <id> --secret-name <client secret> --url <full webhook url> [--api-version 2026-10]",
  "       … (the same first four) --list [--url <full webhook url>]",
  "       … (the same first four) --delete <subscription id>",
  "       … (the same first four) --source-names [--days <1-60>]",
].join("\n");

function arg(name) {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : undefined;
}
const flag = (name) => process.argv.includes(`--${name}`);
function fail(message, code = 1) {
  console.error(message);
  process.exit(code);
}

const project = arg("project");
const shop = (arg("shop") ?? "").trim().toLowerCase();
const clientId = (arg("client-id") ?? "").trim();
const secretName = arg("secret-name");
const url = arg("url");
const version = arg("api-version") ?? "2026-10";
const list = flag("list");
const del = arg("delete");
const sources = flag("source-names");
const days = arg("days") === undefined ? 30 : Number(arg("days"));
const modes = [list, del !== undefined, sources].filter(Boolean).length;
if (!project || !/^[a-z][a-z0-9-]{4,29}$/.test(project) || !/^[a-z0-9][a-z0-9-]{0,59}\.myshopify\.com$/.test(shop)
    || !/^[A-Za-z0-9_-]{8,100}$/.test(clientId) || !secretName || !/^[A-Za-z0-9_-]{1,255}$/.test(secretName) || modes > 1) fail(usage, 2);
if (!/^\d{4}-(01|04|07|10)$/.test(version)) fail(`--api-version ${version} is not a Shopify API version (YYYY-01, -04, -07 or -10)`, 2);
if (!Number.isInteger(days) || days < 1 || days > 60) fail("--days is a whole number from 1 to 60", 2);
const mode = list ? "list" : del !== undefined ? "delete" : sources ? "sources" : "create";
if (mode === "create" && !url) fail(usage, 2);
if (mode === "delete" && !/^(gid:\/\/shopify\/WebhookSubscription\/)?\d{1,20}$/.test(del ?? "")) fail(`--delete takes a subscription id (as --list prints it)\n${usage}`, 2);
if (url !== undefined) {
  let u;
  try {
    u = new URL(url);
  } catch {
    fail(`--url ${url} is not a URL`, 2);
  }
  if (u.protocol !== "https:" || !/^\/shopify\/[A-Za-z0-9_-]{24,64}$/.test(u.pathname) || u.search || u.hash) {
    fail("--url must be https://<host>/shopify/<connection key>, without a query (the webhook address of PROD_RUNBOOK 9.7)", 2);
  }
}

let base = `https://${shop}`;
if (process.env.INGEST_SHOPIFY_API_BASE) {
  const b = new URL(process.env.INGEST_SHOPIFY_API_BASE.replace("{shop}", shop));
  if (b.protocol !== "https:" && !(b.protocol === "http:" && ["127.0.0.1", "localhost"].includes(b.hostname))) fail("INGEST_SHOPIFY_API_BASE must be https", 2);
  base = `${b.origin}${b.pathname.replace(/\/+$/, "")}`;
}

let secret;
try {
  secret = execFileSync("gcloud", ["secrets", "versions", "access", "latest", `--secret=${secretName}`, `--project=${project}`],
    { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] }).replace(/\r?\n$/, "");
} catch {
  fail(`could not read ${secretName} (gcloud secrets versions access)`);
}
if (!secret) fail(`${secretName} is empty`);

// The store token by the client credentials grant; held for this run only
let token;
{
  const res = await fetch(`${base}/admin/oauth/access_token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
    body: new URLSearchParams({ grant_type: "client_credentials", client_id: clientId, client_secret: secret }).toString(),
  }).catch(() => null);
  secret = null;
  if (!res) fail(`${shop} did not answer the token request`);
  const body = await res.json().catch(() => null);
  if (!res.ok || typeof body?.access_token !== "string") {
    fail(`${shop} refused the token (${res.status}${typeof body?.error === "string" ? ` ${body.error}` : ""}): the client id, the client secret, or a store outside the app's organisation`);
  }
  token = body.access_token;
}

/** One GraphQL request: data, or the run stops with Shopify's error messages (never the token). */
async function gql(query, variables = {}) {
  const res = await fetch(`${base}/admin/api/${version}/graphql.json`, {
    method: "POST", headers: { "content-type": "application/json", accept: "application/json", "x-shopify-access-token": token },
    body: JSON.stringify({ query, variables }),
  }).catch(() => null);
  if (!res) fail(`${shop} did not answer`);
  const body = await res.json().catch(() => null);
  if (!res.ok || !body?.data) fail(`Shopify answered ${res.status}: ${(body?.errors ?? []).map((e) => e?.message).filter(Boolean).join("; ").slice(0, 300) || "no data"}`);
  return body.data;
}

async function subscriptions() {
  const out = [];
  let after = null;
  for (let i = 0; i < 10; i += 1) {
    const d = await gql(`query ($after: String) { webhookSubscriptions(first: 100, after: $after) { nodes { id topic uri } pageInfo { hasNextPage endCursor } } }`, { after });
    out.push(...(d.webhookSubscriptions?.nodes ?? []));
    if (!d.webhookSubscriptions?.pageInfo?.hasNextPage) break;
    after = d.webhookSubscriptions.pageInfo.endCursor;
  }
  return out;
}

if (mode === "list") {
  const all = await subscriptions();
  for (const s of all) console.log(`${url && s.uri === url ? "* " : "  "}${s.id}  ${s.topic}  ${s.uri}`);
  console.error(`-- ${all.length} subscription(s) of ${shop}${url ? "; * marks those for --url" : ""}`);
  process.exit(0);
}

if (mode === "delete") {
  const id = del.startsWith("gid://") ? del : `gid://shopify/WebhookSubscription/${del}`;
  const d = await gql(`mutation ($id: ID!) { webhookSubscriptionDelete(id: $id) { deletedWebhookSubscriptionId userErrors { field message } } }`, { id });
  const errors = d.webhookSubscriptionDelete?.userErrors ?? [];
  if (errors.length || !d.webhookSubscriptionDelete?.deletedWebhookSubscriptionId) fail(`not deleted: ${errors.map((e) => e.message).join("; ") || "no id answered"}`);
  console.log(`deleted ${d.webhookSubscriptionDelete.deletedWebhookSubscriptionId}`);
  process.exit(0);
}

if (mode === "sources") {
  const since = new Date(Date.now() - days * 86_400_000).toISOString().replace(/\.\d{3}Z$/, "Z");
  const counts = new Map();
  let after = null;
  let n = 0;
  for (let page = 0; page < 4; page += 1) {
    const d = await gql(`query ($q: String!, $after: String) { orders(first: 250, after: $after, query: $q, sortKey: CREATED_AT, reverse: true) {
      nodes { sourceName app { id name } } pageInfo { hasNextPage endCursor } } }`, { q: `created_at:>='${since}'`, after });
    for (const o of d.orders?.nodes ?? []) {
      const appId = typeof o.app?.id === "string" ? o.app.id.split("/").pop() : "";
      const k = `${o.sourceName ?? ""}\t${appId}\t${o.app?.name ?? ""}`;
      counts.set(k, (counts.get(k) ?? 0) + 1);
      n += 1;
    }
    if (!d.orders?.pageInfo?.hasNextPage) break;
    after = d.orders.pageInfo.endCursor;
  }
  console.log("orders\tsource name\tapp id\tapp name");
  for (const [k, c] of [...counts].sort((a, b) => b[1] - a[1])) console.log(`${c}\t${k}`);
  console.error(`-- ${n} order(s) of ${shop} since ${since}. The subscription app's renewals show as one source name or app id with many orders; Shopify's own checkout is web, the point of sale pos`);
  process.exit(0);
}

// Create: each topic once at this address
const existing = (await subscriptions()).filter((s) => s.uri === url);
for (const topic of TOPICS) {
  const there = existing.find((s) => s.topic === topic);
  if (there) {
    console.log(`exists   ${there.id}  ${topic}`);
    continue;
  }
  const d = await gql(`mutation ($topic: WebhookSubscriptionTopic!, $uri: String!) { webhookSubscriptionCreate(topic: $topic, webhookSubscription: { uri: $uri }) {
    webhookSubscription { id topic } userErrors { field message } } }`, { topic, uri: url });
  const errors = d.webhookSubscriptionCreate?.userErrors ?? [];
  const created = d.webhookSubscriptionCreate?.webhookSubscription;
  if (errors.length || !created?.id) fail(`${topic} not created: ${errors.map((e) => e.message).join("; ") || "no id answered"}`);
  console.log(`created  ${created.id}  ${topic}`);
}
token = null;
console.error(`-- ${TOPICS.length} topics at the connection's address. The nightly reconcile checks them and recreates one Shopify deleted after failed deliveries`);
