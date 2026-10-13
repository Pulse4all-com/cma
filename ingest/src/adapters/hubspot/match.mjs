/**
 * Contact lookups another adapter asks of a HubSpot connection (DESIGN §4.3a): the commerce adapter
 * finds the CRM contact of a store's customer by the customer's email, or, when the store withholds
 * the email, by the customer id in the contact properties the write-back fills (commerce_ref). Both
 * answer at most two contact ids: one is a match, none or two is no match. The email arrives in
 * memory and is never logged, stored or returned.
 *
 * HubSpot's CRM search allows five requests per second per account (developers.hubspot.com, API
 * usage guidelines); these lookups take one per 400 ms per CRM connection and process (RATES.search,
 * half the limit). A job waits for its slot; a webhook's read-back never waits past its budget: the
 * lookup fails with paced and the sweep reads the object again.
 */
import { getSecret, SecretUnavailable } from "../../core/secrets.mjs";
import { SourceError } from "../../core/http.mjs";
import { Pace } from "../../core/pace.mjs";
import { hubspotClient, RATES } from "./read.mjs";

const paces = new Map(); // CRM connection id → the pace of its searches in this process

function paceOf(connectionId) {
  if (!paces.has(connectionId)) paces.set(connectionId, new Pace(RATES.search));
  return paces.get(connectionId);
}

async function slot(connection, budget) {
  const pace = paceOf(connection.connectionId);
  if (Number.isFinite(budget.remaining()) && pace.delay() + 200 > budget.remaining()) throw new SourceError("paced");
  await pace.wait();
}

async function clientOf(connection, budget) {
  let token;
  try {
    token = await getSecret(connection.tokenSecretName);
  } catch (err) {
    throw new SourceError(err instanceof SecretUnavailable ? "token_unavailable" : "secret_error");
  }
  // The search slot above is this module's pace; the client itself does not pace again
  return hubspotClient(token, { signal: (ms) => budget.signal(ms), remaining: () => budget.remaining() });
}

/** The contact ids (at most two) whose email equals the given one, compared in lower case. */
export async function findContactsByEmail({ connection, email, budget }) {
  const value = typeof email === "string" ? email.trim().toLowerCase() : "";
  if (!value || value.length > 254 || !value.includes("@")) return [];
  const api = await clientOf(connection, budget);
  await slot(connection, budget);
  return api.contactIdsWhere("email", value);
}

/** The contact ids (at most two) holding the value in any of the properties (one search, OR across them). */
export async function findContactsByProperties({ connection, properties, value, budget }) {
  const props = [...new Set((properties ?? []).filter((p) => typeof p === "string" && /^[a-z0-9_]{1,100}$/.test(p)))].slice(0, 5);
  const v = typeof value === "string" ? value.trim() : "";
  if (!props.length || !v) return [];
  const api = await clientOf(connection, budget);
  await slot(connection, budget);
  const r = await api.search("contact", {
    filterGroups: props.map((p) => ({ filters: [{ propertyName: p, operator: "EQ", value: v }] })),
    properties: ["hs_object_id"], limit: 2,
  });
  return [...new Set((r?.results ?? []).map((x) => String(x.id)))];
}

/** Test aid: forget the search paces of this process. */
export function resetSearchPaces() {
  paces.clear();
}
