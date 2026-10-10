/**
 * HubSpot → canonical shapes (DESIGN §2, §4.1). Pure functions: no database, no network.
 *
 * Events: a webhook body is an array of events, from crmObjects subscriptions (object.creation,
 * object.propertyChange, … with objectTypeId), from older object-named subscriptions (deal.creation,
 * …) and from hubEvents (contact.privacyDeletion). Each becomes one canonical event keyed hs:<eventId>
 * with ids and timestamps only: a property change's value, the acting user and anything else the
 * event carries are dropped. An event of another portal is kept as ignored (portal_mismatch) and
 * never read back.
 *
 * Objects: a batch read answer becomes a record, contact or call in the shape of the ingest
 * functions. HubSpot's own structural properties (pipeline, stage, owner, times) are named here;
 * every other property comes from the connection's field mapping (cma.connection_field). A call's
 * numbers are hashed and dropped: the result never holds a number.
 */
import { hashNumber } from "../../core/hash.mjs";

// HubSpot object type ids and names → canonical object types
const TYPE_IDS = { "0-1": "contact", "0-2": "company", "0-3": "deal", "0-5": "ticket", "0-48": "crm_call" };
const TYPE_NAMES = { contact: "contact", contacts: "contact", company: "company", companies: "company", deal: "deal", deals: "deal",
  ticket: "ticket", tickets: "ticket", call: "crm_call", calls: "crm_call" };
const KINDS = { creation: "created", deletion: "deleted", merge: "merged", restore: "restored", propertychange: "changed",
  associationchange: "associated", privacydeletion: "deleted" };

/** The canonical object types the CMA reads back, with HubSpot's API object names. */
export const API_OBJECT = { deal: "deals", ticket: "tickets", contact: "contacts", crm_call: "calls" };

// Associations kept, in their stored direction (activity or record → contact, activity → record);
// HubSpot's own README in hubspot/ names the same four.
const KEPT_PAIRS = new Set(["deal>contact", "ticket>contact", "crm_call>contact", "crm_call>deal"]);

function typeOf(value) {
  if (value === undefined || value === null) return null;
  const v = String(value).toLowerCase();
  return TYPE_IDS[v] ?? TYPE_NAMES[v] ?? null;
}

function idOf(value) {
  if (value === undefined || value === null) return null;
  const s = String(value).trim();
  return s && s.length <= 100 ? s : null;
}

function isoMs(ms) {
  const n = Number(ms);
  return Number.isFinite(n) && n > 0 ? new Date(n).toISOString() : null;
}

/** The (from, to) pair of an association event as canonical types, from the type ids or the AAA_TO_BBB name. */
function associationPair(e) {
  let from = typeOf(e.fromObjectTypeId);
  let to = typeOf(e.toObjectTypeId);
  if ((!from || !to) && typeof e.associationType === "string") {
    const m = /^([A-Z]+)_TO_([A-Z]+)$/.exec(e.associationType.toUpperCase());
    if (m) {
      from = typeOf(m[1]);
      to = typeOf(m[2]);
    }
  }
  return { from, to, fromId: idOf(e.fromObjectId), toId: idOf(e.toObjectId) };
}

/** The pair in its stored direction, or null when the CMA does not keep it. */
export function keptAssociation(from, fromId, to, toId) {
  if (KEPT_PAIRS.has(`${from}>${to}`)) return { fromType: from, fromId, toType: to, toId };
  if (KEPT_PAIRS.has(`${to}>${from}`)) return { fromType: to, fromId: toId, toType: from, toId: fromId };
  return null;
}

/**
 * One webhook event → one canonical event. portalId: the connection's account (external_account_id).
 * Never throws: an event it cannot place is kept with ignore set, so the log shows it arrived.
 */
