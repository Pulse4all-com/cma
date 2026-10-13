/**
 * Verifier: the Shopify Admin API client (src/adapters/shopify/client.mjs): the client credentials
 * token and its cache, the cost bucket, and how answers are classified. Against a fake Shopify on
 * localhost; no database, no real Shopify. Everything is invented.
 *
 *   node verify/shopify-client.mjs             every check must PASS
 *   node verify/shopify-client.mjs --provoke   every check must FAIL
 */
import http from "node:http";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, verdict, PROVOKE } from "./lib.mjs";

console.log(`verify/shopify-client.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

const SHOP = "client-a.myshopify.com";
const SECRET = "fixture-client-secret-0001";
const CLIENT = "fixtureclientid0001";
const fake = { mints: 0, expiresIn: 86399, answer: null, requests: [], delay: 0 };
const server = http.createServer((req, res) => {
  let data = "";
  req.on("data", (c) => { data += c; });
  req.on("end", async () => {
    const json = (status, body) => { res.writeHead(status, { "content-type": "application/json" }); res.end(JSON.stringify(body)); };
    fake.requests.push({ path: req.url, token: req.headers["x-shopify-access-token"], t: Date.now() });
    if (fake.delay) await new Promise((r) => setTimeout(r, fake.delay));
    if (req.url === `/shop/${SHOP}/admin/oauth/access_token`) {
      const f = new URLSearchParams(data);
      if (f.get("client_secret") !== SECRET || f.get("client_id") !== CLIENT || f.get("grant_type") !== "client_credentials") return json(400, { error: "invalid_client" });
      fake.mints += 1;
      return json(200, { access_token: `shpat_fixture_${fake.mints}`, scope: "read_customers,read_orders", expires_in: fake.expiresIn });
    }
    if (req.url === `/shop/${SHOP}/admin/api/2026-10/graphql.json`) {
      if (!String(req.headers["x-shopify-access-token"] ?? "").startsWith("shpat_fixture_")) return json(401, { errors: "invalid token" });
      const a = fake.answer ?? { data: { ok: true }, extensions: { cost: { requestedQueryCost: 10, actualQueryCost: 5, throttleStatus: { maximumAvailable: 1000, currentlyAvailable: 995, restoreRate: 100 } } } };
      if (a.status) return json(a.status, a.body ?? {});
      return json(200, a);
    }
    json(404, {});
  });
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const secretsDir = mkdtempSync(path.join(tmpdir(), "shopify-client-"));
writeFileSync(path.join(secretsDir, "ingest-shopify-verify-signing"), SECRET);
process.env.INGEST_SECRETS_DIR = secretsDir;
process.env.INGEST_SHOPIFY_API_BASE = `http://127.0.0.1:${server.address().port}/shop/{shop}`;

const { shopifyClient, tokenFor, resetClients, bucketOf, availableNow, waitFor, shopBase } = await import("../src/adapters/shopify/client.mjs");
const { Budget, JobBudget } = await import("../src/core/budget.mjs");
const connection = { connectionId: "c1", externalAccountId: SHOP, signingSecretName: "ingest-shopify-verify-signing" };
const settings = { client_id: CLIENT, api_version: "2026-10" };
const codeOf = async (p) => p.then(() => "ok", (e) => e.code ?? e.name);

// ---- The token ---------------------------------------------------------------------------------------
const tokens = await Promise.all([1, 2, 3, 4, 5].map(() => tokenFor(connection, settings, AbortSignal.timeout(2000))));
expect("five callers at once: one token minted, all get it", [fake.mints, new Set(tokens).size], [1, 1], [5, 5]);
expect("…sent form-encoded with the client id and secret (the fake refuses otherwise)", tokens[0], "shpat_fixture_1", null);
expect("a second call reuses the cached token", [await tokenFor(connection, settings, AbortSignal.timeout(2000)), fake.mints], ["shpat_fixture_1", 1], ["shpat_fixture_2", 2]);
const later = Date.now() + 86399_000 - 4 * 60_000; // four minutes before expiry: inside the five-minute margin
expect("within five minutes of its expiry the token is minted again", [await tokenFor(connection, settings, AbortSignal.timeout(2000), later), fake.mints], ["shpat_fixture_2", 2], ["shpat_fixture_1", 1]);
const earlier = Date.now() + 86399_000 - 6 * 60_000;
expect("…six minutes before, it is still used", [await tokenFor(connection, settings, AbortSignal.timeout(2000), earlier), fake.mints], ["shpat_fixture_2", 2], ["shpat_fixture_3", 3]);
expect("no client id setting → client_id_not_set", await codeOf(tokenFor(connection, {}, AbortSignal.timeout(2000))), "client_id_not_set", "ok");
resetClients();
expect("another client id → the token request refused (token_http_400)", await codeOf(tokenFor(connection, { client_id: "anotherclientid01" }, AbortSignal.timeout(2000))), "token_http_400", "ok");
expect("a missing client secret → client_secret_unavailable", await codeOf(tokenFor({ ...connection, signingSecretName: "ingest-shopify-missing" }, settings, AbortSignal.timeout(2000))), "client_secret_unavailable", "ok");
expect("a shop that is not <handle>.myshopify.com → shop_invalid", (() => { try { shopBase("evil.example.com"); return "ok"; } catch (e) { return e.code; } })(), "shop_invalid", "ok");

// ---- Answers -------------------------------------------------------------------------------------------
resetClients();
// a fresh webhook budget per call: the checks below take longer than one budget together
const api = { query: (...a) => shopifyClient(connection, settings, new Budget(1500)).query(...a) };
expect("a query answers its data, at version 2026-10 with the shop's token", [await api.query("query X { ok }"), fake.requests.at(-1).path.endsWith("/admin/api/2026-10/graphql.json"), fake.requests.at(-1).token?.startsWith("shpat_fixture_")],
  [{ ok: true }, true, true], [null, false, false]);
expect("the bucket learns the shop's restore rate and maximum from throttleStatus", [bucketOf(SHOP).restore, bucketOf(SHOP).max], [100, 1000], [50, 0]);
fake.answer = { errors: [{ message: "Throttled", extensions: { code: "THROTTLED" } }], extensions: { cost: { throttleStatus: { maximumAvailable: 1000, currentlyAvailable: 3, restoreRate: 100 } } } };
expect("a THROTTLED answer → rate_limited, the estimate emptied", [await codeOf(api.query("query X { ok }")), Math.round(availableNow(bucketOf(SHOP)))], ["rate_limited", 0], ["ok", 1000]);
fake.answer = { data: { node: { defaultEmailAddress: null } }, errors: [{ message: "Access denied for emailAddress field.", path: ["node", "defaultEmailAddress"], extensions: { code: "ACCESS_DENIED" } }] };
expect("a withheld protected field (ACCESS_DENIED) → the data with the field null, nothing fails", await codeOf(api.query("query X { ok }")), "ok", "graphql_error");
fake.answer = { errors: [{ message: "Internal error", extensions: { code: "INTERNAL_SERVER_ERROR" } }] };
expect("another error without data → graphql_error", await codeOf(api.query("query X { ok }")), "graphql_error", "ok");
fake.answer = { status: 401 };
const minted = fake.mints;
expect("a 401 → http_401 and the token dropped (the next call mints)", [await codeOf(api.query("query X { ok }")), (fake.answer = null, await codeOf(api.query("query X { ok }"))), fake.mints - minted], ["http_401", "ok", 1], ["ok", "ok", 0]);
fake.answer = { status: 429 };
expect("a 429 → rate_limited", await codeOf(api.query("query X { ok }")), "rate_limited", "ok");
fake.answer = null;

// ---- The cost bucket -----------------------------------------------------------------------------------------
resetClients();
const b = bucketOf(SHOP);
b.available = 0;
b.at = Date.now();
b.restore = 100;
expect("waitFor: 300 points at 100 a second from empty → 3 seconds", waitFor(b, 300), 3000, 0);
const webhook = shopifyClient(connection, settings, new Budget(1500));
let t0 = Date.now();
expect("a webhook never waits past its budget: 300 points short → throttled at once", [await codeOf(webhook.query("query X { ok }", {}, 300)), Date.now() - t0 < 200], ["throttled", true], ["ok", false]);
b.available = 0;
b.at = Date.now();
t0 = Date.now();
expect("…a short wait that leaves a second of its budget is waited for", [await codeOf(shopifyClient(connection, settings, new Budget(1500)).query("query X { ok }", {}, 30)), Date.now() - t0 >= 250], ["ok", true], ["throttled", false]);
b.available = 0;
b.at = Date.now();
b.restore = 1000;
t0 = Date.now();
const job = shopifyClient(connection, settings, new JobBudget());
expect("a job waits for the refill instead (500 points at 1000 a second: about half a second)", [await codeOf(job.query("query X { ok }", {}, 500)), Date.now() - t0 >= 400], ["ok", true], ["throttled", false]);
resetClients();
const q = bucketOf(SHOP);
q.available = 100;
q.at = Date.now();
q.restore = 1000;
fake.delay = 0;
const queued = await Promise.all([1, 2, 3].map(() => shopifyClient(connection, settings, new JobBudget()).query("query X { ok }", {}, 100).then(() => Date.now())));
expect("three callers sharing a bucket of 100 at 1000 a second queue behind each other (reserved before the wait)", queued[2] - queued[0] >= 150, true, false);

await new Promise((r) => server.close(r));
rmSync(secretsDir, { recursive: true, force: true });
verdict();
