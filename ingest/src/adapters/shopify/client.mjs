/**
 * The Shopify Admin GraphQL API for one store connection (DESIGN §2, §5; shopify.dev, checked
 * 13 October 2026):
 *
 *   token     the client credentials grant: POST https://<shop>/admin/oauth/access_token with
 *             grant_type=client_credentials, the app's client id (connection setting client_id, not a
 *             secret) and its client secret (the connection's signing secret: Shopify signs webhooks
 *             with the same secret), form-encoded; the answer's access_token lives 24 hours
 *             (expires_in 86399). Cached per shop and client id until five minutes before it expires;
 *             one request mints it however many ask at once (a renewal burst). A 401 from the API
 *             drops the cached token. The grant works only for stores in the app's organisation
 *   graphql   POST https://<shop>/admin/api/<version>/graphql.json, the version from the connection
 *             setting api_version (default 2026-10, the latest stable version on 13 October 2026)
 *   cost      Shopify limits GraphQL by query cost per app and store (a bucket of points that refills
 *             at the plan's restore rate; every answer carries extensions.cost.throttleStatus). One
 *             bucket estimate per shop and process: before a call its estimated cost is taken from the
 *             estimate, after the answer the estimate is the answer's currentlyAvailable. The webhook
 *             path never waits for points: a call the bucket cannot pay fails with throttled and the
 *             sweep reads it; a job waits for the refill. A THROTTLED answer or a 429 is rate_limited
 *
 * INGEST_SHOPIFY_API_BASE replaces https://{shop} for a fake API (the flow verifier): a URL with
 * {shop} in it, https, or http on the local machine. Errors carry a code only, never a body.
 */
import { getSecret, SecretUnavailable } from "../../core/secrets.mjs";
import { requestJson, SourceError } from "../../core/http.mjs";
import { warn } from "../../core/log.mjs";

export const DEFAULT_API_VERSION = "2026-10";
const SHOP = /^[a-z0-9][a-z0-9-]{0,59}\.myshopify\.com$/;
const VERSION = /^\d{4}-(01|04|07|10)$/;
const PER_CALL_MS = 4000;
const TOKEN_MARGIN_MS = 5 * 60_000;
const DEFAULT_BUCKET = { max: 1000, restore: 50 };

/** The shop's base URL: https://<handle>.myshopify.com, or the verifier's fake. */
export function shopBase(shop) {
  const domain = String(shop ?? "").trim().toLowerCase();
  if (!SHOP.test(domain)) throw new SourceError("shop_invalid");
  const template = process.env.INGEST_SHOPIFY_API_BASE;
  if (!template) return `https://${domain}`;
  const u = new URL(template.replace("{shop}", domain));
  const local = u.hostname === "127.0.0.1" || u.hostname === "localhost";
  if (u.protocol !== "https:" && !(u.protocol === "http:" && local)) throw new Error("INGEST_SHOPIFY_API_BASE must be https");
  return `${u.origin}${u.pathname.replace(/\/+$/, "")}`;
}

/** The connection's API version (setting api_version, YYYY-01|04|07|10), else the pinned default. */
export function apiVersionOf(settings) {
  const v = typeof settings?.api_version === "string" ? settings.api_version.trim() : "";
  return VERSION.test(v) ? v : DEFAULT_API_VERSION;
}

/** The app's client id (connection setting client_id); SourceError client_id_not_set without one. */
export function clientIdOf(settings) {
  const v = typeof settings?.client_id === "string" ? settings.client_id.trim() : "";
  if (!/^[A-Za-z0-9_-]{8,100}$/.test(v)) throw new SourceError("client_id_not_set");
  return v;
}

// ---- Tokens ----------------------------------------------------------------------------------------
const tokens = new Map(); // shop|client id → { promise, value, expiresAt }

/** Mints a token by the client credentials grant: { value, expiresAt }; SourceError token_<code> otherwise. */
export async function mintToken(shop, clientId, clientSecret, signal) {
  let res;
  try {
    res = await fetch(`${shopBase(shop)}/admin/oauth/access_token`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
      body: new URLSearchParams({ grant_type: "client_credentials", client_id: clientId, client_secret: clientSecret }).toString(),
      signal,
    });
  } catch (err) {
    throw new SourceError(err?.name === "TimeoutError" || err?.name === "AbortError" ? "token_timeout" : "token_unreachable");
  }
  let body = null;
  try {
    body = await res.json();
  } catch {
    body = null;
  }
  if (!res.ok) throw new SourceError(res.status === 429 ? "rate_limited" : `token_http_${res.status}`, res.status);
  const value = typeof body?.access_token === "string" ? body.access_token : "";
  if (!value) throw new SourceError("token_invalid");
  const seconds = Number(body?.expires_in);
  const lifeMs = (Number.isFinite(seconds) && seconds > 0 ? seconds : 86_399) * 1000;
  return { value, expiresAt: Date.now() + lifeMs };
}

/**
 * The shop's current token: the cached one until five minutes before it expires, else a new one (one
 * mint per shop and client id however many callers ask at once).
 */
