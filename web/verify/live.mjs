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
 * call, an earlier outbound call not counting, a later missed call calling nobody back, the lookback, a
 * reason without a callback, anonymous calls counted and never listed, a waiting call not missed and a
 * lost one missed, oldest first, office time or the time since the call, the link only with a template,
 * no caller in any answer, and the times missed counted since the latest callback (61 B15). Since the IT audit of
 * 17 October 2026 also when the waiting figure reads Closed (no office time since the call) instead of 0 min. Since
 * addition 0008zv also one contact center's board (boardOfOrganisation): its people only, with their memberships and
 * shifts, a person without an organisation on no board, the status flags, inbound and follow-up as read. Since addition
 * 0009h also Outbound today as 165 proves it in the database: the attempts, connected, the connected rate with one
 * decimal and its dash without an attempt, the outbound conversations only (not under the talk threshold, not with a
 * tag meaning not reached, never an inbound one), the talk time of the connected calls and its average, each call on
 * its day in its line's zone, a line that does not count left out, the settings moving the figures; and the absence
 * of Longest waiting: no such tile, no such field, no such word in the copy, the registry or the catalog. Since
 * addition 0009j Inbound today's Talk time in place of Waiting now, as 169 proves it in the database: the six tiles in
 * their order, Talk time in the column of Outbound today's, a dash without an answered call, the talk time of the
 * answered inbound calls of the tenant's day (Reports → Calls' talk time minus its outbound talk time but for calls on
 * another day in their line's zone), and no
 * Waiting now key in the copy, the registry, the catalog, the types, the component, the mock or the mapping. Since the
 * Live board's UX and speed pass (10 November 2026): Inbound today by hour's 24 columns from Reports → Inbound's hour
 * rows (the total row left out), the axis' clean top, the board's word on its own freshness (old after two failed polls,
 * never after one; a poll gives up before the next is due), and the board's words: exactly the hints and follow-up words
 * the board shows, each in English and Dutch, a small part of the whole hints object.
 */
import {
  INBOUND_TILES, LIVE_FOLLOW_UP_KEYS, LIVE_GROUPS, LIVE_HINT_KEYS, LIVE_POLL_TIMEOUT_MS, LIVE_STALE_AFTER_FAILURES, OUTBOUND_TILES, boardOfOrganisation, callbackWaiting,
  employersOf, filterRows, fmtSeconds, hoursDue, inboundHours, inboundTalkToday, inboundTileValue, isStale, LIVE_HOURS_MS, liveBoardWords, liveGroupOf, liveRows,
  missedCallbacks, niceCeiling,
  outboundTileValue, outboundToday, secondsSince, sortCallbacks, teamKeysByUser, teamsOf, tiles, workedSeconds, workdayStartsAt,
} from "../src/lib/live.ts";
import { callRecords, callRules, callsFigures, fmtRate1, fmtTalk, personalDataIn } from "../src/lib/reports.ts";
import { readFileSync } from "node:fs";
import { gzipSync } from "node:zlib";
import { copy } from "../src/lib/copy.ts";

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

// One contact center's board (addition 0008zv): its people, their memberships and shifts; the rest as read
const read = {
  now: { people, statusFlags: [{ isWorking: true, isProductive: true, isPaid: true }] },
  memberships,
  shifts: [{ userId: "p1", date: "2026-10-07" }, { userId: "p2", date: "2026-10-07" }, { userId: "p3", date: "2026-10-07" }],
  inbound: { telephony: true, callbacks: [{ sourceId: "c-1" }] },
  followUp: { leadsPastTarget: 4 },
  settings: { adherenceToleranceMinutes: 5 },
  readAt: T1,
};
const partner = boardOfOrganisation(read, "partner");
expect("a contact center's board holds its people only, a person without one on none",
  [partner.now.people.map((p) => p.userId), boardOfOrganisation(read, "company").now.people.map((p) => p.userId)],
  [["p1", "p3", "p4"], ["p2", "p5", "p7"]], [["p1", "p3", "p4", "p6"], ["p2", "p5", "p6", "p7"]]);
