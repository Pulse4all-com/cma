/**
 * Contact lookups another adapter asks of a HubSpot connection (DESIGN §4.3a; addition 0008h): the
 * commerce adapter finds the CRM contact of a store's customer by the customer's email, or, when the
 * store withholds the email, by the customer id in the contact properties that hold it (the
 * connection's contact ref fields). Both answer at most two contact ids: one is a match, none or two
 * is no match. The email arrives in memory and is never logged, stored or returned. existingContacts
 * checks that contacts the CMA linked earlier still exist as themselves (one batch read, not a
 * search): a deleted contact, or one merged into another, is not among them.
 *
 * HubSpot's CRM search allows five requests per second per account (developers.hubspot.com, API
 * usage guidelines); these lookups take one per 400 ms per CRM connection and process (RATES.search,
 * half the limit). A job waits for its slot; a webhook's read-back never waits past its budget: the
 * lookup fails with paced and the sweep reads the object again.
 *
 * The legacy call import (addition 0008zg) asks two more: findContactsByAnyEmail (the primary email, then the
 * additional emails, each candidate of the second confirmed by its stored list) and findContactsByPhone (an E.164
 * number searched by its national number on HubSpot's searchable phone properties, which hold the number without its
 * country code, then at most five candidates read and kept only when their phone or mobile phone, normalised with the
 * number's region, is that E.164). missingContactProperties says which of these properties the portal lacks, so the
 * job never relies on a property the live portal does not hold. The number and the email are never logged, stored or
 * returned.
 */
import { parsePhoneNumberFromString } from "libphonenumber-js";
import { getSecret, SecretUnavailable } from "../../core/secrets.mjs";
import { SourceError } from "../../core/http.mjs";
import { Pace } from "../../core/pace.mjs";
import { toE164 } from "../../core/hash.mjs";
import { hubspotClient, RATES } from "./read.mjs";

/** The contact properties the email and phone lookups of the legacy call import rely on (addition 0008zg) */
export const ADDITIONAL_EMAILS = "hs_additional_emails";
export const PHONE_SEARCH_PROPERTIES = ["hs_searchable_calculated_phone_number", "hs_searchable_calculated_mobile_number"];
export const PHONE_PROPERTIES = ["phone", "mobilephone"];
export const LOOKUP_PROPERTIES = [ADDITIONAL_EMAILS, ...PHONE_SEARCH_PROPERTIES, ...PHONE_PROPERTIES];
/** Candidates read to confirm a search that cannot be exact; a search holding more reads as several */
export const MAX_CANDIDATES = 5;

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
  // The search slot above is this module's pace; the client itself does not pace again. A job's budget also counts the
  // requests, takes HubSpot's daily reading and pauses below its floor (the reviews' lookups, addition 0008ze); a
  // webhook's budget has none of the three
  return hubspotClient(token, {
    signal: (ms) => budget.signal(ms), remaining: () => budget.remaining(),
    guard: () => budget.guard?.(), count: (endpoint) => budget.count?.(endpoint),
    ...(budget.observeDaily ? { observeDaily: (reading) => budget.observeDaily(reading) } : {}),
  });
}

/** An email as the lookups compare it: trimmed, lower case, at most 254 characters with an @; else "" */
function emailOf(email) {
  const value = typeof email === "string" ? email.trim().toLowerCase() : "";
  return value && value.length <= 254 && value.includes("@") ? value : "";
}

/** The contact ids (at most two) whose email equals the given one, compared in lower case. */
export async function findContactsByEmail({ connection, email, budget }) {
  const value = emailOf(email);
  if (!value) return [];
  const api = await clientOf(connection, budget);
  await slot(connection, budget);
  return api.contactIdsWhere("email", value);
}

/**
 * The ids of a search's candidates (one search, at most MAX_CANDIDATES), read with `properties` and kept when keep(the
 * contact's properties) holds; at most two ids. A search holding more candidates than it read cannot be confirmed: its
 * first two candidates answer, which reads as several.
 */
