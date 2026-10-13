/**
 * Aircall read-back (DESIGN §2, §4.2): the calls named by claimed events are read from Aircall's
 * Public API (https://api.aircall.io, Basic authentication with the API ID and token of the
 * connection's token secret, JSON {"api_id","api_token"}) and turned into units for the core to write.
 *
 *   calls      GET /v1/calls/{id}, one read per call however many of its events a batch holds; the
 *              call with its whole current tag set into cma.ingest_upsert_telephony_calls, the other
 *              party's number hashed with the tenant's pepper (default region: the line's market,
 *              else the tenant's first active market) and dropped. A call Aircall does not know
 *              (404) is ignored. A call a job already holds from Aircall's own listing (inline, source
 *              api) is not read again
 *   catalogs   GET /v1/numbers and GET /v1/tags into cma.ingest_upsert_telephony_catalog: from the
 *              sweep at most hourly per connection (cursor `catalogs`), and on the first event of a
 *              connection whose line catalog is empty; a line's market and counted flag stay (0007a)
 *   replay     dev only: with INGEST_ALLOW_REPLAY=1 in the service's environment AND the connection
 *              setting {"replay": true}, a call is taken from the event's own call object (held in
 *              memory for this request) instead of the API, and nothing calls Aircall. Without the
 *              variable the setting does nothing (deploy.sh sets it in dev only)
 *
 * Pacing (Aircall: 120 requests per minute; the adapter's own limit is the connection setting
 * aircall_max_per_minute, default 60, at most 120): one pace per connection and process, shared by
 * the read-back, the catalogs, the reconcile and the backfill. The webhook path does not wait past its
 * budget for a slot: the event fails (paced) and the sweep reads it. On a 429 the rest of the batch
 * is not tried: its events fail with rate_limited (the sweep reads them after their backoff) and the
 * connection makes no call before Aircall's X-AircallApi-Reset (at most 70 seconds ahead). Nothing
 * retries in a loop.
 */
import { getSecret, SecretUnavailable } from "../../core/secrets.mjs";
import { requestJson, checkedBase, SourceError } from "../../core/http.mjs";
import { Pace } from "../../core/pace.mjs";
import { applyUnits } from "../../core/store.mjs";
import { contextOf } from "../../core/connection.mjs";
import { info, warn } from "../../core/log.mjs";
import { OBJECT_TYPE, callFromObject, numberItem, tagItem } from "./map.mjs";

const PER_CALL_MS = 2500;
const PER_PAGE = 50;
const CATALOG_EVERY_MS = 60 * 60_000;
const CATALOG_MAX = 500;
const HOLD_MAX_MS = 70_000;
export const DEFAULT_PER_MINUTE = 60;
export const MAX_PER_MINUTE = 120;
export const CATALOG_STREAM = "catalogs";

function apiBase() {
  return checkedBase(process.env.INGEST_AIRCALL_API_BASE ?? "https://api.aircall.io");
}

/** Dev replay is possible only where the environment allows it (deploy.sh dev; never prod). */
export function replayAllowed() {
  return process.env.INGEST_ALLOW_REPLAY === "1";
}

/** The connection asks for replay, and the environment allows it. */
export function replayOn(settings) {
  return replayAllowed() && (settings?.replay === true || settings?.replay === "true");
}

/** The connection's own limit (setting aircall_max_per_minute): a whole number 1 to 120, else 60. */
export function perMinuteOf(settings) {
  const v = settings?.aircall_max_per_minute;
  const n = typeof v === "number" ? v : typeof v === "string" && /^\d{1,3}$/.test(v.trim()) ? Number(v) : NaN;
  return Number.isInteger(n) && n >= 1 && n <= MAX_PER_MINUTE ? n : DEFAULT_PER_MINUTE;
}

const paces = new Map(); // connection id → { perMinute, pace } (per process)

