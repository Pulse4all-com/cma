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
 * hint inside the viewport, or the not-connected state, and no horizontal scrolling. Saves screenshots under records/ for the release note.
 *
 *   BASE=http://localhost:8080 node verify/layout.mjs             expect PASS
 *   BASE=http://localhost:8080 node verify/layout.mjs --provoke   renders at
 *       1279 px and demands the app shell, moves one hint panel over its header, lets the
 *       Intake and Inbound tables spill out of their cards, writes a count on a Light Blue reason mark,
 *       widens the Live board's inbound tiles past the main area, focuses the confirm button of each
 *       irreversible confirmation (unticking the line's box) and Cancel on End workday, expect FAIL, exit 1
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
for (const subject of ["manager", "supervisor", "admin", "analyst", "invest-analyst", "agent-two"]) await acknowledgeUrgent(subject);
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
    ["analyst", ["/", "/messages", "/live/board", "/reports/dashboard", "/reports/speed-to-lead", "/reports/intake", "/reports/inbound", "/reports/data-quality"], false],
    // Since 0005 My schedule (roster.view) follows My hours in the Time group
    ["agent-one", ["/", "/messages", "/day", "/hours", "/schedule"], true],
    ["supervisor", ["/", "/messages", "/live/board", "/day", "/hours", "/schedule", "/team/hours", "/reports/dashboard", "/reports/speed-to-lead", "/reports/intake", "/reports/inbound"], true],
    // Since 0004 the Team group sits between Live and Time for people who manage others (manager, admin);
    // the supervisor and the agent see no Team group, so their keys do not move. The planner (0005) joins it.
    ["manager", ["/", "/messages", "/live/board", "/team/people", "/roster/planner", "/day", "/hours", "/schedule", "/team/hours", "/reports/dashboard", "/reports/speed-to-lead", "/reports/intake", "/reports/inbound", "/reports/data-quality"], true],
    ["admin", ["/", "/messages", "/live/board", "/team/people", "/roster/planner", "/day", "/hours", "/schedule", "/team/hours", "/reports/dashboard", "/reports/speed-to-lead", "/reports/intake", "/reports/inbound", "/reports/data-quality"], true],
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
  for (const path of ["/reports/speed-to-lead", "/reports/intake", "/reports/inbound", "/reports/data-quality"]) {
    await p.goto(BASE + path);
    await p.waitForLoadState("networkidle");
    if (await p.locator("main table").count() > 0) problems.push(`agent-one ${path}: a report table is shown to an agent`);
  }
  await ctx.close();
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

await expectShell(1280, 800);
await expectShell(1920, 1080);
await expectNavigation();
await expectReports();
await expectLiveBoard();
await expectIntakeConfiguration();
await expectIrreversibleConfirmations();
if (provoke) await expectShell(1279, 800);
else await expectGate(1279, 800);
await b.close();

for (const x of problems) console.log("  " + x);
console.log(problems.length === 0 ? `layout: PASS (1280, 1920, gate at 1279, Welcome, the shift line, navigation, the Configuration group and My account for 5 identities, the three intake reports, Inbound and the Intake row with a header hint open, Intake and Inbound inside their cards, no text on Light Blue or Soft Rose, the Live board for 6 identities, Sources, Markets and Alert rules, the irreversible confirmations on Lines, Teams and the planner and End workday opening on its confirm button; screenshots in ${outDir})` : `layout: FAIL (${problems.length} problems)`);
process.exit(problems.length === 0 ? 0 : 1);
