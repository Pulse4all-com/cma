/**
 * Verifier: layout at 1280 and 1920 px, the 1280 px gate below that, no
 * horizontal scrolling, the shell dimensions from the tokens, and the keycaps
 * that make the keyboard shortcuts discoverable. Also the navigation per
 * permission: everyone lands on Welcome (increment e), which pages each test
 * identity sees, numbered 1, 2, 3 without gaps, that someone without a clock
 * is sent from My day to Welcome, and that the Clock in button is shown only to
 * a person whose time is kept. On the intake reports and the Dashboard one header hint is opened
 * by keyboard focus: the panel must show, stay inside the viewport, and not cover the header or
 * label it explains when there is room below, and the Intake table scrolls inside its card so the
 * main area never scrolls sideways at 1280 px (12 October 2026). The irreversible confirmations (B9a.1,
 * 13 October 2026): switching a line off, dissolving a team and copying the previous week open on Cancel,
 * Enter at open writes nothing, the confirm button is the destructive secondary style without a keycap, and
 * a line's box stays ticked until the switch-off is confirmed, and since addition 0008y its question names the stored calls
 * it removes, the confirm button disabled while the count loads and after a failed read (backlog CMA-020); End workday, an ordinary confirmation, opens
 * on its confirm button (agent-two clocks in through the route for it, inside the mock's 07:00 to 22:00
 * workday window). Inbound and the Live board (addition 0008i): the Inbound report at 1280 px with its
 * keycaps, a hint on its right-most reason column, its table scrolling inside its card and no text on a
 * Light Blue or Soft Rose reason mark, the not-connected state for a tenant without telephony; the
 * Live board for every identity that holds it, with the inbound tiles, the missed calls and a tile's
 * hint inside the viewport, or the not-connected state, and no horizontal scrolling. Calls and Calls per
 * agent (addition 0008j) for seven identities: the per-agent page only for performance.team (the reader,
 * with reports.view alone, sees Calls and not Calls per agent), the keycaps K, N and G, the tag table and
 * the per-agent table with two rows opened inside their cards, Enter opening a row and Down moving to the
 * next person, the right-most header's hint inside the viewport, the not-connected state. Invitations
 * (addition 0008l): People with the Invitations section and the Invite dialog for the admin and the
 * manager (only the roles each may give), and /invite/<token> in its four states for an account that is no
 * person yet, plus a sign-in of another business line. Since 16 October 2026 the frame's preferences: the rail
 * folded to icons by cookie and by W (64 px, icons only, the foot hidden, the keys still working, a group's
 * click unfolding it and opening the group with both cookies, the current page's pill kept), the keyboard
 * hints hidden by cookie and shown again by ? (the keys still working), aria-keyshortcuts on the rail and
 * the top bar, the breadcrumbs on a bare page, a grouped page, Sources' detail, My account and Send a
 * message, preview as role for the admin (banner, select, the agent's rail, the role's 403 on a report
 * route, the narrowed My account, Exit) and the ignored cookie of a manager and an agent, and the roster's
 * week bar at 1280 px (three links on one line, one range label, the absence keywords, the placeholder).
 * Forms (addition 0008p) for seven identities: in the rail for reports.view or performance.team, the keycaps
 * K, Y, F, G and X, four tiles, the forms table and the answers inside their cards, the right-most header's hint
 * inside the viewport, the deltas like for like and "No history to compare yet" before the forms history;
 * Sources with its form categories. Email and Email per agent (addition 0008t) for seven identities: Email for
 * reports.view or performance.team, Email per agent for performance.team while the tenant's reports.per_person
 * holds email (absent from the rail and not found otherwise), the keycaps K, I, B and G, the tables inside their
 * cards, a row's hours opened by Enter, Down to the next person, "No email connected" for a tenant without email.
 * First orders and Orders per person (addition 0008u) for seven identities: First orders for reports.view or
 * performance.team, Orders per person for performance.team while reports.per_person holds orders (absent from the
 * rail and not found otherwise), the keycaps K, V, G and X, four tiles, a bar per level, "History from" in Muted,
 * every grouping and the tables inside their cards, "No orders connected" for a tenant without an order pipeline.
 * Callbacks kept (addition 0008w) for five identities: on Follow-up the eight weeks for reports.view or performance.team
 * and per person for performance.team, both inside their cards, the right-most header hint inside the viewport, "No
 * callback type set" for a tenant without one, there and on the Dashboard's Intake row.
 * Attempts per deal and Attempts per agent (addition 0008y) for seven identities: Attempts per deal for reports.view or
 * performance.team, Attempts per agent for performance.team while reports.per_person holds attempts (absent from the rail
 * and not found otherwise), after Speed to lead (analytics' and a reports reader's keys 4 to 9 move), the keycaps K, P, S and G, five
 * tiles, every grouping and the tables inside their cards, the right-most header's hint inside the viewport. The rail as
 * an accordion (19 October 2026): Time then Reports leaves only Reports open with cma-nav-open=reports, the server
 * renders one group open after a reload, a click on the open group closes it, Configuration's letter C opens it alone
 * and focuses its first page (Time has no letter), the folded rail unfolds with only the clicked group open, the
 * retired cma-nav-time and cma-nav-reports cookies are ignored and expired on the first toggle, a digit key opens a page
 * of a closed group and the closed group keeps its pill. No header's info mark wraps apart from its label at 1440 px on
 * Follow-up, Attempts per deal and Attempts per agent, and Attempts per deal never scrolls sideways.
 * Funnel and Cancellations (addition 0008zb) for seven identities: both for reports.view or performance.team after
 * Attempts per agent (Attempts per deal for the reader), deals per person on Funnel for performance.team while
 * reports.per_person holds deals, the keycaps K, P, S, G and X (K, G and X on Cancellations), ten tiles and four, by week
 * and by day, the tables inside their cards, the page never sideways.
 * Campaign monitoring (addition 0008v) for seven identities: in the Campaigns group for reports.view or
 * performance.team, a card per journey inside the main area (the archived one absent), a journey's Muted banner,
 * seven dashed placeholders (the drill-down locked), its prerequisites unticked, no figure, the breadcrumbs
 * Welcome › Campaigns › the journey, an archived or unknown journey not found, no journeys said in words.
 * Since the IT audit of 17 October 2026: only the first nine pages carry a
 * digit key (no data-shortcut is longer than one character, the later pages have no keycap), every open dialog
 * has an accessible name (aria-labelledby pointing at its title), and the Live board's tiles form a named
 * group. The frame fixed to the viewport (23 October 2026): on the Live board, Speed to lead and Follow-up at 1280 and
 * 1920 px the wheel and End never scroll the page, only main, down to its last line, fixed elements still sit against
 * the window, and at 1280x600 the rail with its longest group open scrolls on its own to its toggle.
 * Saves screenshots under records/ for the release note.
 *
 *   BASE=http://localhost:8080 node verify/layout.mjs             expect PASS
 *   BASE=http://localhost:8080 node verify/layout.mjs --provoke   renders at
 *       1279 px and demands the app shell, moves one hint panel over its header, lets the
 *       Intake and Inbound tables spill out of their cards, writes a count on a Light Blue reason mark,
 *       lets the Calls tag table and the per-agent table spill out of theirs,
 *       widens the missed-reason table past its card on Sources,
 *       widens the Live board's inbound tiles past the main area, focuses the confirm button of each
 *       irreversible confirmation (unticking the line's box) and Cancel on End workday, lets the invitations
 *       table spill out of its card and expects the expired invitation open, expects the folded rail at
 *       256 px, breadcrumbs on Welcome, a keycap with hidden hints, one crumb fewer everywhere, a shorter
 *       agent rail for the previewing admin and one page fewer for the ignored cookies, lets the forms table
 *       spill out of its card, lets the first orders list and the callbacks' weeks spill out of their cards, widens the first journey card past the main
 *       area, writes a two-character key on the manager's tenth page, strips the name off
 *       every dialog before it is read and the role off the tiles, expects Time still open after Reports opens,
 *       breaks the line before one header's mark per page, lets the attempts list and the lost deals per period spill out
 *       of their cards, puts the frame of before back (rows that grow, main not positioned, the rail not scrolling),
 *       expect FAIL, exit 1
 */
import { mkdirSync } from "node:fs";
import { chromium } from "playwright";

const BASE = process.env.BASE ?? "http://localhost:8080";
const provoke = process.argv.includes("--provoke");
const outDir = process.env.OUT_DIR ?? new URL("../../records/layout", import.meta.url).pathname;
mkdirSync(outDir, { recursive: true });

const problems = [];
/**
 * The mock's urgent fixture message pops up for every identity but the first one to poll the inbox, and
 * its dialog holds the focus, so a header hint could never open on a fresh server for the others (seen on
 * main, 13 October 2026). Acknowledge it first for the identities read here, as a person would.
 */
async function acknowledgeUrgent(subject) {
  const r = await fetch(`${BASE}/api/v1/me/messages`, { headers: { "x-cma-mock-subject": subject } }).catch(() => null);
  const list = (await r?.json().catch(() => null))?.data?.messages ?? [];
  for (const m of list) {
    if (m.urgency === "urgent" && !m.acknowledgedAt) {
      await fetch(`${BASE}/api/v1/me/messages/${m.id}/ack`, { method: "POST", headers: { "x-cma-mock-subject": subject, "x-cma-request": "1" } });
    }
  }
}
for (const subject of ["manager", "supervisor", "admin", "analyst", "invest-analyst", "agent-two", "reader", "agent-one"]) await acknowledgeUrgent(subject);
const b = await chromium.launch();

/**
 * Every open dialog has an accessible name (the IT audit of 17 October 2026): aria-labelledby pointing at
 * an element with text, or aria-label. --provoke strips the attributes off first, so the check fails.
 */
async function expectDialogNamed(p, where) {
  const name = await p.evaluate((strip) => {
    const d = document.querySelector("dialog[open]");
    if (!d) return null;
    if (strip) { d.removeAttribute("aria-labelledby"); d.removeAttribute("aria-label"); }
    const by = d.getAttribute("aria-labelledby");
    const text = by ? by.split(/\s+/).map((id) => document.getElementById(id)?.textContent?.trim() ?? "").join(" ") : d.getAttribute("aria-label") ?? "";
    return text.trim();
  }, provoke);
  if (name === null) problems.push(`${where}: no open dialog to name`);
  else if (name === "") problems.push(`${where}: the open dialog has no accessible name`);
}

async function expectShell(width, height) {
  const p = await b.newPage({ viewport: { width, height } });
  await p.goto(BASE + "/");
  await p.waitForLoadState("networkidle");
  const m = await p.evaluate(() => {
    const nav = document.querySelector("nav");
    const header = document.querySelector("header");
    const main = document.querySelector("main");
    return {
      gateVisible: !!document.querySelector('[data-testid="desktop-only"]') && getComputedStyle(document.querySelector('[data-testid="desktop-only"]')).display !== "none",
      scrollX: document.documentElement.scrollWidth > window.innerWidth,
      rail: nav ? nav.getBoundingClientRect().width : 0,
      topbar: header ? header.getBoundingClientRect().height : 0,
      content: main ? main.querySelector("div")?.getBoundingClientRect().width ?? 0 : 0,
      keycaps: document.querySelectorAll("kbd").length,
      focusable: [...document.querySelectorAll("a, button")].every((el) => el.tabIndex >= 0),
    };
  });
  const tag = `${width}x${height}`;
  if (m.gateVisible) problems.push(`${tag}: the desktop-only gate is showing instead of the app`);
  if (m.scrollX) problems.push(`${tag}: page scrolls horizontally`);
  if (Math.round(m.rail) !== 256) problems.push(`${tag}: rail is ${m.rail}px, token says 256`);
  if (Math.round(m.topbar) !== 56) problems.push(`${tag}: top bar is ${m.topbar}px, token says 56`);
  if (m.content > 896) problems.push(`${tag}: content column is ${m.content}px, wider than max-w-4xl`);
  if (m.keycaps < 3) problems.push(`${tag}: only ${m.keycaps} keycaps visible, expected nav keys and log out`);
  if (!m.focusable) problems.push(`${tag}: an interactive element is not focusable`);
  await p.screenshot({ path: `${outDir}/${tag}.png` });
  await p.close();
}

// Mock identities as the default ladder: analyst (no clock, the Live board), agent, supervisor, manager, admin. Everyone lands on
// Welcome; the Clock in button appears only for a person whose time is kept; My day sends the
// analyst back to Welcome.
async function expectNavigation() {
  const cases = [
    // Since 0008 Messages is a bare page right after Welcome for everyone, so every key below moves by one
    // Since B11 (12 October 2026) the Reports group holds Speed to lead and Intake (reports.view or performance.team)
    // and Data quality (reports.view or tenant.configure): the supervisor holds neither of the latter
    // Since 0008i Inbound follows Intake for the same permissions
    // Since 0008j Calls (reports.view or performance.team) and Calls per agent (performance.team) follow Inbound
    // Since 0008o (16 October 2026) Follow-up follows Speed to lead (reports.view, performance.team or monitoring.live);
    // since 0008p Forms (reports.view or performance.team) follows Calls per agent, so Data quality moves by one;
    // since 0008t Email (reports.view or performance.team) and Email per agent (performance.team, and the tenant's
    // reports.per_person holding email, as the dev seed's does) follow Forms; since 0008u First orders (reports.view or
    // performance.team) and Orders per person (performance.team, and reports.per_person holding orders, as the dev
    // seed's does) follow Email per agent; since 0008v the Campaigns group (Campaign monitoring, reports.view or
    // performance.team) follows Reports; since 0008y Attempts per deal (reports.view or performance.team) and Attempts per
    // agent (performance.team, and reports.per_person holding attempts, as the dev seed's does) follow Speed to lead, so the
    // analyst's keys 6 to 9 and the reader's 4 to 9 move (accepted during the soft launch, Martin, 19 October 2026). Since
    // 0008z (Martin, 20 October 2026) Reports runs Dashboard, Speed to lead, Calls, Calls per agent, Email, Email per agent,
    // Follow-up, Attempts per deal, Attempts per agent, Forms, Intake, Inbound, First orders, Orders per person, Data quality,
    // so the digit keys after Speed to lead move for everyone who sees Reports. Since 0008zb Funnel and Cancellations
    // (reports.view or performance.team) follow Attempts per agent (Attempts per deal for the reader)
    // Since 0008ze Reviews (reports.view or performance.team) follows Orders per person (First orders for the reader); since
    // 0008zi Maintenance (reports.view or performance.team) follows Reviews
    ["analyst", ["/", "/messages", "/live/board", "/reports/dashboard", "/reports/speed-to-lead", "/reports/calls", "/reports/calls-per-agent", "/reports/email",
      "/reports/email-per-agent", "/reports/follow-up", "/reports/attempts", "/reports/attempts-per-agent", "/reports/funnel", "/reports/cancellations", "/reports/forms",
      "/reports/intake", "/reports/inbound", "/reports/first-orders", "/reports/orders-per-person", "/reports/reviews", "/reports/maintenance", "/reports/data-quality",
      "/campaigns"], false],
    // A reports reader (reports.view alone, 0008j): Calls without Calls per agent, no Dashboard; Email without Email per agent;
    // Attempts per deal without Attempts per agent; First orders without Orders per person
    ["reader", ["/", "/messages", "/reports/speed-to-lead", "/reports/calls", "/reports/email", "/reports/follow-up", "/reports/attempts", "/reports/funnel",
      "/reports/cancellations", "/reports/forms", "/reports/intake", "/reports/inbound", "/reports/first-orders", "/reports/reviews", "/reports/maintenance", "/reports/data-quality", "/campaigns"], false],
    // Since 0005 My schedule (roster.view) follows My hours in the Time group
    ["agent-one", ["/", "/messages", "/day", "/hours", "/schedule"], true],
    ["supervisor", ["/", "/messages", "/live/board", "/day", "/hours", "/schedule", "/team/hours", "/reports/dashboard", "/reports/speed-to-lead", "/reports/calls",
      "/reports/calls-per-agent", "/reports/email", "/reports/email-per-agent", "/reports/follow-up", "/reports/attempts", "/reports/attempts-per-agent",
      "/reports/funnel", "/reports/cancellations", "/reports/forms", "/reports/intake", "/reports/inbound", "/reports/first-orders", "/reports/orders-per-person",
      "/reports/reviews", "/reports/maintenance", "/campaigns"], true],
    // Since 0004 the Team group sits between Live and Time for people who manage others (manager, admin);
    // the supervisor and the agent see no Team group, so their keys do not move. The planner (0005) joins it.
    ["manager", ["/", "/messages", "/live/board", "/team/people", "/roster/planner", "/day", "/hours", "/schedule", "/team/hours", "/reports/dashboard",
      "/reports/speed-to-lead", "/reports/calls", "/reports/calls-per-agent", "/reports/email", "/reports/email-per-agent", "/reports/follow-up", "/reports/attempts",
      "/reports/attempts-per-agent", "/reports/funnel", "/reports/cancellations", "/reports/forms", "/reports/intake", "/reports/inbound", "/reports/first-orders",
      "/reports/orders-per-person", "/reports/reviews", "/reports/maintenance", "/reports/data-quality", "/campaigns"], true],
    ["admin", ["/", "/messages", "/live/board", "/team/people", "/roster/planner", "/day", "/hours", "/schedule", "/team/hours", "/reports/dashboard",
      "/reports/speed-to-lead", "/reports/calls", "/reports/calls-per-agent", "/reports/email", "/reports/email-per-agent", "/reports/follow-up", "/reports/attempts",
      "/reports/attempts-per-agent", "/reports/funnel", "/reports/cancellations", "/reports/forms", "/reports/intake", "/reports/inbound", "/reports/first-orders",
      "/reports/orders-per-person", "/reports/reviews", "/reports/maintenance", "/reports/data-quality", "/campaigns"], true],
  ];
  for (const [subject, hrefs, clock] of cases) {
    const ctx = await b.newContext({ viewport: { width: 1440, height: 900 }, extraHTTPHeaders: { "x-cma-mock-subject": subject } });
    const p = await ctx.newPage();
    await p.goto(BASE + "/");
    await p.waitForLoadState("networkidle");
    const path = new URL(p.url()).pathname;
    // Since the IT audit of 17 October 2026 only the first nine pages carry a digit key (one keypress; "10" can never be
    // pressed): the later pages are in the rail without a key or a keycap. --provoke writes a two-character key on the tenth
    const links = await p.evaluate((spoil) => {
      // The rail is the first nav; the period bar on a page is another
      const all = [...(document.querySelector("nav")?.querySelectorAll('a[href]:not([href^="/configuration/"])') ?? [])];
      if (spoil && all[9]) all[9].setAttribute("data-shortcut", "10");
      return all.map((a) => [a.getAttribute("data-shortcut"), a.getAttribute("href"), !!a.querySelector("kbd"), a.getAttribute("aria-keyshortcuts")]);
    }, provoke && subject === "manager");
    const want = hrefs.map((h, i) => [i < 9 ? String(i + 1) : null, h, i < 9, i < 9 ? String(i + 1) : null]);
    for (const [key, href] of links) if (key !== null && key.length !== 1) problems.push(`${subject}: ${href} carries the key "${key}", which no single keypress gives`);
    const hasClockIn = await p.locator('[data-testid="clock-in"]').count() > 0;
    // The shift sentence (0005): only for a person with a roster (roster.view), from the published fixture
    const hasShiftLine = await p.locator('[data-testid="shift-line"]').count() > 0;
    if (hasShiftLine !== clock) problems.push(`${subject}: shift line ${hasShiftLine ? "shown" : "missing"} on Welcome, expected ${clock ? "shown" : "missing"}`);
    if (path !== "/") problems.push(`${subject}: landed on ${path}, expected Welcome at /`);
    if (JSON.stringify(links) !== JSON.stringify(want)) problems.push(`${subject}: navigation ${JSON.stringify(links)}, expected ${JSON.stringify(want)}`);
    // The Configuration group (0005a): unnumbered pages for tenant.configure only (the admin); nobody else sees the group
    const configLinks = await p.evaluate(() => [...(document.querySelector("nav")?.querySelectorAll('a[href^="/configuration/"]') ?? [])].map((a) => [a.getAttribute("data-shortcut"), a.getAttribute("href")]));
    const wantConfig = subject === "admin"
      // since 0008z (Martin, 20 October 2026): Team and skills, Statuses, Absences and coverage, Markets, Sources, App links,
      // Exports, Alert rules, System health
      ? [["/configuration/teams"], ["/configuration/statuses"], ["/configuration/absences"], ["/configuration/markets"], ["/configuration/sources"],
         ["/configuration/app-links"], ["/configuration/exports"], ["/configuration/alert-rules"], ["/configuration/metrics"], ["/configuration/health"]].map(([h]) => [null, h])
      : [];
    if (JSON.stringify(configLinks) !== JSON.stringify(wantConfig)) problems.push(`${subject}: configuration pages ${JSON.stringify(configLinks)}, expected ${JSON.stringify(wantConfig)}`);
    if (hasClockIn !== clock) problems.push(`${subject}: Clock in ${hasClockIn ? "shown" : "missing"} on Welcome, expected ${clock ? "shown" : "missing"}`);
    // My account (0005b): the name in the top bar opens it, for everyone; it is never a rail item
    const accountLinks = await p.evaluate(() => [...document.querySelectorAll('a[href="/account"]')].map((a) => a.closest("header, nav")?.tagName ?? ""));
    if (JSON.stringify(accountLinks) !== JSON.stringify(["HEADER"])) problems.push(`${subject}: My account linked from ${JSON.stringify(accountLinks)}, expected the top bar only`);
    await p.screenshot({ path: `${outDir}/${subject}-welcome.png` });
    await p.goto(BASE + "/account");
    await p.waitForLoadState("networkidle");
    const accountPath = new URL(p.url()).pathname;
    const accountTitle = await p.locator("main h1").first().textContent().catch(() => null);
    if (accountPath !== "/account" || !accountTitle) problems.push(`${subject}: My account answered ${accountPath} with title ${JSON.stringify(accountTitle)}`);
    await p.screenshot({ path: `${outDir}/${subject}-account.png` });
    if (!clock) {
      await p.goto(BASE + "/day");
      await p.waitForLoadState("networkidle");
      const dayPath = new URL(p.url()).pathname;
      if (dayPath !== "/") problems.push(`${subject}: My day answered ${dayPath}, expected to be sent to Welcome`);
    }
    await ctx.close();
  }
}

