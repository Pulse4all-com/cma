/**
 * Verifier: the roster's logic (src/lib/roster.ts), without a browser or a database.
 *
 *   node --experimental-strip-types verify/roster.mjs             every check must PASS
 *   node --experimental-strip-types verify/roster.mjs --provoke   every check must FAIL
 *
 * Covers the quick-typing parser (shifts in the many ways people type times, absences by key, name
 * or unambiguous start, empty clears, the midnight rule), the cell labels, the week's days across a
 * month end, planned minutes and headcount, the coverage states and grid, and the adherence flags
 * from a planned shift against the actual clock in a zone, around the autumn clock change too; since
 * 16 October 2026 (backlog CMA-061) the week's one-range label in both locales and the absence keywords
 * built from the tenant's types; since 17 November 2026 (brief B39, addition 0009y) who is on the roster: the planner's list
 * and the Live board's flags hold only people with their time kept and roster.planned, roles combined; since 19 November
 * 2026 (brief B41) the planner's one team per page view: Everyone without a ?team= or with one that names no current
 * team, and the select, the header, the reads, print, copy, publish and the address all on that one key; since 25 November
 * 2026 (brief A, addition 0009zx) the assignments: the CODE-MARKET parser with the UK alias, painting and emptying over a
 * selection inside the shift, joined bars, the colours from what a type books, the planner zone, the planned figures per
 * slot and per person on 249's B10 fixture, and the plan check. Copy week, Apply and Save as standard week write the team
 * as the other writes do (four writes on the page's key).
 */
import { readFileSync } from "node:fs";
import {
  absenceKeywordList, adherence, cellLabel, coverageGrid, coverageState, EVERYONE, headcountByDate, isoWeek, onRoster, parseCell, plannedInstant, plannedMinutesByUser,
  plannerNeedsTeams, plannerSearch, plannerTeam, plannerTeamOfHeader, rosterTeamArg, shiftMinutes, weekDays,
} from "../src/lib/roster.ts";
import { fmtDateRange } from "../src/lib/time.ts";
import {
  assignmentText, fromPlannerMinutes, joinBlocks, paintBlocks, parseAssignment, planCheck, plannedByKey, plannedMinutes, plannedSummary, pickerFilter,
  pickerOrder, slotFigures, toneOf, toPlannerMinutes,
} from "../src/lib/assignments.ts";

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

// ---- the week's label and the absences a cell takes (16 October 2026, backlog CMA-061) -----------------
// ICU writes the range's dash with thin spaces (U+2009) when the two sides differ in more than the day;
// since ICU 78 (CLDR 48; Node.js 22.23.4, the pinned image since 4 November 2026) English writes them within one
// month too (12 – 18 October 2026), Dutch does not (12–18 oktober 2026): the locale's own shape, not the CMA's
const dash = "\u2009\u2013\u2009";
const sameMonthDashEn = Number(process.versions.icu.split(".")[0]) >= 78 ? dash : "\u2013";
expect("a week inside one month is one range", fmtDateRange("2026-10-12", "2026-10-18", "en"), `12${sameMonthDashEn}18 October 2026`, "12 - 18 October 2026");
expect("a week across two months names both", fmtDateRange("2026-09-28", "2026-10-04", "en"), `28 September${dash}4 October 2026`, `28 September${dash}4 October`);
expect("a week across the year end names both years", fmtDateRange("2026-12-28", "2027-01-03", "en"), `28 December 2026${dash}3 January 2027`, `28 December${dash}3 January 2027`);
expect("the same in Dutch", [fmtDateRange("2026-10-12", "2026-10-18", "nl"), fmtDateRange("2026-09-28", "2026-10-04", "nl")],
  ["12\u201318 oktober 2026", `28 september${dash}4 oktober 2026`], ["12-18 oktober 2026", "28 september - 4 oktober 2026"]);
expect("the absences a cell takes, by name, the key where it differs", absenceKeywordList(absences),
  "Day off (off), Leave, Sick, Public holiday (public_holiday), Other", "off, leave, sick, public_holiday, other");