/** The connection's pace in this process, rebuilt (keeping its next slot) when the setting changes. */
export function paceOf(connectionId, perMinute) {
  const hit = paces.get(connectionId);
  if (hit && hit.perMinute === perMinute) return hit.pace;
  const pace = new Pace(60_000 / perMinute);
  if (hit) pace.holdUntil(hit.pace.next);
  paces.set(connectionId, { perMinute, pace });
  return pace;
}

/** Aircall's reset time after a 429 (X-AircallApi-Reset, a UNIX time), at most 70 seconds ahead; 60 s without it. */
export function resetAt(rateLimit, now = Date.now()) {
  const v = Number(rateLimit?.["x-aircallapi-reset"]);
  const at = Number.isFinite(v) && v > 0 ? (v > 1e12 ? v : v * 1000) : now + 60_000;
  return Math.min(Math.max(at, now), now + HOLD_MAX_MS);
}

/** The API ID and token from the token secret; SourceError token_unavailable or token_invalid. */
export async function credentialsOf(connection) {
  let value;
  try {
    value = await getSecret(connection.tokenSecretName);
  } catch (err) {
    throw new SourceError(err instanceof SecretUnavailable ? "token_unavailable" : "secret_error");
  }
  let parsed;
  try {
    parsed = JSON.parse(value);
  } catch {
    throw new SourceError("token_invalid");
  }
  if (typeof parsed?.api_id !== "string" || typeof parsed?.api_token !== "string" || !parsed.api_id || !parsed.api_token) {
    throw new SourceError("token_invalid");
  }
  return parsed;
}

/**
 * The Aircall API for one connection, every call paced (per connection) and bound to the budget.
 * settings: the connection's settings (the pace). A 429 holds the connection until Aircall's reset.
 */
export function aircallClient(credentials, connection, settings, budget) {
  const base = apiBase();
  const headers = { authorization: `Basic ${Buffer.from(`${credentials.api_id}:${credentials.api_token}`).toString("base64")}` };
  const pace = paceOf(connection.connectionId, perMinuteOf(settings));
  const call = async (method, path, body) => {
    // A deadline (the webhook's budget) never waits past itself for a slot: the sweep does the rest
    if (pace.delay() + 200 > budget.remaining()) throw new SourceError("paced");
    await pace.wait();
    try {
      return await requestJson(`${base}${path}`, { method, headers, body, signal: budget.signal(PER_CALL_MS) });
    } catch (err) {
      if (err instanceof SourceError && err.code === "rate_limited") {
        const at = resetAt(err.rateLimit);
        pace.holdUntil(at);
        warn("aircall rate limited", {
          connection: connection.connectionId, code: "rate_limited",
          limit: Number(err.rateLimit?.["x-aircallapi-limit"]) || null, remaining: Number(err.rateLimit?.["x-aircallapi-remaining"] ?? NaN),
          resumeInSeconds: Math.round((at - Date.now()) / 1000),
        });
      }
      throw err;
    }
  };
  const pages = async (path, key) => {
    const out = [];
    for (let page = 1; page <= 200; page += 1) {
      const sep = path.includes("?") ? "&" : "?";
      const r = await call("GET", `${path}${sep}per_page=${PER_PAGE}&page=${page}`);
      const list = Array.isArray(r?.[key]) ? r[key] : [];
      out.push(...list);
      if (!list.length || !r?.meta?.next_page_link) break;
    }
    return out;
  };
  return {
    /** GET /v1/calls/{id} → the call object, or null when Aircall does not know it (404). */
    async getCall(id) {
      try {
        return (await call("GET", `/v1/calls/${encodeURIComponent(id)}`))?.call ?? null;
      } catch (err) {
        if (err instanceof SourceError && err.code === "http_404") return null;
        throw err;
      }
    },
    /** One page of GET /v1/calls created between two UNIX times (seconds), ascending: { calls, meta }. */
    async listCalls(fromS, toS, page) {
      const r = await call("GET", `/v1/calls?from=${fromS}&to=${toS}&order=asc&per_page=${PER_PAGE}&page=${page}`);
      return { calls: Array.isArray(r?.calls) ? r.calls : [], meta: r?.meta ?? {} };
    },
    numbers: () => pages("/v1/numbers", "numbers"),
    tags: () => pages("/v1/tags", "tags"),
    webhooks: () => pages("/v1/webhooks", "webhooks"),
    /** PUT /v1/webhooks/{id}: the events are sent again, since an update without them resets a webhook to all events. */
    async updateWebhook(id, body) {
      return (await call("PUT", `/v1/webhooks/${encodeURIComponent(id)}`, body))?.webhook ?? null;
    },
    async company() {
      return (await call("GET", "/v1/company"))?.company ?? null;
    },
  };
}