export async function tokenFor(connection, settings, signal, now = Date.now()) {
  const clientId = clientIdOf(settings);
  const shop = connection.externalAccountId;
  const k = `${shop}|${clientId}`;
  const hit = tokens.get(k);
  if (hit?.value && hit.expiresAt - TOKEN_MARGIN_MS > now) return hit.value;
  if (hit?.promise) return (await hit.promise).value;
  const promise = (async () => {
    let secret;
    try {
      secret = await getSecret(connection.signingSecretName);
    } catch (err) {
      throw new SourceError(err instanceof SecretUnavailable ? "client_secret_unavailable" : "secret_error");
    }
    return mintToken(shop, clientId, secret, signal);
  })();
  tokens.set(k, { promise });
  try {
    const t = await promise;
    tokens.set(k, { value: t.value, expiresAt: t.expiresAt });
    return t.value;
  } catch (err) {
    tokens.delete(k);
    throw err;
  }
}

/** Forgets a shop's token (a 401 answer); the next call mints a new one. */
export function dropToken(connection, settings) {
  try {
    tokens.delete(`${connection.externalAccountId}|${clientIdOf(settings)}`);
  } catch {
    // no client id: nothing cached
  }
}

// ---- The cost bucket --------------------------------------------------------------------------------
const buckets = new Map(); // shop → { max, restore, available, at }

export function bucketOf(shop) {
  if (!buckets.has(shop)) buckets.set(shop, { ...DEFAULT_BUCKET, available: DEFAULT_BUCKET.max, at: Date.now() });
  return buckets.get(shop);
}

/** The points the bucket holds now, refilled since its last known state. */
export function availableNow(b, now = Date.now()) {
  return Math.min(b.max, b.available + ((now - b.at) / 1000) * b.restore);
}

/** Milliseconds until the bucket holds the cost (0 when it does now). */
export function waitFor(b, cost, now = Date.now()) {
  const short = cost - availableNow(b, now);
  return short <= 0 ? 0 : Math.ceil((short / Math.max(1, b.restore)) * 1000);
}

function take(b, cost, now = Date.now()) {
  b.available = availableNow(b, now) - cost;
  b.at = now;
}

function learn(b, throttle, now = Date.now()) {
  const max = Number(throttle?.maximumAvailable);
  const cur = Number(throttle?.currentlyAvailable);
  const restore = Number(throttle?.restoreRate);
  if (Number.isFinite(max) && max > 0) b.max = max;
  if (Number.isFinite(restore) && restore > 0) b.restore = restore;
  // never above the local estimate: calls still in flight have taken their points already
  if (Number.isFinite(cur) && cur >= 0) {
    b.available = Math.min(cur, availableNow(b, now));
    b.at = now;
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Errors of a field the store withholds (protected customer data not granted): the field is null
const WITHHELD = /^(email|phone|defaultEmailAddress|defaultPhoneNumber|emailAddress|phoneNumber)$/;

function classify(errors) {
  const list = Array.isArray(errors) ? errors : [];
  if (list.some((e) => e?.extensions?.code === "THROTTLED")) return "rate_limited";
  if (list.some((e) => e?.extensions?.code === "MAX_COST_EXCEEDED")) return "max_cost_exceeded";
  const other = list.filter((e) => !(e?.extensions?.code === "ACCESS_DENIED" || (Array.isArray(e?.path) && WITHHELD.test(String(e.path.at(-1))))));
  return other.length ? "graphql_error" : null;
}

/**
 * The GraphQL API of one store connection, every call bound to the budget and paid from the shop's
 * cost bucket. budget: the webhook's Budget (no waiting for points) or a job's JobBudget (waits).
 */
export function shopifyClient(connection, settings, budget) {
  const shop = String(connection.externalAccountId ?? "").trim().toLowerCase();
  const version = apiVersionOf(settings);
  const bucket = bucketOf(shop);
  const waits = !Number.isFinite(budget.remaining());

  return {
    version,
    /** One GraphQL request: data, or SourceError (throttled, rate_limited, timeout, http_<status>, graphql_error). */
    async query(text, variables = {}, cost = 10) {
      const need = Math.min(cost, bucket.max);
      const wait = waitFor(bucket, need);
      if (wait > 0) {
        if (!waits) throw new SourceError("throttled");
        await sleep(Math.min(wait, 60_000));
      }
      take(bucket, need);
      const token = await tokenFor(connection, settings, budget.signal(PER_CALL_MS));
      let r;
      try {
        r = await requestJson(`${shopBase(shop)}/admin/api/${version}/graphql.json`, {
          method: "POST", headers: { "x-shopify-access-token": token }, body: { query: text, variables }, signal: budget.signal(PER_CALL_MS),
        });
      } catch (err) {
        if (err instanceof SourceError && err.code === "http_401") dropToken(connection, settings);
        if (err instanceof SourceError && err.code === "rate_limited") {
          // empty the estimate: the next call waits for a refill (or, in a webhook, leaves the read to the sweep)
          bucket.available = 0;
          bucket.at = Date.now();
        }
        throw err;
      }
      learn(bucket, r?.extensions?.cost?.throttleStatus);
      const code = classify(r?.errors);
      if (code === "rate_limited") {
        warn("shopify throttled", { connection: connection.connectionId, code, available: Math.round(availableNow(bucket)) });
        bucket.available = 0;
        bucket.at = Date.now();
      }
      if (code || !r?.data) throw new SourceError(code ?? "graphql_error");
      return r.data;
    },
  };
}

/** Test aid: forget the tokens and buckets of this process. */
export function resetClients() {
  tokens.clear();
  buckets.clear();
}
