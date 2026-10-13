/**
 * Aircall → canonical shapes (DESIGN §2, §2.1, §4.2). Pure functions: no database, no network.
 *
 * Events: a webhook body is one event, { resource, event, timestamp, token, data }, with the call
 * object in data (developer.aircall.io, Webhooks). The six call events the CMA subscribes to are
 * recorded keyed ac:<event>:<call id>:<timestamp> (Aircall delivers at least once and not in order:
 * the key absorbs the retries); kinds as DESIGN §2: call.created → created, the other five → changed.
 * Any other event (another call event, or another resource) is recorded as ignored with
 * event_not_handled and never read back. Only ids and times are kept: the token, the call object and
 * everything in it stay out of the event log.
 *
 * Calls: the call object (from the API, or in dev a replayed event's own) becomes an item of
 * cma.ingest_upsert_telephony_calls with its whole current tag set. The other party's number
 * (raw_digits) becomes the keyed hash and is dropped; the telephony user and the line are kept as
 * ids only. Never kept (DESIGN §2.1): names, emails, the contact, comments, recordings, voicemails,
 * transcriptions, asset and short URLs; raw is an allowlist of flat keys.
 */
import { createHash } from "node:crypto";
import { hashNumber } from "../../core/hash.mjs";

/** The webhook events the CMA subscribes to (VENDOR_SETUP §2.3), with their canonical kind. */
export const EVENTS = {
  "call.created": "created",
  "call.answered": "changed",
  "call.ended": "changed",
  "call.tagged": "changed",
  "call.untagged": "changed",
  "call.archived": "changed",
};
export const OBJECT_TYPE = "telephony_call";

// The flat keys of a call that raw may keep; everything else is left out (the database filters again)
export const RAW_KEYS = ["status", "direction", "missed_call_reason", "duration", "archived", "started_at", "answered_at", "ended_at"];

export function idOf(value) {
  if (value === undefined || value === null || typeof value === "object") return null;
  const s = String(value).trim();
  return s && s.length <= 100 && /^[A-Za-z0-9_.-]+$/.test(s) ? s : null;
}

function text(value, max) {
  if (value === undefined || value === null || typeof value === "object") return null;
  const s = String(value).trim();
  return s ? s.slice(0, max) : null;
}

/** A UNIX time in seconds (Aircall's times) as ISO 8601, or null (also for 0 and empty). */
export function unixIso(value) {
  if (value === undefined || value === null || value === "") return null;
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return null;
  // seconds; a value in milliseconds is read as such rather than as a date 50,000 years ahead
  return new Date(n > 1e12 ? n : n * 1000).toISOString();
}

/**
 * One webhook body (already authenticated and parsed) → one canonical event. inlineAllowed: dev replay
 * (INGEST_ALLOW_REPLAY=1): the event then carries its own call object in memory (never recorded), for
 * a connection whose settings ask for replay. Never throws.
 */
export function mapEvent(payload, { inlineAllowed = false } = {}) {
  const event = typeof payload?.event === "string" ? payload.event.slice(0, 60) : "unknown";
  const resource = typeof payload?.resource === "string" ? payload.resource.slice(0, 30) : "unknown";
  const data = payload?.data && typeof payload.data === "object" && !Array.isArray(payload.data) ? payload.data : {};
  const objectId = idOf(data.id);
  const ts = Number(payload?.timestamp);
  const stamp = Number.isFinite(ts) && ts > 0 ? String(Math.trunc(ts)) : "none";
  const occurredAt = unixIso(payload?.timestamp) ?? new Date().toISOString();
  const handled = resource === "call" && Object.hasOwn(EVENTS, event);
  const out = {
    key: `ac:${event}:${objectId ?? "unknown"}:${stamp}`.slice(0, 200),
    sourceType: event,
    kind: handled ? EVENTS[event] : "changed",
    objectType: resource === "call" ? OBJECT_TYPE : /^[a-z][a-z0-9_]{0,29}$/.test(resource) ? resource : "other",
    objectId: objectId ?? "unknown",
    occurredAt,
    raw: { event, resource, timestamp: stamp === "none" ? undefined : Number(stamp) },
  };
  if (out.raw.timestamp === undefined) delete out.raw.timestamp;
  if (!handled) out.ignore = "event_not_handled";
  else if (!objectId) out.ignore = "malformed";
  else if (inlineAllowed) out.inline = { object: data, at: occurredAt, source: "replay" };
  return out;
}