// The intake reports (B11): at 1280 px every page keeps the shell without horizontal scrolling, even the
// widest table (Intake); the grouping and market keycaps are there; a tenant without telephony or a shop
// says so in words; an agent who opens a report gets the no-permission card, never figures
async function expectReports() {
  // The last value is the header hint opened on the page: a middle column, the right-most column (the
  // panel must stay inside the viewport) and a tile
  const lastIntakeHeader = '[data-testid="intake-table"] thead tr:nth-child(2) th:last-child button[data-header-hint]';
  const cases = [
    ["manager", "/reports/speed-to-lead?range=month", ["G", "T", "W", "M", "C"], '[data-testid="speed-summary"]',
      '[data-testid="speed-summary"] th:nth-child(6) button[data-header-hint]'],
    ["manager", "/reports/intake?range=month", ["F", "T", "W", "M", "C"], '[data-testid="intake-table"]', lastIntakeHeader],
    ["manager", "/reports/data-quality", [], '[data-testid="data-quality"]', '[data-testid="data-quality"] th:nth-child(2) button[data-header-hint]'],
    ["manager", "/reports/dashboard?range=month", ["P", "T"], '[data-testid="intake-row"]', '[data-testid="intake-speed"] button[data-header-hint]'],
    ["invest-analyst", "/reports/intake?range=month", ["F"], '[data-testid="not-connected"]', lastIntakeHeader],
    ["invest-analyst", "/reports/dashboard?range=month", [], '[data-testid="not-connected"]', '[data-testid="intake-calls"] button[data-header-hint]'],
    // Inbound (addition 0008i): the right-most reason column's hint stays inside the viewport; a tenant
    // without telephony says so in words and has no header to open
    ["manager", "/reports/inbound?range=month", ["G", "T", "W", "M", "C"], '[data-testid="inbound-table"]',
      '[data-testid="inbound-table"] thead th:last-child button[data-header-hint]'],
    ["invest-analyst", "/reports/inbound?range=month", ["G"], '[data-testid="inbound-not-connected"]', null],
    // Follow-up (addition 0008o): the three filters' keycaps, the tickets table's right-most header hint stays
    // inside the viewport; the reader (reports.view alone) gets the lists without the per-person table
    ["manager", "/reports/follow-up", ["K", "O", "S"], '[data-testid="follow-up-by-owner"]', '[data-testid="follow-up-tickets"] thead th:last-child button[data-header-hint]'],
    ["reader", "/reports/follow-up?state=attention", ["K", "O", "S"], '[data-testid="follow-up-leads"]',
      '[data-testid="follow-up-tasks"] thead th:last-child button[data-header-hint]'],
    ["agent-one", "/me/follow-up", [], '[data-testid="my-leads"]', '[data-testid="my-tickets"] thead th:last-child button[data-header-hint]'],
  ];
  for (const [subject, path, keys, selector, hintMark] of cases) {
    const ctx = await b.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": subject } });
    const p = await ctx.newPage();
    await p.goto(BASE + path);
    await p.waitForLoadState("networkidle");
    const m = await p.evaluate(() => ({
      scrollX: document.documentElement.scrollWidth > window.innerWidth,
      rail: document.querySelector("nav")?.getBoundingClientRect().width ?? 0,
      keycaps: [...document.querySelectorAll("main kbd")].map((k) => k.textContent?.trim()),
    }));
    if (m.scrollX) problems.push(`${subject} ${path}: page scrolls horizontally at 1280`);
    // Intake, the widest table: it scrolls inside its own card, so the main area never scrolls
    // sideways (12 October 2026); --provoke lets the table spill out of its card again
    if (path.startsWith("/reports/intake") || (path.startsWith("/reports/inbound") && subject === "manager")) {
      const w = await p.evaluate(([spill, id]) => {
        const box = document.querySelector(`[data-testid="${id}"]`);
        if (!box) return null;
        if (spill) box.style.overflowX = "visible";
        const main = document.querySelector("main");
        return { main: main.scrollWidth - main.clientWidth };
      }, [provoke && subject === "manager", path.startsWith("/reports/inbound") ? "inbound-scroll" : "intake-scroll"]);
      if (!w) problems.push(`${subject} ${path}: the table has no scroll container`);
      else if (w.main > 0) problems.push(`${subject} ${path}: the main area scrolls sideways by ${w.main}px at 1280`);
    }
    // No text on a Light Blue or Soft Rose segment or dot of the reason series (docs/style/Pulse4all-Style.md 7.8);
    // --provoke writes a count into the first Light Blue one
    if (path.startsWith("/reports/inbound") && subject === "manager") {
      const t = await p.evaluate((spill) => {
        const marks = [...document.querySelectorAll('[data-testid="inbound-legend"] .bg-p4a-lightblue, [data-testid="inbound-legend"] .bg-p4a-rose, [data-testid="inbound-table"] .bg-p4a-lightblue, [data-testid="inbound-table"] .bg-p4a-rose')];
        if (spill && marks[0]) marks[0].textContent = "3";
        return { marks: marks.length, withText: marks.filter((m) => (m.textContent ?? "").trim() !== "").length };
      }, provoke);
      if (t.marks === 0) problems.push(`${subject} ${path}: no Light Blue or Soft Rose reason mark to check`);
      if (t.withText > 0) problems.push(`${subject} ${path}: ${t.withText} Light Blue or Soft Rose reason marks carry text`);
    }
    if (Math.round(m.rail) !== 256) problems.push(`${subject} ${path}: rail is ${m.rail}px`);
    for (const k of keys) if (!m.keycaps.includes(k)) problems.push(`${subject} ${path}: keycap ${k} missing`);
    if (await p.locator(selector).count() === 0) problems.push(`${subject} ${path}: ${selector} missing`);
    await p.screenshot({ path: `${outDir}/${subject}-${path.split("?")[0].split("/").pop()}.png`, fullPage: true });
    // One header hint, opened by keyboard focus (none on a page that only says a source is not connected)
    if (hintMark === null) {
      await ctx.close();
      continue;
    }
    const mark = p.locator(hintMark);
    if (await mark.count() !== 1) problems.push(`${subject} ${path}: header hint ${hintMark} missing`);
    else {
      await mark.focus();
      const h = await p.evaluate((cover) => {
        const m = document.activeElement;
        const panel = m && document.getElementById(m.getAttribute("aria-describedby") ?? "");
        if (!panel || panel.hidden || getComputedStyle(panel).visibility !== "visible") return null;
        const anchor = m.closest("th, [data-hint-anchor]").getBoundingClientRect();
        if (cover) panel.style.top = `${anchor.top}px`;
        const r = panel.getBoundingClientRect();
        return {
          inside: r.left >= 0 && r.top >= 0 && r.right <= window.innerWidth && r.bottom <= window.innerHeight,
          covers: r.top < anchor.bottom && r.bottom > anchor.top && r.left < anchor.right && r.right > anchor.left,
          roomBelow: anchor.bottom + r.height + 8 <= window.innerHeight,
          width: r.width,
        };
      }, provoke && path.startsWith("/reports/data-quality"));
      if (!h) problems.push(`${subject} ${path}: the header hint does not show on focus`);
      else {
        if (!h.inside) problems.push(`${subject} ${path}: the header hint leaves the viewport`);
        if (h.covers && h.roomBelow) problems.push(`${subject} ${path}: the header hint covers the header it explains`);
        if (h.width > 320) problems.push(`${subject} ${path}: the header hint is ${h.width}px wide, more than 320`);
      }
      await p.screenshot({ path: `${outDir}/${subject}-${path.split("?")[0].split("/").pop()}-hint.png` });
    }
    await ctx.close();
  }
  const ctx = await b.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": "agent-one" } });
  const p = await ctx.newPage();
  for (const path of ["/reports/speed-to-lead", "/reports/follow-up", "/reports/intake", "/reports/inbound", "/reports/calls", "/reports/calls-per-agent", "/reports/forms",
    "/reports/email", "/reports/email-per-agent", "/reports/attempts", "/reports/attempts-per-agent", "/reports/funnel", "/reports/cancellations",
    "/reports/first-orders", "/reports/orders-per-person", "/reports/reviews", "/reports/maintenance", "/reports/data-quality"]) {
    await p.goto(BASE + path);
    await p.waitForLoadState("networkidle");
    if (await p.locator("main table").count() > 0) problems.push(`agent-one ${path}: a report table is shown to an agent`);
  }
  // The reader (reports.view alone) sees no per-person table on Follow-up (performance.team only, 0008o)
  await p.goto(BASE + "/reports/follow-up");
  await p.waitForLoadState("networkidle");
  await ctx.close();
  const reader = await b.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": "reader" } });
  const rp = await reader.newPage();
  await rp.goto(BASE + "/reports/follow-up");
  await rp.waitForLoadState("networkidle");
  if (await rp.locator('[data-testid="follow-up-by-owner"]').count() !== (provoke ? 1 : 0)) problems.push("reader /reports/follow-up: the per-person table is shown without performance.team");
  await reader.close();
}

// Calls and Calls per agent (addition 0008j, brief B16), per identity at 1280 px: Calls for reports.view or
// performance.team, Calls per agent for performance.team only, in the rail and on the page (the reader, with
// reports.view alone, and the agent get the no-permission card and no figures); the page never scrolls
// sideways; the keycaps K, N and G next to the period bar's; the tag table and the per-agent table end
// inside their cards (the tag table may scroll inside its card, the per-agent table fits); a row opens with
// Enter on its name and Down moves to the next person; the opened rows, the not-linked one too, stay inside
// the card; the right-most header's hint stays inside the viewport; a tenant without telephony says so in
// words; the four deltas say what they compare with (like for like: this week, still running, with the
// same point in the previous one; a week that ended with the whole previous week; 30 days to yesterday,
// whose previous span starts before the fixture's telephony history six weeks back, with nothing: "No
// history to compare yet" in Muted, no arrow and no percentage, the history's first date in its title,
// brief B16.1). --provoke lets the tag table spill out of its card, widens the per-agent table past it and
// expects each of the three labels to be the next one's
async function expectCalls() {
  const fits = (p, scrollId, spill) => p.evaluate(([id, spill]) => {
    const box = document.querySelector(`[data-testid="${id}"]`);
    if (!box) return null;
    if (spill) { box.style.overflowX = "visible"; box.querySelector("table")?.setAttribute("style", "min-width: 1400px"); }
    const card = box.closest("section");
    const edge = card.getBoundingClientRect().right - parseFloat(getComputedStyle(card).paddingRight);
    const main = document.querySelector("main");
    return { spills: box.getBoundingClientRect().right > edge + 0.5 || [...box.querySelectorAll("tr")].some((r) => r.getBoundingClientRect().right > edge + 0.5 && getComputedStyle(box).overflowX === "visible"),
      scrolls: box.scrollWidth > box.clientWidth, mainX: main.scrollWidth - main.clientWidth };
  }, [scrollId, spill]);
  const hintInside = async (p, selector, where) => {
    const mark = p.locator(selector);
    if (await mark.count() !== 1) return problems.push(`${where}: header hint ${selector} missing`);
    await mark.focus();
    const ok = await p.evaluate(() => {
      const m = document.activeElement;
      const panel = m && document.getElementById(m.getAttribute("aria-describedby") ?? "");
      if (!panel || panel.hidden) return null;
      const r = panel.getBoundingClientRect();
      return r.left >= 0 && r.top >= 0 && r.right <= window.innerWidth && r.bottom <= window.innerHeight;
    });
    if (ok === null) problems.push(`${where}: the header hint does not show on focus`);
    else if (!ok) problems.push(`${where}: the header hint leaves the viewport`);
  };
  // [subject, sees Calls, sees Calls per agent, telephony connected]
  const cases = [
    ["manager", true, true, true], ["supervisor", true, true, true], ["admin", true, true, true], ["analyst", true, true, true],
    ["reader", true, false, true], ["invest-analyst", true, true, false], ["agent-one", false, false, true],
  ];
  for (const [subject, calls, perAgent, telephony] of cases) {
    const ctx = await b.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": subject } });
    const p = await ctx.newPage();
    await p.goto(BASE + "/");
    await p.waitForLoadState("networkidle");
    const rail = await p.evaluate(() => [...(document.querySelector("nav")?.querySelectorAll("a") ?? [])].map((a) => a.getAttribute("href")));
    if (rail.includes("/reports/calls") !== calls) problems.push(`${subject}: Calls ${calls ? "missing from" : "shown in"} the rail`);
    if (rail.includes("/reports/calls-per-agent") !== perAgent) problems.push(`${subject}: Calls per agent ${perAgent ? "missing from" : "shown in"} the rail`);
    for (const [path, may, table] of [["/reports/calls?range=month&group=day", calls, "tag-table"], ["/reports/calls-per-agent?range=month", perAgent, "agents-table"]]) {
      const where = `${subject} ${path.split("?")[0]}`;
      await p.goto(BASE + path);
      await p.waitForLoadState("networkidle");
      const m = await p.evaluate(() => ({
        scrollX: document.documentElement.scrollWidth > window.innerWidth,
        keycaps: [...document.querySelectorAll("main kbd")].map((k) => k.textContent?.trim()),
        tables: document.querySelectorAll("main table").length,
        notConnected: !!document.querySelector('[data-testid="calls-not-connected"], [data-testid="agents-not-connected"]'),
      }));
      if (m.scrollX) problems.push(`${where}: page scrolls horizontally at 1280`);
      if (!may) {
        if (m.tables > 0 || m.notConnected) problems.push(`${where}: figures shown to someone without the permission`);
        continue;
      }
      if (!telephony) {
        if (!m.notConnected || m.tables > 0) problems.push(`${where}: a tenant without telephony does not say so in words`);
        continue;
      }
      for (const k of ["T", "W", "M", "C", "K", "N", ...(path.startsWith("/reports/calls?") ? ["G"] : [])]) if (!m.keycaps.includes(k)) problems.push(`${where}: keycap ${k} missing`);
      if (path.startsWith("/reports/calls-per-agent")) {
        // Enter on the first person's name opens the row, Down moves to the next person; the not-linked row opens with a click
        const first = p.locator('[data-testid="agent-toggle"]').first();
        await first.focus();
        await p.keyboard.press("Enter");
        await p.keyboard.press("ArrowDown");
        const moved = await p.evaluate(() => document.activeElement?.getAttribute("data-testid") === "agent-toggle"
          && document.activeElement !== document.querySelector('[data-testid="agent-toggle"]'));
        await p.locator('[data-testid="agent-not-linked"] td').nth(1).click();
        const opened = await p.locator('[data-testid="agent-split"]').count();
        if (await first.getAttribute("aria-expanded") !== "true") problems.push(`${where}: Enter does not open the first row`);
        if (!moved) problems.push(`${where}: Down does not move to the next person`);
        if (opened !== 2) problems.push(`${where}: ${opened} rows opened, expected the first and the not-linked one`);
      }
      const f = await fits(p, table === "tag-table" ? "tag-table-scroll" : "agents-scroll", provoke && subject === "manager");
      if (!f) problems.push(`${where}: ${table} missing`);
      else {
        if (f.spills) problems.push(`${where}: ${table} does not end inside its card at 1280`);
        if (f.mainX > 0) problems.push(`${where}: the main area scrolls sideways by ${f.mainX}px at 1280`);
        if (table === "agents-table" && f.scrolls) problems.push(`${where}: the per-agent table needs to scroll inside its card at 1280`);
      }
      await hintInside(p, `[data-testid="${table}"] thead th:last-child button[data-header-hint]`, where);
      await p.screenshot({ path: `${outDir}/${subject}-${path.split("?")[0].split("/").pop()}.png`, fullPage: true });
      if (subject === "manager" && table === "tag-table") {
        // a week that ended two days ago in any zone, by UTC dates; 30 days to yesterday, whose previous
        // span (60 to 31 days back) starts before the fixture's telephony history (42 days back)
        const day = (n) => new Date(Date.now() + n * 86_400_000).toISOString().slice(0, 10);
        const next = { partial: "whole", whole: "none", none: "partial" };
        for (const [q, want] of [["range=week&group=day", "partial"], [`range=custom&from=${day(-8)}&to=${day(-2)}&group=day`, "whole"],
          [`range=custom&from=${day(-30)}&to=${day(-1)}&group=day`, "none"]]) {
          await p.goto(`${BASE}/reports/calls?${q}`);
          await p.waitForLoadState("networkidle");
          const deltas = await p.evaluate(() => [...document.querySelectorAll('[data-testid="delta"]')].map((d) => ({
            compares: d.getAttribute("data-compares"), text: d.textContent?.trim() ?? "", title: d.getAttribute("title") ?? "",
            muted: d.classList.contains("text-p4a-muted"), start: d.getAttribute("data-history-start") })));
          const said = deltas.map((d) => d.compares);
          const expected = provoke ? next[want] : want;
          const label = `${q.split("&")[0]}${want === "none" ? " (30 days to yesterday)" : ""}`;
          if (said.length !== 4 || said.some((x) => x !== expected)) problems.push(`${where}: the deltas of ${label} compare with ${said.join(",") || "nothing"}, expected ${expected} four times`);
          if (want === "none" && !provoke) {
            const wrong = deltas.filter((d) => d.text !== "No history to compare yet" || !d.muted || /[↑↓%]/.test(d.text)
              || !/^\d{4}-\d{2}-\d{2}$/.test(d.start ?? "") || !d.title.startsWith("The telephony history starts on "));
            if (wrong.length > 0) problems.push(`${where}: ${wrong.length} of the deltas before the telephony history do not say "No history to compare yet" in Muted with the history's first date in the title`);
          }
        }
      }
    }
    await ctx.close();
  }
}

