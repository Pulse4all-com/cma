/**
 * Verifier: the signed-out page outside IAP and the Log out flag (README, Authentication; Decision log,
 * 15 October 2026), without a browser or a server.
 *
 *   node --experimental-strip-types verify/signed-out.mjs             every check must PASS
 *   node --experimental-strip-types verify/signed-out.mjs --provoke   feeds a page and an implementation
 *                                                                      that break every rule: every check must FAIL
 *
 * The page (web/signed-out/index.html): no cookie access, no fetch or XHR, no external script or stylesheet,
 * the CSP with the one inline script's hash, no tenant name before the deploy script writes one in, both
 * languages equal to copy.ts's signedOut keys, the three links. The flag (src/lib/logout.ts and its callers):
 * Log out's Location when CMA_LOGOUT_TARGET is legacy, signed-out or unset, a typo refused, the build passing
 * it; "Use another account" on No access yet only with the flag. The gate: /signed-out has no exception in
 * proxy.ts's matcher and no route or file in the app, so without a valid IAP token it is refused like any page.
 */
import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { logoutLocation, parseLogoutTarget, switchAccountHref } from "../src/lib/logout.ts";

const PROVOKE = process.argv.includes("--provoke");
const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const results = [];
function check(name, problems) {
  const pass = problems.length === 0;
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name}${pass ? "" : `: ${problems.join("; ")}`}`);
}

// ---- inputs (the provoked run swaps in versions that break every rule) ----------------------------
let page = read("../signed-out/index.html");
const copySrc = read("../src/lib/copy.ts");
let proxySrc = read("../src/proxy.ts");
let logoutRoute = read("../src/app/logout/end/route.ts");
let configSrc = read("../src/lib/config.ts");
let noAccessPage = read("../src/app/no-access/page.tsx");
let accessSrc = read("../src/app/access.tsx");
let build = read("../../cloudbuild.yaml");
let impl = { parseLogoutTarget, logoutLocation, switchAccountHref };
const appDir = new URL("../src/app/", import.meta.url);
let routeFiles = readdirSync(appDir, { recursive: true }).map(String);
let publicSignedOut = existsSync(new URL("../public/signed-out", import.meta.url));

if (PROVOKE) {
  page = page
    .replace("default-src 'none';", "default-src *;")
    .replace("var T = {", "fetch('/x'); document.cookie = 'a=1'; var T = {")
    .replace("</head>", '<script src="https://cdn.example.com/x.js"></script><link rel="stylesheet" href="https://fonts.example.com/a.css"></head>')
    .replace('alt="{{DISPLAY_NAME}}"', 'alt="Pulse4all"')
    .replace('subtitle: "Je sessie in de Workspace op deze browser is beëindigd."', 'subtitle: "Je sessie is klaar."')
    .replace('href="https://accounts.google.com/Logout"', 'href="https://accounts.google.com/logout?x=1"');
  proxySrc = proxySrc.replace("_next/image|", "_next/image|signed-out|");
  logoutRoute = logoutRoute.replace("logoutLocation(config.logoutTarget)", '"/logout/done?gcp-iap-mode=CLEAR_LOGIN_COOKIE"');
  configSrc = configSrc.replace("parseLogoutTarget(process.env.CMA_LOGOUT_TARGET)", '"legacy" as const');
  noAccessPage = noAccessPage.replace("switchHref={switchAccountHref(config.logoutTarget)}", 'switchHref="/signed-out?gcp-iap-mode=CLEAR_LOGIN_COOKIE"');
  accessSrc = accessSrc.replace("{switchHref ? (", "{true ? (");
  build = build.replace(",CMA_LOGOUT_TARGET=${_LOGOUT_TARGET}", "").replace("_LOGOUT_TARGET: legacy", "_LOGOUT_TARGET: signed-out");
  impl = {
    parseLogoutTarget: () => "signed-out",
    logoutLocation: () => "https://workspace.example.com/signed-out",
    switchAccountHref: () => "/signed-out",
  };
  routeFiles = [...routeFiles, "signed-out/page.tsx"];
  publicSignedOut = true;
}

// ---- the page ---------------------------------------------------------------------------------------
const scripts = [...page.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)];
const inline = scripts.filter((m) => !/\bsrc\s*=/.test(m[1]));
const code = inline.map((m) => m[2]).join("\n");

check("the page reads and writes no cookie", [
  ...(/document\.cookie|cookieStore|set-cookie/i.test(page) ? ["touches cookies"] : []),
  ...(/localStorage|sessionStorage|indexedDB/.test(page) ? ["uses browser storage"] : []),
]);

check("the page makes no request of its own (no fetch, XHR, beacon, socket, import)", [
  ...(/\bfetch\s*\(|XMLHttpRequest|sendBeacon|WebSocket|EventSource|\bimport\s*\(/.test(code) ? ["requests in the script"] : []),
  ...(/<form\b/i.test(page) ? ["a form"] : []),
]);

const urls = [...page.matchAll(/\b(?:src|href)\s*=\s*"([^"]*)"/g)].map((m) => m[1]);
const cssUrls = [...page.matchAll(/url\(\s*"?([^")]+)"?\s*\)/g)].map((m) => m[1]);
// Google's two web addresses: AddSession (in the markup, and with ?continue= built by the script) and Logout
const GOOGLE = ["https://accounts.google.com/AddSession", "https://accounts.google.com/AddSession?continue=", "https://accounts.google.com/Logout"];
check("no external script, stylesheet or font: only the page's own files and Google's two addresses", [
  ...(scripts.some((m) => /\bsrc\s*=/.test(m[1])) ? ["a script with src"] : []),
  ...(/<link\b/i.test(page) ? ["a link element"] : []),
  ...(/@import/i.test(page) ? ["@import in the style"] : []),
  ...urls.filter((u) => /^(https?:)?\/\//i.test(u) && !GOOGLE.includes(u)).map((u) => `external address ${u}`),
  ...cssUrls.filter((u) => !u.startsWith("/signed-out/")).map((u) => `style address ${u}`),
  ...(/\son[a-z]+\s*=/i.test(page.replace(/<script[\s\S]*?<\/script>/g, "")) ? ["an inline event handler"] : []),
]);

const cspMatch = page.match(/<meta http-equiv="Content-Security-Policy" content="([^"]+)">/);
const hash = createHash("sha256").update(code, "utf8").digest("base64");
const wantCsp = `default-src 'none'; img-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self'; script-src 'sha256-${hash}'; base-uri 'none'; form-action 'none'`;
check("the CSP is present, exact, and allows the one inline script by its hash only", [
  ...(inline.length !== 1 ? [`${inline.length} inline scripts`] : []),
  ...(!cspMatch ? ["no CSP meta tag"] : cspMatch[1] !== wantCsp ? [`CSP is "${cspMatch[1]}"`] : []),
  ...(page.indexOf("Content-Security-Policy") > page.indexOf("<style") ? ["the CSP comes after the style"] : []),
]);

