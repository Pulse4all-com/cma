/**
 * The eTrusted API (Trusted Shops) for one reviews connection (addition 0008ze, brief B18; prod discovery of
 * 25 October 2026):
 *
 *   token     OAuth2 client credentials: POST https://login.etrusted.com/oauth/token, form-encoded,
 *             grant_type=client_credentials, the API client's id (connection setting client_id, not a secret), its
 *             secret (the connection's token secret, by name) and audience=https://api.etrusted.com. The token lives
 *             300 seconds; it is cached until 30 seconds before it expires, keyed by the connection, its secret's
 *             name and the client id (as the Shopify client, CMA-037), one mint however many ask at once. A 401 from
 *             the API drops it
 *   requests  GET https://api.etrusted.com/<path> with the bearer token, each one counted per endpoint on the job's
 *             budget (the run's log line) and paced per connection at the setting etrusted_max_per_minute (default
 *             60, at most 600): the rate limits are not documented. A 429 holds the connection until its
 *             Retry-After (at most two minutes; one minute without it) and fails the call (rate_limited): the run
 *             ends there and the next one carries on. Nothing retries in a loop
 *
 * INGEST_ETRUSTED_LOGIN_BASE and INGEST_ETRUSTED_API_BASE replace the two hosts for a fake (the verifiers): https,
 * or http on the local machine. Errors carry a code only, never a body.
 */
import { getSecret, SecretUnavailable } from "../../core/secrets.mjs";
import { DEFAULT_REF_PATTERN } from "./map.mjs";
import { requestJson, checkedBase, SourceError } from "../../core/http.mjs";
import { Pace } from "../../core/pace.mjs";
import { warn } from "../../core/log.mjs";

const AUDIENCE = "https://api.etrusted.com";
const PER_CALL_MS = 15_000;
const TOKEN_MARGIN_MS = 30_000;
const HOLD_DEFAULT_MS = 60_000;
const HOLD_MAX_MS = 120_000;

function loginBase() {
  return checkedBase(process.env.INGEST_ETRUSTED_LOGIN_BASE ?? "https://login.etrusted.com");
}

function apiBase() {
  return checkedBase(process.env.INGEST_ETRUSTED_API_BASE ?? "https://api.etrusted.com");
}

