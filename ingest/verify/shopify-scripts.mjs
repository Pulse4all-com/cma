/**
 * Verifier: docs/ingest/shopify-subscribe.mjs against a fake Shopify (token grant and GraphQL) and a
 * fake `gcloud` on PATH that serves secrets from files. No network beyond localhost, no database, no
 * real gcloud. Everything is invented.
 *
 *   node verify/shopify-scripts.mjs             every check must PASS
 *   node verify/shopify-scripts.mjs --provoke   every check must FAIL
 */
import http from "node:http";
import { mkdtempSync, writeFileSync, rmSync, chmodSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { expect, verdict, PROVOKE } from "./lib.mjs";

console.log(`verify/shopify-scripts.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

const here = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = path.join(here, "../../docs/ingest/shopify-subscribe.mjs");
const PROJECT = "p4a-cma-verify";
const SHOP = "verify-shop.myshopify.com";
const CLIENT = "fixtureclientid0001";
const SECRET = "fixture-client-secret-0001";
const URL_OK = "https://ingest.example.com/shopify/key00000000000000000000000001";
const TOPICS = ["CUSTOMERS_CREATE", "CUSTOMERS_UPDATE", "CUSTOMERS_DELETE", "ORDERS_CREATE", "ORDERS_UPDATED", "ORDERS_CANCELLED", "ORDERS_DELETE"];

// ---- The fake gcloud ---------------------------------------------------------------------------------
const dir = mkdtempSync(path.join(tmpdir(), "shopify-scripts-"));
const secrets = path.join(dir, "secrets");
mkdirSync(secrets);
writeFileSync(path.join(dir, "gcloud"), `#!/bin/bash
d="${secrets}"
name=""; for a in "$@"; do case "$a" in --secret=*) name="\${a#--secret=}";; esac; done
if [ "$1 $2 $3" = "secrets versions access" ]; then cat "$d/$name" 2>/dev/null || exit 1; exit 0; fi
exit 3
`);
chmodSync(path.join(dir, "gcloud"), 0o755);
writeFileSync(path.join(secrets, "ingest-shopify-app-signing"), `${SECRET}\n`);

// ---- The fake Shopify ----------------------------------------------------------------------------------
const fake = { subs: [], requests: [], mints: 0, orders: [] };
let seq = 0;
const server = http.createServer((req, res) => {
  let data = "";
  req.on("data", (c) => { data += c; });
  req.on("end", () => {
    const json = (status, body) => { res.writeHead(status, { "content-type": "application/json" }); res.end(JSON.stringify(body)); };
    fake.requests.push({ path: req.url, token: req.headers["x-shopify-access-token"], body: data });
    if (req.url === `/shop/${SHOP}/admin/oauth/access_token`) {
      const f = new URLSearchParams(data);
      if (f.get("client_id") !== CLIENT || f.get("client_secret") !== SECRET || f.get("grant_type") !== "client_credentials") return json(400, { error: "invalid_client" });
      fake.mints += 1;
      return json(200, { access_token: "shpat_fixture_script_0001", scope: "read_customers,read_orders", expires_in: 86399 });
    }
    if (req.url !== `/shop/${SHOP}/admin/api/2026-10/graphql.json`) return json(404, {});
    if (req.headers["x-shopify-access-token"] !== "shpat_fixture_script_0001") return json(401, { errors: "invalid" });
    const { query, variables } = JSON.parse(data);
    if (/webhookSubscriptionCreate/.test(query)) {
      seq += 1;
      const s = { id: `gid://shopify/WebhookSubscription/${7700000000 + seq}`, topic: variables.topic, uri: variables.uri };
      fake.subs.push(s);
      return json(200, { data: { webhookSubscriptionCreate: { webhookSubscription: { id: s.id, topic: s.topic }, userErrors: [] } } });
    }
    if (/webhookSubscriptionDelete/.test(query)) {
      const before = fake.subs.length;
      fake.subs = fake.subs.filter((s) => s.id !== variables.id);
      return json(200, { data: { webhookSubscriptionDelete: before === fake.subs.length
        ? { deletedWebhookSubscriptionId: null, userErrors: [{ field: ["id"], message: "Webhook subscription does not exist" }] }
        : { deletedWebhookSubscriptionId: variables.id, userErrors: [] } } });
    }
    if (/webhookSubscriptions\(/.test(query)) return json(200, { data: { webhookSubscriptions: { nodes: fake.subs, pageInfo: { hasNextPage: false, endCursor: null } } } });
    if (/orders\(/.test(query)) return json(200, { data: { orders: { nodes: fake.orders, pageInfo: { hasNextPage: false, endCursor: null } } } });
    json(200, { errors: [{ message: "unknown" }] });
  });
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const BASE = `http://127.0.0.1:${server.address().port}/shop/{shop}`;

function run(argv) {
  return new Promise((resolve) => {
    const p = spawn(process.execPath, [SCRIPT, ...argv], { env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, INGEST_SHOPIFY_API_BASE: BASE } });
    let out = "";
    let err = "";
    p.stdout.on("data", (c) => { out += c; });
    p.stderr.on("data", (c) => { err += c; });
    p.on("close", (code) => resolve({ code, out, err }));
  });
}
const common = (o = {}) => ["--project", PROJECT, "--shop", o.shop ?? SHOP, "--client-id", o.client ?? CLIENT, "--secret-name", o.secret ?? "ingest-shopify-app-signing"];
const shown = (r) => [SECRET, "shpat_fixture_script_0001"].some((t) => r.out.includes(t) || r.err.includes(t));