expect("and only their memberships and shifts",
  [partner.memberships.map((m) => `${m.userId}:${m.teamKey}`), partner.shifts.map((x) => x.userId)],
  [["p1:zz", "p1:aa"], ["p1", "p3"]], [["p1:zz", "p1:aa", "p2:aa", "p9:mm"], ["p1", "p2", "p3"]]);
expect("the status flags, inbound, follow-up, settings and the instant stay as read",
  [partner.now.statusFlags === read.now.statusFlags, partner.inbound === read.inbound, partner.followUp === read.followUp,
    partner.settings === read.settings, partner.readAt === read.readAt],
  [true, true, true, true, true], [false, true, true, true, true]);
expect("the tiles count the board's people only",
  tiles(liveRows(partner.now.people), [S.work, S.other, S.paidPause, S.unpaidPause]).map((x) => `${x.group}:${x.count}`),
  ["productive:1", "otherWork:0", "paidPause:1", "unpaidPause:1", "clockedOut:0", "notClockedIn:0"],
  ["productive:2", "otherWork:1", "paidPause:1", "unpaidPause:1", "clockedOut:1", "notClockedIn:1"]);
expect("an organisation no one works for gives an empty board, the read itself unchanged",
  [boardOfOrganisation(read, "nobody").now.people.length, read.now.people.length, read.memberships.length], [0, 7, 4], [7, 7, 4]);

// The figures that tick, from fixed instants
const nowMs = Date.parse("2026-10-07T09:00:30.000Z");
expect("since counts whole seconds from the instant", secondsSince(T1, nowMs), 1830, 1800);
expect("since is never negative", secondsSince("2026-10-07T10:00:00.000Z", nowMs), 0, -3570);
expect("worked adds the running stretch to the closed ones", workedSeconds({ closedSeconds: 600, runningSince: T1 }, nowMs), 2430, 600);
expect("worked stands still while paused or ended", workedSeconds({ closedSeconds: 9000, runningSince: null }, nowMs), 9000, 9030);

// A split shift (addition 0008zp): in the gap between two sessions the person is clocked out and the clock
// stands still; back for the second session they are in their status again, and worked time is the closed
// first session plus the running stretch, the gap counting nothing
const inGap = person("p8", "Eli", "Partner", { ...day("lunch", T1, { closedSeconds: 7200, runningSince: null }, true), sessions: 1, canClockInAgain: true }, null);
const backAgain = person("p9", "Fay", "Partner", { ...day("lunch", T1, { closedSeconds: 7200, runningSince: T1 }), sessions: 2, sessionStartedAt: T1 }, S.work);
expect("in the gap between two sessions a person is clocked out", liveGroupOf(inGap), "clockedOut", "productive");
expect("back for a second session a person is in their status", liveGroupOf(backAgain), "productive", "clockedOut");
expect("the gap is not worked: the first session plus the running stretch",
  workedSeconds(backAgain.day.clock, nowMs), 7200 + Math.floor((nowMs - Date.parse(T1)) / 1000), 7200 + Math.floor((nowMs - Date.parse(T0)) / 1000));
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
  avgAnswerSeconds: 17.2, p80AnswerSeconds: 25.8, unansweredByReason: {}, date: "2026-10-14", inboundTalkSeconds: 1234,
  serviceLevelSeconds: 20, waitingMaxMinutes: 30 };
expect("the inbound tiles in order with their values",
  INBOUND_TILES.map((k) => [k, inboundTileValue(today, k)]),
  [["offered", { kind: "count", value: 28 }], ["answered", { kind: "count", value: 17 }], ["unansweredPct", { kind: "pct", value: 37 }],
    ["serviceLevel", { kind: "pct", value: 44 }], ["talk", { kind: "talk", value: 1234 }], ["avgAnswer", { kind: "seconds", value: 17.2 }]],
  [["offered", { kind: "count", value: 28 }], ["answered", { kind: "count", value: 17 }], ["unansweredPct", { kind: "pct", value: 35.7 }],
    ["serviceLevel", { kind: "pct", value: 44 }], ["avgAnswer", { kind: "seconds", value: 17.2 }], ["waitingNow", { kind: "count", value: 1 }]]);
