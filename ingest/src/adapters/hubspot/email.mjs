/**
 * HubSpot email engagements (source kind crm_email; addition 0008m, brief B17b): emails sent from the
 * CRM, logged by BCC, replies to logged emails. No webhook: polled every minute (src/jobs/poll-email.mjs),
 * read by the nightly reconcile for the last 26 hours, backfilled from cma.email_start_date_of.
 *
 *   list         POST /crm/v3/objects/emails/search by hs_lastmodifieddate, ascending, 100 a page, the
 *                allowed properties only (crm.objects.contacts.read and crm.objects.emails.read)
 *   map          direction (hs_email_direction EMAIL, INCOMING_EMAIL, FORWARDED_EMAIL → out, in,
 *                forwarded), status (hs_email_status whose value in lower case is sent, bounced,
 *                failed or scheduled; anything else other), time, the owner, the CRM thread id and
 *                the automation origin when the connection names their properties (settings
 *                email_thread_property, email_origin_property, email_automated_origins), the category
 *   associations email → contact, deal, ticket (v4 batch read), stored in their one direction
 *   contacts     the contact the email points to (labelled primary, else the lowest id) read once,
 *                after the email is written (R6: ingest_upsert_contacts holds it only then)
 *
 * Metadata only (R1): the subject (hs_email_subject) is asked for only while the connection has an
 * active subject rule, the sender's address (hs_email_from_email) only while it has an active sender
 * domain rule; both are matched in memory (rules.mjs) and dropped. Body, text, html, headers,
 * attachments, recipients and names are never asked for. Actors (R2): an outgoing or forwarded email
 * with an owner is the agent's (owner id); one whose origin value the connection lists as automated
 * is the system's; an incoming one the customer's; anything else unknown.
 */
import { SourceError } from "../../core/http.mjs";
import { hubspotClient, tokenOf } from "./read.mjs";
import { searchPages } from "./search.mjs";
import { iso, propertiesFor, contactFromObject, primaryContact, associationDiff } from "./map.mjs";
import { activeRules, ruleNeeds, classify, domainOf } from "./rules.mjs";

export const ENGAGEMENTS_STREAM = "email:engagements";
export const EMAIL_PROPERTIES = ["hs_timestamp", "hs_email_direction", "hs_email_status", "hubspot_owner_id", "hs_createdate", "hs_lastmodifieddate"];
export const RULE_PROPERTIES = { subject: "hs_email_subject", senderDomain: "hs_email_from_email" };
const DIRECTIONS = { EMAIL: "out", INCOMING_EMAIL: "in", FORWARDED_EMAIL: "forwarded" };
const STATUSES = new Set(["sent", "bounced", "failed", "scheduled"]);
const REF = /^[^@\s]{1,100}$/;
const CODE = /^[A-Za-z0-9_.:-]{1,60}$/;
const PROPERTY = /^[a-z0-9_]{1,100}$/;

// ---- Pure ---------------------------------------------------------------------------------------

/**
 * The connection's email settings (cma.set_connection_settings; flat values): email_poll (true:
 * the poll serves the connection), email_thread_property and email_origin_property (engagement
 * properties, read from GET /crm/v3/properties/emails), email_automated_origins (comma-separated
 * values of the origin property that mean an automation sent the email).
 */
export function emailSettings(config) {
  const s = config?.settings ?? {};
  const prop = (v) => (typeof v === "string" && PROPERTY.test(v.trim()) ? v.trim() : null);
  return {
    enabled: s.email_poll === true,
    threadProperty: prop(s.email_thread_property),
    originProperty: prop(s.email_origin_property),
    automated: new Set(String(s.email_automated_origins ?? "").split(",").map((x) => x.trim().toLowerCase()).filter(Boolean)),
  };
}

/** The properties a search asks for: the structural ones, the configured thread and origin, the rule values only when a rule needs them. */
export function emailProperties(settings, rules) {
  const needs = ruleNeeds(rules);
  const set = new Set(EMAIL_PROPERTIES);
  if (settings.threadProperty) set.add(settings.threadProperty);
  if (settings.originProperty) set.add(settings.originProperty);
  if (needs.subject) set.add(RULE_PROPERTIES.subject);
  if (needs.senderDomain) set.add(RULE_PROPERTIES.senderDomain);
  return [...set].sort();
}

/** The status in the CMA's words: a source value that is one of them (any case), else other. */
export function emailStatus(value) {
  const v = String(value ?? "").trim().toLowerCase();
  return STATUSES.has(v) ? v : "other";
}