const placeholders = ["{{DISPLAY_NAME}}", "{{LOGO_FILE}}"];
check("no tenant or company name before the deploy: the name and the logo are placeholders", [
  ...(/pulse4all|p4a\b/i.test(page) ? ["a tenant or company name in the markup"] : []),
  ...placeholders.filter((p) => !page.includes(p)).map((p) => `${p} missing`),
  ...(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}/.test(page) ? ["an email address"] : []),
]);

function copyBlock(lang) {
  const m = copySrc.match(new RegExp(`const ${lang}(?::\\s*Copy)? = (\\{[\\s\\S]*?\\n\\})(?: satisfies [^;]+)?;`));
  return Function(`return (${m[1]});`)().signedOut;
}
function pageBlock(lang) {
  const m = code.match(new RegExp(`\\b${lang}: (\\{[\\s\\S]*?\\n    \\})`));
  return m ? Function(`return (${m[1]});`)() : null;
}
const text = (id) => (page.match(new RegExp(`id="${id}"[^>]*>([^<]*)<`)) ?? [])[1];
const en = copyBlock("en");
const nl = copyBlock("nl");
const sharedBefore = en.shared.split("{logOutOfGoogle}")[0];
check("English and Dutch, word for word copy.ts's signedOut, chosen from the browser's language", [
  ...(JSON.stringify(pageBlock("en")) !== JSON.stringify(en) ? ["English differs from copy.ts"] : []),
  ...(JSON.stringify(pageBlock("nl")) !== JSON.stringify(nl) ? ["Dutch differs from copy.ts"] : []),
  ...(text("title") !== en.title || text("subtitle") !== en.subtitle || text("log-in") !== en.logIn || text("use-another") !== en.useAnother
    ? ["the markup's English defaults differ from copy.ts"] : []),
  ...(!page.includes(`${sharedBefore}<a id="google-logout"`) ? ["the shared-computer line differs"] : []),
  ...(!/navigator\.languages/.test(code) || !/=== "nl" \? "nl" : "en"/.test(code) ? ["the language is not taken from the browser, English by default"] : []),
]);

