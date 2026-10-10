/**
 * Verifier: the HubSpot project renders (hubspot/render.mjs), without HubSpot, a network or a
 * database.
 *
 *   node hubspot/verify/render.mjs             every check must PASS
 *   node hubspot/verify/render.mjs --provoke   every check must FAIL
 *
 * Covers: dev and prod render; their uids, names and target URLs differ; their scopes are identical,
 * the documented set, and the contact write scope is the only *.write scope; static auth, private
 * distribution, no redirect URLs; the subscription list is the one VENDOR_SETUP.md §1.3 names; the
 * placeholder target URL and other unfit URLs are refused without --draft; the env files hold no
 * ids, tokens or secrets; build/ is git-ignored.
 */
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HUBSPOT_DIR, readEnv, render, targetUrlProblem, write } from "../render.mjs";

const PROVOKE = process.argv.includes("--provoke");
const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(60)} got ${JSON.stringify(actual).slice(0, 70)}${pass ? "" : `, wanted ${JSON.stringify(want).slice(0, 70)}`}`);
}

const REPO = join(HUBSPOT_DIR, "..");
const URL_DEV = "https://cma-ingest-verify-dev.example.com/hubspot/devkey0000000000000000000000000a";
const URL_PROD = "https://cma-ingest-verify-prod.example.com/hubspot/prodkey000000000000000000000000b";
const parse = (r) => Object.fromEntries(Object.entries(r.files).map(([k, v]) => [k, JSON.parse(v)]));
const dev = parse(render("dev", { targetUrl: URL_DEV }));
const prod = parse(render("prod", { targetUrl: URL_PROD }));
const APP = "src/app/app-hsmeta.json";
const HOOKS = "src/app/webhooks/webhook-hsmeta.json";

// ---- both render ---------------------------------------------------------------------------------
expect("dev and prod render the three project files", [Object.keys(dev).sort(), Object.keys(prod).sort()],
  [["hsproject.json", APP, HOOKS].sort(), ["hsproject.json", APP, HOOKS].sort()], [[], []]);
expect("the project: srcDir src, platform version 2026.09", [dev["hsproject.json"].srcDir, dev["hsproject.json"].platformVersion, prod["hsproject.json"].platformVersion],
  ["src", "2026.09", "2026.09"], ["src", "2025.2", "2025.2"]);
expect("types app and webhooks", [dev[APP].type, dev[HOOKS].type, prod[APP].type, prod[HOOKS].type],
  ["app", "webhooks", "app", "webhooks"], ["private-app", "webhook", "private-app", "webhook"]);

// ---- dev and prod are two apps -------------------------------------------------------------------
const uids = [dev[APP].uid, dev[HOOKS].uid, prod[APP].uid, prod[HOOKS].uid];
expect("four distinct uids, HubSpot's uid rule", [new Set(uids).size, uids.every((u) => /^[a-zA-Z0-9_.-]{1,64}$/.test(u))], [4, true], [1, true]);
expect("app and project names", [dev[APP].config.name, prod[APP].config.name, dev["hsproject.json"].name, prod["hsproject.json"].name],
  ["CMA ingest dev", "CMA ingest prod", "CMA ingest dev", "CMA ingest prod"], ["CMA ingest", "CMA ingest", "CMA ingest", "CMA ingest"]);
expect("the target URLs differ and are the ones given", [dev[HOOKS].config.settings.targetUrl, prod[HOOKS].config.settings.targetUrl],
  [URL_DEV, URL_PROD], [URL_DEV, URL_DEV]);
expect("maxConcurrentRequests 10 as a number", [dev[HOOKS].config.settings.maxConcurrentRequests, prod[HOOKS].config.settings.maxConcurrentRequests],
  [10, 10], ["10", "10"]);

// ---- auth and scopes -----------------------------------------------------------------------------
const auth = (p) => p[APP].config.auth;
expect("static auth, private distribution, no redirect URLs",
  [auth(dev).type, dev[APP].config.distribution, "redirectUrls" in auth(dev), "redirectUrls" in dev[APP].config, auth(prod).type, prod[APP].config.distribution],
  ["static", "private", false, false, "static", "private"], ["oauth", "marketplace", true, true, "oauth", "marketplace"]);
expect("dev and prod request identical scopes", JSON.stringify(auth(dev).requiredScopes) === JSON.stringify(auth(prod).requiredScopes)
  && JSON.stringify(auth(dev).optionalScopes) === JSON.stringify(auth(prod).optionalScopes), true, false);
// Scope strings as HubSpot's public API specs name them (HubSpot-public-api-spec-collection, 2026-09
// rollouts) and its project templates (hubspot-project-components 2026.09): see hubspot/README.md.
const SCOPES = ["oauth", "crm.objects.contacts.read", "crm.objects.contacts.write", "crm.objects.deals.read", "tickets",
  "crm.objects.owners.read", "forms"];
expect("the required scopes are exactly the documented set", [...auth(dev).requiredScopes].sort(), [...SCOPES].sort(), [...SCOPES, "crm.objects.deals.write"].sort());
expect("no optional or conditional scopes", [auth(dev).optionalScopes, auth(dev).conditionallyRequiredScopes], [[], []], [["forms"], []]);
expect("crm.objects.contacts.write is the only *.write scope", auth(dev).requiredScopes.filter((s) => /write/.test(s)), ["crm.objects.contacts.write"], []);
// HubSpot has no read-only ticket scope: `tickets` also allows ticket writes. The CMA's code never
// writes tickets; the scope is named here so adding any other write-capable scope fails this check.
const WRITE_CAPABLE = new Set(["crm.objects.contacts.write", "tickets"]);
expect("write-capable scopes: contacts write, and tickets (HubSpot has no read-only one)",
  auth(dev).requiredScopes.filter((s) => WRITE_CAPABLE.has(s) || /write|sensitive|schemas|automation|e-commerce/.test(s)).sort(),
  ["crm.objects.contacts.write", "tickets"], ["crm.objects.contacts.write"]);

// ---- subscriptions: VENDOR_SETUP.md §1.3 ----------------------------------------------------------
const vendor = readFileSync(join(REPO, "docs/night-2026-10-10/VENDOR_SETUP.md"), "utf8");
const section = (from, to) => vendor.slice(vendor.indexOf(from), vendor.indexOf(to, vendor.indexOf(from) + from.length));
const contactProps = [...section("### 1.1", "### 1.2").matchAll(/^\| [^|]+ \| `([a-z0-9_]+)` \|/gm)].map((m) => m[1]);
const s13 = section("### 1.3", "## 2.");
const crm = (o, t, p) => (p ?? [null]).map((x) => `${o} ${t}${x ? ` ${x}` : ""}`);
const EXPECTED = [
  ...["object.creation", "object.deletion", "object.merge", "object.restore"].flatMap((t) => crm("deal", t)),
  ...crm("deal", "object.propertyChange", ["pipeline", "dealstage", "hubspot_owner_id", "closedate", "amount"]),
  ...crm("deal", "object.associationChange"),
  ...["object.creation", "object.deletion", "object.merge", "object.restore"].flatMap((t) => crm("ticket", t)),
  ...crm("ticket", "object.propertyChange", ["hs_pipeline", "hs_pipeline_stage", "hubspot_owner_id", "closed_date"]),
  ...crm("ticket", "object.associationChange"),
  ...crm("contact", "object.propertyChange", contactProps),
  ...crm("contact", "object.deletion"), ...crm("contact", "object.merge"),
  ...crm("call", "object.creation"),
  ...crm("call", "object.propertyChange", ["hs_call_status", "hs_call_disposition", "hubspot_owner_id"]),
  ...crm("call", "object.deletion"), ...crm("call", "object.associationChange"),
].sort();
const subs = (p) => p[HOOKS].config.subscriptions;
const asText = (list) => list.map((s) => `${s.objectType} ${s.subscriptionType}${s.propertyName ? ` ${s.propertyName}` : ""}`).sort();
expect("§1.1 names nine contact properties, all in §1.3's subscriptions", [contactProps.length, contactProps.every((p) => subs(dev).crmObjects.some((s) => s.propertyName === p))],
  [9, true], [8, true]);
expect("every deal, ticket and call property is named in §1.3",
  ["pipeline", "dealstage", "hubspot_owner_id", "closedate", "amount", "hs_pipeline", "hs_pipeline_stage", "closed_date",
   "hs_call_status", "hs_call_disposition", "contact.privacyDeletion", "object.associationChange", "object.restore"].every((x) => s13.includes(`\`${x}\``)),
  true, false);
