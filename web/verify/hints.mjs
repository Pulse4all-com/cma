/**
 * Verifier: every header and tile of the reports explains itself (HeaderHint, 12 October 2026).
 * Every column header with visible text on Speed to lead (the summary in each of the four groups
 * and the open deals), Intake, Inbound (each of its four groups, addition 0008i) and Data quality,
 * every tile on the Dashboard (the Intake row and the time tiles), the Live board's inbound part
 * (its seven tiles and the missed calls' headers), and since addition 0008j every tile and tag-table header
 * of Calls in each grouping and every header of Calls per agent, and since addition 0008p every tile and header of
 * Forms, since addition 0008t every tile and header of Email and Email per agent, and since addition 0008u every tile, header and
 * level bar of First orders and every header of Orders per person, and since addition 0008w the Callbacks kept tile and the
 * headers of the callbacks kept per week and per person, and since addition 0008y every tile, header and bar card of
 * Attempts per deal and every header of Attempts per agent, carries exactly one info mark: a button with a name, described by a
 * role=tooltip panel with text whose braces were all filled in. Then the behaviour: the panel
 * opens on keyboard focus and on hover, Esc closes it, a tap opens and a second tap closes it on
 * a touch screen, and a Dashboard tile still opens its report while its mark does not. Last, the top bar
 * never moves on the hints toggle (19 October 2026): the logo, the hints toggle, the inbox, the preview
 * select, the signed-in name, Log out and every rail item keep their boxes within 0.5 px, hidden and
 * shown again, toggled and on a fresh load, at 1440 by 900 and 1280 by 800 with the rail open and folded.
 *
 *   BASE=http://localhost:8080 node verify/hints.mjs                    expect PASS
 *   BASE=http://localhost:8080 node verify/hints.mjs --provoke          removes one header's mark and Log out's
 *       width fix, expect FAIL, exit 1
 *   BASE=http://localhost:8080 node verify/hints.mjs --provoke-topbar   removes Log out's width fix only (its
 *       keycap leaves the layout again when the hints hide), expect FAIL on the top bar alone, exit 1
 *
 * Needs the app running in mock mode and Playwright's Chromium installed.
 */
import { chromium } from "playwright";

const BASE = process.env.BASE ?? "http://localhost:8080";
const provoke = process.argv.includes("--provoke");
const provokeTopbar = provoke || process.argv.includes("--provoke-topbar");
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
for (const subject of ["manager", "supervisor", "admin", "analyst", "invest-analyst", "reader", "agent-one"]) await acknowledgeUrgent(subject);
const b = await chromium.launch();

/** Headers and tiles of a page (or of one part of it), and what is wrong with their marks */
async function coverage(p, withHeaders, scope = "main") {
  return p.evaluate(([withHeaders, scope]) => {
    const out = { headers: 0, tiles: 0, problems: [] };
    const text = (el) => {
      const c = el.cloneNode(true);
      c.querySelectorAll(".sr-only, [data-hint-panel], button").forEach((x) => x.remove());
      return c.textContent.trim();
    };
    const checkMark = (where, el) => {
      const marks = el.querySelectorAll("button[data-header-hint]");
      if (marks.length !== 1) return out.problems.push(`${where}: ${marks.length} info marks, expected 1`);
      const m = marks[0];
      if (!m.getAttribute("aria-label")) out.problems.push(`${where}: the mark has no name`);
      const panel = document.getElementById(m.getAttribute("aria-describedby") ?? "");
      if (!panel || panel.getAttribute("role") !== "tooltip") return out.problems.push(`${where}: the mark describes no tooltip`);
      const t = panel.textContent.trim();
      if (!t) out.problems.push(`${where}: the hint is empty`);
      if (/[{}]/.test(t)) out.problems.push(`${where}: the hint has an unfilled value: ${t}`);
    };
    for (const th of withHeaders ? document.querySelectorAll(`${scope} th`) : []) {
      const label = text(th);
      if (!label) continue;
      out.headers++;
      checkMark(`header "${label}"`, th);
    }
    for (const tile of document.querySelectorAll(`${scope} [data-tile]`)) {
      out.tiles++;
      checkMark(`tile "${text(tile.querySelector("p") ?? tile)}"`, tile);
    }
    return out;
  }, [withHeaders, scope]);
}

