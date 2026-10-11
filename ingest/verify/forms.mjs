/**
 * Verifier (pure, no database, no network): what the jobs keep of a form submission and how they
 * walk a source (brief B8). Page addresses reduced to host and path with the UTM parameters; the
 * email used only for the contact search and never part of what is written; kept values limited to
 * the form's kept fields; the poll stopping at its cursor or the start date; the CRM search pages of
 * reconcile and backfill; the synthetic event keys; the jobs' argument checks. Invented values only.
 *
 *   node verify/forms.mjs [--provoke]
 */
import { expect, verdict, PROVOKE } from "./lib.mjs";
import { parsePage } from "../src/core/page.mjs";
import { syncEvent } from "../src/core/sync.mjs";
import { emailFieldOf, emailOf, keptValuesOf, submissionItem, takeUntil, newestOf, catalogItem } from "../src/adapters/hubspot/forms.mjs";
import { searchBody, searchPages } from "../src/adapters/hubspot/reconcile.mjs";
import { parseArgs, UsageError } from "../src/jobs/runner.mjs";

console.log(`verify/forms.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

const EMAIL = "someone.invented@example.com";

// ---- Page addresses ------------------------------------------------------------------------------
const page = parsePage(`https://WWW.Example.com/nl/aed-kopen?utm_source=google&utm_medium=cpc&utm_campaign=autumn&utm_term=aed&utm_content=ad1&gclid=abc123&email=${encodeURIComponent(EMAIL)}#form`);
expect("host lower-cased, path without query or fragment", [page.host, page.path], ["www.example.com", "/nl/aed-kopen"], ["WWW.Example.com", "/nl/aed-kopen?utm_source=google"]);
expect("the five UTM parameters parsed", page.utm, { source: "google", medium: "cpc", campaign: "autumn", term: "aed", content: "ad1" }, {});
expect("other query parameters (click id, email) dropped", JSON.stringify(page).includes("abc123") || JSON.stringify(page).includes("example.com/"), false, true);
expect("no email anywhere in the parsed page", JSON.stringify(page).includes("someone.invented"), false, true);
expect("a UTM value cut at 200 characters", parsePage(`https://example.com/?utm_campaign=${"x".repeat(300)}`).utm.campaign.length, 200, 300);
expect("an address without UTM: an empty utm and path /", parsePage("https://example.com").utm, {}, { source: null });
expect("not a URL → nothing", parsePage("not a url"), { host: null, path: null, utm: {} }, { host: "not a url", path: null, utm: {} });
expect("a javascript: address → nothing", parsePage("javascript:alert(1)").host, null, "alert(1)");

// ---- The form definition and the submission --------------------------------------------------------
const form = { id: "11111111-0000-0000-0000-000000000001", name: "Request a quote (test)", fieldGroups: [
  { fields: [{ name: "firstname", fieldType: "single_line_text", objectTypeId: "0-1" }, { name: "work_email", fieldType: "email", objectTypeId: "0-1" }] },
  { fields: [{ name: "product_interest", fieldType: "dropdown", objectTypeId: "0-1" }, { name: "phone", fieldType: "phone", objectTypeId: "0-1" }] }] };
expect("the email field is the field of type email", emailFieldOf(form), "work_email", "email");
expect("…else a contact field named email", emailFieldOf({ fieldGroups: [{ fields: [{ name: "email", fieldType: "single_line_text", objectTypeId: "0-1" }] }] }), "email", null);
expect("…else none", emailFieldOf({ fieldGroups: [{ fields: [{ name: "message", fieldType: "multi_line_text" }] }] }), null, "email");
expect("the catalog item holds id and name only", catalogItem(form), { formId: form.id, name: "Request a quote (test)" }, { formId: form.id });

const sub = {
  conversionId: "c0000000-0000-0000-0000-000000000001", submittedAt: Date.parse("2026-10-10T08:30:00Z"),
  pageUrl: "https://www.example.com/nl/aed-kopen?utm_source=newsletter&utm_medium=email",
  values: [{ name: "firstname", value: "Invented" }, { name: "work_email", value: `  ${EMAIL} ` }, { name: "product_interest", value: "AED Plus" }, { name: "phone", value: "+44 20 0000 0001" }],
};
expect("the submitted email, trimmed, for the search", emailOf(sub, "work_email"), EMAIL, null);
expect("no email field → no email", emailOf(sub, null), null, EMAIL);
expect("a value that is not an email → no email", emailOf({ values: [{ name: "work_email", value: "nope" }] }, "work_email"), null, "nope");
expect("kept values: only the configured kept fields", keptValuesOf(sub, ["product_interest"], "work_email"), { "product_interest": "AED Plus" }, { "product_interest": "AED Plus", firstname: "Invented" });
expect("kept values never hold the email field, even when configured", keptValuesOf(sub, ["product_interest", "work_email"], "work_email"), { "product_interest": "AED Plus" }, { "product_interest": "AED Plus", work_email: EMAIL });
expect("no kept fields → no kept values", keptValuesOf(sub, [], "work_email"), {}, { firstname: "Invented" });

const resolved = submissionItem(sub, { formId: form.id, emailField: "work_email", keptFields: ["product_interest"] }, { contactId: "4300000001" });
expect("the item: ids, time, host, path, UTM, contact, kept values", resolved, {
  sourceId: sub.conversionId, formId: form.id, submittedAt: "2026-10-10T08:30:00.000Z", pageHost: "www.example.com", pagePath: "/nl/aed-kopen",
  utm: { source: "newsletter", medium: "email" }, keptValues: { "product_interest": "AED Plus" }, contactId: "4300000001",
}, {});
const text = JSON.stringify(resolved);
expect("the item holds no email, no name, no phone number", [text.includes("example.com/"), text.includes("someone.invented"), text.includes("Invented"), text.includes("0000 0001")], [false, false, false, false], [false, true, true, true]);
expect("an unresolved contact carries its resolution, no id", submissionItem(sub, { formId: form.id, emailField: "work_email", keptFields: [] }, { resolution: "ambiguous" }).contactResolution, "ambiguous", "resolved");

// ---- The poll's stop -----------------------------------------------------------------------------
const at = (min) => Date.parse("2026-10-10T09:00:00Z") + min * 60_000;
const pageList = [
  { conversionId: "c5", submittedAt: at(5) }, { conversionId: "c4", submittedAt: at(4) }, { conversionId: "c3b", submittedAt: at(3) },
  { conversionId: "c3", submittedAt: at(3) }, { conversionId: "c2", submittedAt: at(2) }, { conversionId: "c1", submittedAt: at(1) }];
const ids = (r) => r.fresh.map((s) => s.conversionId);
expect("stops at the cursor (time and conversion id)", ids(takeUntil(pageList, { at: at(3), id: "c3" })), ["c5", "c4", "c3b"], ["c5", "c4", "c3b", "c3"]);
expect("…and says it reached it", takeUntil(pageList, { at: at(3), id: "c3" }).reached, true, false);
expect("a submission in the cursor's millisecond with another id is new", ids(takeUntil(pageList, { at: at(3), id: "c3b" })), ["c5", "c4"], ["c5", "c4", "c3"]);
expect("an older submission than the cursor stops too", ids(takeUntil(pageList, { at: at(2) + 30_000, id: "zz" })), ["c5", "c4", "c3b", "c3"], ["c5"]);
expect("the first poll stops at the start date", ids(takeUntil(pageList, null, at(2))), ["c5", "c4", "c3b", "c3", "c2"], pageList.map((s) => s.conversionId));
expect("a page entirely newer than the cursor is not reached", takeUntil(pageList, { at: at(0), id: "c0" }).reached, false, true);
expect("entries without an id or a time are skipped", ids(takeUntil([{ submittedAt: at(9) }, { conversionId: "x" }, { conversionId: "c9", submittedAt: at(9) }], null)), ["c9"], ["x", "c9"]);
expect("the new cursor is the newest submission read", newestOf(pageList, { at: at(3), id: "c3" }), { at: at(5), id: "c5" }, { at: at(3), id: "c3" });
expect("nothing new keeps the old cursor", newestOf([], { at: at(3), id: "c3" }), { at: at(3), id: "c3" }, null);

// ---- Reconcile and backfill search ---------------------------------------------------------------
expect("the search body: modified time between from and to, ascending, ids only", searchBody("deal", "hs_lastmodifieddate", 1000, 2000), {
  filterGroups: [{ filters: [{ propertyName: "hs_lastmodifieddate", operator: "GTE", value: "1000" }, { propertyName: "hs_lastmodifieddate", operator: "LTE", value: "2000" }] }],
  sorts: [{ propertyName: "hs_lastmodifieddate", direction: "ASCENDING" }], properties: ["hs_lastmodifieddate"], limit: 100,
}, {});
expect("a backfill body asks the created time and the version (modified time) only", searchBody("deal", "createdate", 1000, null, "100").properties, ["createdate", "hs_lastmodifieddate"], ["createdate", "dealname"]);

// A fake search that answers 10,100 results: past 10,000 a new query starts at the last value
const total = 10_100;
const BASE = Date.parse("2026-10-01T00:00:00Z");
const bodies = [];
const fakeApi = {
  async search(_type, body) {
    bodies.push(body);
    const from = Number(body.filterGroups[0].filters[0].value);
    const offset = Number(body.after ?? 0);
    const all = Array.from({ length: total }, (_, i) => i).filter((i) => BASE + i * 1000 >= from);
    const part = all.slice(offset, offset + 100);
    return { results: part.map((i) => ({ id: String(900000 + i), properties: { createdate: String(BASE + i * 1000), hs_lastmodifieddate: "2026-10-10T09:00:00.000Z" } })),
      paging: offset + 100 < all.length ? { next: { after: String(offset + 100) } } : undefined };
  },
};
const seen = new Set();
for await (const p of searchPages(fakeApi, "deal", "createdate", BASE, null)) for (const i of p.items) seen.add(i.id);
expect("10,100 results all listed across the 10,000-result window", seen.size, total, 10_000);
expect("…by starting a new query at the last value", bodies.filter((b) => !b.after).length, 2, 1);
expect("…never asking past result 10,000 in one query", bodies.every((b) => Number(b.after ?? 0) + 100 <= 10_000), true, false);

// ---- Synthetic events and arguments --------------------------------------------------------------
const e = syncEvent("reconcile", "deal", { id: "4100000001", version: "2026-10-10T09:00:00.000Z" });
expect("a synthetic event: key by object, id and version; kind changed", [e.key, e.kind, e.sourceType, e.occurredAt], ["sync:deal:4100000001:2026-10-10T09:00:00.000Z", "changed", "cma.reconcile", "2026-10-10T09:00:00.000Z"], []);
expect("the same object and version give the same key (read once)", syncEvent("backfill", "deal", { id: "4100000001", version: "2026-10-10T09:00:00.000Z" }).key, e.key, "other");
const refused = (argv, spec) => {
  try {
    parseArgs(argv, spec);
    return false;
  } catch (err) {
    return err instanceof UsageError;
  }
};
expect("arguments: --connection must be a uuid", refused(["--connection", "abc"], { connection: "uuid" }), true, false);
expect("arguments: --from must be a date", refused(["--from", "1 October"], { from: "date" }), true, false);
expect("arguments: an unknown argument is refused", refused(["--everything", "yes"], { from: "date" }), true, false);
expect("arguments: --lookback-minutes is a number", parseArgs(["--lookback-minutes", "10"], { "lookback-minutes": "minutes" }), { "lookback-minutes": 10 }, { "lookback-minutes": "10" });

verdict();
