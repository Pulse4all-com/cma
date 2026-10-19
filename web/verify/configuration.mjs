/**
 * Verifier: the configuration screens' logic (src/lib/configuration.ts), without a browser or a database.
 *
 *   node --experimental-strip-types verify/configuration.mjs             every check must PASS
 *   node --experimental-strip-types verify/configuration.mjs --provoke   every check must FAIL
 *
 * Covers the frozen-flags and retire rules as the database applies them, the status list order,
 * the form checks, market and level parsing, coverage targets, the minute settings and the
 * export preview in every format. Keys and names are fixture values; nothing branches on them.
 * Since addition 0008e (night of 13 October 2026) also the Sources, Markets and Alert rules logic
 * (src/lib/sources.ts, src/lib/alertRules.ts): sections per kind, the settings rules of
 * cma.connection_settings_ok, the record link preview as cma.record_url builds it, the rules by name for
 * forms and call outcomes (12 October 2026's rules reproduced on fixture names), office hours, the
 * market form, and the alert rules' checks and effect in plain words. Since addition 0008p a form's polled and
 * counted switches, the categories a form may get and the form category catalog's checks. Since addition 0008t the
 * email section of a customer-records connection: the origin codes as the database reads them, a mailbox's label
 * and the market order in words.
 */
import {
  exportPreview, flagsFrozen, levelsText, parseLevels, parseMarkets, parseMinutes, parseTarget, retireProblem, statusFormProblem, targetAt, visibleStatuses,
} from "../src/lib/configuration.ts";
import {
  coerceSettingValue, effectiveHours, firstWordIn, kindChoices, marketFormProblem, nameMatches, parseDay, parseOfficeHours, parseWords, planFormRule,
  planOutcomeRule, formRuleProblem, prefixMarket, recordTypeOfSetting, recordUrlPreview, settingKeyProblem, settingsProblem, settingsSize, sourceSections,
  formCategoryChoices, formCategoryProblem, formEditProblem, emailMarketSteps, mailboxLabelProblem, settingCodes,
} from "../src/lib/sources.ts";
import { alertRuleProblem, newRule, parseAge, pipelineLabels, pipelinesFor, recordTypes, ruleEffect } from "../src/lib/alertRules.ts";

