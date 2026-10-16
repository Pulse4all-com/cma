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
 * a line's box stays ticked until the switch-off is confirmed; End workday, an ordinary confirmation, opens
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
 *       agent rail for the previewing admin and one page fewer for the ignored cookies, expect FAIL, exit 1
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
    // Since 0008o (16 October 2026) Follow-up follows Speed to lead (reports.view, performance.team or monitoring.live)
    ["analyst", ["/", "/messages", "/live/board", "/reports/dashboard", "/reports/speed-to-lead", "/reports/follow-up", "/reports/intake", "/reports/inbound", "/reports/calls",
      "/reports/calls-per-agent", "/reports/data-quality"], false],
    // A reports reader (reports.view alone, 0008j): Calls without Calls per agent, no Dashboard
    ["reader", ["/", "/messages", "/reports/speed-to-lead", "/reports/follow-up", "/reports/intake", "/reports/inbound", "/reports/calls", "/reports/data-quality"], false],
    // Since 0005 My schedule (roster.view) follows My hours in the Time group
    ["agent-one", ["/", "/messages", "/day", "/hours", "/schedule"], true],
    ["supervisor", ["/", "/messages", "/live/board", "/day", "/hours", "/schedule", "/team/hours", "/reports/dashboard", "/reports/speed-to-lead", "/reports/follow-up", "/reports/intake",
      "/reports/inbound", "/reports/calls", "/reports/calls-per-agent"], true],
    // Since 0004 the Team group sits between Live and Time for people who manage others (manager, admin);
    // the supervisor and the agent see no Team group, so their keys do not move. The planner (0005) joins it.
    ["manager", ["/", "/messages", "/live/board", "/team/people", "/roster/planner", "/day", "/hours", "/schedule", "/team/hours", "/reports/dashboard", "/reports/speed-to-lead", "/reports/follow-up",
      "/reports/intake", "/reports/inbound", "/reports/calls", "/reports/calls-per-agent", "/reports/data-quality"], true],
    ["admin", ["/", "/messages", "/live/board", "/team/people", "/roster/planner", "/day", "/hours", "/schedule", "/team/hours", "/reports/dashboard", "/reports/speed-to-lead", "/reports/follow-up",
      "/reports/intake", "/reports/inbound", "/reports/calls", "/reports/calls-per-agent", "/reports/data-quality"], true],
  ];
  for (const [subject, hrefs, clock] of cases) {
    const ctx = await b.newContext({ viewport: { width: 1440, height: 900 }, extraHTTPHeaders: { "x-cma-mock-subject": subject } });
    const p = await ctx.newPage();
    await p.goto(BASE + "/");
    await p.waitForLoadState("networkidle");
    const path = new URL(p.url()).pathname;
    const links = await p.evaluate(() =>
      // The rail is the first nav; the period bar on a page is another
      [...(document.querySelector("nav")?.querySelectorAll("a[data-shortcut]") ?? [])].map((a) => [a.getAttribute("data-shortcut"), a.getAttribute("href")]));
    const want = hrefs.map((h, i) => [String(i + 1), h]);
    const hasClockIn = await p.locator('[data-testid="clock-in"]').count() > 0;
    // The shift sentence (0005): only for a person with a roster (roster.view), from the published fixture
    const hasShiftLine = await p.locator('[data-testid="shift-line"]').count() > 0;
    if (hasShiftLine !== clock) problems.push(`${subject}: shift line ${hasShiftLine ? "shown" : "missing"} on Welcome, expected ${clock ? "shown" : "missing"}`);
    if (path !== "/") problems.push(`${subject}: landed on ${path}, expected Welcome at /`);
    if (JSON.stringify(links) !== JSON.stringify(want)) problems.push(`${subject}: navigation ${JSON.stringify(links)}, expected ${JSON.stringify(want)}`);
    // The Configuration group (0005a): unnumbered pages for tenant.configure only (the admin); nobody else sees the group
    const configLinks = await p.evaluate(() => [...(document.querySelector("nav")?.querySelectorAll('a[href^="/configuration/"]') ?? [])].map((a) => [a.getAttribute("data-shortcut"), a.getAttribute("href")]));
    const wantConfig = subject === "admin"
      ? [["/configuration/statuses"], ["/configuration/teams"], ["/configuration/absences"], ["/configuration/exports"], ["/configuration/app-links"],
         ["/configuration/sources"], ["/configuration/markets"], ["/configuration/alert-rules"]].map(([h]) => [null, h])
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
    ["manager", "/reports/speed-to-lead?range=month", ["G", "T", "W", "M", "C"], '[data-testid="speed-summary"]', '[data-testid="speed-summary"] th:nth-child(6) button[data-header-hint]'],
    ["manager", "/reports/intake?range=month", ["F", "T", "W", "M", "C"], '[data-testid="intake-table"]', lastIntakeHeader],
    ["manager", "/reports/data-quality", [], '[data-testid="data-quality"]', '[data-testid="data-quality"] th:nth-child(2) button[data-header-hint]'],
    ["manager", "/reports/dashboard?range=month", ["P", "T"], '[data-testid="intake-row"]', '[data-testid="intake-speed"] button[data-header-hint]'],
    ["invest-analyst", "/reports/intake?range=month", ["F"], '[data-testid="not-connected"]', lastIntakeHeader],
    ["invest-analyst", "/reports/dashboard?range=month", [], '[data-testid="not-connected"]', '[data-testid="intake-calls"] button[data-header-hint]'],
    // Inbound (addition 0008i): the right-most reason column's hint stays inside the viewport; a tenant
    // without telephony says so in words and has no header to open
    ["manager", "/reports/inbound?range=month", ["G", "T", "W", "M", "C"], '[data-testid="inbound-table"]', '[data-testid="inbound-table"] thead th:last-child button[data-header-hint]'],
    ["invest-analyst", "/reports/inbound?range=month", ["G"], '[data-testid="inbound-not-connected"]', null],
    // Follow-up (addition 0008o): the three filters' keycaps, the tickets table's right-most header hint stays
    // inside the viewport; the reader (reports.view alone) gets the lists without the per-person table
    ["manager", "/reports/follow-up", ["K", "O", "S"], '[data-testid="follow-up-by-owner"]', '[data-testid="follow-up-tickets"] thead th:last-child button[data-header-hint]'],
    ["reader", "/reports/follow-up?state=attention", ["K", "O", "S"], '[data-testid="follow-up-leads"]', '[data-testid="follow-up-tasks"] thead th:last-child button[data-header-hint]'],
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
  for (const path of ["/reports/speed-to-lead", "/reports/follow-up", "/reports/intake", "/reports/inbound", "/reports/calls", "/reports/calls-per-agent", "/reports/data-quality"]) {
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
    const m = await p.evaluate(() => {
      const main = document.querySelector("main");
      return {
        scrollX: document.documentElement.scrollWidth > window.innerWidth,
        mainX: main ? main.scrollWidth - main.clientWidth : -1,
        tiles: document.querySelectorAll('[data-testid="inbound-tiles"] [data-tile]').length,
        missed: !!document.querySelector('[data-testid="missed-callbacks"]'),
        notConnected: !!document.querySelector('[data-testid="inbound-live"] [data-testid="inbound-not-connected"]'),
      };
    });
    if (m.scrollX) problems.push(`${subject} /live/board: page scrolls horizontally at 1280`);
    if (m.mainX > 0) problems.push(`${subject} /live/board: the main area scrolls sideways by ${m.mainX}px at 1280`);
    if (telephony && (m.tiles !== 7 || !m.missed)) problems.push(`${subject} /live/board: ${m.tiles} inbound tiles and ${m.missed ? "a" : "no"} missed-calls table, expected 7 and a table`);
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
    ["/configuration/sources", [], '[data-testid="sources"]'],
    ["/configuration/sources/00000000-0000-7000-8000-00000000c001", ["B", "N", "S", "F", "O"], '[data-testid="source-forms"]'],
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
    if (await p.locator(selector).count() === 0) problems.push(`admin ${path}: ${selector} missing`);
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
    if (open.width !== 256 || open.expanded !== "true" || jar["cma-rail"] !== "expanded" || jar["cma-nav-reports"] !== "open") {
      problems.push(`rail: a group's click gave ${JSON.stringify({ ...open, rail: jar["cma-rail"], group: jar["cma-nav-reports"] })}, expected the rail unfolded and the group open, both cookies written`);
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
    if (c.column <= 0 || c.column > 1152) problems.push(`rail: folded, the content column is ${c.column}px (max-w-6xl is 1152)`);
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
      const vis = (el) => el.getClientRects().length > 0;
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
    ["admin", "/configuration/sources/00000000-0000-7000-8000-00000000c001", ["Welcome", "Configuration", "Sources", null], ["/", "/configuration/statuses", "/configuration/sources", null]],
    ["agent-one", "/account", ["Welcome", "My account"], ["/", null]],
    ["supervisor", "/messages/send", ["Welcome", "Messages", "Send a message"], ["/", "/messages", null]],
    // Follow-up and Waiting for you (addition 0008o): a report in its group; the person's own page, no rail item
    ["manager", "/reports/follow-up", ["Welcome", "Reports", "Follow-up"], ["/", "/reports/dashboard", null]],
    ["agent-one", "/me/follow-up", ["Welcome", "Waiting for you"], ["/", null]],
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
      rail: [...document.querySelectorAll("nav[data-rail-nav] a[data-shortcut]")].map((a) => a.getAttribute("href")),
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
  // the manager's rail holds 17 pages since Follow-up joined the Reports group (0008o)
  for (const [subject, pages] of [["manager", 17], ["agent-one", 5]]) {
    const ctx = await withCookies(subject, { "cma-preview-role": "agent" });
    const p = await ctx.newPage();
    await p.goto(BASE + "/");
    await p.waitForLoadState("networkidle");
    const m = await p.evaluate(() => ({
      banner: !!document.querySelector('[data-testid="preview-banner"]'),
      select: !!document.querySelector('[data-testid="preview-select"]'),
      rail: document.querySelectorAll("nav[data-rail-nav] a[data-shortcut]").length,
    }));
    if (m.banner || m.select || m.rail !== (provoke ? pages - 1 : pages)) problems.push(`preview: ${subject} with a preview cookie gets ${JSON.stringify(m)}, expected no control, no banner and ${pages} pages`);
    await ctx.close();
  }
}

await expectShell(1280, 800);
await expectShell(1920, 1080);
await expectNavigation();
await expectFrame();
await expectReports();
await expectLiveBoard();
await expectCalls();
await expectIntakeConfiguration();
await expectInvitations();
await expectIrreversibleConfirmations();
if (provoke) await expectShell(1279, 800);
else await expectGate(1279, 800);
await b.close();

for (const x of problems) console.log("  " + x);
console.log(problems.length === 0 ? `layout: PASS (1280, 1920, gate at 1279, Welcome, the shift line, navigation, the Configuration group and My account for 6 identities, the three intake reports, Inbound and the Intake row with a header hint open, Intake and Inbound inside their cards, no text on Light Blue or Soft Rose, the Live board for 6 identities, Calls and Calls per agent for 7 identities (the per-agent page for performance.team only, the opened rows and the tag table inside their cards, Enter and Down, the deltas like for like and none before the telephony history), Sources (every table inside its card), Markets and Alert rules, People with Invitations and the Invite dialog for the admin and the manager, /invite open, another account, expired, invalid and another business line, the irreversible confirmations on Lines, Teams and the planner and End workday opening on its confirm button, the rail folded by cookie and by W, the hints hidden by cookie and shown by ?, aria-keyshortcuts, breadcrumbs on 6 pages, preview as role for the admin and ignored for 2 others, the roster's week bar; screenshots in ${outDir})` : `layout: FAIL (${problems.length} problems)`);
process.exit(problems.length === 0 ? 0 : 1);
