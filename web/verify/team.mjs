/**
 * Verifier: the Team screen's logic (src/lib/team.ts), without a browser or a database.
 *
 *   node --experimental-strip-types verify/team.mjs             every check must PASS
 *   node --experimental-strip-types verify/team.mjs --provoke   every check must FAIL
 *
 * Covers the skill grouping and labels, the editor's skill state and the payload it sends, the
 * smallest set of writes between an opened and an edited person, the role options (assignable
 * roles plus the held one), the filters and the Add a person checks. Keys and names are fixture
 * values; nothing in the module branches on them.
 */
import {
  checkNewPerson, editChanges, filterPeople, hasChanges, roleOptions, skillLabel, skillStateOf, skillsByDimension, skillsPayload,
} from "../src/lib/team.ts";

const PROVOKE = process.argv.includes("--provoke");
const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(56)} got ${JSON.stringify(actual).slice(0, 70)}${pass ? "" : `, wanted ${JSON.stringify(want).slice(0, 70)}`}`);
}

const levels = [{ level: 1, name: "Basic" }, { level: 2, name: "Good" }, { level: 3, name: "Fluent" }, { level: 4, name: "Native" }];
const catalog = [
  { dimension: "work_type", key: "sales", name: "Sales", sortOrder: 10, isActive: true, levels: [] },
  { dimension: "language", key: "nl", name: "Dutch", sortOrder: 20, isActive: true, levels },
  { dimension: "language", key: "da", name: "Danish", sortOrder: 10, isActive: true, levels },
  { dimension: "language", key: "xx", name: "Retired tongue", sortOrder: 5, isActive: false, levels },
  { dimension: "work_type", key: "debt", name: "Debt", sortOrder: 30, isActive: true, levels: [] },
];

// ---- grouping and labels --------------------------------------------------------------------
const groups = skillsByDimension(catalog);
expect("dimensions in order, channel left out when empty", groups.map((g) => g.dimension), ["language", "work_type"], ["work_type", "language"]);
expect("skills in catalog order, inactive left out", groups[0].skills.map((s) => s.key), ["da", "nl"], ["xx", "da", "nl"]);
expect("a scaled skill is labelled with its level", skillLabel({ dimension: "language", key: "nl", name: "Dutch", level: 3, levelName: "Fluent" }), "Dutch · Fluent", "Dutch");
expect("a held skill is labelled with its name", skillLabel({ dimension: "work_type", key: "sales", name: "Sales", level: null, levelName: null }), "Sales", "Sales · Yes");

// ---- the editor's state and payload ---------------------------------------------------------
const state = skillStateOf([
  { dimension: "language", key: "nl", name: "Dutch", level: 3, levelName: "Fluent" },
  { dimension: "work_type", key: "sales", name: "Sales", level: null, levelName: null },
]);
expect("state holds the level, or true for a binary skill", state, { nl: 3, sales: true }, { nl: true, sales: 3 });
expect("payload lists held skills with levels, in key order, catalog only",
  skillsPayload({ ...state, xx: 2, ghost: 1 }, catalog), [{ key: "nl", level: 3 }, { key: "sales" }], [{ key: "nl", level: 3 }, { key: "sales" }, { key: "xx", level: 2 }]);

// ---- the smallest set of writes --------------------------------------------------------------
const opened = { roleKey: "agent", active: true, teams: ["nl", "en"], skills: state };
expect("no change means no write", editChanges(opened, { ...opened, teams: ["en", "nl"] }, catalog), {}, { teams: ["en", "nl"] });
expect("a role change writes the role only", editChanges(opened, { ...opened, roleKey: "supervisor" }, catalog), { roleKey: "supervisor" }, { roleKey: "supervisor", teams: ["en", "nl"] });
expect("a team change writes the sorted list", editChanges(opened, { ...opened, teams: ["nl"] }, catalog), { teams: ["nl"] }, { teams: ["nl", "en"] });
expect("a level change writes the full skill list", editChanges(opened, { ...opened, skills: { nl: 4, sales: true } }, catalog).skills, [{ key: "nl", level: 4 }, { key: "sales" }], [{ key: "nl", level: 4 }]);
expect("deactivating writes active false", editChanges(opened, { ...opened, active: false }, catalog), { active: false }, { active: true });
expect("hasChanges", [hasChanges({}), hasChanges({ active: false })], [false, true], [true, false]);

// ---- role options -----------------------------------------------------------------------------
const roles = [
  { key: "agent", name: "Agent", isSystem: true, isManaging: false, assignable: true, permissions: [] },
  { key: "manager", name: "Call center manager", isSystem: true, isManaging: true, assignable: false, permissions: [] },
  { key: "admin", name: "Admin", isSystem: true, isManaging: true, assignable: false, permissions: [] },
];
expect("a manager's options: assignable roles plus the held manager role, disabled",
  roleOptions(roles, "manager"), [{ key: "agent", name: "Agent", disabled: false }, { key: "manager", name: "Call center manager", disabled: true }],
  [{ key: "agent", name: "Agent", disabled: false }]);
expect("a person without a role: assignable roles only", roleOptions(roles, null).map((r) => r.key), ["agent"], ["agent", "manager", "admin"]);

// ---- filters -----------------------------------------------------------------------------------
const people = [
  { userId: "1", displayName: "A", isActive: true, teams: [{ key: "nl", name: "NL" }] },
  { userId: "2", displayName: "B", isActive: false, teams: [{ key: "nl", name: "NL" }] },
  { userId: "3", displayName: "C", isActive: true, teams: [] },
];
expect("active people of every team by default", filterPeople(people, { showInactive: false, team: "" }).map((p) => p.userId), ["1", "3"], ["1", "2", "3"]);
expect("one team, inactive included when asked", filterPeople(people, { showInactive: true, team: "nl" }).map((p) => p.userId), ["1", "2"], ["1"]);

// ---- the Add a person checks -------------------------------------------------------------------
const form = { displayName: "New Person", email: "new.person@example.com", organisationKey: "newco", roleKey: "agent", loginSystem: "google", loginId: "1234567890", timeZone: "" };
expect("a complete form has no problems", checkNewPerson(form), [], ["login"]);
expect("every missing part is named", checkNewPerson({ displayName: " ", email: "nope", organisationKey: "", roleKey: "", loginSystem: "google", loginId: "12 34" }),
  ["name", "email", "employer", "role", "login"], ["name", "email"]);

const passed = results.filter(Boolean).length;
const n = results.length;
if (PROVOKE) {
  const ok = passed === 0;
  console.log(`\nteam: ${ok ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
  process.exit(ok ? 0 : 1);
} else {
  const ok = passed === n;
  console.log(`\nteam: ${ok ? `PASS (${n} checks)` : `FAIL (${n - passed} of ${n})`}`);
  process.exit(ok ? 0 : 1);
}
