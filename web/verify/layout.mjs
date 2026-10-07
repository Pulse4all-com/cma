/**
 * Verifier: layout at 1280 and 1920 px, the 1280 px gate below that, no
 * horizontal scrolling, the shell dimensions from the tokens, and the keycaps
 * that make the keyboard shortcuts discoverable. Also the navigation per
 * permission: everyone lands on Welcome (increment e), which pages each test
 * identity sees, numbered 1, 2, 3 without gaps, that someone without a clock
 * is sent from My day to Welcome, and that the Clock in button is shown only to
 * a person whose time is kept. Saves screenshots under records/ for the release note.
 *
 *   BASE=http://localhost:8080 node verify/layout.mjs             expect PASS
 *   BASE=http://localhost:8080 node verify/layout.mjs --provoke   renders at
 *       1279 px and demands the app shell, expect FAIL, exit 1
 */
import { mkdirSync } from "node:fs";
import { chromium } from "playwright";

const BASE = process.env.BASE ?? "http://localhost:8080";
const provoke = process.argv.includes("--provoke");
const outDir = process.env.OUT_DIR ?? new URL("../../records/layout", import.meta.url).pathname;
mkdirSync(outDir, { recursive: true });

const problems = [];
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
  if (Math.round(m.rail) !== 216) problems.push(`${tag}: rail is ${m.rail}px, token says 216`);
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
    ["analyst", ["/", "/live/board", "/reports/dashboard"], false],
    ["agent-one", ["/", "/day", "/hours"], true],
    ["supervisor", ["/", "/live/board", "/day", "/hours", "/team/hours", "/reports/dashboard"], true],
    // Since 0004 the Team group sits between Live and Time for people who manage others (manager, admin);
    // the supervisor and the agent see no Team group, so their keys do not move
    ["manager", ["/", "/live/board", "/team/people", "/day", "/hours", "/team/hours", "/reports/dashboard"], true],
    ["admin", ["/", "/live/board", "/team/people", "/day", "/hours", "/team/hours", "/reports/dashboard"], true],
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
    if (path !== "/") problems.push(`${subject}: landed on ${path}, expected Welcome at /`);
    if (JSON.stringify(links) !== JSON.stringify(want)) problems.push(`${subject}: navigation ${JSON.stringify(links)}, expected ${JSON.stringify(want)}`);
    if (hasClockIn !== clock) problems.push(`${subject}: Clock in ${hasClockIn ? "shown" : "missing"} on Welcome, expected ${clock ? "shown" : "missing"}`);
    await p.screenshot({ path: `${outDir}/${subject}-welcome.png` });
    if (!clock) {
      await p.goto(BASE + "/day");
      await p.waitForLoadState("networkidle");
      const dayPath = new URL(p.url()).pathname;
      if (dayPath !== "/") problems.push(`${subject}: My day answered ${dayPath}, expected to be sent to Welcome`);
    }
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

await expectShell(1280, 800);
await expectShell(1920, 1080);
await expectNavigation();
if (provoke) await expectShell(1279, 800);
else await expectGate(1279, 800);
await b.close();

for (const x of problems) console.log("  " + x);
console.log(problems.length === 0 ? `layout: PASS (1280, 1920, gate at 1279, Welcome and navigation for 5 identities; screenshots in ${outDir})` : `layout: FAIL (${problems.length} problems)`);
process.exit(problems.length === 0 ? 0 : 1);
