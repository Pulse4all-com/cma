/**
 * Verifier: the Dashboard's figures (src/lib/dashboard.ts), without a browser or a database.
 *
 *   node --experimental-strip-types verify/dashboard.mjs             every check must PASS
 *   node --experimental-strip-types verify/dashboard.mjs --provoke   every check must FAIL
 *
 * Covers the groups from flags (never from a key or name), the agent's view without the pay flag,
 * worked and paid minutes added up per person per day exactly as Team hours does, totals, the
 * tenant's status order with inactive statuses kept, every day of the period on the axis (across a
 * month end), people by name, the hours axis, and that every group colour is a palette token.
 */
import { readFileSync } from "node:fs";
import {
  GROUP_BG, GROUP_FILL, GROUPS, agentGroupOf, byDay, byPerson, byStatus, groupOf, groupTotal, hoursAxis, peopleOf,
  share, summarise,
} from "../src/lib/dashboard.ts";

const PROVOKE = process.argv.includes("--provoke");
const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(56)} got ${JSON.stringify(actual).slice(0, 70)}${pass ? "" : `, wanted ${JSON.stringify(want).slice(0, 70)}`}`);
}

// Fixture: keys and names that would mislead any code reading them, flags that decide
const S = {
  work: { statusKey: "lunch", statusName: "Lunch", sortOrder: 30, statusActive: true, isWorking: true, isProductive: true, isPaid: true, isBillable: true },
  other: { statusKey: "available", statusName: "Available", sortOrder: 20, statusActive: true, isWorking: true, isProductive: false, isPaid: true, isBillable: true },
  paidPause: { statusKey: "zz_break", statusName: "Break", sortOrder: 40, statusActive: false, isWorking: false, isProductive: false, isPaid: true, isBillable: false },
  unpaidPause: { statusKey: "aa_break", statusName: "Break too", sortOrder: 40, statusActive: true, isWorking: false, isProductive: false, isPaid: false, isBillable: false },
};
const A = { userId: "a", displayName: "Zoë", organisationName: "Partner", timeZone: "Europe/Madrid" };
const B = { userId: "b", displayName: "Ana", organisationName: "Company", timeZone: "Europe/Amsterdam" };
const row = (p, date, s, seconds, extra = {}) => ({ ...p, date, ...s, seconds, stretches: 1, isCapped: false, ...extra });
const rows = [
  // Zoë, 2026-10-30: 61 s + 61 s working (2 whole minutes), 600 s paid pause, 300 s unpaid pause
  row(A, "2026-10-30", S.work, 61),
  row(A, "2026-10-30", S.other, 61),
  row(A, "2026-10-30", S.paidPause, 600),
  row(A, "2026-10-30", S.unpaidPause, 300),
  // Zoë, 2026-11-02: 59 s working (0 whole minutes), not clocked out
  row(A, "2026-11-02", S.work, 59, { isCapped: true }),
  // Ana, 2026-10-30: 2 h working, 15 min paid pause
  row(B, "2026-10-30", S.work, 7200, { stretches: 3 }),
  row(B, "2026-10-30", S.paidPause, 900),
];

// ---- groups from flags -------------------------------------------------------------------------
expect("four flag combinations give the four groups",
  [groupOf(S.work), groupOf(S.other), groupOf(S.paidPause), groupOf(S.unpaidPause)],
  ["productive", "otherWork", "paidPause", "unpaidPause"],
  ["productive", "otherWork", "unpaidPause", "paidPause"]);
expect("a key or name never decides the group",
  [groupOf({ ...S.work, statusKey: "break", statusName: "Break" }), groupOf({ ...S.unpaidPause, statusKey: "available" })],
  ["productive", "unpaidPause"], ["paidPause", "productive"]);
expect("agents see one pause colour, not the pay flag",
  [agentGroupOf(S.paidPause), agentGroupOf(S.unpaidPause), agentGroupOf(S.other)],
  ["pause", "pause", "otherWork"], ["paidPause", "unpaidPause", "otherWork"]);

// ---- summary: minutes as Team hours adds them --------------------------------------------------
const sum = summarise(rows);
expect("worked minutes are whole minutes per person per day, added",
  [sum.workedMinutes, sum.workedSeconds], [2 + 0 + 120, 61 + 61 + 59 + 7200], [Math.floor((61 + 61 + 59 + 7200) / 60), 7381]);
expect("paid minutes are whole minutes per person per day, added",
  sum.paidMinutes, Math.floor((61 + 61 + 600) / 60) + 0 + Math.floor((7200 + 900) / 60), Math.floor((61 + 61 + 600 + 59 + 7200 + 900) / 60));
expect("groups add up to the clocked time",
  [groupTotal(sum.groups), sum.clockedSeconds, sum.groups.unpaidPause], [9181, 9181, 300], [9181, 9180, 0]);
expect("people, person-days and days not clocked out",
  [sum.people, sum.personDays, sum.cappedDays], [2, 3, 1], [3, 3, 0]);
expect("productive share of worked time", Math.round(share(sum.productiveSeconds, sum.workedSeconds) * 1000) / 1000,
  Math.round(((61 + 59 + 7200) / 7381) * 1000) / 1000, 1);
expect("nothing to divide by is no share", share(5, 0), null, 0);

// ---- per status: the tenant's order, inactive kept ---------------------------------------------
const statuses = byStatus(rows);
expect("statuses in sort order, then key; inactive kept",
  statuses.map((s) => [s.key, s.active, s.seconds]),
  [["available", true, 61], ["lunch", true, 7320], ["aa_break", true, 300], ["zz_break", false, 1500]],
  [["lunch", true, 7320], ["available", true, 61], ["zz_break", false, 1500], ["aa_break", true, 300]]);

// ---- per day: every date on the axis, across a month end ----------------------------------------
const days = byDay(rows, "2026-10-30", "2026-11-02");
expect("every day of the period, empty ones included",
  days.map((d) => [d.date, d.seconds]),
  [["2026-10-30", 9122], ["2026-10-31", 0], ["2026-11-01", 0], ["2026-11-02", 59]],
  [["2026-10-30", 9122], ["2026-11-02", 59]]);
expect("rows outside the period are left out", byDay(rows, "2026-10-31", "2026-11-01").reduce((n, d) => n + d.seconds, 0), 0, 59);

// ---- per person: by name, minutes as Team hours -------------------------------------------------
const persons = byPerson(rows);
expect("people by name with their own whole minutes",
  persons.map((p) => [p.displayName, p.workedMinutes, p.paidMinutes, p.clockedSeconds]),
  [["Ana", 120, 135, 8100], ["Zoë", 2, 12, 1081]],
  [["Zoë", 3, 12, 1081], ["Ana", 120, 135, 8100]]);
expect("the person filter lists the people with time", peopleOf(rows).map((p) => p.userId), ["b", "a"], ["a"]);

// ---- hours axis -----------------------------------------------------------------------------------
expect("a readable hours axis",
  [hoursAxis(0), hoursAxis(3600), hoursAxis(9 * 3600), hoursAxis(45 * 3600)],
  [{ top: 8, step: 2 }, { top: 1, step: 1 }, { top: 10, step: 2 }, { top: 48, step: 12 }],
  [{ top: 8, step: 2 }, { top: 1, step: 1 }, { top: 9, step: 1 }, { top: 45, step: 9 }]);

// ---- colours are palette tokens -------------------------------------------------------------------
const css = readFileSync(new URL("../src/app/globals.css", import.meta.url), "utf8");
const tokens = [...Object.values(GROUP_BG), ...Object.values(GROUP_FILL)].map((c) => c.replace(/^(bg|fill)-/, ""));
expect("every group colour is a palette token",
  tokens.filter((t) => !css.includes(`--color-${t}:`)), [], ["p4a-red"]);
expect("four groups, each with a fill and a background",
  GROUPS.map((g) => !!GROUP_BG[g] && !!GROUP_FILL[g]), [true, true, true, true], [true, true, true]);

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
