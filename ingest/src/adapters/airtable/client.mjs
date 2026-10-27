/**
 * The Airtable Web API for one asset register connection (addition 0008zj). Read only: the adapter sends GET requests,
 * and nothing is ever written to Airtable.
 *
 *   token     the bearer token the connection's token secret name points to in Secret Manager (an Airtable service
 *             account's personal access token, read-only on the one base: scopes data.records:read and
 *             schema.bases:read). A missing secret fails the read with token_unavailable
 *   requests  GET https://api.airtable.com/v0/<path>, each one counted per endpoint on the job's budget (ids replaced,
 *             no query value: the run's log line) and paced per connection and process at the connection setting
 *             airtable_max_per_second (default 2, 1 to 5; Airtable allows five per second per base). A 429 holds the
 *             connection for 30 seconds (Airtable locks the base that long) and fails the call (rate_limited): the run
 *             stops where it stands and the next one carries on. Nothing retries in a loop
 *
 * INGEST_AIRTABLE_API_BASE replaces the host for a fake (the verifiers, a local run): https, or http on the local
 * machine. No redirect is followed, so the token goes to that host only. Errors carry a code only, never a body:
 * token_unavailable, rate_limited, timeout, unreachable, bad_response, http_<status>.
 */
import { getSecret, SecretUnavailable } from "../../core/secrets.mjs";
import { requestJson, checkedBase, SourceError } from "../../core/http.mjs";
import { Pace, paceFactor } from "../../core/pace.mjs";
import { warn } from "../../core/log.mjs";

const PER_CALL_MS = 20_000;
export const LOCKOUT_MS = 30_000;

function apiBase() {
  return `${checkedBase(process.env.INGEST_AIRTABLE_API_BASE ?? "https://api.airtable.com")}/v0`;
}

// ---- Settings ------------------------------------------------------------------------------------
const WHOLE = {
  airtable_max_per_second: { default: 2, min: 1, max: 5 },
  assets_poll_interval_minutes: { default: 15, min: 1, max: 1440 },
  assets_load_chunk: { default: 1000, min: 100, max: 5000 },
};
export const DATE_FORMATS = ["dmy", "mdy", "iso"];
const ID = /^[A-Za-z0-9_-]{1,64}$/;

function whole(settings, name, fallbacks) {
  const v = settings?.[name];
  const n = typeof v === "number" ? v : typeof v === "string" && /^\d{1,6}$/.test(v.trim()) ? Number(v) : NaN;
  const { min, max } = WHOLE[name];
  if (Number.isInteger(n) && n >= min && n <= max) return n;
  if (v !== undefined && v !== null && v !== "") fallbacks.push(name);
  return WHOLE[name].default;
}

function idOf(settings, name, fallbacks) {
  const v = settings?.[name];
  if (typeof v === "string" && ID.test(v.trim())) return v.trim();
  if (v !== undefined && v !== null && v !== "") fallbacks.push(name);
  return null;
}

/**
 * The connection's settings for the adapter: its pace, the poll interval, the rows of a load's part (assets_load_chunk,
 * default 1,000, 100 to 5,000; addition 0008zk), the table and view, the date format of dates that arrive as text. A
 * value out of range (or out of its form) takes the default, or none for the ids and the date format, and is named in
 * fallbacks, which the run logs once.
 */
export function assetSettings(settings) {
  const fallbacks = [];
  const df = settings?.date_format;
  const dateFormat = typeof df === "string" && DATE_FORMATS.includes(df.trim()) ? df.trim() : null;
  if (!dateFormat && df !== undefined && df !== null && df !== "") fallbacks.push("date_format");
  return {
    perSecond: whole(settings, "airtable_max_per_second", fallbacks),
    intervalMinutes: whole(settings, "assets_poll_interval_minutes", fallbacks),
    loadChunk: whole(settings, "assets_load_chunk", fallbacks),
    tableId: idOf(settings, "table_id", fallbacks),
    viewId: idOf(settings, "view_id", fallbacks),
    dateFormat,
    fallbacks,
  };
}

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

/** The path as its endpoint template for the counts: the query left out, every id replaced (GET /{id}/{id}). */
export function endpointOf(method, path) {
  return `${method} ${path.split("?")[0].replace(/\/(app|tbl|viw|rec|fld)[A-Za-z0-9]+/g, "/{id}")}`;
}

/**
 * The Airtable API of one connection, every call paced (per connection), counted and bound to the budget. settings:
 * the connection's settings (the pace).
 */
export function airtableClient(connection, settings, budget) {
  const base = apiBase();
  const pace = paceOf(connection.connectionId, assetSettings(settings).perSecond);
  const call = async (path) => {
    let token;
    try {
      token = await getSecret(connection.tokenSecretName);
    } catch (err) {
      throw new SourceError(err instanceof SecretUnavailable ? "token_unavailable" : "secret_error");
    }
    await pace.wait();
    budget.count?.(endpointOf("GET", path));
    try {
      return await requestJson(`${base}${path}`, { headers: { authorization: `Bearer ${token}` }, signal: budget.signal(PER_CALL_MS) });
    } catch (err) {
      if (err instanceof SourceError && err.code === "rate_limited") {
        // the lockout scales with INGEST_PACE_FACTOR as every interval does (a verifier against a fake; never set on Cloud Run)
        pace.holdUntil(Date.now() + LOCKOUT_MS * paceFactor());
        warn("airtable rate limited", { connection: connection.connectionId, code: "rate_limited", resumeInSeconds: LOCKOUT_MS / 1000 });
      }
      throw err;
    }
  };
  return { get: call };
}

/** Test aid: forget the paces of this process. */
export function resetClients() {
  paces.clear();
}
