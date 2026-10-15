/**
 * Verifier: invitations by email (addition 0008l), without a browser, a server or a database.
 *
 *   node --experimental-strip-types verify/invitations.mjs             every check must PASS
 *   node --experimental-strip-types verify/invitations.mjs --provoke   every check must FAIL
 *
 * Covers src/lib/invitations.ts and src/lib/origin.ts, and reads the routes, the page and the database
 * functions as text where the rule lives there: a case per assignable role of the default ladder (an admin
 * may offer each, a users.manage_agents holder only the roles it may grant, the system role never); the
 * dialog's and the route's checks; the link on the page's own origin; the mail built from copy.ts and the
 * link only, in English and Dutch; the token never in a list (the list's shape, the list route and
 * cma.invitations()); GET /invite changing nothing (the page's one read, cma.invitation_preview stable, no
 * write in it); Accept refusing a cross-origin post before it reads anything; the two settings' parsers; the
 * list's order. Role keys and names are the default ladder's as fixture rows; nothing in the module branches
 * on them.
 */
import { readFileSync } from "node:fs";
import {
  checkInvite, invitationActionable, invitationFromDb, invitationLink, invitationMail, invitePayload, inviteRoleOptions, inviteView,
  normaliseDomains, parseInvitationInput, parseValidDays, sortInvitations,
} from "../src/lib/invitations.ts";
import { isSameOriginPost } from "../src/lib/origin.ts";

const PROVOKE = process.argv.includes("--provoke");
const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(66)} got ${JSON.stringify(actual).slice(0, 70)}${pass ? "" : `, wanted ${JSON.stringify(want).slice(0, 70)}`}`);
}

// The default ladder as cma.roles() answers it (0005a lists assignable roles only: the scheduler never)
const ladder = [
  { key: "agent", name: "Agent", isManaging: false },
  { key: "analytics", name: "Analytics", isManaging: false },
  { key: "supervisor", name: "Supervisor", isManaging: false },
  { key: "manager", name: "Call center manager", isManaging: true },
  { key: "admin", name: "Administrator", isManaging: true },
];
const rolesFor = (all) => ladder.map((r) => ({ ...r, isSystem: true, permissions: [], assignable: all || !r.isManaging }));
const LOCALES = ["en", "nl"];

// ---- a case per assignable role of the default ladder ----------------------------------------------
for (const r of ladder) {
  const offered = inviteRoleOptions(rolesFor(true)).some((o) => o.key === r.key);
  const parsed = parseInvitationInput({ email: `New.${r.key}@Example.com`, displayName: ` ${r.name} `, locale: "nl", roleKey: r.key, organisationKey: "newco" }, LOCALES);
  expect(`users.manage_all may invite as ${r.key}`, [offered, "input" in parsed ? parsed.input.roleKey : null],
    [true, r.key], [false, null]);
}
expect("users.manage_agents is offered only the roles it may grant",
  inviteRoleOptions(rolesFor(false)).map((r) => r.key), ["agent", "analytics", "supervisor"], ["agent", "analytics", "supervisor", "manager", "admin"]);
expect("a role the caller may not assign is never offered (the system role among them)",
  inviteRoleOptions([...rolesFor(false), { key: "scheduler", name: "Scheduler", isSystem: true, isManaging: false, permissions: [], assignable: false }])
    .some((r) => r.key === "scheduler" || r.key === "manager"), false, true);

// ---- the dialog's and the route's checks -----------------------------------------------------------
const form = { email: " ana@example.com ", displayName: "Ana", locale: "nl", roleKey: "agent", organisationKey: "newco", teamKeys: ["nl", "en"], skills: { sales: true, nl: 4 } };
expect("a complete invitation has no problem", checkInvite(form, LOCALES), [], ["email"]);
expect("every missing field is named", checkInvite({ email: "x", displayName: " ", locale: "de", roleKey: "", organisationKey: "", teamKeys: [], skills: {} }, LOCALES),
  ["email", "name", "locale", "role", "employer"], []);
expect("the payload: trimmed, teams sorted, skills by key with their level", invitePayload(form),
  { email: "ana@example.com", displayName: "Ana", locale: "nl", roleKey: "agent", organisationKey: "newco", teamKeys: ["en", "nl"], skills: [{ key: "nl", level: 4 }, { key: "sales" }] },
  { email: " ana@example.com ", displayName: "Ana", locale: "nl", roleKey: "agent", organisationKey: "newco", teamKeys: ["nl", "en"], skills: [] });
const bad = [
  { email: "not an address", displayName: "A", locale: "en", roleKey: "agent", organisationKey: "newco" },
  { email: "a@example.com", displayName: "", locale: "en", roleKey: "agent", organisationKey: "newco" },
  { email: "a@example.com", displayName: "A", locale: "de", roleKey: "agent", organisationKey: "newco" },
  { email: "a@example.com", displayName: "A", locale: "en", roleKey: "Agent!", organisationKey: "newco" },
  { email: "a@example.com", displayName: "A", locale: "en", roleKey: "agent", organisationKey: "newco", teamKeys: "nl" },
  { email: "a@example.com", displayName: "A", locale: "en", roleKey: "agent", organisationKey: "newco", skills: [{ key: "nl", level: 12 }] },
];
expect("the route refuses each malformed body before the database", bad.map((b) => "problem" in parseInvitationInput(b, LOCALES)), bad.map(() => true), bad.map(() => false));
const ok = parseInvitationInput({ email: "A@Example.COM", displayName: " A ", locale: "en", roleKey: "agent", organisationKey: "newco", teamKeys: ["nl", "nl"], skills: [{ key: "nl", level: 2 }, { key: "sales", level: null }] }, LOCALES);
expect("the route lower-cases the address, trims, drops a repeated team", ok.input,
  { email: "a@example.com", displayName: "A", locale: "en", roleKey: "agent", organisationKey: "newco", teamKeys: ["nl"], skills: [{ key: "nl", level: 2 }, { key: "sales" }] }, null);

// ---- the link -------------------------------------------------------------------------------------------
const TOKEN = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abcde";
expect("the link is the page's own https origin, /invite/ and the token",
  [invitationLink("https://workspace.example.com", TOKEN), invitationLink("https://workspace.example.com/team/people?x=1", TOKEN)],
  [`https://workspace.example.com/invite/${TOKEN}`, `https://workspace.example.com/invite/${TOKEN}`], [null, null]);
