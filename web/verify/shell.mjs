/**
 * Verifier: the persistent frame, its prefetches and the writes shown at once (night N07, decisions D2, D3, D5), without a
 * server, a browser or a database.
 *
 *   node --experimental-strip-types verify/shell.mjs             every check must PASS
 *   node --experimental-strip-types verify/shell.mjs --provoke   every check must FAIL
 *
 * Covers:
 *   D2  the rail's current item from the address (lib/nav currentHrefOf): a page's own href, a page under an item (Send a
 *       message, a source's page, a journey), Welcome only on "/", a trailing slash, a path under no item, the longest
 *       prefix at a segment boundary (/reports/calls-per-agent is not under /reports/calls), every visible href of three
 *       roles current on its own address; the route group: every page with the frame sits in app/(shell), the four that
 *       stay outside do not, no loading boundary at the group's root (the pages that must answer a real 404), the skeleton
 *       draws no frame of its own, the layout renders ShellFrame and the page's Shell no longer does
 *   D5  the full prefetch only for 131's agent class (lib/nav mayFullPrefetch): the agent pages, a Live board and the team
 *       pages, never a report, a configuration page or Log out; the head start per role (headStartHrefs): an agent's My
 *       day, Messages, My schedule; a supervisor's the first Live board and Team hours instead; an analyst none; a person
 *       without a contact center no board; the hover delay of 100 ms; staleTimes 30 s for dynamic and full prefetches
 *   D3  the day shown at once (lib/live dayWithStatus, dayEnded): a pause closes the running stretch at that moment and
 *       stops the clock, a working status after a pause starts one, working to working keeps the stretch, the status, its
 *       name and its time, a market alone keeps the status, the day's end caps the clock, an ended day stops it
 */
import { readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import { currentHrefOf, headStartHrefs, HOVER_PREFETCH_MS, mayFullPrefetch, visibleNav } from "../src/lib/nav.ts";
import { dayEnded, dayWithStatus, workedSeconds } from "../src/lib/live.ts";
import { t } from "../src/lib/copy.ts";

const PROVOKE = process.argv.includes("--provoke");
const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(70)} got ${JSON.stringify(actual).slice(0, 70)}${pass ? "" : `, wanted ${JSON.stringify(want).slice(0, 70)}`}`);
}

const here = path.dirname(new URL(import.meta.url).pathname);
const app = path.join(here, "..", "src", "app");
const src = (p) => readFileSync(path.join(here, "..", "src", p), "utf8");
const copy = t("en");
const principal = (permissions, contactCenters = [{ key: "newco", name: "Newco" }]) => ({
  tenantId: "t", tenantName: "Tenant", userId: "u", displayName: "Someone", organisationName: "Org", roleKey: "x",
  permissions, locale: "en", timeZone: "Europe/Madrid", preview: null, canPreview: false, perPerson: ["email", "orders"], contactCenters,
});
const AGENT = ["workday.own", "roster.view", "leads.accept", "performance.own"];
const SUPERVISOR = ["workday.own", "roster.view", "workday.team", "performance.team", "monitoring.live", "messages.send"];
const ANALYST = ["reports.view", "performance.team", "monitoring.live", "quality.manage"];
const ADMIN = ["workday.own", "workday.team", "workday.export", "performance.team", "monitoring.live", "reports.view", "roster.view", "roster.manage",
  "users.manage_all", "users.manage_agents", "messages.send", "tenant.configure"];
const hrefsOf = (perms) => visibleNav(principal(perms), copy).flatMap((e) => (e.kind === "page" ? [e.item.href] : e.items.map((i) => i.href)));

// ---- D2: the current item from the address
const H = hrefsOf(ADMIN);
expect("a page's own href", currentHrefOf("/reports/calls", H), "/reports/calls", "/reports/calls-per-agent");
expect("Welcome on / only", [currentHrefOf("/", H), currentHrefOf("/account", H)], ["/", null], ["/", "/"]);
expect("a page under an item (Send a message, a source, a journey)",
  ["/messages/send", "/configuration/sources/0b0e6f0a-0000-4000-8000-000000000000", "/campaigns/welcome-series"].map((p) => currentHrefOf(p, H)),
  ["/messages", "/configuration/sources", "/campaigns"], [null, null, null]);
expect("a prefix only at a segment boundary", currentHrefOf("/reports/calls-per-agent", H), "/reports/calls-per-agent", "/reports/calls");
expect("a trailing slash", currentHrefOf("/day/", H), "/day", null);
expect("a path under no item (Waiting for you, Log out)", [currentHrefOf("/me/follow-up", H), currentHrefOf("/logout", H)], [null, null], ["/", "/"]);
expect("a contact center's board", currentHrefOf("/live/newco", H), "/live/newco", "/live");
for (const [name, perms] of [["agent", AGENT], ["supervisor", SUPERVISOR], ["admin", ADMIN]]) {
  const hs = hrefsOf(perms);
  expect(`every ${name} rail item current on its own address`, hs.filter((h) => currentHrefOf(h, hs) !== h), [], hs.slice(0, 1));
}

// ---- D2: the route group
const pagesUnder = (dir) => readdirSync(dir).flatMap((f) => {
  const p = path.join(dir, f);
  return statSync(p).isDirectory() ? pagesUnder(p) : f === "page.tsx" ? [path.relative(app, p)] : [];
});
const pages = pagesUnder(app).filter((p) => !p.startsWith("api"));
const withShell = pages.filter((p) => /<Shell\b|ConfigurationPage/.test(readFileSync(path.join(app, p), "utf8")));
expect("every page drawing the Shell sits in the route group (Log out apart)", withShell.filter((p) => !p.startsWith("(shell)") && p !== "logout/page.tsx"), [], ["x"]);
expect("Invitation, Log out, No access and the print view stay outside it",
  ["invite/[token]/page.tsx", "logout/page.tsx", "no-access/page.tsx", "roster/planner/print/page.tsx"].map((p) => pages.includes(p)),
  [true, true, true, true], [false, false, false, false]);
let rootLoading = true;
try { statSync(path.join(app, "(shell)", "loading.tsx")); } catch { rootLoading = false; }
expect("no loading boundary at the group's root (real 404s)", rootLoading, false, true);
const real404 = ["(shell)/campaigns/[code]", "(shell)/reports/attempts-per-agent", "(shell)/reports/email-per-agent", "(shell)/reports/orders-per-person"];
expect("the four pages that answer a real 404 have no loading boundary", real404.filter((d) => { try { statSync(path.join(app, d, "loading.tsx")); return true; } catch { return false; } }), [], ["x"]);
const skeleton = src("components/RouteSkeleton.tsx");
expect("the skeleton draws no frame (no header, rail or cookie)", [/<header/.test(skeleton), /<nav/.test(skeleton), /cookies\(\)/.test(skeleton)], [false, false, false], [true, true, true]);
const layout = readFileSync(path.join(app, "(shell)", "layout.tsx"), "utf8");
const shell = src("components/Shell.tsx");
expect("the group's layout renders the frame, the page's Shell does not", [/<ShellFrame\b/.test(layout), /<header|<nav aria-label=\{copy\.app\.name\}/.test(shell)], [true, false], [false, true]);
expect("the message centre takes no active prop (from the address)", /<MessageCenter copy=\{copy\.messages\} \/>/.test(src("components/ShellFrame.tsx")), true, false);
expect("Log out never prefetches", /href="\/logout"\s+prefetch=\{false\}/.test(src("components/ShellFrame.tsx")), true, false);
expect("no rail link loses its prefetch on a page (the Follow-up exception is gone)", /active === "follow-up" \? false/.test(src("components/ShellFrame.tsx")), false, true);

// ---- D5: prefetch policy
expect("full prefetch for the agent class",
  ["/", "/day", "/hours", "/schedule", "/messages", "/account", "/me/follow-up", "/team/people", "/team/hours", "/roster/planner", "/live/newco"].map(mayFullPrefetch),
  Array(11).fill(true), Array(11).fill(false));
expect("never for a report, configuration or Log out",
  ["/reports/dashboard", "/reports/follow-up", "/reports/flash", "/configuration/sources", "/logout", "/live/newco/x", "/team"].map(mayFullPrefetch),
  Array(7).fill(false), Array(7).fill(true));
expect("an agent's head start once the day is open", headStartHrefs(principal(AGENT), copy, true), ["/day", "/messages", "/schedule"], []);
expect("none while the day is not open (Clock in would throw it away)", [headStartHrefs(principal(AGENT), copy, false), headStartHrefs(principal(AGENT), copy), headStartHrefs(principal(SUPERVISOR), copy, false)], [[], [], []], [["/day"], ["/day"], ["/team/hours"]]);
expect("a supervisor's head start: the board and Team hours, not the agent's set", headStartHrefs(principal(SUPERVISOR), copy, true), ["/live/newco", "/team/hours"], ["/day", "/messages", "/schedule", "/live/newco", "/team/hours"]);
expect("an analyst's head start: the board only (no clock, no Team hours)", headStartHrefs(principal(ANALYST), copy), ["/live/newco"], []);
expect("no contact center, no board", headStartHrefs(principal(SUPERVISOR, []), copy, true), ["/team/hours"], []);
expect("the hover delay", HOVER_PREFETCH_MS, 100, 0);
const config = readFileSync(path.join(here, "..", "next.config.ts"), "utf8");
expect("staleTimes: dynamic and full prefetches 30 s", /staleTimes:\s*\{\s*dynamic:\s*30,\s*static:\s*30\s*\}/.test(config), true, false);

const idle = src("components/IdlePrefetch.tsx");
expect("the head start runs at most once per tab and day state (a module-level set, keyed)", [/^const ran = new Set<string>\(\);/m.test(idle), /ran\.has\(runKey\)/.test(idle)], [true, true], [false, false]);
const welcome = src("app/(shell)/(welcome)/page.tsx");
expect("the head start marks the document: the routes once asked, \"none\" when empty, rendered for an empty list too",
  [/mark\.headStart = "none"/.test(idle), /mark\.headStart = list\.join\(" "\)/.test(idle), /if \(hrefs\.length === 0\) return null/.test(welcome)],
  [true, true, false], [false, false, true]);

// ---- D3: the day shown at once
const T0 = Date.parse("2026-11-25T09:00:00Z");
const day = (clock, extra = {}) => ({
  date: "2026-11-25", status: "working", startedAt: "2026-11-25T08:00:00.000Z", endedAt: null, statusKey: "work", statusName: "Working",
  statusSince: "2026-11-25T08:00:00.000Z", clock, dayEndsAt: "2026-11-25T21:00:00.000Z", sessions: 1, sessionStartedAt: "2026-11-25T08:00:00.000Z",
  clockInAgain: false, canClockInAgain: false, hoursMarket: "NL", ...extra,
});
const running = day({ closedSeconds: 600, runningSince: "2026-11-25T08:30:00.000Z" });
const paused = dayWithStatus(running, { key: "break", name: "Break", isWorking: false }, T0);
expect("a pause closes the running stretch at the click", [paused.clock.closedSeconds, paused.clock.runningSince], [600 + 1800, null], [600, "2026-11-25T08:30:00.000Z"]);
expect("the status, its name and its time", [paused.statusKey, paused.statusName, paused.statusSince], ["break", "Break", "2026-11-25T09:00:00.000Z"], ["work", "Working", "2026-11-25T08:00:00.000Z"]);
expect("the clock stands still in the pause", workedSeconds(paused.clock, T0 + 600_000, paused.dayEndsAt), 2400, 3000);
const back = dayWithStatus(paused, { key: "work", name: "Working", isWorking: true }, T0 + 600_000);
expect("back to work starts a stretch", [back.clock.closedSeconds, back.clock.runningSince], [2400, "2026-11-25T09:10:00.000Z"], [2400, null]);
const sales = dayWithStatus(running, { key: "sales", name: "Sales", isWorking: true }, T0);
expect("working to working keeps the stretch", [sales.clock.closedSeconds, sales.clock.runningSince, sales.statusKey], [600, "2026-11-25T08:30:00.000Z", "sales"], [2400, null, "work"]);
const market = dayWithStatus(running, null, T0, "GB");
expect("a market alone keeps the status and the clock", [market.statusKey, market.statusSince, market.hoursMarket, market.clock.runningSince],
  ["work", "2026-11-25T08:00:00.000Z", "GB", "2026-11-25T08:30:00.000Z"], ["work", "2026-11-25T09:00:00.000Z", "NL", null]);
const late = dayWithStatus(running, { key: "break", name: "Break", isWorking: false }, Date.parse("2026-11-25T22:00:00Z"));
expect("the day's end caps the closed stretch", late.clock.closedSeconds, 600 + 12.5 * 3600, 600 + 13.5 * 3600);
const ended = dayEnded(running, T0);
expect("an ended day: no status, the clock stopped", [ended.status, ended.statusKey, ended.endedAt, ended.clock.runningSince, ended.clock.closedSeconds],
  ["ended", null, "2026-11-25T09:00:00.000Z", null, 2400], ["working", "work", null, "2026-11-25T08:30:00.000Z", 600]);

const passed = results.filter(Boolean).length;
const n = results.length;
if (PROVOKE) {
  const ok = passed === 0;
  console.log(`\nshell: ${ok ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
  process.exit(ok ? 0 : 1);
} else {
  const ok = passed === n;
  console.log(`\nshell: ${ok ? `PASS (${n} checks)` : `FAIL (${n - passed} of ${n})`}`);
  process.exit(ok ? 0 : 1);
}
