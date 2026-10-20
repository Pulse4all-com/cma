/**
 * Verifier: the export files (src/lib/csv.ts), without a browser or a database.
 *
 *   node --experimental-strip-types verify/csv.mjs             every check must PASS
 *   node --experimental-strip-types verify/csv.mjs --provoke   every check must FAIL
 *
 * Covers the tenant formats (separator, decimal mark, date format, duration format, byte order
 * mark), quoting, cells a spreadsheet would run as a formula, times in each day's own zone across
 * the autumn clock change, the settings fallback, and who entered a stretch, an import included
 * (addition 0008d). Since addition 0008p the Reports > Forms file: one row per form and market with the
 * period, the category's name (the code when the catalog lacks it, "No category" for none), Unknown market,
 * the previous period and the resolution split, a form name a spreadsheet would run as a formula defused. Since addition
 * 0008zb the Reports > Funnel files (the stages: a stage whose times are not read with empty figures, days with the decimal
 * mark; the lost reasons: real, data quality and no reason with the share as a fraction, a label a spreadsheet would run
 * as a formula defused) and the Reports > Cancellations file (per week or day and market, Unknown market).
 */
import {
  cancellationsCsv, exportSettingsFrom, firstOrdersCsv, formatDate, formatDuration, formatTime, formsCsv, funnelStagesCsv, hoursCsv, lostReasonsCsv, quote,
  safeText, statusChangesCsv, toCsv,
} from "../src/lib/csv.ts";