// Email and Email per agent (addition 0008t, brief N19-A part 1), per identity at 1280 px: Email in the rail
// and on the page for reports.view or performance.team, Email per agent for performance.team while the
// tenant's reports.per_person holds email (the reader sees Email only; the agent gets the no-permission card;
// the invest tenant, without email and without the switch, sees Email say "No email connected" in words and
// no Email per agent: absent from the rail, its page not found); the page never scrolls sideways; the
// keycaps K, I, B (and G on Email) next to the period bar's; the tables end inside their cards (they may
// scroll inside them); on Email per agent Enter opens the first person's hours, Down moves to the next and
// a click opens the not-linked row; the right-most header's hint stays inside the viewport. --provoke lets
// the per-inbox table spill out of its card
async function expectEmail() {
  // [subject, sees Email, sees Email per agent, email connected]
  const cases = [
    ["manager", true, true, true], ["supervisor", true, true, true], ["admin", true, true, true], ["analyst", true, true, true],
    ["reader", true, false, true], ["invest-analyst", true, false, false], ["agent-one", false, false, true],
  ];
  for (const [subject, email, perAgent, connected] of cases) {
    const ctx = await b.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": subject } });
    const p = await ctx.newPage();
    await p.goto(BASE + "/");
    await p.waitForLoadState("networkidle");
    const rail = await p.evaluate(() => [...(document.querySelector("nav")?.querySelectorAll("a") ?? [])].map((a) => a.getAttribute("href")));
    if (rail.includes("/reports/email") !== email) problems.push(`${subject}: Email ${email ? "missing from" : "shown in"} the rail`);
    if (rail.includes("/reports/email-per-agent") !== perAgent) problems.push(`${subject}: Email per agent ${perAgent ? "missing from" : "shown in"} the rail`);
    for (const [path, may, scroll, table] of [["/reports/email?range=month&group=day", email, "email-by-inbox-scroll", "email-by-inbox"],
      ["/reports/email-per-agent?range=month", perAgent, "email-agents-scroll", "email-agents-table"]]) {
      const where = `${subject} ${path.split("?")[0]}`;
      const r = await p.goto(BASE + path);
      await p.waitForLoadState("networkidle");
      const m = await p.evaluate(() => ({
        scrollX: document.documentElement.scrollWidth > window.innerWidth,
        keycaps: [...document.querySelectorAll("main kbd")].map((k) => k.textContent?.trim()),
        tables: document.querySelectorAll("main table").length,
        notConnected: !!document.querySelector('[data-testid="email-not-connected"], [data-testid="email-agents-not-connected"]'),
      }));
      if (m.scrollX) problems.push(`${where}: page scrolls horizontally at 1280`);
      if (!may) {
        // without the tenant's switch the per-person page does not exist; without the permission it says so
        if (path.startsWith("/reports/email-per-agent") && subject === "invest-analyst" && r?.status() !== 404) problems.push(`${where}: answers ${r?.status()}, expected 404 without reports.per_person`);
        if (m.tables > 0 || m.notConnected) problems.push(`${where}: figures shown to someone without the permission`);
        continue;
      }
      if (!connected) {
        if (!m.notConnected || m.tables > 0) problems.push(`${where}: a tenant without email does not say so in words`);
        continue;
      }
      for (const k of ["T", "W", "M", "C", "K", "I", "B", ...(path.startsWith("/reports/email?") ? ["G"] : [])]) if (!m.keycaps.includes(k)) problems.push(`${where}: keycap ${k} missing`);
      if (path.startsWith("/reports/email-per-agent")) {
        const first = p.locator('[data-testid="email-agent-toggle"]').first();
        await first.focus();
        await p.keyboard.press("Enter");
        await p.keyboard.press("ArrowDown");
        const moved = await p.evaluate(() => document.activeElement?.getAttribute("data-testid") === "email-agent-toggle"
          && document.activeElement !== document.querySelector('[data-testid="email-agent-toggle"]'));
        await p.locator('[data-testid="email-agent-not-linked"] td').nth(1).click();
        const opened = await p.locator('[data-testid="email-agent-hours"]').count();
        if (await first.getAttribute("aria-expanded") !== "true") problems.push(`${where}: Enter does not open the first row`);
        if (!moved) problems.push(`${where}: Down does not move to the next person`);
        if (opened !== 2) problems.push(`${where}: ${opened} rows opened, expected the first and the not-linked one`);
      }
      const f = await p.evaluate(([id, spill]) => {
        const box = document.querySelector(`[data-testid="${id}"]`);
        if (!box) return null;
        if (spill) { box.style.overflowX = "visible"; box.querySelector("table")?.setAttribute("style", "min-width: 1400px"); }
        const card = box.closest("section");
        const edge = card.getBoundingClientRect().right - parseFloat(getComputedStyle(card).paddingRight);
        const main = document.querySelector("main");
        return { spills: box.getBoundingClientRect().right > edge + 0.5 || (getComputedStyle(box).overflowX === "visible"
          && [...box.querySelectorAll("tr")].some((row) => row.getBoundingClientRect().right > edge + 0.5)), mainX: main.scrollWidth - main.clientWidth };
      }, [scroll, provoke && subject === "manager"]);
      if (!f) problems.push(`${where}: ${scroll} missing`);
      else {
        if (f.spills) problems.push(`${where}: its table does not end inside its card at 1280`);
        if (f.mainX > 0) problems.push(`${where}: the main area scrolls sideways by ${f.mainX}px at 1280`);
      }
      const mark = p.locator(`[data-testid="${table}"] thead th:last-child button[data-header-hint]`);
      if (await mark.count() !== 1) problems.push(`${where}: the right-most header's hint is missing`);
      else {
        await mark.focus();
        const inside = await p.evaluate(() => {
          const el = document.activeElement;
          const panel = el && document.getElementById(el.getAttribute("aria-describedby") ?? "");
          if (!panel || panel.hidden) return null;
          const rect = panel.getBoundingClientRect();
          return rect.left >= 0 && rect.top >= 0 && rect.right <= window.innerWidth && rect.bottom <= window.innerHeight;
        });
        if (inside === null) problems.push(`${where}: the right-most header's hint does not show on focus`);
        else if (!inside) problems.push(`${where}: the right-most header's hint leaves the viewport`);
      }
      await p.screenshot({ path: `${outDir}/${subject}-${path.split("?")[0].split("/").pop()}.png`, fullPage: true });
    }
    await ctx.close();
  }
}

// First orders and Orders per person (addition 0008u, brief N19-A part 2), per identity at 1280 px: First
// orders in the rail and on the page for reports.view or performance.team, Orders per person for performance.team
// while the tenant's reports.per_person holds orders (the reader sees First orders only; the agent gets the
// no-permission card; the invest tenant, without an order pipeline and without the switch, sees First orders say
// "No orders connected" in words and no Orders per person: absent from the rail, its page not found); the page never
// scrolls sideways, in every grouping; the keycaps K, V (and G and X on First orders) next to the period bar's; four
// tiles, a bar per level and "History from" in Muted; the tables end inside their cards (they may scroll inside
// them); the right-most header's hint stays inside the viewport. --provoke lets the order list spill out of its card
async function expectFirstOrders() {
  // [subject, sees First orders, sees Orders per person, orders connected]
  const cases = [
    ["manager", true, true, true], ["supervisor", true, true, true], ["admin", true, true, true], ["analyst", true, true, true],
    ["reader", true, false, true], ["invest-analyst", true, false, false], ["agent-one", false, false, true],
  ];
  for (const [subject, orders, perPerson, connected] of cases) {
    const ctx = await b.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": subject } });
    const p = await ctx.newPage();
    await p.goto(BASE + "/");
    await p.waitForLoadState("networkidle");
    const rail = await p.evaluate(() => [...(document.querySelector("nav")?.querySelectorAll("a") ?? [])].map((a) => a.getAttribute("href")));
    if (rail.includes("/reports/first-orders") !== orders) problems.push(`${subject}: First orders ${orders ? "missing from" : "shown in"} the rail`);
    if (rail.includes("/reports/orders-per-person") !== perPerson) problems.push(`${subject}: Orders per person ${perPerson ? "missing from" : "shown in"} the rail`);
    const pages = [
      ["/reports/first-orders?range=month&group=day", orders, "first-order-list-scroll", "first-order-list"],
      ["/reports/first-orders?range=month&group=market", orders, "first-order-by-group-scroll", "first-order-by-group"],
      ["/reports/first-orders?range=month&group=level", orders, "first-order-by-group-scroll", "first-order-by-group"],
      ["/reports/orders-per-person?range=month", perPerson, "orders-person-scroll", "orders-person-table"],
    ];
    for (const [path, may, scroll, table] of pages) {
      const where = `${subject} ${path.split("?")[0]}${path.includes("group=") ? ` (${path.split("group=")[1]})` : ""}`;
      const firstOrders = path.startsWith("/reports/first-orders");
      const r = await p.goto(BASE + path);
      await p.waitForLoadState("networkidle");
      const m = await p.evaluate(() => ({
        scrollX: document.documentElement.scrollWidth > window.innerWidth,
        keycaps: [...document.querySelectorAll("main kbd")].map((k) => k.textContent?.trim()),
        tables: document.querySelectorAll("main table").length,
        tiles: document.querySelectorAll('[data-testid="first-order-tiles"] > *').length,
        levels: document.querySelectorAll('[data-testid="first-order-levels"] > li').length,
        history: (() => {
          const el = document.querySelector('[data-testid="first-order-history"]');
          return el ? { text: el.textContent?.trim() ?? "", muted: el.classList.contains("text-p4a-muted") } : null;
        })(),
        notConnected: !!document.querySelector('[data-testid="first-orders-not-connected"], [data-testid="orders-person-not-connected"]'),
      }));
      if (m.scrollX) problems.push(`${where}: page scrolls horizontally at 1280`);
      if (!may) {
        // without the tenant's switch the per-person page does not exist; without the permission it says so
        if (!firstOrders && subject === "invest-analyst" && r?.status() !== 404) problems.push(`${where}: answers ${r?.status()}, expected 404 without reports.per_person`);
        if (m.tables > 0 || m.notConnected) problems.push(`${where}: figures shown to someone without the permission`);
        continue;
      }
      if (!connected) {
        if (!m.notConnected || m.tables > 0 || m.tiles > 0) problems.push(`${where}: a tenant without an order pipeline does not say so in words`);
        continue;
      }
      for (const k of ["T", "W", "M", "C", "K", "V", ...(firstOrders ? ["G", "X"] : [])]) if (!m.keycaps.includes(k)) problems.push(`${where}: keycap ${k} missing`);
      if (firstOrders) {
        if (m.tiles !== 4) problems.push(`${where}: ${m.tiles} tiles, expected 4`);
        if (m.levels < 2) problems.push(`${where}: ${m.levels} level bars, expected one per level`);
        if (!m.history || !m.history.text.startsWith("History from") || !m.history.muted) problems.push(`${where}: "History from" missing or not in Muted (${JSON.stringify(m.history)})`);
      }
      const f = await p.evaluate(([id, spill]) => {
        const box = document.querySelector(`[data-testid="${id}"]`);
        if (!box) return null;
        if (spill) { box.style.overflowX = "visible"; box.querySelector("table")?.setAttribute("style", "min-width: 1400px"); }
        const card = box.closest("section");
        const edge = card.getBoundingClientRect().right - parseFloat(getComputedStyle(card).paddingRight);
        const main = document.querySelector("main");
        return { spills: box.getBoundingClientRect().right > edge + 0.5 || (getComputedStyle(box).overflowX === "visible"
          && [...box.querySelectorAll("tr")].some((row) => row.getBoundingClientRect().right > edge + 0.5)), mainX: main.scrollWidth - main.clientWidth };
      }, [scroll, provoke && subject === "manager" && scroll === "first-order-list-scroll"]);
      if (!f) problems.push(`${where}: ${scroll} missing`);
      else {
        if (f.spills) problems.push(`${where}: its table does not end inside its card at 1280`);
        if (f.mainX > 0) problems.push(`${where}: the main area scrolls sideways by ${f.mainX}px at 1280`);
      }
      // the order list ends on the link column, whose header is a hidden label without a hint: the right-most hint is the amount's
      const marks = p.locator(`[data-testid="${table}"] thead th button[data-header-hint]`);
      const mark = marks.last();
      if (await marks.count() === 0) problems.push(`${where}: the right-most header's hint is missing`);
      else {
        await mark.focus();
        const inside = await p.evaluate(() => {
          const el = document.activeElement;
          const panel = el && document.getElementById(el.getAttribute("aria-describedby") ?? "");
          if (!panel || panel.hidden) return null;
          const rect = panel.getBoundingClientRect();
          return rect.left >= 0 && rect.top >= 0 && rect.right <= window.innerWidth && rect.bottom <= window.innerHeight;
        });
        if (inside === null) problems.push(`${where}: the right-most header's hint does not show on focus`);
        else if (!inside) problems.push(`${where}: the right-most header's hint leaves the viewport`);
      }
      const name = path.split("?")[0].split("/").pop() + (path.includes("group=") && !path.includes("group=day") ? `-${path.split("group=")[1]}` : "");
      await p.screenshot({ path: `${outDir}/${subject}-${name}.png`, fullPage: true });
    }
    await ctx.close();
  }
}

// Campaign monitoring (addition 0008v, brief N19-A part 3), per identity at 1280 px: in the rail's Campaigns group and
// on the page for reports.view or performance.team (the agent gets the no-permission card and no journey); a card per
// journey, the archived one absent, each card inside the main area; the page never scrolls sideways; a journey's page
// with the Muted banner, seven dashed placeholder cards (the drill-down locked), its prerequisites unticked, the
// breadcrumbs Welcome › Campaigns › the journey and no figure; an archived or unknown journey not found; a tenant
// without journeys says so in words. --provoke widens the first card past the main area
async function expectCampaigns() {
  // [subject, sees Campaign monitoring, journeys]
  const cases = [["manager", true, 3], ["supervisor", true, 3], ["admin", true, 3], ["analyst", true, 3], ["reader", true, 3], ["invest-analyst", true, 0],
    ["agent-one", false, 0]];
  for (const [subject, may, count] of cases) {
    const ctx = await b.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": subject } });
    const p = await ctx.newPage();
    await p.goto(BASE + "/");
    await p.waitForLoadState("networkidle");
    const rail = await p.evaluate(() => [...(document.querySelector("nav")?.querySelectorAll("a") ?? [])].map((a) => a.getAttribute("href")));
    if (rail.includes("/campaigns") !== may) problems.push(`${subject}: Campaign monitoring ${may ? "missing from" : "shown in"} the rail`);
    await p.goto(BASE + "/campaigns");
    await p.waitForLoadState("networkidle");
    const m = await p.evaluate((spill) => {
      const cards = [...document.querySelectorAll('[data-testid="journey-card"]')];
      if (spill && cards[0]) cards[0].style.minWidth = "1400px";
      const main = document.querySelector("main");
      const edge = main.getBoundingClientRect().right;
      return {
        scrollX: document.documentElement.scrollWidth > window.innerWidth,
        codes: cards.map((c) => c.getAttribute("data-code")),
        outside: cards.filter((c) => c.getBoundingClientRect().right > edge + 0.5).length,
        empty: !!document.querySelector('[data-testid="journeys-empty"]'),
        noPermission: !!document.querySelector("main h2") && cards.length === 0 && !document.querySelector('[data-testid="journeys-empty"]'),
      };
    }, provoke && subject === "manager");
    if (m.scrollX) problems.push(`${subject} /campaigns: page scrolls horizontally at 1280`);
    if (!may) {
      if (m.codes.length > 0 || !m.noPermission) problems.push(`${subject} /campaigns: journeys shown to someone without the permission`);
      await ctx.close();
      continue;
    }
    if (m.codes.length !== count) problems.push(`${subject} /campaigns: ${m.codes.length} journeys, expected ${count}`);
    if (m.codes.includes("old-pilot")) problems.push(`${subject} /campaigns: the archived journey is shown`);
    if (count === 0 && !m.empty) problems.push(`${subject} /campaigns: a tenant without journeys does not say so in words`);
    if (m.outside > 0) problems.push(`${subject} /campaigns: ${m.outside} journey cards end outside the main area at 1280`);
    if (count > 0) {
      await p.screenshot({ path: `${outDir}/${subject}-campaigns.png`, fullPage: true });
      await p.locator('[data-testid="journey-card"][data-code="fca-uk-consumers"] h2 a').click();
      await p.waitForURL("**/campaigns/fca-uk-consumers");
      await p.waitForLoadState("networkidle");
      const d = await p.evaluate(() => {
        const banner = document.querySelector('[data-testid="journey-banner"]');
        const planned = [...document.querySelectorAll('[data-testid="planned-card"]')];
        return {
          scrollX: document.documentElement.scrollWidth > window.innerWidth,
          banner: banner ? { text: banner.textContent?.trim() ?? "", muted: banner.classList.contains("text-p4a-muted") } : null,
          planned: planned.map((c) => c.getAttribute("data-plan")),
          dashed: planned.filter((c) => getComputedStyle(c).borderTopStyle === "dashed").length,
          locked: !!document.querySelector('[data-plan="drillDown"] svg') && /Locked/.test(document.querySelector('[data-plan="drillDown"]')?.textContent ?? ""),
          prerequisites: document.querySelectorAll('[data-testid="journey-prerequisite"]').length,
          ticked: document.querySelectorAll('[data-testid="journey-prerequisites"] input:checked').length,
          figures: document.querySelectorAll("main table, main [data-tile]").length,
          design: document.querySelector('[data-testid="journey-design"]')?.getAttribute("target") ?? null,
        };
      });
      const where = `${subject} /campaigns/fca-uk-consumers`;
      if (d.scrollX) problems.push(`${where}: page scrolls horizontally at 1280`);
      if (!d.banner || !d.banner.text.startsWith("Placeholder: this monitor is not built yet") || !d.banner.muted) problems.push(`${where}: the Muted banner is missing (${JSON.stringify(d.banner)})`);
      if (JSON.stringify(d.planned) !== JSON.stringify(["coverage", "steps", "workflow", "attention", "drillDown", "life", "audit"]) || d.dashed !== 7) {
        problems.push(`${where}: placeholder cards ${JSON.stringify(d.planned)}, ${d.dashed} dashed, expected the seven in order, dashed`);
      }
      if (!d.locked) problems.push(`${where}: the customer drill-down is not shown as locked`);
      if (d.prerequisites !== 7 || d.ticked !== 0) problems.push(`${where}: ${d.prerequisites} prerequisites, ${d.ticked} ticked; expected 7, none ticked`);
      if (d.figures > 0) problems.push(`${where}: a placeholder shows a table or a tile`);
      if (d.design !== "_blank") problems.push(`${where}: the design link does not open in a new tab`);
      await p.screenshot({ path: `${outDir}/${subject}-campaign-fca.png`, fullPage: true });
      for (const code of ["old-pilot", "no-such-journey"]) {
        const r = await p.goto(BASE + `/campaigns/${code}`);
        if (r?.status() !== 404) problems.push(`${subject} /campaigns/${code}: answers ${r?.status()}, expected 404`);
      }
    }
    await ctx.close();
  }
  // the breadcrumbs of a journey's page: Welcome › Campaigns › the journey (the analyst, whose urgent message is read)
  const ctx = await b.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": "analyst" } });
  const p = await ctx.newPage();
  await p.goto(BASE + "/campaigns/opc");
  await p.waitForLoadState("networkidle");
  const crumbs = await p.evaluate(() => [...document.querySelectorAll('[data-testid="breadcrumbs"] li')].map((li) => li.textContent?.trim()));
  if (JSON.stringify(crumbs) !== JSON.stringify(["Welcome", "Campaigns", "OPC"])) problems.push(`analyst /campaigns/opc: breadcrumbs ${JSON.stringify(crumbs)}, expected Welcome › Campaigns › OPC`);
  await ctx.close();
}