check("the three links: Log in to / (focused), another account through Google's AddSession, Google's Logout", [
  ...(!/<a class="button" id="log-in" href="\/" autofocus>/.test(page) ? ["Log in is not / with autofocus"] : []),
  ...(!/logIn\.focus\(\)/.test(code) ? ["Log in is not focused by the script"] : []),
  ...(!code.includes('another.href = "https://accounts.google.com/AddSession?continue=" + encodeURIComponent("https://" + location.host + "/")')
    ? ["Use another account does not continue to https://<location.host>/"] : []),
  ...(!page.includes('<a id="google-logout" href="https://accounts.google.com/Logout">') ? ["Log out of Google is not Google's Logout"] : []),
  ...(!/Google's own web pages, opened by the browser, not an API/.test(code) ? ["the comment on the two Google addresses is missing"] : []),
]);

// ---- the flag ----------------------------------------------------------------------------------------
const LEGACY = "/logout/done?gcp-iap-mode=CLEAR_LOGIN_COOKIE";
const SIGNED_OUT = "/signed-out?gcp-iap-mode=CLEAR_LOGIN_COOKIE";
let typo = "accepted";
try { impl.parseLogoutTarget("signedout"); } catch { typo = "refused"; }
check("Log out's Location: unset and legacy /logout/done, signed-out the static page, relative; a typo refused", [
  ...(impl.logoutLocation(impl.parseLogoutTarget(undefined)) !== LEGACY ? ["unset is not legacy"] : []),
  ...(impl.logoutLocation(impl.parseLogoutTarget("")) !== LEGACY ? ["empty is not legacy"] : []),
  ...(impl.logoutLocation(impl.parseLogoutTarget("legacy")) !== LEGACY ? ["legacy moved"] : []),
  ...(impl.logoutLocation(impl.parseLogoutTarget("signed-out")) !== SIGNED_OUT ? ["signed-out is not the static page"] : []),
  ...(typo !== "refused" ? ["a typo is accepted"] : []),
]);

check("the route, the config and the build use the flag, legacy by default", [
  ...(!/headers: \{ Location: logoutLocation\(config\.logoutTarget\) \}/.test(logoutRoute) ? ["/logout/end does not answer logoutLocation(config.logoutTarget)"] : []),
  ...(/Location: "/.test(logoutRoute) ? ["/logout/end has a fixed Location"] : []),
  ...(!/logoutTarget: parseLogoutTarget\(process\.env\.CMA_LOGOUT_TARGET\)/.test(configSrc) ? ["config does not read CMA_LOGOUT_TARGET"] : []),
  ...(!build.includes(",CMA_LOGOUT_TARGET=${_LOGOUT_TARGET}") ? ["the build does not pass CMA_LOGOUT_TARGET"] : []),
  ...(!/\n  _LOGOUT_TARGET: legacy\n/.test(build) ? ["the build's default is not legacy"] : []),
  ...(!/legacy\|signed-out\) ;;/.test(build) ? ["check-config does not refuse another value"] : []),
]);

check("No access yet links to another account only with the flag", [
  ...(impl.switchAccountHref("legacy") !== null ? ["a link without the flag"] : []),
  ...(impl.switchAccountHref("signed-out") !== SIGNED_OUT ? ["the link is not the signed-out page"] : []),
  ...(!noAccessPage.includes("switchHref={switchAccountHref(config.logoutTarget)}") ? ["the page does not follow the flag"] : []),
  ...(!accessSrc.includes("{switchHref ? (") ? ["the link is shown without a switch address"] : []),
]);

// ---- the gate ----------------------------------------------------------------------------------------
const matcher = (proxySrc.match(/matcher: \["([^"]+)"\]/) ?? [])[1] ?? "";
const gated = (path) => new RegExp(`^${matcher}$`).test(path);
check("/signed-out reaching cma-web gets the IAP check: in the matcher, no route, no public file", [
  ...(!matcher ? ["no matcher"] : []),
  ...["/signed-out", "/signed-out/logo.png"].filter((p) => !gated(p)).map((p) => `${p} is not gated`),
  ...(!gated("/team/people") ? ["the matcher does not gate an ordinary page"] : []),
  ...routeFiles.filter((f) => /^signed-out(\/|$)/.test(f)).map((f) => `app route src/app/${f}`),
  ...(publicSignedOut ? ["a public file named signed-out"] : []),
  ...(!/if \(!token\) return unauthenticated\("missing"\);/.test(proxySrc) ? ["a missing token is not refused"] : []),
  ...(!/return unauthenticated\("invalid"\);/.test(proxySrc) ? ["an invalid token is not refused"] : []),
]);

const passed = results.filter(Boolean).length;
const n = results.length;
if (PROVOKE) {
  const ok = passed === 0;
  console.log(`\nsigned-out: ${ok ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
  process.exit(ok ? 0 : 1);
} else {
  const ok = passed === n;
  console.log(`\nsigned-out: ${ok ? `PASS (${n} checks)` : `FAIL (${n - passed} of ${n})`}`);
  process.exit(ok ? 0 : 1);
}
