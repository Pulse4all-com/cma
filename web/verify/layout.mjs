/**
 * Verifier: layout at 1280 and 1920 px (zoom 1), the desktop fit from 1152 to 1279 px (since 9 November 2026: the 1280 px
 * layout zoomed to the window, see expectFit) and the gate below 1152 px with how to fix it, no
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
 * hint inside the viewport, or the not-connected state, and no horizontal scrolling; since addition 0009k the six
 * inbound tiles in their order by test id (Inbound, Answered, Unanswered, Service level, Talk time, Average to answer),
 * no Waiting now, and Talk time in the column of Outbound today's Talk time at 1280 and 1536 px; since the Live board's
 * UX pass (10 November 2026) at 1280 x 800 every call and follow-up figure on the first screen, each panel one row with
 * its figures on one line, the people's columns in view, no Employer filter on a one-employer board, the freshness on
 * the title row, Inbound today by hour's 24 hours with an hour's figures on focus, and the word that the figures are old
 * when the polls keep failing. Calls and Calls per
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
 * The two widths come from src/lib/desktop-fit.ts and the gate's words from src/lib/copy.ts, which Node reads with its type
 * stripping (on by default from Node 22.18; npm run verify:layout passes the flag for earlier 22s).
 *
 *   BASE=http://localhost:8080 npm run verify:layout                expect PASS
 *   BASE=http://localhost:8080 npm run verify:layout -- --provoke   zooms 1920 px, breaks each fit
 *       check at 1216 px (see expectFit), demands the app shell at 1151 px and the old gate's number in its words,
 *       moves one hint panel over its header, lets the
 *       Intake and Inbound tables spill out of their cards, writes a count on a Light Blue reason mark,
 *       lets the Calls tag table and the per-agent table spill out of theirs,
 *       widens the missed-reason table past its card on Sources,
 *       widens the Live board's inbound tiles past the main area, moves Inbound today's Talk time to the end of
 *       its row (the admin's board), puts Outbound today's figures on two rows (the manager's board), lets the
 *       supervisor's board polls answer so no staleness word comes, focuses the confirm button of each
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
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { chromium } from "playwright";
import { copy } from "../src/lib/copy.ts";
import { DESIGN_WIDTH_PX, FIT_FLOOR_PX } from "../src/lib/desktop-fit.ts";

/** Since night N06 every page route streams its skeleton first (loading.tsx): wait until the page has replaced it */
async function settle(page) {
  await page.waitForSelector("[data-route-skeleton]", { state: "detached", timeout: 30000 }).catch(() => {});
}

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
  await settle(p);
  await p.waitForLoadState("networkidle");
  // --provoke scales the window above the design width as the band does under it: the zoom must stay 1 there
  if (provoke && width > DESIGN_WIDTH_PX) await p.addStyleTag({ content: "html { zoom: 0.9 !important }" });
  const m = await p.evaluate(() => {
    const nav = document.querySelector("nav");
    const header = document.querySelector("header");
    const main = document.querySelector("main");
    return {
      zoom: parseFloat(getComputedStyle(document.documentElement).zoom) || 1,
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
  if (Math.abs(m.zoom - 1) > 0.005) problems.push(`${tag}: the root element is zoomed to ${m.zoom}, expected 1 from the design width up`);
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
    // 0008zi Maintenance (reports.view or performance.team) follows Reviews; since 0008zm Lead cohorts (reports.view or
    // performance.team) follows Orders per person (First orders for the reader), so the keys after it move one down. Since
    // 0008zn Flash (reports.view or performance.team) is first in Reports, so every Reports key moves by one for everyone who
    // sees it (brief B21)
    // Since 0008zv (Martin, 5 November 2026) the Live group holds one board per contact center (Newco in the dev seed and
    // the mock, /live/newco), and the report pages sit in three groups: Reports (Flash, Dashboard, Calls, Calls per agent,
    // Inbound, Email, Email per agent, Intake, Forms, Data quality), Sales (Speed to lead, Follow-up, Funnel, Attempts per
    // deal, Attempts per agent, Lead cohorts, First orders, Orders per person) and Customers (Cancellations, Reviews,
    // Maintenance), then Campaigns; every page keeps its permission, and the digit keys follow the new order
    // Since 0008zw (Martin, 5 November 2026) Assets follows Customers: Installed base (Flash's Installed base overview on a
    // page of its own) and Maintenance, which leaves Customers; Time comes before Team, so a manager's and an admin's Time
    // pages take the keys after Live and Team's follow them
    ["analyst", ["/", "/messages", "/live/newco", "/reports/flash", "/reports/dashboard", "/reports/calls", "/reports/calls-per-agent", "/reports/inbound",
      "/reports/email", "/reports/email-per-agent", "/reports/intake", "/reports/forms", "/reports/data-quality", "/reports/speed-to-lead",
      "/reports/follow-up", "/reports/funnel", "/reports/attempts", "/reports/attempts-per-agent", "/reports/lead-cohorts", "/reports/first-orders",
      "/reports/orders-per-person", "/reports/active", "/reports/courtesy", "/reports/reviews", "/reports/cancellations", "/reports/installed-base", "/reports/maintenance", "/campaigns"], false],
    // A reports reader (reports.view alone, 0008j): Calls without Calls per agent, no Dashboard; Email without Email per agent;
    // Attempts per deal without Attempts per agent; First orders without Orders per person
    ["reader", ["/", "/messages", "/reports/flash", "/reports/calls", "/reports/inbound", "/reports/email", "/reports/intake", "/reports/forms",
      "/reports/data-quality", "/reports/speed-to-lead", "/reports/follow-up", "/reports/funnel", "/reports/attempts", "/reports/lead-cohorts",
      "/reports/first-orders", "/reports/active", "/reports/courtesy", "/reports/reviews", "/reports/cancellations", "/reports/installed-base", "/reports/maintenance", "/campaigns"], false],
    // Since 0005 My schedule (roster.view) follows My hours in the Time group
    ["agent-one", ["/", "/messages", "/day", "/hours", "/schedule"], true],
    ["supervisor", ["/", "/messages", "/live/newco", "/day", "/hours", "/schedule", "/team/hours", "/reports/flash", "/reports/dashboard", "/reports/calls",
      "/reports/calls-per-agent", "/reports/inbound", "/reports/email", "/reports/email-per-agent", "/reports/intake", "/reports/forms",
      "/reports/speed-to-lead", "/reports/follow-up", "/reports/funnel", "/reports/attempts", "/reports/attempts-per-agent", "/reports/lead-cohorts",
      "/reports/first-orders", "/reports/orders-per-person", "/reports/active", "/reports/courtesy", "/reports/reviews", "/reports/cancellations", "/reports/installed-base", "/reports/maintenance", "/campaigns"], true],
    // Since 0004 the Team group sits between Live and Time for people who manage others (manager, admin), since 0008zw
    // between Time and Reports; the supervisor and the agent see no Team group, so their keys do not move. The planner
    // (0005) joins it.
    ["manager", ["/", "/messages", "/live/newco", "/day", "/hours", "/schedule", "/team/hours", "/team/people", "/roster/planner", "/reports/flash",
      "/reports/dashboard", "/reports/calls", "/reports/calls-per-agent", "/reports/inbound", "/reports/email", "/reports/email-per-agent",
      "/reports/intake", "/reports/forms", "/reports/data-quality", "/reports/speed-to-lead", "/reports/follow-up", "/reports/funnel",
      "/reports/attempts", "/reports/attempts-per-agent", "/reports/lead-cohorts", "/reports/first-orders", "/reports/orders-per-person",
      "/reports/active", "/reports/courtesy", "/reports/reviews", "/reports/cancellations", "/reports/installed-base", "/reports/maintenance", "/campaigns"], true],
    ["admin", ["/", "/messages", "/live/newco", "/day", "/hours", "/schedule", "/team/hours", "/team/people", "/roster/planner", "/reports/flash",
      "/reports/dashboard", "/reports/calls", "/reports/calls-per-agent", "/reports/inbound", "/reports/email", "/reports/email-per-agent",
      "/reports/intake", "/reports/forms", "/reports/data-quality", "/reports/speed-to-lead", "/reports/follow-up", "/reports/funnel",
      "/reports/attempts", "/reports/attempts-per-agent", "/reports/lead-cohorts", "/reports/first-orders", "/reports/orders-per-person",
      "/reports/active", "/reports/courtesy", "/reports/reviews", "/reports/cancellations", "/reports/installed-base", "/reports/maintenance", "/campaigns"], true],
  ];
  for (const [subject, hrefs, clock] of cases) {
    const ctx = await b.newContext({ viewport: { width: 1440, height: 900 }, extraHTTPHeaders: { "x-cma-mock-subject": subject } });
    const p = await ctx.newPage();
    await p.goto(BASE + "/");
    await settle(p);
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
    await settle(p);
    await p.waitForLoadState("networkidle");
    const accountPath = new URL(p.url()).pathname;
    const accountTitle = await p.locator("main h1").first().textContent().catch(() => null);
    if (accountPath !== "/account" || !accountTitle) problems.push(`${subject}: My account answered ${accountPath} with title ${JSON.stringify(accountTitle)}`);
    await p.screenshot({ path: `${outDir}/${subject}-account.png` });
    if (!clock) {
      await p.goto(BASE + "/day");
      await settle(p);
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
    await settle(p);
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
    "/reports/first-orders", "/reports/orders-per-person", "/reports/lead-cohorts", "/reports/reviews", "/reports/courtesy", "/reports/active", "/reports/maintenance", "/reports/installed-base",
    "/reports/data-quality", "/reports/flash"]) {
    await p.goto(BASE + path);
    await settle(p);
    await p.waitForLoadState("networkidle");
    if (await p.locator("main table").count() > 0) problems.push(`agent-one ${path}: a report table is shown to an agent`);
  }
  // The reader (reports.view alone) sees no per-person table on Follow-up (performance.team only, 0008o)
  await p.goto(BASE + "/reports/follow-up");
  await settle(p);
  await p.waitForLoadState("networkidle");
  await ctx.close();
  const reader = await b.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": "reader" } });
  const rp = await reader.newPage();
  await rp.goto(BASE + "/reports/follow-up");
  await settle(rp);
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
    await settle(p);
    await p.waitForLoadState("networkidle");
    const rail = await p.evaluate(() => [...(document.querySelector("nav")?.querySelectorAll("a") ?? [])].map((a) => a.getAttribute("href")));
    if (rail.includes("/reports/calls") !== calls) problems.push(`${subject}: Calls ${calls ? "missing from" : "shown in"} the rail`);
    if (rail.includes("/reports/calls-per-agent") !== perAgent) problems.push(`${subject}: Calls per agent ${perAgent ? "missing from" : "shown in"} the rail`);
    for (const [path, may, table] of [["/reports/calls?range=month&group=day", calls, "tag-table"], ["/reports/calls-per-agent?range=month", perAgent, "agents-table"]]) {
      const where = `${subject} ${path.split("?")[0]}`;
      await p.goto(BASE + path);
      await settle(p);
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
          await settle(p);
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
    await settle(p);
    await p.waitForLoadState("networkidle");
    const rail = await p.evaluate(() => [...(document.querySelector("nav")?.querySelectorAll("a") ?? [])].map((a) => a.getAttribute("href")));
    if (rail.includes("/reports/email") !== email) problems.push(`${subject}: Email ${email ? "missing from" : "shown in"} the rail`);
    if (rail.includes("/reports/email-per-agent") !== perAgent) problems.push(`${subject}: Email per agent ${perAgent ? "missing from" : "shown in"} the rail`);
    for (const [path, may, scroll, table] of [["/reports/email?range=month&group=day", email, "email-by-inbox-scroll", "email-by-inbox"],
      ["/reports/email-per-agent?range=month", perAgent, "email-agents-scroll", "email-agents-table"]]) {
      const where = `${subject} ${path.split("?")[0]}`;
      const r = await p.goto(BASE + path);
      await settle(p);
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
    await settle(p);
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
      await settle(p);
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
    await settle(p);
    await p.waitForLoadState("networkidle");
    const rail = await p.evaluate(() => [...(document.querySelector("nav")?.querySelectorAll("a") ?? [])].map((a) => a.getAttribute("href")));
    if (rail.includes("/campaigns") !== may) problems.push(`${subject}: Campaign monitoring ${may ? "missing from" : "shown in"} the rail`);
    await p.goto(BASE + "/campaigns");
    await settle(p);
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
      await settle(p);
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
        await settle(p);
        if (r?.status() !== 404) problems.push(`${subject} /campaigns/${code}: answers ${r?.status()}, expected 404`);
      }
    }
    await ctx.close();
  }
  // the breadcrumbs of a journey's page: Welcome › Campaigns › the journey (the analyst, whose urgent message is read)
  const ctx = await b.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": "analyst" } });
  const p = await ctx.newPage();
  await p.goto(BASE + "/campaigns/opc");
  await settle(p);
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
    await settle(p);
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
      await settle(p);
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
    await settle(p);
    await p.waitForLoadState("networkidle");
    const rail = await p.evaluate(() => [...(document.querySelector("nav")?.querySelectorAll("a") ?? [])].map((a) => a.getAttribute("href")));
    if (rail.includes("/reports/forms") !== may) problems.push(`${subject}: Forms ${may ? "missing from" : "shown in"} the rail`);
    const where = `${subject} /reports/forms`;
    await p.goto(BASE + "/reports/forms?range=month&group=day");
    await settle(p);
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
        await settle(p);
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

// Inbound today's tiles in their order (addition 0009k; Martin, 10 November 2026), by test id, not by text
const INBOUND_ORDER = ["offered", "answered", "unansweredPct", "serviceLevel", "talk", "avgAnswer"].map((k) => `inbound-${k}`).join(",");

// The Live board per identity (addition 0008i): at 1280 px the inbound tiles, the missed calls and the
// people board without horizontal scrolling, a tile's hint inside the viewport; a tenant without telephony
// says so in words; an agent gets the no-permission card and no inbound figures
async function expectLiveBoard() {
  // Since addition 0008zv one board per contact center: /live/board opens the first one's (Newco's, /live/newco), every
  // part of the board as before; the invest analyst's tenant has no contact center, so no Live group and /live/board shows
  // the not-found page (a soft 404 behind the board's loading boundary, Martin, 5 November 2026; a tenant without
  // telephony still says so on Reports → Inbound, expectReports)
  for (const [subject, telephony] of [["supervisor", true], ["manager", true], ["admin", true], ["analyst", true], ["invest-analyst", "none"], ["agent-one", null]]) {
    const ctx = await b.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": subject } });
    const p = await ctx.newPage();
    await p.goto(BASE + "/live/board");
    if (telephony === "none") {
      const shown = await p.locator('[data-testid="not-found-page"]').waitFor({ state: "visible", timeout: 10_000 }).then(() => true, () => false);
      const live = await p.locator('nav[data-rail-nav] button[aria-controls="nav-group-live"]').count();
      if (!shown || live > 0) problems.push(`${subject} /live/board: ${shown ? "the not-found page" : "no not-found page"} with ${live} Live group, expected the not-found page and none in a tenant without a contact center`);
      await ctx.close();
      continue;
    }
    await settle(p);
    await p.waitForLoadState("networkidle");
    if (telephony === null) {
      // without monitoring.live the address shows the no-permission card, whatever the key (the permission first)
      if (await p.locator('[data-testid="inbound-live"]').count() > 0) problems.push(`${subject} /live/board: inbound figures shown to someone without the Live board`);
      await ctx.close();
      continue;
    }
    if (new URL(p.url()).pathname !== "/live/newco") problems.push(`${subject} /live/board: opened ${new URL(p.url()).pathname}, expected Newco's board /live/newco`);
    if (provoke && subject === "supervisor") await p.evaluate(() => { const t = document.querySelector('[data-testid="inbound-tiles"]'); if (t) t.style.width = "2400px"; });
    // --provoke puts Missed, not called back back above the team (where it sat before 0008z)
    if (provoke && subject === "analyst") await p.evaluate(() => { const m = document.querySelector('[data-testid="missed-live"]'); const t = document.querySelector('[data-testid="inbound-live"]'); if (m && t) t.after(m); });
    // --provoke moves Inbound today's Talk time to the end of its row (where Waiting now sat before 0009k)
    if (provoke && subject === "admin") await p.evaluate(() => { const t = document.querySelector('[data-testid="inbound-talk"]'); t?.parentElement?.append(t); });
    const m = await p.evaluate((strip) => {
      const main = document.querySelector("main");
      // A name on a plain div or span needs a role (the tiles group, the IT audit of 17 October 2026); --provoke strips it
      if (strip) document.querySelector('main div[role="group"][aria-label]')?.removeAttribute("role");
      return {
        scrollX: document.documentElement.scrollWidth > window.innerWidth,
        mainX: main ? main.scrollWidth - main.clientWidth : -1,
        tiles: document.querySelectorAll('[data-testid="inbound-tiles"] [data-tile]').length,
        // Inbound today since addition 0009k: the six tiles in their order by test id, Talk time in place of Waiting now
        inboundOrder: [...document.querySelectorAll('[data-testid="inbound-tiles"] [data-tile]')].map((el) => el.getAttribute("data-testid")).join(","),
        waitingNow: !!document.querySelector('[data-testid="inbound-waitingNow"]'),
        // Outbound today (addition 0009h): six tiles between Inbound today and Follow-up now; no Longest waiting anywhere
        outboundTiles: document.querySelectorAll('[data-testid="outbound-tiles"] [data-tile]').length,
        outboundBetween: (() => {
          const order = [...document.querySelectorAll('[data-testid="inbound-live"], [data-testid="outbound-live"], [data-testid="follow-up-live"]')].map((el) => el.getAttribute("data-testid"));
          return order.join(",") === "inbound-live,outbound-live,follow-up-live";
        })(),
        // the tile and the tiles' labels only: the page's text may say "longest waiting" elsewhere (a follow-up hint does)
        longestWaiting: !!document.querySelector('[data-testid="inbound-longestWaiting"]')
          || [...document.querySelectorAll("[data-tile] p")].some((el) => (el.firstChild?.textContent ?? "").trim() === "Longest waiting"),
        missed: !!document.querySelector('[data-testid="missed-callbacks"]'),
        // the call parts and the follow-up strip stay tenant-wide on a contact center's board and say so (addition 0008zv)
        scopes: [...document.querySelectorAll('[data-testid="inbound-scope"], [data-testid="outbound-scope"], [data-testid="missed-scope"], [data-testid="follow-up-scope"]')].map((el) => el.textContent ?? ""),
        unnamedLabels: [...document.querySelectorAll("main div[aria-label], main span[aria-label]")].filter((el) => !el.getAttribute("role")).length,
        // Missed, not called back is the board's last section since 0008z: the last heading in main is its own
        lastHeading: [...document.querySelectorAll("main h2")].at(-1)?.closest('[data-testid="missed-live"]') !== null,
      };
    }, provoke && subject === "manager");
    if (m.unnamedLabels > 0) problems.push(`${subject} /live/board: ${m.unnamedLabels} div or span carries aria-label without a role`);
    if (m.scrollX) problems.push(`${subject} /live/board: page scrolls horizontally at 1280`);
    if (m.mainX > 0) problems.push(`${subject} /live/board: the main area scrolls sideways by ${m.mainX}px at 1280`);
    if (telephony && (m.tiles !== 6 || !m.missed)) problems.push(`${subject} /live/board: ${m.tiles} inbound tiles and ${m.missed ? "a" : "no"} missed-calls table, expected 6 and a table`);
    if (telephony && (m.outboundTiles !== 6 || !m.outboundBetween)) problems.push(`${subject} /live/board: ${m.outboundTiles} outbound tiles${m.outboundBetween ? "" : ", not between Inbound today and Follow-up now"}, expected 6 between them`);
    if (!telephony && m.outboundTiles !== 0) problems.push(`${subject} /live/board: outbound tiles without telephony`);
    if (m.longestWaiting) problems.push(`${subject} /live/board: Longest waiting is still on the board`);
    if (telephony && m.inboundOrder !== INBOUND_ORDER) problems.push(`${subject} /live/board: the inbound tiles read ${m.inboundOrder}, expected ${INBOUND_ORDER}`);
    if (m.waitingNow) problems.push(`${subject} /live/board: Waiting now is still on the board`);
    if (telephony) {
      // Talk time in the column of Outbound today's Talk time, at 1280 px (three to a row) and at 1536 px (six to a row)
      for (const width of [1280, 1536]) {
        if (width !== 1280) {
          await p.setViewportSize({ width, height: 900 });
          await settle(p);
        }
        const c = await p.evaluate(() => {
          const x = (id) => document.querySelector(`[data-testid="${id}"]`)?.getBoundingClientRect().left ?? null;
          return {
            order: [...document.querySelectorAll('[data-testid="inbound-tiles"] [data-tile]')].map((el) => el.getAttribute("data-testid")).join(","),
            inbound: x("inbound-talk"), outbound: x("outbound-talk"),
          };
        });
        if (c.order !== INBOUND_ORDER) problems.push(`${subject} /live/board at ${width}: the inbound tiles read ${c.order}, expected ${INBOUND_ORDER}`);
        if (c.inbound === null || c.outbound === null || Math.abs(c.inbound - c.outbound) > 1) {
          problems.push(`${subject} /live/board at ${width}: Inbound today's Talk time at ${c.inbound} px, Outbound today's at ${c.outbound} px, expected one column`);
        }
      }
      await p.setViewportSize({ width: 1280, height: 800 });
      await settle(p);
    }
    if (telephony && !m.lastHeading) problems.push(`${subject} /live/board: Missed, not called back is not the board's last section`);
    if (telephony && (m.scopes.length !== 4 || !m.scopes.every((x) => x.includes("Newco")))) problems.push(`${subject} /live/board: ${m.scopes.length} captions on the call parts and the follow-up strip naming Newco, expected 4`);
    if (telephony) {
      const mark = p.locator('[data-testid="outbound-talkAvg"] button[data-header-hint]');
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
    if (telephony) {
      // The Live board's UX pass (10 November 2026), at 1280 x 800: every call and follow-up figure on the first screen,
      // each panel one row with its figures on one line, the people's columns all in view without the table scrolling
      // sideways, no Employer column or filter on a board whose people have one employer, the freshness on the title row
      // --provoke puts the outbound panel's figures on two rows (the cards of before)
      if (provoke && subject === "manager") await p.evaluate(() => { const g = document.querySelector('[data-testid="outbound-tiles"]'); if (g) g.style.gridTemplateColumns = "repeat(3, minmax(0, 1fr))"; });
      await p.evaluate(() => document.querySelector("main")?.scrollTo(0, 0));
      const u = await p.evaluate(() => {
        const rows = (id) => {
          const cells = [...document.querySelectorAll(`[data-testid="${id}"] [data-tile]`)];
          const tops = new Set(cells.map((c) => Math.round(c.getBoundingClientRect().top)));
          const feet = new Set(cells.map((c) => Math.round(c.lastElementChild?.getBoundingClientRect().bottom ?? 0)));
          return { n: cells.length, rows: tops.size, feet: feet.size };
        };
        const scroll = document.querySelector('[data-testid="live-people-scroll"]');
        const header = document.querySelector("main header");
        return {
          panels: ["inbound-tiles", "outbound-tiles", "follow-up-tiles"].map(rows),
          followUpBottom: Math.round(document.querySelector('[data-testid="follow-up-live"]')?.getBoundingClientRect().bottom ?? 9999),
          tableX: scroll ? scroll.scrollWidth - scroll.clientWidth : -1,
          employerFilter: !!document.querySelector('select[data-shortcut="e"]'),
          freshnessInTitle: !!header?.querySelector('[data-testid="live-freshness"]'),
        };
      });
      for (const [i, id] of ["Inbound today", "Outbound today", "Follow-up now"].entries()) {
        const x = u.panels[i];
        if (x.n !== 6 || x.rows !== 1 || x.feet !== 1) problems.push(`${subject} /live/board: ${id} has ${x.n} figures on ${x.rows} row(s), their figures on ${x.feet} line(s), expected 6 on one row, on one line`);
      }
      if (u.followUpBottom > 800) problems.push(`${subject} /live/board: Follow-up now ends at ${u.followUpBottom} px, expected every call and follow-up figure on the first screen (800 px)`);
      if (u.tableX > 0) problems.push(`${subject} /live/board: the people's table scrolls sideways by ${u.tableX} px at 1280`);
      if (u.employerFilter) problems.push(`${subject} /live/board: an Employer filter on a board whose people have one employer`);
      if (!u.freshnessInTitle) problems.push(`${subject} /live/board: the board's freshness is not on the title row`);
      // Inbound today by hour: 24 hours, a column's figures on focus inside the viewport
      const hoursShown = await p.locator('[data-testid="inbound-hours"] [data-hour], [data-testid="inbound-hours-empty"]').first()
        .waitFor({ state: "attached", timeout: 10_000 }).then(() => true, () => false);
      const hourCount = await p.locator('[data-testid="inbound-hours"] [data-hour]').count();
      if (!hoursShown || (hourCount !== 24 && (await p.locator('[data-testid="inbound-hours-empty"]').count()) === 0)) {
        problems.push(`${subject} /live/board: Inbound today by hour shows ${hourCount} hours, expected 24 (or its empty state)`);
      } else if (hourCount === 24) {
        const busy = p.locator('[data-testid="inbound-hours"] [data-hour]').filter({ has: p.locator("span") }).first();
        await busy.focus();
        const tip = await p.evaluate(() => {
          const el = document.querySelector('[data-testid="inbound-hours-tip"]');
          if (!el) return null;
          const r = el.getBoundingClientRect();
          return r.left >= 0 && r.right <= window.innerWidth && r.top >= 0;
        });
        if (tip === null) problems.push(`${subject} /live/board: an hour's figures do not show on focus`);
        else if (!tip) problems.push(`${subject} /live/board: an hour's figures leave the viewport`);
      }
    }
    await p.screenshot({ path: `${outDir}/${subject}-live-board.png` });
    // An unflagged or unknown organisation's board shows the not-found page, no board (Martin, 5 November 2026: the
    // skeleton stays, so the status is 200, a soft 404; the UI is what counts)
    if (subject === "supervisor") {
      // The Live board's word on its own freshness (10 November 2026): with every poll failing, the board says after two
      // that its figures are old; --provoke lets the polls answer, so the warning never comes
      const stale = await b.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": subject } });
      const sp = await stale.newPage();
      await sp.clock.install();
      // the chart's read fails from the start too: it says so calmly instead of loading for ever
      if (!provoke) await sp.route("**/api/v1/reports/inbound**", (r) => r.abort());
      await sp.goto(BASE + "/live/newco");
      await settle(sp);
      const hoursFailed = await sp.locator('[data-testid="inbound-hours-failed"]').waitFor({ state: "visible", timeout: 10_000 }).then(() => true, () => false);
      if (!hoursFailed) problems.push(`${subject} /live/newco: no word that Inbound today by hour could not be read`);
      if (!provoke) await sp.route("**/api/v1/live/board**", (r) => r.abort());
      // in steps, so each failed poll's answer lands before the clock moves on (polls at 10 s, then 30 s: the wait doubles)
      for (let i = 0; i < 4; i++) {
        await sp.clock.runFor(10_000);
        await sp.waitForTimeout(300);
      }
      const said = await sp.locator('[data-testid="live-stale"]').waitFor({ state: "visible", timeout: 5_000 }).then(() => true, () => false);
      if (!said) problems.push(`${subject} /live/newco: no word that the figures are old after two failed polls`);
      await stale.close();
      for (const path of ["/live/pulse4all", "/live/no-such-organisation"]) {
        await p.goto(BASE + path);
        const shown = await p.locator('[data-testid="not-found-page"]').waitFor({ state: "visible", timeout: 10_000 }).then(() => true, () => false);
        const board = await p.locator("[data-live-board-read-at]").count();
        if (!shown || board > 0) problems.push(`${subject} ${path}: ${shown ? "the" : "no"} not-found page and ${board} board, expected the not-found page and no board`);
      }
    }
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
    for (const path of ["/live/newco", "/reports/speed-to-lead?range=month", "/reports/follow-up"]) {
      const where = `manager ${path} at ${tag}`;
      const before = problems.length;
      const ctx = await b.newContext({ viewport: { width, height }, extraHTTPHeaders: { "x-cma-mock-subject": "manager" } });
      const p = await ctx.newPage();
      await p.goto(BASE + path);
      await settle(p);
      await p.waitForLoadState("networkidle");
      if (provoke) await unfix(p);
      if (path === "/live/newco" && await p.locator('[data-testid="missed-callbacks"]').count() === 0) problems.push(`${where}: the fixture's missed calls are missing`);
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
      if (path === "/live/newco" && tag === "1280x800" && natural <= m.clientHeight) problems.push(`${where}: the board fits in main (${Math.round(natural)}px in ${m.clientHeight}px), so the check has no page longer than the window`);
      if (natural > m.clientHeight) {
        if (m.scrollHeight <= m.clientHeight || wheeled <= 0) problems.push(`${where}: the content is ${Math.round(natural)}px in a ${m.clientHeight}px main, which the wheel does not scroll (scrollHeight ${m.scrollHeight}, moved ${wheeled}px)`);
        if (m.lastBottom > m.mainBottom + 1) problems.push(`${where}: at the bottom of main its last line ends at ${Math.round(m.lastBottom)}px, below main's ${Math.round(m.mainBottom)}px`);
      }
      if (m.probes.some((ok) => !ok)) problems.push(`${where}: a fixed element in the ${m.probes[0] ? "content" : "top bar"} no longer sits 24px from the window's bottom right`);
      const ok = problems.length === before;
      console.log(`${ok ? "PASS" : "FAIL"}  frame does not scroll: ${path} at ${tag}${natural > m.clientHeight ? ", main scrolls" : ", fits"}`);
      if (path === "/live/newco") await p.screenshot({ path: `${outDir}/manager-live-board-bottom-${tag}.png` });
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
    await settle(p);
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

// The gate below FIT_FLOOR_PX (softened on 9 November 2026): the message in the page's language, saying how to make the
// window wide enough, with the number built from FIT_FLOOR_PX, and the app not rendered. --provoke expects the old gate's
// number (DESIGN_WIDTH_PX) in the message
async function expectGate(width, height) {
  const p = await b.newPage({ viewport: { width, height } });
  await p.goto(BASE + "/");
  await settle(p);
  const gate = await p.locator('[data-testid="desktop-only"]').isVisible();
  const shell = await p.locator("nav").isVisible();
  if (!gate || shell) problems.push(`${width}x${height}: expected the desktop-only gate, got the app`);
  const shown = await p.evaluate(() => {
    const g = document.querySelector('[data-testid="desktop-only"]');
    return { lang: document.documentElement.lang, title: g?.querySelector("h1")?.textContent ?? "", body: g?.querySelector("p")?.textContent ?? "" };
  });
  const words = (copy[shown.lang] ?? copy.en).desktopOnly;
  const body = words.body.replace("{px}", String(provoke ? DESIGN_WIDTH_PX : FIT_FLOOR_PX));
  if (shown.title !== words.title) problems.push(`${width}x${height}: the gate's title is "${shown.title}", expected "${words.title}"`);
  if (shown.body !== body) problems.push(`${width}x${height}: the gate says "${shown.body}", expected "${body}"`);
  await p.screenshot({ path: `${outDir}/${width}x${height}-gate.png` });
  await p.close();
}

// The desktop fit (9 November 2026, src/lib/desktop-fit.ts): from FIT_FLOOR_PX to just under DESIGN_WIDTH_PX the app renders
// its DESIGN_WIDTH_PX layout zoomed to the window, while media queries read the real window. At 1279, 1216 and 1152 px: the
// app and not the gate, the zoom the window over 1280 (within 0.005), laid out 1280 px wide, the rail and the top bar at their
// tokens, no horizontal page scroll; on the pages checked at 1280 the main area never sideways and every grid in main with
// the columns it has at 1280 (xl: lowered to the floor); the Follow-up open links in their tables' view (the pinned link
// column), the roster's week bar on one line, the Invite dialog inside the window and centred at its 1280 width. At 1216:
// the frame fixed (the wheel and End scroll main, never the page; a fixed element 24 px times the zoom from the window's
// corner), a header hint next to its mark within 4 px, without JavaScript the unscaled layout (and the gate at 1151), a
// resize from 1400 to 1200 to 1100 to 1400 without a reload, and the roster's print view at A4 printing as it does from
// 1280 (zoom 1, the same pages, page 1 the same to the eye). --provoke at 1216 takes the zoom away on Welcome, widens main's
// content on the first page, gives Flash's cards two columns, unpins the Follow-up link column, narrows the week bar,
// shifts the Invite dialog, lets the page scroll under the frame, places the hint as before (unscaled), expects the zoom
// without JavaScript, freezes the zoom across the resize and zooms the print
const FIT_WIDTHS = [DESIGN_WIDTH_PX - 1, (DESIGN_WIDTH_PX + FIT_FLOOR_PX) / 2, FIT_FLOOR_PX];
const FIT_MID = FIT_WIDTHS[1];
const FIT_PAGES = {
  manager: ["/reports/flash", "/reports/dashboard?range=month", "/reports/speed-to-lead?range=month", "/reports/follow-up",
    "/reports/intake?range=month", "/reports/inbound?range=month", "/reports/data-quality", "/reports/calls?range=month&group=day",
    "/reports/calls-per-agent?range=month", "/reports/forms?range=month&group=day", "/reports/email?range=month&group=day",
    "/reports/email-per-agent?range=month", "/reports/first-orders?range=month&group=day", "/reports/orders-per-person?range=month",
    "/reports/attempts?range=month&group=day", "/reports/attempts-per-agent?range=month", "/reports/funnel?range=month",
    "/reports/cancellations?range=month", "/reports/installed-base", "/live/newco", "/campaigns", "/campaigns/opc", "/roster/planner"],
  admin: ["/team/people", "/configuration/sources", "/configuration/sources/00000000-0000-7000-8000-00000000c002", "/configuration/markets",
    "/configuration/alert-rules"],
};

/** The open page under the fit, in the layout's own pixels (window pixels over the zoom) */
function fitOf(p) {
  return p.evaluate(() => {
    const zoom = parseFloat(getComputedStyle(document.documentElement).zoom) || 1;
    const gate = document.querySelector('[data-testid="desktop-only"]');
    const nav = document.querySelector("nav");
    const header = document.querySelector("header");
    const main = document.querySelector("main");
    window.scrollTo(100000, 0);
    const pageX = window.scrollX;
    window.scrollTo(0, 0);
    return {
      zoom,
      gate: !!gate && getComputedStyle(gate).display !== "none",
      app: !!nav && nav.getClientRects().length > 0,
      layout: document.documentElement.getBoundingClientRect().width / zoom,
      rail: nav ? nav.getBoundingClientRect().width / zoom : 0,
      topbar: header ? header.getBoundingClientRect().height / zoom : 0,
      content: main?.querySelector("div") ? main.querySelector("div").getBoundingClientRect().width / zoom : 0,
      pageX,
      mainX: main ? main.scrollWidth - main.clientWidth : 0,
    };
  });
}

/** Two frames, so a resize has been handled and laid out */
const frames = (p) => p.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));

/** The column count of every grid in main, in document order: what a breakpoint (xl: lowered to the floor) decides */
const gridsOf = (p) => p.evaluate(() => [...document.querySelectorAll("main *")]
  .filter((el) => /grid/.test(getComputedStyle(el).display))
  .map((el) => getComputedStyle(el).gridTemplateColumns.split(" ").length));

async function expectFit() {
  // Every page's grids at the design width, to compare the band's with: a breakpoint up to 1280 must hold from the floor
  const reference = {};
  for (const [subject, paths] of Object.entries(FIT_PAGES)) {
    const ctx = await b.newContext({ viewport: { width: DESIGN_WIDTH_PX, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": subject } });
    const p = await ctx.newPage();
    for (const path of paths) {
      await p.goto(BASE + path);
      await settle(p);
      await p.waitForLoadState("networkidle");
      reference[`${subject} ${path}`] = await gridsOf(p);
    }
    await ctx.close();
  }
  for (const width of FIT_WIDTHS) {
    const tag = `${width}x800`;
    const want = width / DESIGN_WIDTH_PX;
    const before = problems.length;
    const fitted = (where, m) => {
      if (m.gate || !m.app) problems.push(`${where}: ${m.gate ? "the desktop-only gate shows" : "the app is not rendered"}, expected the app scaled to the window`);
      if (Math.abs(m.zoom - want) > 0.005) problems.push(`${where}: the zoom is ${m.zoom}, expected ${want.toFixed(4)} (the window over ${DESIGN_WIDTH_PX})`);
      if (m.pageX > 0) problems.push(`${where}: the page scrolls horizontally`);
      if (m.mainX > 0) problems.push(`${where}: the main area scrolls sideways by ${m.mainX}px`);
    };
    for (const [subject, paths] of Object.entries(FIT_PAGES)) {
      const ctx = await b.newContext({ viewport: { width, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": subject } });
      const p = await ctx.newPage();
      if (subject === "manager") {
        // The shell on Welcome: the design width's layout, its tokens
        await p.goto(BASE + "/");
        await settle(p);
        await p.waitForLoadState("networkidle");
        if (provoke && width === FIT_MID) await p.evaluate(() => { const s = document.getElementById("cma-fit"); if (s) s.textContent = ""; });
        const m = await fitOf(p);
        fitted(tag, m);
        if (Math.abs(m.layout - DESIGN_WIDTH_PX) > 1) problems.push(`${tag}: laid out ${m.layout.toFixed(1)}px wide, expected the design width, ${DESIGN_WIDTH_PX}`);
        if (Math.round(m.rail) !== 256) problems.push(`${tag}: the rail is ${m.rail.toFixed(1)}px in the layout, token says 256`);
        if (Math.round(m.topbar) !== 56) problems.push(`${tag}: the top bar is ${m.topbar.toFixed(1)}px in the layout, token says 56`);
        if (m.content > 896.5) problems.push(`${tag}: the content column is ${m.content.toFixed(1)}px in the layout, wider than max-w-4xl`);
        await p.screenshot({ path: `${outDir}/${tag}-fit.png` });
      }
      for (const [i, path] of paths.entries()) {
        await p.goto(BASE + path);
        await settle(p);
        await p.waitForLoadState("networkidle");
        if (provoke && width === FIT_MID && subject === "manager" && i === 0) {
          await p.evaluate(() => { const d = document.createElement("div"); Object.assign(d.style, { width: "2400px", height: "1px" }); document.querySelector("main").appendChild(d); });
        }
        fitted(`${subject} ${path} at ${tag}`, await fitOf(p));
        const where = `${subject} ${path.split("?")[0]} at ${tag}`;
        // The grids as at 1280 (Flash's cards four across, its totals five, the two-column report sections); --provoke
        // gives Flash's cards two columns
        if (provoke && width === FIT_MID && path === "/reports/flash") {
          await p.evaluate(() => { const g = document.querySelector('[data-testid="flash-cards"]'); if (g) g.style.gridTemplateColumns = "1fr 1fr"; });
        }
        const grids = await gridsOf(p);
        const ref = reference[`${subject} ${path}`];
        if (ref.length === 0 && path === "/reports/flash") problems.push(`${where}: no grid in main to compare with 1280`);
        if (JSON.stringify(grids) !== JSON.stringify(ref)) problems.push(`${where}: the grids in main have ${JSON.stringify(grids)} columns, at ${DESIGN_WIDTH_PX} ${JSON.stringify(ref)}`);
        // The pinned link column (Follow-up's tables): every open link in its table's view, the table scrolled or not
        if (path === "/reports/follow-up") {
          const links = await p.evaluate((unpin) => {
            const tables = [...document.querySelectorAll('table[data-testid^="follow-up-"]')].filter((t) => t.querySelector("tbody tr td:last-child a"));
            return tables.map((t) => {
              const box = t.parentElement;
              if (unpin) {
                for (const c of t.querySelectorAll("tr > :last-child")) c.style.position = "static";
                t.style.minWidth = "2400px";
              }
              const r = box.getBoundingClientRect();
              const a = t.querySelector("tbody tr td:last-child a").getBoundingClientRect();
              return { id: t.dataset.testid, inView: a.width > 0 && a.left >= r.left - 0.5 && a.right <= r.right + 0.5 && a.right <= window.innerWidth };
            });
          }, provoke && width === FIT_MID);
          if (links.length === 0) problems.push(`${where}: no Follow-up table with an open link to check`);
          for (const x of links) if (!x.inView) problems.push(`${where}: ${x.id}'s open link is out of its table's view`);
        }
        // The roster's week bar: the three week links on one line
        if (path === "/roster/planner") {
          const bar = await p.evaluate((narrow) => {
            const links = [...document.querySelectorAll('main nav a[data-shortcut="p"], main nav a[data-shortcut="w"], main nav a[data-shortcut="n"]')];
            if (narrow && links[0]) links[0].closest("nav").style.width = "200px";
            return { n: links.length, lines: new Set(links.map((a) => Math.round(a.getBoundingClientRect().top))).size };
          }, provoke && width === FIT_MID);
          if (bar.n !== 3 || bar.lines !== 1) problems.push(`${where}: the week links are ${bar.n} on ${bar.lines} lines, expected 3 on one line`);
        }
        // A dialog: the Invite dialog inside the window, centred, at its width at 1280 (44rem) in the layout
        if (path === "/team/people") {
          await p.keyboard.press("v");
          await p.locator('[data-testid="invite-dialog"][open]').waitFor({ timeout: 5000 }).catch(() => undefined);
          const d = await p.evaluate((shift) => {
            const dialog = document.querySelector('[data-testid="invite-dialog"][open]');
            if (!dialog) return null;
            if (shift) dialog.style.marginLeft = "0";
            const z = dialog.currentCSSZoom || 1;
            const r = dialog.getBoundingClientRect();
            return {
              inside: r.top >= 0 && r.left >= 0 && r.bottom <= window.innerHeight + 0.5 && r.right <= window.innerWidth + 0.5,
              centred: Math.abs(r.left - (window.innerWidth - r.right)) <= 1,
              width: r.width / z,
            };
          }, provoke && width === FIT_MID);
          if (!d) problems.push(`${where}: V does not open the Invite dialog`);
          else {
            if (!d.inside) problems.push(`${where}: the Invite dialog is not inside the window`);
            if (!d.centred) problems.push(`${where}: the Invite dialog is not centred in the window`);
            if (Math.round(d.width) !== 704) problems.push(`${where}: the Invite dialog is ${d.width.toFixed(1)}px wide in the layout, expected 704 (44rem) as at 1280`);
          }
          await p.keyboard.press("Escape");
        }
      }
      await ctx.close();
    }
    console.log(`${problems.length === before ? "PASS" : "FAIL"}  fit at ${tag}: zoom ${want.toFixed(4)}, the ${DESIGN_WIDTH_PX} px layout on Welcome and ${FIT_PAGES.manager.length + FIT_PAGES.admin.length} pages`);
  }

  const tag = `${FIT_MID}x800`;
  // The frame fixed under the zoom (23 October 2026): the wheel and End move main, never the page; a fixed element 24 px
  // (in the layout) from the window's corner
  {
    const before = problems.length;
    const ctx = await b.newContext({ viewport: { width: FIT_MID, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": "manager" } });
    const p = await ctx.newPage();
    await p.goto(BASE + "/live/newco");
    await settle(p);
    await p.waitForLoadState("networkidle");
    // --provoke puts the frame of before back, as expectFrameFixed's does
    if (provoke) await p.evaluate(() => {
      Object.assign(document.querySelector(".cma-frame").style, { gridTemplateRows: "var(--spacing-topbar) 1fr", overflow: "visible" });
      Object.assign(document.querySelector("main").style, { position: "static", minHeight: "auto" });
      Object.assign(document.querySelector("nav[data-rail-nav]").style, { overflow: "visible", minHeight: "auto" });
    });
    await p.locator("main h1").first().click();
    const box = await p.locator("main").boundingBox();
    await p.mouse.move(box.x + box.width / 2, box.y + Math.min(box.height, 800 - box.y) / 2);
    await p.mouse.wheel(0, 20000);
    await p.waitForTimeout(300);
    await p.keyboard.press("End");
    await p.waitForTimeout(400);
    const m = await p.evaluate(() => {
      const zoom = parseFloat(getComputedStyle(document.documentElement).zoom) || 1;
      const el = document.createElement("div");
      Object.assign(el.style, { position: "fixed", right: "24px", bottom: "24px", width: "8px", height: "8px" });
      document.querySelector("main").appendChild(el);
      const r = el.getBoundingClientRect();
      el.remove();
      return { y: window.scrollY, main: document.querySelector("main").scrollTop, right: (window.innerWidth - r.right) / zoom, bottom: (window.innerHeight - r.bottom) / zoom };
    });
    if (m.y !== 0) problems.push(`manager /live/newco at ${tag}: the wheel and End scrolled the page by ${m.y}px`);
    if (m.main <= 0) problems.push(`manager /live/newco at ${tag}: the wheel and End did not scroll main`);
    if (Math.abs(m.right - 24) > 1 || Math.abs(m.bottom - 24) > 1) problems.push(`manager /live/newco at ${tag}: a fixed element sits ${m.right.toFixed(1)} and ${m.bottom.toFixed(1)}px from the window's corner in the layout, expected 24`);
    console.log(`${problems.length === before ? "PASS" : "FAIL"}  fit at ${tag}: the frame fixed, main scrolls`);
    await ctx.close();
  }
  // A header hint opens next to its mark: below its header (above when there is no room), its left 12 px before the mark,
  // kept inside the window, all within 4 px. --provoke places it as before the fix, the window's pixels written unscaled
  {
    const before = problems.length;
    const ctx = await b.newContext({ viewport: { width: FIT_MID, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": "manager" } });
    const p = await ctx.newPage();
    for (const [path, mark] of [["/reports/speed-to-lead?range=month", '[data-testid="speed-summary"] th:nth-child(3) button[data-header-hint]'],
      ["/reports/speed-to-lead?range=month", '[data-testid="speed-summary"] th:nth-child(6) button[data-header-hint]']]) {
      await p.goto(BASE + path);
      await settle(p);
      await p.waitForLoadState("networkidle");
      const where = `manager ${path.split("?")[0]} ${mark.match(/nth-child\(\d+\)/)[0]} hint at ${tag}`;
      if (await p.locator(mark).count() !== 1) { problems.push(`${where}: the mark is missing`); continue; }
      await p.locator(mark).focus();
      const h = await p.evaluate((unscaled) => {
        const m = document.activeElement;
        const panel = document.getElementById(m.getAttribute("aria-describedby") ?? "");
        if (!panel || panel.hidden || getComputedStyle(panel).visibility !== "visible") return null;
        if (unscaled) {
          const z = panel.currentCSSZoom || 1;
          panel.style.top = `${parseFloat(panel.style.top) * z}px`;
          panel.style.left = `${parseFloat(panel.style.left) * z}px`;
        }
        const a = m.closest("th, [data-hint-anchor]").getBoundingClientRect();
        const k = m.getBoundingClientRect();
        const r = panel.getBoundingClientRect();
        const below = a.bottom + 6 + r.height + 8 <= window.innerHeight;
        return {
          top: r.top, left: r.left,
          wantTop: below ? a.bottom + 6 : Math.max(8, a.top - 6 - r.height),
          wantLeft: Math.max(8, Math.min(k.left - 12, window.innerWidth - r.width - 8)),
        };
      }, provoke);
      if (!h) problems.push(`${where}: the hint does not show on focus`);
      else if (Math.abs(h.top - h.wantTop) > 4 || Math.abs(h.left - h.wantLeft) > 4) {
        problems.push(`${where}: the panel sits at ${h.left.toFixed(1)}, ${h.top.toFixed(1)}, expected next to its mark at ${h.wantLeft.toFixed(1)}, ${h.wantTop.toFixed(1)}`);
      }
      await p.screenshot({ path: `${outDir}/manager-speed-to-lead-hint-${tag}.png` });
    }
    console.log(`${problems.length === before ? "PASS" : "FAIL"}  fit at ${tag}: a header hint next to its mark`);
    await ctx.close();
  }
  // Without JavaScript nothing scales: in the band the unscaled layout (zoom 1, the frame with its rail, the page never
  // sideways), below the floor the gate; never a broken page. --provoke expects the zoom without JavaScript
  {
    const before = problems.length;
    for (const width of [FIT_MID, FIT_FLOOR_PX - 1]) {
      const gate = width < FIT_FLOOR_PX;
      const ctx = await b.newContext({ javaScriptEnabled: false, viewport: { width, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": "manager" } });
      const p = await ctx.newPage();
      await p.goto(BASE + "/");
      const m = await fitOf(p);
      const want = provoke && !gate ? width / DESIGN_WIDTH_PX : 1;
      if (m.gate !== gate || m.app === gate) problems.push(`${width}x800 without JavaScript: ${m.gate ? "the gate" : "the app"} shows, expected ${gate ? "the gate" : "the app"}`);
      if (Math.abs(m.zoom - want) > 0.005) problems.push(`${width}x800 without JavaScript: the zoom is ${m.zoom}, expected ${want}`);
      if (!gate && Math.round(m.rail) !== 256) problems.push(`${width}x800 without JavaScript: the rail is ${m.rail.toFixed(1)}px, token says 256`);
      if (m.pageX > 0) problems.push(`${width}x800 without JavaScript: the page scrolls horizontally`);
      await p.screenshot({ path: `${outDir}/${width}x800-no-javascript.png` });
      await ctx.close();
    }
    console.log(`${problems.length === before ? "PASS" : "FAIL"}  fit without JavaScript: unscaled at ${FIT_MID}, the gate at ${FIT_FLOOR_PX - 1}`);
  }
  // A resize without a reload: 1400 (no zoom), 1200 (zoomed), 1100 (the gate), 1400 again. --provoke freezes the zoom: a copy
  // of the script's style element takes its place, so the script's updates no longer reach the page
  {
    const before = problems.length;
    const ctx = await b.newContext({ viewport: { width: 1400, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": "manager" } });
    const p = await ctx.newPage();
    await p.goto(BASE + "/");
    await settle(p);
    await p.waitForLoadState("networkidle");
    if (provoke) await p.evaluate(() => { const s = document.getElementById("cma-fit"); s?.replaceWith(s.cloneNode(true)); });
    for (const width of [1400, 1200, 1100, 1400]) {
      await p.setViewportSize({ width, height: 800 });
      await frames(p);
      const m = await fitOf(p);
      const gate = width < FIT_FLOOR_PX;
      const want = width < DESIGN_WIDTH_PX && !gate ? width / DESIGN_WIDTH_PX : 1;
      if (m.gate !== gate || m.app === gate) problems.push(`resize to ${width}: ${m.gate ? "the gate" : "the app"} shows, expected ${gate ? "the gate" : "the app"}`);
      if (!gate && Math.abs(m.zoom - want) > 0.005) problems.push(`resize to ${width}: the zoom is ${m.zoom}, expected ${want.toFixed(4)}`);
    }
    console.log(`${problems.length === before ? "PASS" : "FAIL"}  fit: resize 1400, 1200, 1100, 1400 without a reload`);
    await ctx.close();
  }
  // Print (8 October 2026): the zoom 1 on paper, and the roster's print view at A4 from the band as it prints from 1280: the
  // same page count, the same page size, and page 1 the same to the eye. Not the same bytes: Chromium writes the document's
  // title into the PDF's /Title, and the print view carries two titles, its own <title> (the week) and the app's metadata
  // title, whose order in <head> follows how the response streamed, so two identical sheets can differ in that one field
  // (seen with Playwright's chromium v1248, Chrome for Testing 156, 9 November 2026). Page 1 is rendered by Chromium's own
  // PDF viewer, in Playwright's full chromium (the headless shell has none; npx playwright install chromium installs both),
  // and compared pixel by pixel: at most 0.1 % of the pixels may differ by more than 32 in a channel. The footer names the
  // minute, so a pair that differs is made once more. On a failure both PDFs and both rendered pages go to OUT_DIR (and a
  // later pass removes them, as records/layout is tracked). --provoke zooms the paper to 0.9 from the band
  {
    const before = problems.length;
    const files = [`print-${DESIGN_WIDTH_PX}.pdf`, `print-${FIT_MID}.pdf`, `print-${DESIGN_WIDTH_PX}.png`, `print-${FIT_MID}.png`];
    const pdfOf = async (width) => {
      const ctx = await b.newContext({ viewport: { width, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": "manager" } });
      try {
        const p = await ctx.newPage();
        await p.goto(BASE + "/roster/planner/print");
        await settle(p);
        await p.waitForLoadState("networkidle");
        if (provoke && width === FIT_MID) await p.addStyleTag({ content: "@media print { html { zoom: 0.9 !important } }" });
        const pdf = await p.pdf({ preferCSSPageSize: true, printBackground: true });
        await p.emulateMedia({ media: "print" });
        const m = await p.evaluate(() => ({
          zoom: parseFloat(getComputedStyle(document.documentElement).zoom) || 1,
          sheet: !!document.querySelector('[data-testid="roster-print"] table')?.getClientRects().length,
          gate: getComputedStyle(document.querySelector('[data-testid="desktop-only"]')).display !== "none",
        }));
        return { pdf, ...m };
      } finally {
        await ctx.close();
      }
    };
    /** Every page's MediaBox, in points, from the PDF's page objects (one per page); "?" for a page without one of its own */
    const pagesOf = (pdf) => pdf.toString("latin1").split("endobj")
      .filter((o) => /\/Type\s*\/Page(?![s\w])/.test(o))
      .map((o) => {
        const box = o.match(/\/MediaBox\s*\[([^\]]+)\]/)?.[1].trim().split(/\s+/).map(Number) ?? [];
        return box.length === 4 && box.every(Number.isFinite) ? box.map(Math.round).join(" ") : "?";
      });
    // Page 1 in Chromium's PDF viewer at A4 landscape's size at 96 dpi, fitted, without its toolbar. The PDF is served from a
    // routed address (a data URL stops at 2 MiB). The shot is taken once three in a row, 250 ms apart, agree and each is over
    // 20 kB: a viewer still loading changes, and an empty page or a missing viewer gives a small image, so neither passes
    let viewer = null;
    const pageOne = async (pdf) => {
      viewer ??= await chromium.launch({ channel: "chromium" });
      const p = await viewer.newPage({ viewport: { width: 1123, height: 794 } });
      try {
        const html = `<html><body style="margin:0"><embed type="application/pdf" style="display:block;width:100vw;height:100vh"
          src="/page.pdf#toolbar=0&navpanes=0&view=Fit"></body></html>`;
        await p.route("http://print.invalid/**", (route) => route.fulfill(route.request().url().endsWith("/page.pdf")
          ? { status: 200, contentType: "application/pdf", body: pdf }
          : { status: 200, contentType: "text/html", body: html }));
        await p.goto("http://print.invalid/");
        let shot = null;
        let steady = 0;
        for (let i = 0; i < 80 && steady < 2; i++) {
          await p.waitForTimeout(250);
          const next = await p.screenshot();
          steady = shot && next.equals(shot) && next.length > 20000 ? steady + 1 : 0;
          shot = next;
        }
        return steady >= 2 ? shot : null;
      } finally {
        await p.close();
      }
    };
    /** Two PNGs compared in a canvas: the share of pixels that differ by more than 32 in a channel, and each one's white share */
    const compare = async (one, two) => {
      const p = await b.newPage();
      try {
        return await p.evaluate(async ([one, two]) => {
          const load = (src) => new Promise((ok, no) => { const i = new Image(); i.onload = () => ok(i); i.onerror = no; i.src = src; });
          const pixels = (img) => {
            const c = document.createElement("canvas");
            Object.assign(c, { width: img.width, height: img.height });
            const g = c.getContext("2d");
            g.drawImage(img, 0, 0);
            return g.getImageData(0, 0, c.width, c.height).data;
          };
          const [i1, i2] = await Promise.all([load(one), load(two)]);
          if (i1.width !== i2.width || i1.height !== i2.height) return { same: false };
          const [d1, d2] = [pixels(i1), pixels(i2)];
          const isWhite = (d, k) => d[k] >= 245 && d[k + 1] >= 245 && d[k + 2] >= 245;
          let differ = 0;
          let white1 = 0;
          let white2 = 0;
          for (let k = 0; k < d1.length; k += 4) {
            if (Math.max(Math.abs(d1[k] - d2[k]), Math.abs(d1[k + 1] - d2[k + 1]), Math.abs(d1[k + 2] - d2[k + 2])) > 32) differ++;
            if (isWhite(d1, k)) white1++;
            if (isWhite(d2, k)) white2++;
          }
          const n = d1.length / 4;
          return { same: true, differ: differ / n, white: Math.min(white1, white2) / n };
        }, [one, two].map((png) => `data:image/png;base64,${png.toString("base64")}`));
      } finally {
        await p.close();
      }
    };
    const pair = async () => {
      const a = await pdfOf(DESIGN_WIDTH_PX);
      const z = await pdfOf(FIT_MID);
      const pages = { a: pagesOf(a.pdf), z: pagesOf(z.pdf) };
      const shots = { a: null, z: null };
      let error = null;
      try {
        shots.a = await pageOne(a.pdf);
        shots.z = await pageOne(z.pdf);
      } catch (e) {
        error = e;
      }
      const diff = shots.a && shots.z ? await compare(shots.a, shots.z) : null;
      const same = !error && JSON.stringify(pages.a) === JSON.stringify(pages.z) && !!diff?.same && diff.differ <= 0.001;
      return { a, z, pages, shots, diff, error, same };
    };
    let r = await pair();
    if (!r.same) r = await pair();
    await viewer?.close();
    const { a, z, pages, shots, diff, error } = r;
    if (Math.abs(z.zoom - 1) > 0.005) problems.push(`print from ${tag}: the zoom on paper is ${z.zoom}, expected 1`);
    if (!z.sheet || z.gate) problems.push(`print from ${tag}: ${z.gate ? "the gate shows" : "the roster's sheet is missing"} on paper`);
    if (pages.a.length === 0 || pages.a.includes("?") || JSON.stringify(pages.a) !== JSON.stringify(pages.z)) {
      problems.push(`print from ${tag}: ${pages.z.length} pages of ${JSON.stringify(pages.z)} pt, at ${DESIGN_WIDTH_PX} ${pages.a.length} of ${JSON.stringify(pages.a)}`);
    }
    if (error) problems.push(`print from ${tag}: page 1 could not be rendered (${error.message.split("\n")[0]}); it is rendered in Playwright's full chromium: npx playwright install chromium`);
    else if (!shots.a || !shots.z) problems.push(`print from ${tag}: Chromium's PDF viewer showed no settled page 1 (Playwright's full chromium is needed: npx playwright install chromium)`);
    else if (!diff.same) problems.push(`print from ${tag}: page 1 renders at another size than the one printed at ${DESIGN_WIDTH_PX}`);
    else if (diff.white < 0.5) problems.push(`print from ${tag}: page 1 rendered with ${(diff.white * 100).toFixed(1)} % white, so the viewer's backdrop shows, not a sheet filling it`);
    else if (diff.differ > 0.001) problems.push(`print from ${tag}: page 1 differs from the one printed at ${DESIGN_WIDTH_PX} in ${(diff.differ * 100).toFixed(2)} % of its pixels, more than 0.1 %`);
    const contents = [a.pdf, z.pdf, shots.a, shots.z];
    files.forEach((f, i) => {
      if (problems.length > before && contents[i]) writeFileSync(`${outDir}/${f}`, contents[i]);
      else rmSync(`${outDir}/${f}`, { force: true });
    });
    console.log(`${problems.length === before ? "PASS" : "FAIL"}  fit at ${tag}: print at A4 as from ${DESIGN_WIDTH_PX} (pages, size, page 1 to the eye), zoom 1 on paper`);
  }
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
    await settle(p);
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
    await settle(p);
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
    await settle(p);
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
    await settle(p);
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
    await settle(p);
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
      await settle(p);
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
    await settle(p);
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
    await settle(p);
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
    await settle(p);
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
    await settle(p);
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
    await settle(p);
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
    ["manager", "/reports/inbound?range=month", ["Welcome", "Reports", "Inbound"], ["/", "/reports/flash", null]],
    ["reader", "/reports/inbound?range=month", ["Welcome", "Reports", "Inbound"], ["/", "/reports/flash", null]],
    ["admin", "/configuration/sources/00000000-0000-7000-8000-00000000c001", ["Welcome", "Configuration", "Sources", null], ["/", "/configuration/teams", "/configuration/sources", null]],
    ["agent-one", "/account", ["Welcome", "My account"], ["/", null]],
    ["supervisor", "/messages/send", ["Welcome", "Messages", "Send a message"], ["/", "/messages", null]],
    // Follow-up and Waiting for you (addition 0008o): a report in its group (Sales since 0008zv, which links to Speed to
    // lead, its first page); the person's own page, no rail item
    ["manager", "/reports/follow-up", ["Welcome", "Sales", "Follow-up"], ["/", "/reports/speed-to-lead", null]],
    ["agent-one", "/me/follow-up", ["Welcome", "Waiting for you"], ["/", null]],
    // Attempts per deal and Attempts per agent (addition 0008y): reports in their group (Sales since 0008zv)
    ["manager", "/reports/attempts?range=month", ["Welcome", "Sales", "Attempts per deal"], ["/", "/reports/speed-to-lead", null]],
    ["reader", "/reports/attempts?range=month", ["Welcome", "Sales", "Attempts per deal"], ["/", "/reports/speed-to-lead", null]],
    ["supervisor", "/reports/attempts-per-agent?range=month", ["Welcome", "Sales", "Attempts per agent"], ["/", "/reports/speed-to-lead", null]],
    // A contact center's Live board (addition 0008zv): Live › the organisation's name; Reviews in Customers
    ["supervisor", "/live/newco", ["Welcome", "Live", "Newco"], ["/", "/live/newco", null]],
    ["manager", "/reports/reviews", ["Welcome", "Customers", "Reviews"], ["/", "/reports/cancellations", null]],
    // Assets (addition 0008zw): Installed base and Maintenance, the group linking to Installed base, its first page
    ["manager", "/reports/installed-base", ["Welcome", "Assets", "Installed base"], ["/", "/reports/installed-base", null]],
    ["reader", "/reports/maintenance", ["Welcome", "Assets", "Maintenance"], ["/", "/reports/installed-base", null]],
  ]) {
    const ctx = await withCookies(subject, {});
    const p = await ctx.newPage();
    await p.goto(BASE + path);
    await settle(p);
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
    await settle(p);
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
    await settle(p);
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
  // Maintenance; since 0008zm Lead cohorts; since 0008zn Flash, first in Reports, so the Reports crumb links to it; since
  // 0008zw Installed base (Assets); since 0009a Courtesy (Customers)
  for (const [subject, pages] of [["manager", 34], ["agent-one", 5]]) {
    const ctx = await withCookies(subject, { "cma-preview-role": "agent" });
    const p = await ctx.newPage();
    await p.goto(BASE + "/");
    await settle(p);
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
// closed group holding the current page keeps its white pill and the digit keys work with every group closed; a bare rail
// page (Welcome, Messages, the top bar's inbox, a crumb to Welcome or Messages) closes the open group (addition 0008zv). Time has no letter, so the letter is Configuration's C, for the admin. --provoke expects the per-group behaviour of
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
    await settle(p);
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
    // the manager's fourth page is My day, in the closed Time group (since 0008zw Time comes before Team: Welcome,
    // Messages, Newco's Live board, My day; the sixth before)
    await p.keyboard.press("4");
    await p.waitForURL("**/day").catch(() => undefined);
    await settle(p);
    if (new URL(p.url()).pathname !== "/day") problems.push(`accordion: key 4 opened ${new URL(p.url()).pathname} with every group closed, expected /day`);
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
    await settle(p);
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

  // 2b. A bare rail page closes the open group (addition 0008zv, Martin, 5 November 2026): with Time open on My day, a click
  // on Welcome, the key 2 (Messages), a click on the top bar's inbox and a click on the Welcome crumb each close it, and so
  // does the Messages crumb on Send a message; the cookie is then empty and a reload opens none. --provoke expects Time
  // still open
  {
    const ctx = await contextOf("manager", {});
    const p = await ctx.newPage();
    const crumb = (href) => p.locator(`[data-testid="breadcrumbs"] a[href="${href}"]`).click();
    for (const [how, act, path, from] of [
      ["a click on Welcome", () => p.locator('nav[data-rail-nav] a[href="/"]').click(), "/", "/day"],
      ["the key 2", async () => { await p.locator("main h1").click(); await p.keyboard.press("2"); }, "/messages", "/day"],
      ["a click on the inbox", () => p.locator('[data-testid="inbox-link"]').click(), "/messages", "/day"],
      ["a click on the Welcome crumb", () => crumb("/"), "/", "/day"],
      ["a click on the Messages crumb", () => crumb("/messages"), "/messages", "/messages/send"],
    ]) {
      await p.goto(BASE + from);
      await settle(p);
      await p.waitForLoadState("networkidle");
      if (!openOf(await groupsOf(p)).includes("time")) await click(p, "time");
      expectOpen(`on ${from} before ${how}`, await groupsOf(p), ["time"]);
      await act();
      await p.waitForURL((u) => new URL(u).pathname === path).catch(() => undefined);
      await settle(p);
      await p.waitForLoadState("networkidle");
      if (new URL(p.url()).pathname !== path) problems.push(`accordion: ${how} opened ${new URL(p.url()).pathname}, expected ${path}`);
      expectOpen(`after ${how}`, await groupsOf(p), provoke ? ["time"] : []);
      const jar = await jarOf(ctx);
      if (jar["cma-nav-open"] !== "") problems.push(`accordion: after ${how} the cookie is ${JSON.stringify(jar["cma-nav-open"])}, expected empty`);
      await p.reload();
      await p.waitForLoadState("networkidle");
      expectOpen(`after ${how} and a reload`, await groupsOf(p), []);
    }
    await ctx.close();
  }

  // 3. The folded rail: a click on Reports unfolds it with only Reports open (Time was open before the fold)
  {
    const ctx = await contextOf("manager", { "cma-rail": "collapsed", "cma-nav-open": "time" });
    const p = await ctx.newPage();
    await p.goto(BASE + "/");
    await settle(p);
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
    await settle(p);
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
    await settle(p);
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
    await settle(p);
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
      await settle(p);
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
// or performance.team, Funnel directly before Attempts per deal since 0008zv (the agent gets the no-permission card); deals per person on Funnel for
// performance.team while reports.per_person holds deals (not for the reader, not for the invest tenant without the
// switch); the page never scrolls sideways, by week and by day; the keycaps K, P, S, G and X on Funnel, K, G and X on
// Cancellations, next to the period bar's; ten tiles and four; the tables end inside their cards. --provoke lets the
// lost deals per period spill out of their card
// Assets -> Installed base as the "now" view (addition 0009f; by model since 0008zy), as the manager: no As of; the tiles,
// the model donut with its legend (a table: every figure in text), In the field per market stacked per model; the Model
// select with D and "All models" first, the Operational status select with S; no records, breakdown or list until a
// panel is opened (address state: panel=); choosing a model puts f_model in the address, the In the field tile becomes
// that model's legend count and the donut keeps one slice; opening Records streams the list in its card, 50 rows at
// most, without the file-only columns; the serial search (F) finds a device by its serial
async function expectInstalledBaseModels() {
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 }, extraHTTPHeaders: { "x-cma-mock-subject": "manager" } });
  const p = await ctx.newPage();
  await p.goto(BASE + "/reports/installed-base");
  await settle(p);
  await p.waitForLoadState("networkidle");
  const before = await p.evaluate(() => ({
    asOf: !!document.querySelector('[data-testid="flash-as-of"]'),
    split: document.querySelector('[data-testid="flash-split-installed_base"]')?.textContent?.trim() ?? null,
    inField: document.querySelector('[data-testid="flash-total-in_field"] p.tabular')?.textContent?.trim() ?? null,
    legend: [...document.querySelectorAll('[data-testid="ib-donut-legend"] tbody tr[data-testid^="ib-slice-"]')]
      .map((tr) => [tr.getAttribute("data-testid").slice("ib-slice-".length), tr.children[0].textContent.trim(), tr.children[1].textContent.trim()]),
    donutPaths: document.querySelectorAll('[data-testid="ib-donut"] svg path').length,
    stacks: document.querySelectorAll('[data-testid="ib-market-stacks"] > li').length,
    options: [...document.querySelectorAll('[data-testid="flash-model"] option')].map((o) => [o.value, o.textContent?.trim()]),
    key: document.querySelector('[data-testid="flash-model"]')?.getAttribute("data-shortcut") ?? null,
    statusKey: document.querySelector('[data-testid="ib-status"]')?.getAttribute("data-shortcut") ?? null,
    searchKey: document.querySelector('#ib-serial')?.getAttribute("data-shortcut") ?? null,
    panels: document.querySelectorAll('[data-testid="ib-panels"] a').length,
    rows: !!document.querySelector('[data-testid="flash-rows"]'),
    breakdown: !!document.querySelector('[data-testid^="flash-breakdown-"]'),
    links: document.querySelectorAll("main a").length,
  }));
  if (before.asOf) problems.push("installed base: an As of control on the now view");
  if (before.split !== null) problems.push("installed base: the split line still under In the field (the donut replaces it)");
  if (before.legend.length < 2 || before.donutPaths < 2) problems.push(`installed base: the model donut has ${before.donutPaths} slices and ${before.legend.length} legend rows, expected two or more`);
  if (before.stacks < 2) problems.push(`installed base: ${before.stacks} market stacks, expected two or more`);
  if (before.key !== (provoke ? "x" : "d")) problems.push(`installed base: the Model select answers to ${before.key}, expected D`);
  if (before.statusKey !== "s") problems.push(`installed base: the Operational status select answers to ${before.statusKey}, expected S`);
  if (before.searchKey !== "f") problems.push(`installed base: the serial field answers to ${before.searchKey}, expected F`);
  if (before.options[0]?.[0] !== "" || before.options.length < 2) problems.push(`installed base: the Model select's choices ${JSON.stringify(before.options)}, expected All models first`);
  if (before.panels !== 5) problems.push(`installed base: ${before.panels} panel links, expected 5`);
  if (before.rows || before.breakdown) problems.push("installed base: records or a breakdown rendered before a panel was opened");
  if (before.links > 60) problems.push(`installed base: ${before.links} links in the default view, expected a light page (no breakdown filter links)`);
  const [value, name] = before.options[1] ?? ["", ""];
  const part = before.legend.find((r) => r[0] === value)?.[2] ?? null;
  await p.locator('[data-testid="flash-model"]').selectOption(value);
  await p.waitForURL(new RegExp(`f_model=${value}`)).catch(() => undefined);
  await settle(p);
  await p.waitForLoadState("networkidle");
  const after = await p.evaluate(() => ({
    url: location.search,
    inField: document.querySelector('[data-testid="flash-total-in_field"] p.tabular')?.textContent?.trim() ?? null,
    chosen: document.querySelector('[data-testid="flash-model"]')?.value ?? null,
    slices: document.querySelectorAll('[data-testid="ib-donut-legend"] tbody tr[data-testid^="ib-slice-"]').length,
  }));
  if (!after.url.includes(`f_model=${value}`) || after.chosen !== value) problems.push(`installed base: choosing ${value} gave ${after.url} with ${after.chosen} chosen`);
  if (after.inField !== (provoke ? before.inField : part)) problems.push(`installed base: In the field with ${name} is ${after.inField}, the legend's count ${part}`);
  if (after.slices !== 1) problems.push(`installed base: ${after.slices} slices with a Model filter, expected the one model`);
  // the Records panel: the list streams into its card, the Model filter kept, 50 rows at most, the file-only columns left out
  await p.locator('[data-testid="ib-panel-records"]').click();
  await p.waitForURL(/panel=records/).catch(() => undefined);
  await settle(p);
  await p.waitForLoadState("networkidle");
  await p.locator('[data-testid="flash-rows"], [data-testid="flash-rows-empty"]').first().waitFor({ timeout: 15000 }).catch(() => undefined);
  const panel = await p.evaluate(() => ({
    url: location.search,
    rows: document.querySelectorAll('[data-testid="flash-rows"] tbody tr').length,
    headers: [...document.querySelectorAll('[data-testid="flash-rows"] thead th')].map((th) => th.textContent?.trim()),
    open: document.querySelector('[data-testid="ib-panel-records"]')?.getAttribute("aria-current") ?? null,
  }));
  if (!panel.url.includes("panel=records") || !panel.url.includes(`f_model=${value}`)) problems.push(`installed base: opening Records gave ${panel.url}`);
  if (panel.rows < 1 || panel.rows > 50) problems.push(`installed base: ${panel.rows} record rows, expected 1 to 50`);
  if (panel.headers.some((h) => /^(References|Missing references|Subscription link)$/.test(h ?? ""))) problems.push(`installed base: a file-only column on screen (${panel.headers.join(", ")})`);
  if (panel.open !== "page") problems.push("installed base: the open panel is not marked");
  await p.screenshot({ path: `${outDir}/manager-installed-base-model.png` });
  // the serial search: the first record's serial, typed with spaces and in lower case, found
  const serial = await p.evaluate(() => document.querySelector('[data-testid="flash-rows"] tbody tr td')?.textContent?.trim() ?? "");
  await p.fill("#ib-serial", ` ${serial.toLowerCase()} `);
  await p.press("#ib-serial", "Enter");
  await p.waitForURL(/serial=/).catch(() => undefined);
  await settle(p);
  await p.waitForLoadState("networkidle");
  await p.locator('[data-testid="flash-rows"], [data-testid="ib-search-none"]').first().waitFor({ timeout: 15000 }).catch(() => undefined);
  const search = await p.evaluate(() => ({
    rows: document.querySelectorAll('[data-testid="flash-rows"] tbody tr').length,
    first: document.querySelector('[data-testid="flash-rows"] tbody tr td')?.textContent?.trim() ?? null,
    none: !!document.querySelector('[data-testid="ib-search-none"]'),
  }));
  if (search.rows !== 1 || search.first !== serial || search.none) problems.push(`installed base: the serial search for ${serial} gave ${search.rows} row(s), first ${search.first}`);
  await p.screenshot({ path: `${outDir}/manager-installed-base-search.png` });
  await ctx.close();
}

// As of applies on Enter or blur only, when complete and in range (addition 0008zz, Martin, 6 November 2026): typing a
// date digit by digit (its year passes 0002, 0020 and 0202) never navigates; Enter, or leaving the field, loads it once.
// The date is the field's last one less two days (the mock holds snapshots from 21 days back to yesterday, all but the
// sixth day back), typed day, month, year; then Now and the same date again, which loads it again
async function expectAsOfTyping() {
  // a browser of its own whose date fields read day, month, year (en-GB): the order the brief types the date in
  const gb = await chromium.launch({ env: { ...process.env, LANG: "en_GB.UTF-8", LANGUAGE: "en_GB:en" } });
  const ctx = await gb.newContext({ viewport: { width: 1440, height: 900 }, locale: "en-GB", extraHTTPHeaders: { "x-cma-mock-subject": "manager" } });
  // every client navigation (the router pushes the address), counted in the page
  await ctx.addInitScript(() => {
    const push = history.pushState.bind(history);
    window.__cmaPushes = [];
    history.pushState = (state, unused, url) => { window.__cmaPushes.push(String(url)); return push(state, unused, url); };
  });
  const p = await ctx.newPage();
  const errors = [];
  p.on("pageerror", (e) => errors.push(e.message));
  // Enter on one overview; leaving the field (its blur) on another. Both on Reports → Flash: Assets → Installed base has no
  // As of since addition 0009f (the now view)
  for (const [path, key] of [["/reports/flash?o=installed_base", "Enter"], ["/reports/flash?o=customers", "blur"]]) {
    await p.goto(BASE + path);
    await settle(p);
    await p.waitForLoadState("networkidle");
    await p.evaluate(() => { window.__cmaPushes = []; });
    const max = await p.locator('[data-testid="flash-as-of"]').getAttribute("max");
    const day = new Date(Date.parse(`${max}T00:00:00Z`) - 2 * 86_400_000).toISOString().slice(0, 10);
    const typed = `${day.slice(8, 10)}${day.slice(5, 7)}${day.slice(0, 4)}`;
    await p.locator('[data-testid="flash-as-of"]').focus();
    await p.keyboard.type(typed, { delay: 40 });
    await p.waitForTimeout(400);
    const typing = await p.evaluate(() => window.__cmaPushes.slice());
    if (key === "Enter") await p.keyboard.press("Enter");
    else await p.locator('[data-testid="flash-as-of"]').blur();
    await p.waitForURL(new RegExp(`asOf=${day}`), { timeout: 15_000 }).catch(() => undefined);
    await settle(p);
    await p.waitForLoadState("networkidle");
    await p.waitForTimeout(400);
    const after = await p.evaluate(() => ({ pushes: window.__cmaPushes.slice(), search: location.search,
      error: !!document.querySelector('[data-testid="error-page"]'), value: document.querySelector('[data-testid="flash-as-of"]')?.value ?? null }));
    if (typing.length !== (provoke ? -1 : 0)) problems.push(`${path}: typing ${typed} in As of navigated ${typing.length} time(s) before ${key} (${typing.join(", ")})`);
    if (after.pushes.length !== 1 || !after.pushes[0].includes(`asOf=${day}`)) problems.push(`${path}: ${key} after typing As of navigated ${after.pushes.length} time(s): ${after.pushes.join(", ")}`);
    if (!after.search.includes(`asOf=${day}`) || after.value !== day) problems.push(`${path}: As of shows ${after.value} at ${after.search}, expected ${day}`);
    if (after.error) problems.push(`${path}: the error page after typing As of`);
    await p.screenshot({ path: `${outDir}/manager-as-of-typed-${key.toLowerCase()}.png` });
    // Now, then the same date again: it loads again (a date asked once is not refused the next time)
    await p.locator('[data-testid="flash-now"]').click();
    await p.waitForURL((u) => !u.search.includes("asOf="), { timeout: 15_000 }).catch(() => undefined);
    await settle(p);
    await p.waitForLoadState("networkidle");
    await p.evaluate(() => { window.__cmaPushes = []; });
    await p.locator('[data-testid="flash-as-of"]').focus();
    await p.keyboard.type(typed, { delay: 40 });
    if (key === "Enter") await p.keyboard.press("Enter");
    else await p.locator('[data-testid="flash-as-of"]').blur();
    await p.waitForURL(new RegExp(`asOf=${day}`), { timeout: 15_000 }).catch(() => undefined);
    await settle(p);
    await p.waitForLoadState("networkidle");
    const again = await p.evaluate(() => ({ pushes: window.__cmaPushes.slice(), search: location.search }));
    if (again.pushes.length !== (provoke ? -1 : 1) || !again.search.includes(`asOf=${day}`)) {
      problems.push(`${path}: after Now, the same date by ${key} navigated ${again.pushes.length} time(s) to ${again.search}`);
    }
  }
  if (errors.length > 0) problems.push(`As of typing: page errors: ${errors.join("; ")}`);
  await ctx.close();
  await gb.close();
}

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
    await settle(p);
    await p.waitForLoadState("networkidle");
    const rail = await p.evaluate(() => [...(document.querySelector("nav")?.querySelectorAll("a") ?? [])].map((a) => a.getAttribute("href")));
    for (const href of ["/reports/funnel", "/reports/cancellations"]) {
      if (rail.includes(href) !== may) problems.push(`${subject}: ${href} ${may ? "missing from" : "shown in"} the rail`);
    }
    // Since addition 0008zv (Martin, 5 November 2026) Funnel comes directly before Attempts per deal, in Sales
    if (may && rail.indexOf("/reports/funnel") + 1 !== rail.indexOf("/reports/attempts")) {
      problems.push(`${subject}: Funnel does not come directly before Attempts per deal in the rail`);
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
      await settle(p);
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
    await settle(p);
    await p.waitForLoadState("networkidle");
    const first = new URL(p.url()).pathname;
    if (first !== "/") problems.push(`${subject}: a fresh sign-in opening ${deep} landed on ${first}, expected Welcome at /`);
    const jar = Object.fromEntries((await ctx.cookies()).map((c) => [c.name, c]));
    if (!provoke && (!jar["cma-session"] || jar["cma-session"].expires !== -1 || !jar["cma-session"].httpOnly)) problems.push(`${subject}: the browser session is not an HttpOnly session cookie`);
    await p.goto(BASE + deep);
    await settle(p);
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
await expectInstalledBaseModels();
await expectAsOfTyping();
await expectWelcomeOnOpen();
await expectCampaigns();
await expectCallbacks();
await expectIntakeConfiguration();
await expectInvitations();
await expectIrreversibleConfirmations();
await expectFit();
// --provoke also demands the app below the floor
if (provoke) await expectShell(FIT_FLOOR_PX - 1, 800);
await expectGate(FIT_FLOOR_PX - 1, 800);
await b.close();

for (const x of problems) console.log("  " + x);
console.log(problems.length === 0 ? `layout: PASS (1280, 1920, the fit at ${FIT_WIDTHS.join(", ")} on Welcome and ${FIT_PAGES.manager.length + FIT_PAGES.admin.length} pages (zoom, the ${DESIGN_WIDTH_PX} px layout, no sideways scroll, the grids as at ${DESIGN_WIDTH_PX}, the Follow-up link column, the week bar, the Invite dialog, the frame fixed, a hint next to its mark, without JavaScript, a resize, print at A4), the gate at ${FIT_FLOOR_PX - 1} with its words, Welcome, the shift line, navigation, the Configuration group and My account for 6 identities, the three intake reports, Inbound and the Intake row with a header hint open, Intake and Inbound inside their cards, no text on Light Blue or Soft Rose, the Live board for 6 identities, Calls and Calls per agent for 7 identities (the per-agent page for performance.team only, the opened rows and the tag table inside their cards, Enter and Down, the deltas like for like and none before the telephony history), Forms for 7 identities (the keycaps, the four tiles, the forms table and the answers inside their cards, the deltas like for like and none before the forms history), Email and Email per agent for 7 identities (the per-person page for performance.team with the tenant's switch, not found without it, the keycaps, the tables inside their cards, Enter and Down, No email connected), First orders and Orders per person for 7 identities (the per-person page for performance.team with the tenant's switch, not found without it, the keycaps, the four tiles, the level bars, History from in Muted, every grouping and the tables inside their cards, No orders connected), Attempts per deal and Attempts per agent for 7 identities (the per-agent page for performance.team with the tenant's switch, not found without it, the keycaps K, P, A, O, the six tiles, every grouping and the tables inside their cards, the right-most hint inside the viewport, a deal's row opened by Enter and closed by Esc), Funnel and Cancellations for 7 identities (after Attempts in the rail, deals per person for performance.team with the tenant's switch, the keycaps K, P, S, G and X, ten and four tiles, by week and by day, the tables inside their cards), Welcome on open for 2 identities (a fresh sign-in on a deep link lands on /, a deep link while signed in opens), the Live board's last section, Callbacks kept on Follow-up and the Dashboard for 5 identities (the weeks for reports.view or performance.team, per person for performance.team, inside their cards, No callback type set), Campaign monitoring for 7 identities (the journeys' cards inside the main area, the archived one absent, a journey's Muted banner, seven dashed placeholders with the drill-down locked, the prerequisites unticked, no figure, the breadcrumbs, archived and unknown not found, no journeys in words), Sources with its form categories (every table inside its card), Markets and Alert rules, People with Invitations and the Invite dialog for the admin and the manager, /invite open, another account, expired, invalid and another business line, the irreversible confirmations on Lines (with the stored-calls count, loading and failed), Teams and the planner and End workday opening on its confirm button, the rail folded by cookie and by W, the rail as an accordion (one group open, the cookie on the server, a click closing it, the letter, the folded rail, the retired cookies expired, the digit keys and the pill with every group closed), no info mark wrapped apart on Follow-up and Attempts at 1440, the hints hidden by cookie and shown by ?, aria-keyshortcuts, the frame fixed to the viewport (the Live board, Speed to lead and Follow-up at 1280 and 1920 scroll in main only, the rail at 1280x600 on its own), breadcrumbs on 11 pages, preview as role for the admin and ignored for 2 others, the roster's week bar; screenshots in ${outDir})` : `layout: FAIL (${problems.length} problems)`);
process.exit(problems.length === 0 ? 0 : 1);
