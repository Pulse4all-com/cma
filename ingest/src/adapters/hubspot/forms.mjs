/**
 * HubSpot forms (DESIGN §2, §4.1, §5 poll-forms): no webhook exists for form submissions, so they
 * are polled.
 *
 *   catalog      GET /marketing/v3/forms, at most hourly per connection → cma.ingest_upsert_forms:
 *                names, and each form's fields (name, kind, the option values of a choice field; no
 *                label) → cma.connection_form_field (addition 0008p, brief B17d). Counted, polled,
 *                lead source, market, category and kept fields stay configuration
 *   submissions  per polled, active form (is_polled, whether or not it counts in Intake) GET
 *                /form-integrations/v1/submissions/forms/{guid}, newest first, 50 per page, until the
 *                form's cursor (submittedAt + conversion id); on the first poll of a form, until
 *                intake.start_date
 *   contact      the submitted email (the value of the form definition's email field) is looked up
 *                with a CRM search on that property; one contact → resolved with its id, none →
 *                not_found, several → ambiguous, no email → no_email. The email lives in memory for
 *                that search only: it is never written, logged or returned
 *   page         host and path only, the UTM parameters parsed from the query (src/core/page.mjs)
 *   answers      only the form's kept fields that are choice fields of its catalog (dropdown, radio,
 *                multiple checkboxes, single checkbox), never the email field, and only when every
 *                value is one of the field's current options (a multiple-checkboxes answer, "A;B",
 *                becomes the list of its options); any other answer is left out and counted as
 *                dropped in the run's counts. Never free text, an address, a serial number or a bank
 *                field. A form whose fields the catalog has not described yet keeps no answer
 *
 * A search that fails (429, timeout) stops that form without moving its cursor, so the next run reads
 * the same submissions again (they are idempotent on the conversion id). The cursor moves only when
 * a run reached the old cursor (or the start date), so an interrupted run loses nothing.
 */
import { createHash } from "node:crypto";
import { SourceError } from "../../core/http.mjs";
import { parsePage } from "../../core/page.mjs";
import { warn } from "../../core/log.mjs";
import { hubspotClient, tokenOf } from "./read.mjs";

export const CATALOG_STREAM = "forms:catalog";
export const CATALOG_EVERY_MS = 60 * 60_000;
const PAGE_CAP = 100; // pages of 50 per form and run (5000 submissions); beyond that the backfill reads the rest
const FIELD_NAME = /^[A-Za-z0-9_.-]{1,100}$/;
const MAX_FIELDS = 200;
const MAX_OPTIONS = 500;
/** The kinds of field whose answers may be kept: their values are the field's options */
export const CHOICE_KINDS = new Set(["dropdown", "radio", "multiple_checkboxes", "single_checkbox"]);
/** A single checkbox has no options in the form's definition; its submitted value is true or false */
const CHECKBOX_OPTIONS = ["true", "false"];

export const pollStream = (formId) => `forms:${formId}`;
export const backfillStream = (formId) => `backfill:forms:${formId}`;
/**
 * A short key of a form's kept fields, kept in its backfill cursor: a finished backfill from the same date
 * is skipped only while the kept fields are the ones it read with, so a change to them makes the next
 * backfill read the form again and fill the answers of submissions stored without them
 */
export const keptKeyOf = (form) => createHash("sha256").update(JSON.stringify([...(form?.keptFields ?? [])].sort())).digest("hex").slice(0, 16);

// ---- Pure ---------------------------------------------------------------------------------------

/**
 * A form field (v3) → its catalog field: the name, the kind (HubSpot's fieldType when it is one of the
 * four choice kinds, else other) and, for a choice field, the option values (each once, at most 200
 * characters; a single checkbox's true and false). Labels are not kept.
 */
export function fieldOf(field) {
  const type = String(field?.fieldType ?? "");
  const kind = CHOICE_KINDS.has(type) ? type : "other";
  let options = [];
  if (kind === "single_checkbox") options = CHECKBOX_OPTIONS;
  else if (kind !== "other") {
    options = [...new Set((field?.options ?? []).map((o) => o?.value).filter((v) => typeof v === "string" && v.length >= 1 && v.length <= 200))]
      .slice(0, MAX_OPTIONS);
  }
  return { name: String(field.name), kind, options };
}

