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

// ---- the head start of the page's reads (12 November 2026): lib/head-start -------------------------------------------
const { headStart, deadlineIn, DASHBOARD_HEAD_MS, DASHBOARD_PARTS } = await import("../src/lib/head-start.ts");
const after = (ms, v) => new Promise((r) => setTimeout(() => r(v), ms));
const failing = (ms) => new Promise((_, no) => setTimeout(() => no(new Error("refused")), ms));
let unhandled = 0;
process.on("unhandledRejection", () => { unhandled += 1; });
{
  const deadline = deadlineIn(40);
  const [early, lateRead, now] = await Promise.all([headStart(after(5, "time"), deadline), headStart(after(90, "speed"), deadline), headStart(Promise.resolve("counts"), deadline)]);
  expect("a read in by the deadline is drawn with the page, one still on its way is handed on",
    [early.ready, early.ready ? early.value : null, now.ready ? now.value : null, lateRead.ready, lateRead.ready ? null : await lateRead.read],
    [true, "time", "counts", false, "speed"], [false, null, null, true, null]);
  const t0 = performance.now();
  const whole = await Promise.all([headStart(after(5, 1), deadlineIn(500)), headStart(after(10, 2), deadlineIn(500))]);
  expect("the page does not wait for the deadline when every read is in", [whole.every((h) => h.ready), performance.now() - t0 < 200], [true, true], [false, false]);
  const refusedEarly = await headStart(failing(5), deadlineIn(40)).then(() => "answered", (e) => e.message);
  const lateFail = await headStart(failing(60), deadlineIn(20));
  const refusedLate = lateFail.ready ? "ready" : await lateFail.read.then(() => "answered", (e) => e.message);
  // one more read that fails after the deadline and is never awaited: it must not count as an unhandled failure
  await headStart(failing(40), deadlineIn(10));
  await after(80);
  expect("a read that fails before the deadline fails the page, one that fails later fails where it is awaited, none goes unhandled",
    [refusedEarly, lateFail.ready, refusedLate, unhandled], ["refused", false, "refused", 0], ["answered", true, "ready", 1]);
}
const { blankNumbers } = await import("../src/lib/head-start.ts");
expect("a hint's numbers on their way are blanks of a number's width, its words stay",
  [blankNumbers("{pct} within target · {open} open"), blankNumbers("Working statuses"), blankNumbers("{time} of worked time")[0]],
  [[{ text: "00%", blank: true }, { text: " within target · ", blank: false }, { text: "00", blank: true }, { text: " open", blank: false }],
    [{ text: "Working statuses", blank: false }], { text: "00h 00m", blank: true }],
  [[], [], null]);
const src = (rel) => readFileSync(new URL(`../src/${rel}`, import.meta.url), "utf8");
const pageSrc = src("app/reports/dashboard/page.tsx");
const rowSrc = src("components/IntakeRow.tsx");
expect("the page starts its parts' reads at once, as a streamed part, before it waits for any; the parts are the time, the counts and the speed",
  [/const reads = streamed\(\(\) => data\(\)\.getDashboardReads\(me, period\)\);\s*const timeRead = held\("time", reads\.time\);\s*const countsRead = held\("counts", reads\.counts\);\s*const speedRead = held\("speed", reads\.speed\);\s*const \[time, counts, speed\] = await Promise\.all\(/.test(pageSrc),
    [...DASHBOARD_PARTS], DASHBOARD_HEAD_MS, /<ReadsTrace reads=\{\[timeRead, countsRead, speedRead\]\} \/>/.test(pageSrc),
    /const deadline = deadlineIn\(DASHBOARD_HEAD_MS\);/.test(pageSrc)],
  [true, ["time", "counts", "speed"], 300, true, true], [false, [], 0, false, false]);
expect("parts are held back for the test data only; every part's boundary is keyed on the period",
  [/const late = dataIsMock && typeof sp\.late === "string" \? sp\.late\.split\(","\) : \[\];/.test(pageSrc), /const k = `\$\{period\.from\}\|\$\{period\.to\}`;/.test(pageSrc),
    /<Part head=\{time\} k=\{`time\|\$\{k\}`\}/.test(pageSrc), (rowSrc.match(/<Part head=\{counts\} k=\{`(counts-a|counts-b|note)\|\$\{k\}`\}/g) ?? []).length,
    /<Part head=\{speed\} k=\{`speed\|\$\{k\}`\}/.test(rowSrc)],
  [true, true, true, 3, true], [false, false, false, 0, false]);
const pgSrc = src("lib/data/postgres.ts");
expect("two connections: the time handed over before the counts in one transaction; the speed beside them, after the database is asked for performance.team",
  [/counts = withTenant\(ctx\(me\), async \(q\) => \{\s*timeOk\(await readTeamStatusTime\(q, range, null\)\);\s*return \{ intake: await readIntake\(q, range\)/.test(pgSrc),
    /speed = withTenant\(ctx\(me\), async \(q\) => \{\s*await q\.query\(`select cma\.assert_permission\('performance\.team'\)`\);\s*return readSpeedToLeadRows\(q, range, false\);/.test(pgSrc),
    /infoWaits=\{\/\\\{\[a-z\]\+\\\}\/\.test\(text\.replaceAll\("\{hours\}", ""\)\)\}/.test(rowSrc), /className="absolute left-0 top-full mt-2 text-caption text-p4a-grey" data-testid="intake-start-note"/.test(rowSrc)],
  [true, true, true, true], [false, false, false, false]);
expect("a tile that waits keeps its label and its hint's words; the speed tile reads no record link; a click on a period or a person shows a mark",
  [/value=\{<TileWait \/>\} hint=\{hint\} waiting \/>;/.test(rowSrc),
    /: `select r\.\*, null::text as record_url from cma\.speed_to_lead_rows\(\$1::date, \$2::date\) r`/.test(src("lib/data/postgres.ts")),
    /<LinkPending \/>\s*<\/Link>/.test(src("components/PeriodBar.tsx")), /useLinkStatus\(\)/.test(src("components/PendingMark.tsx")),
    /startTransition\(\(\) => \{ router\.push\(/.test(src("components/DashboardFilter.tsx")), /aria-busy=\{pending \|\| undefined\}/.test(src("components/DashboardFilter.tsx"))],
  [true, true, true, true, true, true], [false, false, false, false, false, false]);

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
