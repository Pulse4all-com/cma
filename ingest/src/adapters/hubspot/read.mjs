/**
 * HubSpot read-back (DESIGN §2, §4.1): the objects named by claimed events are read from HubSpot's
 * CRM API with the connection's static token and turned into units for the core to write.
 *
 *   deals, tickets  CRM v3 batch read (structural and configured properties only), their contacts
 *                   through the v4 associations batch read; the primary contact is read too, and
 *                   gives the record its market and language when no record property is mapped
 *   calls           CRM v3 batch read; the other party's number hashed with the tenant's pepper and
 *                   dropped; associations to contacts and deals
 *   contacts        CRM v3 batch read, only for contacts the CMA holds (0006: never the contact base)
 *   deletions       no read: the record, contact or call is marked deleted at the event's time
 *   privacy         contact.privacyDeletion → cma.ingest_contact_forget(), no read
 *   catalogs        pipelines with stages, and the call outcomes, at most hourly per connection
 *
 * Every call takes the budget's signal. 429 and timeouts fail the events of that object type with
 * rate_limited or timeout (the sweeper reads them again with backoff).
 */
import { getSecret, SecretUnavailable } from "../../core/secrets.mjs";
import { requestJson, checkedBase, SourceError } from "../../core/http.mjs";
import { warn } from "../../core/log.mjs";
import {
  API_OBJECT, propertiesFor, recordFromObject, contactFromObject, contactAttributes, callFromObject, primaryContact, associationDiff,
} from "./map.mjs";

const BATCH_READ = 100;
const CATALOG_EVERY_MS = 60 * 60_000;
const PER_CALL_MS = 2500;
const catalogsAt = new Map(); // connection id → { pipelines, outcomes } (ms), per instance

function apiBase() {
  return checkedBase(process.env.INGEST_HUBSPOT_API_BASE ?? "https://api.hubapi.com");
}

/** The HubSpot API with a connection's token, every call bound to the budget. */
export function hubspotClient(token, budget) {
  const base = apiBase();
  const headers = { authorization: `Bearer ${token}` };
  const call = (method, path, body) => requestJson(`${base}${path}`, { method, headers, body, signal: budget.signal(PER_CALL_MS) });
  return {
    async batchRead(type, ids, properties) {
      const results = [];
      for (let i = 0; i < ids.length; i += BATCH_READ) {
        const part = ids.slice(i, i + BATCH_READ);
        const r = await call("POST", `/crm/v3/objects/${API_OBJECT[type]}/batch/read?archived=false`, { properties, inputs: part.map((id) => ({ id })) });
        results.push(...(r?.results ?? []));
      }
      return results;
    },
    async associations(fromType, toType, ids) {
      const out = new Map();
      for (let i = 0; i < ids.length; i += BATCH_READ) {
        const part = ids.slice(i, i + BATCH_READ);
        const r = await call("POST", `/crm/v4/associations/${API_OBJECT[fromType]}/${API_OBJECT[toType]}/batch/read`, { inputs: part.map((id) => ({ id })) });
        for (const x of r?.results ?? []) out.set(String(x.from?.id), x.to ?? []);
      }
      return out;
    },
    async pipelines(type) {
      return (await call("GET", `/crm/v3/pipelines/${API_OBJECT[type]}`))?.results ?? [];
    },
    async callOutcomes() {
      const r = await call("GET", "/calling/v1/dispositions");
      return Array.isArray(r) ? r : (r?.results ?? []);
    },
    async owners(after) {
      return call("GET", `/crm/v3/owners?limit=100${after ? `&after=${encodeURIComponent(after)}` : ""}`);
    },
  };
}

function unit(events, status, error = null, writes = {}) {
  return { eventIds: events.map((e) => e.eventId), status, error, writes };
}

function pipelinesItem(recordType, list) {
  return list.map((p) => ({
    recordType,
    pipelineId: String(p.id),
    label: String(p.label ?? p.id).slice(0, 200),
    stages: (p.stages ?? []).map((s) => ({
      stageId: String(s.id),
      label: String(s.label ?? s.id).slice(0, 200),
      order: Number.isInteger(s.displayOrder) ? s.displayOrder : 0,
      isClosed: String(s.metadata?.isClosed ?? "").toLowerCase() === "true" || String(s.metadata?.ticketState ?? "").toUpperCase() === "CLOSED",
    })),
  }));
}