// ---- on the roster: the planner's list (17 November 2026, brief B39, addition 0009y) ------------------------------------
// The default ladder as db/198 seeds it, abridged (the keys onRoster reads are complete); a person's permissions are
// those of all their roles together
const LADDER = {
  agent: ["workday.own", "roster.view", "leads.accept", "performance.own", "roster.planned"],
  supervisor: ["workday.own", "roster.view", "leads.accept", "performance.own", "workday.team", "performance.team", "monitoring.live", "messages.send", "roster.planned"],
  manager: ["workday.own", "roster.view", "workday.team", "monitoring.live", "roster.manage", "users.manage_agents", "workday.export", "roster.planned"],
  admin: ["workday.own", "roster.view", "workday.team", "monitoring.live", "roster.manage", "users.manage_all", "tenant.configure", "messages.withdraw"],
  analytics: ["reports.view", "performance.team", "monitoring.live", "quality.manage"],
  clock: ["workday.own"],
};
const person = (name, roles, isActive = true) => ({ name, isActive, permissions: [...new Set(roles.flatMap((r) => LADDER[r]))] });
const people = [
  person("agent", ["agent"]), person("supervisor", ["supervisor"]), person("manager", ["manager"]),
  person("admin only", ["admin"]), person("analytics only", ["analytics"]), person("admin and agent", ["admin", "agent"]),
  person("own role, clock only", ["clock"]), person("inactive agent", ["agent"], false),
];
expect("the planner lists agent, supervisor, manager and admin+agent, never admin or analytics alone",
  people.filter(onRoster).map((p) => p.name), ["agent", "supervisor", "manager", "admin and agent"],
  ["agent", "supervisor", "manager", "admin only", "admin and agent"]);
expect("a tenant's role with the clock but without roster.planned keeps the clock, not the roster",
  [people[6].permissions.includes("workday.own"), onRoster(people[6])], [true, false], [true, true]);
expect("roster.planned without the clock is not enough", onRoster({ isActive: true, permissions: ["roster.planned"] }), false, true);
expect("an inactive person is never on the roster", onRoster(people[7]), false, true);

// ---- one team per page view (19 November 2026, brief B41, D1 and D2) ------------------------------------------------
// Prod's mix: the rail's /roster/planner read Team EN's draft (the tenant's first team) while the select and the coverage
// said Everyone. The page resolves the team once; the select, the header and both reads take that one key
const TEAMS = [{ key: "en" }, { key: "nl" }];
expect("(a) no ?team= opens Everyone, not the tenant's first team", [plannerTeam(undefined, TEAMS), plannerTeam(null, TEAMS), plannerTeam(["nl", "en"], TEAMS)],
  [EVERYONE, EVERYONE, EVERYONE], ["en", "en", "nl"]);
expect("(b) a key that names no current team opens Everyone", [plannerTeam("ghost", TEAMS), plannerTeam("", TEAMS), plannerTeam("en", [])], [EVERYONE, EVERYONE, EVERYONE],
  ["ghost", "", "en"]);
expect("Everyone and a current team are kept as asked", [plannerTeam("all", TEAMS), plannerTeam("nl", TEAMS)], ["all", "nl"], ["en", "en"]);
expect("only a value that names a team needs the team list; Everyone resolves without it",
  [undefined, "all", "nl", "ghost"].map(plannerNeedsTeams), [false, false, true, true], [true, true, true, true]);
expect("without the team list a missing value and Everyone still resolve to Everyone", [plannerTeam(undefined, []), plannerTeam("all", [])], [EVERYONE, EVERYONE], ["en", "en"]);
// (c) What each part of the page is given for one query: the select shows the resolved key, getRosterWeek and
// listRosterWeeks read rosterTeamArg of it, and the header the database answers for that read (a roster's team_id,
// null for the whole tenant) reads back as the same key; the browser's header is verify:layout's block 3b
const view = (param) => {
  const team = plannerTeam(param, plannerNeedsTeams(param) ? TEAMS : []);
  const read = rosterTeamArg(team);
  return { select: team, week: read, weeks: read, header: plannerTeamOfHeader({ teamKey: read }), print: plannerTeam(team, TEAMS), address: new URLSearchParams(plannerSearch("", team)).get("team") };
};
const agree = (v) => v.select === v.header && v.select === v.print && v.select === v.address && v.week === v.weeks && v.week === rosterTeamArg(v.select);
expect("(c) Everyone: the select, the header, both reads, print and the address on one key", view("all"),
  { select: "all", week: null, weeks: null, header: "all", print: "all", address: "all" }, { select: "all", week: "en", weeks: "en", header: "en", print: "en", address: "all" });