expect("six inbound tiles, Talk time the fifth, in the column of Outbound today's Talk time; no Waiting now, no Longest waiting",
  [INBOUND_TILES.length, INBOUND_TILES.indexOf("talk"), INBOUND_TILES.indexOf("talk") === OUTBOUND_TILES.indexOf("talk"),
    INBOUND_TILES.includes("waitingNow"), INBOUND_TILES.includes("longestWaiting")],
  [6, 4, true, false, false], [6, 5, false, true, false]);
// the dash needs no answered call and no talk time: a line east of the tenant can carry talk time on the date before the
// tenant's first answered call of the day (Answered counts the tenant's day, the talk time each call's line-zone day)
expect("Talk time as Outbound today's shows it, a dash without an answered call and without talk time",
  [fmtTalk(inboundTileValue(today, "talk").value, "en"), inboundTileValue({ ...today, answered: 0, inboundTalkSeconds: 0 }, "talk"),
    fmtTalk(inboundTileValue({ ...today, answered: 0, inboundTalkSeconds: 0 }, "talk").value, "nl"), fmtTalk(inboundTileValue({ ...today, inboundTalkSeconds: 0 }, "talk").value, "en"),
    fmtTalk(inboundTileValue({ ...today, answered: 0, inboundTalkSeconds: 70 }, "talk").value, "en")],
  ["20m 34s", { kind: "talk", value: null }, "–", "0 s", "1m 10s"], ["1234 s", { kind: "talk", value: 0 }, "0 s", "–", "–"]);
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
  [{ kind: "business", seconds: 9000, closed: false }, { kind: "business", seconds: 7200, closed: false }, { kind: "business", seconds: 3600, closed: false }, { kind: "elapsed", seconds: 2400, closed: false }],
  [{ kind: "elapsed", seconds: 9000, closed: false }, { kind: "elapsed", seconds: 7200, closed: false }, { kind: "elapsed", seconds: 3600, closed: false }, { kind: "business", seconds: 2400, closed: false }]);
// Closed (the IT audit of 17 October 2026): no office time since the call although time has passed, so the board says
// "Closed" instead of "0 min"; a call missed this very second, a line without a market and any office time at all are not closed
expect("closed when no office time has passed since the call, and only then",
  [{ waitingBusinessSeconds: 0, waitingSeconds: 54000 }, { waitingBusinessSeconds: 0, waitingSeconds: 0 }, { waitingBusinessSeconds: null, waitingSeconds: 54000 },
    { waitingBusinessSeconds: 30, waitingSeconds: 54000 }].map((r) => callbackWaiting(r).closed),
  [true, false, false, false], [true, true, false, false]);
expect("the link only where the connection has a template",
  three.rows.map((r) => r.recordUrl !== null), [false, false, true, false], [true, true, true, true]);
expect("no caller, hash, number or name in an answer",
  [personalDataIn(three), ["h1", "h4", "h10"].some((h) => JSON.stringify(three).includes(`"${h}"`))], [[], false], [["$.rows"], true]);