const cases = [
  // [subject, path, at least this many headers, at least this many tiles]; on the Dashboard the tiles
  // only: the charts' own tables (time per status, per person) are not report headers
  ["manager", "/reports/speed-to-lead?range=month&group=day", 12, 0],
  ["manager", "/reports/speed-to-lead?range=month&group=market", 7, 0],
  ["manager", "/reports/speed-to-lead?range=month&group=agent", 7, 0],
  ["manager", "/reports/speed-to-lead?range=month&group=pipeline", 7, 0],
  ["manager", "/reports/intake?range=month", 18, 0],
  ["invest-analyst", "/reports/intake?range=month", 18, 0],
  ["manager", "/reports/data-quality", 3, 0],
  ["manager", "/reports/dashboard?range=month", 0, 11],
  ["invest-analyst", "/reports/dashboard?range=month", 0, 11],
  // Inbound (addition 0008i): seven headers (the 80th percentile left on 15 October 2026) and one per reason that occurs (the fixture has seven)
  ["manager", "/reports/inbound?range=month&group=day", 13, 0],
  ["manager", "/reports/inbound?range=month&group=market", 13, 0],
  ["manager", "/reports/inbound?range=month&group=line", 13, 0],
  ["manager", "/reports/inbound?range=month&group=hour", 13, 0],
  // The Live board's inbound part only: its seven tiles and the missed calls' six headers
  ["supervisor", "/live/board", 6, 7, '[data-testid="inbound-live"]'],
  // Calls (addition 0008j): eight tiles (four with the change, three outbound, the untagged share) and the tag
  // table's headers: the group, conversations, the top twelve tags, Other and Untagged, in each grouping
  ["manager", "/reports/calls?range=month&group=day", 16, 8],
  ["manager", "/reports/calls?range=month&group=week", 16, 8],
  ["manager", "/reports/calls?range=month&group=market", 16, 8],
  ["manager", "/reports/calls?range=month&group=line", 16, 8],
  // Calls per agent: the person, six figures (no total talk time in or out since 19 October 2026) and the first and last call
  ["manager", "/reports/calls-per-agent?range=month", 8, 0],
  ["supervisor", "/reports/calls-per-agent?range=week", 8, 0],
  // Follow-up (addition 0008o): eight tiles; the leads' nine, the tickets' nine and the tasks' eight named headers
  // (the link column's header is read out only, so it is not counted here), and the per-person table's seven
  // for performance.team (the reader, with reports.view alone, has no per-person table); Waiting for you
  // without the owner columns; the Live board's six follow-up tiles. Since addition 0008w the callbacks kept per week
  // (eight headers, for reports.view or performance.team) and per person (seven, performance.team); the Dashboard's
  // Intake row a seventh tile, Callbacks kept (also "No callback type set" for the invest tenant)
  ["manager", "/reports/follow-up", 48, 8],
  ["reader", "/reports/follow-up", 34, 8],
  ["agent-one", "/me/follow-up", 23, 0],
  ["supervisor", "/live/board", 0, 6, '[data-testid="follow-up-live"]'],
  // Forms (addition 0008p): four tiles; the forms table's five headers, the totals per category and per market
  // (four each) and the answers' four, by day and by week
  ["manager", "/reports/forms?range=month&group=day", 17, 4],
  ["reader", "/reports/forms?range=week&group=week", 17, 4],
  // Email (addition 0008t): five tiles; the tables by inbox (ten headers), mailbox (eight), category and market
  // (six each), waiting now (seven) and not responding (six), by day and by week; Email per agent: the person
  // and five figures
  ["manager", "/reports/email?range=month&group=day", 43, 5],
  ["reader", "/reports/email?range=month&group=week", 43, 5],
  ["manager", "/reports/email-per-agent?range=month", 6, 0],
  ["supervisor", "/reports/email-per-agent?range=week", 6, 0],
  // First orders (addition 0008u): four tiles; the table per market (ten headers), the amounts (five) and the order
  // list (seven named headers; the link column's is read out only), by day and by week; grouped by market the table
  // per group adds ten more, grouped by level five; Orders per person: the person and seven figures. The bars per
  // level carry their marks too, checked below
  ["manager", "/reports/first-orders?range=month&group=day", 22, 4],
  ["manager", "/reports/first-orders?range=month&group=week", 22, 4],
  ["manager", "/reports/first-orders?range=month&group=market", 32, 4],
  ["reader", "/reports/first-orders?range=month&group=level", 27, 4],
  ["manager", "/reports/orders-per-person?range=month", 8, 0],
  ["supervisor", "/reports/orders-per-person?range=week", 8, 0],
  // Attempts per deal (addition 0008y): five tiles; the table per group (the group and nine figures) and the deal list
  // (ten named headers; the link column's is read out only), in each grouping; the four bar cards carry their marks
  // too, checked below. Attempts per agent: the person and six figures
  ["manager", "/reports/attempts?range=month&group=day", 20, 5],
  ["manager", "/reports/attempts?range=month&group=week", 20, 5],
  ["manager", "/reports/attempts?range=month&group=market&scope=counted", 20, 5],
  ["reader", "/reports/attempts?range=month&group=pipeline", 20, 5],
  ["manager", "/reports/attempts-per-agent?range=month", 7, 0],
  ["supervisor", "/reports/attempts-per-agent?range=week", 7, 0],
];
let headers = 0;
let tiles = 0;
for (const [subject, path, minHeaders, minTiles, scope] of cases) {
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 }, extraHTTPHeaders: { "x-cma-mock-subject": subject } });
  const p = await ctx.newPage();
  await p.goto(BASE + path);
  await p.waitForLoadState("networkidle");
  if (provoke && path.startsWith("/reports/data-quality")) {
    await p.evaluate(() => document.querySelector("main th button[data-header-hint]")?.closest("span")?.remove());
  }
  const c = await coverage(p, !path.startsWith("/reports/dashboard"), scope);
  for (const x of c.problems) problems.push(`${subject} ${path}: ${x}`);
  if (c.headers < minHeaders) problems.push(`${subject} ${path}: ${c.headers} headers, expected at least ${minHeaders}`);
  if (c.tiles < minTiles) problems.push(`${subject} ${path}: ${c.tiles} tiles, expected at least ${minTiles}`);
  headers += c.headers;
  tiles += c.tiles;
  await ctx.close();
}