/** The client of a connection, with its settings (cma.connection_config) when the caller has none. */
export async function clientFor(connection, settings, budget) {
  return aircallClient(await credentialsOf(connection), connection, settings, budget);
}

/**
 * The account check of the jobs: the API key answers for the company the connection pins
 * (external_account_id = GET /v1/company's name), so a key of another Aircall company never lists
 * its calls into this connection. SourceError account_mismatch otherwise.
 */
export async function assertAccount(api, connection) {
  const company = await api.company();
  const name = typeof company?.name === "string" ? company.name.trim() : "";
  if (!name || name !== String(connection.externalAccountId ?? "").trim()) throw new SourceError("account_mismatch");
}

function unit(events, status, error = null, writes = {}) {
  return { eventIds: events.map((e) => e.eventId), status, error, writes };
}

/** Events grouped by call; the newest event (by occurrence) last. */
function groupByCall(events) {
  const groups = new Map();
  for (const e of events) {
    if (!groups.has(e.objectId)) groups.set(e.objectId, { callId: e.objectId, events: [] });
    groups.get(e.objectId).events.push(e);
  }
  for (const g of groups.values()) g.events.sort((a, b) => String(a.occurredAt).localeCompare(String(b.occurredAt)));
  return [...groups.values()];
}

/** The in-memory object of a group: Aircall's own listing first, else (replay) the newest event's own object. */
function inlineOfGroup(g, inline, replay) {
  const own = g.events.map((e) => inline.get(e.key)).filter(Boolean);
  const api = own.filter((o) => o.source === "api").at(-1);
  if (api) return api;
  if (replay) return own.filter((o) => o.source === "replay").at(-1) ?? null;
  return null;
}

/** The catalogs (numbers and tags) as one unit with its cursor; null when a catalog is too large to refresh. */
async function catalogUnit(api, connection) {
  const [numbers, tags] = [await api.numbers(), await api.tags()];
  const numberItems = numbers.map(numberItem).filter(Boolean);
  const tagItems = tags.map(tagItem).filter(Boolean);
  if (numberItems.length > CATALOG_MAX || tagItems.length > CATALOG_MAX) {
    warn("aircall catalog too large", { connection: connection.connectionId, code: "catalog_too_large", numbers: numberItems.length, tags: tagItems.length });
    return null;
  }
  return {
    eventIds: [], status: "processed", error: null,
    writes: { telephonyNumbers: numberItems, telephonyTags: tagItems, cursors: [{ stream: CATALOG_STREAM, cursor: { refreshedAt: Date.now() } }] },
  };
}

function catalogDue(cursor, now = Date.now()) {
  const at = Number(cursor?.refreshedAt);
  return !Number.isFinite(at) || now - at >= CATALOG_EVERY_MS;
}

/**
 * The sweep's catalog refresh: at most hourly per connection (cursor `catalogs`), never for a replay
 * connection. Answers true when the catalogs were written.
 */
