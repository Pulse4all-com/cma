/**
 * HubSpot forms (DESIGN §2, §4.1, §5 poll-forms): no webhook exists for form submissions, so they
 * are polled.
 *
 *   catalog      GET /marketing/v3/forms, at most hourly per connection → cma.ingest_upsert_forms
 *                (names only; counted, lead source, market and kept fields stay configuration)
 *   submissions  per counted, active form GET /form-integrations/v1/submissions/forms/{guid}, newest
 *                first, 50 per page, until the form's cursor (submittedAt + conversion id); on the
 *                first poll of a form, until intake.start_date
 *   contact      the submitted email (the value of the form definition's email field) is looked up
 *                with a CRM search on that property; one contact → resolved with its id, none →
 *                not_found, several → ambiguous, no email → no_email. The email lives in memory for
 *                that search only: it is never written, logged or returned
 *   page         host and path only, the UTM parameters parsed from the query (src/core/page.mjs)
 *   kept values  only the form's configured kept_fields, never the email field, each at most 200
 *
 * A search that fails (429, timeout) stops that form without moving its cursor, so the next run reads
 * the same submissions again (they are idempotent on the conversion id). The cursor moves only when
 * a run reached the old cursor (or the start date), so an interrupted run loses nothing.
 */
import { SourceError } from "../../core/http.mjs";
import { parsePage } from "../../core/page.mjs";
import { warn } from "../../core/log.mjs";
import { hubspotClient, tokenOf } from "./read.mjs";

export const CATALOG_STREAM = "forms:catalog";
export const CATALOG_EVERY_MS = 60 * 60_000;
const PAGE_CAP = 100; // pages of 50 per form and run (5000 submissions); beyond that the backfill reads the rest

export const pollStream = (formId) => `forms:${formId}`;
export const backfillStream = (formId) => `backfill:forms:${formId}`;

// ---- Pure ---------------------------------------------------------------------------------------

/** A form definition (v3) → its catalog item. */
export function catalogItem(form) {
  return { formId: String(form.id), name: String(form.name ?? form.id).slice(0, 200) };
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

/** The configured kept fields' values, never the email field, each at most 200 characters. */
export function keptValuesOf(submission, keptFields, emailField) {
  const keep = new Set((keptFields ?? []).filter((f) => f && f !== emailField));
  const out = {};
  for (const v of submission?.values ?? []) {
    if (!keep.has(v?.name) || Object.hasOwn(out, v.name)) continue;
    if (typeof v.value === "string" || typeof v.value === "number" || typeof v.value === "boolean") out[v.name] = String(v.value).slice(0, 200);
  }
  return out;
}

const atOf = (s) => {
  const n = Number(s?.submittedAt);
  return Number.isFinite(n) && n > 0 ? n : null;
};

/**
 * A submission → ingest_upsert_form_submissions item. contact: { contactId } or { resolution }.
 * The email is not part of the item: the caller resolved it before and drops it.
 */
export function submissionItem(submission, { formId, emailField, keptFields }, contact) {
  const page = parsePage(submission?.pageUrl);
  const at = atOf(submission);
  const item = {
    sourceId: String(submission.conversionId),
    formId,
    submittedAt: at ? new Date(at).toISOString() : null,
    pageHost: page.host,
    pagePath: page.path,
    utm: page.utm,
    keptValues: keptValuesOf(submission, keptFields, emailField),
  };
  if (contact?.contactId) item.contactId = contact.contactId;
  else item.contactResolution = contact?.resolution ?? "pending";
  return item;
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

/** Resolves the emails of a page (one search per distinct email, paced) → submission items. */
async function itemsOf(api, list, form, emailField, contacts) {
  const items = [];
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
    items.push(submissionItem(s, { formId: form.formId, emailField, keptFields: form.keptFields }, contact));
  }
  return items;
}

function tally(counts, outcomes, fetched) {
  counts.fetched += fetched;
  counts.upserted += (outcomes.inserted ?? 0) + (outcomes.resolved ?? 0);
  counts.skipped += outcomes.known ?? 0;
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
 * The poll of one connection: catalog (hourly), then every counted, active form. Answers
 * { counts, error } for the run's sync_run row; error is the first form's code, the other forms
 * still run.
 */
export async function pollForms({ connection, store, budget, now = Date.now() }) {
  const counts = { fetched: 0, upserted: 0, stale: 0, skipped: 0, failed: 0 };
  const api = hubspotClient(await tokenOf(connection), budget);
  const fromCatalog = await refreshCatalog(api, store, now);
  const settings = await store.settings();
  const floor = settings["intake.start_date"] ? (await store.tenantStartOf(settings["intake.start_date"]))?.getTime() ?? null : null;
  const forms = (await store.forms()).filter((f) => f.status === "active" && f.isCounted);
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
        if (take.fresh.length) tally(counts, await store.upsertSubmissions(await itemsOf(api, take.fresh, form, emailField, contacts)), take.fresh.length);
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
 * The backfill of form submissions: every counted, active form from the newest back to `from`
 * (ms), resumable per form through backfill:forms:<guid> ({ from, after, done }). The poll's own
 * cursor is not touched. counts is added to as pages are written, so a failure keeps what was done.
 */
export async function backfillForms({ connection, store, budget, fromMs, counts = { fetched: 0, upserted: 0, stale: 0, skipped: 0, failed: 0 } }) {
  const api = hubspotClient(await tokenOf(connection), budget);
  const forms = (await store.forms()).filter((f) => f.status === "active" && f.isCounted);
  const contacts = new Map();
  try {
    for (const form of forms) {
      const stream = backfillStream(form.formId);
      const cur = await store.cursor(stream);
      if (cur?.done && cur.from === fromMs) continue;
      let after = cur && cur.from === fromMs ? (cur.after ?? undefined) : undefined;
      const emailField = await emailFieldFor(api, form.formId, null, await store.cursor(pollStream(form.formId)));
      for (;;) {
        const r = await api.submissions(form.formId, after);
        const take = takeUntil(r?.results ?? [], null, fromMs);
        if (take.fresh.length) tally(counts, await store.upsertSubmissions(await itemsOf(api, take.fresh, form, emailField, contacts)), take.fresh.length);
        after = r?.paging?.next?.after;
        const done = take.reached || !after;
        await store.setCursor(stream, { from: fromMs, after: done ? null : after, done });
        if (done) break;
      }
    }
  } finally {
    contacts.clear();
  }
  return counts;
}