// First orders (addition 0008u): every bar per level names its level with one described mark, one bar per level
// in the tenant's order and the no-evidence bar last
let levelBars = 0;
{
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 }, extraHTTPHeaders: { "x-cma-mock-subject": "manager" } });
  const p = await ctx.newPage();
  await p.goto(BASE + "/reports/first-orders?range=month");
  await p.waitForLoadState("networkidle");
  const bars = await p.evaluate(() => [...document.querySelectorAll('[data-testid="first-order-levels"] > li')].map((li) => {
    const marks = li.querySelectorAll("button[data-header-hint]");
    const panel = marks.length === 1 ? document.getElementById(marks[0].getAttribute("aria-describedby") ?? "") : null;
    return { marks: marks.length, named: marks.length === 1 && !!marks[0].getAttribute("aria-label"), text: panel?.getAttribute("role") === "tooltip" ? panel.textContent.trim() : "" };
  }));
  if (bars.length < 7) problems.push(`first orders: ${bars.length} level bars, expected one per level and the no-evidence bar`);
  bars.forEach((x, i) => {
    if (x.marks !== 1 || !x.named) problems.push(`first orders: level bar ${i + 1} has ${x.marks} info marks or no name`);
    else if (!x.text || /[{}]/.test(x.text)) problems.push(`first orders: level bar ${i + 1}'s hint is empty or unfilled: ${x.text}`);
  });
  levelBars = bars.length;
  await ctx.close();
}