// 61 B15: missed, called back, missed again later counts 1 (by outbound calls, the latest of two, and
// by an answered inbound call)
const again = missedCallbacks([...calls,
  call("d-1", "inbound", 50 * 60, null, true, "no_available_agent", "nl", "h11"), call("d-2", "outbound", 49 * 60, null, true, null, "nl", "h11"),
  call("d-3", "inbound", 26 * 60, null, true, "no_available_agent", "nl", "h11"), call("d-4", "outbound", 25 * 60, 7, true, null, "nl", "h11"),
  call("d-5", "inbound", 50, null, true, "agents_did_not_answer", "nl", "h11"),
  call("e-1", "inbound", 27 * 60, null, true, "no_available_agent", "nl", "h12"), call("e-2", "inbound", 26 * 60, null, true, "abandoned_in_ivr", "nl", "h12"),
  call("e-3", "inbound", 25 * 60, 9, true, null, "nl", "h12"), call("e-4", "inbound", 45, null, true, "no_available_agent", "nl", "h12"),
], lines, reasons, "Europe/Amsterdam", 30, 3, NOW, business, url);
expect("times missed counts the missed calls since the latest callback",
  again.rows.filter((r) => /^[de]-/.test(r.sourceId)).map((r) => `${r.sourceId}:${r.missedCount}`), ["d-5:1", "e-4:1"], ["d-5:3", "e-4:3"]);
expect("oldest first, then by the call's id",
  sortCallbacks([{ startedAt: ago(10), sourceId: "b" }, { startedAt: ago(20), sourceId: "z" }, { startedAt: ago(10), sourceId: "a" }]).map((r) => r.sourceId),
  ["z", "a", "b"], ["a", "b", "z"]);

// ---- Outbound today (addition 0009h) --------------------------------------------------------------
// The calls of 165 B (invented ids): 6 October 2026 on the NL line (Amsterdam), five seconds of ringing, then the talk;
// a New York line whose call of 7 October 01:30 in Amsterdam is still the 6th there and whose call of 6 October 03:00
// in Amsterdam is the 5th there; a Tokyo line whose call of 5 October 23:30 in Amsterdam is already the 6th there; a line
// that does not count; the tag nr means not reached
const D = Date.parse("2026-10-06T08:00:00Z");
const oLines = [
  { connectionId: "c", lineRef: "nl", name: "NL line", market: "NL", zone: "Europe/Amsterdam", isCounted: true },
  { connectionId: "c", lineRef: "us", name: "US line", market: "US", zone: "America/New_York", isCounted: true },
  { connectionId: "c", lineRef: "jp", name: "JP line", market: "JP", zone: "Asia/Tokyo", isCounted: true },
  { connectionId: "c", lineRef: "test", name: "Test line", market: "NL", zone: "Europe/Amsterdam", isCounted: false },
];
const oCall = (sourceId, direction, startMs, talk, lineRef, tagRefs = [], ended = true) => ({
  sourceId, connectionId: "c", sourceSystem: "tel", direction, startedAt: new Date(startMs).toISOString(),
  answeredAt: talk === null ? null : new Date(startMs + 5000).toISOString(),
  endedAt: !ended ? null : new Date(startMs + (talk === null ? 20_000 : 5000 + talk * 1000)).toISOString(),
  missedReason: null, lineRef, tagRefs,
});
const min = (n) => D + n * 60_000;
const oCalls = [
  oCall("o1", "outbound", min(0), 1, "nl"), oCall("o2", "outbound", min(10), 0, "nl", [], false), oCall("o3", "outbound", min(20), 30, "nl"),
  oCall("o4", "outbound", min(30), 120, "nl", ["nr"]), oCall("o5", "outbound", min(40), null, "nl"), oCall("o6", "outbound", min(50), 300, "nl"),
  oCall("i1", "inbound", min(60), 45, "nl"), oCall("t1", "outbound", min(70), 60, "test"),
  oCall("u1", "outbound", Date.parse("2026-10-06T23:30:00Z"), 60, "us"), oCall("u2", "outbound", Date.parse("2026-10-06T01:00:00Z"), 60, "us"),
  oCall("y1", "outbound", D - 86_400_000, 60, "nl"), oCall("j1", "outbound", Date.parse("2026-10-05T21:30:00Z"), 60, "jp"),
];
const oTags = [{ connectionId: "c", tagRef: "nr", name: "Not reached", isCounted: true, meaning: "not_reached" }];
const outboundOn = (date, connectedMin = 0, conversationMin = 30) =>
  outboundToday(callRecords(oCalls, oLines, "Europe/Amsterdam", callRules(connectedMin, conversationMin, oTags)), date);