// Callbacks kept (addition 0008w, brief N19-A part 4) at 1280 px: on Follow-up below the lists the eight weeks for
// reports.view or performance.team and the per-person table for performance.team only (the reader sees the weeks; the
// agent neither); both tables end inside their cards (they may scroll inside them); the weeks' right-most header hint
// stays inside the viewport; a tenant without a callback type says "No callback type set" in words, on Follow-up and
// on the Dashboard's Intake row, whose seventh tile it is. --provoke lets the weeks table spill out of its card
async function expectCallbacks() {
  // [subject, sees the weeks, sees per person, a callback type counted]
  const cases = [["manager", true, true, true], ["analyst", true, true, true], ["reader", true, false, true], ["invest-analyst", true, false, false],
    ["agent-one", false, false, true]];
  for (const [subject, weeks, owners, connected] of cases) {
    const ctx = await b.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": subject } });
    const p = await ctx.newPage();
    await p.goto(BASE + "/reports/follow-up");
    await p.waitForLoadState("networkidle");
    const where = `${subject} /reports/follow-up`;
    const m = await p.evaluate(([spill]) => {
      const inCard = (id) => {
        const box = document.querySelector(`[data-testid="${id}"]`);
        if (!box) return null;
        if (spill) { box.style.overflowX = "visible"; box.querySelector("table")?.setAttribute("style", "min-width: 1400px"); }
        const card = box.closest("section");
        const edge = card.getBoundingClientRect().right - parseFloat(getComputedStyle(card).paddingRight);
        return box.getBoundingClientRect().right > edge + 0.5 || (getComputedStyle(box).overflowX === "visible"
          && [...box.querySelectorAll("tr")].some((row) => row.getBoundingClientRect().right > edge + 0.5));
      };
      const main = document.querySelector("main");
      return {
        weeks: document.querySelectorAll('[data-testid="callbacks-weeks"]').length,
        weekRows: document.querySelectorAll('[data-testid="callbacks-week"]').length,
        owners: document.querySelectorAll('[data-testid="callbacks-owners"]').length,
        notConnected: !!document.querySelector('[data-testid="callbacks-not-connected"]'),
        spills: [inCard("callbacks-weeks-scroll"), inCard("callbacks-owners-scroll")],
        mainX: main ? main.scrollWidth - main.clientWidth : 0,
        scrollX: document.documentElement.scrollWidth > window.innerWidth,
      };
    }, [provoke && subject === "manager"]);
    if (m.scrollX || m.mainX > 0) problems.push(`${where}: the page or the main area scrolls sideways at 1280`);
    if ((m.weeks === 1) !== (weeks && connected)) problems.push(`${where}: the weeks table ${m.weeks ? "shown" : "missing"}`);
    if ((m.owners === 1) !== (owners && connected)) problems.push(`${where}: the per-person table ${m.owners ? "shown" : "missing"}`);
    if (m.notConnected !== (weeks && !connected)) problems.push(`${where}: "No callback type set" ${m.notConnected ? "shown" : "missing"}`);
    if (weeks && connected && m.weekRows !== 8) problems.push(`${where}: ${m.weekRows} weeks, expected the current one and the seven before`);
    if (m.spills.some((x) => x === true)) problems.push(`${where}: a callbacks table does not end inside its card at 1280`);
    if (subject === "manager") {
      const mark = p.locator('[data-testid="callbacks-weeks"] thead th:last-child button[data-header-hint]');
      if (await mark.count() !== 1) problems.push(`${where}: the weeks' right-most header hint is missing`);
      else {
        await mark.focus();
        const inside = await p.evaluate(() => {
          const el = document.activeElement;
          const panel = el && document.getElementById(el.getAttribute("aria-describedby") ?? "");
          if (!panel || panel.hidden) return null;
          const r = panel.getBoundingClientRect();
          return r.left >= 0 && r.top >= 0 && r.right <= window.innerWidth && r.bottom <= window.innerHeight;
        });
        if (inside !== true) problems.push(`${where}: the weeks' right-most header hint ${inside === null ? "does not show on focus" : "leaves the viewport"}`);
      }
      await p.screenshot({ path: `${outDir}/${subject}-follow-up-callbacks.png`, fullPage: true });
    }
    if (subject === "manager" || subject === "invest-analyst") {
      await p.goto(BASE + "/reports/dashboard?range=month");
      await p.waitForLoadState("networkidle");
      const tile = await p.evaluate(() => {
        const el = document.querySelector('[data-testid="intake-callbacks"]');
        return el ? { notConnected: !!el.querySelector('[data-testid="not-connected"]'), text: el.textContent ?? "" } : null;
      });
      if (!tile) problems.push(`${subject} /reports/dashboard: the Callbacks kept tile is missing from the Intake row`);
      else if (tile.notConnected !== !connected || (!connected && !tile.text.includes("No callback type set"))) {
        problems.push(`${subject} /reports/dashboard: the Callbacks kept tile ${connected ? "says not connected" : "does not say No callback type set"}`);
      }
    }
    await ctx.close();
  }
}

// Forms (addition 0008p, brief B17d), per identity at 1280 px: in the rail and on the page for reports.view or
// performance.team (the agent gets the no-permission card and no figures); the page never scrolls sideways;
// the keycaps K, A (Category, on Y until the period bar gained Yesterday on 26 October 2026), F, G and X next to the
// period bar's Y, T, W, M and C; four tiles; the forms table and the answers end inside
// their cards (they may scroll inside them); the right-most header's hint stays inside the viewport; the
// deltas say what they compare with, and before the fixture's forms history (six weeks back) "No history to
// compare yet" with the forms history's first date in the title. --provoke lets the forms table spill out of
// its card
async function expectForms() {
  const cases = [["manager", true], ["supervisor", true], ["admin", true], ["analyst", true], ["reader", true], ["invest-analyst", true], ["agent-one", false]];
  for (const [subject, may] of cases) {
    const ctx = await b.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": subject } });
    const p = await ctx.newPage();
    await p.goto(BASE + "/");
    await p.waitForLoadState("networkidle");
    const rail = await p.evaluate(() => [...(document.querySelector("nav")?.querySelectorAll("a") ?? [])].map((a) => a.getAttribute("href")));
    if (rail.includes("/reports/forms") !== may) problems.push(`${subject}: Forms ${may ? "missing from" : "shown in"} the rail`);
    const where = `${subject} /reports/forms`;
    await p.goto(BASE + "/reports/forms?range=month&group=day");
    await p.waitForLoadState("networkidle");
    const m = await p.evaluate((spill) => {
      const main = document.querySelector("main");
      const box = document.querySelector('[data-testid="forms-table-scroll"]');
      if (spill && box) { box.style.overflowX = "visible"; box.querySelector("table")?.setAttribute("style", "min-width: 1400px"); }
      const inside = (id) => {
        const b = document.querySelector(`[data-testid="${id}"]`);
        if (!b) return null;
        const card = b.closest("section");
        const edge = card.getBoundingClientRect().right - parseFloat(getComputedStyle(card).paddingRight);
        return b.getBoundingClientRect().right <= edge + 0.5 && (getComputedStyle(b).overflowX !== "visible" || b.scrollWidth <= b.clientWidth);
      };
      return {
        scrollX: document.documentElement.scrollWidth > window.innerWidth,
        mainX: main ? main.scrollWidth - main.clientWidth : -1,
        keycaps: [...document.querySelectorAll("main kbd")].map((k) => k.textContent?.trim()),
        tables: document.querySelectorAll("main table").length,
        tiles: document.querySelectorAll('[data-testid="forms-tiles"] [data-tile]').length,
        table: inside("forms-table-scroll"),
        answers: inside("forms-answers-scroll"),
      };
    }, provoke && subject === "manager");
    if (m.scrollX) problems.push(`${where}: page scrolls horizontally at 1280`);
    if (!may) {
      if (m.tables > 0 || m.tiles > 0) problems.push(`${where}: figures shown to someone without the permission`);
      await ctx.close();
      continue;
    }
    if (m.mainX > 0) problems.push(`${where}: the main area scrolls sideways by ${m.mainX}px at 1280`);
    for (const k of ["Y", "T", "W", "M", "C", "K", "A", "F", "G", "X"]) if (!m.keycaps.includes(k)) problems.push(`${where}: keycap ${k} missing`);
    if (m.tiles !== 4) problems.push(`${where}: ${m.tiles} tiles, expected 4`);
    if (m.table !== true) problems.push(`${where}: the forms table ${m.table === null ? "is missing" : "does not end inside its card at 1280"}`);
    if (m.answers !== true) problems.push(`${where}: the answers ${m.answers === null ? "are missing" : "do not end inside their card at 1280"}`);
    const mark = p.locator('[data-testid="forms-table"] thead th:last-child button[data-header-hint]');
    if (await mark.count() !== 1) problems.push(`${where}: header hint of the last column missing`);
    else {
      await mark.focus();
      const ok = await p.evaluate(() => {
        const el = document.activeElement;
        const panel = el && document.getElementById(el.getAttribute("aria-describedby") ?? "");
        if (!panel || panel.hidden) return null;
        const r = panel.getBoundingClientRect();
        return r.left >= 0 && r.top >= 0 && r.right <= window.innerWidth && r.bottom <= window.innerHeight;
      });
      if (ok === null) problems.push(`${where}: the header hint does not show on focus`);
      else if (!ok) problems.push(`${where}: the header hint leaves the viewport`);
    }
    await p.screenshot({ path: `${outDir}/${subject}-forms.png`, fullPage: true });
    if (subject === "manager") {
      // this week, still running, against the same point in the previous one; 30 days to yesterday, whose
      // previous span starts before the fixture's forms history (42 days back), against nothing
      const day = (n) => new Date(Date.now() + n * 86_400_000).toISOString().slice(0, 10);
      for (const [q, want] of [["range=week", "partial"], [`range=custom&from=${day(-30)}&to=${day(-1)}`, "none"]]) {
        await p.goto(`${BASE}/reports/forms?${q}`);
        await p.waitForLoadState("networkidle");
        const deltas = await p.evaluate(() => [...document.querySelectorAll('[data-testid="forms-tiles"] [data-testid="delta"]')].map((d) => ({
          compares: d.getAttribute("data-compares"), text: d.textContent?.trim() ?? "", title: d.getAttribute("title") ?? "" })));
        if (deltas.length !== 2 || deltas.some((d) => d.compares !== want)) problems.push(`${where}: the deltas of ${q.split("&")[0]} compare with ${deltas.map((d) => d.compares).join(",") || "nothing"}, expected ${want} twice`);
        if (want === "none" && deltas.some((d) => d.text !== "No history to compare yet" || !d.title.startsWith("The forms history starts on "))) {
          problems.push(`${where}: before the forms history the deltas do not say "No history to compare yet" with the forms history's first date`);
        }
      }
    }
    await ctx.close();
  }
}

// The Live board per identity (addition 0008i): at 1280 px the inbound tiles, the missed calls and the
// people board without horizontal scrolling, a tile's hint inside the viewport; a tenant without telephony
// says so in words; an agent gets the no-permission card and no inbound figures
async function expectLiveBoard() {
  for (const [subject, telephony] of [["supervisor", true], ["manager", true], ["admin", true], ["analyst", true], ["invest-analyst", false], ["agent-one", null]]) {
    const ctx = await b.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": subject } });
    const p = await ctx.newPage();
    await p.goto(BASE + "/live/board");
    await p.waitForLoadState("networkidle");
    if (telephony === null) {
      if (await p.locator('[data-testid="inbound-live"]').count() > 0) problems.push(`${subject} /live/board: inbound figures shown to someone without the Live board`);
      await ctx.close();
      continue;
    }
    if (provoke && subject === "supervisor") await p.evaluate(() => { const t = document.querySelector('[data-testid="inbound-tiles"]'); if (t) t.style.width = "2400px"; });
    // --provoke puts Missed, not called back back above the team (where it sat before 0008z)
    if (provoke && subject === "analyst") await p.evaluate(() => { const m = document.querySelector('[data-testid="missed-live"]'); const t = document.querySelector('[data-testid="inbound-live"]'); if (m && t) t.after(m); });
    const m = await p.evaluate((strip) => {
      const main = document.querySelector("main");
      // A name on a plain div or span needs a role (the tiles group, the IT audit of 17 October 2026); --provoke strips it
      if (strip) document.querySelector('main div[role="group"][aria-label]')?.removeAttribute("role");
      return {
        scrollX: document.documentElement.scrollWidth > window.innerWidth,
        mainX: main ? main.scrollWidth - main.clientWidth : -1,
        tiles: document.querySelectorAll('[data-testid="inbound-tiles"] [data-tile]').length,
        missed: !!document.querySelector('[data-testid="missed-callbacks"]'),
        notConnected: !!document.querySelector('[data-testid="inbound-live"] [data-testid="inbound-not-connected"]'),
        unnamedLabels: [...document.querySelectorAll("main div[aria-label], main span[aria-label]")].filter((el) => !el.getAttribute("role")).length,
        // Missed, not called back is the board's last section since 0008z: the last heading in main is its own
        lastHeading: [...document.querySelectorAll("main h2")].at(-1)?.closest('[data-testid="missed-live"]') !== null,
      };
    }, provoke && subject === "manager");
    if (m.unnamedLabels > 0) problems.push(`${subject} /live/board: ${m.unnamedLabels} div or span carries aria-label without a role`);
    if (m.scrollX) problems.push(`${subject} /live/board: page scrolls horizontally at 1280`);
    if (m.mainX > 0) problems.push(`${subject} /live/board: the main area scrolls sideways by ${m.mainX}px at 1280`);
    if (telephony && (m.tiles !== 7 || !m.missed)) problems.push(`${subject} /live/board: ${m.tiles} inbound tiles and ${m.missed ? "a" : "no"} missed-calls table, expected 7 and a table`);
    if (telephony && !m.lastHeading) problems.push(`${subject} /live/board: Missed, not called back is not the board's last section`);
    if (!telephony && (!m.notConnected || m.tiles > 0)) problems.push(`${subject} /live/board: a tenant without telephony must say so instead of showing tiles`);
    if (telephony) {
      const mark = p.locator('[data-testid="inbound-longestWaiting"] button[data-header-hint]');
      await mark.focus();
      const h = await p.evaluate(() => {
        const m = document.activeElement;
        const panel = m && document.getElementById(m.getAttribute("aria-describedby") ?? "");
        if (!panel || panel.hidden || getComputedStyle(panel).visibility !== "visible") return null;
        const r = panel.getBoundingClientRect();
        return r.left >= 0 && r.top >= 0 && r.right <= window.innerWidth && r.bottom <= window.innerHeight;
      });
      if (h === null) problems.push(`${subject} /live/board: the tile's hint does not show on focus`);
      else if (!h) problems.push(`${subject} /live/board: the tile's hint leaves the viewport`);
    }
    await p.screenshot({ path: `${outDir}/${subject}-live-board.png` });
    await ctx.close();
  }
}

