/**
 * Verifier: tools/legacy-sessions-to-staging.mjs on the synthetic fixture in tools/fixtures/, and on
 * small files written to a temporary folder. No database, no real data.
 *
 *   node tools/verify-legacy-sessions.mjs             every check must PASS
 *   node tools/verify-legacy-sessions.mjs --provoke   every check must FAIL
 * (from web/: npm run verify:import)
 *
 * Covers the default columns and date format with CRLF, a byte order mark, semicolons and a quoted
 * name; the counts; accounts absent from the map or excluded; the staging file and the person map
 * statement; other column names, another date format and commas through the options; and the
 * refusals (the spring gap, a duplicate session, a logout before its login, a time that does not
 * read, a malformed batch key), each without writing a file; the map template.
 */
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const PROVOKE = process.argv.includes("--provoke");
const TOOL = fileURLToPath(new URL("./legacy-sessions-to-staging.mjs", import.meta.url));
const FIXTURES = fileURLToPath(new URL("./fixtures/", import.meta.url));
const dir = mkdtempSync(join(tmpdir(), "legacy-sessions-"));

const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(52)} got ${JSON.stringify(actual).slice(0, 70)}${pass ? "" : `, wanted ${JSON.stringify(want).slice(0, 70)}`}`);
}

function run(exportPath, extra = [], mapPath = join(FIXTURES, "legacy-person-map.csv")) {
  const out = join(dir, `staging-${results.length}.csv`);
  const mapSql = join(dir, `map-${results.length}.sql`);
  const r = spawnSync(process.execPath, [TOOL, exportPath, "--map", mapPath, "--zone", "Europe/Amsterdam",
    "--batch", "verify-sample", "--out", out, "--map-sql", mapSql, ...extra], { encoding: "utf8" });
  const counts = Object.fromEntries(r.stdout.split("\n").map((l) => /^(\w+)\s+(\S+)$/.exec(l)).filter(Boolean).map((m) => [m[1], m[2]]));
  return { code: r.status, counts, printed: r.stdout + r.stderr, out: existsSync(out) ? readFileSync(out, "utf8") : null,
           mapSql: existsSync(mapSql) ? readFileSync(mapSql, "utf8") : null };
}

// ---- the fixture, with the defaults -------------------------------------------------------------
const sample = run(join(FIXTURES, "legacy-sessions-sample.csv"));
expect("the fixture converts", sample.code, 0, 1);
expect("counts", sample.counts, {
  rows_read: "8", sessions_written: "6", sessions_open: "1", sessions_dropped: "2", accounts_in_export: "4",
  accounts_written: "2", accounts_absent_from_map: "1", accounts_excluded: "1", map_rows_without_sessions: "1",
  sessions_duration_differs: "1", period_from: "2026-01-02", period_to: "2026-10-09",
}, { rows_read: "8", sessions_written: "8" });
const lines = (sample.out ?? "").split("\n");
expect("the staging header", lines[0],
  "batch_key,external_person_id,external_person_name,external_session_id,login_local,logout_local,role", "PersoneelsPID;Personeel");
expect("ISO local times, an open session without a logout",
  [lines[1], lines[3]],
  ["verify-sample,1001,Test Account A,90001,2026-01-02T08:59:12,2026-01-02T12:30:00,Agent",
   "verify-sample,1001,Test Account A,90003,2026-01-05T09:00:00,,Agent"],
  ["verify-sample,1001,Test Account A,90001,2-1-2026 08:59:12,2-1-2026 12:30:00,Agent", ""]);
expect("an unpadded hour and a quoted name", lines[4],
  'verify-sample,1002,"Account, B",90004,2026-01-05T07:45:00,2026-01-05T16:00:00,Teamleider',
  "verify-sample,1002,Account, B,90004,2026-01-05T7:45:00,2026-01-05T16:00:00,Teamleider");
expect("excluded and absent accounts are dropped", ["1003", "1004"].map((p) => (sample.out ?? "").includes(`,${p},`)), [false, false], [true, true]);
expect("map statement: included accounts, emails lowercased",
  (sample.mapSql ?? "").match(/\('\d+', '[^']+'\)/g), ["('1001', 'account.a@example.com')", "('1002', 'account.b@example.com')"],
  ["('1001', 'account.a@example.com')", "('1002', 'Account.B@example.com')", "('1003', 'account.c@example.com')"]);
expect("the map statement names its batch and no other", /b\.key = 'verify-sample'/.test(sample.mapSql ?? ""), true, false);

// ---- other column names, another date format, commas -------------------------------------------
const english = join(dir, "english.csv");
writeFileSync(english, [
  "pid,name,start,stop,length,session,function",
  "1001,Test Account A,2026-03-02 09:00,2026-03-02 17:30,8:30,s1,Agent",
  "1002,Account B,2026-03-03 10:00,,,s2,Agent",
].join("\n"));
const opts = ["--col-person-id", "pid", "--col-person-name", "name", "--col-login", "start", "--col-logout", "stop",
  "--col-duration", "length", "--col-session-id", "session", "--col-role", "function", "--date-format", "yyyy-mm-dd hh:mm"];
const eng = run(english, opts);
expect("column names and the date format are options", [eng.code, (eng.out ?? "").split("\n")[1]],
  [0, "verify-sample,1001,Test Account A,s1,2026-03-02T09:00:00,2026-03-02T17:30:00,Agent"], [1, null]);
expect("without the options the columns are missing", run(english).code, 1, 0);

// ---- refusals: nothing is written ----------------------------------------------------------------
const header = "PersoneelsPID;Personeel;Ingelogd;Uitgelogd;Ingelogde tijd;Sessie-ID;Functie";
const refusals = {
  "the spring gap": "1001;A;29-3-2026 02:30:00;29-3-2026 09:00:00;6:30:00;r1;Agent",
  "a duplicate session": "1001;A;2-3-2026 09:00:00;2-3-2026 10:00:00;1:00:00;r1;Agent\r\n1001;A;3-3-2026 09:00:00;3-3-2026 10:00:00;1:00:00;r1;Agent",
  "a logout before its login": "1001;A;2-3-2026 09:00:00;2-3-2026 08:00:00;;r1;Agent",
  "a time that does not read": "1001;A;2026-03-02 09:00;2-3-2026 10:00:00;;r1;Agent",
  "a row without a session id": "1001;A;2-3-2026 09:00:00;2-3-2026 10:00:00;;;Agent",
};
for (const [name, body] of Object.entries(refusals)) {
  const f = join(dir, `refuse-${results.length}.csv`);
  writeFileSync(f, `${header}\r\n${body}\r\n`);
  const r = run(f);
  expect(`refused: ${name}`, [r.code, r.out === null, r.mapSql === null], [1, true, true], [0, false, false]);
}
const badKey = spawnSync(process.execPath, [TOOL, join(FIXTURES, "legacy-sessions-sample.csv"), "--map", join(FIXTURES, "legacy-person-map.csv"),
  "--zone", "Europe/Amsterdam", "--batch", "Steam 2026", "--out", join(dir, "never.csv")], { encoding: "utf8" });
expect("refused: a malformed batch key", [badKey.status, existsSync(join(dir, "never.csv"))], [2, false], [0, true]);
const template = join(dir, "template.csv");
const tpl = spawnSync(process.execPath, [TOOL, join(FIXTURES, "legacy-sessions-sample.csv"), "--map-template", template], { encoding: "utf8" });
expect("a map template lists every account of the export",
  [tpl.status, existsSync(template) ? readFileSync(template, "utf8").split("\n").slice(0, 3) : null],
  [0, ["steam_pid,work_email,include,steam_name,sessions,first_day,last_day", "1001,,,Test Account A,4,2026-01-02,2026-10-09",
       '1002,,,"Account, B",2,2026-01-05,2026-01-06']], [1, null]);
expect("the tool prints no name and no email", /Test Account|Account, B|@example\.com/i.test(sample.printed), false, true);

rmSync(dir, { recursive: true, force: true });
const passed = results.filter(Boolean).length;
const n = results.length;
if (PROVOKE) {
  console.log(passed === 0 ? `\nALL ${n} PROVOKED CHECKS FAILED, as they must` : `\n${passed} of ${n} checks did not fail when provoked`);
  process.exit(passed === 0 ? 0 : 1);
}
console.log(passed === n ? `\nALL ${n} PASS` : `\n${n - passed} of ${n} FAILED`);
process.exit(passed === n ? 0 : 1);
