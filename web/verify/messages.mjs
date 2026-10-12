/**
 * Verifier: the pure messaging helpers in src/lib/messages.ts (migration 0008): the inbox query, the
 * read and send bodies with the same rules as cma.send_message, the poller's toast and urgent
 * decisions, the browser title and the seconds format.
 *
 *   npm run verify:messages              every check must PASS
 *   npm run verify:messages -- --provoke every check gets a wrong expectation and must FAIL
 */
import { arrivals, fmtSeconds, parseIds, parseInboxQuery, parseSendInput, titleWithUnread } from "../src/lib/messages.ts";

const PROVOKE = process.argv.includes("--provoke");
const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(56)} got ${JSON.stringify(actual).slice(0, 70)}${pass ? "" : `, wanted ${JSON.stringify(want).slice(0, 70)}`}`);
}
const code = (v) => (v.ok ? "ok" : v.code);

// ---- the inbox query
expect("no since, no limit: null and 50", parseInboxQuery(null, null), { ok: true, value: { since: null, limit: 50 } }, { ok: true, value: { since: null, limit: 20 } });
expect("an ISO instant and a limit of 200", parseInboxQuery("2026-10-11T09:00:00.000Z", "200"), { ok: true, value: { since: "2026-10-11T09:00:00.000Z", limit: 200 } }, { ok: false });
expect("a local time is refused", code(parseInboxQuery("2026-10-11T09:00:00+02:00", null)), "invalid_since", "ok");
expect("an impossible date is refused", code(parseInboxQuery("2026-13-45T09:00:00Z", null)), "invalid_since", "ok");
expect("limit 0 and 201 are refused", [code(parseInboxQuery(null, "0")), code(parseInboxQuery(null, "201"))], ["invalid_limit", "invalid_limit"], ["ok", "ok"]);

// ---- the read body
const U1 = "00000000-0000-7000-8000-0000000a0001";
const U2 = "00000000-0000-7000-8000-0000000A0002";
expect("ids: lower-cased and deduplicated", parseIds({ ids: [U2, U1, U1] }).value, [U2.toLowerCase(), U1], [U2, U1, U1]);
expect("ids: empty, not a list, not an id, too many", [code(parseIds({ ids: [] })), code(parseIds({ ids: "x" })), code(parseIds({ ids: ["nope"] })), code(parseIds({ ids: Array(501).fill(U1) }))],
  ["invalid_ids", "invalid_ids", "invalid_ids", "invalid_ids"], ["ok", "ok", "ok", "ok"]);

// ---- the send body
const base = { title: "  Line check at 12:00  ", body: "Stay available.", urgency: "urgent" };
expect("everyone: title trimmed, urgency kept", parseSendInput({ ...base, target: { everyone: true } }).value,
  { title: "Line check at 12:00", body: "Stay available.", urgency: "urgent", target: { everyone: true } }, null);
expect("teams with onlyClockedIn, deduplicated", parseSendInput({ title: "t", target: { teams: ["nl", "nl", "de"], onlyClockedIn: true } }).value.target, { teams: ["nl", "de"], onlyClockedIn: true }, { teams: ["nl", "nl", "de"] });
expect("urgency defaults to normal, body to empty", [parseSendInput({ title: "t", target: { everyone: true } }).value.urgency, parseSendInput({ title: "t", target: { everyone: true } }).value.body], ["normal", ""], ["urgent", ""]);
expect("language with a level and without", [parseSendInput({ title: "t", target: { language: { skill: "fr", minLevel: 3 } } }).value.target, parseSendInput({ title: "t", target: { language: { skill: "fr" } } }).value.target],
  [{ language: { skill: "fr", minLevel: 3 } }, { language: { skill: "fr", minLevel: null } }], []);
expect("users lower-cased", parseSendInput({ title: "t", target: { users: [U2] } }).value.target, { users: [U2.toLowerCase()] }, { users: [U2] });
expect("an empty title and one of 121 characters are refused", [code(parseSendInput({ title: "   ", target: { everyone: true } })), code(parseSendInput({ title: "x".repeat(121), target: { everyone: true } }))], ["invalid_title", "invalid_title"], ["ok", "ok"]);
expect("a body of 501 characters is refused", code(parseSendInput({ title: "t", body: "x".repeat(501), target: { everyone: true } })), "invalid_body_text", "ok");
expect("an unknown urgency is refused", code(parseSendInput({ title: "t", urgency: "loud", target: { everyone: true } })), "invalid_urgency", "ok");
expect("two groups, no group, everyone false, bad level, bad key", [
  code(parseSendInput({ title: "t", target: { everyone: true, teams: ["nl"] } })),
  code(parseSendInput({ title: "t", target: { onlyClockedIn: true } })),
  code(parseSendInput({ title: "t", target: { everyone: false } })),
  code(parseSendInput({ title: "t", target: { language: { skill: "fr", minLevel: 10 } } })),
  code(parseSendInput({ title: "t", target: { teams: ["Team NL"] } })),
], ["invalid_target", "invalid_target", "invalid_target", "invalid_target", "invalid_target"], ["ok", "ok", "ok", "ok", "ok"]);
expect("onlyClockedIn must be a boolean", code(parseSendInput({ title: "t", target: { everyone: true, onlyClockedIn: "yes" } })), "invalid_target", "ok");

// ---- the poller's decisions
const msg = (id, extra = {}) => ({ id, kind: "announcement", urgency: "normal", title: id, body: "", ref: null, createdAt: `2026-10-11T09:0${id.length % 10}:00.000Z`, expiresAt: null, deliveredAt: null, readAt: null, acknowledgedAt: null, ...extra });
const known = new Set();
const first = arrivals(known, [msg("b"), msg("a"), msg("u", { urgency: "urgent" })], true);
expect("first poll: no toasts, the urgent one needs confirming", [first.toasts.map((m) => m.id), first.urgent.map((m) => m.id)], [[], ["u"]], [["b", "a"], ["u"]]);
expect("…and every message is now known", [...known].sort(), ["a", "b", "u"], ["a", "b"]);
const second = arrivals(known, [msg("d"), msg("c", { readAt: "2026-10-11T09:05:00.000Z" }), msg("b"), msg("u", { urgency: "urgent" })], false);
expect("second poll: new unread messages toast, oldest first; known and read ones do not", second.toasts.map((m) => m.id), ["d"], ["d", "c", "b"]);
expect("an urgent message unacknowledged keeps asking; an acknowledged one stops", [second.urgent.map((m) => m.id), arrivals(new Set(), [msg("u", { urgency: "urgent", acknowledgedAt: "2026-10-11T09:05:00.000Z" })], false).urgent.length], [["u"], 0], [[], 1]);
expect("a new urgent message is never a toast", arrivals(new Set(["x"]), [msg("v", { urgency: "urgent" })], false), { toasts: [], urgent: [msg("v", { urgency: "urgent" })] }, { toasts: [msg("v", { urgency: "urgent" })], urgent: [] });

// ---- formatting
expect("the title carries the count, and loses it at zero", [titleWithUnread("Workspace", 3), titleWithUnread("(3) Workspace", 0), titleWithUnread("(3) Workspace", 12)], ["(3) Workspace", "Workspace", "(12) Workspace"], ["Workspace", "(3) Workspace", "(12) Workspace"]);
expect("seconds as m:ss, or a mark when there is nothing", [fmtSeconds(83), fmtSeconds(0), fmtSeconds(null)], ["1:23", "0:00", "–"], ["83", "0", ""]);

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
