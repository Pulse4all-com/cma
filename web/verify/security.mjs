/**
 * verify/security.mjs: brief N07, WP8 (25 November 2026), the browser's side of a sign-in that ends. Pure checks without
 * a server; with BASE (the app in mock mode) three browser checks as well. The Content-Security-Policy is verify:csp's.
 *
 *   npm run verify:security                              the pure checks
 *   BASE=http://localhost:8082 npm run verify:security   and in Chromium
 *   ... -- --provoke                                     every check runs against a broken copy and must fail
 *
 * Pure: clientFetch (src/lib/client-fetch.ts) sends X-Requested-With on every request, a 401 marks the tab signed out
 * once and from then on no request leaves it; every client component's request goes through clientFetch; Reports →
 * Follow-up's LiveRefresh stops once the sign-in has ended; the notice uses the Button primitive, reloads on a click only,
 * takes no focus and stands clear of the message toasts; its words in en and nl, without the word session (a stretch of
 * a workday, docs/definitions.md). With BASE: a mocked 401 (IAP's own answer) shows the notice without moving the focus,
 * stops the polls and reloads nothing; on Reports → Follow-up the router's refresh stops too; after Log out, Back shows
 * nothing of the person who left (IAP's cookie cleared as IAP does, here the mock's cookies).
 */
import { readFileSync, readdirSync, statSync } from "node:fs";
import * as realFetch from "../src/lib/client-fetch.ts";

const PROVOKE = process.argv.includes("--provoke");
const BASE = process.env.BASE ?? null;
let n = 0, passed = 0;
function check(name, ok, detail = "") {
  n += 1;
  if (ok) passed += 1;
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${ok ? "" : detail ? `  (${detail})` : ""}`);
}
const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const breakSource = (s, ...needles) => (PROVOKE ? needles.reduce((x, k) => x.split(k).join("/*removed*/"), s) : s);

// Under --provoke: a fetch that adds nothing and forgets a 401
const cf = PROVOKE ? { ...realFetch, clientFetch: (input, init = {}) => fetch(input, init) } : realFetch;

// 1. clientFetch with a mocked server: X-Requested-With always, a 401 once, then nothing leaves the tab
const sent = [];
const answers = [200, 401, 200];
const networkFetch = globalThis.fetch;
globalThis.fetch = async (input, init = {}) => {
  sent.push(new Headers(init.headers).get("x-requested-with"));
  return new Response(null, { status: answers[sent.length - 1] ?? 200, headers: { "x-goog-iap-generated-response": "true" } });
};
const events = [];
globalThis.window = new EventTarget();
window.addEventListener(realFetch.SESSION_EXPIRED_EVENT, () => events.push(1));
realFetch.resetSessionForTest();
const a = await cf.clientFetch("/api/v1/me/messages", { headers: { accept: "application/json" } });
const b = await cf.clientFetch("/api/v1/me/messages");
const c = await cf.clientFetch("/api/v1/me/status", { method: "POST", headers: { "x-cma-request": "1" } });
const d = await cf.clientFetch("/api/v1/me/messages");
globalThis.fetch = networkFetch;
delete globalThis.window;
check("every request carries X-Requested-With: XMLHttpRequest, so IAP answers an ended sign-in with 401, not a redirect",
  sent.length >= 2 && sent.every((h) => h === "XMLHttpRequest"), JSON.stringify(sent));
check("the first 401 marks the tab signed out and tells the notice once", a.status === 200 && b.status === 401 && events.length === 1 && realFetch.sessionExpired() === !PROVOKE, `events ${events.length}`);
check("after the 401 no request leaves the tab: the polls and writes stop reaching the Workspace (answered 401 in the tab)",
  sent.length === 2 && c.status === 401 && d.status === 401, `${sent.length} sent`);

// 2. every client request goes through clientFetch; LiveRefresh stops; the notice
function walk(dir) {
  return readdirSync(dir).flatMap((f) => { const p = `${dir}/${f}`; return statSync(p).isDirectory() ? walk(p) : [p]; });
}
const srcDir = new URL("../src", import.meta.url).pathname;
const clientFiles = walk(srcDir).filter((p) => /\.(tsx?|mts)$/.test(p) && !p.includes("/app/api/") && !p.endsWith("/lib/client-fetch.ts"))
  .filter((p) => /^["']use client["']/m.test(readFileSync(p, "utf8")));
const offenders = clientFiles.filter((p) => {
  let s = readFileSync(p, "utf8");
  if (PROVOKE && p.endsWith("/WorkdayPanel.tsx")) s = s.replace("clientFetch(", "fetch(");
  return /(?<![\w.])fetch\(/.test(s) || /sendBeacon/.test(s);
});
check(`every client component's request goes through clientFetch (${clientFiles.length} client modules)`, offenders.length === 0, offenders.join(" "));
const live = breakSource(read("../src/components/LiveRefresh.tsx"), "if (sessionExpired()) return stop();", "window.addEventListener(SESSION_EXPIRED_EVENT, stop)");
check("Reports → Follow-up's LiveRefresh stops once the sign-in has ended (each tick, on return to the tab, on the event)",
  (live.match(/if \(sessionExpired\(\)\) return stop\(\);/g) ?? []).length === 2 && /window\.addEventListener\(SESSION_EXPIRED_EVENT, stop\)/.test(live) &&
  /visibilityState === "visible" && !sessionExpired\(\)\) start\(\)/.test(live));
