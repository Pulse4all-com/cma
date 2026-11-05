/**
 * Unit test: tools/legacy-export-html-to-csv.mjs on the synthetic fixture
 * tools/fixtures/legacy-login-out-sample.xls (an HTML table named .xls, two ISO weeks, Steam's
 * footer row) and on small files written to a temporary folder. No database, no real data.
 *
 *   node --test tools/*.test.mjs
 * (also run by tools/verify-legacy-sessions.mjs, from web/: npm run verify:import)
 */
import { test, after } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { decodeEntities, decodeExport, isoWeek, readTable, splitByWeek } from "./legacy-export-html-to-csv.mjs";

const TOOL = fileURLToPath(new URL("./legacy-export-html-to-csv.mjs", import.meta.url));
const STAGING = fileURLToPath(new URL("./legacy-sessions-to-staging.mjs", import.meta.url));
const FIXTURES = fileURLToPath(new URL("./fixtures/", import.meta.url));
const SAMPLE = join(FIXTURES, "legacy-login-out-sample.xls");
const root = mkdtempSync(join(tmpdir(), "legacy-export-html-"));
after(() => rmSync(root, { recursive: true, force: true }));

let runs = 0;
/** The tool on a file, into a fresh folder: exit code, printed lines and the files it wrote */
function run(exportPath, extra = []) {
  const out = mkdtempSync(join(root, `out-${runs++}-`));
  const r = spawnSync(process.execPath, [TOOL, exportPath, "--out", out, ...extra], { encoding: "utf8" });
  const files = Object.fromEntries(readdirSync(out).sort().map((f) => [f, readFileSync(join(out, f), "utf8")]));
  return { code: r.status, stdout: r.stdout, stderr: r.stderr, out, files };
}

/** A small HTML file in the temporary folder */
function html(name, body) {
  const path = join(root, name);
  writeFileSync(path, `<html><body>${body}</body></html>\n`);
  return path;
}

const HEADER = "<thead><tr><th>PersoneelsPID</th><th>Ingelogd</th><th>Sessie-ID</th></tr></thead>";

test("the fixture: one file per ISO week of the login, the footer dropped and counted", () => {
  const r = run(SAMPLE);
  assert.equal(r.code, 0, r.stderr);
  assert.deepEqual(Object.keys(r.files), ["steam-export-w44.csv", "steam-export-w45.csv"]);
  assert.deepEqual(r.stdout.split("\n"), [
    `${join(r.out, "steam-export-w44.csv")}  3 rows`,
    `${join(r.out, "steam-export-w45.csv")}  2 rows`,
    "rows_read                    6",
    "rows_dropped_footer          1",
    "",
  ]);
  assert.ok(!Object.values(r.files).some((t) => t.includes("# Records")), "the footer row is in no file");
});

test("the CSV: the table's header, cells trimmed, entities decoded, quoted where needed, the export's order", () => {
  const { files } = run(SAMPLE);
  assert.equal(files["steam-export-w44.csv"], [
    "PersoneelsPID,Personeel,Ingelogd,Uitgelogd,Ingelogde tijd,Sessie-ID,Functie",
    "1001,Test Account A,26-10-2026 08:59:12,26-10-2026 12:30:00,3:30:48,90001,Agent",
    '1002,"Account, B & Co",26-10-2026 7:45:00,26-10-2026 16:00:00,8:15:00,90002,Teamleider',
    "1001,Test Account A,30-10-2026 09:00:00,,,90003,Agent",
    "",
  ].join("\n"));
  assert.equal(files["steam-export-w45.csv"], [
    "PersoneelsPID,Personeel,Ingelogd,Uitgelogd,Ingelogde tijd,Sessie-ID,Functie",
    "1003,Test Account \u00c9,2-11-2026 09:00:00,2-11-2026 17:00:00,8:00:00,90004,Agent",
    '1005,"Test Account ""E""",3-11-2026 09:00:00,3-11-2026 12:00:00,3:00:00,90005,Directie',
    "",
  ].join("\n"));
});