/**
 * An engagement → an ingest_upsert_emails item, or null when its direction is not one of the three
 * (the caller counts it skipped). contactId is set by the caller from the associations. Nothing of
 * the subject or the sender leaves this function but the category.
 */
export function emailFromObject(obj, settings, rules) {
  const p = obj?.properties ?? {};
  const direction = DIRECTIONS[String(p.hs_email_direction ?? "").toUpperCase()] ?? null;
  if (!direction || !REF.test(String(obj?.id ?? ""))) return null;
  const owner = /^\d{1,30}$/.test(String(p.hubspot_owner_id ?? "")) ? String(p.hubspot_owner_id) : null;
  const originRaw = settings.originProperty ? String(p[settings.originProperty] ?? "").trim() : "";
  const origin = CODE.test(originRaw) ? originRaw : null;
  const threadRaw = settings.threadProperty ? String(p[settings.threadProperty] ?? "").trim() : "";
  let actorKind = "unknown";
  if (direction === "in") actorKind = "customer";
  else if (origin && settings.automated.has(origin.toLowerCase())) actorKind = "system";
  else if (owner) actorKind = "agent";
  const category = rules.length
    ? classify({ subject: typeof p[RULE_PROPERTIES.subject] === "string" ? p[RULE_PROPERTIES.subject] : null,
      senderDomain: domainOf(p[RULE_PROPERTIES.senderDomain]) }, rules)
    : null;
  const raw = { direction: String(p.hs_email_direction).toUpperCase() };
  if (CODE.test(String(p.hs_email_status ?? ""))) raw.status = String(p.hs_email_status);
  if (origin) raw.origin = origin;
  return {
    sourceKind: "crm_email",
    sourceId: String(obj.id),
    threadId: REF.test(threadRaw) ? threadRaw : null,
    direction,
    status: emailStatus(p.hs_email_status),
    occurredAt: iso(p.hs_timestamp) ?? iso(p.hs_createdate) ?? iso(obj.createdAt),
    actorKind,
    ownerRef: actorKind === "agent" ? owner : null,
    category,
    createdAt: iso(p.hs_createdate) ?? iso(obj.createdAt),
    updatedAt: iso(obj.updatedAt) ?? iso(p.hs_lastmodifieddate),
    raw,
  };
}

/** Run counts (sync_run) from a write's outcomes; the detail per kind goes to the log line. */
export function tally(counts, detail, kind, outcomes) {
  detail[kind] ??= {};
  for (const [k, n] of Object.entries(outcomes ?? {})) {
    detail[kind][k] = (detail[kind][k] ?? 0) + n;
    if (kind === "associations") continue;
    if (k === "inserted" || k === "updated" || k === "deleted") counts.upserted += n;
    else if (k === "stale") counts.stale += n;
    else counts.skipped += n;
  }
}

// ---- With HubSpot and the database ----------------------------------------------------------------

/**
 * The contacts a page's emails or threads point to that the CMA has no row for yet, read with the
 * configured properties and written after the emails and threads (R6).
 */
export async function writeContacts(api, store, config, ids, counts, detail) {
  const unique = [...new Set(ids.filter(Boolean))];
  if (!unique.length) return;
  const stored = await store.storedContacts(unique);
  const need = unique.filter((id) => !stored.has(id));
  if (!need.length) return;
  // An empty property list would bring HubSpot's defaults (email, names): ask for the id alone then
  const properties = propertiesFor("contact", config);
  const objects = await api.batchRead("contact", need, properties.length ? properties : ["hs_object_id"]);
  if (objects.length) tally(counts, detail, "contacts", await store.upsertContacts(objects.map((o) => contactFromObject(o, config))));
}

