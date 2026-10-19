/**
 * Verifier (pure, no database, no network): what the jobs keep of a form submission and how they
 * walk a source (brief B8). Page addresses reduced to host and path with the UTM parameters; the
 * email used only for the contact search and never part of what is written; the catalog's fields
 * (names, kinds, option values, no labels) and the answers kept only for the form's kept choice fields
 * within their options, everything else dropped and counted (addition 0008p, brief B17d); the poll stopping at its cursor or the start date; the CRM search pages of
 * reconcile and backfill; the synthetic event keys; the jobs' argument checks. Invented values only.
 *
 *   node verify/forms.mjs [--provoke]
 */
import { expect, verdict, PROVOKE } from "./lib.mjs";
import { parsePage } from "../src/core/page.mjs";
import { syncEvent } from "../src/core/sync.mjs";
import { emailFieldOf, emailOf, answerOf, answersOf, submissionItem, takeUntil, newestOf, catalogItem, keptKeyOf } from "../src/adapters/hubspot/forms.mjs";
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

// ---- The form definition, its fields and the submission ------------------------------------------
const YES = "Yes, I'm an existing Customer";
const NO = "No, I'm not a customer yet";
const form = { id: "11111111-0000-0000-0000-000000000001", name: "Request a quote (test)", fieldGroups: [
  { fields: [{ name: "firstname", fieldType: "single_line_text", objectTypeId: "0-1" }, { name: "work_email", fieldType: "email", objectTypeId: "0-1" }] },
  { fields: [{ name: "product_interest", fieldType: "dropdown", objectTypeId: "0-1", options: [{ label: "AED Plus (label)", value: "AED Plus" }, { label: "AED 3", value: "AED 3" }, { label: "Twice", value: "AED Plus" }] },
    { name: "phone", fieldType: "phone", objectTypeId: "0-1" }, { name: "customer", fieldType: "radio", options: [{ value: YES }, { value: NO }] },
    { name: "topics", fieldType: "multiple_checkboxes", options: [{ value: "Billing" }, { value: "Device" }, { value: "Delivery" }] },
    { name: "consent", fieldType: "single_checkbox" }, { name: "iban", fieldType: "single_line_text" }, { name: "bad name!", fieldType: "dropdown", options: [{ value: "x" }] },
    { name: "customer", fieldType: "radio", options: [{ value: "duplicate" }] }] }] };
expect("the email field is the field of type email", emailFieldOf(form), "work_email", "email");
expect("…else a contact field named email", emailFieldOf({ fieldGroups: [{ fields: [{ name: "email", fieldType: "single_line_text", objectTypeId: "0-1" }] }] }), "email", null);
expect("…else none", emailFieldOf({ fieldGroups: [{ fields: [{ name: "message", fieldType: "multi_line_text" }] }] }), null, "email");
const item = catalogItem(form);
expect("the catalog item: id, name and the fields (no label; a bad name left out, a name once)", [item.formId, item.name, item.fields.map((f) => f.name)],
  [form.id, "Request a quote (test)", ["firstname", "work_email", "product_interest", "phone", "customer", "topics", "consent", "iban"]],
  [form.id, "Request a quote (test)", ["firstname"]]);
expect("fields: the four choice kinds with their option values (each once), every other field other without options",
  item.fields.map((f) => `${f.name}=${f.kind}:${f.options.join("|")}`),
  ["firstname=other:", "work_email=other:", "product_interest=dropdown:AED Plus|AED 3", "phone=other:", `customer=radio:${YES}|${NO}`,
    "topics=multiple_checkboxes:Billing|Device|Delivery", "consent=single_checkbox:true|false", "iban=other:"], []);
expect("no label of an option reaches the catalog", JSON.stringify(item).includes("(label)"), false, true);

