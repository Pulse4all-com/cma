/**
 * Verifier: the configuration screens' logic (src/lib/configuration.ts), without a browser or a database.
 *
 *   node --experimental-strip-types verify/configuration.mjs             every check must PASS
 *   node --experimental-strip-types verify/configuration.mjs --provoke   every check must FAIL
 *
 * Covers the frozen-flags and retire rules as the database applies them, the status list order,
 * the form checks, market and level parsing, coverage targets, the minute settings and the
 * export preview in every format. Keys and names are fixture values; nothing branches on them.
 */
import {
  exportPreview, flagsFrozen, levelsText, parseLevels, parseMarkets, parseMinutes, parseTarget, retireProblem, statusFormProblem, targetAt, visibleStatuses,
} from "../src/lib/configuration.ts";

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

const passed = results.filter(Boolean).length;
const n = results.length;
if (PROVOKE) {
  const ok = passed === 0;
  console.log(`\n${ok ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
  process.exit(ok ? 0 : 1);
}
console.log(`\n${passed === n ? `ALL ${n} PASS` : `${n - passed} of ${n} FAILED`}`);
process.exit(passed === n ? 0 : 1);