/** One page of engagements: emails, then associations, then contacts. */
export async function writeEmailPage(api, store, config, objects, counts, detail, readAt = new Date().toISOString()) {
  const settings = emailSettings(config);
  const rules = activeRules(config);
  counts.fetched += objects.length;
  // An email the CMA holds at this version is not written again (every update is an audit row): the
  // poll's boundary and the nightly reconcile list most emails a second time
  const versions = await store.emailVersions("crm_email", objects.map((o) => String(o.id)));
  const items = [];
  for (const o of objects) {
    const item = emailFromObject(o, settings, rules);
    const held = versions.get(String(o?.id));
    if (!item || (held && item.updatedAt && Date.parse(item.updatedAt) <= held)) counts.skipped += 1;
    else items.push(item);
  }
  if (!items.length) return;
  const ids = items.map((i) => i.sourceId);
  const toContacts = await api.associations("crm_email", "contact", ids);
  const toDeals = await api.associations("crm_email", "deal", ids);
  const toTickets = await api.associations("crm_email", "ticket", ids);
  for (const i of items) i.contactId = primaryContact(toContacts.get(i.sourceId) ?? []);
  tally(counts, detail, "emails", await store.upsertEmails(items));
  const stored = await store.currentAssociations("crm_email", ids);
  const assoc = [];
  for (const id of ids) {
    const current = [
      ...(toContacts.get(id) ?? []).map((t) => ({ toType: "contact", toId: String(t.toObjectId) })),
      ...(toDeals.get(id) ?? []).map((t) => ({ toType: "deal", toId: String(t.toObjectId) })),
      ...(toTickets.get(id) ?? []).map((t) => ({ toType: "ticket", toId: String(t.toObjectId) })),
    ];
    assoc.push(...associationDiff("crm_email", id, current, stored, ["contact", "deal", "ticket"], readAt));
  }
  if (assoc.length) tally(counts, detail, "associations", await store.upsertAssociations(assoc));
  await writeContacts(api, store, config, items.map((i) => i.contactId), counts, detail);
}

/**
 * The poll's engagements: modified since the cursor (on the first poll the last 26 hours, not before
 * the email start), page by page until done or the deadline; the cursor moves after each page written,
 * so a failed read (429, timeout) leaves it where the last page put it.
 */
export async function pollEmails({ api, store, config, now, floorMs, deadline, counts, detail }) {
  const cur = await store.cursor(ENGAGEMENTS_STREAM);
  const from = Number.isFinite(cur?.at) ? cur.at : Math.max(floorMs ?? 0, now - 26 * 60 * 60_000);
  const properties = emailProperties(emailSettings(config), activeRules(config));
  let at = from;
  for await (const page of searchPages(api, "crm_email", "hs_lastmodifieddate", from, null, { properties })) {
    if (page.results.length) await writeEmailPage(api, store, config, page.results, counts, detail);
    if (page.last !== null && page.last > at) at = page.last;
    await store.setCursor(ENGAGEMENTS_STREAM, { at });
    if (Date.now() > deadline) break;
  }
  if (!Number.isFinite(cur?.at)) await store.setCursor(ENGAGEMENTS_STREAM, { at });
}

async function emailContext(connection, store, budget) {
  const config = await store.config();
  if (!emailSettings(config).enabled) return null;
  return { config, api: hubspotClient(await tokenOf(connection), budget) };
}

/** The nightly reconcile: engagements modified in the look-back, written as the poll writes them. */
export async function reconcileEmails({ connection, store, budget, sinceMs, untilMs, counts }) {
  const c = await emailContext(connection, store, budget);
  if (!c) return;
  const properties = emailProperties(emailSettings(c.config), activeRules(c.config));
  const detail = {};
  for await (const page of searchPages(c.api, "crm_email", "hs_lastmodifieddate", sinceMs, untilMs, { properties })) {
    if (page.results.length) await writeEmailPage(c.api, store, c.config, page.results, counts, detail);
  }
}

/**
 * The backfill: engagements by their time (hs_timestamp) from fromMs up to the run's start, resumable
 * through backfill:crm_email:hs_timestamp ({ from, value, done }) after every page.
 */
export async function backfillEmails({ connection, store, budget, fromMs, untilMs, counts }) {
  const c = await emailContext(connection, store, budget);
  if (!c) throw new SourceError("email_poll_not_enabled");
  const stream = "backfill:crm_email:hs_timestamp";
  const cur = await store.cursor(stream);
  if (cur?.from === fromMs && cur.done) return;
  const start = cur?.from === fromMs && Number.isFinite(cur.value) ? Math.max(fromMs, cur.value) : fromMs;
  const properties = emailProperties(emailSettings(c.config), activeRules(c.config));
  const detail = {};
  let last = start;
  for await (const page of searchPages(c.api, "crm_email", "hs_timestamp", start, untilMs, { properties })) {
    if (page.results.length) await writeEmailPage(c.api, store, c.config, page.results, counts, detail);
    if (page.last !== null) last = Math.max(last, page.last);
    await store.setCursor(stream, { from: fromMs, value: last, done: false });
  }
  await store.setCursor(stream, { from: fromMs, value: last, done: true });
}