const out6 = outboundOn("2026-10-06");
expect("outbound today: attempts, connected, rate, outbound conversations, talk and its average",
  out6, { date: "2026-10-06", attempts: 8, connected: 7, connectedRate: 87.5, conversations: 4, talkSeconds: 571, talkAvgSeconds: 95.2 },
  { date: "2026-10-06", attempts: 7, connected: 6, connectedRate: 85.7, conversations: 3, talkSeconds: 511, talkAvgSeconds: 102.2 });
expect("the outbound tiles in order with their values",
  OUTBOUND_TILES.map((k) => [k, outboundTileValue(out6, k)]),
  [["attempts", { kind: "count", value: 8 }], ["connected", { kind: "count", value: 7 }], ["connectedRate", { kind: "rate", value: 87.5 }],
    ["conversations", { kind: "count", value: 4 }], ["talk", { kind: "talk", value: 571 }], ["talkAvg", { kind: "talk", value: 95.2 }]],
  [["attempts", { kind: "count", value: 8 }], ["connected", { kind: "count", value: 7 }], ["connectedRate", { kind: "pct", value: 88 }],
    ["conversations", { kind: "count", value: 4 }], ["talk", { kind: "talk", value: 571 }], ["talkAvg", { kind: "talk", value: 95.2 }]]);
expect("the settings move the figures: connected from 5 s; a conversation from 31 s",
  [outboundOn("2026-10-06", 5), outboundOn("2026-10-06", 0, 31).conversations],
  [{ date: "2026-10-06", attempts: 8, connected: 5, connectedRate: 62.5, conversations: 4, talkSeconds: 570, talkAvgSeconds: 114 }, 3],
  [{ date: "2026-10-06", attempts: 8, connected: 7, connectedRate: 87.5, conversations: 4, talkSeconds: 571, talkAvgSeconds: 95.2 }, 4]);
expect("each call on its day in its line's zone: the 5th counts its two calls",
  outboundOn("2026-10-05"), { date: "2026-10-05", attempts: 2, connected: 2, connectedRate: 100, conversations: 2, talkSeconds: 120, talkAvgSeconds: 60 },
  { date: "2026-10-05", attempts: 1, connected: 1, connectedRate: 100, conversations: 1, talkSeconds: 60, talkAvgSeconds: 60 });
const none = outboundOn("2026-10-01");
expect("a day without an attempt: zeros, no rate, no average",
  none, { date: "2026-10-01", attempts: 0, connected: 0, connectedRate: null, conversations: 0, talkSeconds: 0, talkAvgSeconds: null },
  { date: "2026-10-01", attempts: 0, connected: 0, connectedRate: 0, conversations: 0, talkSeconds: 0, talkAvgSeconds: 0 });
expect("the connected rate with one decimal, a dash without an attempt; the average's dash",
  [fmtRate1(out6.connectedRate, "en"), fmtRate1(57.1, "nl"), fmtRate1(100, "en"), fmtRate1(none.connectedRate, "en"), fmtTalk(none.talkAvgSeconds, "en"), fmtTalk(none.talkSeconds, "en")],
  ["87.5%", "57,1%", "100.0%", "–", "–", "0 s"], ["88%", "57%", "100%", "0%", "0 s", "–"]);