// The frame is exactly the viewport (23 October 2026): main and the rail are the only scroll containers, and main is the
// containing block of the absolutely positioned content in it (the sr-only labels in table headers once stretched the
// document and showed an empty area below the frame). At 1280x800 and 1920x1080 on the Live board (with the fixture's missed
// calls), Speed to lead and Follow-up: after the wheel over main and End, with main at its bottom, the document is exactly the
// window and never scrolled; a page longer than main still scrolls in main by the wheel, down to its last line (the Live board
// is that page at 1280x800); a fixed element in
// the top bar (the toasts) and in main (the header hints) still sits against the window. At 1280x800 the rail's foot sits at
// its bottom; at 1280x600 with the longest group open the page stays put and the rail toggle is reached by scrolling the rail.
// --provoke puts the frame of before back (rows that grow with the rail, main not positioned, the rail not a scroll container)
async function expectFrameFixed() {
  const unfix = (p) => p.evaluate(() => {
    const frame = document.querySelector(".cma-frame");
    Object.assign(frame.style, { gridTemplateRows: "var(--spacing-topbar) 1fr", overflow: "visible" });
    Object.assign(document.querySelector("main").style, { position: "static", minHeight: "auto" });
    Object.assign(document.querySelector("nav[data-rail-nav]").style, { overflow: "visible", minHeight: "auto" });
  });
  const docOf = (p) => p.evaluate(() => ({ height: document.scrollingElement.scrollHeight, inner: window.innerHeight, y: window.scrollY }));
  for (const [width, height] of [[1280, 800], [1920, 1080]]) {
    const tag = `${width}x${height}`;
    for (const path of ["/live/board", "/reports/speed-to-lead?range=month", "/reports/follow-up"]) {
      const where = `manager ${path} at ${tag}`;
      const before = problems.length;
      const ctx = await b.newContext({ viewport: { width, height }, extraHTTPHeaders: { "x-cma-mock-subject": "manager" } });
      const p = await ctx.newPage();
      await p.goto(BASE + path);
      await p.waitForLoadState("networkidle");
      if (provoke) await unfix(p);
      if (path === "/live/board" && await p.locator('[data-testid="missed-callbacks"]').count() === 0) problems.push(`${where}: the fixture's missed calls are missing`);
      // The content's own height, before any scrolling: from the top of main's first child to the bottom of its last, with main's padding
      const natural = await p.evaluate(() => {
        const main = document.querySelector("main");
        const s = getComputedStyle(main);
        return main.lastElementChild.getBoundingClientRect().bottom - main.firstElementChild.getBoundingClientRect().top + parseFloat(s.paddingTop) + parseFloat(s.paddingBottom);
      });
      // As a person would: a click in the content, the wheel over it to the bottom, then End
      await p.locator("main h1").first().click();
      const box = await p.locator("main").boundingBox();
      await p.mouse.move(box.x + box.width / 2, box.y + Math.min(box.height, height - box.y) / 2);
      await p.mouse.wheel(0, 20000);
      await p.waitForTimeout(300);
      // what the wheel moved on its own, before main is set to its very bottom for End
      const wheeled = await p.evaluate(() => document.querySelector("main").scrollTop);
      await p.evaluate(() => { const main = document.querySelector("main"); main.scrollTop = main.scrollHeight; });
      await p.keyboard.press("End");
      await p.waitForTimeout(400);
      const m = await p.evaluate(() => {
        const main = document.querySelector("main");
        const r = main.getBoundingClientRect();
        // A probe with the toasts' position (bottom-6 right-6) in the top bar and in main's last table header, where the header
        // hints sit: both against the window
        const probes = [document.querySelector("header"), [...main.querySelectorAll("th")].at(-1) ?? main.lastElementChild].map((host) => {
          const el = document.createElement("div");
          Object.assign(el.style, { position: "fixed", right: "24px", bottom: "24px", width: "8px", height: "8px" });
          host.appendChild(el);
          const pr = el.getBoundingClientRect();
          el.remove();
          return Math.round(window.innerWidth - pr.right) === 24 && Math.round(window.innerHeight - pr.bottom) === 24;
        });
        return {
          scrollHeight: main.scrollHeight,
          clientHeight: main.clientHeight,
          lastBottom: main.lastElementChild.getBoundingClientRect().bottom,
          mainBottom: Math.min(r.bottom, window.innerHeight),
          probes,
        };
      });
      const doc = await docOf(p);
      if (doc.height !== doc.inner) problems.push(`${where}: the document is ${doc.height}px tall in a ${doc.inner}px window, so the page scrolls below the frame`);
      if (doc.y !== 0) problems.push(`${where}: the wheel and End scrolled the page by ${doc.y}px`);
      if (path === "/live/board" && tag === "1280x800" && natural <= m.clientHeight) problems.push(`${where}: the board fits in main (${Math.round(natural)}px in ${m.clientHeight}px), so the check has no page longer than the window`);
      if (natural > m.clientHeight) {
        if (m.scrollHeight <= m.clientHeight || wheeled <= 0) problems.push(`${where}: the content is ${Math.round(natural)}px in a ${m.clientHeight}px main, which the wheel does not scroll (scrollHeight ${m.scrollHeight}, moved ${wheeled}px)`);
        if (m.lastBottom > m.mainBottom + 1) problems.push(`${where}: at the bottom of main its last line ends at ${Math.round(m.lastBottom)}px, below main's ${Math.round(m.mainBottom)}px`);
      }
      if (m.probes.some((ok) => !ok)) problems.push(`${where}: a fixed element in the ${m.probes[0] ? "content" : "top bar"} no longer sits 24px from the window's bottom right`);
      const ok = problems.length === before;
      console.log(`${ok ? "PASS" : "FAIL"}  frame does not scroll: ${path} at ${tag}${natural > m.clientHeight ? ", main scrolls" : ", fits"}`);
      if (path === "/live/board") await p.screenshot({ path: `${outDir}/manager-live-board-bottom-${tag}.png` });
      await ctx.close();
    }
  }

  // The rail: its foot at the bottom while it fits (1280x800, no group open); at 1280x600 with the longest group open it
  // scrolls on its own, the page stays put and the rail toggle is reached
  {
    const before = problems.length;
    const ctx = await b.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": "manager" } });
    const p = await ctx.newPage();
    await p.goto(BASE + "/");
    await p.waitForLoadState("networkidle");
    if (provoke) await unfix(p);
    const foot = await p.evaluate(() => {
      const nav = document.querySelector("nav[data-rail-nav]");
      const fits = nav.scrollHeight <= nav.clientHeight;
      const gap = nav.getBoundingClientRect().bottom - parseFloat(getComputedStyle(nav).paddingBottom) - document.querySelector('[data-testid="rail-toggle"]').getBoundingClientRect().bottom;
      return { fits, gap: Math.round(gap) };
    });
    if (foot.fits && foot.gap !== 0) problems.push(`rail at 1280x800: the rail fits but its toggle sits ${foot.gap}px above the rail's foot`);
    await p.setViewportSize({ width: 1280, height: 600 });
    const longest = await p.evaluate(() => [...document.querySelectorAll('nav[data-rail-nav] ul[id^="nav-group-"]')]
      .map((u) => [u.id.slice("nav-group-".length), u.children.length]).sort((x, y) => y[1] - x[1])[0]?.[0]);
    await p.locator(`nav[data-rail-nav] button[aria-controls="nav-group-${longest}"]`).click();
    await p.waitForTimeout(200);
    if (provoke) await unfix(p);
    const nav = await p.locator("nav[data-rail-nav]").boundingBox();
    await p.mouse.move(nav.x + nav.width / 2, 300);
    await p.mouse.wheel(0, 5000);
    await p.waitForTimeout(400);
    const r = await p.evaluate(() => {
      const nav = document.querySelector("nav[data-rail-nav]");
      const n = nav.getBoundingClientRect();
      const t = document.querySelector('[data-testid="rail-toggle"]');
      const tr = t.getBoundingClientRect();
      const hit = document.elementFromPoint(tr.left + tr.width / 2, tr.top + tr.height / 2);
      return {
        taller: nav.scrollHeight > nav.clientHeight,
        scrolled: nav.scrollTop,
        inside: tr.top >= n.top && tr.bottom <= Math.min(n.bottom, window.innerHeight),
        hit: !!hit && t.contains(hit),
      };
    });
    const doc = await docOf(p);
    const where = `rail at 1280x600 with ${longest} open`;
    if (!r.taller || r.scrolled <= 0) problems.push(`${where}: the rail does not scroll on its own (taller ${r.taller}, scrollTop ${r.scrolled})`);
    if (doc.height !== doc.inner || doc.y !== 0) problems.push(`${where}: the page scrolls (document ${doc.height}px in ${doc.inner}px, scrolled ${doc.y}px)`);
    if (!r.inside || !r.hit) problems.push(`${where}: the rail toggle is not reached by scrolling the rail`);
    console.log(`${problems.length === before ? "PASS" : "FAIL"}  frame does not scroll: the rail at 1280x600 with ${longest} open`);
    await p.screenshot({ path: `${outDir}/manager-rail-1280x600.png` });
    await ctx.close();
  }
}

async function expectGate(width, height) {
  const p = await b.newPage({ viewport: { width, height } });
  await p.goto(BASE + "/");
  const gate = await p.locator('[data-testid="desktop-only"]').isVisible();
  const shell = await p.locator("nav").isVisible();
  if (!gate || shell) problems.push(`${width}x${height}: expected the desktop-only gate, got the app`);
  await p.screenshot({ path: `${outDir}/${width}x${height}-gate.png` });
  await p.close();
}

// Sources, Markets and Alert rules (addition 0008e): at 1280 px as the admin, the shell without horizontal
// scrolling, the main area never sideways, the page's own keycaps, and its tables there; on a connection's
// page every table inside its card (addition 0008i)
async function expectIntakeConfiguration() {
  const cases = [
    // since addition 0008p the form categories follow the connections, with Add category (A)
    ["/configuration/sources", ["A"], ['[data-testid="sources"]', '[data-testid="form-categories"]']],
    // since addition 0008zc no O: the call outcomes' rule went with their connected switch (W14)
    ["/configuration/sources/00000000-0000-7000-8000-00000000c001", ["B", "N", "S", "F"], '[data-testid="source-forms"]'],
    ["/configuration/sources/00000000-0000-7000-8000-00000000c002", ["B", "N", "S"], '[data-testid="source-lines"]'],
    ["/configuration/sources/00000000-0000-7000-8000-00000000c003", ["B", "N", "S", "A"], '[data-testid="source-store"]'],
    ["/configuration/markets", ["A", "I", "H"], '[data-testid="office-hours"]'],
    ["/configuration/alert-rules", ["A"], '[data-testid="alert-rules"]'],
  ];
  for (const [path, keys, selector] of cases) {
    const ctx = await b.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": "admin" } });
    const p = await ctx.newPage();
    await p.goto(BASE + path);
    await p.waitForLoadState("networkidle");
    const m = await p.evaluate((spill) => {
      if (spill) document.querySelector("main table")?.setAttribute("style", "min-width: 2000px");
      const main = document.querySelector("main");
      return {
        scrollX: document.documentElement.scrollWidth > window.innerWidth,
        mainX: main ? main.scrollWidth - main.clientWidth : -1,
        rail: document.querySelector("nav")?.getBoundingClientRect().width ?? 0,
        keycaps: [...document.querySelectorAll("main kbd")].map((k) => k.textContent?.trim()),
      };
    }, provoke && path === "/configuration/alert-rules");
    if (m.scrollX) problems.push(`admin ${path}: page scrolls horizontally at 1280`);
    if (m.mainX > 0) problems.push(`admin ${path}: the main area scrolls sideways by ${m.mainX}px at 1280`);
    if (Math.round(m.rail) !== 256) problems.push(`admin ${path}: rail is ${m.rail}px`);
    for (const k of keys) if (!m.keycaps.includes(k)) problems.push(`admin ${path}: keycap ${k} missing`);
    for (const one of [selector].flat()) if (await p.locator(one).count() === 0) problems.push(`admin ${path}: ${one} missing`);
    // A connection's page (docs/style/Pulse4all-Style.md 7.3 and 7.6): every table ends inside its card's
    // padding and none needs to scroll at 1280; --provoke widens the missed-reason table
    if (path.startsWith("/configuration/sources/")) {
      const spilt = await p.evaluate((widen) => {
        if (widen) document.querySelector('[data-testid="source-missed-reasons"]')?.setAttribute("style", "min-width: 1400px");
        return [...document.querySelectorAll("main section table")].filter((t) => {
          const card = t.closest("section");
          const box = t.parentElement;
          const edge = card.getBoundingClientRect().right - parseFloat(getComputedStyle(card).paddingRight);
          return t.getBoundingClientRect().right > edge + 0.5 || box.scrollWidth > box.clientWidth;
        }).map((t) => t.dataset.testid ?? "a table");
      }, provoke && path.endsWith("c002"));
      for (const id of spilt) problems.push(`admin ${path}: ${id} does not fit its card at 1280`);
    }
    const name = path.split("/").slice(2).join("-").replace(/00000000-0000-7000-8000-00000000/, "");
    await p.screenshot({ path: `${outDir}/admin-${name}.png`, fullPage: true });
    await ctx.close();
  }
}

// Invitations (addition 0008l, 15 October 2026): People at 1280 px as the admin with the Invitations section
// below the people, its table inside its card, the keycaps V (Invite) and A (Add a person); V opens the
// dialog inside the viewport with every role the admin may give, and the manager's dialog offers only the
// roles it may grant; /invite/<token> for an account that is no person yet (the mock's invitee identities)
// in its four states, open (Accept focused), another account, expired and invalid, each one card inside
// the viewport without horizontal scrolling, and a person of the main tenant opening the second tenant's link
// (other_tenant). --provoke lets the invitations table spill out of its card and opens the expired link
// expecting it open
async function expectInvitations() {
  const TOKENS = { open: "mock-open-invitation".padEnd(43, "0"), expired: "mock-expired-invitation".padEnd(43, "0") };
  for (const subject of ["admin", "manager"]) {
    const ctx = await b.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": subject } });
    const p = await ctx.newPage();
    await p.goto(BASE + "/team/people");
    await p.waitForLoadState("networkidle");
    const m = await p.evaluate((spill) => {
      const section = document.querySelector('[data-testid="invitations"]');
      const table = section?.querySelector("table");
      if (spill && table) table.setAttribute("style", "min-width: 2400px");
      const main = document.querySelector("main");
      const edge = section ? section.getBoundingClientRect().right - parseFloat(getComputedStyle(section).paddingRight) : 0;
      return {
        section: !!section,
        rows: section?.querySelectorAll('[data-testid="invitation-row"]').length ?? 0,
        tableFits: !table || (table.getBoundingClientRect().right <= edge + 0.5 && table.parentElement.scrollWidth <= table.parentElement.clientWidth),
        scrollX: document.documentElement.scrollWidth > window.innerWidth,
        mainX: main ? main.scrollWidth - main.clientWidth : -1,
        keycaps: [...document.querySelectorAll("main kbd")].map((k) => k.textContent?.trim()),
      };
    }, provoke && subject === "admin");
    if (!m.section) problems.push(`${subject} /team/people: the Invitations section is missing`);
    if (m.rows === 0) problems.push(`${subject} /team/people: no invitation listed`);
    if (!m.tableFits) problems.push(`${subject} /team/people: the invitations table does not fit its card at 1280`);
    if (m.scrollX || m.mainX > 0) problems.push(`${subject} /team/people: scrolls sideways at 1280`);
    for (const k of ["V", "A"]) if (!m.keycaps.includes(k)) problems.push(`${subject} /team/people: keycap ${k} missing`);
    await p.locator('[data-testid="invitations"]').scrollIntoViewIfNeeded();
    await p.screenshot({ path: `${outDir}/${subject}-people-invitations.png` });
    await p.keyboard.press("v");
    await p.locator('[data-testid="invite-dialog"][open]').waitFor({ timeout: 5000 }).catch(() => undefined);
    const d = await p.evaluate(() => {
      const dialog = document.querySelector('[data-testid="invite-dialog"][open]');
      if (!dialog) return null;
      const r = dialog.getBoundingClientRect();
      return {
        inside: r.top >= 0 && r.left >= 0 && r.bottom <= window.innerHeight + 0.5 && r.right <= window.innerWidth + 0.5,
        roles: [...dialog.querySelectorAll('[data-testid="invite-role"] option')].map((o) => o.value).filter(Boolean),
        focus: document.activeElement?.getAttribute("type"),
      };
    });
    const wantRoles = subject === "admin" ? ["agent", "analytics", "supervisor", "manager", "admin"] : ["agent", "analytics", "supervisor"];
    if (!d) problems.push(`${subject} /team/people: V does not open the Invite dialog`);
    else {
      await expectDialogNamed(p, `${subject} Invite dialog`);
      if (!d.inside) problems.push(`${subject} Invite dialog: not inside the viewport at 1280 x 800`);
      if (JSON.stringify(d.roles) !== JSON.stringify(wantRoles)) problems.push(`${subject} Invite dialog: roles ${d.roles.join(",")}, wanted ${wantRoles.join(",")}`);
      if (d.focus !== "email") problems.push(`${subject} Invite dialog: does not open on the email field`);
    }
    await p.screenshot({ path: `${outDir}/${subject}-invite-dialog.png` });
    await ctx.close();
  }
  const states = [
    ["invitee-one", TOKENS.open, "open"],
    ["invitee-other", TOKENS.open, "wrong_account"],
    ["invitee-one", TOKENS.expired, provoke ? "open" : "expired"],
    ["invitee-one", "mock-no-such-invitation".padEnd(43, "0"), "invalid"],
    // a person of the main tenant opening the second tenant's link: no second business line without a tenant picker
    ["admin", "mock-tenant-two-invitation".padEnd(43, "0"), "other_tenant"],
  ];
  for (const [subject, token, state] of states) {
    const ctx = await b.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": subject } });
    const p = await ctx.newPage();
    await p.goto(`${BASE}/invite/${token}`);
    await p.waitForLoadState("networkidle");
    const m = await p.evaluate(() => {
      const card = document.querySelector('[data-testid^="invite-"]');
      const r = card?.getBoundingClientRect();
      return {
        state: card?.getAttribute("data-testid")?.slice("invite-".length) ?? null,
        inside: !!r && r.top >= 0 && r.bottom <= window.innerHeight && r.right <= window.innerWidth,
        scrollX: document.documentElement.scrollWidth > window.innerWidth,
        focus: document.activeElement?.tagName === "BUTTON" ? document.activeElement.textContent?.trim() : null,
        rail: !!document.querySelector("nav"),
      };
    });
    if (m.state !== state) problems.push(`/invite as ${subject}: shows ${m.state}, wanted ${state}`);
    if (!m.inside || m.scrollX) problems.push(`/invite ${state}: the card is not inside the viewport at 1280`);
    if (m.rail) problems.push(`/invite ${state}: shows the Workspace's navigation to someone who is no person yet`);
    if (state === "open" && !(m.focus ?? "").startsWith("Accept")) problems.push("/invite open: Accept is not focused");
    await p.screenshot({ path: `${outDir}/invite-${state}.png` });
    await ctx.close();
  }
}

