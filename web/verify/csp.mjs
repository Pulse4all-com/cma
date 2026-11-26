/**
 * verify/csp.mjs: the Content-Security-Policy's step 2 (brief N07, WP8; decision D11, 25 November 2026). Pure checks
 * without a server; with BASE (the app in mock mode) the answers' headers and Chromium as well.
 *
 *   npm run verify:csp                              the pure checks (a build in .next for the prerender check)
 *   BASE=http://localhost:8082 npm run verify:csp   and over HTTP and in Chromium
 *   ... -- --provoke                                every check runs against a broken copy and must fail
 *
 * Pure: src/lib/csp.ts's policy: script-src with this request's nonce, 'strict-dynamic', 'self' and the desktop fit's
 * sha256 (equal to the hash of the text the root layout renders), no 'unsafe-inline', 'unsafe-eval' in development only,
 * no style-src, step 1's four directives as next.config.ts sends them; nonces of 16 random bytes, never repeated;
 * proxy.ts puts one policy on the request and the answer; the build renders every page per request (no page among the
 * prerendered routes). With BASE: every page answer carries the policy with a fresh nonce, every script of the HTML
 * carries that nonce but the fit's, whose text has the policy's hash; in Chromium Welcome, My day, Messages, My hours
 * and an unknown address (the 404 page) raise no CSP violation, and the fit still zooms at 1216 px; and after the load
 * (26 November 2026, after N07b, N07b2 and N07d): Welcome's head start writes its marker, the navigation beacon is
 * answered 204, a rail click and Back stay client navigations (no document load), the Live board and Flash load as the
 * supervisor, without a CSP violation. 8 checks, 14 with BASE.
 */
import { readFileSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
import * as realCsp from "../src/lib/csp.ts";
import { FIT_SCRIPT } from "../src/lib/desktop-fit.ts";

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

// Under --provoke: a policy with 'unsafe-inline', a style-src, a wrong hash and a fixed nonce
const csp = PROVOKE ? {
  ...realCsp,
  FIT_SCRIPT_HASH: "'sha256-AAAA'",
  newNonce: () => "Zml4ZWQ=",
  contentSecurityPolicy: (nonce) => `script-src 'self' 'unsafe-inline' 'unsafe-eval' 'nonce-${nonce}'; style-src 'self'; frame-ancestors 'none'`,
} : realCsp;

// 1. the policy
const nonce = "dGVzdG5vbmNlMTIzNDU2Nw==";
const prod = csp.contentSecurityPolicy(nonce);
const dev = csp.contentSecurityPolicy(nonce, { dev: true });
const directive = (pol, name) => pol.split(";").map((d) => d.trim()).find((d) => d.startsWith(`${name} `)) ?? null;
const ss = directive(prod, "script-src") ?? "";
check("script-src holds this request's nonce, 'strict-dynamic', 'self' and the fit's hash",
  ss.includes(`'nonce-${nonce}'`) && ss.includes("'strict-dynamic'") && ss.split(" ").includes("'self'") && ss.includes(csp.FIT_SCRIPT_HASH), ss);
check("script-src never allows 'unsafe-inline', and 'unsafe-eval' only in development",
  !prod.includes("'unsafe-inline'") && !prod.includes("'unsafe-eval'") && dev.includes("'unsafe-eval'"), prod);
check("no style-src tonight (inline style attributes and the fit's style element stay allowed)", directive(prod, "style-src") === null && directive(prod, "default-src") === null);
const step1 = (read("../next.config.ts").match(/key: "Content-Security-Policy", value: "([^"]+)"/) ?? [])[1];
check("step 1's four directives as next.config.ts sends them, repeated at the end of step 2's one policy",
  step1 === "frame-ancestors 'none'; base-uri 'self'; form-action 'self'; object-src 'none'" && prod.endsWith(`; ${step1}`), `${step1} | ${prod}`);
const hash = `'sha256-${createHash("sha256").update(FIT_SCRIPT, "utf8").digest("base64")}'`;
const layout = read("../src/app/layout.tsx");
check("the fit's hash is the sha256 of the exact text the root layout renders in <head>",
  csp.FIT_SCRIPT_HASH === hash && /<script dangerouslySetInnerHTML=\{\{ __html: FIT_SCRIPT \}\} \/>/.test(layout) && (layout.match(/<script/g) ?? []).length === 1);
const nonces = Array.from({ length: 200 }, () => csp.newNonce());
check("a nonce is 16 random bytes in base64 and never repeats over 200 requests",
  new Set(nonces).size === 200 && nonces.every((x) => Buffer.from(x, "base64").length === 16));
const proxy = breakSource(read("../src/proxy.ts"), 'headers.set("content-security-policy", csp)');
check("proxy.ts puts one policy with a fresh nonce on the request (where Next reads it) and on the answer",
  /const csp = contentSecurityPolicy\(newNonce\(\), \{ dev: process\.env\.NODE_ENV === "development" \}\);\s*headers\.set\("content-security-policy", csp\);\s*const res = NextResponse\.next\(\{ request: \{ headers \} \}\);\s*res\.headers\.set\("Content-Security-Policy", csp\);/.test(proxy));
const manifest = new URL("../.next/prerender-manifest.json", import.meta.url);
if (existsSync(manifest)) {
  const routes = Object.keys(JSON.parse(readFileSync(manifest, "utf8")).routes ?? {});
  const pages = routes.filter((r) => !["/app.webmanifest", "/icon.png", "/_global-error", "/_not-found"].includes(r));
  if (PROVOKE) pages.push("/day");
  check(`the build renders every page per request, so every page gets its nonce (prerendered: ${routes.join(", ")})`, pages.length === 0, pages.join(", "));
} else {
  check("the build renders every page per request (no build in .next: run npm run build first)", false);
}

// 2. over HTTP and in Chromium
if (BASE) {
  const page = async (path) => fetch(`${BASE}${path}`, { headers: { cookie: "cma-session=1; cma-mock-subject=agent-two" }, redirect: "manual" });
  const r1 = await page("/day");
  const r2 = await page("/day");
  const pol = (r) => r.headers.get("content-security-policy") ?? "";
  const nonceOf = (p) => (p.match(/'nonce-([^']+)'/) ?? [])[1] ?? null;
  const n1 = PROVOKE ? "same" : nonceOf(pol(r1)), n2 = PROVOKE ? "same" : nonceOf(pol(r2));
  check("HTTP: a page answer carries one policy with script-src and a nonce, a new one per request", n1 !== null && n2 !== null && n1 !== n2 && pol(r1).endsWith(`; ${step1}`), pol(r1));
  const html = await r1.text();
  const scripts = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)];
  const bad = scripts.filter(([, attrs, body]) => {
    const own = (attrs.match(/nonce="([^"]+)"/) ?? [])[1];
    if (own && own === n1) return false;
    if (!/\bsrc=/.test(attrs) && `'sha256-${createHash("sha256").update(body, "utf8").digest("base64")}'` === realCsp.FIT_SCRIPT_HASH && pol(r1).includes(realCsp.FIT_SCRIPT_HASH)) return false;
    return true;
  });
  check(`HTTP: every script of the page (${scripts.length}) carries the request's nonce, but the fit, which has the policy's hash`, scripts.length > 3 && bad.length === 0, `${bad.length} without: ${bad.slice(0, 2).map((m) => m[1].slice(0, 60)).join(" | ")}`);

  const { chromium } = await import("playwright");
  const browser = await chromium.launch();
  try {
    const ctx = await browser.newContext({ viewport: { width: PROVOKE ? 1440 : 1216, height: 800 } });
    const p = await ctx.newPage();
    const violations = [];
    p.on("console", (m) => { if (/Content Security Policy/i.test(m.text())) violations.push(m.text().slice(0, 120)); });
    await p.addInitScript(() => document.addEventListener("securitypolicyviolation", (e) => console.log(`Content Security Policy violation: ${e.violatedDirective} ${e.blockedURI}`)));
    // the 404 page renders through the same layout and gets its nonce too; a page without one would show here
    const notFound = PROVOKE ? "/day" : `/no-such-page-${Date.now()}`;
    let hydrated404 = false;
    for (const path of ["/?as=agent-two", "/day", "/messages", "/hours", notFound]) {
      const res = await p.goto(`${BASE}${path}`, { waitUntil: "networkidle" });
      if (path === notFound) {
        // React ran on the 404 page: a script refused by the policy would leave it without hydration
        // window.next exists only once Next's client runtime ran; a nonce attribute alone stays on a refused script
        hydrated404 = res?.status() === 404 && (await p.evaluate(() => Boolean(window.next)));
      }
    }
    if (PROVOKE) violations.push("provoked");
    check("Chromium: Welcome, My day, Messages, My hours and an unknown address (the 404 page) run without a CSP violation", violations.length === 0, violations.slice(0, 3).join(" | "));
    check("Chromium: the 404 page answers 404 with its scripts nonced", hydrated404);
    const zoom = await p.evaluate(() => document.getElementById("cma-fit")?.textContent ?? "");
    check("Chromium: the desktop fit's script ran under the policy (its zoom written at 1216 px)", /0\.9\d*/.test(zoom), zoom.slice(0, 80));
    await ctx.close();

    // After the load (26 November 2026, after N07b, N07b2 and N07d): what runs on a page once it is there runs under the
    // policy too. Welcome's head start writes its marker (client code ran: N07b2), the navigation beacon is answered
    // (N07d), a rail click and Back stay client navigations in the persistent shell (no document load: N07b), and the
    // Live board and Flash load as the supervisor; no CSP violation on the way
    // the urgent pop-up would cover the rail: the subjects' urgent messages are acknowledged first (as layout and
    // optimistic do; dev data)
    for (const subject of ["agent-two", "supervisor"]) {
      const inbox = await fetch(`${BASE}/api/v1/me/messages`, { headers: { "x-cma-mock-subject": subject } }).then((r) => r.json()).catch(() => null);
      for (const m of inbox?.data?.messages ?? []) {
        if (m.urgency === "urgent" && !m.acknowledgedAt) {
          await fetch(`${BASE}/api/v1/me/messages/${m.id}/ack`, { method: "POST", headers: { "x-cma-mock-subject": subject, "x-cma-request": "1" } });
        }
      }
    }
    const ctx2 = await browser.newContext({ viewport: { width: 1440, height: 900 } });
    const q = await ctx2.newPage();
    const after = [];
    q.on("console", (m) => { if (/Content Security Policy/i.test(m.text())) after.push(m.text().slice(0, 120)); });
    await q.addInitScript(() => document.addEventListener("securitypolicyviolation", (e) => console.log(`Content Security Policy violation: ${e.violatedDirective} ${e.blockedURI}`)));
    let documents = 0;
    const beacons = [];
    q.on("request", (req) => { if (req.resourceType() === "document") documents += 1; });
    q.on("response", (res) => { if (new URL(res.url()).pathname === "/api/v1/telemetry/navigation") beacons.push(res.status()); });
    await q.goto(`${BASE}/?as=agent-two`, { waitUntil: "networkidle" });
    const marker = await q.waitForFunction(() => document.documentElement.dataset.headStart ?? null, null, { timeout: 15000 })
      .then((h) => h.jsonValue()).catch(() => null);
    const before = documents;
    const rail = await q.locator("nav[data-rail-nav] a[href]").evaluateAll((as) => as.filter((a) => a.offsetParent !== null).map((a) => a.getAttribute("href")));
    const target = rail.find((h) => h !== "/" && !h.startsWith("/reports")) ?? null;
    let clickError = null;
    if (target) {
      // a click that cannot happen (a dialog over the rail) is this check's FAIL with its reason, never a crash
      try {
        await q.locator(`nav[data-rail-nav] a[href="${target}"]`).first().click({ timeout: 10000 });
        await q.waitForURL(`**${target}`, { timeout: 10000 });
        await q.waitForLoadState("networkidle");
        await q.goBack();
        await q.waitForLoadState("networkidle");
      } catch (e) {
        clickError = String(e.message ?? e).split("\n")[0].slice(0, 100);
      }
    }
    const clientNavs = documents - before;
    for (const path of ["/?as=supervisor", "/live/newco", "/reports/flash"]) await q.goto(`${BASE}${path}`, { waitUntil: "networkidle" });
    await q.waitForTimeout(1500);
    if (PROVOKE) after.push("provoked");
    check("Chromium after the load: the head start's marker, the beacon answered, a rail click and Back without a document load, the Live board and Flash, no CSP violation",
      after.length === 0 && marker !== null && beacons.includes(204) && target !== null && clickError === null && clientNavs === 0,
      `violations ${after.slice(0, 2).join(" | ") || 0}; marker ${marker}; beacons ${beacons.join(",") || "none"}; rail click ${target}${clickError ? ` failed: ${clickError}` : ""}; document loads ${clientNavs}`);
    await ctx2.close();
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