const PROVOKE = process.argv.includes("--provoke");
const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(52)} got ${JSON.stringify(actual).slice(0, 70)}${pass ? "" : `, wanted ${JSON.stringify(want).slice(0, 70)}`}`);
}

const DUTCH = exportSettingsFrom([
  { key: "export.csv.separator", value: "semicolon", isDefault: false },
  { key: "export.csv.decimal_mark", value: "comma", isDefault: false },
  { key: "export.csv.date_format", value: "dd-mm-yyyy", isDefault: false },
]);
const labels = {
  date: "Date", person: "Person", employer: "Employer", timeZone: "Time zone", clockedIn: "Clocked in",
  clockedOut: "Clocked out", worked: "Worked", paid: "Paid", billable: "Billable", notClockedOut: "Not clocked out",
  corrected: "Corrected afterwards", status: "Status", from: "From", to: "To", duration: "Duration", working: "Working",
  enteredBy: "Entered by", sourceUser: "Person", sourceSystem: "System", sourceCorrection: "Correction", sourceImport: "Import",
  yes: "Yes", no: "No",
};

// ---- settings -----------------------------------------------------------------------------------
expect("missing settings fall back to the catalog defaults", exportSettingsFrom([]),
  { separator: "comma", decimalMark: "point", dateFormat: "yyyy-mm-dd", durationFormat: "decimal_hours", utf8Bom: true },
  { separator: "semicolon", decimalMark: "point", dateFormat: "yyyy-mm-dd", durationFormat: "decimal_hours", utf8Bom: true });
expect("an unknown value is never used",
  exportSettingsFrom([{ key: "export.csv.separator", value: "|", isDefault: false }]).separator, "comma", "|");

// ---- cells --------------------------------------------------------------------------------------
expect("formula starts get an apostrophe", ["=SUM(A1)", "+31", "-1", "@x", "\tx", "Ana"].map(safeText),
  ["'=SUM(A1)", "'+31", "'-1", "'@x", "'\tx", "Ana"], ["=SUM(A1)", "+31", "-1", "@x", "\tx", "Ana"]);
expect("separator, quote and line break are quoted", [quote("a;b", ";"), quote('say "hi"', ";"), quote("a\nb", ";"), quote("a,b", ";")],
  ['"a;b"', '"say ""hi"""', '"a\nb"', "a,b"], ["a;b", 'say "hi"', "a\nb", '"a,b"']);

// ---- formats ------------------------------------------------------------------------------------
expect("date formats", ["yyyy-mm-dd", "dd-mm-yyyy", "dd/mm/yyyy", "mm/dd/yyyy"].map((f) => formatDate("2026-10-05", f)),
  ["2026-10-05", "05-10-2026", "05/10/2026", "10/05/2026"], ["2026-10-05", "2026-10-05", "2026-10-05", "2026-10-05"]);
expect("decimal hours with a comma", formatDuration(27_000, { durationFormat: "decimal_hours", decimalMark: "comma" }), "7,50", "7.50");
expect("hh:mm and minutes", [formatDuration(27_059, { durationFormat: "hh:mm", decimalMark: "point" }),
  formatDuration(27_059, { durationFormat: "minutes", decimalMark: "point" })], ["7:30", "450"], ["7:31", "451"]);
expect("whole minutes first, as on screen", formatDuration(1_199, { durationFormat: "decimal_hours", decimalMark: "point" }), "0.32", "0.33");
expect("times in the day's own zone, 24-hour",
  [formatTime("2026-10-05T16:30:00Z", "Europe/Madrid"), formatTime("2026-10-05T16:30:00Z", "Europe/London")],
  ["18:30", "17:30"], ["16:30", "16:30"]);
expect("the repeated autumn hour reads twice",
  [formatTime("2026-10-25T00:30:00Z", "Europe/Madrid"), formatTime("2026-10-25T01:30:00Z", "Europe/Madrid")],
  ["02:30", "02:30"], ["02:30", "03:30"]);

// ---- files --------------------------------------------------------------------------------------
const bom = toCsv(["a"], [["b"]], { separator: "comma", utf8Bom: true });
const noBom = toCsv(["a"], [["b"]], { separator: "comma", utf8Bom: false });
expect("byte order mark and CRLF line ends", [bom, noBom], ["\uFEFFa\r\nb\r\n", "a\r\nb\r\n"], ["a\nb\n", "a\nb\n"]);

const hours = hoursCsv([{
  userId: "u1", displayName: "=Ana Ferrer", organisationName: "Newco", date: "2026-10-05", timeZone: "Europe/Madrid",
  status: "ended", startedAt: "2026-10-05T06:50:00Z", endedAt: "2026-10-05T15:30:00Z",
  workedSeconds: 28_800, productiveSeconds: 28_800, paidSeconds: 30_600, billableSeconds: 30_600,
  isCapped: false, needsCorrection: false, hasCorrection: true,
}], DUTCH, labels).split("\r\n");
expect("hours file in the Dutch format", hours[1],
  "05-10-2026;'=Ana Ferrer;Newco;Europe/Madrid;08:50;17:30;8,00;8,50;8,50;No;Yes",
  "2026-10-05,=Ana Ferrer,Newco,Europe/Madrid,06:50,15:30,8.00,8.50,8.50,No,Yes");

const commaBoth = hoursCsv([{
  userId: "u1", displayName: "Ana", organisationName: "Newco", date: "2026-10-05", timeZone: "UTC",
  status: "ended", startedAt: "2026-10-05T08:00:00Z", endedAt: "2026-10-05T16:00:00Z",
  workedSeconds: 27_000, productiveSeconds: 0, paidSeconds: 27_000, billableSeconds: 0,
  isCapped: false, needsCorrection: false, hasCorrection: false,
}], { ...DUTCH, separator: "comma" }, labels).split("\r\n")[1];
expect("a decimal comma with a comma separator stays one cell", commaBoth,
  '05-10-2026,Ana,Newco,UTC,08:00,16:00,"7,50","7,50","0,00",No,No', "05-10-2026,Ana,Newco,UTC,08:00,16:00,7,50,7,50,0,00,No,No");

const status = statusChangesCsv([{
  userId: "u1", displayName: "Ana", organisationName: "Newco", date: "2026-10-05", timeZone: "Europe/Madrid",
  statusKey: "break", statusName: "Break", isWorking: false, isProductive: false, isPaid: true, isBillable: false,
  from: "2026-10-05T09:00:00Z", to: null, isOpen: true, isCapped: true, seconds: 900, source: "correction",
}], DUTCH, labels).split("\r\n");
expect("an open stretch has no end and names its source", status[1],
  "05-10-2026;Ana;Newco;Europe/Madrid;Break;11:00;;0,25;No;Yes;No;Correction;Yes",
  "05-10-2026;Ana;Newco;Europe/Madrid;Break;11:00;11:15;0,25;No;Yes;No;correction;Yes");
expect("the header is the caller's labels", status[0].replace("\uFEFF", "").split(";").length, 13, 12);

// An imported day (addition 0008d): the session as a working stretch, the gap in the gap status,
// both entered by the import, in the day's own zone
const imported = statusChangesCsv([
  { userId: "u1", displayName: "Ana", organisationName: "Newco", date: "2026-03-06", timeZone: "Europe/Amsterdam",
    statusKey: "legacy_session", statusName: "Earlier session", isWorking: true, isProductive: true, isPaid: true, isBillable: true,
    from: "2026-03-06T07:00:00Z", to: "2026-03-06T09:00:00Z", isOpen: false, isCapped: false, seconds: 7_200, source: "import" },
  { userId: "u1", displayName: "Ana", organisationName: "Newco", date: "2026-03-06", timeZone: "Europe/Amsterdam",
    statusKey: "break", statusName: "Break", isWorking: false, isProductive: false, isPaid: false, isBillable: false,
    from: "2026-03-06T09:00:00Z", to: "2026-03-06T09:15:00Z", isOpen: false, isCapped: false, seconds: 900, source: "import" },
], DUTCH, labels).split("\r\n");
expect("an imported stretch and its gap name the import", [imported[1], imported[2]],
  ["06-03-2026;Ana;Newco;Europe/Amsterdam;Earlier session;08:00;10:00;2,00;Yes;Yes;Yes;Import;No",
   "06-03-2026;Ana;Newco;Europe/Amsterdam;Break;10:00;10:15;0,25;No;No;No;Import;No"],
  ["06-03-2026;Ana;Newco;Europe/Amsterdam;Earlier session;08:00;10:00;2,00;Yes;Yes;Yes;;No",
   "06-03-2026;Ana;Newco;Europe/Amsterdam;Break;10:00;10:15;0,25;No;No;No;;No"]);

// Reports > Forms (addition 0008p): counts only, the period in the tenant's date format
const formsLabels = { from: "From", to: "To", form: "Form", category: "Category", market: "Market", submissions: "Submissions", previous: "Previous period",
  resolved: "Contact found", notFound: "No contact", ambiguous: "Several contacts", noEmail: "No email address", pending: "Not looked up yet",
  noCategory: "No category", unknownMarket: "Unknown market" };
const formsFile = formsCsv([
  { formName: "NL Contact", category: "contact", market: "NL", submissions: 3, previous: 4, resolved: 1, notFound: 2, ambiguous: 0, noEmail: 0, pending: 0 },
  { formName: "=Legacy; form", category: null, market: "unknown", submissions: 0, previous: 1, resolved: 0, notFound: 0, ambiguous: 0, noEmail: 0, pending: 0 },
  { formName: "Old", category: "retired", market: "GB", submissions: 2, previous: 0, resolved: 0, notFound: 0, ambiguous: 1, noEmail: 0, pending: 1 },
], "2026-10-05", "2026-10-11", { contact: "Contact" }, DUTCH, formsLabels).split("\r\n");
expect("forms file: header, the period in the tenant's format, names, unknown market and counts", formsFile.slice(0, 4),
  ["\uFEFFFrom;To;Form;Category;Market;Submissions;Previous period;Contact found;No contact;Several contacts;No email address;Not looked up yet",
   "05-10-2026;11-10-2026;NL Contact;Contact;NL;3;4;1;2;0;0;0",
   "05-10-2026;11-10-2026;\"'=Legacy; form\";No category;Unknown market;0;1;0;0;0;0;0",
   "05-10-2026;11-10-2026;Old;retired;GB;2;0;0;0;1;0;1"],
  ["From;To;Form;Category;Market;Submissions;Previous period;Contact found;No contact;Several contacts;No email address;Not looked up yet",
   "2026-10-05;2026-10-11;NL Contact;contact;NL;3;4;1;2;0;0;0",
   "2026-10-05;2026-10-11;=Legacy; form;;unknown;0;1;0;0;0;0;0",
   "2026-10-05;2026-10-11;Old;Old;GB;2;0;0;0;1;0;1"]);

// First orders (addition 0008u): the period, the deal, when in the reader's zone, the level in words, yes or no per
// evidence, the amount with the tenant's decimal mark and never a sum across currencies
const foLabels = { from: "From", to: "To", deal: "Deal", orderedAt: "Ordered", market: "Market", level: "Level", attribution: "Attribution", leadDeal: "Lead deal",
  conversation: "Conversation", email: "Email", phoneMatch: "Phone match", attempt: "Call attempt", knownContact: "Known contact", currency: "Currency",
  amount: "Amount", days: "Days from first touch", yes: "yes", no: "no", callCenter: "call center", selfService: "self-service", unknownMarket: "Unknown market" };
const foLevels = { lead_deal: "Lead deal", conversation: "Conversation", email: "Email", phone_match: "Phone match", attempt: "Call attempt",
  known_contact: "Known contact", self_service: "No evidence" };
const ev = (on) => ({ lead_deal: on.includes("l"), conversation: on.includes("c"), email: on.includes("e"), phone_match: on.includes("p"), attempt: false,
  known_contact: on.includes("k") });
const foFile = firstOrdersCsv([
  { connectionId: "c", dealSourceId: "4100000001", market: "NL", createdAt: "2026-10-05T22:30:00.000Z", level: "lead_deal", attribution: "call_center",
    evidence: ev("lek"), phoneHashed: true, hasOrder: true, currency: "EUR", amount: 1234.5, daysFromFirstTouch: 3.08, recordUrl: null },
  { connectionId: "c", dealSourceId: "4100000002", market: "unknown", createdAt: "2026-10-06T09:00:00.000Z", level: "self_service", attribution: "self_service",
    evidence: ev(""), phoneHashed: false, hasOrder: false, currency: null, amount: null, daysFromFirstTouch: null, recordUrl: null },
], "2026-10-05", "2026-10-11", "Europe/Amsterdam", DUTCH, foLabels, foLevels).split("\r\n");
expect("first orders file: header, the date and time in the reader's zone, the level in words, yes or no, the decimal comma", foFile.slice(0, 3),
  ["\uFEFFFrom;To;Deal;Ordered;Market;Level;Attribution;Lead deal;Conversation;Email;Phone match;Call attempt;Known contact;Currency;Amount;Days from first touch",
   "05-10-2026;11-10-2026;4100000001;06-10-2026 00:30;NL;Lead deal;call center;yes;no;yes;no;no;yes;EUR;1234,50;3,08",
   "05-10-2026;11-10-2026;4100000002;06-10-2026 11:00;Unknown market;No evidence;self-service;no;no;no;no;no;no;;;"],
  ["From;To;Deal;Ordered;Market;Level;Attribution;Lead deal;Conversation;Email;Phone match;Call attempt;Known contact;Currency;Amount;Days from first touch",
   "2026-10-05;2026-10-11;4100000001;2026-10-05 22:30;NL;lead_deal;call_center;true;false;true;false;false;true;EUR;1234.5;3.08",
   "2026-10-05;2026-10-11;4100000002;2026-10-06 09:00;unknown;self_service;self_service;false;false;false;false;false;false;;;"]);

// ---- Reports > Funnel and Cancellations (addition 0008zb) ----------------------------------------------------
const fnLabels = { from: "From", to: "To", pipeline: "Pipeline", stage: "Stage", readsTimes: "Times read", entered: "Entered", stillThere: "Still there",
  movedOn: "Moved on", medianDays: "Median days", p80Days: "80th percentile days", reachedWon: "Reached won", enteredPrevious: "Entered in the previous period",
  yes: "Yes", no: "No" };
const fnStage = (o) => ({ pipeline: "c:sales", pipelineLabel: "Sales", stageId: "s1", label: "New", order: 1, isClosed: false, outcome: null, readsTimes: true,
  entered: 9, stillThere: 3, movedOn: 6, timed: 6, medianDays: 1, p80Days: 2.04, reachedWon: 2, wonShare: 0.2222, enteredPrevious: 2, ...o });
const fnFile = funnelStagesCsv([fnStage({}), fnStage({ stageId: "sl", label: "=Lost", readsTimes: false, entered: null, stillThere: null, movedOn: null, timed: null,
  medianDays: null, p80Days: null, reachedWon: null, wonShare: null, enteredPrevious: null })], "2026-10-05", "2026-10-11", DUTCH, fnLabels).split("\r\n");
expect("funnel file: header, a stage per row, days with the decimal comma, a stage off with empty figures, a label defused", fnFile.slice(0, 3),
  ["﻿From;To;Pipeline;Stage;Times read;Entered;Still there;Moved on;Median days;80th percentile days;Reached won;Entered in the previous period",
   "05-10-2026;11-10-2026;Sales;New;Yes;9;3;6;1,0;2,0;2;2",
   "05-10-2026;11-10-2026;Sales;'=Lost;No;;;;;;;"],
  ["From;To;Pipeline;Stage;Times read;Entered;Still there;Moved on;Median days;80th percentile days;Reached won;Entered in the previous period",
   "2026-10-05;2026-10-11;Sales;New;true;9;3;6;1;2.04;2;2",
   "2026-10-05;2026-10-11;Sales;=Lost;false;0;0;0;0;0;0;0"]);
const lrLabels = { from: "From", to: "To", reason: "Reason", value: "Value", kind: "Kind", deals: "Lost deals", share: "Share", real: "Real reason",
  dataQuality: "Never a lead", none: "No reason", noReason: "No reason" };
const lrFile = lostReasonsCsv([{ value: "too_expensive", label: "Too expensive", deals: 3, share: 0.4286 }], [{ value: "duplicate", label: "+Duplicate", deals: 1, share: 0.1 }],
  { deals: 1, share: 0.1 }, "2026-10-05", "2026-10-11", DUTCH, lrLabels).split("\r\n");
expect("lost reasons file: real, data quality and no reason, the share as a fraction with the decimal comma, a label defused", lrFile.slice(0, 4),
  ["﻿From;To;Reason;Value;Kind;Lost deals;Share", "05-10-2026;11-10-2026;Too expensive;too_expensive;Real reason;3;0,4286",
   "05-10-2026;11-10-2026;'+Duplicate;duplicate;Never a lead;1;0,1000", "05-10-2026;11-10-2026;No reason;;No reason;1;0,1000"],
  ["From;To;Reason;Value;Kind;Lost deals;Share", "2026-10-05;2026-10-11;Too expensive;too_expensive;real;3;42.86%",
   "2026-10-05;2026-10-11;+Duplicate;duplicate;data_quality;1;10%", "2026-10-05;2026-10-11;;;none;1;10%"]);
const cnLabels = { period: "Period", day: "Day", week: "Week of", market: "Market", requests: "Requests", open: "Open", closed: "Closed",
  medianDays: "Median days to close", unknownMarket: "Unknown market" };
const cnFile = cancellationsCsv([{ key: "2026-10-05", market: "NL", requests: 2, open: 0, closed: 2, medianDaysToClose: 1.25 },
  { key: "2026-10-05", market: "unknown", requests: 1, open: 1, closed: 0, medianDaysToClose: null }], "week", DUTCH, cnLabels).split("\r\n");
expect("cancellations file: a row per week and market, Unknown market, the median with the decimal comma, empty without one", cnFile.slice(0, 3),
  ["﻿Period;Market;Requests;Open;Closed;Median days to close", "Week of 05-10-2026;NL;2;0;2;1,3", "Week of 05-10-2026;Unknown market;1;1;0;"],
  ["Period;Market;Requests;Open;Closed;Median days to close", "2026-10-05;NL;2;0;2;1.25", "2026-10-05;unknown;1;1;0;0"]);

const passed = results.filter(Boolean).length;
const n = results.length;
if (PROVOKE) {
  const ok = passed === 0;
  console.log(`\n${ok ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
  process.exit(ok ? 0 : 1);
} else {
  const ok = passed === n;
  console.log(`\n${ok ? `ALL ${n} PASS` : `${n - passed} of ${n} FAILED`}`);
  process.exit(ok ? 0 : 1);
}