async function confirmedCandidates(connection, budget, filterGroups, properties, keep) {
  const api = await clientOf(connection, budget);
  await slot(connection, budget);
  const r = await api.search("contact", { filterGroups, properties: ["hs_object_id"], limit: MAX_CANDIDATES });
  const ids = [...new Set((r?.results ?? []).map((x) => String(x.id)))];
  if (!ids.length) return [];
  if (Number(r?.total ?? ids.length) > MAX_CANDIDATES) return ids.slice(0, 2);
  const found = await api.batchRead("contact", ids, properties);
  return [...new Set(found.filter((c) => keep(c.properties ?? {})).map((c) => String(c.id)))].slice(0, 2);
}

/**
 * The contact ids (at most two) of an email: those whose primary email equals it; when none does, those whose
 * additional emails (hs_additional_emails, the addresses separated by ;) hold it, each candidate confirmed by its list.
 */
export async function findContactsByAnyEmail({ connection, email, budget }) {
  const value = emailOf(email);
  if (!value) return [];
  const primary = await findContactsByEmail({ connection, email: value, budget });
  if (primary.length) return primary;
  return confirmedCandidates(connection, budget,
    [{ filters: [{ propertyName: ADDITIONAL_EMAILS, operator: "CONTAINS_TOKEN", value }] }], [ADDITIONAL_EMAILS],
    (p) => String(p[ADDITIONAL_EMAILS] ?? "").split(";").some((x) => x.trim().toLowerCase() === value));
}

/**
 * The contact ids (at most two) of an E.164 number (anything else finds none): the contacts whose searchable phone or
 * mobile number equals the number's national number (HubSpot's phone search drops the country code, so the same
 * national number in another country is a candidate too), kept when their phone or mobile phone, normalised with the
 * number's region, is the number itself.
 */
export async function findContactsByPhone({ connection, e164, budget }) {
  const text = typeof e164 === "string" ? e164.trim() : "";
  let parsed = null;
  try {
    parsed = /^\+[1-9]\d{6,14}$/.test(text) ? parsePhoneNumberFromString(text) : null;
  } catch {
    parsed = null;
  }
  if (!parsed || parsed.number !== text || !parsed.isPossible()) return [];
  const region = parsed.country ?? null;
  return confirmedCandidates(connection, budget,
    PHONE_SEARCH_PROPERTIES.map((p) => ({ filters: [{ propertyName: p, operator: "EQ", value: parsed.nationalNumber }] })), PHONE_PROPERTIES,
    (p) => PHONE_PROPERTIES.some((name) => toE164(p[name], region) === text));
}

/** Which of the given contact properties the portal does not hold (a 404 on its definition); [] when all exist. */
export async function missingContactProperties({ connection, names, budget }) {
  const api = await clientOf(connection, budget);
  const missing = [];
  for (const name of names) {
    try {
      await api.property("contact", name);
    } catch (err) {
      if (err instanceof SourceError && err.code === "http_404") missing.push(name);
      else throw err;
    }
  }
  return missing;
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

/**
 * The contact ids among ids that HubSpot still holds under the same id (a batch read of 100 at a
 * time, the object id only). A contact merged into another answers with the other's id, so it is
 * not among them; a deleted one is missing.
 */
export async function existingContacts({ connection, ids, budget }) {
  const want = [...new Set((ids ?? []).map(String).filter((id) => /^\d{1,20}$/.test(id)))];
  if (!want.length) return new Set();
  const api = await clientOf(connection, budget);
  const found = await api.batchRead("contact", want, ["hs_object_id"]);
  const answered = new Set(found.map((c) => String(c.id)));
  return new Set(want.filter((id) => answered.has(id)));
}

/** Test aid: forget the search paces of this process. */
export function resetSearchPaces() {
  paces.clear();
}
