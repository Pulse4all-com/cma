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
 * languages equal to copy.ts's signedOut keys, the three links: Add another account is Google's plain AddSession
 * in a new tab, with no continue address anywhere in the page or its script, because Google answers 400 to a
 * continue outside Google (seen in prod, 15 October 2026). The flag (src/lib/logout.ts and its callers):
 * Log out's Location when CMA_LOGOUT_TARGET is legacy, signed-out or unset, a typo refused, the build passing
 * it; "Use another account" on No access yet only with the flag. The gate: /signed-out has no exception in
 * proxy.ts's matcher and no route or file in the app, so without a valid IAP token it is refused like any page.
 * The bucket and the route (Gemini audit of #128, findings 1.2 and 2.1): docs/signed-out/deploy.sh grants allUsers
 * roles/storage.legacyObjectReader (an object by its name, no listing) and stops on any other role allUsers holds;
 * docs/signed-out/urlmap.py, run with python3 on the fixture verify/signed-out-urlmap.json, plans exactly the three
 * route rules, keeps the default service and the ingest host rule, and writes the three new url-map tests. The
 * bucket's create passes --no-public-access-prevention: gcloud takes --[no-]public-access-prevention (--[no-]pap)
 * as a boolean and refuses a value, as the first --apply in prod found. After the second --apply in prod (15 October
 * 2026), which re-imported an unchanged map: a rerun on the planned map writes no new map, only the map as it is for
 * validate, and deploy.sh then validates and does not import; the new map keeps the fingerprint of the map as read,
 * deploy.sh compares it with the live one before the import and stops on a difference or a 412, and the restore
 * command it prints writes the live fingerprint into a copy of the export, since the export's own is stale once the
 * map changes and later gcloud versions refuse a stale one with 412.
 */
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
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
let deploySrc = read("../../docs/signed-out/deploy.sh");
let urlmapSrc = read("../../docs/signed-out/urlmap.py");
const urlmapFixture = JSON.parse(read("./signed-out-urlmap.json"));

if (PROVOKE) {
  page = page
    .replace("default-src 'none';", "default-src *;")
    .replace("var T = {", "fetch('/x'); document.cookie = 'a=1'; var T = {")
    // the continue line that Google refused in prod, put back
    .replace('document.getElementById("add-account").textContent = t.addAccount;',
      'var another = document.getElementById("add-account");\n  another.textContent = t.addAccount;\n' +
      '  another.href = "https://accounts.google.com/AddSession?continue=" + encodeURIComponent("https://" + location.host + "/");')
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
  // the audit's two findings put back (a role that lists the bucket, one prefix rule with no redirect), and the
  // value on public access prevention that stopped the first --apply in prod
  deploySrc = deploySrc
    .replace("PUBLIC_ROLE=roles/storage.legacyObjectReader", "PUBLIC_ROLE=roles/storage.objectViewer")
    .replace("--no-public-access-prevention", "--public-access-prevention=inherited");
  urlmapSrc = urlmapSrc
    .replace('"matchRules": [{"fullPathMatch": SIGNED_OUT}, {"prefixMatch": SIGNED_OUT + "/"}]', '"matchRules": [{"prefixMatch": SIGNED_OUT}]')
    .replace('"redirectResponseCode": "FOUND"', '"redirectResponseCode": "MOVED_PERMANENTLY_DEFAULT"');
  // the second prod --apply's re-import of an unchanged map, a new map without the fingerprint, the plain import of
  // a stale export as the restore command
  urlmapSrc = urlmapSrc
    .replace('nothing to change")\n            json.dump(new, open(validate_path, "w"), indent=2)',
      'nothing to change")\n            json.dump(new, open(new_path, "w"), indent=2)\n            json.dump(new, open(validate_path, "w"), indent=2)')
    .replace('    json.dump(new, open(new_path, "w"), indent=2)\n    json.dump({**new, "tests": tests}',
      '    json.dump({k: v for k, v in new.items() if k != "fingerprint"}, open(new_path, "w"), indent=2)\n    json.dump({**new, "tests": tests}');
  deploySrc = deploySrc
    .replace('if [ ! -f "${WORK}/urlmap-new.json" ]; then', "if false; then")
    .replace('[ "$live_fp" = "$planned_fp" ] || changed_since_export', "true")
    .replace("--source=${RESTORE} --quiet", "--source=${EXPORT} --quiet");
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
// Google's two web addresses, as they stand in the markup: AddSession (no continue: Google refuses one outside Google) and Logout
const GOOGLE = ["https://accounts.google.com/AddSession", "https://accounts.google.com/Logout"];
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
  ...(text("title") !== en.title || text("subtitle") !== en.subtitle || text("log-in") !== en.logIn || text("add-account") !== en.addAccount ||
      text("add-account-hint") !== en.addAccountHint
    ? ["the markup's English defaults differ from copy.ts"] : []),
  ...(!page.includes(`${sharedBefore}<a id="google-logout"`) ? ["the shared-computer line differs"] : []),
  ...(!/navigator\.languages/.test(code) || !/=== "nl" \? "nl" : "en"/.test(code) ? ["the language is not taken from the browser, English by default"] : []),
]);