/** A form definition (v3) → its catalog item: id, name and its fields (a name that is no field name left out, each once). */
export function catalogItem(form) {
  const fields = [];
  const seen = new Set();
  for (const f of (form?.fieldGroups ?? []).flatMap((g) => g?.fields ?? [])) {
    const name = String(f?.name ?? "");
    if (!FIELD_NAME.test(name) || seen.has(name)) continue;
    seen.add(name);
    fields.push(fieldOf(f));
  }
  return { formId: String(form.id), name: String(form.name ?? form.id).slice(0, 200), fields: fields.slice(0, MAX_FIELDS) };
}

/** The name of the form's email field: the field of type email, else a contact field named email; null when none. */
export function emailFieldOf(form) {
  const fields = (form?.fieldGroups ?? []).flatMap((g) => g?.fields ?? []);
  const typed = fields.find((f) => String(f?.fieldType ?? "").toLowerCase() === "email" && f?.name);
  if (typed) return String(typed.name);
  const named = fields.find((f) => String(f?.name ?? "").toLowerCase() === "email" && (f?.objectTypeId ?? "0-1") === "0-1");
  return named ? String(named.name) : null;
}

/** The submitted email, trimmed, or null. In memory only. */
export function emailOf(submission, emailField) {
  if (!emailField) return null;
  const v = (submission?.values ?? []).find((x) => x?.name === emailField)?.value;
  const s = typeof v === "string" ? v.trim() : "";
  return s && s.length <= 254 && s.includes("@") ? s : null;
}

/**
 * One field's answer as kept: a choice field's option value, or for multiple checkboxes the sorted list
 * of its options ("A;B", or several values of the same name); null when there is no answer; undefined
 * when the answer cannot be kept (the field is no choice field of the catalog, or a value is no option).
 */
export function answerOf(field, raws) {
  const texts = (raws ?? []).filter((r) => r !== null && r !== undefined && r !== "")
    .map((r) => (typeof r === "string" ? r : typeof r === "number" || typeof r === "boolean" ? String(r) : null));
  if (!texts.length) return null;
  if (!field || !CHOICE_KINDS.has(field.kind) || texts.includes(null)) return undefined;
  const options = new Set(field.options ?? []);
  if (field.kind !== "multiple_checkboxes") return texts.length === 1 && options.has(texts[0]) ? texts[0] : undefined;
  const parts = texts.flatMap((t) => (options.has(t) ? [t] : t.split(";").map((p) => p.trim()).filter(Boolean)));
  if (!parts.length || parts.length > 50 || !parts.every((p) => options.has(p))) return undefined;
  return [...new Set(parts)].sort();
}

/**
 * The submission's answers of the form's kept fields (never the email field), checked against the
 * catalog's fields (form.fields: name, kind, options): { values, dropped }, dropped counting the answers
 * left out. A form the catalog has not described has no fields, so every answer of it is dropped.
 */
export function answersOf(submission, form, emailField) {
  const fields = new Map((form?.fields ?? []).map((f) => [f.name, f]));
  const given = new Map();
  for (const v of submission?.values ?? []) {
    if (!v?.name) continue;
    given.set(v.name, [...(given.get(v.name) ?? []), v.value]);
  }
  const values = {};
  let dropped = 0;
  for (const name of new Set((form?.keptFields ?? []).filter((f) => f && f !== emailField))) {
    if (!given.has(name)) continue;
    const answer = answerOf(fields.get(name), given.get(name));
    if (answer === undefined) dropped += 1;
    else if (answer !== null) values[name] = answer;
  }
  return { values, dropped };
}

const atOf = (s) => {
  const n = Number(s?.submittedAt);
  return Number.isFinite(n) && n > 0 ? n : null;
};

/**
 * A submission → { item, dropped }: the ingest_upsert_form_submissions item and how many answers were
 * left out. contact: { contactId } or { resolution }. The email is not part of the item: the caller
 * resolved it before and drops it.
 */
