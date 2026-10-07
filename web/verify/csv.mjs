/**
 * Verifier: the export files (src/lib/csv.ts), without a browser or a database.
 *
 *   node --experimental-strip-types verify/csv.mjs             every check must PASS
 *   node --experimental-strip-types verify/csv.mjs --provoke   every check must FAIL
 *
 * Covers the tenant formats (separator, decimal mark, date format, duration format, byte order
 * mark), quoting, cells a spreadsheet would run as a formula, times in each day's own zone across
 * the autumn clock change, and the settings fallback.
 */
import {
  exportSettingsFrom, formatDate, formatDuration, formatTime, hoursCsv, quote, safeText, statusChangesCsv, toCsv,
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
  enteredBy: "Entered by", sourceUser: "Person", sourceSystem: "System", sourceCorrection: "Correction", yes: "Yes", no: "No",
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
