/**
 * The outbox worker's HubSpot side (DESIGN §4.3a; migration 0007c): claimed contact write-backs are
 * applied against each contact's current values and written in one batch update.
 *
 *   read     POST /crm/v3/objects/contacts/batch/read with the connection's write-back properties
 *            (cma.connection_config().writeback, enabled rows only)
 *   plan     per action, the modes against the values just read (planWrite, pure):
 *              always    written when different
 *              if_empty  written only into an empty property (an agent's country, currency or
 *                        language is never overwritten)
 *              slot      commerce_ref only: the id already in a slot → nothing; else the first empty
 *                        slot (1, then 2); every slot held by another id → nothing (slots_full)
 *            commerce_store, commerce_orders and commerce_spent describe the customer in slot 1:
 *            written only when this customer's id is, or just became, slot 1, whatever their mode
 *   write    POST /crm/v3/objects/contacts/batch/update with every contact's difference, at most
 *            100 contacts a call (the claim takes 50); a property that is not an enabled write-back
 *            property of the connection is refused here again (property_not_configured), so the
 *            code can never write what the configuration does not name
 *   finish   per action: sent with the result (properties written and skipped with the reason, the
 *            commerce ref's state and slot), or failed with a short code: rate_limited, timeout,
 *            unreachable, http_<status>, contact_not_found, contact_rejected; the claim already set
 *            the next attempt (backoff), and the database parks an action after outbox.max_attempts
 *
 * Nothing here logs a value; the result holds property names, reasons and the slot.
 */
import { getSecret, SecretUnavailable } from "../../core/secrets.mjs";
import { SourceError } from "../../core/http.mjs";
import { hubspotClient } from "./read.mjs";

const BATCH = 100;
const NUMERIC = new Set(["commerce_orders", "commerce_spent"]);
const SLOT_ONE_ONLY = new Set(["commerce_store", "commerce_orders", "commerce_spent"]);
const ORDER = ["commerce_ref", "commerce_store", "commerce_orders", "commerce_spent", "country", "currency", "language"];

export class NotConfigured extends Error {
  constructor(property) {
    super(`property ${property} is not an enabled write-back property`);
    this.code = "property_not_configured";
  }
}

function empty(v) {
  return v === undefined || v === null || String(v).trim() === "";
}

function same(field, a, b) {
  if (empty(a) || empty(b)) return empty(a) && empty(b);
  if (NUMERIC.has(field)) return Number(a) === Number(b);
  return String(a).trim() === String(b).trim();
}

/** The enabled write-back fields of a connection config, as { field, slot, property, mode }. */
export function enabledFields(config) {
  return (config?.writeback ?? []).filter((w) => w?.enabled === true && typeof w.property === "string" && w.property)
    .map((w) => ({ field: w.field, slot: Number(w.slot ?? 1), property: w.property, mode: w.mode }));
}

/**
 * One action's plan: { properties: {property: value}, written: [property], skipped: {property: reason},
 * ref: "written" | "present" | "slots_full" | null, slot: number | null }. payload: canonical field →
 * value; fields: enabledFields(); current: the contact's current values by property.
 */
export function planWrite(payload, fields, current) {
  const properties = {};
  const skipped = {};
  const put = (f, value) => { properties[f.property] = String(value); };
  let ref = null;
  let slot = null;

  const refFields = fields.filter((f) => f.field === "commerce_ref").sort((a, b) => a.slot - b.slot);
  const id = empty(payload?.commerce_ref) ? null : String(payload.commerce_ref).trim();
  if (id && refFields.length) {
    const holding = refFields.find((f) => same("commerce_ref", current[f.property], id));
    if (holding) {
      ref = "present";
      slot = holding.slot;
      for (const f of refFields) if (f !== holding) skipped[f.property] = "not_needed";
      skipped[holding.property] = "unchanged";
    } else {
      for (const f of refFields) {
        if (slot !== null) {
          skipped[f.property] = "not_needed";
          continue;
        }
        if (f.mode === "always" || ((f.mode === "slot" || f.mode === "if_empty") && empty(current[f.property]))) {
          put(f, id);
          ref = "written";
          slot = f.slot;
        } else {
          skipped[f.property] = "slot_taken";
        }
      }
      if (slot === null) ref = "slots_full";
    }
  }

  for (const name of ORDER.slice(1)) {
    const f = fields.find((x) => x.field === name);
    if (!f) continue;
    const value = payload?.[name];
    if (empty(value)) continue;
    if (SLOT_ONE_ONLY.has(name) && slot !== 1) {
      skipped[f.property] = "not_slot_one";
      continue;
    }
    if (f.mode === "if_empty") {
      if (empty(current[f.property])) put(f, value);
      else skipped[f.property] = same(name, current[f.property], value) ? "unchanged" : "not_empty";
    } else if (same(name, current[f.property], value)) {
      skipped[f.property] = "unchanged";
    } else {
      put(f, value);
    }
  }
  return { properties, written: Object.keys(properties), skipped, ref, slot };
}

