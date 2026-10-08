/**
 * Verifier: the roster's logic (src/lib/roster.ts), without a browser or a database.
 *
 *   node --experimental-strip-types verify/roster.mjs             every check must PASS
 *   node --experimental-strip-types verify/roster.mjs --provoke   every check must FAIL
 *
 * Covers the quick-typing parser (shifts in the many ways people type times, absences by key, name
 * or unambiguous start, empty clears, the midnight rule), the cell labels, the week's days across a
 * month end, planned minutes and headcount, the coverage states and grid, and the adherence flags
 * from a planned shift against the actual clock in a zone, around the autumn clock change too.
 */
import {
  adherence, cellLabel, coverageGrid, coverageState, headcountByDate, isoWeek, parseCell, plannedInstant, plannedMinutesByUser, shiftMinutes, weekDays,
} from "../src/lib/roster.ts";

const PROVOKE = process.argv.includes("--provoke");
const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(58)} got ${JSON.stringify(actual).slice(0, 66)}${pass ? "" : `, wanted ${JSON.stringify(want).slice(0, 66)}`}`);
}

const absences = [
  { key: "off", name: "Day off" }, { key: "leave", name: "Leave" }, { key: "sick", name: "Sick" },
  { key: "public_holiday", name: "Public holiday" }, { key: "other", name: "Other" },
];
const shift = (start, end) => ({ cell: { kind: "shift", start, end } });

// ---- the parser ------------------------------------------------------------------------------
expect("9-17 is a nine to five shift", parseCell("9-17", absences), shift("09:00", "17:00"), shift("09:00", "17:30"));
expect("9:30-18 with minutes", parseCell("9:30-18", absences), shift("09:30", "18:00"), shift("09:30", "18:30"));
expect("dots, h and u as separators, en dash between", parseCell("9.30 – 17h45", absences), shift("09:30", "17:45"), shift("09:30", "17:00"));
expect("four digits without a separator", parseCell("0830-1700", absences), shift("08:30", "17:00"), shift("08:30", "17:30"));
expect("'to' between the times, 24:00 as the end of the day", parseCell("16 to 24", absences), shift("16:00", "24:00"), shift("16:00", "00:00"));
expect("an end before the start is refused (no shift crosses midnight)", parseCell("22-06", absences), { problem: "order" }, shift("22:00", "06:00"));
expect("an impossible time is a format problem", parseCell("9-25:70", absences), { problem: "format" }, shift("09:00", "25:70"));
expect("off is the day-off absence by key", parseCell("off", absences), { cell: { kind: "absence", key: "off" } }, { cell: { kind: "clear" } });
expect("an absence by its name, any case", parseCell("Public Holiday", absences), { cell: { kind: "absence", key: "public_holiday" } }, { problem: "absence" });
expect("an unambiguous start of a name", parseCell("si", absences), { cell: { kind: "absence", key: "sick" } }, { cell: { kind: "absence", key: "other" } });
expect("an ambiguous start is refused", parseCell("o", absences), { problem: "absence" }, { cell: { kind: "absence", key: "off" } });
expect("an empty cell clears", parseCell("   ", absences), { cell: { kind: "clear" } }, { problem: "format" });

// ---- labels and the week ------------------------------------------------------------------------
expect("a shift is labelled with an en dash", cellLabel({ kind: "shift", start: "09:00:00", end: "17:30:00", absenceName: null }), "09:00–17:30", "09:00-17:30");
expect("an absence is labelled with its name, an empty cell with nothing",
  [cellLabel({ kind: "absence", start: null, end: null, absenceName: "Leave" }), cellLabel(null)], ["Leave", ""], ["Leave", "–"]);
expect("the week's seven days run across a month end", weekDays("2026-09-28"),
  ["2026-09-28", "2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04"],
  ["2026-09-28", "2026-09-29", "2026-09-30", "2026-09-31", "2026-10-01", "2026-10-02", "2026-10-03"]);
expect("ISO week numbers across a year end", [isoWeek("2026-10-05"), isoWeek("2026-12-28"), isoWeek("2027-01-01"), isoWeek("2027-01-04")], [41, 53, 53, 1], [41, 52, 1, 1]);
expect("minutes of a shift, 24:00 counted as midnight", [shiftMinutes("09:00", "17:30"), shiftMinutes("16:00", "24:00")], [510, 480], [510, 0]);

const entries = [
  { userId: "a", date: "2026-10-05", kind: "shift", start: "09:00", end: "17:30", absenceName: null },
  { userId: "a", date: "2026-10-06", kind: "shift", start: "09:00", end: "15:00", absenceName: null },
  { userId: "a", date: "2026-10-07", kind: "absence", start: null, end: null, absenceName: "Leave" },
  { userId: "b", date: "2026-10-05", kind: "shift", start: "10:00", end: "18:00", absenceName: null },
];
expect("planned minutes per person, shifts only", Object.fromEntries(plannedMinutesByUser(entries)), { a: 870, b: 480 }, { a: 870, b: 0 });
expect("headcount per date, absences left out", Object.fromEntries(headcountByDate(entries)), { "2026-10-05": 2, "2026-10-06": 1 }, { "2026-10-05": 2, "2026-10-06": 1, "2026-10-07": 1 });

// ---- coverage ----------------------------------------------------------------------------------
expect("coverage states", [coverageState(0, null), coverageState(1, null), coverageState(2, null), coverageState(1, 2), coverageState(2, 2)],
  ["none", "single", "ok", "short", "ok"], ["none", "ok", "ok", "short", "ok"]);
const cov = [
  { date: "2026-10-05", skillKey: "sales", skillName: "Sales", plannedPeople: 2, peopleNames: ["A", "B"], target: 2 },
  { date: "2026-10-06", skillKey: "sales", skillName: "Sales", plannedPeople: 1, peopleNames: ["A"], target: 2 },
  { date: "2026-10-05", skillKey: "debt", skillName: "Debt", plannedPeople: 1, peopleNames: ["B"], target: null },
];
const grid = coverageGrid(cov, ["2026-10-05", "2026-10-06"]);
expect("one row per work type in first-seen order, one cell per day, missing days as none",
  grid.map((r) => [r.skillKey, r.cells.map((c) => c.state)]), [["sales", ["ok", "short"]], ["debt", ["single", "none"]]], [["debt", ["single", "none"]], ["sales", ["ok", "short"]]]);

// ---- adherence --------------------------------------------------------------------------------
const Z = "Europe/Madrid";
const planned = { kind: "shift", start: "09:00:00", end: "17:00:00" };
const at = (iso) => Date.parse(iso);
expect("a planned instant in the zone", plannedInstant("2026-10-07", "09:00", Z), at("2026-10-07T07:00:00Z"), at("2026-10-07T09:00:00Z"));
expect("24:00 is midnight at the end of the day", plannedInstant("2026-10-07", "24:00", Z), at("2026-10-07T22:00:00Z"), at("2026-10-06T22:00:00Z"));
expect("on time within tolerance", adherence(planned, { startedAt: "2026-10-07T07:04:00Z", endedAt: null }, "2026-10-07", Z, at("2026-10-07T10:00:00Z"), 5), "onTime", "late");
expect("late past the tolerance", adherence(planned, { startedAt: "2026-10-07T07:06:00Z", endedAt: null }, "2026-10-07", Z, at("2026-10-07T10:00:00Z"), 5), "late", "onTime");
expect("left early", adherence(planned, { startedAt: "2026-10-07T07:00:00Z", endedAt: "2026-10-07T14:30:00Z" }, "2026-10-07", Z, at("2026-10-07T16:00:00Z"), 5), "leftEarly", "onTime");
expect("expected once the start has passed and nobody clocked in", adherence(planned, { startedAt: null, endedAt: null }, "2026-10-07", Z, at("2026-10-07T07:10:00Z"), 5), "expected", null);
expect("nothing to say before the start", adherence(planned, { startedAt: null, endedAt: null }, "2026-10-07", Z, at("2026-10-07T06:00:00Z"), 5), null, "expected");
expect("an absence planned, nobody on the clock", adherence({ kind: "absence", start: null, end: null }, { startedAt: null, endedAt: null }, "2026-10-07", Z, at("2026-10-07T10:00:00Z"), 5), "absent", null);
expect("on the clock without a plan is unplanned", adherence(null, { startedAt: "2026-10-07T07:00:00Z", endedAt: null }, "2026-10-07", Z, at("2026-10-07T10:00:00Z"), 5), "unplanned", null);
expect("the autumn change: a 02:30 start on 25 October is the earlier of the two",
  plannedInstant("2026-10-25", "02:30", Z), at("2026-10-25T00:30:00Z"), at("2026-10-25T01:30:00Z"));

const passed = results.filter(Boolean).length;
const n = results.length;
if (PROVOKE) {
  const ok = passed === 0;
  console.log(`\nroster: ${ok ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
  process.exit(ok ? 0 : 1);
} else {
  const ok = passed === n;
  console.log(`\nroster: ${ok ? `PASS (${n} checks)` : `FAIL (${n - passed} of ${n})`}`);
  process.exit(ok ? 0 : 1);
}
