/**
 * Verifier: the day editor's logic (src/lib/corrections.ts), without a browser or a database.
 *
 *   node --experimental-strip-types verify/corrections.mjs             every check must PASS
 *   node --experimental-strip-types verify/corrections.mjs --provoke   every check must FAIL
 *
 * Covers the clock changes of Europe/Madrid in 2026 (29 March: 02:00 to 02:59 does not exist;
 * 25 October: 02:00 to 02:59 occurs twice), the order rules, and the diff: unchanged rows send
 * nothing, a changed row replaces its event, a removed row is voided, Add day starts with the start.
 */
import { check, instantsForLocal, localParts, normalizeTime, rowsFromEvents } from "../src/lib/corrections.ts";

const PROVOKE = process.argv.includes("--provoke");
const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(48)} got ${JSON.stringify(actual).slice(0, 70)}${pass ? "" : `, wanted ${JSON.stringify(want).slice(0, 70)}`}`);
}

const TZ = "Europe/Madrid";
const LATER = Date.parse("2030-01-01T00:00:00Z");

// ---- zone math --------------------------------------------------------------------------------
expect("an ordinary time has one instant",
  instantsForLocal("2026-10-05", "09:00", TZ).map((x) => x.at), ["2026-10-05T09:00:00+02:00"], []);
expect("the repeated autumn hour has two instants",
  instantsForLocal("2026-10-25", "02:30", TZ).map((x) => x.at),
  ["2026-10-25T02:30:00+02:00", "2026-10-25T02:30:00+01:00"], ["2026-10-25T02:30:00+02:00"]);
expect("the skipped spring hour has none", instantsForLocal("2026-03-29", "02:30", TZ).length, 0, 1);
expect("a time after the autumn change is winter time",
  instantsForLocal("2026-10-25", "03:00", TZ).map((x) => x.offset), ["+01:00"], ["+02:00"]);
expect("a zone west of UTC", instantsForLocal("2026-10-05", "09:00", "America/New_York")[0]?.at,
  "2026-10-05T09:00:00-04:00", "2026-10-05T09:00:00+04:00");
expect("local parts read the day's zone, not the server's",
  localParts("2026-10-05T07:00:00Z", TZ), { date: "2026-10-05", time: "09:00", offset: "+02:00" },
  { date: "2026-10-05", time: "07:00", offset: "+00:00" });

expect("typed times become 24-hour hh:mm", ["905", "0905", "9:05", "17.30", "25:00"].map(normalizeTime),
  ["09:05", "09:05", "09:05", "17:30", "25:00"], ["905", "0905", "9:05", "17.30", "25:00"]);

// ---- rows and diff ----------------------------------------------------------------------------
const ev = (id, kind, at, statusKey = null) =>
  ({ id, kind, statusKey, statusName: null, at, recordedAt: at, source: "user", supersedes: null, reason: null, approvedByName: null, isEffective: true });
const ID = (n) => `00000000-0000-4000-8000-00000000000${n}`;
const day = [
  ev(ID(1), "start", "2026-10-05T07:00:00Z", "available"),
  ev(ID(2), "status", "2026-10-05T09:00:00Z", "break"),
  ev(ID(3), "status", "2026-10-05T09:15:00Z", "available"),
  ev(ID(4), "end", "2026-10-05T15:30:00Z"),
  { ...ev(ID(5), "end", "2026-10-05T15:00:00Z"), isEffective: false },   // an earlier, replaced end
];
const original = rowsFromEvents(day, TZ);
expect("rows show effective events in local time",
  original.map((r) => `${r.time} ${r.end ? "end" : r.statusKey}`),
  ["09:00 available", "11:00 break", "11:15 available", "17:30 end"], ["09:00 available"]);

const run = (rows, date = "2026-10-05", base = original) => check(base, rows, date, TZ, LATER);
expect("unchanged rows send nothing", run(original).dayProblems, ["noChange"], []);

const moved = original.map((r) => (r.eventId === ID(4) ? { ...r, time: "18:00" } : r));
expect("a changed time replaces that event", run(moved).changes,
  [{ kind: "end", at: "2026-10-05T18:00:00+02:00", supersedes: ID(4) }], [{ kind: "end", at: "2026-10-05T18:00:00+02:00" }]);

const removed = original.filter((r) => r.eventId !== ID(2) && r.eventId !== ID(3));
expect("a removed row voids its event", run(removed).changes,
  [{ kind: "void", supersedes: ID(2) }, { kind: "void", supersedes: ID(3) }], []);

const earlier = [...original, { id: "n1", eventId: null, end: false, statusKey: "training", time: "08:30", offset: null }];
expect("a new earlier row becomes the start", run(earlier).changes,
  [{ kind: "start", at: "2026-10-05T08:30:00+02:00", statusKey: "training" },
   { kind: "status", at: "2026-10-05T09:00:00+02:00", statusKey: "available", supersedes: ID(1) }],
  [{ kind: "start", at: "2026-10-05T08:30:00+02:00", statusKey: "training" }]);

const addDay = [
  { id: "a", eventId: null, end: true, statusKey: null, time: "17:00", offset: null },
  { id: "b", eventId: null, end: false, statusKey: "available", time: "09:00", offset: null },
];
expect("add day sends the start first", run(addDay, "2026-10-02", []).changes.map((c) => c.kind), ["start", "end"], ["end", "start"]);

// ---- refusals ---------------------------------------------------------------------------------
const one = (time, extra = {}) => [{ id: "x", eventId: null, end: false, statusKey: "available", time, offset: null, ...extra }];
expect("a skipped time is refused", run(one("02:30"), "2026-03-29", []).rowProblems, { x: "gap" }, {});
expect("a repeated time needs an offset", run(one("02:30"), "2026-10-25", []).rowProblems, { x: "ambiguous" }, {});
expect("a chosen offset resolves it", run(one("02:30", { offset: "+01:00" }), "2026-10-25", []).changes[0]?.at,
  "2026-10-25T02:30:00+01:00", "2026-10-25T02:30:00+02:00");
expect("a future time is refused", check([], one("09:00"), "2026-10-05", TZ, Date.parse("2026-10-05T06:00:00Z")).rowProblems,
  { x: "future" }, {});
expect("the first row cannot be clocked out",
  run([{ id: "e", eventId: null, end: true, statusKey: null, time: "08:00", offset: null }, ...one("09:00")], "2026-10-05", []).dayProblems,
  ["firstIsEnd"], []);
expect("two clock-outs are refused",
  run([...one("09:00"), { id: "e1", eventId: null, end: true, statusKey: null, time: "16:00", offset: null },
       { id: "e2", eventId: null, end: true, statusKey: null, time: "17:00", offset: null }], "2026-10-05", []).dayProblems,
  ["twoEnds"], []);
expect("nothing after the clock-out",
  run([...one("09:00"), { id: "e", eventId: null, end: true, statusKey: null, time: "16:00", offset: null },
       { id: "y", eventId: null, end: false, statusKey: "available", time: "17:00", offset: null }], "2026-10-05", []).dayProblems,
  ["endNotLast"], []);
expect("an invalid time is refused", run(one("9.00"), "2026-10-05", []).rowProblems, { x: "time" }, {});

const passed = results.filter(Boolean).length;
const n = results.length;
if (PROVOKE) {
  console.log(passed === 0 ? `\nALL ${n} PROVOKED CHECKS FAILED, as they must` : `\n${passed} of ${n} checks did not fail when provoked`);
  process.exit(passed === 0 ? 0 : 1);
}
console.log(passed === n ? `\nALL ${n} PASS` : `\n${n - passed} of ${n} FAILED`);
process.exit(passed === n ? 0 : 1);
