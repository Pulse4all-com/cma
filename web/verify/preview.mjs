/**
 * Verifier: preview as role (src/lib/auth/preview.ts, 16 October 2026), without a server or a database.
 *
 *   node --experimental-strip-types verify/preview.mjs             every check must PASS
 *   node --experimental-strip-types verify/preview.mjs --provoke   every check must FAIL
 *
 * Covers: the narrowing is an intersection and nothing else (a property test over random sets: a subset of
 * the real set and of the role's set, every common key kept, each key once, in the real set's order); an
 * unknown role key is ignored; a non-admin's cookie is ignored; an empty intersection is allowed, and such a
 * person still lands on Welcome, as everyone with a role does (firstPage()); canPreview is true for the admin
 * whether or not a preview is on; the cookie's name and 12 hours; which keys are accepted at all.
 */
import { applyPreview, isRoleKey, mayPreview, narrowPermissions, PREVIEW_COOKIE, PREVIEW_MAX_AGE_S } from "../src/lib/auth/preview.ts";
import { firstPage, visiblePages } from "../src/lib/nav.ts";
import { t } from "../src/lib/copy.ts";

const PROVOKE = process.argv.includes("--provoke");
const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(64)} got ${JSON.stringify(actual).slice(0, 70)}${pass ? "" : `, wanted ${JSON.stringify(want).slice(0, 70)}`}`);
}

const ALL = ["workday.own", "workday.team", "workday.export", "roster.view", "roster.manage", "skills.manage", "leads.accept",
  "performance.own", "performance.team", "monitoring.live", "quality.manage", "messages.send", "reports.view",
  "users.manage_agents", "users.manage_all", "tenant.configure"];
const copy = t("en");
const principal = (permissions, roleKey = "admin") => ({
  tenantId: "t", tenantName: "Tenant", userId: "u", displayName: "Someone", organisationName: "Org", roleKey,
  permissions, locale: "en", timeZone: "Europe/Madrid", preview: null, canPreview: false, perPerson: ["email", "orders"],
});
const ADMIN = ["workday.own", "workday.team", "workday.export", "performance.team", "monitoring.live", "reports.view",
  "users.manage_agents", "users.manage_all", "tenant.configure", "skills.manage", "roster.manage", "roster.view", "messages.send"];
const roles = [
  { key: "agent", name: "Agent", permissions: ["workday.own", "roster.view", "leads.accept", "performance.own"] },
  { key: "analytics", name: "Analytics", permissions: ["reports.view", "performance.team", "monitoring.live", "quality.manage"] },
  { key: "supervisor", name: "Supervisor", permissions: ["workday.own", "roster.view", "workday.team", "performance.team", "monitoring.live", "messages.send"] },
  { key: "coach", name: "Coach", permissions: ["quality.manage"] },
];

// ---- the intersection, as a property over random sets --------------------------------------------------
let seed = 20261016;
const rnd = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;
const pick = () => ALL.filter(() => rnd() < 0.5);
let holds = 0;
const TRIES = 300;
for (let i = 0; i < TRIES; i++) {
  const real = pick();
  const role = pick();
  const got = narrowPermissions(real, role);
  const common = real.filter((p) => role.includes(p));
  const subsetOfReal = got.every((p) => real.includes(p));
  const subsetOfRole = got.every((p) => role.includes(p));
  const keepsCommon = common.every((p) => got.includes(p));
  const once = new Set(got).size === got.length;
  const inRealOrder = JSON.stringify(got) === JSON.stringify(common);
  if (subsetOfReal && subsetOfRole && keepsCommon && once && inRealOrder) holds++;
}
expect("the narrowing is exactly the intersection, in the real order, each key once", holds, TRIES, TRIES - 1);
expect("a role's permission the person lacks never appears", narrowPermissions(["workday.own"], ["workday.own", "quality.manage"]), ["workday.own"], ["workday.own", "quality.manage"]);
expect("a key named twice in the real set is kept once", narrowPermissions(["reports.view", "reports.view", "workday.own"], ["reports.view"]), ["reports.view"], ["reports.view", "reports.view"]);

// ---- applyPreview ----------------------------------------------------------------------------------------
const asAgent = applyPreview(principal(ADMIN), "agent", roles);
expect("the admin previewing as agent sees the intersection", asAgent.permissions, ["workday.own", "roster.view"], ["workday.own", "roster.view", "leads.accept", "performance.own"]);
expect("the preview names the role", asAgent.preview, { roleKey: "agent", roleName: "Agent" }, null);
expect("canPreview is true while previewing", asAgent.canPreview, true, false);
expect("canPreview is true for the admin without a preview", applyPreview(principal(ADMIN), undefined, roles).canPreview, true, false);
expect("no cookie: the admin keeps every permission", applyPreview(principal(ADMIN), undefined, roles).permissions, ADMIN, ["workday.own"]);
const unknown = applyPreview(principal(ADMIN), "director", roles);
expect("an unknown role key is ignored", [unknown.preview, unknown.permissions.length], [null, ADMIN.length], [{ roleKey: "director", roleName: "director" }, 0]);
const manager = principal(["workday.own", "workday.team", "performance.team", "users.manage_agents", "roster.manage"], "manager");
const managerTry = applyPreview(manager, "agent", roles);
expect("a non-admin's cookie is ignored: permissions unchanged, no preview", [managerTry.preview, managerTry.permissions], [null, manager.permissions], [{ roleKey: "agent", roleName: "Agent" }, ["workday.own"]]);
expect("a non-admin cannot preview", [managerTry.canPreview, mayPreview(manager.permissions)], [false, false], [true, true]);
const empty = applyPreview(principal(ADMIN), "coach", roles);
expect("an empty intersection is allowed", [empty.permissions, empty.preview?.roleKey], [[], "coach"], [["quality.manage"], "coach"]);
expect("with no permission left the person still lands on Welcome, like everyone with a role",
  [firstPage(empty, copy), visiblePages(empty, copy).map((p) => p.href)], ["/", ["/", "/messages"]], [null, []]);
expect("the real principal is not changed by the narrowing", principal(ADMIN).permissions.length, ADMIN.length, 2);
expect("the user and the tenant stay the person's own", [asAgent.userId, asAgent.tenantId, asAgent.roleKey], ["u", "t", "admin"], ["agent", "t", "agent"]);

// ---- the cookie and the keys -----------------------------------------------------------------------------
expect("the cookie's name and 12 hours", [PREVIEW_COOKIE, PREVIEW_MAX_AGE_S], ["cma-preview-role", 43200], ["cma-preview", 86400]);
expect("role keys are lower-case slugs", ["agent", "call_center-2", "a".repeat(64)].map(isRoleKey), [true, true, true], [true, true, false]);
expect("anything else is refused", ["", "Agent", "agent; Path=/", "a".repeat(65), 7, null, undefined].map(isRoleKey), [false, false, false, false, false, false, false], [true, false, false, false, false, false, false]);

const passed = results.filter(Boolean).length;
const n = results.length;
if (PROVOKE) {
  const ok = passed === 0;
  console.log(`\npreview: ${ok ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
  process.exit(ok ? 0 : 1);
} else {
  const ok = passed === n;
  console.log(`\npreview: ${ok ? `PASS (${n} checks)` : `FAIL (${n - passed} of ${n})`}`);
  process.exit(ok ? 0 : 1);
}