// ---- Inbound today's Talk time (addition 0009j) ----------------------------------------------------
// The calls of 169 B (invented ids), on 10 November 2026 around the tenant's midnight (Europe/Amsterdam, 23:00 UTC the
// day before): two ended NL calls (45 and 100 s), one answered and in progress, one unanswered; the New York line's
// answered call 5 seconds after the tenant's midnight (18:00 the day before there); the Tokyo line's call 10 seconds
// before it (07:59:50 on the date there); a connected outbound call (30 s), an outbound one not connected; the day before
const MIDNIGHT = Date.parse("2026-11-09T23:00:00Z");
const sec = (n) => MIDNIGHT + n * 1000;
const tCalls = [
  oCall("i1", "inbound", sec(1), 45, "nl"), oCall("i2", "inbound", sec(2), 100, "nl"), oCall("i3", "inbound", sec(3), 0, "nl", [], false),
  oCall("i4", "inbound", sec(4), null, "nl"), oCall("u1", "inbound", sec(5), 60, "us"), oCall("j1", "inbound", sec(-10), 70, "jp"),
  oCall("o1", "outbound", sec(6), 30, "nl"), oCall("o2", "outbound", sec(7), null, "nl"), oCall("y1", "inbound", sec(-23 * 3600), 50, "nl"),
];
const tRecords = (connectedMin) => callRecords(tCalls, oLines, "Europe/Amsterdam", callRules(connectedMin, 30, oTags));
const reportDiff = (connectedMin, date) => {
  const f = callsFigures(tRecords(connectedMin).filter((c) => c.date === date));
  return f.talkSeconds - f.outboundTalkSeconds;
};
// the tenant's day (Martin, 10 November 2026): the row's own calls, as the other inbound figures
const DAY_MS = 86_400_000;
const talkOn = (fromMs) => inboundTalkToday(tCalls, oLines, fromMs, fromMs + DAY_MS);
expect("inbound talk today over the tenant's day: the ended NL calls and the New York call, not the Tokyo call (the day before in the tenant's zone)",
  [talkOn(MIDNIGHT), talkOn(MIDNIGHT - DAY_MS)], [205, 120], [215, 110]);
expect("it is Reports → Calls' talk time minus its outbound talk time but for the calls on another day in their line's zone (+60 New York, −70 Tokyo); above the Connected threshold the report's difference holds more",
  [reportDiff(0, "2026-11-10"), talkOn(MIDNIGHT) === reportDiff(0, "2026-11-10") + 60 - 70, reportDiff(40, "2026-11-10")], [215, true, 245], [205, false, 215]);
// Waiting now is gone everywhere the web held its keys: the copy's (inboundWaitingNow, liveWaitingNow, en and nl), the
// registry's and the catalog's (live.inbound.waiting_now), the field, the tile, the mock and the database mapping (no
// waiting_now read). Email's own "Waiting now" (email.waitingTitle) is another figure and stays
const keysGone = [
  ["src/lib/copy.ts", /inboundWaitingNow|liveWaitingNow/], ["src/lib/metrics.ts", /live\.inbound\.waiting_now/],
  ["src/lib/metrics-catalog.json", /"live\.inbound\.waiting_now"/], ["src/lib/data/types.ts", /waitingNow/],
  ["src/components/InboundLive.tsx", /waitingNow|WaitingNow/], ["src/lib/live.ts", /waitingNow/], ["src/lib/data/mock.ts", /waitingNow/],
  ["src/lib/data/postgres.ts", /\.waiting_now\b|waiting_now:|\.longest_waiting_seconds\b/],
].filter(([f, re]) => re.test(readFileSync(new URL(`../${f}`, import.meta.url), "utf8"))).map(([f]) => f);
expect("no Waiting now in the copy, the registry, the catalog, the types, the component, the tiles, the mock or the mapping", keysGone, [],
  ["src/lib/copy.ts"]);
expect("email's Waiting now stays (another figure)", /waitingTitle: "Waiting now"/.test(readFileSync(new URL("../src/lib/copy.ts", import.meta.url), "utf8")), true, false);

// ---- Inbound today by hour, the board's freshness and its words (the Live board's UX and speed pass) ----------------
const hourRows = [
  { groupKey: "09", offered: 5, answered: 3, unanswered: 2, waiting: 0, serviceLevelPct: 60 },
  { groupKey: "14", offered: 2, answered: 1, unanswered: 0, waiting: 1, serviceLevelPct: 100 },
  { groupKey: null, offered: 7, answered: 4, unanswered: 2, waiting: 1, serviceLevelPct: 66.7 },   // the total row
  { groupKey: "7", offered: 9, answered: 9, unanswered: 0, waiting: 0, serviceLevelPct: 100 },     // no hour key
];
const hrs = inboundHours(hourRows);
expect("inbound today by hour: 24 columns 00 to 23, the hours with calls in place, the total row and a bad key left out",
  [hrs.length, hrs[0].hour, hrs[23].hour, hrs[9].offered, hrs[9].unanswered, hrs[14].waiting, hrs[7].offered, hrs.reduce((n, h) => n + h.offered, 0)],
  [24, 0, 23, 5, 2, 1, 0, 7], [24, 0, 23, 5, 2, 1, 9, 23]);