test("a week's file is step 4's export: session ids from Sessie-ID, no --session-id-from", () => {
  const { out } = run(SAMPLE);
  const r = spawnSync(process.execPath, [STAGING, join(out, "steam-export-w44.csv"), "--map", join(FIXTURES, "legacy-person-map.csv"),
    "--zone", "Europe/Amsterdam", "--batch", "steam-2026-w44", "--out", join(out, "staging.csv")], { encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
  const counts = Object.fromEntries(r.stdout.split("\n").map((l) => /^(\w+)\s+(\S+)$/.exec(l)).filter(Boolean).map((m) => [m[1], m[2]]));
  assert.equal(counts.sessions_written, "3");
  assert.equal(counts.sessions_open, "1");
  assert.equal(counts.sessions_duration_differs, "0");
  assert.equal(counts.period_from, "2026-10-26");
  assert.equal(counts.period_to, "2026-10-30");
  assert.match(readFileSync(join(out, "staging.csv"), "utf8"), /^steam-2026-w44,1001,Test Account A,90003,2026-10-30T09:00:00,,Agent$/m);
});

test("refused, nothing written: a file without a <table>", () => {
  const r = run(html("no-table.xls", "<p>No data</p>"));
  assert.equal(r.code, 1);
  assert.match(r.stderr, /refused, nothing written/);
  assert.match(r.stderr, /no <table>/);
  assert.deepEqual(r.files, {});
});

test("refused, nothing written: a header without the login column", () => {
  const other = run(SAMPLE, ["--col-login", "Login"]);
  assert.equal(other.code, 1);
  assert.match(other.stderr, /the header has no column "Login"/);
  assert.deepEqual(other.files, {});
  const noHead = run(html("no-thead.xls", "<table><tr><td>PersoneelsPID</td><td>Ingelogd</td></tr><tr><td>1001</td><td>26-10-2026 09:00:00</td></tr></table>"));
  assert.equal(noHead.code, 1);
  assert.match(noHead.stderr, /no header row in <thead>/);
  assert.deepEqual(noHead.files, {});
});

test("refused, nothing written: a login that does not parse, its table row named", () => {
  const r = run(html("bad-login.xls", `<table>${HEADER}<tbody>`
    + "<tr><td>1001</td><td>26-10-2026 09:00:00</td><td>1</td></tr>"
    + "<tr><td>1001</td><td>2026-10-27 09:00:00</td><td>2</td></tr>"
    + "<tr><td>1001</td><td>31-2-2026 09:00:00</td><td>3</td></tr>"
    + "<tr><td>1001</td><td>&nbsp;</td><td>4</td></tr>"
    + "</tbody></table>"));
  assert.equal(r.code, 1);
  assert.match(r.stderr, /3 problem\(s\)/);
  assert.match(r.stderr, /table row 3: the login does not read as d-m-yyyy/);
  assert.match(r.stderr, /table row 4: /);
  assert.match(r.stderr, /table row 5: /);
  assert.deepEqual(r.files, {}, "not even the week that did parse");
});

test("refused, nothing written: a table without a row of the header's width, and weeks of two years in one file name", () => {
  const empty = run(html("footer-only.xls", `<table>${HEADER}<tbody><tr><td colspan="3"># Records: 0</td></tr></tbody></table>`));
  assert.equal(empty.code, 1);
  assert.match(empty.stderr, /no row of the header's 3 cells/);
  const years = run(html("two-years.xls", `<table>${HEADER}<tbody>`
    + "<tr><td>1001</td><td>5-1-2026 09:00:00</td><td>1</td></tr><tr><td>1001</td><td>11-1-2027 09:00:00</td><td>2</td></tr></tbody></table>"));
  assert.equal(years.code, 1);
  assert.match(years.stderr, /ISO weeks 2026-W02 and 2027-W02 would both write steam-export-w02\.csv/);
  assert.deepEqual(years.files, {});
});

test("ISO weeks: Monday to Sunday, the Thursday decides the year", () => {
  assert.deepEqual(isoWeek("2026-10-26"), { year: 2026, week: 44 });
  assert.deepEqual(isoWeek("2026-11-01"), { year: 2026, week: 44 });
  assert.deepEqual(isoWeek("2026-11-02"), { year: 2026, week: 45 });
  assert.deepEqual(isoWeek("2026-10-25"), { year: 2026, week: 43 });
  assert.deepEqual(isoWeek("2026-12-31"), { year: 2026, week: 53 });
  assert.deepEqual(isoWeek("2027-01-03"), { year: 2026, week: 53 });
  assert.deepEqual(isoWeek("2027-01-04"), { year: 2027, week: 1 });
  assert.deepEqual(isoWeek("2025-12-29"), { year: 2026, week: 1 });
});

test("the table: closing tags HTML lets a file leave out, comments, tags inside a cell", () => {
  const rows = readTable("<TABLE><!-- <tr><td>x</td></tr> --><THEAD><TR><TH>A<TH>B<TBODY><TR><TD><b>1</b><TD> 2 <TR><TD>3<TD>&#52;</TABLE><table><tr><td>other</td></tr></table>");
  assert.deepEqual(rows, [{ head: true, cells: ["A", "B"] }, { head: false, cells: ["1", "2"] }, { head: false, cells: ["3", "4"] }]);
  assert.equal(decodeEntities("&lt;a&gt; &amp;amp; &#x41;&#66; &euml; &unknown; &#0;"), "<a> &amp; AB \u00eb &unknown; \ufffd");
  assert.equal(decodeEntities("&constructor; &toString;"), "&constructor; &toString;", "no inherited name reads as an entity");
  assert.equal(splitByWeek("<table><thead><tr><th>Start</th></tr></thead><tr><td>2026-10-26 09:00</td></tr></table>",
    { loginColumn: "Start", dateFormat: "yyyy-mm-dd", prefix: "other" }).files[0].name, "other-w44.csv");
});

test("the charset: a byte order mark, a <meta>, else UTF-8; bytes that do not read refuse", () => {
  const latin = Buffer.concat([Buffer.from('<meta charset="windows-1252"><p>'), Buffer.from([0xe9]), Buffer.from("</p>")]);
  assert.equal(decodeExport(latin).text, '<meta charset="windows-1252"><p>é</p>');
  const utf16 = Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from("<table>", "utf16le")]);
  assert.equal(decodeExport(utf16).text, "<table>");
  const bom = Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from("<table>")]);
  assert.equal(decodeExport(bom).text, "<table>");
  assert.match(decodeExport(Buffer.from([0x3c, 0x70, 0x3e, 0xe9, 0x3c])).problem, /does not read as utf-8/);
  assert.match(decodeExport(Buffer.from('<meta charset="x-unknown">')).problem, /does not know/);
});