// Attempts per deal (addition 0008y): each of the four bar cards names its figure in one described mark at the end of
// its intro
let barCards = 0;
{
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 }, extraHTTPHeaders: { "x-cma-mock-subject": "manager" } });
  const p = await ctx.newPage();
  await p.goto(BASE + "/reports/attempts?range=month");
  await p.waitForLoadState("networkidle");
  const intros = await p.evaluate(() => [...document.querySelectorAll("main [data-attempt-intro]")].map((el) => {
    const marks = el.querySelectorAll("button[data-header-hint]");
    const panel = marks.length === 1 ? document.getElementById(marks[0].getAttribute("aria-describedby") ?? "") : null;
    return { marks: marks.length, named: marks.length === 1 && !!marks[0].getAttribute("aria-label"), text: panel?.getAttribute("role") === "tooltip" ? panel.textContent.trim() : "" };
  }));
  if (intros.length !== 4) problems.push(`attempts: ${intros.length} bar cards with a mark, expected 4`);
  intros.forEach((x, i) => {
    if (x.marks !== 1 || !x.named) problems.push(`attempts: bar card ${i + 1} has ${x.marks} info marks or no name`);
    else if (!x.text || /[{}]/.test(x.text)) problems.push(`attempts: bar card ${i + 1}'s hint is empty or unfilled: ${x.text}`);
  });
  barCards = intros.length;
  await ctx.close();
}

// Behaviour on Speed to lead: focus opens, Esc closes, hover opens
{
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 }, extraHTTPHeaders: { "x-cma-mock-subject": "manager" } });
  const p = await ctx.newPage();
  await p.goto(BASE + "/reports/speed-to-lead?range=month");
  await p.waitForLoadState("networkidle");
  const mark = p.locator('[data-testid="speed-summary"] th button[data-header-hint]').nth(1);
  const panelOf = async (m) => p.locator(`[id="${await m.getAttribute("aria-describedby")}"]`);
  const panel = await panelOf(mark);
  await mark.focus();
  if (!(await panel.isVisible())) problems.push("speed to lead: the hint does not open on keyboard focus");
  await p.keyboard.press("Escape");
  if (await panel.isVisible()) problems.push("speed to lead: Esc does not close the hint");
  const focused = await p.evaluate(() => document.activeElement?.hasAttribute("data-header-hint"));
  if (!focused) problems.push("speed to lead: Esc moved the focus away from the mark");
  await p.keyboard.press("Tab");
  const next = await p.evaluate(() => document.activeElement?.hasAttribute("data-header-hint"));
  if (!next) problems.push("speed to lead: Tab from one mark does not reach the next header's mark");
  await p.mouse.move(0, 0);
  await p.locator("main h1").click();
  const hovered = p.locator('[data-testid="speed-summary"] th button[data-header-hint]').nth(3);
  await hovered.hover();
  if (!(await (await panelOf(hovered)).isVisible())) problems.push("speed to lead: the hint does not open on hover");
  await p.mouse.move(0, 0);
  await p.waitForTimeout(300);
  if (await (await panelOf(hovered)).isVisible()) problems.push("speed to lead: the hint stays open after the pointer leaves");
  await ctx.close();
}

// Touch: a tap opens, a second tap closes, a tap elsewhere closes
{
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 }, hasTouch: true, extraHTTPHeaders: { "x-cma-mock-subject": "manager" } });
  const p = await ctx.newPage();
  await p.goto(BASE + "/reports/data-quality");
  await p.waitForLoadState("networkidle");
  const mark = p.locator("main th button[data-header-hint]").first();
  const panel = p.locator(`[id="${await mark.getAttribute("aria-describedby")}"]`);
  await mark.tap();
  if (!(await panel.isVisible())) problems.push("data quality: a tap does not open the hint");
  await mark.tap();
  if (await panel.isVisible()) problems.push("data quality: a second tap does not close the hint");
  await mark.tap();
  await p.locator("main h1").tap();
  if (await panel.isVisible()) problems.push("data quality: a tap elsewhere does not close the hint");
  await ctx.close();
}