export async function refreshCatalogs({ connection, store, budget }) {
  const config = await store.config();
  if (replayOn(config?.settings)) return false;
  if (!catalogDue(await store.cursor(CATALOG_STREAM))) return false;
  const api = await clientFor(connection, config?.settings, budget);
  const u = await catalogUnit(api, connection);
  if (!u) return false;
  await applyUnits(contextOf(connection), connection.connectionId, [u]);
  info("aircall catalogs", { connection: connection.connectionId, numbers: u.writes.telephonyNumbers.length, tags: u.writes.telephonyTags.length });
  return true;
}

/** The read-back of claimed events → units. inline: the in-memory objects by event key. */
export async function readBack({ connection, config, events, store, budget, inline = new Map() }) {
  const settings = config?.settings ?? {};
  const replay = replayOn(settings);
  const units = [];
  const groups = [];
  for (const g of groupByCall(events)) {
    if (g.events.some((e) => e.objectType !== OBJECT_TYPE) || g.callId === "unknown") units.push(unit(g.events, "ignored"));
    else groups.push(g);
  }
  if (!groups.length) return units;

  let pepper;
  try {
    pepper = await getSecret(`ingest-hash-pepper-${await store.tenantSlug()}`);
  } catch {
    return [...units, ...groups.map((g) => unit(g.events, "failed", "pepper_unavailable"))];
  }

  // The source of each call: an object in memory, or one GET (none for a replay connection)
  const objects = new Map(); // call id → { object, at }
  const toRead = [];
  for (const g of groups) {
    const held = inlineOfGroup(g, inline, replay);
    if (held) objects.set(g.callId, { object: held.object, at: held.at });
    else if (replay) units.push(unit(g.events, "failed", "replay_payload_gone"));
    else toRead.push(g);
  }

  let api = null;
  if (toRead.length) {
    try {
      api = await clientFor(connection, settings, budget);
    } catch (err) {
      units.push(...toRead.map((g) => unit(g.events, "failed", err instanceof SourceError ? err.code : "readback_error")));
      toRead.length = 0;
    }
  }
  let read = 0;
  for (let i = 0; i < toRead.length; i += 1) {
    const g = toRead[i];
    try {
      const at = new Date().toISOString();
      const object = await api.getCall(g.callId);
      read += 1;
      if (object) objects.set(g.callId, { object, at });
      else units.push(unit(g.events, "ignored"));
    } catch (err) {
      // This call and the rest of the batch fail with the same code: no further call after a 429, a
      // timeout or an Aircall that is down; the sweep reads them after their backoff
      const code = err instanceof SourceError ? err.code : "readback_error";
      units.push(...toRead.slice(i).map((x) => unit(x.events, "failed", code)));
      break;
    }
  }

  // The default region per line: the line's market, else the tenant's first active market
  const lines = [...new Set([...objects.values()].map((o) => o.object?.number?.id).filter((v) => v !== undefined && v !== null).map(String))];
  let markets = new Map();
  let fallback = null;
  if (objects.size) {
    markets = await store.lineMarkets(lines);
    if (lines.some((l) => !markets.has(l)) || !lines.length) fallback = await store.firstMarket();
  }
  for (const g of groups) {
    const o = objects.get(g.callId);
    if (!o) continue;
    const region = markets.get(String(o.object?.number?.id ?? "")) ?? fallback;
    const item = callFromObject(o.object, { pepper, region, versionAt: o.at });
    units.push(item ? unit(g.events, "processed", null, { telephonyCalls: [item] }) : unit(g.events, "failed", "bad_call"));
  }
  pepper = null;

  // The first event of a connection without lines reads the catalogs too, when Aircall answered and time is left
  if (api && read > 0 && !replay && budget.remaining() > 1500) {
    try {
      if ((await store.lineCount()) === 0 && catalogDue(await store.cursor(CATALOG_STREAM))) {
        const u = await catalogUnit(api, connection);
        if (u) units.unshift(u);
      }
    } catch (err) {
      warn("aircall catalogs skipped", { connection: connection.connectionId, code: err?.code ?? "error" });
    }
  }
  return units;
}

/** Test aid: forget the paces of this process. */
export function resetPaces() {
  paces.clear();
}
