/**
 * Verifier: every header and tile of the reports explains itself (HeaderHint, 12 October 2026).
 * Every column header with visible text on Speed to lead (the summary in each of the four groups
 * and the open deals), Intake, Inbound (each of its four groups, addition 0008i) and Data quality,
 * every tile on the Dashboard (the Intake row and the time tiles), the Live board's inbound part
 * (its seven tiles and the missed calls' headers), and since addition 0008j every tile and tag-table header
 * of Calls in each grouping and every header of Calls per agent, and since addition 0008p every tile and header of
 * Forms, carries exactly one info mark: a button with a name, described by a
 * role=tooltip panel with text whose braces were all filled in. Then the behaviour: the panel
 * opens on keyboard focus and on hover, Esc closes it, a tap opens and a second tap closes it on
 * a touch screen, and a Dashboard tile still opens its report while its mark does not.
 *
 *   BASE=http://localhost:8080 node verify/hints.mjs             expect PASS
 *   BASE=http://localhost:8080 node verify/hints.mjs --provoke   removes one header's mark,
 *       expect FAIL, exit 1
 *
 * Needs the app running in mock mode and Playwright's Chromium installed.
 */
import { chromium } from "playwright";

const BASE = process.env.BASE ?? "http://localhost:8080";
const provoke = process.argv.includes("--provoke");
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
for (const subject of ["manager", "supervisor", "admin", "analyst", "invest-analyst", "reader"]) await acknowledgeUrgent(subject);
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
  ["manager", "/reports/dashboard?range=month", 0, 10],
  ["invest-analyst", "/reports/dashboard?range=month", 0, 6],
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
  // Calls per agent: the person, eight figures and the first and last call
  ["manager", "/reports/calls-per-agent?range=month", 10, 0],
  ["supervisor", "/reports/calls-per-agent?range=week", 10, 0],
  // Forms (addition 0008p): four tiles; the forms table's five headers, the totals per category and per market
  // (four each) and the answers' four, by day and by week
  ["manager", "/reports/forms?range=month&group=day", 17, 4],
  ["reader", "/reports/forms?range=week&group=week", 17, 4],
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
  const visibleKeycaps = () => p.evaluate(() => [...document.querySelectorAll("kbd")].filter((k) => k.getClientRects().length > 0).length);
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

await b.close();
for (const x of problems) console.log("  " + x);
console.log(problems.length === 0
  ? `hints: PASS (${headers} headers and ${tiles} tiles on ${cases.length} pages, each with one described mark; focus, hover, Esc, Tab, tap and the tile links; the hints with hidden keycaps)`
  : `hints: FAIL (${problems.length} problems)`);
process.exit(problems.length === 0 ? 0 : 1);
