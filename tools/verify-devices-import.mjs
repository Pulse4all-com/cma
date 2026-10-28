/**
 * Verifier: tools/devices-to-staging.mjs on the synthetic fixture in tools/fixtures/ with the example map in
 * docs/import/, and on small files written to a temporary folder. No database, no real data.
 *
 *   node tools/verify-devices-import.mjs             every check must PASS
 *   node tools/verify-devices-import.mjs --provoke   every check must FAIL
 * (from web/: npm run verify:devices-import)
 *
 * Covers the fixture with the example map (30 rows, the counts, the staging header, the dates as YYYY-MM-DD, the
 * components and the named ids as JSON, the export's line as source_row); no ignored column ever reaches the staging
 * file (the personal columns' synthetic values are absent from it), a mapped cell holding an @ is written as a bare @
 * and counted, and the tool prints no value; every data-quality
 * case of 113 is in the fixture (a missing serial, a duplicate, an unmapped model, status and country, a customer
 * reference that is no id, a device without dates or components, a device in the field without a subscription); a
 * mapped kind with every cell empty written as an empty object, one whose expiry does not read left out; the
 * three date formats, each read strictly (a day of 31 in a 30-day month, a two-digit year and the other formats fail)
 * and the failures counted with their line and column, never their value, the cell written empty; the refusals, each
 * without writing a file: a header neither mapped nor ignored, a mapped header the export lacks, a header both mapped
 * and ignored, an unknown staging column or key in the map, a malformed kind or name, no source_id, a row without a
 * record id, a record id holding an @, a record id twice (its lines named), a cell longer than 500 characters; and the
 * usage errors (no or an
 * unknown --date-format, a malformed batch key, a map that is no JSON).
 */
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { convert, mapProblems, parseDate } from "./devices-to-staging.mjs";

const PROVOKE = process.argv.includes("--provoke");
const TOOL = fileURLToPath(new URL("./devices-to-staging.mjs", import.meta.url));
const FIXTURE = fileURLToPath(new URL("./fixtures/devices-sample.csv", import.meta.url));
const MAP = fileURLToPath(new URL("../docs/import/devices-map.example.json", import.meta.url));
const dir = mkdtempSync(join(tmpdir(), "devices-import-"));