expect("crmObjects equal §1.3 (36 subscriptions)", asText(subs(dev).crmObjects), EXPECTED, EXPECTED.slice(1));
expect("prod subscribes to exactly the same", JSON.stringify(subs(prod)) === JSON.stringify(subs(dev)), true, false);
expect("no legacy subscriptions; hubEvents is the privacy deletion only",
  [subs(dev).legacyCrmObjects, subs(dev).hubEvents.map((s) => s.subscriptionType)], [[], ["contact.privacyDeletion"]], [[], []]);
expect("every subscription is active", [...subs(dev).crmObjects, ...subs(dev).hubEvents].every((s) => s.active === true), true, false);

// ---- the placeholder and unfit URLs are refused ----------------------------------------------------
const refused = (fn) => { try { fn(); return false; } catch { return true; } };
expect("the env files' target URL is the placeholder", [targetUrlProblem(readEnv("dev").targetUrl), targetUrlProblem(readEnv("prod").targetUrl)],
  ["still the placeholder", "still the placeholder"], [null, null]);
expect("render refuses the placeholder without --draft", [refused(() => render("dev")), refused(() => render("prod"))], [true, true], [false, false]);
expect("render refuses http, a wrong path, a query and a short key",
  ["http://h.example.com/hubspot/devkey0000000000000000000000000a", "https://h.example.com/aircall/devkey0000000000000000000000000a",
   "https://h.example.com/hubspot/devkey0000000000000000000000000a?x=1", "https://h.example.com/hubspot/short"]
    .map((u) => refused(() => render("dev", { targetUrl: u }))), [true, true, true, true], [false, false, false, false]);
