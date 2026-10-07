/**
 * Verifier: the Live board's logic (src/lib/live.ts), without a browser or a database.
 *
 *   node --experimental-strip-types verify/live.mjs             every check must PASS
 *   node --experimental-strip-types verify/live.mjs --provoke   every check must FAIL
 *
 * Covers the group of a person from the current status's flags (never from a key or name) and
 * from the day's state (clocked out, not clocked in), the row order (group, then name, no
 * ranking), the tiles (a flag group only when an active status belongs to it, the two day states
 * always, counts before any filter), the filters, the employers, and the two figures that tick
 * (since, worked so far) from fixed instants.
 */
import {
  LIVE_GROUPS, employersOf, filterRows, fmtSeconds, liveGroupOf, liveRows, secondsSince, tiles, workedSeconds,
} from "../src/lib/live.ts";

const PROVOKE = process.argv.includes("--provoke");
const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(56)} got ${JSON.stringify(actual).slice(0, 70)}${pass ? "" : `, wanted ${JSON.stringify(want).slice(0, 70)}`}`);
}

// Fixture: keys and names that would mislead any code reading them; the flags decide
const T0 = "2026-10-07T06:00:00.000Z";
const T1 = "2026-10-07T08:30:00.000Z";
const status = (key, name, f) => ({ key, name, isActive: true, isBillable: f.isPaid, ...f });
const S = {
  work: status("lunch", "Lunch", { isWorking: true, isProductive: true, isPaid: true }),
  other: status("available", "Available", { isWorking: true, isProductive: false, isPaid: true }),
  paidPause: status("zz_break", "Break", { isWorking: false, isProductive: false, isPaid: true }),
  unpaidPause: status("aa_break", "Break too", { isWorking: false, isProductive: false, isPaid: false }),
};
const day = (statusKey, statusSince, clock, ended = false) => ({
  date: "2026-10-07", status: ended ? "ended" : "working", startedAt: T0, endedAt: ended ? T1 : null,
  statusKey: ended ? null : statusKey, statusSince: ended ? null : statusSince, clock,
});
const person = (id, name, org, day, status) => ({
  userId: id, displayName: name, organisationKey: org ? org.toLowerCase() : null, organisationName: org ?? "",
  timeZone: "Europe/Madrid", date: "2026-10-07", day, status,
});
const people = [
  person("p1", "Zoë", "Partner", day("lunch", T1, { closedSeconds: 600, runningSince: T1 }), S.work),
  person("p2", "Ana", "Company", day("available", T1, { closedSeconds: 0, runningSince: T0 }), S.other),
  person("p3", "Bo", "Partner", day("zz_break", T1, { closedSeconds: 9000, runningSince: null }), S.paidPause),
  person("p4", "Cas", "Partner", day("aa_break", T1, { closedSeconds: 9000, runningSince: null }), S.unpaidPause),
  person("p5", "Dee", "Company", day("lunch", T1, { closedSeconds: 9000, runningSince: null }, true), null),
  person("p6", "Abe", null, null, null),
  person("p7", "Ada", "Company", day("lunch", T1, { closedSeconds: 0, runningSince: T1 }), S.work),
];

// Groups from flags and from the day's state
expect("working and productive is productive", liveGroupOf(people[0]), "productive", "otherWork");
expect("working, not productive is other work", liveGroupOf(people[1]), "otherWork", "productive");
expect("not working, paid is a paid pause", liveGroupOf(people[2]), "paidPause", "unpaidPause");
expect("not working, unpaid is an unpaid pause", liveGroupOf(people[3]), "unpaidPause", "paidPause");
expect("an ended day is clocked out, whatever its last status", liveGroupOf(people[4]), "clockedOut", "productive");
expect("no day is not clocked in", liveGroupOf(people[5]), "notClockedIn", "clockedOut");
expect("the order is work, pauses, then off the clock", LIVE_GROUPS,
  ["productive", "otherWork", "paidPause", "unpaidPause", "clockedOut", "notClockedIn"],
  ["notClockedIn", "clockedOut", "unpaidPause", "paidPause", "otherWork", "productive"]);

// Rows: by group, then by name, never by any figure
const rows = liveRows(people);
expect("rows sort by group, then by name", rows.map((r) => r.person.displayName),
  ["Ada", "Zoë", "Ana", "Bo", "Cas", "Dee", "Abe"], ["Zoë", "Ada", "Ana", "Bo", "Cas", "Dee", "Abe"]);

// Tiles: a flag group only when an active status belongs to it; the two day states always
const allFlags = [S.work, S.other, S.paidPause, S.unpaidPause];
expect("six tiles with their counts when every group has a status", tiles(rows, allFlags).map((x) => [x.group, x.count]),
  [["productive", 2], ["otherWork", 1], ["paidPause", 1], ["unpaidPause", 1], ["clockedOut", 1], ["notClockedIn", 1]],
  [["productive", 1], ["otherWork", 1], ["paidPause", 1], ["unpaidPause", 1], ["clockedOut", 1], ["notClockedIn", 1]]);
expect("no paid pause tile without a paid pause status", tiles(rows, [S.work, S.other, S.unpaidPause]).map((x) => x.group),
  ["productive", "otherWork", "unpaidPause", "clockedOut", "notClockedIn"],
  ["productive", "otherWork", "paidPause", "unpaidPause", "clockedOut", "notClockedIn"]);
expect("the day-state tiles exist even with no status at all", tiles(rows, []).map((x) => x.group),
  ["clockedOut", "notClockedIn"], []);

// Filters and employers
expect("the group filter keeps that group", filterRows(rows, { group: "productive", employer: "" }).map((r) => r.person.userId),
  ["p7", "p1"], ["p1"]);
expect("the employer filter keeps that employer, across groups", filterRows(rows, { group: "", employer: "company" }).map((r) => r.person.userId),
  ["p7", "p2", "p5"], ["p2", "p5"]);
expect("both filters combine", filterRows(rows, { group: "productive", employer: "partner" }).map((r) => r.person.userId), ["p1"], ["p7", "p1"]);
expect("no filter keeps everyone", filterRows(rows, { group: "", employer: "" }).length, 7, 6);
expect("employers by name, a person without one left out", employersOf(rows), [{ key: "company", name: "Company" }, { key: "partner", name: "Partner" }],
  [{ key: "partner", name: "Partner" }, { key: "company", name: "Company" }]);

// The figures that tick, from fixed instants
const nowMs = Date.parse("2026-10-07T09:00:30.000Z");
expect("since counts whole seconds from the instant", secondsSince(T1, nowMs), 1830, 1800);
expect("since is never negative", secondsSince("2026-10-07T10:00:00.000Z", nowMs), 0, -3570);
expect("worked adds the running stretch to the closed ones", workedSeconds({ closedSeconds: 600, runningSince: T1 }, nowMs), 2430, 600);
expect("worked stands still while paused or ended", workedSeconds({ closedSeconds: 9000, runningSince: null }, nowMs), 9000, 9030);
expect("the format drops the hour below one", [fmtSeconds(5), fmtSeconds(3599), fmtSeconds(3600), fmtSeconds(37230)],
  ["0:05", "59:59", "1:00:00", "10:20:30"], ["0:05", "59:59", "1:00:00", "10:20:31"]);

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