async function catalogUnit(api, connectionId, types, budget) {
  const at = catalogsAt.get(connectionId) ?? { pipelines: 0, outcomes: 0 };
  const writes = {};
  const now = Date.now();
  try {
    if ((types.has("deal") || types.has("ticket")) && now - at.pipelines > CATALOG_EVERY_MS && budget.remaining() > 500) {
      writes.pipelines = [...pipelinesItem("deal", await api.pipelines("deal")), ...pipelinesItem("ticket", await api.pipelines("ticket"))];
      at.pipelines = now;
    }
    if (types.has("crm_call") && now - at.outcomes > CATALOG_EVERY_MS && budget.remaining() > 500) {
      writes.callOutcomes = (await api.callOutcomes())
        .filter((o) => o && o.id !== undefined && o.deleted !== true)
        .map((o) => ({ outcomeRef: String(o.id), label: String(o.label ?? o.id).slice(0, 100) }));
      at.outcomes = now;
    }
  } catch (err) {
    // A catalog that cannot be read now is read on a later request; the events do not wait for it
    warn("catalog refresh skipped", { connection: connectionId, code: err?.code ?? "error" });
  }
  catalogsAt.set(connectionId, at);
  return Object.keys(writes).length ? { eventIds: [], status: "processed", error: null, writes } : null;
}

/** Groups events by object; the newest event decides whether the object is read or marked deleted. */
function groupEvents(events) {
  const groups = new Map();
  for (const e of events) {
    const k = `${e.objectType}:${e.objectId}`;
    if (!groups.has(k)) groups.set(k, { objectType: e.objectType, objectId: e.objectId, events: [] });
    groups.get(k).events.push(e);
  }
  for (const g of groups.values()) {
    g.events.sort((a, b) => String(a.occurredAt).localeCompare(String(b.occurredAt)));
    g.latest = g.events[g.events.length - 1];
    g.privacy = g.events.some((e) => e.raw?.privacy === true);
    g.mergedIds = [...new Set(g.events.flatMap((e) => (Array.isArray(e.raw?.mergedObjectIds) ? e.raw.mergedObjectIds : [])))];
  }
  return [...groups.values()];
}

function deletionWrites(objectType, id, at) {
  if (objectType === "deal" || objectType === "ticket") return { records: [{ recordType: objectType, sourceId: id, deletedAt: at }] };
  if (objectType === "contact") return { contacts: [{ sourceId: id, deletedAt: at }] };
  if (objectType === "crm_call") return { calls: [{ sourceId: id, deletedAt: at }] };
  return {};
}

function mergeWrites(a, b) {
  const out = { ...a };
  for (const [k, v] of Object.entries(b)) out[k] = [...(out[k] ?? []), ...v];
  return out;
}

function failGroups(groups, code) {
  return groups.map((g) => unit(g.events, "failed", code));
}

