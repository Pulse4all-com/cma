/**
 * Verifier: the follow-up layer's logic (src/lib/follow-up.ts, addition 0008o), without a server or a database.
 *
 *   node --experimental-strip-types verify/follow-up.mjs             every check must PASS
 *   node --experimental-strip-types verify/follow-up.mjs --provoke   every check must FAIL
 *
 * Covers: the four settings' rules as cma.check_tenant_setting applies them (the bucket list's form and
 * order, the bounds of the three numbers), a pipeline's own response time, the filter parsed from a query and
 * written back, the market, person and state filters over a fixture, the filters' choices (unknown last, the
 * not-linked choice only when a row has no person), the summary and the per-person rows as the database
 * computes them (the not-linked row last, nobody with nothing waiting), the person's own rows, Welcome's
 * Needs attention lines with their links (the days not clocked out land on Team hours filtered to the days to
 * correct), the Live board's six tiles, the age bucket in words, the unlinked-calls setting in force per kind.
 * Since addition 0008s: the page's one read as cma.follow_up_page returns it (the lists capped at
 * follow_up.list_rows with their filtered totals, the counts before the filters, per person only for
 * performance.team), the list_rows setting's bounds, "Updated …" in words and when it turns stale.
 */
import {
  agoText, attentionLines, bucketLabel, byOwner, daysSince, DQ_UNLINKED_SKIP_DEFAULT, DQ_UNLINKED_SKIP_NONE, filterLeads, filterOptions, filterQuery,
  filterTasks, filterTickets, FOLLOW_UP_TILES, followUpPage, isStale, listRowsOf, normaliseBucketList, OWNER_NONE, ownRows, parseFollowUpFilter,
  parseFollowUpSetting, parsePipelineSla, summarise, unlinkedSkipOf,
} from "../src/lib/follow-up.ts";