check("the three links: Log in to / (focused), Add another account to Google's plain AddSession in a new tab, Google's Logout", [
  ...(!/<a class="button" id="log-in" href="\/" autofocus>/.test(page) ? ["Log in is not / with autofocus"] : []),
  ...(!/logIn\.focus\(\)/.test(code) ? ["Log in is not focused by the script"] : []),
  ...(!page.includes('<a id="add-account" href="https://accounts.google.com/AddSession" target="_blank" rel="noopener noreferrer" aria-describedby="add-account-hint">')
    ? ["Add another account is not plain AddSession with target=_blank and rel=\"noopener noreferrer\""] : []),
  ...(page.split("https://accounts.google.com/AddSession").length !== 2 ? ["AddSession is not named exactly once"] : []),
  ...(/continue/i.test(page) ? ["a continue in the page or its script"] : []),
  ...(/\.href\s*=|setAttribute\s*\(|\.search\s*=/.test(code) ? ["the script changes a link's address"] : []),
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

// ---- the bucket and the route ----------------------------------------------------------------------
const binds = [...deploySrc.matchAll(/add-iam-policy-binding(?:[^\n]*\\\n)*[^\n]*/g)].map((m) => m[0].replace(/\\\n\s*/g, ""));
check("deploy.sh grants allUsers legacyObjectReader (no listing), never objectViewer, and stops on any other role", [
  ...(!/^PUBLIC_ROLE=roles\/storage\.legacyObjectReader$/m.test(deploySrc) ? ["the public role is not roles/storage.legacyObjectReader"] : []),
  ...(binds.length !== 1 ? [`${binds.length} add-iam-policy-binding calls`] : []),
  ...binds.filter((b) => !b.includes('--member=allUsers --role="$PUBLIC_ROLE"')).map((b) => `a binding other than allUsers to the public role: ${b}`),
  ...(/objectViewer/.test(deploySrc) ? ["objectViewer is named"] : []),
  ...(!deploySrc.includes('if "allUsers" in b.get("members", [])') ? ["the check does not read allUsers' roles from the policy"] : []),
  ...(!deploySrc.includes('if [ "$public_roles" = "$PUBLIC_ROLE" ]; then') ? ["an existing binding is not matched on exactly the public role"] : []),
  ...(!deploySrc.includes('if [ "$role" != "$PUBLIC_ROLE" ]; then') ||
      !deploySrc.includes('echo "b. STOP: allUsers holds ${role} on gs://${BUCKET}; remove it by hand"') ? ["another role of allUsers does not stop the script"] : []),
]);

// gcloud storage buckets create/update take --[no-]public-access-prevention and --[no-]pap as booleans: a value
// is refused ("ignored explicit argument"), and --no-public-access-prevention leaves the bucket inherited
const creates = [...deploySrc.matchAll(/storage buckets create(?:[^\n]*\\\n)*[^\n]*/g)].map((m) => m[0].replace(/\\\n\s*/g, ""));
check("deploy.sh passes no value to --public-access-prevention or --pap; the bucket's create leaves it inherited", [
  ...[...deploySrc.matchAll(/--(?:no-)?(?:public-access-prevention|pap)=\S*/g)].map((m) => `a value on a boolean flag: ${m[0]}`),
  ...(creates.length !== 1 ? [`${creates.length} bucket creates`] : []),
  ...creates.filter((c) => !/ --no-public-access-prevention(?: |$)/.test(c)).map(() => "the bucket's create does not pass --no-public-access-prevention"),
]);

// Stable JSON: the same value with keys in any order gives the same text
const canon = (v) => JSON.stringify(v, (_, x) => (x && typeof x === "object" && !Array.isArray(x)
  ? Object.fromEntries(Object.keys(x).sort().map((k) => [k, x[k]])) : x));
// A route rule without its description, which is free text
const undescribed = (r) => Object.fromEntries(Object.entries(r).filter(([k]) => k !== "description"));
const HOST = "workspace.example.test";
const WEB = urlmapFixture.defaultService;
const BUCKET = WEB.replace(/backendServices\/[^/]+$/, "backendBuckets/cma-signed-out-backend");
const wantRules = [
  { priority: 1, matchRules: [{ prefixMatch: "/signed-out", queryParameterMatches: [{ name: "gcp-iap-mode", exactMatch: "CLEAR_LOGIN_COOKIE" }] }], service: WEB },
  { priority: 2, matchRules: [{ fullPathMatch: "/signed-out/" }], urlRedirect: { pathRedirect: "/signed-out", redirectResponseCode: "FOUND" } },
  { priority: 3, matchRules: [{ fullPathMatch: "/signed-out" }, { prefixMatch: "/signed-out/" }], service: BUCKET },
];
const wantTests = [
  { host: HOST, path: "/signed-out", service: BUCKET },
  { host: HOST, path: "/signed-out/", expectedOutputUrl: `http://${HOST}/signed-out`, expectedRedirectResponseCode: 302 },
  { host: HOST, path: "/signed-out/logo-blue.png", service: BUCKET },
  { host: HOST, path: "/signed-outx", service: WEB },
];
const work = mkdtempSync(join(tmpdir(), "signed-out-urlmap-"));
const planner = join(work, "urlmap.py");
writeFileSync(planner, urlmapSrc);
writeFileSync(join(work, "before.json"), JSON.stringify(urlmapFixture));
const plan = (before, out) => spawnSync("python3", [planner, "plan", join(work, before), HOST, WEB, BUCKET, join(work, `${out}.json`), join(work, `${out}-validate.json`)], { encoding: "utf8" });
const readJson = (f) => { try { return JSON.parse(readFileSync(join(work, f), "utf8")); } catch { return null; } };
const urlmapProblems = [];
const first = plan("before.json", "new");
const after = first.status === 0 ? readJson("new.json") : null;
const validate = first.status === 0 ? readJson("new-validate.json") : null;
if (first.error) urlmapProblems.push(`python3 did not run: ${first.error.message}`);
else if (first.status !== 0 || !after || !validate) urlmapProblems.push(`the plan stopped: ${(first.stdout + first.stderr).trim().split("\n").pop()}`);
else {
  const OUTPUT_ONLY = ["kind", "id", "creationTimestamp", "selfLink"];
  const rest = (m) => Object.fromEntries(Object.entries(m).filter(([k]) => !OUTPUT_ONLY.includes(k) && k !== "hostRules" && k !== "pathMatchers"));
  const ingestRule = urlmapFixture.hostRules[0];
  const ingestMatcher = urlmapFixture.pathMatchers[0];
  if (after.defaultService !== urlmapFixture.defaultService) urlmapProblems.push("the default service changed");
  if (canon(rest(after)) !== canon(rest(urlmapFixture))) urlmapProblems.push("the map's other fields changed");
  if (canon(after.hostRules) !== canon([ingestRule, { hosts: [HOST], pathMatcher: "cma-web" }])) urlmapProblems.push(`host rules ${canon(after.hostRules)}`);
  if (canon((after.pathMatchers ?? []).find((m) => m.name === ingestMatcher.name)) !== canon(ingestMatcher)) urlmapProblems.push("the ingest path matcher changed");
  const web = (after.pathMatchers ?? []).find((m) => m.name === "cma-web");
  if ((after.pathMatchers ?? []).length !== 2 || !web) urlmapProblems.push("not exactly the ingest matcher and cma-web");
  else {
    if (web.defaultService !== WEB) urlmapProblems.push("cma-web's default is not the web backend");
    if (Object.keys(web).sort().join() !== "defaultService,name,routeRules") urlmapProblems.push(`cma-web holds ${Object.keys(web).sort().join()}`);
    const got = (web.routeRules ?? []).map(undescribed);
    if (canon(got) !== canon(wantRules)) urlmapProblems.push(`route rules ${canon(got)}`);
  }
  const tests = (validate.tests ?? []).map(canon);
  for (const t of wantTests) if (!tests.includes(canon(t))) urlmapProblems.push(`no url-map test ${canon(t)}`);
  if ("tests" in after) urlmapProblems.push("the imported map carries the tests");
}
// The Workspace with a path matcher of its own: priorities 1 to 3 are reserved, pathRules convert from 10 on
const withMatcher = (matcher) => ({ ...urlmapFixture, hostRules: [...urlmapFixture.hostRules, { hosts: [HOST], pathMatcher: "web" }],
  pathMatchers: [...urlmapFixture.pathMatchers, { name: "web", defaultService: WEB, ...matcher }] });
writeFileSync(join(work, "taken.json"), JSON.stringify(withMatcher({ routeRules: [{ priority: 3, matchRules: [{ prefixMatch: "/x" }], service: WEB }] })));
const taken = plan("taken.json", "taken-new");
if (taken.status !== 1 || !/STOP: path matcher web already has a route rule with priority 1, 2 or 3/.test(taken.stdout)) urlmapProblems.push("a matcher with priority 3 taken does not stop the plan");
writeFileSync(join(work, "paths.json"), JSON.stringify(withMatcher({ pathRules: [{ paths: ["/api/*"], service: WEB }] })));
const paths = plan("paths.json", "paths-new");
const converted = paths.status === 0 ? (readJson("paths-new.json")?.pathMatchers ?? []).find((m) => m.name === "web") : null;
if (!converted || "pathRules" in converted ||
    canon((converted.routeRules ?? []).map(undescribed)) !== canon([...wantRules, { priority: 10, matchRules: [{ prefixMatch: "/api/" }], service: WEB }])) {
  urlmapProblems.push("a matcher's pathRules are not converted behind the three rules from priority 10");
}
// A rerun on the planned map: the three rules are in place, so no new map, only the map as it is for validate
const unchangedProblems = [];
// The lock: the new map keeps the fingerprint of the map as read; a map without one stops the plan
const lockProblems = [];
if (!after) {
  unchangedProblems.push("no plan to rerun");
  lockProblems.push("no plan");
} else {
  const again = plan("new.json", "rerun");
  if (again.status !== 0 || !/nothing to change/.test(again.stdout)) unchangedProblems.push("a rerun on the new map does not find the three rules in place");
  if (existsSync(join(work, "rerun.json"))) unchangedProblems.push("a rerun on the new map writes a new map to import");
  if (canon(readJson("rerun-validate.json")) !== canon(after)) unchangedProblems.push("a rerun does not write the map as it is for validate");
  if (after.fingerprint !== urlmapFixture.fingerprint) lockProblems.push(`the new map's fingerprint is ${after.fingerprint ?? "missing"}, not the map's as read`);
}
writeFileSync(join(work, "bare.json"), JSON.stringify(Object.fromEntries(Object.entries(urlmapFixture).filter(([k]) => k !== "fingerprint"))));
const bare = plan("bare.json", "bare-new");
if (bare.status !== 1 || !/STOP: the map as read has no fingerprint/.test(bare.stdout) || existsSync(join(work, "bare-new.json"))) {
  lockProblems.push("a map without a fingerprint does not stop the plan");
}
rmSync(work, { recursive: true, force: true });
check("urlmap.py on the fixture: exactly the three route rules, the default service and the ingest host rule kept, the new tests", urlmapProblems);

// deploy.sh: the import only when there is a new map, after validate; an unchanged map says so
const guard = 'if [ ! -f "${WORK}/urlmap-new.json" ]; then\n  echo "e. map unchanged, no import"\nelse\n';
const imports = [...deploySrc.matchAll(/url-maps import "\$URLMAP"/g)].map((m) => m.index);
const guardAt = deploySrc.indexOf(guard);
const guardEnd = guardAt < 0 ? -1 : deploySrc.indexOf("\nfi\n", guardAt);
check("an unchanged plan is validated, not imported: urlmap.py writes no new map, deploy.sh imports only a new one", [
  ...unchangedProblems,
  ...(guardAt < 0 ? ["deploy.sh does not skip the import without a new map (\"e. map unchanged, no import\")"] : []),
  ...(imports.length !== 1 ? [`${imports.length} url-maps imports in deploy.sh`] : []),
  ...imports.filter((i) => guardAt < 0 || i < guardAt || i > guardEnd).map(() => "the import is outside the branch for a new map"),
  ...(guardAt >= 0 && deploySrc.indexOf("gcloud compute url-maps validate") > guardAt ? ["validate does not come first"] : []),
]);

// deploy.sh: the live fingerprint against the planned one before the import, a 412 from it, the restore command
const lockAt = deploySrc.indexOf('[ "$live_fp" = "$planned_fp" ] || changed_since_export');
check("the import is locked on the map as read (its fingerprint kept, compared, a 412 stops), the restore writes the live one", [
  ...lockProblems,
  ...(!deploySrc.includes(`planned_fp="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["fingerprint"])' "\${WORK}/urlmap-new.json")"`) ? ["the planned fingerprint is not read from urlmap-new.json"] : []),
  ...(!deploySrc.includes(`live_fp="$(gcloud compute url-maps describe "$URLMAP" --project="$PROJECT" --global --format='value(fingerprint)')"`) ? ["the live fingerprint is not read"] : []),
  ...(lockAt < 0 || lockAt > (imports[0] ?? -1) ? ["the two fingerprints are not compared before the import"] : []),
  ...(!deploySrc.includes(`|| { grep -Eq '^ERROR: .*(412|conditionNotMet)' "\${WORK}/urlmap-import.txt" && changed_since_export; exit 1; }`) ? ["a 412 from the import does not stop as a changed map"] : []),
  ...(!deploySrc.includes('echo "e. STOP: ${URLMAP} changed since the export; nothing was imported, rerun"') ? ["the STOP line for a changed map is missing"] : []),
  ...(!deploySrc.includes(`{ grep -v '^fingerprint:' \${EXPORT}; echo "fingerprint: '\\$fp'"; } > \${RESTORE}`) ? ["the restore does not write the live fingerprint into a copy"] : []),
  ...(!deploySrc.includes("--global --source=${RESTORE} --quiet") ? ["the restore does not import the copy"] : []),
  ...(deploySrc.includes("--source=${EXPORT}") ? ["the export itself is imported, with its stale fingerprint"] : []),
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