export function mapEvent(e, portalId) {
  const subscriptionType = typeof e?.subscriptionType === "string" ? e.subscriptionType.slice(0, 100) : "unknown";
  const [prefix, action = ""] = subscriptionType.split(".");
  const kind = KINDS[action.toLowerCase()] ?? "changed";
  const objectType = prefix.toLowerCase() === "object" ? typeOf(e?.objectTypeId ?? e?.objectType) : typeOf(prefix);
  const eventId = idOf(e?.eventId);
  const occurredAt = isoMs(e?.occurredAt) ?? new Date().toISOString();
  const raw = {
    eventId: eventId ?? undefined, subscriptionType, objectTypeId: e?.objectTypeId ?? undefined, portalId: idOf(e?.portalId) ?? undefined,
    attemptNumber: Number.isInteger(e?.attemptNumber) ? e.attemptNumber : undefined, changeSource: typeof e?.changeSource === "string" ? e.changeSource.slice(0, 60) : undefined,
    propertyName: typeof e?.propertyName === "string" ? e.propertyName.slice(0, 100) : undefined,
  };
  const out = {
    key: eventId ? `hs:${eventId}` : null,
    sourceType: subscriptionType,
    kind,
    objectType: objectType ?? "other",
    objectId: idOf(e?.objectId) ?? "unknown",
    propertyName: raw.propertyName ?? null,
    occurredAt,
    attempt: (Number.isInteger(e?.attemptNumber) ? e.attemptNumber : 0) + 1,
    raw,
  };
  if (action.toLowerCase() === "privacydeletion") raw.privacy = true;

  if (kind === "merged") {
    const primary = idOf(e?.newObjectId) ?? idOf(e?.primaryObjectId) ?? idOf(e?.objectId);
    const merged = Array.isArray(e?.mergedObjectIds) ? e.mergedObjectIds.map(idOf).filter(Boolean).slice(0, 50) : [];
    out.objectId = primary ?? "unknown";
    raw.primaryObjectId = primary ?? undefined;
    raw.mergedObjectIds = merged.filter((id) => id !== primary);
  }

  if (kind === "associated") {
    const p = associationPair(e ?? {});
    raw.fromObjectTypeId = e?.fromObjectTypeId ?? undefined;
    raw.toObjectTypeId = e?.toObjectTypeId ?? undefined;
    raw.associationRemoved = e?.associationRemoved === true;
    const kept = p.from && p.to && p.fromId && p.toId ? keptAssociation(p.from, p.fromId, p.to, p.toId) : null;
    if (kept) {
      // The owning side (the record or the call) is read back; its associations come with it
      out.objectType = kept.fromType;
      out.objectId = kept.fromId;
      raw.fromId = kept.fromId;
      raw.toType = kept.toType;
      raw.toId = kept.toId;
    } else {
      out.objectType = p.from ?? out.objectType;
      out.objectId = p.fromId ?? out.objectId;
      out.ignore = "association_not_kept";
    }
  }

  if (!out.key) {
    out.key = `hs:x:${subscriptionType}:${out.objectId}:${e?.occurredAt ?? ""}`.slice(0, 200);
  }
  if (!out.ignore) {
    if (idOf(e?.portalId) !== String(portalId)) out.ignore = "portal_mismatch";
    else if (!API_OBJECT[out.objectType]) out.ignore = "object_not_kept";
    else if (out.objectId === "unknown") out.ignore = "malformed";
  }
  for (const k of Object.keys(raw)) if (raw[k] === undefined) delete raw[k];
  return out;
}

/** A webhook body (already authenticated and parsed) → canonical events. */
export function mapEvents(body, portalId) {
  const list = Array.isArray(body) ? body : body && typeof body === "object" ? [body] : [];
  return list.map((e) => mapEvent(e, portalId));
}

// ---- Objects ---------------------------------------------------------------------------------

// HubSpot's structural properties per record type (not configuration: they are what a deal or a
// ticket is in HubSpot). VENDOR_SETUP.md §1.1, last paragraph.
export const RECORD_STANDARD = {
  deal: { pipeline: "pipeline", stage: "dealstage", owner: "hubspot_owner_id", created: "createdate", closed: "closedate", modified: "hs_lastmodifieddate" },
  ticket: { pipeline: "hs_pipeline", stage: "hs_pipeline_stage", owner: "hubspot_owner_id", created: "createdate", closed: "closed_date", modified: "hs_lastmodifieddate" },
};
// A call engagement's properties; the two numbers are read only to be hashed
export const CALL_PROPERTIES = ["hs_timestamp", "hs_call_direction", "hs_call_status", "hs_call_disposition", "hs_call_duration",
  "hubspot_owner_id", "hs_call_source", "hs_createdate", "hs_lastmodifieddate"];