// Irreversible confirmations (B9a.1, 13 October 2026; README Decision log): a confirmation that removes data
// or changes it for good opens on Cancel, so Enter at open cancels; its confirm button is the destructive
// secondary style (the error colour, outlined) without a keycap. On Lines, as the admin: Enter at open does
// not call the lines route, and the box stays ticked while the confirmation is open and changes only after
// a confirmed save (then it is ticked again, so the mock stands as before). Dissolve on Teams (the admin)
// and Copy previous week on the planner (the manager): Cancel at open, the style, Enter cancels without a
// write. --provoke moves the focus to the confirm button before measuring (the old default) and unticks
// the box while the confirmation is open, so every check here fails. End workday, an ordinary
// confirmation, last
async function expectIrreversibleConfirmations() {
  const state = (p) => p.evaluate(() => {
    const d = document.querySelector("dialog[open]");
    if (!d) return null;
    const confirm = d.querySelector("[data-confirm]") ?? d.querySelector("button"); // the confirm button comes first
    return {
      cancelFocused: document.activeElement?.hasAttribute("data-confirm-cancel") ?? false,
      destructive: !!confirm && confirm.className.includes("border-p4a-error") && !confirm.className.includes("bg-p4a-deepblue"),
      keycap: !!confirm?.querySelector("kbd"),
    };
  });
  const oldDefault = (p) => p.evaluate(() => document.querySelector("dialog[open] button")?.focus());
  const check = (where, s) => {
    if (!s) return problems.push(`${where}: the confirmation did not open`);
    if (!s.cancelFocused) problems.push(`${where}: the confirmation does not open on Cancel`);
    if (!s.destructive) problems.push(`${where}: the confirm button is not the destructive secondary style`);
    if (s.keycap) problems.push(`${where}: the confirm button shows a keycap`);
  };

  // Lines: the full flow
  {
    const ctx = await b.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": "admin" } });
    const p = await ctx.newPage();
    const puts = [];
    p.on("request", (r) => { if (r.method() === "PUT" && new URL(r.url()).pathname.endsWith("/lines")) puts.push(r.postDataJSON()); });
    await p.goto(BASE + "/configuration/sources/00000000-0000-7000-8000-00000000c002");
    await p.waitForLoadState("networkidle");
    const box = p.locator('[data-testid="source-lines"] input[type="checkbox"]').first();
    const dialog = p.locator("dialog[open]");
    if (!(await box.isChecked())) problems.push("lines: the first line of the mock does not count at the start");
    await box.click();
    await dialog.waitFor({ timeout: 5000 }).catch(() => undefined);
    if (provoke) await oldDefault(p);
    check("lines", await state(p));
    await expectDialogNamed(p, "lines");
    if (provoke) await box.evaluate((el) => { el.checked = false; });
    if (!(await box.isChecked())) problems.push("lines: the box is unticked while the confirmation is open");
    await p.keyboard.press("Enter");
    await p.waitForTimeout(800);
    if (puts.length) problems.push(`lines: Enter at open called the lines route with ${JSON.stringify(puts)}`);
    if (await dialog.count()) problems.push("lines: Enter at open left the confirmation open");
    if (!(await box.isChecked())) problems.push("lines: the box is unticked after Enter at open");
    if (!provoke) {
      // confirmed: the save goes out once, then the box shows the line switched off
      if (await box.isChecked()) {
        await box.click();
        const asked = await dialog.waitFor({ timeout: 5000 }).then(() => true, () => false);
        if (!asked) problems.push("lines: unticking a counted line did not ask for confirmation");
        else {
          if (!(await box.isChecked())) problems.push("lines: the box is unticked before the switch-off is confirmed");
          await dialog.locator("button").first().click();
          await p.waitForFunction(() => !document.querySelector('[data-testid="source-lines"] input[type="checkbox"]')?.checked, null, { timeout: 5000 }).catch(() => undefined);
          if (JSON.stringify(puts.map((x) => x?.isCounted)) !== "[false]") problems.push(`lines: a confirmed switch-off sent ${JSON.stringify(puts)}`);
          if (await box.isChecked()) problems.push("lines: the box is still ticked after a confirmed switch-off");
        }
      }
    }
    // tick it again (switching on does not ask), so the mock stands as before
    if (!(await box.isChecked())) {
      await box.click();
      await p.waitForFunction(() => document.querySelector('[data-testid="source-lines"] input[type="checkbox"]')?.checked, null, { timeout: 5000 }).catch(() => undefined);
      if (await dialog.count()) problems.push("lines: switching a line on asked for confirmation");
    }
    // The stored calls it removes (backlog CMA-020, addition 0008y): while the count loads the confirm button is disabled
    // and Cancel works; then the question names the count; a failed read says so in the error colour, names no number and
    // keeps the button disabled. Nothing is written. --provoke expects the button enabled while the count loads
    {
      const confirm = dialog.locator("[data-confirm]");
      const before = puts.length;
      let release = () => {};
      await p.route("**/lines/stored-calls**", async (route) => { await new Promise((r) => { release = r; }); await route.continue(); });
      await box.click();
      await dialog.waitFor({ timeout: 5000 }).catch(() => undefined);
      const counting = await dialog.locator('[data-testid="line-off-counting"][role="status"]').count();
      const waiting = await confirm.isDisabled().catch(() => null);
      if (counting !== 1 || waiting !== !provoke) problems.push(`lines: while the count loads the dialog shows ${counting} counting line and the confirm button is ${waiting ? "disabled" : "enabled"}, expected one and ${provoke ? "enabled" : "disabled"}`);
      release();
      const shown = await dialog.locator('[data-testid="line-off-count"]').waitFor({ timeout: 5000 }).then(() => true, () => false);
      const count = shown ? await dialog.locator('[data-testid="line-off-count"]').evaluate((el) => ({ n: el.getAttribute("data-stored-calls"), text: el.textContent ?? "" })) : null;
      if (!count || !/^\d+$/.test(count.n ?? "") || !count.text.includes(Number(count.n).toLocaleString("en-GB"))) problems.push(`lines: the question names no stored-calls count once read (${JSON.stringify(count)})`);
      if (await confirm.isDisabled().catch(() => true)) problems.push("lines: the confirm button stays disabled once the count is read");
      await p.keyboard.press("Escape");
      await p.waitForTimeout(300);
      await p.unroute("**/lines/stored-calls**");
      await p.route("**/lines/stored-calls**", (route) => route.fulfill({ status: 500, contentType: "application/json", body: JSON.stringify({ error: { code: "internal" } }) }));
      await box.click();
      await dialog.waitFor({ timeout: 5000 }).catch(() => undefined);
      const failed = await dialog.locator('[data-testid="line-off-failed"][role="alert"]').waitFor({ timeout: 5000 }).then(() => true, () => false);
      const failedText = failed ? await dialog.locator('[data-testid="line-off-failed"]').evaluate((el) => ({ text: el.textContent ?? "", error: el.classList.contains("text-p4a-error") })) : null;
      if (!failedText || !failedText.error || /\d[\d,.]*\s+stored call/.test(failedText.text)) problems.push(`lines: a failed count read shows ${JSON.stringify(failedText)}, expected the error copy in the error colour without a number`);
      if (!(await confirm.isDisabled().catch(() => false))) problems.push("lines: the confirm button is enabled after a failed count read");
      await dialog.locator("[data-confirm-cancel]").click();
      await p.waitForTimeout(300);
      await p.unroute("**/lines/stored-calls**");
      if (await dialog.count()) problems.push("lines: Cancel does not close the confirmation after a failed count read");
      if (puts.length !== before) problems.push(`lines: reading the count wrote ${JSON.stringify(puts.slice(before))}`);
      if (!(await box.isChecked())) problems.push("lines: the box is unticked after the count checks");
    }
    await ctx.close();
  }

  // Dissolve on Teams, Copy previous week on the planner: open, measure, Enter (Esc when provoked: no write)
  const cases = [
    ["admin", "/configuration/teams", "Dissolve on Teams", (p) => p.locator("main button", { hasText: /^Dissolve$/ }).first().click()],
    ["manager", "/roster/planner", "Copy previous week on the planner", (p) => p.keyboard.press("c")],
  ];
  for (const [subject, path, where, open] of cases) {
    const ctx = await b.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": subject } });
    const p = await ctx.newPage();
    const writes = [];
    p.on("request", (r) => { if (r.method() !== "GET" && new URL(r.url()).pathname.startsWith("/api/v1/") && !new URL(r.url()).pathname.startsWith("/api/v1/me/messages")) writes.push(`${r.method()} ${new URL(r.url()).pathname}`); });
    await p.goto(BASE + path);
    await p.waitForLoadState("networkidle");
    await open(p);
    await p.locator("dialog[open]").waitFor({ timeout: 5000 }).catch(() => undefined);
    if (provoke) await oldDefault(p);
    check(where, await state(p));
    await expectDialogNamed(p, where);
    await p.keyboard.press(provoke ? "Escape" : "Enter");
    await p.waitForTimeout(500);
    if (writes.length) problems.push(`${where}: Enter at open wrote ${JSON.stringify(writes)}`);
    if (await p.locator("dialog[open]").count()) problems.push(`${where}: Enter at open left the confirmation open`);
    await ctx.close();
  }
  // End workday on My day is an ordinary confirmation (a workday ended by mistake is corrected, README
  // Decision log, 13 October 2026): it opens on its confirm button, the primary style with the Enter keycap,
  // so E then Enter ends the day. agent-two clocks in through the route, as in the theme verifier (inside
  // the mock's workday window, 07:00 to 22:00); the dialog is closed with Esc, so the day is never ended
  // here and a rerun finds it open. --provoke moves the focus to Cancel first
  {
    const start = await fetch(BASE + "/api/v1/me/day/start", { method: "POST", headers: { "x-cma-mock-subject": "agent-two", "x-cma-request": "1" } });
    if (!start.ok) problems.push(`End workday: agent-two could not clock in (${start.status}; the mock's workday window is 07:00 to 22:00)`);
    else {
      const ctx = await b.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": "agent-two" } });
      const p = await ctx.newPage();
      const writes = [];
      p.on("request", (r) => { const u = new URL(r.url()); if (r.method() !== "GET" && u.pathname.startsWith("/api/v1/") && !u.pathname.startsWith("/api/v1/me/messages")) writes.push(`${r.method()} ${u.pathname}`); });
      await p.goto(BASE + "/day");
      await p.waitForLoadState("networkidle");
      await p.keyboard.press("e");
      await p.locator("dialog[open]").waitFor({ timeout: 5000 }).catch(() => undefined);
      if (provoke) await p.evaluate(() => document.querySelector("dialog[open] button:last-of-type")?.focus());
      const s = await p.evaluate(() => {
        const d = document.querySelector("dialog[open]");
        const confirm = d?.querySelector("button"); // the confirm button comes first
        return d ? { confirmFocused: document.activeElement === confirm, primary: !!confirm?.className.includes("bg-p4a-deepblue"),
                     keycap: confirm?.querySelector("kbd")?.textContent?.trim() ?? null } : null;
      });
      if (!s) problems.push("End workday: E did not open the confirmation");
      else {
        await expectDialogNamed(p, "End workday");
        if (!s.confirmFocused) problems.push("End workday: the confirmation does not open on its confirm button");
        if (!s.primary || s.keycap !== "Enter") problems.push(`End workday: the confirm button is not the primary style with the Enter keycap (${JSON.stringify(s)})`);
      }
      await p.keyboard.press("Escape");
      await p.waitForTimeout(500);
      if (writes.length) problems.push(`End workday: opening and closing the confirmation wrote ${JSON.stringify(writes)}`);
      await ctx.close();
    }
  }
}

// The frame's preferences, the breadcrumbs, preview as role and the roster's week bar (16 October 2026)
async function expectFrame() {
  const host = new URL(BASE).hostname;
  const withCookies = async (subject, cookies) => {
    const ctx = await b.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": subject } });
    await ctx.addCookies(Object.entries(cookies).map(([name, value]) => ({ name, value, domain: host, path: "/" })));
    return ctx;
  };
  const jarOf = async (ctx) => Object.fromEntries((await ctx.cookies()).map((c) => [c.name, c.value]));
  const railOf = (p) => p.evaluate(() => {
    const nav = document.querySelector("nav[data-rail-nav]");
    const vis = (el) => el.getClientRects().length > 0;
    const links = [...nav.querySelectorAll("a[data-shortcut]")];
    // the bare pages and the group buttons: what the folded rail shows (a group's pages are hidden then)
    const shown = [...nav.querySelectorAll(":scope > ul > li > a[data-shortcut], :scope > ul > li > button")];
    const toggle = document.querySelector('[data-testid="rail-toggle"]');
    return {
      width: Math.round(nav.getBoundingClientRect().width),
      state: document.querySelector("[data-rail]")?.getAttribute("data-rail"),
      labelsVisible: links.filter((a) => [...a.querySelectorAll("[data-rail-text]")].some(vis)).length,
      keycapsVisible: [...nav.querySelectorAll("kbd")].filter(vis).length,
      named: shown.every((el) => /\S/.test(el.getAttribute("aria-label") ?? "") && el.getAttribute("title") === el.getAttribute("aria-label"))
        && shown.filter((el) => el.tagName === "A").every((a) => /\(\d+\)$/.test(a.getAttribute("aria-label") ?? "")),
      keyshortcuts: links.every((a) => a.getAttribute("aria-keyshortcuts") === a.getAttribute("data-shortcut")),
      footVisible: [...nav.querySelectorAll("[data-shortcuts-hint]")].some(vis),
      toggle: { expanded: toggle?.getAttribute("aria-expanded"), key: toggle?.getAttribute("aria-keyshortcuts"), shortcut: toggle?.getAttribute("data-shortcut") },
      heights: [...new Set(shown.filter(vis).map((el) => Math.round(el.getBoundingClientRect().height)))],
      currentPill: !!nav.querySelector('a[aria-current="page"].bg-white, button[data-current="true"]'),
    };
  });

  // 1. The default: unfolded, named for assistive tech; W folds it; the keys still work; a group unfolds it
  {
    const ctx = await withCookies("manager", {});
    const p = await ctx.newPage();
    await p.goto(BASE + "/");
    await p.waitForLoadState("networkidle");
    const r = await railOf(p);
    if (r.width !== 256 || r.state !== "expanded") problems.push(`rail: the default is ${r.state} at ${r.width}px, expected expanded at 256`);
    if (r.labelsVisible === 0 || r.keycapsVisible === 0) problems.push("rail: labels or keycaps missing from the unfolded rail");
    if (!r.keyshortcuts || !r.named) problems.push("rail: a link lacks aria-keyshortcuts, or a title and aria-label naming its key");
    if (r.toggle.expanded !== "true" || r.toggle.key !== "W" || r.toggle.shortcut !== "w") problems.push(`rail toggle: ${JSON.stringify(r.toggle)}, expected aria-expanded true and W`);
    const top = await p.evaluate(() => ({
      logout: document.querySelector('header a[href="/logout"]')?.getAttribute("aria-keyshortcuts"),
      hints: document.querySelector('[data-testid="hints-toggle"]')?.getAttribute("aria-keyshortcuts"),
      pressed: document.querySelector('[data-testid="hints-toggle"]')?.getAttribute("aria-pressed"),
    }));
    if (top.logout !== "L" || top.hints !== "?" || top.pressed !== "false") problems.push(`top bar: ${JSON.stringify(top)}, expected L, ? and the hints shown`);
    if ((await p.locator('[data-testid="breadcrumbs"]').count()) !== (provoke ? 1 : 0)) problems.push("breadcrumbs: Welcome shows a trail");
    await p.keyboard.press("w");
    await p.waitForTimeout(200);
    const folded = await railOf(p);
    if (folded.width !== (provoke ? 256 : 64) || folded.state !== "collapsed") problems.push(`rail: after W it is ${folded.state} at ${folded.width}px, expected collapsed at 64`);
    if (folded.labelsVisible > 0 || folded.keycapsVisible > 0 || folded.footVisible) problems.push("rail: labels, keycaps or the foot still visible when folded");
    if (folded.heights.some((h) => h !== 40)) problems.push(`rail: folded items are ${folded.heights.join(",")}px tall, expected 40`);
    if (folded.toggle.expanded !== "false") problems.push("rail toggle: aria-expanded stays true when folded");
    const cookie = (await ctx.cookies()).find((c) => c.name === "cma-rail");
    if (cookie?.value !== "collapsed" || cookie.path !== "/") problems.push(`rail: the cookie is ${JSON.stringify(cookie)}, expected cma-rail=collapsed on /`);
    await p.keyboard.press("2");
    await p.waitForURL("**/messages").catch(() => undefined);
    if (new URL(p.url()).pathname !== "/messages") problems.push("rail: key 2 does not open Messages while folded");
    await p.waitForLoadState("networkidle");
    const next = await railOf(p);
    if (next.width !== 64) problems.push(`rail: the next page renders at ${next.width}px; the cookie was not read on the server`);
    if (!next.currentPill) problems.push("rail: the current page lost its white pill when folded");
    await p.screenshot({ path: `${outDir}/manager-rail-folded.png` });
    await p.locator('nav[data-rail-nav] button[aria-controls="nav-group-reports"]').click();
    await p.waitForTimeout(200);
    const open = await p.evaluate(() => ({
      width: Math.round(document.querySelector("nav[data-rail-nav]").getBoundingClientRect().width),
      expanded: document.querySelector('button[aria-controls="nav-group-reports"]')?.getAttribute("aria-expanded"),
    }));
    const jar = await jarOf(ctx);
    if (open.width !== 256 || open.expanded !== "true" || jar["cma-rail"] !== "expanded" || jar["cma-nav-open"] !== "reports") {
      problems.push(`rail: a group's click gave ${JSON.stringify({ ...open, rail: jar["cma-rail"], group: jar["cma-nav-open"] })}, expected the rail unfolded and the group open, both cookies written`);
    }
    await ctx.close();
  }

  // 2. Folded by cookie at first paint, on a report page: 64 px, no wider content, no horizontal scrolling
  {
    const ctx = await withCookies("manager", { "cma-rail": "collapsed" });
    const p = await ctx.newPage();
    await p.goto(BASE + "/reports/inbound?range=month");
    await p.waitForLoadState("networkidle");
    const r = await railOf(p);
    if (r.width !== 64 || r.labelsVisible > 0) problems.push(`rail: with the cookie Inbound renders at ${r.width}px with ${r.labelsVisible} labels, expected 64 and none`);
    const c = await p.evaluate(() => ({ scrollX: document.documentElement.scrollWidth > window.innerWidth, column: Math.round(document.querySelector("main > div:last-child")?.getBoundingClientRect().width ?? 0) }));
    if (c.scrollX) problems.push("rail: folded, Inbound scrolls horizontally at 1280");
    if (c.column <= 0 || c.column > 1536) problems.push(`rail: folded, the content column is ${c.column}px (max-w-screen-2xl is 1536)`);
    await p.screenshot({ path: `${outDir}/manager-inbound-rail-folded.png` });
    await ctx.close();
  }

  // 3. Hints hidden by cookie: no keycap, no shortcuts line, the keys still work, ? shows them again; and the
  // roster's week bar (backlog CMA-061): three links on one line, one range label, the keywords, the placeholder
  {
    const ctx = await withCookies("manager", { "cma-hints": "hidden" });
    const p = await ctx.newPage();
    await p.goto(BASE + "/roster/planner");
    await p.waitForLoadState("networkidle");
    const m = await p.evaluate(() => {
      // Log out's keycap and the shortcuts line keep their space, invisible (19 October 2026)
      const vis = (el) => el.getClientRects().length > 0 && getComputedStyle(el).visibility !== "hidden";
      return {
        kbd: [...document.querySelectorAll("kbd")].filter(vis).length,
        hint: [...document.querySelectorAll("[data-shortcuts-hint]")].some(vis),
        pressed: document.querySelector('[data-testid="hints-toggle"]')?.getAttribute("aria-pressed"),
        state: document.querySelector("[data-hints]")?.getAttribute("data-hints"),
      };
    });
    if (m.kbd !== (provoke ? 1 : 0) || m.hint || m.pressed !== "true" || m.state !== "hidden") problems.push(`hints: hidden by cookie gives ${JSON.stringify(m)}, expected no keycap, no shortcuts line, the toggle pressed`);
    await p.keyboard.press("n");
    await p.waitForURL("**/roster/planner?**").catch(() => undefined);
    if (!new URL(p.url()).searchParams.get("week")) problems.push("hints: N no longer moves to the next week while the keycaps are hidden");
    await p.waitForLoadState("networkidle");
    await p.keyboard.press("?");
    await p.waitForTimeout(200);
    const after = await p.evaluate(() => ({ kbd: [...document.querySelectorAll("kbd")].filter((el) => el.getClientRects().length > 0).length, pressed: document.querySelector('[data-testid="hints-toggle"]')?.getAttribute("aria-pressed") }));
    const jar = await jarOf(ctx);
    if (after.kbd === 0 || after.pressed !== "false" || jar["cma-hints"] !== "shown") problems.push(`hints: ? gives ${JSON.stringify({ ...after, cookie: jar["cma-hints"] })}, expected the keycaps back and cma-hints=shown`);
    const bar = await p.evaluate(() => {
      const links = [...document.querySelectorAll('main nav a[data-shortcut="p"], main nav a[data-shortcut="w"], main nav a[data-shortcut="n"]')];
      return {
        n: links.length,
        lines: new Set(links.map((a) => Math.round(a.getBoundingClientRect().top))).size,
        label: document.querySelector('[data-testid="week-label"]')?.textContent ?? "",
        keywords: document.querySelector('[data-testid="absence-keywords"]')?.textContent ?? "",
        placeholder: document.querySelector("main input[data-cell]")?.getAttribute("placeholder") ?? "",
      };
    });
    if (bar.n !== 3 || bar.lines !== 1) problems.push(`roster: the week links are ${bar.n} on ${bar.lines} lines at 1280, expected 3 on one line`);
    if (!/\d{4}$/.test(bar.label) || (bar.label.match(/\d{4}/g) ?? []).length > 2 || bar.label.includes("Mon")) problems.push(`roster: the week label is "${bar.label}", expected one range in the locale ending in the year`);
    if (!bar.keywords.includes("Day off (off)") || !bar.keywords.includes("Public holiday (public_holiday)") || bar.placeholder !== "9-17:30 or off") problems.push(`roster: keywords "${bar.keywords}", placeholder "${bar.placeholder}"`);
    await p.screenshot({ path: `${outDir}/manager-roster-1280.png` });
    await ctx.close();
  }

  // 4. Breadcrumbs: Welcome › group › page, the group linking to the person's first page of it; a bare page;
  // Sources' detail with the connection's name; My account; Send a message. The last crumb is current and no link.
  const crumbsOf = (p) => p.evaluate(() => {
    const nav = document.querySelector('[data-testid="breadcrumbs"]');
    if (!nav) return null;
    const items = [...nav.querySelectorAll("li")];
    return {
      labels: items.map((li) => li.textContent.trim()),
      hrefs: items.map((li) => li.querySelector("a")?.getAttribute("href") ?? null),
      current: items.map((li) => li.querySelector('[aria-current="page"]') !== null),
      separators: nav.querySelectorAll("svg[aria-hidden]").length,
      label: nav.getAttribute("aria-label"),
      lastIsLink: !!items.at(-1)?.querySelector("a"),
    };
  });
  for (const [subject, path, labels, hrefs] of [
    ["agent-one", "/messages", ["Welcome", "Messages"], ["/", null]],
    ["manager", "/reports/inbound?range=month", ["Welcome", "Reports", "Inbound"], ["/", "/reports/dashboard", null]],
    ["reader", "/reports/inbound?range=month", ["Welcome", "Reports", "Inbound"], ["/", "/reports/speed-to-lead", null]],
    ["admin", "/configuration/sources/00000000-0000-7000-8000-00000000c001", ["Welcome", "Configuration", "Sources", null], ["/", "/configuration/teams", "/configuration/sources", null]],
    ["agent-one", "/account", ["Welcome", "My account"], ["/", null]],
    ["supervisor", "/messages/send", ["Welcome", "Messages", "Send a message"], ["/", "/messages", null]],
    // Follow-up and Waiting for you (addition 0008o): a report in its group; the person's own page, no rail item
    ["manager", "/reports/follow-up", ["Welcome", "Reports", "Follow-up"], ["/", "/reports/dashboard", null]],
    ["agent-one", "/me/follow-up", ["Welcome", "Waiting for you"], ["/", null]],
    // Attempts per deal and Attempts per agent (addition 0008y): reports in their group
    ["manager", "/reports/attempts?range=month", ["Welcome", "Reports", "Attempts per deal"], ["/", "/reports/dashboard", null]],
    ["reader", "/reports/attempts?range=month", ["Welcome", "Reports", "Attempts per deal"], ["/", "/reports/speed-to-lead", null]],
    ["supervisor", "/reports/attempts-per-agent?range=month", ["Welcome", "Reports", "Attempts per agent"], ["/", "/reports/dashboard", null]],
  ]) {
    const ctx = await withCookies(subject, {});
    const p = await ctx.newPage();
    await p.goto(BASE + path);
    await p.waitForLoadState("networkidle");
    const where = `${subject} ${path.split("?")[0]}`;
    const c = await crumbsOf(p);
    if (!c) {
      problems.push(`${where}: no breadcrumbs`);
      await ctx.close();
      continue;
    }
    const want = provoke ? labels.slice(0, -1) : labels;
    if (c.labels.length !== want.length || !want.every((l, i) => l === null || l === c.labels[i])) problems.push(`${where}: crumbs ${JSON.stringify(c.labels)}, expected ${JSON.stringify(want)}`);
    if (JSON.stringify(c.hrefs) !== JSON.stringify(hrefs)) problems.push(`${where}: crumb links ${JSON.stringify(c.hrefs)}, expected ${JSON.stringify(hrefs)}`);
    if (c.current.filter(Boolean).length !== 1 || !c.current.at(-1) || c.lastIsLink) problems.push(`${where}: the last crumb is not the one current, link-free crumb`);
    if (c.separators !== c.labels.length - 1) problems.push(`${where}: ${c.separators} separators for ${c.labels.length} crumbs`);
    if (c.label !== "You are here") problems.push(`${where}: the trail is named ${JSON.stringify(c.label)}`);
    if (path.startsWith("/configuration/sources/")) await p.screenshot({ path: `${outDir}/admin-sources-detail-breadcrumbs.png` });
    await ctx.close();
  }

  // 5. Preview as role: the admin with the cookie sees the agent's rail and the banner, keeps their name, gets the
  // role's 403 on a report route and the narrowed My account; Exit clears the cookie. A manager's and an agent's
  // cookie is ignored: no control, no banner, their own rail.
  {
    const ctx = await withCookies("admin", { "cma-preview-role": "agent" });
    const p = await ctx.newPage();
    await p.goto(BASE + "/");
    await p.waitForLoadState("networkidle");
    const m = await p.evaluate(() => ({
      banner: document.querySelector('[data-testid="preview-banner"]')?.textContent?.trim() ?? null,
      select: document.querySelector('[data-testid="preview-select"]')?.value ?? null,
      options: [...document.querySelectorAll('[data-testid="preview-select"] option')].map((o) => o.value),
      rail: [...document.querySelectorAll('nav[data-rail-nav] a[href]:not([href^="/configuration/"])')].map((a) => a.getAttribute("href")),
      config: document.querySelectorAll('nav[data-rail-nav] a[href^="/configuration/"]').length,
      name: document.querySelector('header a[href="/account"]')?.textContent?.trim(),
    }));
    const agentRail = ["/", "/messages", "/day", "/hours", "/schedule"];
    if (!(m.banner ?? "").startsWith("Previewing as Agent")) problems.push(`preview: the banner says ${JSON.stringify(m.banner)}`);
    if (m.select !== "agent") problems.push(`preview: the select shows ${JSON.stringify(m.select)}, expected agent`);
    if (m.options[0] !== "" || m.options.includes("admin") || !m.options.includes("agent")) problems.push(`preview: options ${JSON.stringify(m.options)}, expected the own view first and every role but the admin's own`);
    if (JSON.stringify(m.rail) !== JSON.stringify(provoke ? agentRail.slice(0, 4) : agentRail) || m.config > 0) problems.push(`preview: the admin previewing as agent sees ${JSON.stringify(m.rail)} and ${m.config} configuration pages`);
    if (m.name !== "Test admin") problems.push(`preview: the signed-in name became ${JSON.stringify(m.name)}; a preview changes visibility, never identity`);
    const report = await p.request.get(BASE + "/api/v1/reports/speed-to-lead?from=2026-10-01&to=2026-10-02");
    if (report.status() !== 403) problems.push(`preview: a report route answered ${report.status()} to the admin previewing as agent, expected the role's 403`);
    await p.screenshot({ path: `${outDir}/admin-preview-agent.png` });
    await p.goto(BASE + "/account");
    await p.waitForLoadState("networkidle");
    const allows = await p.locator('[data-testid="permissions-list"] li').count();
    if (allows !== 2) problems.push(`preview: My account lists ${allows} permissions while previewing as agent, expected the narrowed 2`);
    await p.locator('[data-testid="exit-preview"]').click();
    await p.locator('[data-testid="preview-banner"]').waitFor({ state: "detached", timeout: 5000 }).catch(() => undefined);
    await p.waitForLoadState("networkidle");
    const after = await p.evaluate(() => ({
      banner: !!document.querySelector('[data-testid="preview-banner"]'),
      config: document.querySelectorAll('nav[data-rail-nav] a[href^="/configuration/"]').length,
      allows: document.querySelectorAll('[data-testid="permissions-list"] li').length,
    }));
    const jar = await jarOf(ctx);
    if (after.banner || after.config === 0 || after.allows < 10 || jar["cma-preview-role"]) problems.push(`preview: after Exit ${JSON.stringify({ ...after, cookie: jar["cma-preview-role"] ?? null })}, expected the admin's own view and no cookie`);
    await ctx.close();
  }
  // the manager's rail holds 25 pages since Follow-up (0008o), Forms (0008p), Email and Email per agent (0008t), First
  // orders and Orders per person (0008u), Attempts per deal and Attempts per agent (0008y) joined the Reports group and
  // Campaign monitoring (0008v) the Campaigns group (only the first nine with a digit key since the IT audit of 17 October
  // 2026, so the pages are counted by their links); since 0008zb Funnel and Cancellations; since 0008ze Reviews; since 0008zi
  // Maintenance
  for (const [subject, pages] of [["manager", 29], ["agent-one", 5]]) {
    const ctx = await withCookies(subject, { "cma-preview-role": "agent" });
    const p = await ctx.newPage();
    await p.goto(BASE + "/");
    await p.waitForLoadState("networkidle");
    const m = await p.evaluate(() => ({
      banner: !!document.querySelector('[data-testid="preview-banner"]'),
      select: !!document.querySelector('[data-testid="preview-select"]'),
      rail: document.querySelectorAll('nav[data-rail-nav] a[href]:not([href^="/configuration/"])').length,
    }));
    if (m.banner || m.select || m.rail !== (provoke ? pages - 1 : pages)) problems.push(`preview: ${subject} with a preview cookie gets ${JSON.stringify(m)}, expected no control, no banner and ${pages} pages`);
    await ctx.close();
  }
}