const PROVOKE = process.argv.includes("--provoke");
const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(64)} got ${JSON.stringify(actual).slice(0, 70)}${pass ? "" : `, wanted ${JSON.stringify(want).slice(0, 70)}`}`);
}

// ---- the settings, as the database checks them ----------------------------------------------------------
expect("buckets: 1,2,5 is kept", normaliseBucketList("1,2,5"), "1,2,5", null);
expect("buckets: spaces are stripped, as the trigger does", normaliseBucketList("1, 2, 5"), "1,2,5", "1, 2, 5");
expect("buckets: out of order, from 0, six of them, a word, empty are refused",
  ["2,1", "0,1", "1,2,3,4,5,6", "a", "", "1,,2"].map(normaliseBucketList), [null, null, null, null, null, null], ["2,1", null, null, null, null, null]);
expect("response time: 1 and 100000 pass, 0 and 100001 do not",
  ["1", "100000", "0", "100001", "four"].map((v) => parseFollowUpSetting("tickets.sla_minutes", v)), ["1", "100000", null, null, null], ["0", "100000", null, null, null]);
expect("warning share: 1 to 100", ["1", "100", "0", "101"].map((v) => parseFollowUpSetting("tickets.sla_warning_pct", v)), ["1", "100", null, null], ["1", "100", "0", null]);
expect("list rows: 1 to 500 pass, 0, 501 and a word do not",
  ["1", "100", "500", "0", "501", "many"].map((v) => parseFollowUpSetting("follow_up.list_rows", v)), ["1", "100", "500", null, null, null], ["1", "100", "500", null, "501", null]);
expect("list rows in force: the value within 1 to 500, the default 100 when missing or ill-formed",
  [listRowsOf("25"), listRowsOf(0), listRowsOf(1000), listRowsOf(null), listRowsOf("x")], [25, 1, 500, 100, 100], [25, 0, 1000, 100, 100]);
expect("callback window: 0 to 10080", ["0", "10080", "10081", "-1"].map((v) => parseFollowUpSetting("tasks.callback_window_minutes", v)), ["0", "10080", null, null], [null, "10080", null, null]);
expect("a pipeline's response time: empty is the default, 60 is 60, 0 and a word are refused",
  ["", " 60 ", "0", "x", "100001"].map(parsePipelineSla), [null, 60, undefined, undefined, undefined], [null, 60, 0, undefined, undefined]);

// ---- the filter from a query ------------------------------------------------------------------------------
const uid = "00000000-0000-7000-8000-000000000201";
const UID_UPPER = "00000000-0000-7000-8000-00000000AbCd";
expect("filter: market, a person's id (lower-cased) and the state are read",
  parseFollowUpFilter({ market: "NL", owner: UID_UPPER, state: "attention" }), { market: "NL", owner: UID_UPPER.toLowerCase(), state: "attention" }, { market: "NL", owner: UID_UPPER, state: "attention" });
expect("filter: none for nobody linked; an ill-formed owner, market or state is no filter",
  parseFollowUpFilter(new URLSearchParams("owner=none&market=N%20L&state=everything")), { market: null, owner: OWNER_NONE, state: null }, { market: "N L", owner: OWNER_NONE, state: null });
expect("filter: written back without the empty parts", filterQuery({ market: "GB", owner: null, state: "attention" }), { market: "GB", state: "attention" }, { market: "GB", owner: "", state: "attention" });

// ---- a fixture: three people, one owner nobody maps to, rows without an owner ----------------------------
const ana = { id: "00000000-0000-7000-8000-000000000201", name: "Ana Ferrer" };
const jordi = { id: "00000000-0000-7000-8000-000000000202", name: "Jordi Puig" };
const sanne = { id: "00000000-0000-7000-8000-000000000203", name: "Sanne Visser" };
const lead = (id, owner, ref, market, pastTarget) => ({
  dealId: id, connectionId: "c", dealSourceId: id, pipelineId: "p", pipelineLabel: "Sales", ownerUserId: owner?.id ?? null, ownerName: owner?.name ?? null, ownerRef: ref,
  market, createdAt: "2026-10-15T08:00:00.000Z", waitingBusinessSeconds: pastTarget === null ? null : 3600, ageBusinessDays: pastTarget === null ? null : 1,
  bucketFrom: pastTarget === null ? null : 0, bucketTo: pastTarget === null ? null : 1, pastTarget, lastCallAt: null, lastCallDays: null, recordUrl: null,
});
const ticket = (id, owner, ref, market, state) => ({
  ticketId: id, connectionId: "c", ticketSourceId: id, pipelineId: "s", pipelineLabel: "Support", stageId: "t1", stageLabel: "New", ownerUserId: owner?.id ?? null,
  ownerName: owner?.name ?? null, ownerRef: ref, market, createdAt: "2026-10-15T08:00:00.000Z", openBusinessSeconds: 0, slaMinutes: 240, slaState: state, minutesToBreach: 0, recordUrl: null,
});
const task = (id, owner, ref, market, due) => ({
  taskId: id, connectionId: "c", taskSourceId: id, typeRef: "CALL", typeLabel: "Call", isCallback: false, priorityRef: null, statusRef: "NOT_STARTED", statusLabel: "Not started",
  ownerUserId: owner?.id ?? null, ownerName: owner?.name ?? null, ownerRef: ref, market, dueAt: null, dueState: due, recordType: null, recordSourceId: null,
  createdAt: "2026-10-15T08:00:00.000Z", recordUrl: null,
});
const leads = [lead("d1", ana, "o-1", "NL", true), lead("d2", jordi, "o-2", "GB", false), lead("d3", null, "o-9", "NL", true), lead("d4", null, null, "unknown", null)];
const tickets = [ticket("x1", ana, "o-1", "NL", "ok"), ticket("x2", ana, "o-1", "GB", "at_risk"), ticket("x3", jordi, "o-2", "NL", "breached"),
  ticket("x4", null, null, "NL", "breached"), ticket("x5", sanne, "o-3", "unknown", "no_hours")];
const tasks = [task("k1", ana, "o-1", "NL", "overdue"), task("k2", jordi, "o-2", "GB", "today"), task("k3", null, "o-9", null, "later"), task("k4", null, null, null, "none")];
const ids = (rows) => rows.map((r) => r.dealId ?? r.ticketId ?? r.taskId);

expect("filter by market: NL leads, tickets and tasks (a task without a market counts as unknown)",
  [ids(filterLeads(leads, { market: "NL", owner: null, state: null })), ids(filterTickets(tickets, { market: "NL", owner: null, state: null })),
    ids(filterTasks(tasks, { market: "unknown", owner: null, state: null }))],
  [["d1", "d3"], ["x1", "x3", "x4"], ["k3", "k4"]], [["d1"], ["x1", "x3", "x4"], ["k3", "k4"]]);
expect("filter by person: Ana's rows; none for rows whose owner maps to nobody or is empty",
  [ids(filterLeads(leads, { market: null, owner: ana.id, state: null })), ids(filterLeads(leads, { market: null, owner: OWNER_NONE, state: null })),
    ids(filterTickets(tickets, { market: null, owner: OWNER_NONE, state: null }))],
  [["d1"], ["d3", "d4"], ["x4"]], [["d1", "d3"], ["d3", "d4"], ["x4"]]);
expect("filter by state: attention keeps leads past the target, tickets at risk or breached, tasks overdue",
  [ids(filterLeads(leads, { market: null, owner: null, state: "attention" })), ids(filterTickets(tickets, { market: null, owner: null, state: "attention" })),
    ids(filterTasks(tasks, { market: null, owner: null, state: "attention" }))],
  [["d1", "d3"], ["x2", "x3", "x4"], ["k1"]], [["d1", "d3"], ["x2", "x3", "x4"], ["k1", "k2"]]);
const options = filterOptions(leads, tickets, tasks);
expect("the filters' choices: markets with unknown last, people by name, the not-linked choice",
  [options.markets, options.owners.map((o) => o.name), options.hasUnowned],
  [["GB", "NL", "unknown"], ["Ana Ferrer", "Jordi Puig", "Sanne Visser"], true], [["GB", "NL", "unknown"], ["Ana Ferrer", "Jordi Puig", "Sanne Visser"], false]);
expect("no not-linked choice while every row has a person", filterOptions([leads[0]], [tickets[0]], [tasks[0]]).hasUnowned, false, true);

// ---- the counts, as cma.follow_up_summary_of and cma.follow_up_by_owner_of compute them -----------------
expect("the summary over the fixture", summarise(leads, tickets, tasks),
  { leadsOpenNotCalled: 4, leadsPastTarget: 2, ticketsAtRisk: 1, ticketsBreached: 2, ticketsWithoutOwner: 1, tasksOverdue: 1, tasksDueToday: 1, tasksUnmappedOwner: 1 },
  { leadsOpenNotCalled: 4, leadsPastTarget: 1, ticketsAtRisk: 1, ticketsBreached: 2, ticketsWithoutOwner: 1, tasksOverdue: 1, tasksDueToday: 1, tasksUnmappedOwner: 1 });
const owners = byOwner(leads, tickets, tasks);
expect("per person: by name, the not-linked row last, nobody with nothing waiting",
  owners.map((o) => [o.displayName, o.openLeads, o.leadsPastTarget, o.openTickets, o.ticketsAtRiskOrBreached, o.tasksOverdue, o.tasksDueToday]),
  [["Ana Ferrer", 1, 1, 2, 1, 1, 0], ["Jordi Puig", 1, 0, 1, 1, 0, 1], ["Sanne Visser", 0, 0, 1, 0, 0, 0], [null, 2, 1, 1, 1, 0, 0]],
  [["Ana Ferrer", 1, 1, 2, 1, 1, 0], ["Jordi Puig", 1, 0, 1, 1, 0, 1], [null, 2, 1, 1, 1, 0, 0], ["Sanne Visser", 0, 0, 1, 0, 0, 0]]);
expect("per person: a task with no due state counted nowhere; an empty set gives no rows", [owners.length, byOwner([], [], []).length], [4, 0], [4, 1]);
expect("the person's own rows", [ids(ownRows(leads, ana.id)), ids(ownRows(tickets, ana.id)), ids(ownRows(tasks, jordi.id))], [["d1"], ["x1", "x2"], ["k2"]], [["d1"], ["x1"], ["k2"]]);

// ---- Welcome's Needs attention and the Live board's tiles ------------------------------------------------
const summary = summarise(leads, tickets, tasks);
expect("attention lines: the five in order, each with where to act",
  attentionLines(summary, 3, 2).map((l) => [l.key, l.count, l.href]),
  [["daysNotEnded", 3, "/team/hours?range=month&needs=correction"], ["leadsPastTarget", 2, "/reports/follow-up?state=attention"], ["ticketsAtRiskOrBreached", 3, "/reports/follow-up?state=attention"],
    ["tasksOverdue", 1, "/reports/follow-up?state=attention"], ["missedCallbacks", 2, "/live/board"]],
  [["daysNotEnded", 3, "/team/hours?range=month"], ["leadsPastTarget", 2, "/reports/follow-up"], ["ticketsAtRiskOrBreached", 3, "/reports/follow-up?state=attention"],
    ["tasksOverdue", 1, "/reports/follow-up?state=attention"], ["missedCallbacks", 2, "/live/board"]]);
expect("attention lines: without Team hours and without telephony, the three figures alone",
  attentionLines(summary, null, null).map((l) => l.key), ["leadsPastTarget", "ticketsAtRiskOrBreached", "tasksOverdue"], ["daysNotEnded", "leadsPastTarget", "ticketsAtRiskOrBreached", "tasksOverdue"]);
expect("the Live board's six tiles are summary figures", [FOLLOW_UP_TILES.length, FOLLOW_UP_TILES.every((k) => typeof summary[k] === "number")], [6, true], [7, true]);

// ---- the page's one read (0008s), as cma.follow_up_page returns it -------------------------------------------
const at = "2026-10-18T10:00:00.000Z";
const pageOf = (filter, rows, canByOwner) => followUpPage(leads, tickets, tasks, filter, { rows, canByOwner, computedAt: at, durationMs: 12, targetMinutes: 15, warningPct: 80 });
const all = { market: null, owner: null, state: null };
const nl = pageOf({ market: "NL", owner: null, state: null }, 1, true);
expect("page: each list the first rows after the filter, with the filtered total",
  [[nl.leads.total, ids(nl.leads.rows)], [nl.tickets.total, ids(nl.tickets.rows)], [nl.tasks.total, ids(nl.tasks.rows)]],
  [[2, ["d1"]], [3, ["x1"]], [1, ["k1"]]], [[2, ["d1", "d3"]], [3, ["x1"]], [1, ["k1"]]]);
expect("page: the summary, the choices and the counts take every row, whatever the filter",
  [JSON.stringify(nl.summary) === JSON.stringify(summarise(leads, tickets, tasks)), nl.options.markets, nl.counts],
  [true, ["GB", "NL", "unknown"], { leads: 4, tickets: 5, tasks: 4 }], [true, ["NL"], { leads: 2, tickets: 3, tasks: 0 }]);
expect("page: the rows asked for, capped at 500 and at least 1",
  [pageOf(all, 3, true).rows, pageOf(all, 1000, true).rows, pageOf(all, 0, true).rows, ids(pageOf(all, 1000, true).tickets.rows).length], [3, 500, 1, 5], [3, 1000, 0, 5]);
expect("page: per person for performance.team only, the time computed passed on",
  [pageOf(all, 100, true).byOwner?.length, pageOf(all, 100, false).byOwner, nl.computedAt], [4, null, at], [4, [], at]);

// ---- "Updated …" under the title -----------------------------------------------------------------------------
const now = new Date("2026-10-18T10:05:00.000Z");
const ago = (ms) => new Date(now.getTime() - ms).toISOString();
expect("updated: now, seconds, minutes, an hour ago in English",
  [agoText(ago(4_000), now, "en"), agoText(ago(40_000), now, "en"), agoText(ago(120_000), now, "en"), agoText(ago(3_700_000), now, "en")],
  ["now", "40 seconds ago", "2 minutes ago", "1 hour ago"], ["now", "40 seconds ago", "2 minutes ago", "61 minutes ago"]);
expect("updated: in Dutch", [agoText(ago(4_000), now, "nl"), agoText(ago(120_000), now, "nl")], ["nu", "2 minuten geleden"], ["nu", "2 minutes ago"]);
expect("updated: stale only past three minutes; a time ahead of now is fresh",
  [isStale(ago(60_000), now), isStale(ago(180_000), now), isStale(ago(181_000), now), isStale(ago(-5_000), now)], [false, false, true, false], [false, true, true, false]);

// ---- formats and the unlinked-calls setting ---------------------------------------------------------------
expect("the age bucket in words: 0–1, 2–5, 5+ (open), none without business hours",
  [bucketLabel(0, 1), bucketLabel(2, 5), bucketLabel(5, null), bucketLabel(null, null)], ["0–1", "2–5", "5+", null], ["0-1", "2–5", "5+", null]);
expect("days since a date: today 0, yesterday 1, never negative", [daysSince("2026-10-16", "2026-10-16"), daysSince("2026-10-15", "2026-10-16"), daysSince("2026-10-17", "2026-10-16")], [0, 1, 0], [0, 1, -1]);
expect("the unlinked-calls check: the stored value, else skip for a telephony connection and none for another kind",
  [unlinkedSkipOf({ dq_unlinked_skip: "none" }, "telephony"), unlinkedSkipOf({}, "telephony"), unlinkedSkipOf({}, "crm"), unlinkedSkipOf({ dq_unlinked_skip: "" }, "telephony")],
  [DQ_UNLINKED_SKIP_NONE, DQ_UNLINKED_SKIP_DEFAULT, DQ_UNLINKED_SKIP_NONE, DQ_UNLINKED_SKIP_DEFAULT], [DQ_UNLINKED_SKIP_NONE, DQ_UNLINKED_SKIP_DEFAULT, DQ_UNLINKED_SKIP_DEFAULT, DQ_UNLINKED_SKIP_DEFAULT]);

const passed = results.filter(Boolean).length;
if (PROVOKE) {
  const ok = passed === 0;
  console.log(`\n${ok ? `ALL ${results.length} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${results.length} checks did not fail when provoked`}`);
  process.exit(ok ? 0 : 1);
}
console.log(`\n${passed === results.length ? `follow-up: PASS (${results.length} checks)` : `follow-up: FAIL (${results.length - passed} of ${results.length})`}`);
process.exit(passed === results.length ? 0 : 1);