export const CALL_NUMBER_PROPERTIES = ["hs_call_from_number", "hs_call_to_number"];

const RECORD_KEYS = { market: "market", language: "language", currency: "currency", amount: "amount", source_channel: "sourceChannel", category: "category" };
const CONTACT_KEYS = { country: "country", language: "language", currency: "currency", store: "store" };

/** The configured fields of one entity (deal, ticket, contact) from cma.connection_config. */
export function fieldsOf(config, entity) {
  return (config?.fields ?? []).filter((f) => f.entity === entity && typeof f.property === "string" && f.property);
}

/** The properties a batch read asks for: the structural ones plus the configured ones, nothing else. */
export function propertiesFor(entity, config) {
  const set = new Set();
  if (RECORD_STANDARD[entity]) for (const p of Object.values(RECORD_STANDARD[entity])) set.add(p);
  if (entity === "crm_call") for (const p of [...CALL_PROPERTIES, ...CALL_NUMBER_PROPERTIES]) set.add(p);
  if (entity !== "crm_call") for (const f of fieldsOf(config, entity)) set.add(f.property);
  return [...set].sort();
}

/** A time from HubSpot (ISO text or milliseconds) as ISO 8601, or null. */
export function iso(value) {
  if (value === undefined || value === null || value === "") return null;
  const n = typeof value === "number" ? value : /^\d{10,16}$/.test(String(value)) ? Number(value) : Date.parse(String(value));
  return Number.isFinite(n) ? new Date(n).toISOString() : null;
}

function text(value, max = 200) {
  if (value === undefined || value === null) return null;
  const s = String(value).trim();
  return s ? s.slice(0, max) : null;
}

function pick(props, names) {
  const out = {};
  for (const n of names) if (props?.[n] !== undefined && props[n] !== null && props[n] !== "") out[n] = props[n];
  return out;
}

/**
 * A deal or ticket → ingest_upsert_records item. fallback: { country, language } of its primary
 * contact, used when the connection maps no market or language property for the record type
 * (VENDOR_SETUP §1.1: a deal's market comes from its contact's country unless a deal property is
 * mapped). contactId is set by the caller from the associations.
 */
export function recordFromObject(recordType, obj, config, fallback = {}) {
  const std = RECORD_STANDARD[recordType];
  const p = obj?.properties ?? {};
  const fields = fieldsOf(config, recordType);
  const r = {
    recordType,
    sourceId: String(obj.id),
    pipelineId: text(p[std.pipeline], 100),
    stageId: text(p[std.stage], 100),
    ownerRef: text(p[std.owner], 100),
    createdAt: iso(p[std.created]) ?? iso(obj.createdAt),
    updatedAt: iso(obj.updatedAt) ?? iso(p[std.modified]),
    closedAt: iso(p[std.closed]),
    raw: pick(p, propertiesFor(recordType, config)),
  };
  for (const f of fields) {
    const key = RECORD_KEYS[f.field];
    if (key) r[key] = text(p[f.property]);
  }
  if (!fields.some((f) => f.field === "market") && fallback.country) r.market = fallback.country;
  if (!fields.some((f) => f.field === "language") && fallback.language) r.language = fallback.language;
  return r;
}

/** A contact → ingest_upsert_contacts item, refs as {system: [slot 1, slot 2, …]}. */
export function contactFromObject(obj, config) {
  const p = obj?.properties ?? {};
  const fields = fieldsOf(config, "contact");
  const c = { sourceId: String(obj.id), updatedAt: iso(obj.updatedAt) ?? iso(p.lastmodifieddate), raw: pick(p, propertiesFor("contact", config)) };
  const refs = {};
  for (const f of fields) {
    if (f.field === "ref" && f.refSystem) {
      const slot = Number(f.slot ?? 1);
      if (!Number.isInteger(slot) || slot < 1 || slot > 9) continue;
      refs[f.refSystem] ??= [];
      while (refs[f.refSystem].length < slot) refs[f.refSystem].push(null);
      refs[f.refSystem][slot - 1] = text(p[f.property], 100);
    } else if (CONTACT_KEYS[f.field]) {
      c[CONTACT_KEYS[f.field]] = text(p[f.property]);
    }
  }
  if (Object.keys(refs).length) c.refs = refs;
  return c;
}