expect("the axis' top: a clean whole step at or above the tallest column, at least 4",
  [0, 3, 5, 7, 11, 23, 26, 51, 120].map(niceCeiling), [4, 4, 5, 8, 15, 25, 30, 60, 150], [1, 3, 5, 7, 11, 23, 26, 51, 120]);
expect("the board says its figures are old after two failed polls in a row, never after one; a poll gives up before the next is due",
  [isStale(0), isStale(1), isStale(LIVE_STALE_AFTER_FAILURES), isStale(5), LIVE_POLL_TIMEOUT_MS < 10_000],
  [false, false, true, true, true], [false, true, true, true, true]);
expect("the hours are read when never read or a minute old; a tab back within the minute waits",
  [hoursDue(0, 5_000), hoursDue(1_000, 1_000 + LIVE_HOURS_MS - 1), hoursDue(1_000, 1_000 + LIVE_HOURS_MS), LIVE_HOURS_MS],
  [true, false, true, 60_000], [true, true, true, 60_000]);
const words = liveBoardWords(copy.en);
const wordsNl = liveBoardWords(copy.nl);
const hintKeys = Object.keys(words.hints).sort();
expect("the board's words: exactly its hints and follow-up words, every one in English and Dutch",
  [hintKeys.join(",") === [...LIVE_HINT_KEYS].sort().join(","), Object.keys(words.followUp).length === LIVE_FOLLOW_UP_KEYS.length,
    [...LIVE_HINT_KEYS].every((k) => typeof words.hints[k] === "string" && words.hints[k] !== "" && typeof wordsNl.hints[k] === "string" && wordsNl.hints[k] !== ""),
    LIVE_FOLLOW_UP_KEYS.every((k) => typeof wordsNl.followUp[k] === "string" && wordsNl.followUp[k] !== "")],
  [true, true, true, true], [false, true, true, true]);
const sliceKb = gzipSync(JSON.stringify(words.hints)).length / 1024;
const wholeKb = gzipSync(JSON.stringify(copy.en.hints)).length / 1024;
expect("the board's hints are a small part of the whole hints object (gzip, in the page's payload)",
  sliceKb < wholeKb / 4, true, false);
// The missed callers' first page: the component shows MISSED_SHOWN before "Show all"
const inboundLive = readFileSync(new URL("../src/components/InboundLive.tsx", import.meta.url), "utf8");
expect("the missed callers show the oldest 20 first, the rest on request",
  [/export const MISSED_SHOWN = 20;/.test(inboundLive), /inbound\.callbacks\.slice\(0, MISSED_SHOWN\)/.test(inboundLive), /data-testid="missed-more"/.test(inboundLive)],
  [true, true, true], [false, true, true]);

// Longest waiting is gone everywhere the web holds its keys: the copy's (inboundLongestWaiting, liveLongestWaiting and
// nobodyWaiting, en and nl), the registry's and the catalog's (live.inbound.longest_waiting), the field and the tile
const gone = ["src/lib/copy.ts", "src/lib/metrics.ts", "src/lib/metrics-catalog.json", "src/lib/data/types.ts", "src/components/InboundLive.tsx"]
  .filter((f) => /longestWaiting|LongestWaiting|longest_waiting|nobodyWaiting/.test(readFileSync(new URL(`../${f}`, import.meta.url), "utf8")));
expect("no Longest waiting in the copy, the registry, the catalog, the types or the component", gone, [], ["src/lib/copy.ts"]);

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
