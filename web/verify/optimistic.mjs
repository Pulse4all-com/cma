/**
 * verify/optimistic.mjs: a write shows its result at once (night N07, decision D3), measured in a browser.
 *
 * On My day as a mock agent, each status button is clicked in turn; the time from the click (a capture listener in the
 * page, performance.now()) to the frame in which the clicked button is pressed (aria-pressed="true", watched by a
 * MutationObserver) is the time to the result. The target: within 50 ms of the click, every change. Then the navigation
 * part of the persistent frame (D2): after a click from My day to Messages and back, the top bar and the rail are the
 * same DOM nodes (the frame never re-mounted) and the inbox badge never went blank.
 *
 *   BASE=http://localhost:8081 node verify/optimistic.mjs             expect PASS
 *   BASE=http://localhost:8081 node verify/optimistic.mjs --provoke   the budget is 0 ms and the frame must re-mount: expect FAIL
 *
 * Needs the app in mock mode (CMA_AUTH_MODE=mock CMA_DATA_MODE=mock), a production build (next start or the standalone
 * server) and Playwright's preinstalled chromium. Local measurements: the container's milliseconds; the ratio carries.
 */
import { chromium } from "playwright";

const BASE = process.env.BASE ?? "http://localhost:8081";
const SUBJECT = process.env.SUBJECT ?? "agent-two";
const provoke = process.argv.includes("--provoke");
const BUDGET_MS = provoke ? 0 : 50;
const problems = [];
const lines = [];

// The urgent pop-up would cover the page: the subject's urgent messages are acknowledged first (as verify/layout.mjs does)
const inbox = await fetch(`${BASE}/api/v1/me/messages`, { headers: { "x-cma-mock-subject": SUBJECT } }).then((r) => r.json()).catch(() => null);
for (const m of inbox?.data?.messages ?? []) {
  if (m.urgency === "urgent" && !m.acknowledgedAt) {
    await fetch(`${BASE}/api/v1/me/messages/${m.id}/ack`, { method: "POST", headers: { "x-cma-mock-subject": SUBJECT, "x-cma-request": "1" } });
  }
}

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": SUBJECT } });
const page = await ctx.newPage();
await page.goto(`${BASE}/day`, { waitUntil: "networkidle" });
if (await page.locator('[data-testid="clock-in"]').count()) {
  await page.locator('[data-testid="clock-in"]').first().click();
  await page.waitForSelector("[data-status-key]", { timeout: 15000 });
}
await page.waitForSelector("[data-status-key]", { timeout: 15000 });

// The watcher: a capture listener notes the click's instant; a MutationObserver notes the first frame the clicked button
// is pressed in (requestAnimationFrame after the mutation: the frame that paints it)
await page.evaluate(() => {
  const w = window;
  w.__clickAt = null;
  w.__shownAt = null;
  w.__target = null;
  document.addEventListener("click", (e) => {
    const b = e.target instanceof Element ? e.target.closest("[data-status-key]") : null;
    if (!b) return;
    w.__clickAt = performance.now();
    w.__shownAt = null;
    w.__target = b.getAttribute("data-status-key");
  }, true);
  new MutationObserver(() => {
    if (w.__clickAt === null || w.__shownAt !== null) return;
    const b = document.querySelector(`[data-status-key="${w.__target}"]`);
    if (b?.getAttribute("aria-pressed") === "true") requestAnimationFrame(() => { if (w.__shownAt === null) w.__shownAt = performance.now(); });
  }).observe(document.body, { subtree: true, attributes: true, attributeFilter: ["aria-pressed"], childList: true });
});

const keys = await page.locator("[data-status-key]").evaluateAll((bs) => bs.map((b) => b.getAttribute("data-status-key")));
const times = [];
for (const key of [...keys.slice(1), keys[0], ...keys.slice(1, 3)].filter(Boolean).slice(0, 6)) {
  const button = page.locator(`[data-status-key="${key}"]`);
  if ((await button.getAttribute("aria-pressed")) === "true") continue;
  await button.click();
  await page.waitForFunction(() => window.__shownAt !== null, null, { timeout: 10000 }).catch(() => undefined);
  const ms = await page.evaluate(() => (window.__shownAt === null ? null : window.__shownAt - window.__clickAt));
  times.push(ms);
  lines.push(`status ${key}: ${ms === null ? "never shown" : `${ms.toFixed(1)} ms`} from the click to the pressed button`);
  // the change lands and the page is read again before the next click
  await page.waitForLoadState("networkidle");
  await page.waitForTimeout(300);
}
if (times.length === 0) problems.push("no status change could be measured");
for (const ms of times) if (ms === null || ms > BUDGET_MS) problems.push(`a status change shown after ${ms === null ? "never" : `${ms.toFixed(1)} ms`} (budget ${BUDGET_MS} ms)`);

// D2: the frame survives a navigation, the badge never blanks
const marks = await page.evaluate(() => {
  const header = document.querySelector("header");
  const nav = document.querySelector("nav[data-rail-nav]");
  if (header) header.dataset.n07Mark = "kept";
  if (nav) nav.dataset.n07Mark = "kept";
  window.__badgeBlank = 0;
  new MutationObserver(() => {
    if (!document.querySelector('[data-testid="inbox-link"]')) window.__badgeBlank += 1;
  }).observe(document.body, { subtree: true, childList: true });
  return Boolean(header && nav);
});
if (!marks) problems.push("no top bar or rail on My day");
let messagesRequests = 0;
page.on("request", (r) => { if (new URL(r.url()).pathname === "/api/v1/me/messages") messagesRequests += 1; });
await page.locator('nav[data-rail-nav] a[href="/messages"]').first().click();
await page.waitForURL("**/messages");
await page.waitForSelector('[data-testid="inbox-list"], [data-testid="inbox-unread-line"]', { timeout: 15000 });
// back (Messages, a bare rail page, closed the Time group): the client router cache answers it (D4)
await page.goBack();
await page.waitForURL("**/day");
await page.waitForSelector("[data-status-key]", { timeout: 15000 });
const after = await page.evaluate(() => ({
  header: document.querySelector("header")?.dataset.n07Mark ?? null,
  nav: document.querySelector("nav[data-rail-nav]")?.dataset.n07Mark ?? null,
  blank: window.__badgeBlank,
}));
const keptWanted = provoke ? null : "kept";
if (after.header !== keptWanted || after.nav !== keptWanted) problems.push(`the frame was mounted again on a navigation (top bar ${after.header}, rail ${after.nav})`);
if (!provoke && after.blank > 0) problems.push(`the inbox link left the page ${after.blank} times during two navigations`);
lines.push(`two navigations: top bar ${after.header ?? "new"}, rail ${after.nav ?? "new"}, inbox link gone ${after.blank} times, ${messagesRequests} inbox polls`);
await browser.close();

for (const l of lines) console.log(l);
const sorted = times.filter((x) => x !== null).sort((a, b) => a - b);
if (sorted.length) console.log(`status change to the screen: p50 ${sorted[Math.floor(sorted.length / 2)].toFixed(1)} ms, max ${sorted.at(-1).toFixed(1)} ms over ${sorted.length} changes`);
if (problems.length) {
  for (const p of problems) console.log(`FAIL  ${p}`);
  console.log(`\noptimistic: FAIL (${problems.length} problem${problems.length === 1 ? "" : "s"})${provoke ? " (provoked, as it must)" : ""}`);
  process.exit(1);
}
console.log("\noptimistic: PASS");