// Hidden keyboard hints (16 October 2026, backlog CMA-004): with the cookie no keycap is visible, the header
// hints still open on focus, and ? shows the keycaps again. --provoke sets the cookie to shown instead
{
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 }, extraHTTPHeaders: { "x-cma-mock-subject": "manager" } });
  await ctx.addCookies([{ name: "cma-hints", value: provoke ? "shown" : "hidden", domain: new URL(BASE).hostname, path: "/" }]);
  const p = await ctx.newPage();
  await p.goto(BASE + "/reports/speed-to-lead?range=month");
  await p.waitForLoadState("networkidle");
  // Log out's keycap keeps its place in the layout, invisible (19 October 2026), so visible means rendered and not hidden
  const visibleKeycaps = () => p.evaluate(() => [...document.querySelectorAll("kbd")].filter((k) => k.getClientRects().length > 0 && getComputedStyle(k).visibility !== "hidden").length);
  const before = await visibleKeycaps();
  if (before !== 0) problems.push(`hidden hints: ${before} keycaps still visible`);
  const mark = p.locator('[data-testid="speed-summary"] th button[data-header-hint]').first();
  await mark.focus();
  const panel = p.locator(`[id="${await mark.getAttribute("aria-describedby")}"]`);
  if (!(await panel.isVisible())) problems.push("hidden hints: the header hint no longer opens on focus");
  await p.keyboard.press("Escape");
  await p.locator("main h1").click();
  await p.keyboard.press("?");
  await p.waitForTimeout(200);
  if ((await visibleKeycaps()) === 0) problems.push("hidden hints: ? does not show the keycaps again");
  await ctx.close();
}

// The Dashboard: a tile still opens its report, its mark only opens the hint
{
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 }, extraHTTPHeaders: { "x-cma-mock-subject": "manager" } });
  const p = await ctx.newPage();
  await p.goto(BASE + "/reports/dashboard?range=month");
  await p.waitForLoadState("networkidle");
  await p.locator('[data-testid="intake-leads"] button[data-header-hint]').click();
  if (new URL(p.url()).pathname !== "/reports/dashboard") problems.push("dashboard: the Leads tile's mark navigated away");
  // A click on the figure, where the label's link is stretched over the tile
  const box = await p.locator('[data-testid="intake-speed"] .text-title').boundingBox();
  await p.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
  await p.waitForURL("**/reports/speed-to-lead**").catch(() => {});
  if (new URL(p.url()).pathname !== "/reports/speed-to-lead") problems.push("dashboard: the Speed to lead tile no longer opens its report");
  await ctx.close();
}