/** Refuses any property the connection's enabled write-back fields do not name. */
export function assertConfigured(properties, fields) {
  const allowed = new Set(fields.map((f) => f.property));
  for (const p of Object.keys(properties)) if (!allowed.has(p)) throw new NotConfigured(p);
}

function resultOf(plan) {
  return { written: plan.written, skipped: plan.skipped, ref: plan.ref, slot: plan.slot };
}

/**
 * Applies claimed actions of one CRM connection. actions: rows of cma.outbox_claim (action_id,
 * target_type, target_id, payload). Answers [{ ids, outcome: sent|failed, result, error }], one group
 * per outcome and result shape, for cma.outbox_finish.
 */
export async function writeContacts({ connection, config, actions, budget }) {
  const out = [];
  const fail = (list, code) => { if (list.length) out.push({ ids: list.map((a) => a.action_id), outcome: "failed", result: null, error: code }); };
  const fields = enabledFields(config);
  const mine = actions.filter((a) => a.action === "crm.contact.set_properties" && a.target_type === "contact");
  fail(actions.filter((a) => !mine.includes(a)), "action_not_supported");
  if (!mine.length) return out;
  if (!fields.length) {
    fail(mine, "writeback_not_configured");
    return out;
  }

  let token;
  try {
    token = await getSecret(connection.tokenSecretName);
  } catch (err) {
    fail(mine, err instanceof SecretUnavailable ? "token_unavailable" : "secret_error");
    return out;
  }
  const api = hubspotClient(token, budget);

  let current;
  try {
    const ids = [...new Set(mine.map((a) => String(a.target_id)))];
    current = new Map((await api.batchRead("contact", ids, [...new Set(fields.map((f) => f.property))]))
      .map((c) => [String(c.id), c.properties ?? {}]));
  } catch (err) {
    fail(mine, err instanceof SourceError ? err.code : "readback_error");
    return out;
  }

  const planned = [];
  for (const a of mine) {
    const values = current.get(String(a.target_id));
    if (!values) {
      fail([a], "contact_not_found");
      continue;
    }
    const plan = planWrite(a.payload ?? {}, fields, values);
    try {
      assertConfigured(plan.properties, fields);
    } catch (err) {
      fail([a], err.code);
      continue;
    }
    planned.push({ action: a, plan });
  }

  const toWrite = planned.filter((p) => p.plan.written.length);
  for (const p of planned.filter((x) => !x.plan.written.length)) out.push({ ids: [p.action.action_id], outcome: "sent", result: resultOf(p.plan), error: null });
  for (let i = 0; i < toWrite.length; i += BATCH) {
    const part = toWrite.slice(i, i + BATCH);
    let r;
    try {
      r = await api.batchUpdate("contact", part.map((p) => ({ id: String(p.action.target_id), properties: p.plan.properties })));
    } catch (err) {
      fail(part.map((p) => p.action), err instanceof SourceError ? err.code : "write_error");
      continue;
    }
    // A 207 names the contacts it could not update; the others were written
    const rejected = new Set((r?.errors ?? []).flatMap((e) => (Array.isArray(e?.context?.ids) ? e.context.ids.map(String) : [])));
    for (const p of part) {
      if (rejected.has(String(p.action.target_id))) fail([p.action], "contact_rejected");
      else out.push({ ids: [p.action.action_id], outcome: "sent", result: resultOf(p.plan), error: null });
    }
  }
  return out;
}