// ---- Settings ------------------------------------------------------------------------------------
const WHOLE = {
  etrusted_max_per_minute: { default: 60, min: 1, max: 600 },
  reviews_poll_interval_minutes: { default: 60, min: 1, max: 1440 },
  reviews_reconcile_days: { default: 30, min: 1, max: 365 },
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
 * The connection's transaction_ref_pattern as a regular expression: text of at most 200 characters that compiles;
 * anything else takes the default (map.mjs DEFAULT_REF_PATTERN) and is named in fallbacks. The pattern decides which
 * references are kept; an @ is never kept whatever it says (map.mjs referenceOf).
 */
function refPatternOf(settings, fallbacks) {
  const v = settings?.transaction_ref_pattern;
  if (typeof v === "string" && v.trim() !== "" && v.length <= 200) {
    try {
      return new RegExp(v);
    } catch {
      // falls back below
    }
  }
  if (v !== undefined && v !== null && v !== "") fallbacks.push("transaction_ref_pattern");
  return new RegExp(DEFAULT_REF_PATTERN);
}

/**
 * The connection's settings for the adapter: its pace, poll interval and reconcile window (a value out of range takes
 * the default and is named in fallbacks), whether star-only reviews are asked for (etrusted_include_statements, default
 * true: the API leaves them out unless ignoreStatements=false), the CRM connection the reviewers' emails are matched in,
 * and the pattern a transaction reference must match to be kept (transaction_ref_pattern, addition 0008zf).
 */
export function reviewSettings(settings) {
  const fallbacks = [];
  const statements = settings?.etrusted_include_statements;
  return {
    perMinute: whole(settings, "etrusted_max_per_minute", fallbacks),
    intervalMinutes: whole(settings, "reviews_poll_interval_minutes", fallbacks),
    reconcileDays: whole(settings, "reviews_reconcile_days", fallbacks),
    includeStatements: !(statements === false || statements === "false"),
    crmConnectionId: typeof settings?.crm_connection_id === "string" ? settings.crm_connection_id.trim() : "",
    refPattern: refPatternOf(settings, fallbacks),
    fallbacks,
  };
}

/** The API client's id (connection setting client_id); SourceError client_id_not_set without one. */
export function clientIdOf(settings) {
  const v = typeof settings?.client_id === "string" ? settings.client_id.trim() : "";
  if (!/^[A-Za-z0-9_.:-]{4,200}$/.test(v)) throw new SourceError("client_id_not_set");
  return v;
}

// ---- Tokens --------------------------------------------------------------------------------------
const tokens = new Map(); // connection id|token secret name|client id → { promise, value, expiresAt }
const tokenKey = (connection, clientId) => `${connection.connectionId}|${connection.tokenSecretName ?? ""}|${clientId}`;

/**
 * Mints a token by the client credentials grant: { value, expiresAt }; SourceError token_<code> otherwise. No redirect
 * is followed: the client secret goes to the login host only.
 */
export async function mintToken(clientId, clientSecret, signal) {
  let res;
  try {
    res = await fetch(`${loginBase()}/oauth/token`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
      body: new URLSearchParams({ grant_type: "client_credentials", client_id: clientId, client_secret: clientSecret, audience: AUDIENCE }).toString(),
      signal,
      redirect: "manual",
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
  const lifeMs = (Number.isFinite(seconds) && seconds > 0 ? seconds : 300) * 1000;
  return { value, expiresAt: Date.now() + lifeMs };
}

/** The connection's token: the cached one until 30 seconds before it expires (half its life if shorter), else a new one. */
export async function tokenFor(connection, settings, signal, now = Date.now(), budget = null) {
  const clientId = clientIdOf(settings);
  const k = tokenKey(connection, clientId);
  const hit = tokens.get(k);
  if (hit?.value && hit.expiresAt - hit.margin > now) return hit.value;
  if (hit?.promise) return (await hit.promise).value;
  const promise = (async () => {
    let secret;
    try {
      secret = await getSecret(connection.tokenSecretName);
    } catch (err) {
      throw new SourceError(err instanceof SecretUnavailable ? "client_secret_unavailable" : "secret_error");
    }
    budget?.count?.("POST /oauth/token");
    return mintToken(clientId, secret, signal);
  })();
  tokens.set(k, { promise });
  try {
    const t = await promise;
    tokens.set(k, { value: t.value, expiresAt: t.expiresAt, margin: Math.min(TOKEN_MARGIN_MS, (t.expiresAt - Date.now()) / 2) });
    return t.value;
  } catch (err) {
    tokens.delete(k);
    throw err;
  }
}

/** Forgets a connection's token (a 401 answer); the next call mints a new one. */
export function dropToken(connection, settings) {
  try {
    tokens.delete(tokenKey(connection, clientIdOf(settings)));
  } catch {
    // no client id: nothing cached
  }
}

// ---- Pace ----------------------------------------------------------------------------------------
const paces = new Map(); // connection id → { perMinute, pace } (per process)

function paceOf(connectionId, perMinute) {
  const hit = paces.get(connectionId);
  if (hit && hit.perMinute === perMinute) return hit.pace;
  const pace = new Pace(60_000 / perMinute);
  if (hit) pace.holdUntil(hit.pace.next);
  paces.set(connectionId, { perMinute, pace });
  return pace;
}

/** The hold after a 429: Retry-After in seconds (or an HTTP date), at most two minutes ahead; one minute without it. */
export function holdUntilOf(rateLimit, now = Date.now()) {
  const v = rateLimit?.["retry-after"];
  const s = Number(v);
  const at = Number.isFinite(s) && s >= 0 ? now + s * 1000 : Number.isFinite(Date.parse(v)) ? Date.parse(v) : now + HOLD_DEFAULT_MS;
  return Math.min(Math.max(at, now), now + HOLD_MAX_MS);
}

/** The path as its endpoint template for the counts: the query left out, ids replaced (GET /reviews, GET /channels). */
export function endpointOf(method, path) {
  return `${method} ${path.split("?")[0].replace(/\/(chl|rev|acc)-[A-Za-z0-9-]+/g, "/{id}")}`;
}

/**
 * The eTrusted API of one connection, every call paced (per connection), counted and bound to the budget. settings:
 * the connection's settings (client id, pace).
 */
export function etrustedClient(connection, settings, budget) {
  const base = apiBase();
  const pace = paceOf(connection.connectionId, reviewSettings(settings).perMinute);
  const call = async (path) => {
    await pace.wait();
    const token = await tokenFor(connection, settings, budget.signal(PER_CALL_MS), Date.now(), budget);
    budget.count?.(endpointOf("GET", path));
    try {
      return await requestJson(`${base}${path}`, { headers: { authorization: `Bearer ${token}` }, signal: budget.signal(PER_CALL_MS) });
    } catch (err) {
      if (err instanceof SourceError && err.code === "http_401") dropToken(connection, settings);
      if (err instanceof SourceError && err.code === "rate_limited") {
        const at = holdUntilOf(err.rateLimit);
        pace.holdUntil(at);
        warn("etrusted rate limited", { connection: connection.connectionId, code: "rate_limited", resumeInSeconds: Math.round((at - Date.now()) / 1000) });
      }
      throw err;
    }
  };
  return { get: call };
}

/** Test aid: forget the tokens and paces of this process. */
export function resetClients() {
  tokens.clear();
  paces.clear();
}