// The top bar never moves on the hints toggle (19 October 2026): Log out keeps the width it has with its keycap, so
// nothing left of it shifts, and the rail's items stay where they are; only the page's content may narrow or widen.
// For the admin (the preview select shows), at two viewports, with the rail open and folded and the Configuration
// group open (its keycap hides too): shown on a fresh load, hidden by the toggle, hidden on a fresh load, shown by the
// toggle, each against the first. --provoke-topbar takes the keycap out of the layout again, as before the fix
const TOPBAR_SLACK = 0.5;
let topbarRuns = 0;
let topbarBoxes = 0;
for (const [width, height] of [[1440, 900], [1280, 800]]) {
  for (const rail of ["expanded", "collapsed"]) {
    const ctx = await b.newContext({ viewport: { width, height }, extraHTTPHeaders: { "x-cma-mock-subject": "admin" } });
    const host = new URL(BASE).hostname;
    await ctx.addCookies([
      { name: "cma-hints", value: "shown", domain: host, path: "/" },
      { name: "cma-rail", value: rail, domain: host, path: "/" },
      { name: "cma-nav-open", value: "configuration", domain: host, path: "/" },
    ]);
    const p = await ctx.newPage();
    const load = async (how) => {
      if (how === "goto") await p.goto(BASE + "/configuration/statuses");
      else await p.reload();
      await p.waitForLoadState("networkidle");
      if (provokeTopbar) await p.addStyleTag({ content: '[data-hints="hidden"] [data-logout="with-key"] kbd { display: none !important; }' });
    };
    const boxes = () => p.evaluate(() => {
      const out = {};
      const put = (name, el) => {
        if (!el || el.getClientRects().length === 0) return;
        const r = el.getBoundingClientRect();
        out[name] = [r.x, r.y, r.width, r.height];
      };
      put("logo", document.querySelector("header img"));
      put("hints toggle", document.querySelector('[data-testid="hints-toggle"]'));
      put("inbox", document.querySelector('[data-testid="inbox-link"]'));
      put("preview select", document.querySelector('[data-testid="preview-select"]'));
      put("signed-in name", document.querySelector('header a[href="/account"]'));
      put("log out", document.querySelector('[data-testid="logout"]'));
      document.querySelectorAll("nav[data-rail-nav] a, nav[data-rail-nav] button").forEach((el, i) =>
        put(`rail item ${i + 1} (${el.getAttribute("aria-label") ?? el.textContent.trim()})`, el));
      return out;
    });
    const hintsState = () => p.evaluate(() => document.querySelector("[data-hints]")?.getAttribute("data-hints"));
    const where = `${width}x${height}, rail ${rail === "expanded" ? "open" : "folded"}`;
    const toggle = async () => {
      await p.locator('[data-testid="hints-toggle"]').click();
      await p.mouse.move(width / 2, height - 10);
      await p.waitForTimeout(150);
    };
    await load("goto");
    const first = await boxes();
    for (const k of ["logo", "hints toggle", "inbox", "preview select", "signed-in name", "log out"]) {
      if (!first[k]) problems.push(`top bar ${where}: no ${k} to measure`);
    }
    if (!Object.keys(first).some((k) => k.startsWith("rail item"))) problems.push(`top bar ${where}: no rail item to measure`);
    const steps = [];
    await toggle();
    steps.push(["hidden by the toggle", await hintsState(), "hidden", await boxes()]);
    await load("reload");
    steps.push(["hidden on a fresh load", await hintsState(), "hidden", await boxes()]);
    await toggle();
    steps.push(["shown by the toggle", await hintsState(), "shown", await boxes()]);
    for (const [step, state, expected, now] of steps) {
      if (state !== expected) problems.push(`top bar ${where}, ${step}: the hints are ${state}, expected ${expected}`);
      for (const [k, a] of Object.entries(first)) {
        const c = now[k];
        if (!c) { problems.push(`top bar ${where}, ${step}: ${k} is gone`); continue; }
        const off = Math.max(...a.map((v, i) => Math.abs(v - c[i])));
        if (off > TOPBAR_SLACK) problems.push(`top bar ${where}, ${step}: ${k} moved by ${off.toFixed(1)} px (x ${a[0].toFixed(1)} to ${c[0].toFixed(1)}, width ${a[2].toFixed(1)} to ${c[2].toFixed(1)})`);
      }
    }
    topbarRuns++;
    topbarBoxes += Object.keys(first).length;
    await ctx.close();
  }
}

await b.close();
for (const x of problems) console.log("  " + x);
console.log(problems.length === 0
  ? `hints: PASS (${headers} headers and ${tiles} tiles on ${cases.length} pages, ${levelBars} level bars on First orders and ${barCards} bar cards on Attempts per deal, each with one described mark; focus, hover, Esc, Tab, tap and the tile links; the hints with hidden keycaps; the top bar and the rail still within ${TOPBAR_SLACK} px on the toggle, ${topbarBoxes} boxes in ${topbarRuns} runs)`
  : `hints: FAIL (${problems.length} problems)`);
process.exit(problems.length === 0 ? 0 : 1);