/** The read-back of claimed events → units. */
export async function readBack({ connection, config, events, store, budget }) {
  const units = [];
  const groups = groupEvents(events);
  const toRead = { deal: [], ticket: [], crm_call: [], contact: [] };

  for (const g of groups) {
    if (g.privacy) {
      units.push(unit(g.events, "processed", null, { forgets: [g.objectId] }));
    } else if (!API_OBJECT[g.objectType]) {
      units.push(unit(g.events, "ignored"));
    } else if (g.latest.kind === "deleted") {
      units.push(unit(g.events, "processed", null, deletionWrites(g.objectType, g.objectId, g.latest.occurredAt)));
    } else {
      toRead[g.objectType].push(g);
    }
  }

  // Contacts the CMA does not hold are not read: 0006 takes a contact in only while a record points to it
  if (toRead.contact.length) {
    const held = await store.heldContacts(toRead.contact.flatMap((g) => [g.objectId, ...g.mergedIds]));
    const keep = [];
    for (const g of toRead.contact) {
      if (held.has(g.objectId) || g.mergedIds.some((id) => held.has(id))) keep.push(g);
      else units.push(unit(g.events, "ignored"));
    }
    toRead.contact = keep;
  }

  const pending = Object.values(toRead).flat();
  if (!pending.length) return units;

  let token;
  try {
    token = await getSecret(connection.tokenSecretName);
  } catch (err) {
    return [...units, ...failGroups(pending, err instanceof SecretUnavailable ? "token_unavailable" : "secret_error")];
  }
  const api = hubspotClient(token, budget);
  const readAt = new Date().toISOString();

  // Records: deals and tickets with their contacts
  const contactReads = new Map(); // contact id → object (read once per run)
  for (const recordType of ["deal", "ticket"]) {
    const list = toRead[recordType];
    if (!list.length) continue;
    try {
      const ids = list.map((g) => g.objectId);
      const objects = await api.batchRead(recordType, ids, propertiesFor(recordType, config));
      const assoc = await api.associations(recordType, "contact", ids);
      const storedContact = await store.recordContacts(recordType, ids);
      const storedAssoc = await store.currentAssociations(recordType, ids);
      const byId = new Map(objects.map((o) => [String(o.id), o]));
      const primaries = new Map();
      for (const id of ids) {
        if (byId.has(id)) primaries.set(id, primaryContact(assoc.get(id) ?? [], storedContact.get(id) ?? null));
      }
      const need = [...new Set([...primaries.values()].filter((c) => c && !contactReads.has(c)))];
      if (need.length) for (const c of await api.batchRead("contact", need, propertiesFor("contact", config))) contactReads.set(String(c.id), c);
      for (const g of list) {
        const obj = byId.get(g.objectId);
        if (!obj) {
          units.push(unit(g.events, "ignored"));
          continue;
        }
        const contactId = primaries.get(g.objectId);
        const contactObj = contactId ? contactReads.get(contactId) : null;
        const record = recordFromObject(recordType, obj, config, contactObj ? contactAttributes(contactObj, config) : {});
        if (contactId) record.contactId = contactId;
        let writes = { records: [record] };
        if (contactObj) writes.contacts = [contactFromObject(contactObj, config)];
        const current = (assoc.get(g.objectId) ?? []).map((t) => ({ toType: "contact", toId: String(t.toObjectId) }));
        const diff = associationDiff(recordType, g.objectId, current, storedAssoc, ["contact"], readAt);
        if (diff.length) writes.associations = diff;
        for (const m of g.mergedIds) writes = mergeWrites(writes, deletionWrites(recordType, m, g.latest.occurredAt));
        units.push(unit(g.events, "processed", null, writes));
      }
    } catch (err) {
      units.push(...failGroups(list, err instanceof SourceError ? err.code : "readback_error"));
    }
  }

  // Calls: the hash pepper of the tenant, the engagement, its contacts and deals
  if (toRead.crm_call.length) {
    const list = toRead.crm_call;
    try {
      const slug = await store.tenantSlug();
      let pepper;
      try {
        pepper = await getSecret(`ingest-hash-pepper-${slug}`);
      } catch {
        throw new SourceError("pepper_unavailable");
      }
      const ids = list.map((g) => g.objectId);
      const objects = await api.batchRead("crm_call", ids, propertiesFor("crm_call", config));
      const toContacts = await api.associations("crm_call", "contact", ids);
      const toDeals = await api.associations("crm_call", "deal", ids);
      const storedAssoc = await store.currentAssociations("crm_call", ids);
      const region = typeof config?.settings?.phone_default_region === "string" ? config.settings.phone_default_region.toUpperCase() : null;
      const byId = new Map(objects.map((o) => [String(o.id), o]));
      for (const g of list) {
        const obj = byId.get(g.objectId);
        if (!obj) {
          units.push(unit(g.events, "ignored"));
          continue;
        }
        const current = [
          ...(toContacts.get(g.objectId) ?? []).map((t) => ({ toType: "contact", toId: String(t.toObjectId) })),
          ...(toDeals.get(g.objectId) ?? []).map((t) => ({ toType: "deal", toId: String(t.toObjectId) })),
        ];
        const writes = { calls: [callFromObject(obj, { pepper, region })] };
        const diff = associationDiff("crm_call", g.objectId, current, storedAssoc, ["contact", "deal"], readAt);
        if (diff.length) writes.associations = diff;
        units.push(unit(g.events, "processed", null, writes));
      }
      pepper = null;
    } catch (err) {
      units.push(...failGroups(list, err instanceof SourceError ? err.code : "readback_error"));
    }
  }

  // Contacts the CMA holds: their configured properties
  if (toRead.contact.length) {
    const list = toRead.contact;
    try {
      const ids = list.map((g) => g.objectId).filter((id) => !contactReads.has(id));
      if (ids.length) for (const c of await api.batchRead("contact", ids, propertiesFor("contact", config))) contactReads.set(String(c.id), c);
      for (const g of list) {
        const obj = contactReads.get(g.objectId);
        let writes = obj ? { contacts: [contactFromObject(obj, config)] } : {};
        for (const m of g.mergedIds) writes = mergeWrites(writes, deletionWrites("contact", m, g.latest.occurredAt));
        units.push(unit(g.events, obj || g.mergedIds.length ? "processed" : "ignored", null, writes));
      }
    } catch (err) {
      units.push(...failGroups(list, err instanceof SourceError ? err.code : "readback_error"));
    }
  }

  // Catalogs only when HubSpot answered in this run (a source that is down is not asked twice)
  if (!units.some((u) => u.status === "processed" && u.eventIds.length && pending.some((g) => g.events.some((e) => u.eventIds.includes(e.eventId))))) return units;
  const types = new Set(pending.map((g) => g.objectType));
  const catalogs = await catalogUnit(api, connection.connectionId, types, budget);
  if (catalogs) units.unshift(catalogs);
  return units;
}

/** Test aid: forget when catalogs were last refreshed. */
export function resetCatalogClock() {
  catalogsAt.clear();
}