// The rail as an accordion (19 October 2026): at most one group open, the open one in the cookie cma-nav-open (empty for
// none) and rendered by the server, a click on the open group closing it, a group's letter opening it (closing the other)
// with the focus on its first page, a click in the folded rail unfolding it with only that group open, the retired
// per-group cookies ignored and expired on the first toggle; aria-expanded and aria-controls agree with what shows, a
// closed group holding the current page keeps its white pill and the digit keys work with every group closed.
// Time has no letter, so the letter is Configuration's C, for the admin. --provoke expects the per-group behaviour of
// 7 October 2026 (Time still open after Reports opens)
async function expectAccordion() {
  const host = new URL(BASE).hostname;
  const contextOf = async (subject, cookies) => {
    const ctx = await b.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": subject } });
    // host-only, as a page's document.cookie writes them
    await ctx.addCookies(Object.entries(cookies).map(([name, value]) => ({ name, value, url: BASE + "/" })));
    return ctx;
  };
  const jarOf = async (ctx) => Object.fromEntries((await ctx.cookies()).filter((c) => c.domain.replace(/^\./, "") === host).map((c) => [c.name, c.value]));
  const groupsOf = (p) => p.evaluate(() => [...document.querySelectorAll('nav[data-rail-nav] button[aria-controls^="nav-group-"]')].map((btn) => {
    const list = document.getElementById(btn.getAttribute("aria-controls") ?? "");
    return {
      id: btn.getAttribute("data-nav-group"),
      expanded: btn.getAttribute("aria-expanded"),
      controls: !!list && list.tagName === "UL",
      shown: !!list && list.getClientRects().length > 0,
      pill: btn.getAttribute("data-current") === "true" && btn.classList.contains("bg-white"),
    };
  }));
  const openOf = (g) => g.filter((x) => x.expanded === "true").map((x) => x.id);
  const agree = (where, g) => {
    for (const x of g) {
      if (!x.controls) problems.push(`accordion ${where}: ${x.id}'s aria-controls names no list`);
      if ((x.expanded === "true") !== x.shown) problems.push(`accordion ${where}: ${x.id} has aria-expanded ${x.expanded} while its pages are ${x.shown ? "shown" : "hidden"}`);
    }
  };
  const expectOpen = (where, g, want) => {
    if (JSON.stringify(openOf(g)) !== JSON.stringify(want)) problems.push(`accordion ${where}: open ${JSON.stringify(openOf(g))}, expected ${JSON.stringify(want)}`);
  };
  const click = async (p, id) => {
    await p.locator(`nav[data-rail-nav] button[aria-controls="nav-group-${id}"]`).click();
    await p.waitForTimeout(150);
  };
  /** The groups the server renders open, from its HTML (the rail toggle's own aria-expanded is not a group) */
  const serverOpen = async (ctx, path) => {
    const html = await (await ctx.request.get(BASE + path)).text();
    return [...html.matchAll(/<button[^>]*aria-controls="nav-group-([a-z-]+)"[^>]*>/g)].filter((m) => m[0].includes('aria-expanded="true"')).map((m) => m[1]);
  };

  // 1. Time then Reports: only Reports open, the cookie names it; the server renders it so after a reload; a click on
  // Reports closes it, none open and the cookie empty; a digit key still opens a page of a closed group
  {
    const ctx = await contextOf("manager", {});
    const p = await ctx.newPage();
    await p.goto(BASE + "/");
    await p.waitForLoadState("networkidle");
    expectOpen("on a first visit", await groupsOf(p), []);
    await click(p, "time");
    expectOpen("after Time", await groupsOf(p), ["time"]);
    await click(p, "reports");
    const g = await groupsOf(p);
    expectOpen("after Time then Reports", g, provoke ? ["time", "reports"] : ["reports"]);
    agree("after Time then Reports", g);
    const jar = await jarOf(ctx);
    if (jar["cma-nav-open"] !== "reports") problems.push(`accordion: the cookie is cma-nav-open=${JSON.stringify(jar["cma-nav-open"])}, expected reports`);
    const fromServer = await serverOpen(ctx, "/");
    if (JSON.stringify(fromServer) !== JSON.stringify(["reports"])) problems.push(`accordion: the server renders ${JSON.stringify(fromServer)} open, expected exactly one aria-expanded="true", on Reports`);
    await p.reload();
    await p.waitForLoadState("networkidle");
    expectOpen("after a reload", await groupsOf(p), ["reports"]);
    await click(p, "reports");
    const none = await groupsOf(p);
    expectOpen("after a click on the open Reports", none, []);
    agree("with none open", none);
    const after = await jarOf(ctx);
    if (after["cma-nav-open"] !== "") problems.push(`accordion: with none open the cookie is ${JSON.stringify(after["cma-nav-open"])}, expected empty`);
    if ((await serverOpen(ctx, "/")).length !== 0) problems.push("accordion: with the cookie empty the server still renders a group open");
    // the manager's sixth page is My day, in the closed Time group
    await p.keyboard.press("6");
    await p.waitForURL("**/day").catch(() => undefined);
    if (new URL(p.url()).pathname !== "/day") problems.push(`accordion: key 6 opened ${new URL(p.url()).pathname} with every group closed, expected /day`);
    await p.waitForLoadState("networkidle");
    const pill = (await groupsOf(p)).find((x) => x.id === "time");
    if (!pill?.pill || pill.expanded !== "false") problems.push(`accordion: the closed Time group holding My day is ${JSON.stringify(pill)}, expected closed with its white pill`);
    await p.screenshot({ path: `${outDir}/manager-rail-accordion.png` });
    await ctx.close();
  }

  // 2. A group's letter (Configuration's C, the admin): Reports open first, then C opens only Configuration and focuses its
  // first page; C again closes it
  {
    const ctx = await contextOf("admin", { "cma-nav-open": "reports" });
    const p = await ctx.newPage();
    await p.goto(BASE + "/");
    await p.waitForLoadState("networkidle");
    expectOpen("for the admin with the cookie", await groupsOf(p), ["reports"]);
    await p.locator("main h1").click();
    await p.keyboard.press("c");
    await p.waitForTimeout(250);
    const g = await groupsOf(p);
    expectOpen("after C", g, ["configuration"]);
    agree("after C", g);
    const focus = await p.evaluate(() => document.activeElement?.getAttribute("href"));
    if (focus !== "/configuration/teams") problems.push(`accordion: after C the focus is on ${JSON.stringify(focus)}, expected Configuration's first page`);
    if ((await jarOf(ctx))["cma-nav-open"] !== "configuration") problems.push("accordion: C did not write cma-nav-open=configuration");
    await ctx.close();
  }

  // 3. The folded rail: a click on Reports unfolds it with only Reports open (Time was open before the fold)
  {
    const ctx = await contextOf("manager", { "cma-rail": "collapsed", "cma-nav-open": "time" });
    const p = await ctx.newPage();
    await p.goto(BASE + "/");
    await p.waitForLoadState("networkidle");
    await click(p, "reports");
    const width = await p.evaluate(() => Math.round(document.querySelector("nav[data-rail-nav]").getBoundingClientRect().width));
    const g = await groupsOf(p);
    expectOpen("after a click in the folded rail", g, ["reports"]);
    agree("after a click in the folded rail", g);
    const jar = await jarOf(ctx);
    if (width !== 256 || jar["cma-rail"] !== "expanded" || jar["cma-nav-open"] !== "reports") problems.push(`accordion: a click in the folded rail gave ${width}px, cma-rail=${jar["cma-rail"]}, cma-nav-open=${jar["cma-nav-open"]}, expected 256, expanded and reports`);
    await ctx.close();
  }

  // 4. The retired cookies of 7 October 2026: ignored (none open, on the server too) and expired after one toggle
  {
    const ctx = await contextOf("manager", { "cma-nav-time": "open", "cma-nav-reports": "open" });
    const p = await ctx.newPage();
    await p.goto(BASE + "/");
    await p.waitForLoadState("networkidle");
    expectOpen("with the retired cookies", await groupsOf(p), []);
    if ((await serverOpen(ctx, "/")).length !== 0) problems.push("accordion: the server renders a group open from a retired per-group cookie");
    await click(p, "time");
    const jar = await jarOf(ctx);
    const left = ["cma-nav-time", "cma-nav-reports"].filter((k) => k in jar);
    if (left.length > 0 || jar["cma-nav-open"] !== "time") problems.push(`accordion: after one toggle ${JSON.stringify(left)} still set and cma-nav-open=${JSON.stringify(jar["cma-nav-open"])}, expected both expired and time`);
    await ctx.close();
  }
}

// No header's info mark wraps apart from its label (19 October 2026): at 1440 px with the rail open, on Follow-up, Attempts
// per deal (two groupings) and Attempts per agent, every header's mark sits on the line of the label's last word. Attempts
// per deal never scrolls sideways there. --provoke breaks the line before one mark per page
async function expectNoWrappedMarks() {
  for (const [subject, path] of [["manager", "/reports/follow-up"], ["manager", "/reports/attempts?range=month&group=day"],
    ["manager", "/reports/attempts?range=month&group=pipeline&attempted=some"], ["manager", "/reports/attempts-per-agent?range=month"]]) {
    const ctx = await b.newContext({ viewport: { width: 1440, height: 900 }, extraHTTPHeaders: { "x-cma-mock-subject": subject } });
    const p = await ctx.newPage();
    await p.goto(BASE + path);
    await p.waitForLoadState("networkidle");
    const where = `${subject} ${path.split("?")[0]}${path.includes("group=") ? ` (${path.split("group=")[1].split("&")[0]})` : ""} at 1440`;
    const r = await p.evaluate((spoil) => {
      const ths = [...document.querySelectorAll("main th")].filter((th) => th.querySelector("button[data-header-hint]"));
      if (spoil && ths[0]) ths[0].querySelector("button[data-header-hint]").parentElement.before(document.createElement("br"));
      const out = { headers: 0, wrapped: [] };
      for (const th of ths) {
        const texts = [];
        const walk = document.createTreeWalker(th, NodeFilter.SHOW_TEXT, {
          acceptNode: (n) => n.parentElement.closest(".sr-only, [data-hint-panel], button") || !/\S/.test(n.textContent) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT,
        });
        while (walk.nextNode()) texts.push(walk.currentNode);
        const last = texts.at(-1);
        if (!last) continue; // a header read out only (the link column)
        out.headers++;
        const range = document.createRange();
        range.selectNodeContents(last);
        const line = [...range.getClientRects()].at(-1);
        const mark = th.querySelector("button[data-header-hint]").getBoundingClientRect();
        const middle = mark.top + mark.height / 2;
        if (!line || middle < line.top - 1 || middle > line.bottom + 1 || mark.left < line.left) out.wrapped.push(th.textContent.trim().slice(0, 40));
      }
      const main = document.querySelector("main");
      return { ...out, scrollX: document.documentElement.scrollWidth > window.innerWidth || main.scrollWidth > main.clientWidth };
    }, provoke);
    if (r.headers === 0) problems.push(`${where}: no header with a mark to check`);
    for (const h of r.wrapped) problems.push(`${where}: the info mark of "${h}" wraps apart from its label`);
    if (path.startsWith("/reports/attempts?") && r.scrollX) problems.push(`${where}: the page scrolls sideways`);
    await ctx.close();
  }
}