export function submissionItem(submission, form, emailField, contact) {
  const page = parsePage(submission?.pageUrl);
  const at = atOf(submission);
  const answers = answersOf(submission, form, emailField);
  const item = {
    sourceId: String(submission.conversionId),
    formId: form.formId,
    submittedAt: at ? new Date(at).toISOString() : null,
    pageHost: page.host,
    pagePath: page.path,
    utm: page.utm,
    keptValues: answers.values,
  };
  if (contact?.contactId) item.contactId = contact.contactId;
  else item.contactResolution = contact?.resolution ?? "pending";
  return { item, dropped: answers.dropped };
}

/**
 * Takes a page (newest first) until the cursor ({ at, id } of the newest submission already read)
 * or the floor (ms; the start date on a first poll). reached: the page went past the cursor or floor.
 * A submission at the cursor's time with another id is still new (two in the same millisecond).
 */
export function takeUntil(results, cursor, floorMs = null) {
  const fresh = [];
  for (const s of results ?? []) {
    const at = atOf(s);
    if (!s?.conversionId || at === null) continue;
    if (cursor && (at < cursor.at || (at === cursor.at && String(s.conversionId) === cursor.id))) return { fresh, reached: true };
    if (floorMs !== null && at < floorMs) return { fresh, reached: true };
    fresh.push(s);
  }
  return { fresh, reached: false };
}

/** The newest { at, id } of a list (newest first), or the old cursor. */
export function newestOf(list, cursor) {
  const first = (list ?? []).find((s) => atOf(s) !== null && s?.conversionId);
  if (!first) return cursor ?? null;
  const n = { at: atOf(first), id: String(first.conversionId) };
  return !cursor || n.at > cursor.at || (n.at === cursor.at && n.id !== cursor.id) ? n : cursor;
}

// ---- With HubSpot and the database ----------------------------------------------------------------

/** Resolves the emails of a page (one search per distinct email, paced) → { items, dropped }. */
async function itemsOf(api, list, form, emailField, contacts) {
  const items = [];
  let dropped = 0;
  for (const s of list) {
    let email = emailOf(s, emailField);
    let contact;
    if (!email) {
      contact = { resolution: "no_email" };
    } else {
      const k = email.toLowerCase();
      if (!contacts.has(k)) {
        const ids = await api.contactIdsWhere(emailField, email);
        contacts.set(k, ids.length === 1 ? { contactId: ids[0] } : { resolution: ids.length ? "ambiguous" : "not_found" });
      }
      contact = contacts.get(k);
    }
    email = null;
    const one = submissionItem(s, form, emailField, contact);
    items.push(one.item);
    dropped += one.dropped;
  }
  return { items, dropped };
}

/** Adds a page's outcomes to the run's counts; dropped (answers left out) only once there is one */
function tally(counts, outcomes, fetched, dropped) {
  counts.fetched += fetched;
  counts.upserted += (outcomes.inserted ?? 0) + (outcomes.resolved ?? 0) + (outcomes.filled ?? 0);
  counts.skipped += outcomes.known ?? 0;
  if (dropped) counts.dropped = (counts.dropped ?? 0) + dropped;
}

/** Writes a page: its items, then the tally */
async function writePage(api, store, list, form, emailField, contacts, counts) {
  const { items, dropped } = await itemsOf(api, list, form, emailField, contacts);
  tally(counts, await store.upsertSubmissions(items), list.length, dropped);
}

/** Refreshes the catalog when it is older than an hour; answers the email field per form id when it did. */
async function refreshCatalog(api, store, now) {
  const cur = await store.cursor(CATALOG_STREAM);
  if (cur?.refreshedAt && now - Date.parse(cur.refreshedAt) < CATALOG_EVERY_MS) return null;
  const forms = [];
  let after;
  for (let i = 0; i < 50; i += 1) {
    const r = await api.forms(after);
    forms.push(...(r?.results ?? []).filter((f) => f?.id && f.archived !== true));
    after = r?.paging?.next?.after;
    if (!after) break;
  }
  if (forms.length > 500) warn("form catalog over 500; the rest is not refreshed", { forms: forms.length });
  await store.upsertForms(forms.slice(0, 500).map(catalogItem));
  await store.setCursor(CATALOG_STREAM, { refreshedAt: new Date(now).toISOString() });
  return new Map(forms.map((f) => [String(f.id), emailFieldOf(f)]));
}