let r = await run([...common(), "--url", "http://ingest.example.com/shopify/key00000000000000000000000001"]);
expect("a URL that is not https → usage, nothing asked of Shopify", [r.code, fake.requests.length], [2, 0], [0, 1]);
r = await run([...common(), "--url", "https://ingest.example.com/aircall/key00000000000000000000000001"]);
expect("a URL that is not /shopify/<key> → usage", r.code, 2, 0);
r = await run([...common(), "--url", `${URL_OK}?email=someone@example.com`]);
expect("a URL with a query → usage (no personal data in the address)", r.code, 2, 0);
r = await run([...common({ shop: "verify-shop.example.com" }), "--url", URL_OK]);
expect("a shop that is not <handle>.myshopify.com → usage", r.code, 2, 0);
r = await run([...common(), "--url", URL_OK, "--api-version", "2026-11"]);
expect("an API version that is not a release → usage", r.code, 2, 0);
r = await run([...common({ client: "anotherclient01" }), "--url", URL_OK]);
expect("another client id → the token refused, nothing created", [r.code, /refused the token \(400 invalid_client\)/.test(r.err), fake.subs.length], [1, true, 0], [0, false, 7]);
r = await run([...common({ secret: "ingest-shopify-missing" }), "--url", URL_OK]);
expect("a secret that cannot be read → stops before Shopify", [r.code, /could not read ingest-shopify-missing/.test(r.err)], [1, true], [0, false]);

r = await run([...common(), "--url", URL_OK]);
expect("create: the seven topics at the address, by the client credentials grant", [r.code, fake.subs.map((s) => s.topic), fake.subs.every((s) => s.uri === URL_OK)], [0, TOPICS, true], [1, [], false]);
expect("…the token request form-encoded at /admin/oauth/access_token, GraphQL at 2026-10", [fake.requests.some((x) => x.path.endsWith("/admin/oauth/access_token")), fake.requests.some((x) => x.path.endsWith("/admin/api/2026-10/graphql.json"))], [true, true], [false, false]);
expect("…subscribed with uri (not the deprecated callbackUrl)", fake.requests.filter((x) => /webhookSubscriptionCreate/.test(x.body)).every((x) => /uri: \$uri/.test(JSON.parse(x.body).query)), true, false);
expect("…prints ids and topics only, never the secret or the token", [r.out.split("\n").filter(Boolean).every((l) => /^created {2}gid:\/\/shopify\/WebhookSubscription\/\d+ {2}[A-Z_]+$/.test(l)), shown(r)], [true, false], [false, true]);
r = await run([...common(), "--url", URL_OK]);
expect("a rerun creates nothing and lists the seven as existing", [r.code, fake.subs.length, r.out.split("\n").filter((l) => l.startsWith("exists")).length], [0, 7, 7], [0, 14, 0]);
fake.subs = fake.subs.filter((s) => s.topic !== "ORDERS_UPDATED");
r = await run([...common(), "--url", URL_OK]);
expect("a missing topic is created again, the others left", [r.code, fake.subs.filter((s) => s.topic === "ORDERS_UPDATED").length, fake.subs.length], [0, 1, 7], [0, 0, 6]);
fake.subs.push({ id: "gid://shopify/WebhookSubscription/7799999999", topic: "ORDERS_CREATE", uri: "https://elsewhere.example.com/hook" });
r = await run([...common(), "--list", "--url", URL_OK]);
expect("--list: every subscription, those of --url marked", [r.code, r.out.split("\n").filter((l) => l.startsWith("* ")).length, r.out.includes("  gid://shopify/WebhookSubscription/7799999999  ORDERS_CREATE  https://elsewhere.example.com/hook"), shown(r)],
  [0, 7, true, false], [1, 0, false, true]);
r = await run([...common(), "--delete", "7799999999"]);
expect("--delete <numeric id> deletes that subscription", [r.code, fake.subs.some((s) => s.id.endsWith("7799999999")), r.out.trim()], [0, false, "deleted gid://shopify/WebhookSubscription/7799999999"], [1, true, ""]);
r = await run([...common(), "--delete", "7799999999"]);
expect("…a second delete of it fails with Shopify's message", [r.code, /does not exist/.test(r.err)], [1, true], [0, false]);
r = await run([...common(), "--delete", "not-an-id"]);
expect("--delete with something that is not an id → usage", r.code, 2, 0);
fake.orders = [
  ...Array.from({ length: 5 }, () => ({ sourceName: "web", app: { id: "gid://shopify/App/580111", name: "Online Store" } })),
  ...Array.from({ length: 12 }, () => ({ sourceName: "subscription_contract", app: { id: "gid://shopify/App/9900001", name: "Invented Subscriptions" } })),
  { sourceName: "pos", app: null },
];
r = await run([...common(), "--source-names", "--days", "14"]);
expect("--source-names: counts per source name and app, the most frequent first", [r.code, r.out.split("\n")[1], r.out.split("\n")[2]], [0, "12\tsubscription_contract\t9900001\tInvented Subscriptions", "5\tweb\t580111\tOnline Store"], [1, "", ""]);
const ordersQuery = JSON.parse(fake.requests.findLast((x) => /orders\(/.test(x.body))?.body ?? "{}");
expect("…asks for the source name and the app only, created in the last --days days", [/nodes \{ sourceName app \{ id name \} \}/.test(ordersQuery.query ?? ""), /^created_at:>='\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z'$/.test(ordersQuery.variables?.q ?? "")], [true, true], [false, false]);
r = await run([...common(), "--source-names", "--days", "90"]);
expect("--days beyond 60 → usage", r.code, 2, 0);
r = await run([...common(), "--list", "--source-names"]);
expect("two modes at once → usage", r.code, 2, 0);

await new Promise((res) => server.close(res));
rmSync(dir, { recursive: true, force: true });
verdict();