// Attempts per deal and Attempts per agent (addition 0008y; for sales since 0008z), per identity at 1280 px: Attempts per
// deal in the rail and on the page for reports.view or performance.team, Attempts per agent for performance.team while the
// tenant's reports.per_person holds attempts (the reader sees Attempts per deal only; the agent gets the no-permission card;
// the invest tenant, without the switch, has no Attempts per agent: absent from the rail, its page not found); the page
// never scrolls sideways, in every grouping and with the attempted and outcome filters; the keycaps K, P, A, O (and G on
// Attempts per deal) next to the period bar's; six tiles; the tables end inside their cards; the right-most header's hint
// stays inside the viewport; a deal's row opens with Enter to its attempts, inside the card, and closes with Esc, the
// focus back on the deal. --provoke lets the deal list spill out of its card and swallows Esc
async function expectAttempts() {
  // [subject, sees Attempts per deal, sees Attempts per agent]
  const cases = [
    ["manager", true, true], ["supervisor", true, true], ["admin", true, true], ["analyst", true, true],
    ["reader", true, false], ["invest-analyst", true, false], ["agent-one", false, false],
  ];
  for (const [subject, deals, perAgent] of cases) {
    const ctx = await b.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": subject } });
    const p = await ctx.newPage();
    await p.goto(BASE + "/");
    await p.waitForLoadState("networkidle");
    const rail = await p.evaluate(() => [...(document.querySelector("nav")?.querySelectorAll("a") ?? [])].map((a) => a.getAttribute("href")));
    if (rail.includes("/reports/attempts") !== deals) problems.push(`${subject}: Attempts per deal ${deals ? "missing from" : "shown in"} the rail`);
    if (rail.includes("/reports/attempts-per-agent") !== perAgent) problems.push(`${subject}: Attempts per agent ${perAgent ? "missing from" : "shown in"} the rail`);
    const pages = [
      ["/reports/attempts?range=month&group=day", deals, "attempts-list-scroll", "attempts-list", ["K", "P", "A", "O", "G", "T", "W", "M", "C"]],
      ["/reports/attempts?range=month&group=week&outcome=open", deals, "attempts-list-scroll", "attempts-list", ["G"]],
      ["/reports/attempts?range=month&group=market", deals, "attempts-groups-scroll", "attempts-groups", ["G"]],
      ["/reports/attempts?range=month&group=pipeline", deals, "attempts-groups-scroll", "attempts-groups", ["G"]],
      ["/reports/attempts-per-agent?range=month", perAgent, "attempts-agents-scroll", "attempts-agents-table", ["K", "P", "A", "O", "T", "W", "M", "C"]],
    ];
    for (const [path, may, scroll, table, keys] of pages) {
      const where = `${subject} ${path.split("?")[0]}${path.includes("group=") ? ` (${path.split("group=")[1].split("&")[0]})` : ""}`;
      const perDeal = path.startsWith("/reports/attempts?");
      const r = await p.goto(BASE + path);
      await p.waitForLoadState("networkidle");
      const m = await p.evaluate(() => ({
        scrollX: document.documentElement.scrollWidth > window.innerWidth,
        keycaps: [...document.querySelectorAll("main kbd")].map((k) => k.textContent?.trim()),
        tables: document.querySelectorAll("main table").length,
        tiles: document.querySelectorAll('[data-testid="attempts-tiles"] > *').length,
      }));
      if (m.scrollX) problems.push(`${where}: page scrolls horizontally at 1280`);
      if (!may) {
        // without the tenant's switch the per-agent page does not exist; without the permission it says so
        if (!perDeal && subject === "invest-analyst" && r?.status() !== 404) problems.push(`${where}: answers ${r?.status()}, expected 404 without reports.per_person`);
        if (m.tables > 0) problems.push(`${where}: figures shown to someone without the permission`);
        continue;
      }
      for (const k of keys) if (!m.keycaps.includes(k)) problems.push(`${where}: keycap ${k} missing`);
      if (perDeal && m.tiles !== 6) problems.push(`${where}: ${m.tiles} tiles, expected 6`);
      if (await p.locator(`[data-testid="${table}"]`).count() === 0) {
        problems.push(`${where}: ${table} missing`);
        continue;
      }
      const inside = await p.evaluate(([id, spill]) => {
        const box = document.querySelector(`[data-testid="${id}"]`);
        if (!box) return null;
        if (spill) box.style.overflowX = "visible";
        const main = document.querySelector("main");
        const card = box.parentElement.getBoundingClientRect();
        const r = box.getBoundingClientRect();
        return { main: main.scrollWidth - main.clientWidth, inCard: r.right <= card.right + 0.5 };
      }, [scroll, provoke && subject === "manager" && path.includes("group=day")]);
      if (!inside) problems.push(`${where}: the table has no scroll container`);
      else if (inside.main > 0 || !inside.inCard) problems.push(`${where}: the table spills out of its card, the main area scrolls sideways by ${inside.main}px at 1280`);
      if (subject === "manager") {
        const mark = p.locator(`[data-testid="${table}"] thead th:last-child button[data-header-hint]`);
        if (await mark.count() !== 1) problems.push(`${where}: the right-most header's hint is missing`);
        else {
          await mark.focus();
          const h = await p.evaluate(() => {
            const m = document.activeElement;
            const panel = m && document.getElementById(m.getAttribute("aria-describedby") ?? "");
            if (!panel || panel.hidden || getComputedStyle(panel).visibility !== "visible") return null;
            const r = panel.getBoundingClientRect();
            return r.left >= 0 && r.top >= 0 && r.right <= window.innerWidth && r.bottom <= window.innerHeight;
          });
          if (h === null) problems.push(`${where}: the right-most header's hint does not show on focus`);
          else if (!h) problems.push(`${where}: the right-most header's hint leaves the viewport`);
          await p.keyboard.press("Escape");
        }
        await p.screenshot({ path: `${outDir}/${subject}-${path.split("?")[0].split("/").pop()}-${path.includes("group=") ? path.split("group=")[1].split("&")[0] : "month"}.png`, fullPage: true });
      }
      if (perDeal && path.includes("group=day") && ["manager", "reader"].includes(subject)) await expectDealRow(p, where);
    }
    await ctx.close();
  }
}

// A deal's row (addition 0008z): Enter on the deal opens its attempts below it (aria-expanded, the attempts or "No attempt
// yet" read from the API), inside the card without a sideways scroll; Esc closes it and the focus stays on the deal
// Funnel and Cancellations (addition 0008zb), per identity at 1280 px: both in the rail and on the page for reports.view
// or performance.team after Attempts per agent (the agent gets the no-permission card); deals per person on Funnel for
// performance.team while reports.per_person holds deals (not for the reader, not for the invest tenant without the
// switch); the page never scrolls sideways, by week and by day; the keycaps K, P, S, G and X on Funnel, K, G and X on
// Cancellations, next to the period bar's; ten tiles and four; the tables end inside their cards. --provoke lets the
// lost deals per period spill out of their card
async function expectFunnel() {
  // [subject, sees the pages, sees deals per person]
  const cases = [
    ["manager", true, true], ["supervisor", true, true], ["admin", true, true], ["analyst", true, true],
    ["reader", true, false], ["invest-analyst", true, false], ["agent-one", false, false],
  ];
  for (const [subject, may, people] of cases) {
    const ctx = await b.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": subject } });
    const p = await ctx.newPage();
    await p.goto(BASE + "/");
    await p.waitForLoadState("networkidle");
    const rail = await p.evaluate(() => [...(document.querySelector("nav")?.querySelectorAll("a") ?? [])].map((a) => a.getAttribute("href")));
    for (const href of ["/reports/funnel", "/reports/cancellations"]) {
      if (rail.includes(href) !== may) problems.push(`${subject}: ${href} ${may ? "missing from" : "shown in"} the rail`);
    }
    if (may && rail.indexOf("/reports/funnel") !== rail.indexOf(subject === "reader" || subject === "invest-analyst" ? "/reports/attempts" : "/reports/attempts-per-agent") + 1) {
      problems.push(`${subject}: Funnel does not follow Attempts in the rail`);
    }
    const pages = [
      ["/reports/funnel?range=month&group=week", ["funnel-stages", "funnel-by-period", "funnel-by-market"], ["K", "P", "S", "G", "X", "T", "W", "M", "C"], 10],
      ["/reports/funnel?range=month&group=day", ["funnel-by-period", "funnel-by-source"], ["G"], 10],
      ["/reports/cancellations?range=month&group=week", ["cancellations-periods", "cancellations-list"], ["K", "G", "X", "T", "W", "M", "C"], 4],
      ["/reports/cancellations?range=month&group=day", ["cancellations-periods"], ["G"], 4],
    ];
    for (const [path, tables, keys, tiles] of pages) {
      const where = `${subject} ${path.split("?")[0]} (${path.split("group=")[1]})`;
      await p.goto(BASE + path);
      await p.waitForLoadState("networkidle");
      const m = await p.evaluate(() => ({
        scrollX: document.documentElement.scrollWidth > window.innerWidth,
        keycaps: [...document.querySelectorAll("main kbd")].map((k) => k.textContent?.trim()),
        tables: document.querySelectorAll("main table").length,
        tiles: document.querySelectorAll("main [data-tile]").length,
        people: !!document.querySelector('[data-testid="people-section"]'),
      }));
      if (m.scrollX) problems.push(`${where}: page scrolls horizontally at 1280`);
      if (!may) {
        if (m.tables > 0) problems.push(`${where}: figures shown to someone without the permission`);
        continue;
      }
      for (const k of keys) if (!m.keycaps.includes(k)) problems.push(`${where}: keycap ${k} missing`);
      if (m.tiles !== tiles) problems.push(`${where}: ${m.tiles} tiles, expected ${tiles}`);
      if (path.startsWith("/reports/funnel") && m.people !== people) problems.push(`${where}: deals per person ${people ? "missing" : "shown"}`);
      for (const table of tables) {
        const inside = await p.evaluate(([id, spill]) => {
          const box = document.querySelector(`[data-testid="${id}-scroll"]`);
          if (!box) return null;
          if (spill) {
            // provoked: the table wider than its card, and the card letting it out
            box.style.overflowX = "visible";
            const table = box.querySelector("table");
            if (table) table.style.minWidth = "2400px";
          }
          const main = document.querySelector("main");
          const card = box.closest("section")?.getBoundingClientRect() ?? box.parentElement.getBoundingClientRect();
          const r = box.getBoundingClientRect();
          return { main: main.scrollWidth - main.clientWidth, inCard: r.right <= card.right + 0.5 };
        }, [table, provoke && subject === "manager" && table === "funnel-by-period"]);
        if (!inside) problems.push(`${where}: ${table} has no scroll container`);
        else if (inside.main > 0 || !inside.inCard) problems.push(`${where}: ${table} spills out of its card, the main area scrolls sideways by ${inside.main}px at 1280`);
      }
      if (subject === "manager") {
        await p.screenshot({ path: `${outDir}/${subject}-${path.split("?")[0].split("/").pop()}-${path.split("group=")[1]}.png`, fullPage: true });
      }
    }
    await ctx.close();
  }
}

async function expectDealRow(p, where) {
  const toggle = p.locator('[data-testid="attempts-toggle"]').first();
  if (await toggle.count() === 0) { problems.push(`${where}: no deal to open`); return; }
  if (provoke) await p.evaluate(() => document.addEventListener("keydown", (e) => { if (e.key === "Escape") e.stopImmediatePropagation(); }, true));
  await toggle.focus();
  await p.keyboard.press("Enter");
  await p.locator('[data-testid="attempt-row"], [data-testid="attempts-detail-none"], [data-testid="attempts-detail-failed"]').first().waitFor({ timeout: 5000 }).catch(() => {});
  const opened = await p.evaluate(() => {
    const main = document.querySelector("main");
    const box = document.querySelector('[data-testid="attempts-list-scroll"]');
    return {
      expanded: document.querySelector('[data-testid="attempts-toggle"]')?.getAttribute("aria-expanded"),
      rows: document.querySelectorAll('[data-testid="attempt-row"]').length,
      none: !!document.querySelector('[data-testid="attempts-detail-none"]'),
      failed: !!document.querySelector('[data-testid="attempts-detail-failed"]'),
      mainX: main.scrollWidth - main.clientWidth,
      inCard: box ? box.getBoundingClientRect().right <= box.parentElement.getBoundingClientRect().right + 0.5 : false,
    };
  });
  if (opened.expanded !== "true") problems.push(`${where}: Enter on a deal does not open it (aria-expanded ${opened.expanded})`);
  if (opened.failed) problems.push(`${where}: the deal's attempts could not be loaded`);
  else if (opened.rows === 0 && !opened.none) problems.push(`${where}: the opened deal shows neither attempts nor "No attempt yet"`);
  if (opened.mainX > 0 || !opened.inCard) problems.push(`${where}: the opened deal spills out of its card, the main area scrolls sideways by ${opened.mainX}px`);
  await p.keyboard.press("Escape");
  const closed = await p.evaluate(() => ({
    expanded: document.querySelector('[data-testid="attempts-toggle"]')?.getAttribute("aria-expanded"),
    detail: document.querySelectorAll('[data-testid="attempts-detail"]').length,
    focus: document.activeElement?.getAttribute("data-testid"),
  }));
  if (closed.expanded !== "false" || closed.detail !== 0) problems.push(`${where}: Esc does not close the opened deal`);
  if (closed.focus !== "attempts-toggle") problems.push(`${where}: after Esc the focus is on ${closed.focus}, expected the deal`);
}

// Welcome on open (addition 0008z): a browser with an identity and no browser session (a fresh sign-in, a new session) that
// opens a deep link lands on Welcome; from then on a deep link opens as asked; the API is never redirected. The mock
// identity travels as the cma-mock-subject cookie here, as a browser after ?as= or IAP's sign-in, not the verifiers' header.
// --provoke gives the browser a session cookie before its first page, as a remembered last page would
async function expectWelcomeOnOpen() {
  for (const subject of ["manager", "agent-one"]) {
    const host = new URL(BASE).hostname;
    const ctx = await b.newContext({ viewport: { width: 1280, height: 800 } });
    await ctx.addCookies([{ name: "cma-mock-subject", value: subject, domain: host, path: "/" },
      ...(provoke ? [{ name: "cma-session", value: "1", domain: host, path: "/" }] : [])]);
    const p = await ctx.newPage();
    const deep = subject === "manager" ? "/reports/attempts?range=month" : "/hours";
    await p.goto(BASE + deep);
    await p.waitForLoadState("networkidle");
    const first = new URL(p.url()).pathname;
    if (first !== "/") problems.push(`${subject}: a fresh sign-in opening ${deep} landed on ${first}, expected Welcome at /`);
    const jar = Object.fromEntries((await ctx.cookies()).map((c) => [c.name, c]));
    if (!provoke && (!jar["cma-session"] || jar["cma-session"].expires !== -1 || !jar["cma-session"].httpOnly)) problems.push(`${subject}: the browser session is not an HttpOnly session cookie`);
    await p.goto(BASE + deep);
    await p.waitForLoadState("networkidle");
    const second = new URL(p.url()).pathname;
    if (second !== deep.split("?")[0]) problems.push(`${subject}: a deep link while signed in landed on ${second}, expected ${deep.split("?")[0]}`);
    await ctx.close();
  }
}

await expectShell(1280, 800);
await expectShell(1920, 1080);
await expectNavigation();
await expectFrame();
await expectAccordion();
await expectNoWrappedMarks();
await expectReports();
await expectLiveBoard();
await expectFrameFixed();
await expectCalls();
await expectForms();
await expectEmail();
await expectFirstOrders();
await expectAttempts();
await expectFunnel();
await expectWelcomeOnOpen();
await expectCampaigns();
await expectCallbacks();
await expectIntakeConfiguration();
await expectInvitations();
await expectIrreversibleConfirmations();
if (provoke) await expectShell(1279, 800);
else await expectGate(1279, 800);
await b.close();

for (const x of problems) console.log("  " + x);
console.log(problems.length === 0 ? `layout: PASS (1280, 1920, gate at 1279, Welcome, the shift line, navigation, the Configuration group and My account for 6 identities, the three intake reports, Inbound and the Intake row with a header hint open, Intake and Inbound inside their cards, no text on Light Blue or Soft Rose, the Live board for 6 identities, Calls and Calls per agent for 7 identities (the per-agent page for performance.team only, the opened rows and the tag table inside their cards, Enter and Down, the deltas like for like and none before the telephony history), Forms for 7 identities (the keycaps, the four tiles, the forms table and the answers inside their cards, the deltas like for like and none before the forms history), Email and Email per agent for 7 identities (the per-person page for performance.team with the tenant's switch, not found without it, the keycaps, the tables inside their cards, Enter and Down, No email connected), First orders and Orders per person for 7 identities (the per-person page for performance.team with the tenant's switch, not found without it, the keycaps, the four tiles, the level bars, History from in Muted, every grouping and the tables inside their cards, No orders connected), Attempts per deal and Attempts per agent for 7 identities (the per-agent page for performance.team with the tenant's switch, not found without it, the keycaps K, P, A, O, the six tiles, every grouping and the tables inside their cards, the right-most hint inside the viewport, a deal's row opened by Enter and closed by Esc), Funnel and Cancellations for 7 identities (after Attempts in the rail, deals per person for performance.team with the tenant's switch, the keycaps K, P, S, G and X, ten and four tiles, by week and by day, the tables inside their cards), Welcome on open for 2 identities (a fresh sign-in on a deep link lands on /, a deep link while signed in opens), the Live board's last section, Callbacks kept on Follow-up and the Dashboard for 5 identities (the weeks for reports.view or performance.team, per person for performance.team, inside their cards, No callback type set), Campaign monitoring for 7 identities (the journeys' cards inside the main area, the archived one absent, a journey's Muted banner, seven dashed placeholders with the drill-down locked, the prerequisites unticked, no figure, the breadcrumbs, archived and unknown not found, no journeys in words), Sources with its form categories (every table inside its card), Markets and Alert rules, People with Invitations and the Invite dialog for the admin and the manager, /invite open, another account, expired, invalid and another business line, the irreversible confirmations on Lines (with the stored-calls count, loading and failed), Teams and the planner and End workday opening on its confirm button, the rail folded by cookie and by W, the rail as an accordion (one group open, the cookie on the server, a click closing it, the letter, the folded rail, the retired cookies expired, the digit keys and the pill with every group closed), no info mark wrapped apart on Follow-up and Attempts at 1440, the hints hidden by cookie and shown by ?, aria-keyshortcuts, the frame fixed to the viewport (the Live board, Speed to lead and Follow-up at 1280 and 1920 scroll in main only, the rail at 1280x600 on its own), breadcrumbs on 11 pages, preview as role for the admin and ignored for 2 others, the roster's week bar; screenshots in ${outDir})` : `layout: FAIL (${problems.length} problems)`);
process.exit(problems.length === 0 ? 0 : 1);