expect("(c) a team: the select, the header, both reads, print and the address on one key", view("nl"),
  { select: "nl", week: "nl", weeks: "nl", header: "nl", print: "nl", address: "nl" }, { select: "nl", week: "nl", weeks: "en", header: "nl", print: "nl", address: "nl" });
expect("(c) no ?team=: the select, the header, both reads, print and the address on Everyone", view(undefined),
  { select: "all", week: null, weeks: null, header: "all", print: "all", address: "all" }, { select: "all", week: "en", weeks: "en", header: "en", print: "en", address: "en" });
expect("(c) every part agrees for all, a team, a missing and an unknown key", ["all", "nl", undefined, "ghost"].map((x) => agree(view(x))), [true, true, true, true], [false, true, false, true]);
expect("the address gains the team and keeps the week; a stale team is replaced",
  [plannerSearch("", "all"), plannerSearch("?week=2026-11-16", "all"), plannerSearch("?team=ghost&week=2026-11-16", "all")],
  ["?team=all", "?week=2026-11-16&team=all", "?team=all&week=2026-11-16"], ["", "?week=2026-11-16", "?team=ghost&week=2026-11-16"]);

// (c) in the code that renders it: the page resolves once and hands that key to both reads and the planner (keyed by
// week and team, so another team is never the previous grid under new props); the planner's select, links, print,
// writes and address take the same key; the print view resolves the same way
const src = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
const page = src("../src/app/(shell)/roster/planner/page.tsx");
const planner = src("../src/components/RosterPlanner.tsx");
const print = src("../src/app/roster/planner/print/page.tsx");
expect("(c) the page: one resolved key for both reads and the planner, no first team",
  [/const team = plannerTeam\(sp\.team, plannerNeedsTeams\(sp\.team\) \? await teamsRead : \[\]\);/.test(page), /const read = rosterTeamArg\(team\);/.test(page), /getRosterWeek\(me, weekStart, read\)/.test(page),
    /listRosterWeeks\(me, read, /.test(page), /key=\{`\$\{weekStart\}:\$\{team\}`\}/.test(page), /\bteam=\{team\}/.test(page), !/teams\[0\]/.test(page)],
  [true, true, true, true, true, true, true], [false, false, false, false, false, false, false]);
expect("(c) the planner: select, week links, print, copy, publish, cells and the address on the page's key",
  [/usePendingChoice\(team\)/.test(planner), /value=\{shownTeam\}/.test(planner), /const keep = \{ team \};/.test(planner), /const teamArg = rosterTeamArg\(team\);/.test(planner),
    (planner.match(/\{ team: teamArg[ ,]/g) ?? []).length, /print\?week=\$\{weekStart\}&team=\$\{encodeURIComponent\(team\)\}/.test(planner),
    /window\.history\.replaceState\(null, "", plannerSearch\(window\.location\.search, team\)\)/.test(planner), /if \(answer !== week\) \{/.test(planner),
    /data-team=\{plannerTeamOfHeader\(header\)\}/.test(planner)],
  [true, true, true, true, 4, true, true, true, true], [false, false, false, false, 0, false, false, false, false]);
expect("(c) the print view resolves the team as the planner does, the team list only for a named team",
  [/getRosterWeek\(me, weekStart, rosterTeamArg\(plannerTeam\(sp\.team, teams\)\)\)/.test(print), /const teams = plannerNeedsTeams\(sp\.team\) \? await data\(\)\.listTeams\(me\) : \[\];/.test(print)],
  [true, true], [false, false]);

// ---- assignments (addition 0009zx, brief A) -------------------------------------------------------
const types = [
  { code: "SL", name: "Sales", kind: "work", workArea: "sales", isExtra: false, statusIsProductive: true, isActive: true },
  { code: "GO", name: "General Ops", kind: "work", workArea: "operations", isExtra: false, statusIsProductive: true, isActive: true },
  { code: "TR", name: "Training", kind: "work", workArea: null, isExtra: false, statusIsProductive: false, isActive: true },
  { code: "LB", name: "Lunch break", kind: "pause", workArea: null, isExtra: false, statusIsProductive: false, isActive: true },
  { code: "X", name: "Extra hours", kind: "work", workArea: null, isExtra: true, statusIsProductive: null, isActive: true },
  { code: "OLD", name: "Retired", kind: "work", workArea: "operations", isExtra: false, statusIsProductive: true, isActive: false },
];
const markets = [{ code: "GB", isActive: true }, { code: "NL", isActive: true }, { code: "SE", isActive: false }];
expect("D5: a code, a code and a market, any case, an en dash too",
  [parseAssignment("sl", types, markets), parseAssignment("SL-GB", types, markets), parseAssignment(" go – nl ", types, markets), parseAssignment("x", types, markets)],
  [{ code: "SL", market: null }, { code: "SL", market: "GB" }, { code: "GO", market: "NL" }, { code: "X", market: null }],
  [{ code: "SL", market: null }, { code: "SL", market: "UK" }, { code: "GO", market: "NL" }, { code: "X", market: null }]);
expect("D5: UK is read as GB and always shown as GB", [parseAssignment("SL-UK", types, markets), assignmentText({ code: "SL", market: "GB" })],
  [{ code: "SL", market: "GB" }, "SL-GB"], [{ code: "SL", market: "UK" }, "SL-UK"]);
expect("refusals: unknown code, retired type, no or an inactive hours market, a bad shape, nothing typed",
  [parseAssignment("ZZ", types, markets), parseAssignment("OLD", types, markets), parseAssignment("SL-BE", types, markets), parseAssignment("SL-SE", types, markets),
    parseAssignment("SL-GB-X", types, markets), parseAssignment("  ", types, markets)].map((x) => x.problem),
  ["unknown", "retired", "market", "market", "format", "empty"], ["unknown", "retired", "market", "market", "format", null]);
const shift9to17 = { start: 540, end: 1020 };
const painted = paintBlocks([], 540, 660, { code: "SL", market: "GB" }, shift9to17);
const over = paintBlocks(painted, 600, 630, { code: "LB", market: null }, shift9to17);
expect("painting cuts a block in two around a new one, keeps the order",
  over.map((b) => `${b.code}${b.market ? "-" + b.market : ""} ${b.start}-${b.end}`), ["SL-GB 540-600", "LB 600-630", "SL-GB 630-660"], ["SL-GB 540-660", "LB 600-630"]);
expect("Delete empties a selection; painting the same type back joins the bar again",
  [paintBlocks(over, 600, 630, null, shift9to17).length, paintBlocks(over, 600, 630, { code: "SL", market: "GB" }, shift9to17).map((b) => `${b.start}-${b.end}`)],
  [2, ["540-660"]], [3, ["540-600", "600-630", "630-660"]]);
expect("a selection beyond the shift is clipped to it; wholly outside paints nothing",
  [paintBlocks([], 480, 600, { code: "GO", market: null }, shift9to17).map((b) => `${b.start}-${b.end}`), paintBlocks([], 1020, 1080, { code: "GO", market: null }, shift9to17).length],
  [["540-600"], 0], [["480-600"], 1]);
expect("joined bars: neighbours of one code and market, never across a market or a note",
  joinBlocks([{ code: "SL", start: 540, end: 600, market: null, note: null }, { code: "SL", start: 600, end: 660, market: null, note: null },
    { code: "SL", start: 660, end: 720, market: "GB", note: null }, { code: "SL", start: 720, end: 780, market: "GB", note: "desk" }]).length, 3, 1);
expect("D13: the colour follows what a type books", types.map(toneOf), ["sales", "operations", "otherWork", "pause", "extra", "operations"],
  ["sales", "sales", "otherWork", "pause", "extra", "operations"]);
expect("the planner zone: one hour ahead in winter and summer, equal zones untouched, back again",
  [toPlannerMinutes("2026-12-07", "09:00", "Europe/London", "Europe/Madrid"), toPlannerMinutes("2026-07-06", "09:00", "Europe/London", "Europe/Madrid"),
    toPlannerMinutes("2026-12-07", "09:00", "Europe/Madrid", "Europe/Madrid"), fromPlannerMinutes(600, "2026-12-07", "Europe/London", "Europe/Madrid"),
    fromPlannerMinutes(1500, "2026-12-07", "Europe/London", "Europe/Madrid")],
  [600, 600, 540, "09:00", "24:00"], [540, 540, 540, "10:00", null]);
// 249's B10: a2 GO 08-12 (no Default market), LB 12-13, SL 13-16 under GB; a1 (Default NL) SL 09-13, X 13-14, SL 14-17 GB; one
// hour ahead on the planner's axis
const kinds = new Map(types.map((x) => [x.code, x.kind]));
const h = (x) => x * 60 + 60;
const fixture = [
  { userId: "a2", defaultMarket: null, blocks: [{ code: "GO", start: h(8), end: h(12), market: null, note: null }, { code: "LB", start: h(12), end: h(13), market: null, note: null }, { code: "SL", start: h(13), end: h(16), market: "GB", note: null }] },
  { userId: "a1", defaultMarket: "NL", blocks: [{ code: "SL", start: h(9), end: h(13), market: null, note: null }, { code: "X", start: h(13), end: h(14), market: null, note: null }, { code: "SL", start: h(14), end: h(17), market: "GB", note: null }] },
];
const figs = slotFigures(fixture, kinds, 15, h(8), h(17));
const slotAt = (hhmm) => { const f = figs.find((x) => x.start === Number(hhmm.slice(0, 2)) * 60 + Number(hhmm.slice(3))); return `w${f.working} ${[...f.byKey].sort().map(([k, n]) => `${k}=${n}`).join(" ")}`; };
expect("D12 per slot as 249's B10 counts it (the planner's 09:00, 10:00, 13:00, 14:00, 17:45)",
  [figs.length, slotAt("09:00"), slotAt("10:00"), slotAt("13:00"), slotAt("14:00"), slotAt("17:45")],
  [36, "w1 GO/=1", "w2 GO/=1 SL/NL=1", "w1 LB/=1 SL/NL=1", "w2 SL/GB=1 X/NL=1", "w1 SL/GB=1"],
  [36, "w1 GO/=1", "w2 GO/=1 SL/NL=1", "w2 LB/=1 SL/NL=1", "w2 SL/GB=1 X/NL=1", "w1 SL/GB=1"]);
expect("D12 per person as 249's B10's planned minutes",
  fixture.map((p) => [...plannedByKey(p.blocks, p.defaultMarket, kinds)].sort().map(([k, v]) => `${k}=${v}`).join(" ")),
  ["GO/=240 LB/=60 SL/GB=180", "SL/GB=180 SL/NL=240 X/NL=60"], ["GO/=240 LB/=60 SL/GB=180", "SL/GB=180 SL/NL=300"]);

// ---- the follow-up of 26 November 2026 (Martin's hand check in dev, addition 0009zz) ---------------------------------
expect("a pause has no hours market: LB-GB is refused, LB alone is taken",
  [parseAssignment("LB-GB", types, markets), parseAssignment("lb", types, markets)],
  [{ problem: "pauseMarket" }, { code: "LB", market: null }], [{ code: "LB", market: "GB" }, { code: "LB", market: null }]);
// Agent One's day: a shift 09:00-16:00 with a 30-minute lunch, Default market NL
const agentOne = [{ code: "SL", start: 540, end: 750, market: null, note: null }, { code: "LB", start: 750, end: 780, market: "GB", note: null },
  { code: "SL", start: 780, end: 960, market: null, note: null }];
expect("a pause counts under no market, never under the Default market",
  [...plannedByKey(agentOne, "NL", kinds)].sort().map(([k, v]) => `${k}=${v}`).join(" "), "LB/=30 SL/NL=390", "LB/GB=30 SL/NL=390");
expect("Planned: the work blocks (X too), never a pause; a shift without blocks whole; no shift 0",
  [plannedMinutes({ start: 540, end: 960 }, agentOne, kinds), plannedMinutes({ start: 540, end: 960 }, [], kinds), plannedMinutes(null, agentOne, kinds),
    plannedMinutes({ start: 540, end: 1020 }, [{ code: "X", start: 540, end: 600 }, { code: "SL", start: 600, end: 660 }], kinds)],
  [390, 420, 0, 120], [420, 420, 0, 60]);
const summary = plannedSummary([
  { userId: "a1", date: "2026-11-30", defaultMarket: "NL", shift: { start: 540, end: 960 }, blocks: agentOne },
  { userId: "a2", date: "2026-11-30", defaultMarket: null, shift: { start: 480, end: 960 }, blocks: [] },
  { userId: "a3", date: "2026-11-30", defaultMarket: "GB", shift: null, blocks: [] },
], kinds);
expect("the meter: Planned = the sum of the people's Planned, against the hours on shift; split per type and market; pauses apart",
  [summary.planned, summary.onShift, [...summary.byKey].map(([k, v]) => `${k}=${v}`).join(" "), summary.dayLevel, [...summary.pauses].map(([k, v]) => `${k}=${v}`).join(" ")],
  [870, 900, "SL/NL=390", 480, "LB=30"], [900, 900, "SL/NL=390 LB/=30", 480, ""]);
expect("the Assignment dropdown: work types first, then pauses, then the extra types; the retired left out",
  pickerOrder(types.map((t, i) => ({ ...t, sortOrder: [10, 20, 30, 5, 1, 40][i] }))).map((t) => t.code), ["SL", "GO", "TR", "LB", "X"], ["X", "LB", "SL", "GO", "TR"]);
expect("typing filters the dropdown: the codes that start with the text first, then the names that hold it",
  [pickerFilter(types, "lu").map((t) => t.code), pickerFilter(types, "go-gb").map((t) => t.code), pickerFilter(types, "").length, pickerFilter(types, "l")[0]?.code],
  [["LB"], ["GO"], 6, "LB"], [["LB", "SL"], ["GO"], 6, "SL"]);
const dayView = readFileSync(new URL("../src/components/RosterDay.tsx", import.meta.url), "utf8");
const plannerView = readFileSync(new URL("../src/components/RosterPlanner.tsx", import.meta.url), "utf8");
expect("the grid keeps the focus after a click and a drag; Enter applies the assignment chosen",
  [/if \(!d \|\| d\.moved\) \{ grid\.current\?\.focus\(\); return; \}/.test(dayView), /else grid\.current\?\.focus\(\);/.test(dayView),
    /if \(e\.key === "Enter"\) \{ e\.preventDefault\(\); applyChosen\(\); return; \}/.test(dayView), /d\.moved\) \{ codeField|else codeField\.current/.test(dayView)],
  [true, true, true, false], [false, false, false, true]);
expect("Working shows 0 inside someone's shift; Publish reads Published and waits while nothing changed",
  [/f\.working > 0 \|\| inShift\.has\(f\.start\) \? f\.working : ""/.test(dayView),
    /disabled=\{pending \|\| \(header\.status === "published" && !header\.changedSincePublish\)\}/.test(plannerView)],
  [true, true], [false, false]);
const day = [{ code: "SL", start: 540, end: 720, market: null, note: null }, { code: "GO", start: 780, end: 1020, market: null, note: null }];
expect("the plan check: no lunch block in a long shift and a gap; the lunch type named or any pause; a shift without blocks unchecked",
  [planCheck(shift9to17, day, 360, "LB", kinds), planCheck(shift9to17, [...day, { code: "LB", start: 720, end: 780, market: null, note: null }], 360, "LB", kinds),
    planCheck(shift9to17, [...day, { code: "LB", start: 720, end: 750, market: null, note: null }], 360, "", kinds).map((w) => w.kind), planCheck(shift9to17, [], 360, "LB", kinds)],
  [[{ kind: "lunch" }, { kind: "gap", start: 720, end: 780 }], [], ["gap"], []],
  [[{ kind: "gap", start: 720, end: 780 }], [], [], []]);

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