const notice = breakSource(read("../src/components/SessionExpiredNotice.tsx"), "<Button ", "top-[calc(var(--spacing-topbar)+24px)]");
const toasts = read("../src/components/MessageCenter.tsx");
check("the notice reloads on a click only, with the Button primitive, takes no focus and stands clear of the toasts (top right against bottom right)",
  (notice.match(/reload\(/g) ?? []).length === 1 && /<Button className="mt-4" onClick=\{\(\) => window\.location\.reload\(\)\}>/.test(notice) &&
  !/autoFocus|\.focus\(|setTimeout|setInterval/.test(notice) && /role="alert"/.test(notice) &&
  /top-\[calc\(var\(--spacing-topbar\)\+24px\)\]/.test(notice) && !/\bbottom-/.test(notice) && /fixed bottom-6 right-6/.test(toasts));
const copySrc = breakSource(read("../src/lib/copy.ts"), "Your sign-in to the Workspace has ended");
const blocks = [...copySrc.matchAll(/sessionExpired: \{\s*title: "([^"]+)",\s*body: "([^"]+)",\s*reload: "([^"]+)",/g)];
check("the notice's words exist in en and nl, name the sign-in (never the word session), and the button names the outcome",
  blocks.length === 2 && blocks.every((m) => !/\b(sessie|session|api|token|iap|401|cookie|server|reload|herlaad)\b/i.test(m.slice(1).join(" ")) && !m[1].endsWith(".")) &&
  blocks[0][2].startsWith("Your sign-in to the Workspace has ended.") && blocks[0][3] === "Sign in again" &&
  blocks[1][2].startsWith("Je aanmelding bij de Workspace is verlopen.") && blocks[1][3] === "Opnieuw aanmelden", blocks.map((m) => m[3]).join(" | "));
const layout = read("../src/app/layout.tsx");
check("the root layout mounts the notice once", (breakSource(layout, "<SessionExpiredNotice").match(/<SessionExpiredNotice copy=\{copy\.sessionExpired\} \/>/g) ?? []).length === 1);

// 3. in Chromium
if (BASE) {
  const { chromium } = await import("playwright");
  const browser = await chromium.launch();
  const expire = async (page, status) => {
    let withHeader = null;
    await page.route("**/api/v1/**", async (route) => {
      withHeader = route.request().headers()["x-requested-with"] ?? null;
      if (route.request().url().includes("/telemetry/")) return route.continue();
      await route.fulfill({ status, headers: { "x-goog-iap-generated-response": "true", "content-type": "text/html" }, body: "" });
    });
    return () => withHeader;
  };
  try {
    // a mocked 401 (IAP's own answer): the notice, no focus taken, the polls stopped, no reload
    const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
    const q = await ctx.newPage();
    await q.goto(`${BASE}/?as=agent-two`, { waitUntil: "networkidle" });
    let loads = 0;
    q.on("load", () => { loads += 1; });
    const apiAfter = [];
    let armed = false;
    q.on("request", (r) => { if (armed && new URL(r.url()).pathname.startsWith("/api/v1/") && !r.url().includes("/telemetry/")) apiAfter.push(r.url()); });
    const header = await expire(q, PROVOKE ? 200 : 401);
    const focusedBefore = await q.evaluate(() => document.activeElement?.outerHTML.slice(0, 80) ?? "");
    await q.evaluate(() => window.dispatchEvent(new Event("cma-messages-changed")));
    const shown = await q.getByTestId("session-expired").waitFor({ timeout: 8000 }).then(() => true, () => false);
    const focusedAfter = await q.evaluate(() => document.activeElement?.outerHTML.slice(0, 80) ?? "");
    check("a mocked 401 to a poll shows the notice with its one button, without moving the focus; the request carried X-Requested-With",
      shown && header() === "XMLHttpRequest" && (await q.getByTestId("session-expired").getByRole("button").count()) === 1 && focusedAfter === focusedBefore,
      `focus ${focusedBefore} → ${focusedAfter}`);
    armed = true;
    for (let i = 0; i < 3; i += 1) {
      await q.evaluate(() => window.dispatchEvent(new Event("cma-messages-changed")));
      await q.waitForTimeout(800);
    }
    check("after the 401 the polls send nothing more, and nothing reloads the page by itself", shown && apiAfter.length === 0 && loads === 0,
      `${apiAfter.length} requests, ${loads} loads`);
    await ctx.close();

    // Reports → Follow-up: once the sign-in has ended, LiveRefresh's router refresh stops too
    const ctx2 = await browser.newContext({ viewport: { width: 1440, height: 900 } });
    const f = await ctx2.newPage();
    await f.goto(`${BASE}/reports/follow-up?as=manager`, { waitUntil: "networkidle" });
    await expire(f, PROVOKE ? 200 : 401);
    await f.evaluate(() => window.dispatchEvent(new Event("cma-messages-changed")));
    const shownF = await f.getByTestId("session-expired").waitFor({ timeout: 8000 }).then(() => true, () => false);
    const rsc = [];
    f.on("request", (r) => { if (r.headers()["rsc"] === "1" && !r.headers()["next-router-prefetch"]) rsc.push(r.url()); });
    await f.waitForTimeout(12_500); // more than LiveRefresh's 10 s
    check("Reports → Follow-up: after the 401 the page's refresh sends no request in 12.5 s (LiveRefresh stopped)", shownF && rsc.length === 0, `${rsc.length} refreshes, notice ${shownF}`);
    await ctx2.close();

    // Back after Log out shows nothing of the person who left
    const ctx3 = await browser.newContext({ viewport: { width: 1440, height: 900 } });
    const r = await ctx3.newPage();
    await r.goto(`${BASE}/day?as=agent-two`, { waitUntil: "networkidle" });
    const name = (await r.locator('a[href="/account"]').first().innerText().catch(() => "")).trim();
    // Log out as a person does it: the top bar's link, then the page's confirmation (a form POST to /logout/end)
    await r.getByTestId("logout").first().click();
    await r.waitForURL(/\/logout$/, { timeout: 10_000 }).catch(() => undefined);
    await r.locator('form[action="/logout/end"] button[type="submit"]').click();
    await r.waitForURL(/\/logout\/done|\/signed-out/, { timeout: 10_000 }).catch(() => undefined);
    const leftAt = r.url();
    // IAP clears its own cookie on the way out (gcp-iap-mode=CLEAR_LOGIN_COOKIE); the mock's cookies stand for it here
    if (!PROVOKE) await ctx3.clearCookies();
    let docRequests = 0;
    r.on("request", (x) => { if (x.resourceType() === "document") docRequests += 1; });
    await r.goBack({ waitUntil: "networkidle" }).catch(() => undefined);
    const body = await r.locator("body").innerText().catch(() => "");
    check(`after Log out, Back shows nothing of the person who left (name ${JSON.stringify(name)}, left at ${new URL(leftAt).pathname})`,
      name.length > 0 && /\/logout\/done|\/signed-out/.test(leftAt) && !body.includes(name) && docRequests >= 1,
      `document requests ${docRequests}, name shown ${body.includes(name)}`);
    await ctx3.close();
  } finally {
    await browser.close();
  }
}

if (PROVOKE) {
  console.log(`\n${passed === 0 ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
  process.exit(passed === 0 ? 0 : 1);
}
console.log(`\n${passed === n ? `ALL ${n} PASS` : `${n - passed} of ${n} FAILED`}`);
process.exit(passed === n ? 0 : 1);