const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(56)} got ${JSON.stringify(actual).slice(0, 70)}${pass ? "" : `, wanted ${JSON.stringify(want).slice(0, 70)}`}`);
}

function run(exportPath, extra = ["--date-format", "dmy"], mapPath = MAP) {
  const out = join(dir, `staging-${results.length}.csv`);
  const r = spawnSync(process.execPath, [TOOL, exportPath, "--map", mapPath, "--batch", "verify-devices", "--out", out, ...extra], { encoding: "utf8" });
  const counts = Object.fromEntries(r.stdout.split("\n").map((l) => /^(\w+)\s+(\S+)$/.exec(l)).filter(Boolean).map((m) => [m[1], m[2]]));
  return { code: r.status, counts, printed: r.stdout + r.stderr, out: existsSync(out) ? readFileSync(out, "utf8") : null };
}
const write = (name, text) => { const p = join(dir, name); writeFileSync(p, text); return p; };
const mapOf = (patch) => write(`map-${results.length}-${Math.random().toString(36).slice(2, 8)}.json`, JSON.stringify({ ...JSON.parse(readFileSync(MAP, "utf8")), ...patch }));

// ---- the fixture, with the example map ------------------------------------------------------------
const sample = run(FIXTURE);
expect("the fixture converts", sample.code, 0, 1);
expect("counts", sample.counts, { rows: "30", mapped_columns: "21", ignored_columns: "31", date_parse_failures: "0", values_with_at: "1" },
  { rows: "30", mapped_columns: "52" });
const lines = (sample.out ?? "").trimEnd().split("\n");
expect("the staging header",
  lines[0],
  "batch_key,source_row,source_id,serial,model,status,country,warehouse_ref,customer_ref,subscription_ref,order_ref,first_shipped_on,"
    + "stock_received_on,last_shipped_on,warranty_until,end_of_life_on,components,external_refs",
  "aed_sn,aed_sn_check");
expect("a row: the line, dates as YYYY-MM-DD, components and named ids as JSON",
  lines[1],
  'verify-devices,2,recTESTFIX000001,TEST-SN-0001,HS1,Active/Customer,United Kingdom,,7000000001,9100000001,#TEST1001,2025-03-10,,,2033-03-10,2033-03-10,'
    + '"{""pads"":{""serial"":""TEST-PAD-0001"",""expires_on"":""2027-01-10""},""battery"":{""serial"":""TEST-BAT-0001"",""expires_on"":""2027-02-20""}}",'
    + '"{""ns_internal_id"":""50001"",""ns_fam_id"":""FAM-0001"",""ns_sales_order_id"":""SO-0001""}"',
  "verify-devices,2,recTESTFIX000001,TEST-SN-0001,HS1,Active/Customer,United Kingdom,,,,,10/03/2025");
expect("no ignored column, no address reaches the staging file; no value printed",
  [/example\.invalid|Person \d\d|Test Editor|checked, synthetic|Test entity|PO-TEST|\w@|@\w/.test(sample.out ?? ""),
   /TEST-SN|recTESTFIX|example\.invalid|Person \d\d/.test(sample.printed)],
  [false, false], [true, true]);
// every data-quality case 113 checks is in the fixture, as the staging file carries it
const rows = lines.slice(1).map((l) => l.split(","));
const col = (name) => lines[0].split(",").indexOf(name);
expect("the fixture covers every data-quality case",
  [rows.filter((r) => r[col("serial")] === "").length,
   rows.filter((r) => r[col("serial")] === "TEST-SN-0005").length,
   rows.filter((r) => r[col("model")] === "model_aed").length,
   rows.filter((r) => r[col("status")] === "Returned").length,
   rows.filter((r) => ["Spain", "Italy"].includes(r[col("country")])).length,
   rows.filter((r) => r[col("customer_ref")] === "@").length,
   rows.filter((r) => r[col("status")] === "In Storage" && r[col("first_shipped_on")] === "" && r[col("last_shipped_on")] === ""
                      && !/""pads"":\{""/.test(lines[rows.indexOf(r) + 1])).length,
   rows.filter((r) => r[col("status")] === "Active/Customer" && r[col("subscription_ref")] === "").length],
  [1, 2, 1, 1, 2, 1, 2, 1], [0, 0, 0, 0, 0, 0, 0, 0]);

// an emptied kind (every mapped cell empty) is an empty object, so the load closes the device's current one; a kind
// whose expiry does not read is left out, so nothing is closed on a date the tool could not read
const kindMap = { columns: { source_id: "id" }, components: { pads: { serial: "ps", expires_on: "pe" }, battery: { serial: "bs" } }, ignore: [] };
const kinds = convert("id,ps,pe,bs\nr1,,,B-1\nr2,,31/02/2026,\nr3,P-3,01/01/2027,\n", kindMap, { batch: "b", dateFormat: "dmy" });
const kindsAt = convert("id,ps,pe,bs\nr1,a@b,,B-1\n", kindMap, { batch: "b", dateFormat: "dmy" });
expect("an emptied kind an empty object; a kind whose expiry does not read left out; an @ in a component cell counted once",
  [...kinds.rows.map((r) => r[r.length - 2]), kindsAt.rows[0][kindsAt.rows[0].length - 2], kindsAt.counts.values_with_at],
  ['{"pads":{},"battery":{"serial":"B-1"}}', '{"battery":{}}', '{"pads":{"serial":"P-3","expires_on":"2027-01-01"},"battery":{}}',
   '{"pads":{"serial":"@"},"battery":{"serial":"B-1"}}', 1],
  ['{"battery":{"serial":"B-1"}}', '', '{"pads":{"serial":"P-3","expires_on":"2027-01-01"}}', '', 2]);

// ---- dates ---------------------------------------------------------------------------------------------
expect("the three formats, strictly",
  [parseDate("15/11/2024", "dmy"), parseDate("5.1.2024", "dmy"), parseDate("15-11-2024", "dmy"), parseDate("11/15/2024", "mdy"),
   parseDate("2024-11-15", "iso"), parseDate("2024-2-5", "iso"), parseDate("", "dmy"), parseDate("31/04/2026", "dmy"), parseDate("15/11/24", "dmy"),
   parseDate("2024-11-15", "dmy"), parseDate("15/11/2024", "mdy"), parseDate("15/11/2024", "iso"), parseDate("29/02/2025", "dmy")],
  ["2024-11-15", "2024-01-05", "2024-11-15", "2024-11-15", "2024-11-15", "2024-02-05", "", null, null, null, null, null, null],
  ["2024-11-15", "2024-01-05", "2024-11-15", "2024-11-15", "2024-11-15", "2024-02-05", "", "2026-05-01", null, null, null, null, null]);
const wrongFormat = run(FIXTURE, ["--date-format", "mdy"]);
// line 5 (the fourth record) ships on 15/01/2025: as mdy the month is 15, so the cell is written empty; a day of 12 or
// less still reads, wrongly, which is why the format is never guessed and a wrong one shows as many failures
expect("a wrong format: failures counted with line and column, never the value, the cell empty",
  [wrongFormat.code, Number(wrongFormat.counts.date_parse_failures) > 10, /date not read: line \d+: \w+/.test(wrongFormat.printed),
   /\d\d\/\d\d\/\d{4}/.test(wrongFormat.printed), (wrongFormat.out ?? "").split("\n")[4]?.split(",")[11] === ""],
  [0, true, true, false, true], [1, false, false, true, false]);

// ---- refusals, nothing written ---------------------------------------------------------------------------
const header = readFileSync(FIXTURE, "utf8").split("\n")[0];
const body = readFileSync(FIXTURE, "utf8").split("\n").slice(1).join("\n");
const extraColumn = run(write("extra.csv", `${header},customer_phone\n${body.split("\n").map((l) => (l ? `${l},+31000000000` : l)).join("\n")}`));
const missingColumn = run(write("missing.csv", readFileSync(FIXTURE, "utf8").replace("pads_sn,", "pads_serial,")));
const both = run(FIXTURE, ["--date-format", "dmy"], mapOf({ ignore: [...JSON.parse(readFileSync(MAP, "utf8")).ignore, "aed_sn"] }));
const unknownColumn = run(FIXTURE, ["--date-format", "dmy"], mapOf({ columns: { ...JSON.parse(readFileSync(MAP, "utf8")).columns, customer_name: "customer_first_name" } }));
const badKind = run(FIXTURE, ["--date-format", "dmy"], mapOf({ components: { Pads: { serial: "pads_sn" } } }));
const noSource = run(FIXTURE, ["--date-format", "dmy"], mapOf({ columns: { serial: "aed_sn" } }));
expect("refused: an unknown header, a missing one, mapped and ignored, an unknown column, a kind, no source_id",
  [extraColumn.code, /customer_phone/.test(extraColumn.printed), extraColumn.out, missingColumn.code, /pads_sn/.test(missingColumn.printed), missingColumn.out,
   both.code, both.out, unknownColumn.code, unknownColumn.out, badKind.code, badKind.out, noSource.code, noSource.out],
  [1, true, null, 1, true, null, 1, null, 1, null, 1, null, 1, null],
  [0, false, "x", 0, false, "x", 0, "x", 0, "x", 0, "x", 0, "x"]);
const dupe = run(write("dupe.csv", `${header}\n${body.split("\n")[0]}\n${body.split("\n")[1]}\n${body.split("\n")[0]}\n`));
const noId = run(write("noid.csv", `${header}\n${body.split("\n")[0].replace("recTESTFIX000001", "")}\n`));
const long = run(write("long.csv", `${header}\n${body.split("\n")[0].replace("TEST-SN-0001", "X".repeat(501))}\n`));
const atId = run(write("atid.csv", `${header}\n${body.split("\n")[0].replace("recTESTFIX000001", "person@example.invalid")}\n`));
expect("refused: a record id twice (its lines named), no record id, an id with an @, a cell over 500 characters",
  [dupe.code, /lines 2, 4: one record id appears 2 times/.test(dupe.printed), dupe.out, noId.code, /line 2: no record id/.test(noId.printed), noId.out,
   atId.code, /line 2: the record id holds an @/.test(atId.printed), /example\.invalid/.test(atId.printed), atId.out, long.code, long.out],
  [1, true, null, 1, true, null, 1, true, false, null, 1, null], [0, false, "x", 0, false, "x", 0, false, true, "x", 0, "x"]);
const noFormat = run(FIXTURE, []);
const otherFormat = run(FIXTURE, ["--date-format", "auto"]);
const badBatch = spawnSync(process.execPath, [TOOL, FIXTURE, "--map", MAP, "--date-format", "dmy", "--batch", "Bad Key", "--out", join(dir, "x.csv")], { encoding: "utf8" });
const badMap = run(FIXTURE, ["--date-format", "dmy"], write("bad.json", "{ not json"));
expect("usage: no or an unknown --date-format, a malformed batch key, a map that is no JSON",
  [noFormat.code, noFormat.out, otherFormat.code, badBatch.status, badMap.code], [2, null, 2, 2, 2], [0, "x", 0, 0, 0]);
expect("the map's own checks",
  [mapProblems(JSON.parse(readFileSync(MAP, "utf8"))).length, mapProblems({ columns: { source_id: "id" }, external_refs: { "Bad name": "x" } }).length,
   mapProblems({ columns: { source_id: "id" }, components: { device: { serial: "s" } } }).length, mapProblems([]).length,
   convert("a,b\n1,2\n", { columns: { source_id: "a" }, ignore: ["b"] }, { batch: "b", dateFormat: "iso" }).counts.rows],
  [0, 1, 1, 1, 1], [1, 0, 0, 0, 0]);

rmSync(dir, { recursive: true, force: true });
const passed = results.filter(Boolean).length;
const n = results.length;
if (PROVOKE) {
  console.log(passed === 0 ? `\nALL ${n} PROVOKED CHECKS FAILED, as they must` : `\n${passed} of ${n} checks did not fail when provoked`);
  process.exit(passed === 0 ? 0 : 1);
}
console.log(passed === n ? `\nALL ${n} PASS` : `\n${n - passed} of ${n} FAILED`);
process.exit(passed === n ? 0 : 1);