// The form as the store gives it: kept fields and the catalog's fields
const stored = { formId: form.id, keptFields: ["product_interest", "customer", "topics", "consent", "work_email", "iban", "firstname"], fields: item.fields };
const sub = {
  conversionId: "c0000000-0000-0000-0000-000000000001", submittedAt: Date.parse("2026-10-10T08:30:00Z"),
  pageUrl: "https://www.example.com/nl/aed-kopen?utm_source=newsletter&utm_medium=email",
  values: [{ name: "firstname", value: "Invented" }, { name: "work_email", value: `  ${EMAIL} ` }, { name: "product_interest", value: "AED Plus" },
    { name: "phone", value: "+44 20 0000 0001" }, { name: "customer", value: NO }, { name: "topics", value: "Device;Billing" }, { name: "consent", value: "true" },
    { name: "iban", value: "NL91TEST0000000000" }],
};
expect("the submitted email, trimmed, for the search", emailOf(sub, "work_email"), EMAIL, null);
expect("no email field → no email", emailOf(sub, null), null, EMAIL);
expect("a value that is not an email → no email", emailOf({ values: [{ name: "work_email", value: "nope" }] }, "work_email"), null, "nope");
expect("answers: choice fields within their options (multiple checkboxes as a sorted list); text, email and a bank field dropped",
  answersOf(sub, stored, "work_email"), { values: { product_interest: "AED Plus", customer: NO, topics: ["Billing", "Device"], consent: "true" }, dropped: 2 },
  { values: { product_interest: "AED Plus", customer: NO, topics: "Device;Billing", consent: "true", iban: "NL91TEST0000000000", firstname: "Invented" }, dropped: 0 });
expect("an answer no option accounts for is dropped and counted", answersOf({ values: [{ name: "customer", value: "Maybe" }, { name: "topics", value: "Device;Unknown" },
  { name: "product_interest", value: "AED Plus" }] }, stored, "work_email"), { values: { product_interest: "AED Plus" }, dropped: 2 }, { values: { customer: "Maybe", topics: ["Device", "Unknown"], product_interest: "AED Plus" }, dropped: 0 });
expect("multiple checkboxes sent as several values of one name, each once", answerOf(item.fields.find((f) => f.name === "topics"), ["Device", "Billing", "Device"]),
  ["Billing", "Device"], ["Device", "Billing", "Device"]);
expect("a missing or empty answer is neither kept nor dropped", answersOf({ values: [{ name: "customer", value: "" }] }, stored, "work_email"), { values: {}, dropped: 0 }, { values: { customer: "" }, dropped: 0 });
expect("a form not described yet (no fields) keeps no answer: each is dropped", answersOf(sub, { ...stored, fields: [] }, "work_email"),
  { values: {}, dropped: 6 }, { values: { product_interest: "AED Plus" }, dropped: 0 });
expect("the email field is never kept, even when configured and described as a choice", answersOf({ values: [{ name: "work_email", value: "AED Plus" }] },
  { keptFields: ["work_email"], fields: [{ name: "work_email", kind: "dropdown", options: ["AED Plus"] }] }, "work_email"), { values: {}, dropped: 0 }, { values: { work_email: "AED Plus" }, dropped: 0 });
expect("no kept fields → no answers", answersOf(sub, { ...stored, keptFields: [] }, "work_email"), { values: {}, dropped: 0 }, { values: { firstname: "Invented" }, dropped: 0 });

const resolved = submissionItem(sub, { ...stored, keptFields: ["product_interest"] }, "work_email", { contactId: "4300000001" });
expect("the item: ids, time, host, path, UTM, contact, answers", resolved, { item: {
  sourceId: sub.conversionId, formId: form.id, submittedAt: "2026-10-10T08:30:00.000Z", pageHost: "www.example.com", pagePath: "/nl/aed-kopen",
  utm: { source: "newsletter", medium: "email" }, keptValues: { product_interest: "AED Plus" }, contactId: "4300000001",
}, dropped: 0 }, {});
const text = JSON.stringify(submissionItem(sub, stored, "work_email", { contactId: "4300000001" }));
expect("the item holds no email, no name, no phone number, no bank field", [text.includes("example.com/"), text.includes("someone.invented"), text.includes("Invented"),
  text.includes("0000 0001"), text.includes("NL91")], [false, false, false, false, false], [false, true, true, true, true]);
expect("an unresolved contact carries its resolution, no id", submissionItem(sub, { ...stored, keptFields: [] }, "work_email", { resolution: "ambiguous" }).item.contactResolution, "ambiguous", "resolved");
expect("the backfill's key of the kept fields: the same for the same set, another once they change",
  [keptKeyOf({ keptFields: ["b", "a"] }) === keptKeyOf({ keptFields: ["a", "b"] }), keptKeyOf({ keptFields: ["a"] }) === keptKeyOf({ keptFields: ["a", "b"] })], [true, false], [false, true]);

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
expect("arguments: --again is a flag, without a value", parseArgs(["--object", "contact", "--again"], { object: "text", again: "flag" }), { object: "contact", again: true }, { object: "contact" });
expect("arguments: …a value after a flag is refused", refused(["--again", "yes"], { again: "flag" }), true, false);

verdict();