const PROVOKE = process.argv.includes("--provoke");
const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(56)} got ${JSON.stringify(actual).slice(0, 70)}${pass ? "" : `, wanted ${JSON.stringify(want).slice(0, 70)}`}`);
}

const st = (key, o) => ({ key, name: key, isWorking: true, isProductive: true, isPaid: true, isBillable: true, isDefault: false, sortOrder: 100, isActive: true, usageCount: 0, ...o });
const all = [st("a", { isDefault: true, sortOrder: 10, usageCount: 5 }), st("b", { sortOrder: 20 }), st("p", { isWorking: false, sortOrder: 5 }), st("z", { isActive: false, sortOrder: 1 })];

expect("flags are frozen once a status has time", flagsFrozen(all[0]), true, false);
expect("flags are free on a new status", flagsFrozen(all[1]), false, true);
expect("the default cannot be retired", retireProblem(all[0], all), "default", null);
expect("a working status with another working one can", retireProblem(all[1], all), null, "lastWorking");
expect("the last working status cannot", retireProblem(all[1], [all[0], all[1], all[2]].map((s) => (s.key === "a" ? { ...s, isActive: false, isDefault: false } : s))), "lastWorking", null);
expect("a retired status has nothing to retire", retireProblem(all[3], all), null, "default");
expect("active statuses in order, retired hidden", visibleStatuses(all, false).map((s) => s.key), ["p", "a", "b"], ["a", "b", "p"]);
expect("retired statuses after the active ones", visibleStatuses(all, true).map((s) => s.key), ["p", "a", "b", "z"], ["z", "p", "a", "b"]);
expect("a bad key is named", statusFormProblem({ key: "Bad Key", name: "x" }, true, []), "key", null);
expect("a duplicate key on add", statusFormProblem({ key: "a", name: "x" }, true, ["a"]), "duplicate", null);
expect("the same key on edit is fine", statusFormProblem({ key: "a", name: "x" }, false, ["a"]), null, "duplicate");
expect("an empty name is named", statusFormProblem({ key: "ok", name: "  " }, true, []), "name", null);
expect("markets: lowercase, unique, sorted", parseMarkets("nl, be  DE nl"), ["be", "de", "nl"], ["nl", "be", "de"]);
expect("markets: a bad token refuses", parseMarkets("nl, bel"), null, ["nl"]);
expect("markets: empty is no markets", parseMarkets(" "), [], null);
expect("levels from a comma list", parseLevels("Basic, Good, Fluent, Native"), [{ level: 1, name: "Basic" }, { level: 2, name: "Good" }, { level: 3, name: "Fluent" }, { level: 4, name: "Native" }], []);
expect("levels: empty is binary", parseLevels(""), [], null);
expect("levels: duplicates refuse", parseLevels("Good, good"), null, []);
expect("levels back to text in level order", levelsText([{ level: 2, name: "B" }, { level: 1, name: "A" }]), "A, B", "B, A");
const targets = [{ teamKey: "t", skillKey: "s", weekday: 1, minCount: 2 }];
expect("a target is found", targetAt(targets, "t", "s", 1), 2, 0);
expect("no target is 0", targetAt(targets, "t", "s", 2), 0, 2);
expect("a typed target", parseTarget(" 7 "), 7, null);
expect("an empty target clears", parseTarget(""), 0, null);
expect("a bad target refuses", parseTarget("1a"), null, 0);
expect("minutes parse", parseMinutes("120"), 120, null);
expect("minutes refuse a decimal", parseMinutes("1.5"), null, 1);
const labels = { date: "Date", person: "Person", worked: "Worked", bom: "with BOM", noBom: "no BOM" };
const dutch = [
  { key: "export.csv.separator", value: "semicolon", isDefault: false }, { key: "export.csv.decimal_mark", value: "comma", isDefault: false },
  { key: "export.csv.date_format", value: "dd-mm-yyyy", isDefault: false }, { key: "export.csv.duration_format", value: "decimal_hours", isDefault: true },
  { key: "export.csv.utf8_bom", value: "true", isDefault: true },
];
expect("preview in the Dutch format", exportPreview(dutch, labels), ["with BOM", "Date;Person;Worked", "08-10-2026;A. Example;7,50"], ["no BOM", "Date,Person,Worked", "2026-10-08,A. Example,7.50"]);
expect("preview in the defaults", exportPreview([], labels), ["with BOM", "Date,Person,Worked", "2026-10-08,A. Example,7.50"], ["no BOM"]);
const tabs = [{ key: "export.csv.separator", value: "tab", isDefault: false }, { key: "export.csv.duration_format", value: "hh:mm", isDefault: false }, { key: "export.csv.utf8_bom", value: "false", isDefault: false }];
expect("preview with tabs, hh:mm and no mark", exportPreview(tabs, labels), ["no BOM", "Date ⇥ Person ⇥ Worked", "2026-10-08 ⇥ A. Example ⇥ 7:30"], ["with BOM"]);
expect("preview in minutes with a decimal comma stays one cell", exportPreview([{ key: "export.csv.duration_format", value: "minutes", isDefault: false }, { key: "export.csv.decimal_mark", value: "comma", isDefault: false }], labels)[2], "2026-10-08,A. Example,450", "2026-10-08,A. Example,\"7,5\"");

// ---- Sources (addition 0008e) ----------------------------------------------------------------------
// since addition 0008n the task statuses and types follow the fields, since 0008t the email section
expect("a customer-records connection has seven sections", sourceSections("crm", []), ["pipelines", "forms", "callOutcomes", "fields", "taskStatuses", "taskTypes", "email"],
  ["pipelines", "forms", "callOutcomes", "fields", "taskStatuses", "taskTypes"]);
expect("an unset kind shows what its rows imply", sourceSections(null, ["telephony"]), ["lines", "tags", "missedReasons"], ["lines", "tags"]);
expect("an automation connection has no catalog section", sourceSections("automation", []), [], ["store"]);
expect("the kind is free while nothing is held", kindChoices([]), ["crm", "telephony", "commerce", "automation"], ["crm"]);
expect("held rows narrow the kinds offered", kindChoices(["crm"]), ["crm"], ["crm", "telephony", "commerce", "automation"]);
expect("a settings key in the right form", settingKeyProblem("record_url_deal", ["app_host"], true), null, "key");
expect("a secret-looking key is refused", settingKeyProblem("api_token", [], true), "secret", null);
expect("the word key in a key is refused too", settingKeyProblem("license_key", [], true), "secret", null);
expect("an upper-case key is refused", settingKeyProblem("AppHost", [], true), "key", null);
expect("a new key that exists is a duplicate", settingKeyProblem("app_host", ["app_host"], true), "duplicate", null);
expect("settings with a nested value are refused", settingsProblem({ a: { b: 1 } }), "value", null);
expect("flat settings pass", settingsProblem({ app_host: "x.example.com", replay: true, retries: 3 }), null, "value");
expect("settings measured as the database does", settingsSize({ a: "b", c: 1 }), 18, 13);
expect("a boolean stays a boolean", coerceSettingValue("false", true), false, "false");
expect("a number stays a number", coerceSettingValue(" 42 ", 7), 42, "42");
expect("a new setting is text", coerceSettingValue("true"), "true", true);
expect("the record type of a link template", recordTypeOfSetting("record_url_ticket"), "ticket", null);
expect("no record type for another key", recordTypeOfSetting("app_host"), null, "app_host");
const linkSettings = { app_host: "app.example.com" };
expect("a record link as cma.record_url builds it", recordUrlPreview("https://{app_host}/r/{account}/deal/{id}", linkSettings, "147000", "41000123"),
  "https://app.example.com/r/147000/deal/41000123", null);
expect("no link without a valid host", recordUrlPreview("https://{app_host}/x/{id}", { app_host: "Bad Host" }, "1", "2"), null, "https://Bad Host/x/2");
expect("no link while a placeholder stays unfilled", recordUrlPreview("https://x.example.com/{record}/{id}", {}, "1", "2"), null, "https://x.example.com/{record}/2");
expect("no link that is not https", recordUrlPreview("http://x.example.com/{id}", {}, "1", "2"), null, "http://x.example.com/2");
expect("words are lower case, trimmed, once", parseWords("Quote, contact;INFO, quote,"), ["quote", "contact", "info"], ["Quote", "contact", "INFO"]);
expect("a name matches an include word", nameMatches("NL - Quote form", ["quote", "contact"], ["cancel"]), true, false);
expect("an exclude word wins", nameMatches("NL - Quote cancellation", ["quote"], ["cancellation"]), false, true);
expect("no include words match every name", nameMatches("Anything", [], []), true, false);
expect("the first word found in the name", firstWordIn("Contact us for a quote", ["quote", "contact"]), "contact", "quote");
const mk = [{ code: "GB", aliases: ["uk", "united kingdom"] }, { code: "NL", aliases: [] }, { code: "DE", aliases: [] }];
expect("a UK prefix reads through the alias", prefixMarket("UK - Contact form", mk), "GB", "UK");
expect("a code prefix is the market", prefixMarket("  nl Quote", mk), "NL", null);
expect("three letters are no prefix", prefixMarket("NLD quote", mk), null, "NL");
expect("an unknown prefix names no market", prefixMarket("ES - Quote", mk), null, "ES");
// Martin's form rule of 12 October 2026, on fictional names
const fixtureForms = [
  ["f1", "NL - Quote form"], ["f2", "UK - Contact form"], ["f3", "DE Info request"], ["f4", "NL - Cancellation form"],
  ["f5", "UK - Replacement request"], ["f6", "Support question"], ["f7", "Newsletter sign-up"], ["f8", "ES - Quote form"],
].map(([formId, name]) => ({ formId, name, isCounted: true, leadSource: null, market: null, keptFields: [], isActive: true }));
const leadRule = { include: ["quote", "contact", "info"], exclude: ["cancellation", "replacement", "support"], counted: "yes",
  leadSource: { kind: "firstWord" }, market: { kind: "prefix" }, others: "notCounted" };
const plan = planFormRule(fixtureForms, leadRule, mk);
expect("the lead rule changes the forms it should", plan.map((p) => p.formId), ["f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8"], ["f1"]);
expect("a quote form gets quote and NL", plan.find((p) => p.formId === "f1")?.after, { isCounted: true, leadSource: "quote", market: "NL" }, { isCounted: true, leadSource: null, market: null });
expect("a UK contact form gets contact and GB", plan.find((p) => p.formId === "f2")?.after, { isCounted: true, leadSource: "contact", market: "GB" }, { isCounted: true, leadSource: "contact", market: "UK" });
expect("a cancellation form stops counting", plan.find((p) => p.formId === "f4")?.after, { isCounted: false, leadSource: null, market: null }, { isCounted: true, leadSource: null, market: "NL" });
expect("a form without a market prefix keeps its market", plan.find((p) => p.formId === "f8")?.after, { isCounted: true, leadSource: "quote", market: null }, { isCounted: true, leadSource: "quote", market: "ES" });
expect("a second run changes nothing", planFormRule(fixtureForms.map((f) => { const p = plan.find((x) => x.formId === f.formId); return p ? { ...f, ...p.after } : f; }), leadRule, mk).length, 0, 8);
expect("a rule that sets nothing is refused", formRuleProblem({ ...leadRule, counted: "keep", leadSource: { kind: "keep" }, market: { kind: "keep" }, others: "keep" }), "nothing", null);
expect("the first word needs include words", formRuleProblem({ ...leadRule, include: [] }), "noInclude", null);
expect("a lead source value needs a value", formRuleProblem({ ...leadRule, leadSource: { kind: "value", value: " " } }), "leadSource", null);
// Martin's call outcome rule of 12 October 2026
const outcomes = [["o1", "Connected", false], ["o2", "Not reached", true], ["o3", "Voicemail", true], ["o4", "Do Not Call Or Email", false], ["o5", "Left live message", true], ["o6", "Busy", false]]
  .map(([outcomeRef, label, isConnected]) => ({ outcomeRef, label, isConnected, isActive: true }));
const outcomePlan = planOutcomeRule(outcomes, { include: parseWords("not reached, voicemail, no answer, busy, wrong number, incorrect data, email only, left live message"), exclude: [], connected: false, others: "opposite" });
expect("the outcome rule: not reached and voicemail off, connected on", outcomePlan.map((p) => `${p.outcomeRef}=${p.after}`), ["o1=true", "o2=false", "o3=false", "o4=true", "o5=false"], ["o1=false"]);
expect("others left alone change nothing", planOutcomeRule(outcomes, { include: ["busy"], exclude: [], connected: false, others: "keep" }).length, 0, 1);
// Markets
expect("office hours as typed", parseOfficeHours("9-12:30, 13-17"), "09:00-12:30,13:00-17:00", "9-12:30,13-17");
expect("hours in four digits and to 24:00", parseOfficeHours("0900-2400"), "09:00-24:00", null);
expect("empty hours are closed", parseOfficeHours("  "), "", null);
expect("overlapping ranges are refused", parseOfficeHours("9-13, 12-17"), null, "09:00-13:00,12:00-17:00");
expect("a range that closes before it opens is refused", parseOfficeHours("17-9"), null, "17:00-09:00");
const hours = [{ market: "*", weekday: 1, hours: "09:00-17:00" }, { market: "GB", weekday: 1, hours: "08:00-16:00" }];
expect("a market without own hours follows the default", effectiveHours(hours, "NL", 1), { hours: "09:00-17:00", fromDefault: true }, { hours: "", fromDefault: false });
expect("a market with own hours is closed on a day without", effectiveHours(hours, "GB", 2), { hours: "", fromDefault: false }, { hours: "09:00-17:00", fromDefault: true });
expect("UK is refused as a market code", marketFormProblem({ code: "UK", name: "x", timeZone: "Europe/London", languageCode: "en", currency: "GBP", languageSkillKey: null, minLanguageLevel: null }), "uk", null);
expect("a minimum level needs a skill", marketFormProblem({ code: "NL", name: "x", timeZone: "Europe/Amsterdam", languageCode: "nl", currency: "EUR", languageSkillKey: null, minLanguageLevel: 3 }), "level", null);
expect("a holiday date is a real date", parseDay("2026-02-30"), null, "2026-02-30");
// Alert rules
const choices = [{ connectionName: "C", recordType: "deal", pipelineId: "p2", label: "Web orders", isCounted: false }, { connectionName: "C", recordType: "deal", pipelineId: "p1", label: "Sales", isCounted: true },
  { connectionName: "C", recordType: "ticket", pipelineId: "p3", label: "Support", isCounted: true }];
expect("record types from the pipelines and the rules", recordTypes(choices, ["follow_up"]), ["deal", "follow_up", "ticket"], ["deal", "ticket"]);
expect("pipelines of a type, counted first", pipelinesFor(choices, "deal").map((c) => c.pipelineId), ["p1", "p2"], ["p2", "p1"]);
expect("pipeline labels, an unknown id as itself", pipelineLabels(["p1", "px"], choices, "deal"), ["Sales", "px"], ["Sales"]);
expect("an empty age is the default", parseAge(""), null, 60);
expect("an age above a week is refused", parseAge("10081"), "invalid", 10081);
const rules = [{ name: "New deal", trigger: "record_created" }];
expect("a new rule with a name in use is a duplicate", alertRuleProblem({ ...newRule("record_created", "deal"), name: "New deal" }, rules, true), "duplicate", null);
expect("a name of the other trigger is refused on edit", alertRuleProblem({ ...newRule("record_assigned", "deal"), name: "New deal" }, rules, false), "trigger", null);
expect("contact cannot raise alerts", alertRuleProblem({ ...newRule("record_created", "contact"), name: "x" }, rules, true), "recordType", null);
const words = { effectCreated: "A new {record} in {where} alerts {who}.", effectAssigned: "When a {record} in {where} gets an owner, that owner's person is alerted.",
  effectEveryPipeline: "any counted pipeline", effectPipelines: "{pipelines}", effectAudience: "the holders of {permission}", effectClockedIn: "clocked in",
  effectLanguage: "with the language", effectFallback: "Else {permission}.", effectNoFallback: "Else nobody.", effectAge: "At most {minutes} minutes old.",
  effectAgeDefault: "At most {minutes} minutes old (default).", soundNormal: "One tone.", soundUrgent: "A chime.", effectOff: "Off." };
expect("the effect of a created-record rule", ruleEffect({ ...newRule("record_created", "deal"), enabled: true }, choices, 60, words),
  ["A new deal in any counted pipeline alerts the holders of leads.accept, clocked in, with the language.", "Else leads.manage.", "At most 60 minutes old (default).", "One tone."], []);
expect("the effect of an assignment rule, switched off", ruleEffect({ ...newRule("record_assigned", "deal"), pipelineIds: ["p1"], maxAgeMinutes: 30, enabled: false }, choices, 60, words),
  ["Off.", "When a deal in Sales gets an owner, that owner's person is alerted.", "At most 30 minutes old.", "A chime."], ["Off."]);

// Forms reporting (addition 0008p): polled and counted, the category choices and the category catalog
expect("a counted form that is not polled is refused", formEditProblem({ isCounted: true, isPolled: false, leadSource: "" }), "polled", null);
expect("a polled form that does not count is fine", formEditProblem({ isCounted: false, isPolled: true, leadSource: "quote" }), null, "polled");
expect("a lead source over 60 characters comes first", formEditProblem({ isCounted: true, isPolled: false, leadSource: "x".repeat(61) }), "leadSource", "polled");
const cats = [{ code: "quote", isActive: true }, { code: "legacy", isActive: false }, { code: "info", isActive: true }];
expect("a switched-off category is not offered to another form", formCategoryChoices(cats, "quote").map((k) => k.code), ["quote", "info"], ["quote", "legacy", "info"]);
expect("a form keeps its own switched-off category", formCategoryChoices(cats, "legacy").map((k) => k.code), ["quote", "legacy", "info"], ["quote", "info"]);
expect("category codes as the database takes them",
  ["iban_change", "Quote", "1st", "none", "a".repeat(41), "x"].map((code) => formCategoryProblem({ code, name: "Name", sortOrder: "10" })),
  [null, "code", "code", "code", "code", null], [null, null, null, null, null, null]);
expect("a category needs a name and an order from 0 to 9999",
  [formCategoryProblem({ code: "info", name: "  ", sortOrder: "10" }), formCategoryProblem({ code: "info", name: "Info", sortOrder: "10000" }),
    formCategoryProblem({ code: "info", name: "Info", sortOrder: "" }), formCategoryProblem({ code: "info", name: "Info", sortOrder: "0" })],
  ["name", "order", "order", null], [null, null, null, "order"]);

// ---- Sources, email (addition 0008t) ------------------------------------------------------------------
expect("origin codes: trimmed, empty parts and repeats dropped", settingCodes({ codes: " ALPHA,,beta , ALPHA" }, "codes"), ["ALPHA", "beta"], ["ALPHA", "", "beta", "ALPHA"]);
expect("origin codes: absent or not text is none", [settingCodes({}, "codes"), settingCodes({ codes: true }, "codes")], [[], []], [["true"], ["true"]]);
expect("a mailbox label: at most 80 characters, never an address, empty is the source's name",
  ["Support", "", "a".repeat(80), "a".repeat(81), "team@example.invalid"].map(mailboxLabelProblem), [false, false, false, true, true], [true, true, true, false, false]);
expect("the market order in the tenant's order", emailMarketSteps("inbox,contact"), ["inbox", "contact"], ["contact", "form", "record", "inbox"]);
expect("an unreadable market order falls back to the catalog's steps", [emailMarketSteps(""), emailMarketSteps("contact,contact"), emailMarketSteps(null)],
  [["contact", "form", "record", "inbox"], ["contact", "form", "record", "inbox"], ["contact", "form", "record", "inbox"]], [[""], ["contact", "contact"], []]);

const passed = results.filter(Boolean).length;
const n = results.length;
if (PROVOKE) {
  const ok = passed === 0;
  console.log(`\n${ok ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
  process.exit(ok ? 0 : 1);
}
console.log(`\n${passed === n ? `ALL ${n} PASS` : `${n - passed} of ${n} FAILED`}`);
process.exit(passed === n ? 0 : 1);