expect("no link for plain http elsewhere than localhost, or a token of another shape",
  [invitationLink("http://workspace.example.com", TOKEN), invitationLink("https://w.example.com", TOKEN.slice(1)), invitationLink("https://w.example.com", `${TOKEN.slice(1)}/`)],
  [null, null, null], ["http://workspace.example.com/invite/x", null, null]);

// ---- the mail, from copy.ts and the link only --------------------------------------------------------
const copySrc = read("../src/lib/copy.ts");
function copyOf(lang) {
  const m = copySrc.match(new RegExp(`const ${lang}(?::\\s*Copy)? = (\\{[\\s\\S]*?\\n\\})(?: satisfies [^;]+)?;`));
  return Function(`return (${m[1]});`)();
}
const values = { email: "new.agent@example.com", name: "New Agent", inviter: "Test Manager", workspace: "Example Workspace", role: "Agent",
  link: `https://workspace.example.com/invite/${TOKEN}`, expires: "21 October 2026, 14:05" };
for (const lang of LOCALES) {
  const c = PROVOKE ? { ...copyOf(lang).invitationMail, body: "Your code: {token}" } : copyOf(lang).invitationMail;
  const mail = invitationMail(c, values);
  const decoded = decodeURIComponent(mail.href.split("&body=")[1] ?? "");
  // Removing the values from the body leaves the copy's template exactly
  let template = mail.body;
  for (const [k, v] of Object.entries({ ...values, expires: values.expires })) template = template.split(v).join(`{${k}}`);
  expect(`${lang}: subject and body from copy with every value, nothing left over`, [
    mail.subject === c.subject.replace("{workspace}", values.workspace),
    template === copyOf(lang).invitationMail.body.replace(/\n/g, "\r\n"),
    !/\{\w+\}/.test(mail.body),
    mail.body.split(TOKEN).length - 1,
  ], [true, true, true, 1], [true, true, true, 1]);
  expect(`${lang}: a mailto to the invitee, subject and body encoded with CRLF line breaks`, [
    mail.href.startsWith("mailto:new.agent@example.com?subject="),
    decoded === mail.body,
    mail.href.includes("%0D%0A"),
    !/[\s<>"]/.test(mail.href),
  ], [true, true, true, true], [true, false, false, true]);
}

// ---- the token never in a list ---------------------------------------------------------------------------
const row = {
  invitation_id: "00000000-0000-7000-8000-0000000e0001", email: "a@example.com", display_name: "A", locale: "en", role_key: "agent", role_name: "Agent",
  organisation_key: "newco", organisation_name: "Newco", teams: [{ key: "nl", name: "Team NL", extra: 1 }], skills: [],
  state: "open", created_at: new Date("2026-10-14T10:00:00Z"), created_by_name: "M", expires_at: "2026-10-21T10:00:00Z", renewed_at: null,
  accepted_at: null, accepted_user_id: null, accepted_name: null, revoked_at: null, revoked_by_name: null,
  token: TOKEN, token_hash: "a".repeat(64),
};
const listed = PROVOKE ? { ...invitationFromDb(row), token: TOKEN } : invitationFromDb(row);
const listJson = JSON.stringify(listed);
expect("a list row carries named fields only: no token, no hash", [listJson.includes(TOKEN), listJson.includes("a".repeat(64)), Object.keys(listed).includes("tokenHash")],
  [false, false, false], [false, false, false]);
const listRoute = read("../src/app/api/v1/team/invitations/route.ts");
const sql = read("../../db/66_invitations.sql");
const fnBody = (name) => (sql.match(new RegExp(`create or replace function cma\\.${name}\\([\\s\\S]*?\\n\\$\\$;`)) ?? [""])[0];
const listOut = (fnBody("invitations").match(/returns table \(([\s\S]*?)\n\)/) ?? ["", ""])[1];
expect("GET lists through cma.invitations(), whose answer has no token or hash column",
  [/export async function GET\(\)[\s\S]*?listInvitations\(me\)/.test(listRoute), /\btoken/.test(listOut), listOut.includes("invitation_id")],
  [true, false, true], PROVOKE ? [true, true, true] : [true, false, true]);

// ---- GET /invite changes nothing --------------------------------------------------------------------------
const page = read("../src/app/invite/[token]/page.tsx");
const preview = fnBody("invitation_preview");
expect("the page reads the preview only; the preview is stable and writes nothing", [
  /previewInvitation\(identity, token\)/.test(page),
  /acceptInvitation|createInvitation|renewInvitation|revokeInvitation|method="get"/i.test(page),
  /language plpgsql stable security definer/.test(preview),
  /\b(insert|update|delete)\s+(into\s+)?cma\./i.test(preview),
], [true, false, true, false], [true, true, true, false]);
const views = ["open", "invalid", "expired", "wrong_account", "already_member", "other_tenant"].map((result) =>
  inviteView({ result, tenantName: "W", roleName: "Agent", invitedEmail: "a@example.com", locale: "en", expiresAt: null }, "b@example.com").kind);
expect("each preview answer has its own view; a person of that business line goes home", views,
  ["open", "invalid", "expired", "wrong_account", "home", "other_tenant"], ["open", "invalid", "expired", "wrong_account", "already_member", "open"]);

// ---- Accept refuses a cross-origin post ------------------------------------------------------------------
const H = (secFetchSite, origin, host = "workspace.example.com") => ({ secFetchSite, origin, host });
const origins = [
  H("same-origin", null), H("cross-site", "https://evil.example.org"), H("same-site", "https://ingest.example.com"),
  H(null, "https://workspace.example.com"), H(null, "https://evil.example.org"), H(null, null), H(null, "null"), H("none", "https://workspace.example.com"),
].map(isSameOriginPost);
expect("only a same-origin post passes (Sec-Fetch-Site, else the Origin's host)", origins,
  [true, false, false, true, false, false, false, true], [true, true, true, true, true, true, true, true]);
const accept = read("../src/app/invite/accept/route.ts");
const at = (re) => accept.search(re);
expect("Accept checks the origin before anything else, binds the verified identity, answers relative Locations", [
  at(/isSameOriginPost\(/) > -1 && at(/isSameOriginPost\(/) < at(/getIdentity\(\)/) && at(/getIdentity\(\)/) < at(/acceptInvitation\(/),
  /INVITE_TOKEN_RE\.test\(token\)/.test(accept),
  /const location = result === "accepted" \|\| result === "already_member" \? "\/" : `\/invite\/\$\{token\}`;/.test(accept),
  /console\.(log|warn|error)\([^)]*(token|email|identity)/.test(accept),
], [true, true, true, false], PROVOKE ? [false, true, true, false] : [true, true, true, false]);

// ---- the two settings -----------------------------------------------------------------------------------
expect("valid days: a whole number from 1 to 30", ["0", "1", "7", "30", "31", "7.5", "x", " 12 "].map(parseValidDays),
  [null, 1, 7, 30, null, null, null, 12], [0, 1, 7, 30, 31, 7, null, 12]);
expect("domains: lower case, no spaces, comma-separated, empty for any",
  [" Example.ORG , other.example.org ", "", "@example.org", "example", "example.org;b.org", "-bad.org", "a.org,"].map(normaliseDomains),
  ["example.org,other.example.org", "", null, null, null, null, null], [" Example.ORG , other.example.org ", "", "@example.org", null, null, null, null]);

// ---- the list's order and actions ------------------------------------------------------------------------
const inv = (id, state, createdAt) => ({ ...invitationFromDb({ ...row, invitation_id: id, state, created_at: createdAt }) });
const sorted = sortInvitations([inv("a", "accepted", "2026-10-14T09:00:00Z"), inv("b", "open", "2026-10-13T09:00:00Z"), inv("c", "revoked", "2026-10-14T10:00:00Z"),
  inv("d", "expired", "2026-10-01T09:00:00Z"), inv("e", "open", "2026-10-14T08:00:00Z")]);
expect("open, expired, accepted, revoked; newest first; actions on open and expired only",
  [sorted.map((i) => i.invitationId), sorted.map(invitationActionable)],
  [["e", "b", "d", "a", "c"], [true, true, true, false, false]], [["a", "b", "c", "d", "e"], [true, true, true, true, true]]);

const passed = results.filter(Boolean).length;
const n = results.length;
if (PROVOKE) {
  const good = passed === 0;
  console.log(`\ninvitations: ${good ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
  process.exit(good ? 0 : 1);
} else {
  const good = passed === n;
  console.log(`\ninvitations: ${good ? `PASS (${n} checks)` : `FAIL (${n - passed} of ${n})`}`);
  process.exit(good ? 0 : 1);
}
