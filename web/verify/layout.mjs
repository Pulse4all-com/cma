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
 * main area never scrolls sideways at 1280 px (12 October 2026). Saves screenshots under records/
 * for the release note.
 *
 *   BASE=http://localhost:8080 node verify/layout.mjs             expect PASS
 *   BASE=http://localhost:8080 node verify/layout.mjs --provoke   renders at
 *       1279 px and demands the app shell, moves one hint panel over its header and lets the
 *       Intake table spill out of its card, expect FAIL, exit 1
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
for (const subject of ["manager", "supervisor", "admin", "analyst", "invest-analyst"]) await acknowledgeUrgent(subject);
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
    ["analyst", ["/", "/messages", "/live/board", "/reports/dashboard", "/reports/speed-to-lead", "/reports/intake", "/reports/data-quality"], false],
    // Since 0005 My schedule (roster.view) follows My hours in the Time group
    ["agent-one", ["/", "/messages", "/day", "/hours", "/schedule"], true],
    ["supervisor", ["/", "/messages", "/live/board", "/day", "/hours", "/schedule", "/team/hours", "/reports/dashboard", "/reports/speed-to-lead", "/reports/intake"], true],
    // Since 0004 the Team group sits between Live and Time for people who manage others (manager, admin);
    // the supervisor and the agent see no Team group, so their keys do not move. The planner (0005) joins it.
    ["manager", ["/", "/messages", "/live/board", "/team/people", "/roster/planner", "/day", "/hours", "/schedule", "/team/hours", "/reports/dashboard", "/reports/speed-to-lead", "/reports/intake", "/reports/data-quality"], true],
    ["admin", ["/", "/messages", "/live/board", "/team/people", "/roster/planner", "/day", "/hours", "/schedule", "/team/hours", "/reports/dashboard", "/reports/speed-to-lead", "/reports/intake", "/reports/data-quality"], true],
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
    if (path.startsWith("/reports/intake")) {
      const w = await p.evaluate((spill) => {
        const box = document.querySelector('[data-testid="intake-scroll"]');
        if (!box) return null;
        if (spill) box.style.overflowX = "visible";
        const main = document.querySelector("main");
        return { main: main.scrollWidth - main.clientWidth };
      }, provoke && subject === "manager");
      if (!w) problems.push(`${subject} ${path}: the Intake table has no scroll container`);
      else if (w.main > 0) problems.push(`${subject} ${path}: the main area scrolls sideways by ${w.main}px at 1280`);
    }
    if (Math.round(m.rail) !== 256) problems.push(`${subject} ${path}: rail is ${m.rail}px`);
    for (const k of keys) if (!m.keycaps.includes(k)) problems.push(`${subject} ${path}: keycap ${k} missing`);
    if (await p.locator(selector).count() === 0) problems.push(`${subject} ${path}: ${selector} missing`);
    await p.screenshot({ path: `${outDir}/${subject}-${path.split("?")[0].split("/").pop()}.png`, fullPage: true });
    // One header hint, opened by keyboard focus
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
  for (const path of ["/reports/speed-to-lead", "/reports/intake", "/reports/data-quality"]) {
    await p.goto(BASE + path);
    await p.waitForLoadState("networkidle");
    if (await p.locator("main table").count() > 0) problems.push(`agent-one ${path}: a report table is shown to an agent`);
  }
  await ctx.close();
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
// scrolling, the main area never sideways, the page's own keycaps, and its tables there
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
    const name = path.split("/").slice(2).join("-").replace(/00000000-0000-7000-8000-00000000/, "");
    await p.screenshot({ path: `${outDir}/admin-${name}.png`, fullPage: true });
    await ctx.close();
  }
}

await expectShell(1280, 800);
await expectShell(1920, 1080);
await expectNavigation();
await expectReports();
await expectIntakeConfiguration();
if (provoke) await expectShell(1279, 800);
else await expectGate(1279, 800);
await b.close();

for (const x of problems) console.log("  " + x);
console.log(problems.length === 0 ? `layout: PASS (1280, 1920, gate at 1279, Welcome, the shift line, navigation, the Configuration group and My account for 5 identities, the three intake reports and the Intake row with a header hint open, Intake inside its card, Sources, Markets and Alert rules; screenshots in ${outDir})` : `layout: FAIL (${problems.length} problems)`);
process.exit(problems.length === 0 ? 0 : 1);
