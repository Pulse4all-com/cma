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
 * (since, worked so far, which stops at the day's end since addition 0008b) from fixed instants,
 * and the window start read from a refused clock-in. Since addition 0008i (brief B15) also the inbound
 * tiles and the missed calls not called back as 61 proves them in the database: a caller missed twice
 * as one row, called back by an outbound attempt on another connection and by an answered inbound
 * call, an earlier outbound call not counting, a later missed call calling nobody back, the lookback, a reason without a callback, anonymous
 * calls counted and never listed, a waiting call not missed and a lost one missed, oldest first, office
 * time or the time since the call, the link only with a template, and no caller in any answer.
 */
import {
  INBOUND_TILES, LIVE_GROUPS, callbackWaiting, employersOf, filterRows, fmtSeconds, inboundTileValue, liveGroupOf, liveRows, missedCallbacks,
  secondsSince, sortCallbacks, teamKeysByUser, teamsOf, tiles, workedSeconds, workdayStartsAt,
} from "../src/lib/live.ts";
import { personalDataIn } from "../src/lib/reports.ts";

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

// Teams (migration 0004): memberships as cma.team_members_now returns them; a person may be in several
const memberships = [
  { userId: "p1", teamKey: "zz", teamName: "Zulu" }, { userId: "p1", teamKey: "aa", teamName: "Alpha" },
  { userId: "p2", teamKey: "aa", teamName: "Alpha" }, { userId: "p9", teamKey: "mm", teamName: "Not on the board" },
];
expect("team keys per person, sorted", Object.fromEntries(teamKeysByUser(memberships)), { p1: ["aa", "zz"], p2: ["aa"], p9: ["mm"] }, { p1: ["zz", "aa"], p2: ["aa"], p9: ["mm"] });
expect("the team filter keeps the team's people across groups", filterRows(rows, { group: "", employer: "", team: "aa" }, memberships).map((r) => r.person.userId),
  ["p1", "p2"], ["p1"]);
expect("the team filter combines with the others", filterRows(rows, { group: "productive", employer: "partner", team: "zz" }, memberships).map((r) => r.person.userId), ["p1"], []);
expect("no team filter without memberships changes nothing", filterRows(rows, { group: "", employer: "", team: "" }, []).length, 7, 2);
expect("teams on the board by name, a team of nobody on it left out", teamsOf(rows, memberships), [{ key: "aa", name: "Alpha" }, { key: "zz", name: "Zulu" }],
  [{ key: "aa", name: "Alpha" }, { key: "mm", name: "Not on the board" }, { key: "zz", name: "Zulu" }]);

// The figures that tick, from fixed instants
const nowMs = Date.parse("2026-10-07T09:00:30.000Z");
expect("since counts whole seconds from the instant", secondsSince(T1, nowMs), 1830, 1800);
expect("since is never negative", secondsSince("2026-10-07T10:00:00.000Z", nowMs), 0, -3570);
expect("worked adds the running stretch to the closed ones", workedSeconds({ closedSeconds: 600, runningSince: T1 }, nowMs), 2430, 600);
expect("worked stands still while paused or ended", workedSeconds({ closedSeconds: 9000, runningSince: null }, nowMs), 9000, 9030);
// The workday window (addition 0008b): the running stretch stops at the day's end, as the database counts
expect("worked stops at the day's end", workedSeconds({ closedSeconds: 600, runningSince: T1 }, nowMs, "2026-10-07T08:45:00.000Z"), 1500, 2430);
expect("a stretch begun after the day's end counts nothing",
  workedSeconds({ closedSeconds: 54000, runningSince: "2026-10-07T09:00:00.000Z" }, nowMs, "2026-10-07T08:00:00.000Z"), 54000, 54030);
expect("a refused clock-in gives the window start, nothing else does",
  ["the workday starts at 07:00", "the workday starts at 25:00", "invalid", null].map(workdayStartsAt),
  ["07:00", null, null, null], ["07:00", "25:00", null, null]);
expect("the format drops the hour below one", [fmtSeconds(5), fmtSeconds(3599), fmtSeconds(3600), fmtSeconds(37230)],
  ["0:05", "59:59", "1:00:00", "10:20:30"], ["0:05", "59:59", "1:00:00", "10:20:31"]);

// ---- inbound today and the missed calls not called back (addition 0008i) -------------------------
const today = { offered: 28, answered: 17, unanswered: 10, waiting: 1, answeredWithinTarget: 11, serviceLevelBase: 25, serviceLevelPct: 44,
  avgAnswerSeconds: 17.2, p80AnswerSeconds: 25.8, unansweredByReason: {}, date: "2026-10-14", waitingNow: 1, longestWaitingSeconds: 120,
  serviceLevelSeconds: 20, waitingMaxMinutes: 30 };
expect("the inbound tiles in order with their values",
  INBOUND_TILES.map((k) => inboundTileValue(today, k)),
  [{ kind: "count", value: 28 }, { kind: "count", value: 17 }, { kind: "pct", value: 37 }, { kind: "pct", value: 44 },
    { kind: "seconds", value: 17.2 }, { kind: "count", value: 1 }, { kind: "seconds", value: 120 }],
  [{ kind: "count", value: 28 }, { kind: "count", value: 17 }, { kind: "pct", value: 35.7 }, { kind: "pct", value: 44 },
    { kind: "seconds", value: 17.2 }, { kind: "count", value: 1 }, { kind: "seconds", value: 120 }]);
// The calls of 61 B6 to B10 (invented ids; callers are opaque keys standing in for the hash)
const NOW = Date.parse("2026-10-14T12:00:00Z");
const ago = (minutes) => new Date(NOW - minutes * 60_000).toISOString();
const reasons = [{ sourceSystem: "tel", code: "out_of_opening_hours", label: "Outside hours", countsInServiceLevel: false, needsCallback: false }];
const lines = [{ connectionId: "c", lineRef: "nl", name: "NL line", market: "NL", zone: "Europe/Amsterdam", isCounted: true }];
const call = (sourceId, direction, minutesAgo, answerAfter, ended, reason, lineRef, caller, connectionId = "c") => ({
  sourceId, connectionId, sourceSystem: "tel", direction, startedAt: ago(minutesAgo),
  answeredAt: answerAfter === null ? null : new Date(NOW - minutesAgo * 60_000 + answerAfter * 1000).toISOString(),
  endedAt: ended ? new Date(NOW - minutesAgo * 60_000 + 30_000).toISOString() : null, missedReason: reason, lineRef, caller,
});
const calls = [
  call("w-1", "inbound", 5, null, false, null, "nl", "h9"), call("w-2", "inbound", 40, null, false, null, "none", "h10"),
  call("c1-a", "inbound", 180, null, true, "no_available_agent", "nl", "h1"), call("c1-b", "inbound", 60, null, true, "agents_did_not_answer", "nl", "h1"),
  call("c2-a", "inbound", 120, null, true, "no_available_agent", "nl", "h2"), call("c2-o", "outbound", 60, null, true, null, "b", "h2", "c-b"),
  call("c3-a", "inbound", 120, null, true, "no_available_agent", "nl", "h3"), call("c3-b", "inbound", 30, 10, true, null, "nl", "h3"),
  call("c4-o", "outbound", 300, 6, true, null, "nl", "h4"), call("c4-a", "inbound", 120, null, true, "abandoned_in_ivr", "nl", "h4"),
  call("c5-a", "inbound", 4 * 1440, null, true, "no_available_agent", "nl", "h5"),
  call("c6-a", "inbound", 120, null, true, "out_of_opening_hours", "nl", "h6"),
  call("c7-a", "inbound", 150, null, true, "no_available_agent", "nl", "h7"), call("c7-b", "inbound", 20, null, true, "out_of_opening_hours", "nl", "h7"),
  call("an-1", "inbound", 120, null, true, "no_available_agent", "nl", null), call("an-2", "inbound", 90, null, true, null, "nl", null),
  call("an-3", "inbound", 80, null, true, "out_of_opening_hours", "nl", null),
];
const business = (market, from, toMs) => (market === "NL" ? Math.floor((toMs - Date.parse(from)) / 1000) : null);
const url = (connectionId, sourceId) => (sourceId === "c1-b" ? `https://phone.example.com/calls/${sourceId}` : null);
const cb = (lookback) => missedCallbacks(calls, lines, reasons, "Europe/Amsterdam", 30, lookback, NOW, business, url);
const three = cb(3);
expect("a caller missed twice is one row (2), oldest first; a later missed call calls nobody back",
  three.rows.map((r) => `${r.sourceId}:${r.reasonCode}:${r.missedCount}`),
  ["c7-a:no_available_agent:2", "c4-a:abandoned_in_ivr:1", "c1-b:agents_did_not_answer:2", "w-2:unknown:1"],
  ["c1-a:no_available_agent:2", "c4-a:abandoned_in_ivr:1", "c1-b:agents_did_not_answer:1"]);
expect("called back by an outbound attempt and by an answered call; an earlier outbound call does not count",
  ["c2-a", "c3-a", "c4-a"].map((id) => three.rows.some((r) => r.sourceId === id)), [false, false, true], [true, true, false]);
expect("the lookback (3 days out, 5 in) and a reason without a callback",
  [three.rows.some((r) => r.sourceId === "c5-a"), cb(5).rows.some((r) => r.sourceId === "c5-a"), three.rows.some((r) => r.sourceId === "c6-a")],
  [false, true, false], [true, true, true]);
expect("anonymous calls counted and never listed; a waiting call is not missed",
  [three.anonymousCount, three.rows.some((r) => r.sourceId.startsWith("an-")), three.rows.some((r) => r.sourceId === "w-1")],
  [2, false, false], [3, true, true]);
expect("waiting in office time, or the time since the call for a line without a market",
  three.rows.map((r) => callbackWaiting(r)),
  [{ kind: "business", seconds: 9000 }, { kind: "business", seconds: 7200 }, { kind: "business", seconds: 3600 }, { kind: "elapsed", seconds: 2400 }],
  [{ kind: "elapsed", seconds: 9000 }, { kind: "elapsed", seconds: 7200 }, { kind: "elapsed", seconds: 3600 }, { kind: "business", seconds: 2400 }]);
expect("the link only where the connection has a template",
  three.rows.map((r) => r.recordUrl !== null), [false, false, true, false], [true, true, true, true]);
expect("no caller, hash, number or name in an answer",
  [personalDataIn(three), ["h1", "h4", "h10"].some((h) => JSON.stringify(three).includes(`"${h}"`))], [[], false], [["$.rows"], true]);
expect("oldest first, then by the call's id",
  sortCallbacks([{ startedAt: ago(10), sourceId: "b" }, { startedAt: ago(20), sourceId: "z" }, { startedAt: ago(10), sourceId: "a" }]).map((r) => r.sourceId),
  ["z", "a", "b"], ["a", "b", "z"]);

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