/** A webhook body → canonical events (Aircall sends one event per request); throws SyntaxError on non-JSON. */
export function mapEvents(body, options) {
  const parsed = JSON.parse(Buffer.isBuffer(body) ? body.toString("utf8") : String(body));
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new SyntaxError("not one event");
  return [mapEvent(parsed, options)];
}

/** The call's current tag set as [{ tagRef, name }]; null when the object carries no tag list. */
export function tagsOf(call) {
  if (!Array.isArray(call?.tags)) return null;
  const seen = new Set();
  const out = [];
  for (const t of call.tags) {
    const tagRef = idOf(t?.id);
    if (!tagRef || seen.has(tagRef)) continue;
    seen.add(tagRef);
    out.push({ tagRef, name: text(t?.name, 100) ?? tagRef });
  }
  return out.slice(0, 50);
}

/** The allowlisted flat keys of a call (numbers, booleans, short strings). */
export function rawOf(call) {
  const raw = {};
  for (const k of RAW_KEYS) {
    const v = call?.[k];
    if (typeof v === "number" || typeof v === "boolean") raw[k] = v;
    else if (typeof v === "string" && v.length <= 60) raw[k] = v;
  }
  return raw;
}

const DIRECTIONS = new Set(["inbound", "outbound"]);

/**
 * A call object → an ingest_upsert_telephony_calls item, or null when it is not a call (no id or no
 * direction). versionAt: the time the object was read (an API read or listing) or, for a replayed
 * event, the event's time: the stale guard keeps the newest. region: the default region for a
 * number in national format (the line's market, else the tenant's first active market).
 */
export function callFromObject(call, { pepper, region = null, versionAt }) {
  const sourceId = idOf(call?.id);
  const direction = String(call?.direction ?? "").toLowerCase();
  if (!sourceId || !DIRECTIONS.has(direction)) return null;
  const duration = Number(call.duration);
  const item = {
    sourceId,
    direction,
    status: text(call.status, 40),
    missedReason: text(call.missed_call_reason, 60),
    startedAt: unixIso(call.started_at),
    answeredAt: unixIso(call.answered_at),
    endedAt: unixIso(call.ended_at),
    durationSeconds: Number.isInteger(duration) && duration >= 0 ? duration : null,
    userRef: idOf(call.user?.id),
    numberRef: idOf(call.number?.id),
    counterpartHash: typeof call.raw_digits === "string" ? hashNumber(pepper, call.raw_digits, region) : null,
    isArchived: call.archived === true,
    versionAt,
    raw: rawOf(call),
  };
  const tags = tagsOf(call);
  if (tags) item.tags = tags;
  return item;
}

/**
 * A short fingerprint of what the CMA keeps of a listed call (never the number): the version of its
 * synthetic event, so a reconcile or backfill reads an unchanged call once however often it lists it.
 */
export function fingerprint(call) {
  const kept = [idOf(call?.id), call?.status, call?.direction, call?.started_at, call?.answered_at, call?.ended_at, call?.duration,
    call?.archived === true, call?.missed_call_reason, idOf(call?.user?.id), idOf(call?.number?.id), (tagsOf(call) ?? []).map((t) => t.tagRef).sort()];
  return createHash("sha256").update(JSON.stringify(kept)).digest("hex").slice(0, 16);
}

/** Catalog items for cma.ingest_upsert_telephony_catalog. */
export function numberItem(n) {
  const numberRef = idOf(n?.id);
  return numberRef ? { numberRef, name: text(n.name, 100) ?? numberRef, digits: typeof n.digits === "string" ? n.digits.slice(0, 40) : null } : null;
}
export function tagItem(t) {
  const tagRef = idOf(t?.id);
  return tagRef ? { tagRef, name: text(t.name, 100) ?? tagRef } : null;
}