/** The mapped country and language of a contact (for a record's fallback). */
export function contactAttributes(obj, config) {
  const c = contactFromObject(obj, config);
  return { country: c.country ?? null, language: c.language ?? null };
}

const DIRECTIONS = { INBOUND: "inbound", OUTBOUND: "outbound" };

/**
 * A call engagement → ingest_upsert_calls item. The other party's number (the "to" number of an
 * outbound call, the "from" number of an inbound one) becomes HMAC-SHA256(pepper, E.164) with the
 * connection's default region for national formats; both numbers are dropped from raw.
 * sourceApp: the engagement's hs_call_source, lower case.
 */
export function callFromObject(obj, { pepper, region = null } = {}) {
  const p = obj?.properties ?? {};
  const direction = DIRECTIONS[String(p.hs_call_direction ?? "").toUpperCase()] ?? "unknown";
  const other = direction === "outbound" ? p.hs_call_to_number : direction === "inbound" ? p.hs_call_from_number : null;
  const ms = Number(p.hs_call_duration);
  return {
    sourceId: String(obj.id),
    occurredAt: iso(p.hs_timestamp),
    direction,
    status: text(p.hs_call_status, 40),
    outcomeRef: text(p.hs_call_disposition, 100),
    durationSeconds: Number.isFinite(ms) && ms >= 0 ? Math.round(ms / 1000) : null,
    ownerRef: text(p.hubspot_owner_id, 100),
    sourceApp: text(p.hs_call_source, 60)?.toLowerCase() ?? null,
    counterpartHash: other ? hashNumber(pepper, other, region) : null,
    createdAt: iso(p.hs_createdate) ?? iso(obj.createdAt),
    updatedAt: iso(obj.updatedAt) ?? iso(p.hs_lastmodifieddate),
    raw: pick(p, CALL_PROPERTIES),
  };
}

/**
 * The primary contact of a record from its associations: a contact labelled primary, else the one
 * the CMA already holds for it when still associated, else the lowest id (deterministic).
 * to: [{ toObjectId, associationTypes: [{ label }] }]
 */
export function primaryContact(to, storedContactId = null) {
  const ids = (to ?? []).map((t) => idOf(t.toObjectId)).filter(Boolean);
  if (!ids.length) return null;
  const labelled = (to ?? []).find((t) => (t.associationTypes ?? []).some((a) => /primary/i.test(String(a.label ?? ""))));
  if (labelled) return idOf(labelled.toObjectId);
  if (storedContactId && ids.includes(storedContactId)) return storedContactId;
  return [...ids].sort((a, b) => (a.length - b.length) || (a < b ? -1 : a > b ? 1 : 0))[0];
}

/**
 * Association items for one object from a read-back: every current association not stored is added,
 * every stored one the source no longer has is removed, both at the read time.
 */
export function associationDiff(fromType, fromId, current, stored, toTypes, at) {
  const items = [];
  const now = new Set(current.map((c) => `${c.toType}:${c.toId}`));
  const had = new Set(stored.filter((s) => s.fromId === fromId && toTypes.includes(s.toType)).map((s) => `${s.toType}:${s.toId}`));
  for (const c of current) {
    if (!had.has(`${c.toType}:${c.toId}`)) items.push({ fromType, fromId, toType: c.toType, toId: c.toId, removed: false, changedAt: at });
  }
  for (const k of had) {
    if (!now.has(k)) {
      const [toType, toId] = [k.slice(0, k.indexOf(":")), k.slice(k.indexOf(":") + 1)];
      items.push({ fromType, fromId, toType, toId, removed: true, changedAt: at });
    }
  }
  return items;
}
