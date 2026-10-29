/**
 * Juo's Admin API for one subscriptions connection (addition 0008zl, brief B20). Read only: the adapter sends GET
 * requests, and nothing is ever written to Juo.
 *
 *   key       the store's Admin API key, from the Secret Manager secret the connection's token secret name names
 *             (ingest-juo-<handle>-key): the header X-Juo-Admin-Api-Key. Keys are per store. A missing secret fails
 *             the read with token_unavailable
 *   store     the header X-Tenant-ID, the connection's account id: the store's own domain, <handle>.myshopify.com
 *             (lower case; another form fails with tenant_id_invalid before any request). A key answers 401 for
 *             another store's id: the read fails key_rejected
 *   requests  GET https://api.juo.io/admin/v1/<path>, each one counted per endpoint on the job's budget (ids replaced,
 *             no query value: the run's log line) and paced per connection and process at the connection setting
 *             subscriptions_max_per_second (default 2, 1 to 10). Juo states no rate limit (no rate-limit header was
 *             seen on a GET, 28 October 2026). A 429 holds the connection until its Retry-After (seconds or a date, at
 *             most a minute; five seconds without one) and the same request is sent again once the hold has passed, at
 *             most twice: a third 429 fails the read (rate_limited), and the next run carries on
 *   paging    cursor paging: { data, hasNextPage, endCursor }; the next page with after=<endCursor>
 *
 * INGEST_JUO_API_BASE replaces the host for a fake (the verifiers, a local run): https, or http on the local machine.
 * No redirect is followed, so the key goes to that host only. Errors carry a code only, never a body:
 * token_unavailable, tenant_id_invalid, key_rejected, rate_limited, timeout, unreachable, bad_response, http_<status>.
 */
import { getSecret, SecretUnavailable } from "../../core/secrets.mjs";
import { requestJson, checkedBase, SourceError } from "../../core/http.mjs";
import { Pace, paceFactor } from "../../core/pace.mjs";
import { warn } from "../../core/log.mjs";

const PER_CALL_MS = 20_000;
/** The holds after a 429: the source's Retry-After, at most a minute; five seconds without one */
export const HOLD_DEFAULT_MS = 5_000;
export const HOLD_MAX_MS = 60_000;
/** A request is sent at most this often when the source answers 429 */
export const MAX_ATTEMPTS = 3;
/** The store's own domain, as Juo names a tenant: <handle>.myshopify.com */
const STORE = /^[a-z0-9][a-z0-9-]{0,59}\.myshopify\.com$/;

function apiBase() {
  return `${checkedBase(process.env.INGEST_JUO_API_BASE ?? "https://api.juo.io")}/admin/v1`;
}

// ---- Settings ------------------------------------------------------------------------------------
const WHOLE = {
  subscriptions_poll_interval_minutes: { default: 5, min: 1, max: 60 },
  subscriptions_max_per_second: { default: 2, min: 1, max: 10 },
};

function whole(settings, name, fallbacks) {
  const v = settings?.[name];
  const n = typeof v === "number" ? v : typeof v === "string" && /^\d{1,6}$/.test(v.trim()) ? Number(v) : NaN;
  const { min, max } = WHOLE[name];
  if (Number.isInteger(n) && n >= min && n <= max) return n;
  if (v !== undefined && v !== null && v !== "") fallbacks.push(name);
  return WHOLE[name].default;
}

/**
 * The connection's settings for the adapter: its pace and its poll interval. A value out of range (or out of its
 * form) takes the default and is named in fallbacks, which the run logs once (cma.set_connection_settings refuses
 * both out of range since 0008zl; this guards a value stored before).
 */
export function juoSettings(settings) {
  const fallbacks = [];
  return {
    perSecond: whole(settings, "subscriptions_max_per_second", fallbacks),
    intervalMinutes: whole(settings, "subscriptions_poll_interval_minutes", fallbacks),
    fallbacks,
  };
}

/** The store's id Juo takes as X-Tenant-ID: the connection's account id in lower case; SourceError tenant_id_invalid otherwise. */
export function tenantIdOf(connection) {
  const v = String(connection?.externalAccountId ?? "").trim().toLowerCase();
  if (!STORE.test(v)) throw new SourceError("tenant_id_invalid");
  return v;
}

/** The store's handle: the account id up to its first dot (cma.subscription_store_connection_of matches the same). */
export const handleOf = (connection) => tenantIdOf(connection).split(".")[0];

// ---- Pace ----------------------------------------------------------------------------------------
const paces = new Map(); // connection id → { perSecond, pace } (per process)

function paceOf(connectionId, perSecond) {
  const hit = paces.get(connectionId);
  if (hit && hit.perSecond === perSecond) return hit.pace;
  const pace = new Pace(1000 / perSecond);
  if (hit) pace.holdUntil(hit.pace.next);
  paces.set(connectionId, { perSecond, pace });
  return pace;
}

/**
 * The hold after a 429, in milliseconds: Retry-After in seconds or as an HTTP date, at most a minute; five seconds
 * without one. Scaled by INGEST_PACE_FACTOR as every interval is (a verifier against a fake; never set on Cloud Run).
 */
export function holdMsOf(rateLimit, now = Date.now()) {
  const v = rateLimit?.["retry-after"];
  const s = Number(v);
  const ms = v !== undefined && Number.isFinite(s) && s >= 0 ? s * 1000
    : v !== undefined && Number.isFinite(Date.parse(v)) ? Date.parse(v) - now : HOLD_DEFAULT_MS;
  return Math.min(Math.max(ms, 0), HOLD_MAX_MS) * paceFactor();
}

/** The path as its endpoint template for the counts: the query left out, every id replaced (GET /subscriptions/{id}). */
export function endpointOf(method, path) {
  return `${method} ${path.split("?")[0].replace(/\/[0-9a-f]{8}-[0-9a-f-]{27,}/gi, "/{id}")}`;
}

/**
 * The Admin API of one connection, every call paced (per connection), counted and bound to the budget. settings: the
 * connection's settings (the pace).
 */
export function juoClient(connection, settings, budget) {
  const base = apiBase();
  const tenantId = tenantIdOf(connection);
  const pace = paceOf(connection.connectionId, juoSettings(settings).perSecond);
  const call = async (path) => {
    let key;
    try {
      key = await getSecret(connection.tokenSecretName);
    } catch (err) {
      throw new SourceError(err instanceof SecretUnavailable ? "token_unavailable" : "secret_error");
    }
    for (let attempt = 1; ; attempt += 1) {
      await pace.wait();
      budget.count?.(endpointOf("GET", path));
      try {
        return await requestJson(`${base}${path}`, { headers: { "x-juo-admin-api-key": key, "x-tenant-id": tenantId }, signal: budget.signal(PER_CALL_MS) });
      } catch (err) {
        if (err instanceof SourceError && err.code === "http_401") throw new SourceError("key_rejected", 401);
        if (!(err instanceof SourceError && err.code === "rate_limited")) throw err;
        const holdMs = holdMsOf(err.rateLimit);
        pace.holdUntil(Date.now() + holdMs);
        warn("juo rate limited", { connection: connection.connectionId, code: "rate_limited", attempt, resumeInMs: Math.round(holdMs),
          retried: attempt < MAX_ATTEMPTS });
        if (attempt >= MAX_ATTEMPTS) throw err;
      }
    }
  };
  return { get: call };
}

/** Test aid: forget the paces of this process. */
export function resetClients() {
  paces.clear();
}