const draft = render("dev", { draft: true });
expect("--draft renders with the placeholder and says it is a draft",
  [draft.draft, JSON.parse(draft.files[HOOKS]).config.settings.targetUrl], [true, readEnv("dev").targetUrl], [false, URL_DEV]);
const cli = spawnSync(process.execPath, [join(HUBSPOT_DIR, "render.mjs"), "dev", "--out", join(tmpdir(), "cma-hubspot-never-written")], { encoding: "utf8" });
expect("the command line refuses the placeholder with exit code 2", [cli.status, /refused: target URL still the placeholder/.test(cli.stderr)], [2, true], [0, false]);

// ---- files on disk, no secrets ------------------------------------------------------------------
const tmp = mkdtempSync(join(tmpdir(), "cma-hubspot-"));
const dir = write("dev", render("dev", { targetUrl: URL_DEV }), tmp);
const onDisk = [];
(function walk(d) { for (const e of readdirSync(d)) { const p = join(d, e); statSync(p).isDirectory() ? walk(p) : onDisk.push(p.slice(dir.length + 1)); } })(dir);
expect("written: exactly the three files, parseable", [onDisk.sort(), onDisk.every((f) => JSON.parse(readFileSync(join(dir, f), "utf8")))],
  [["hsproject.json", APP, HOOKS].sort(), true], [[], true]);
rmSync(tmp, { recursive: true, force: true });
const envText = ["dev", "prod"].map((e) => readFileSync(join(HUBSPOT_DIR, "env", `${e}.json`), "utf8")).join("\n");
const templateText = ["hsproject.json", APP, HOOKS].map((f) => readFileSync(join(HUBSPOT_DIR, "template", f), "utf8")).join("\n");
expect("env files: the four keys only, no ids of five or more digits", [Object.keys(readEnv("dev")).sort(), /\d{5,}/.test(envText)],
  [["appName", "maxConcurrentRequests", "targetUrl", "uidSuffix"], false], [["appName", "maxConcurrentRequests", "portalId", "targetUrl", "uidSuffix"], false]);
expect("no secret-looking key or value in template or env files",
  /"[^"]*(secret|token|password|apikey|api_key|clientsecret)[^"]*"\s*:|pat-[a-z0-9]{2}-|[A-Fa-f0-9]{32,}/i.test(envText + templateText), false, true);
expect("the template holds placeholders for env values only",
  [...new Set([...templateText.matchAll(/\{\{(\w+)\}\}/g)].map((m) => m[1]))].sort(),
  ["appName", "appUid", "maxConcurrentRequests", "projectName", "targetUrl", "webhooksUid"], ["appName"]);
const ignored = spawnSync("git", ["check-ignore", "-q", "hubspot/build/dev/hsproject.json"], { cwd: REPO }).status === 0;
expect("hubspot/build/ is git-ignored", ignored, true, false);
expect("nothing under hubspot/build is tracked", execFileSync("git", ["ls-files", "hubspot/build"], { cwd: REPO, encoding: "utf8" }).trim(), "", "hubspot/build/dev/hsproject.json");

const passed = results.filter(Boolean).length;
const n = results.length;
if (PROVOKE) {
  const ok = passed === 0;
  console.log(`\n${ok ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
  process.exit(ok ? 0 : 1);
} else {
  const ok = passed === n;
  console.log(`\n${ok ? `ALL ${n} PASS` : `${n - passed} of ${n} FAILED`}`);
  process.exit(ok ? 0 : 1);
}