/**
 * The email field of a form: from this run's catalog, else from the poll cursor ("" = the form has
 * none), else from the form's definition (GET /marketing/v3/forms/{id}). Answers a name or null.
 */
async function emailFieldFor(api, formId, fromCatalog, cursor) {
  if (fromCatalog?.has(formId)) return fromCatalog.get(formId);
  if (typeof cursor?.emailField === "string") return cursor.emailField || null;
  return emailFieldOf(await api.form(formId));
}

/**
 * The poll of one connection: catalog (hourly), then every polled, active form. Answers
 * { counts, error } for the run's sync_run row; error is the first form's code, the other forms
 * still run.
 */
export async function pollForms({ connection, store, budget, now = Date.now() }) {
  const counts = { fetched: 0, upserted: 0, stale: 0, skipped: 0, failed: 0 };
  const api = hubspotClient(await tokenOf(connection), budget);
  const fromCatalog = await refreshCatalog(api, store, now);
  const settings = await store.settings();
  const floor = settings["intake.start_date"] ? (await store.tenantStartOf(settings["intake.start_date"]))?.getTime() ?? null : null;
  const forms = (await store.forms()).filter((f) => f.status === "active" && f.isPolled);
  let error = null;
  const contacts = new Map(); // email (lower case) → resolution, this run only
  for (const form of forms) {
    try {
      const cursor = await store.cursor(pollStream(form.formId));
      const emailField = await emailFieldFor(api, form.formId, fromCatalog, cursor);
      let after;
      let newest = cursor?.at ? { at: cursor.at, id: cursor.id } : null;
      let reached = false;
      let pages = 0;
      while (!reached && pages < PAGE_CAP) {
        const r = await api.submissions(form.formId, after);
        pages += 1;
        const take = takeUntil(r?.results ?? [], cursor?.at ? cursor : null, cursor?.at ? null : floor);
        newest = newestOf(take.fresh, newest);
        if (take.fresh.length) await writePage(api, store, take.fresh, form, emailField, contacts, counts);
        reached = take.reached;
        after = r?.paging?.next?.after;
        if (!after) reached = true;
      }
      if (!reached) error ??= "page_cap_backfill_needed";
      await store.setCursor(pollStream(form.formId), { ...(newest ?? {}), emailField: emailField ?? "" });
    } catch (err) {
      counts.failed += 1;
      error ??= err instanceof SourceError ? err.code : (err?.code ?? "forms_error");
      warn("form poll stopped", { connection: connection.connectionId, code: err?.code ?? "forms_error" });
    }
  }
  contacts.clear();
  return { counts, error };
}

/**
 * The backfill of form submissions: every polled, active form from the newest back to `from` (ms),
 * resumable per form through backfill:forms:<guid> ({ from, after, done, kept }; a run reads a form
 * again when its kept fields changed since, keptKeyOf). A submission already
 * stored without answers takes them (the database fills them once, never after a privacy deletion).
 * The poll's own cursor is not touched. counts is added to as pages are written, so a failure keeps
 * what was done.
 */
export async function backfillForms({ connection, store, budget, fromMs, counts = { fetched: 0, upserted: 0, stale: 0, skipped: 0, failed: 0 } }) {
  const api = hubspotClient(await tokenOf(connection), budget);
  const forms = (await store.forms()).filter((f) => f.status === "active" && f.isPolled);
  const contacts = new Map();
  try {
    for (const form of forms) {
      const stream = backfillStream(form.formId);
      const cur = await store.cursor(stream);
      const kept = keptKeyOf(form);
      const same = cur?.from === fromMs && cur?.kept === kept;
      if (cur?.done && same) continue;
      let after = same ? (cur.after ?? undefined) : undefined;
      const emailField = await emailFieldFor(api, form.formId, null, await store.cursor(pollStream(form.formId)));
      for (;;) {
        const r = await api.submissions(form.formId, after);
        const take = takeUntil(r?.results ?? [], null, fromMs);
        if (take.fresh.length) await writePage(api, store, take.fresh, form, emailField, contacts, counts);
        after = r?.paging?.next?.after;
        const done = take.reached || !after;
        await store.setCursor(stream, { from: fromMs, after: done ? null : after, done, kept });
        if (done) break;
      }
    }
  } finally {
    contacts.clear();
  }
  return counts;
}
