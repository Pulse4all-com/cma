/**
 * Verifier: the Trusted Shops adapter without a database (addition 0008ze, brief B18), against verify/etrusted-fake.mjs
 * and the invented fixture verify/fixtures/trustedshops/reviews-source.json.
 *
 *   node verify/reviews-mapping.mjs [--provoke]
 *
 * Proves: no customer field, title or text survives the map (item and raw), raw holds the allowed keys only, the email
 * comes back beside the item for the match in memory only; published from the state; a statement, a reply, a decimal
 * rating; unreadable reviews and channels refused; the client's token minted once per connection, secret name and
 * client id, again near its expiry and after a 401, sent with the audience; paging across pages until a short page,
 * totalElements 0 next to items ignored; ignoreStatements=false sent unless the connection says otherwise; a 429 is
 * rate_limited and holds the connection; the requests counted per endpoint; the settings' ranges; the contact match
 * (one, none, several; the map of emails emptied; below the daily floor a poll defers the rest and a backfill pauses);
 * the poll's cadence; the year windows; and the adapter's code naming no customer field but the email, which no log
 * line carries.
 */
import { mkdtempSync, writeFileSync, rmSync, readdirSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, verdict, PROVOKE } from "./lib.mjs";
import { startFakeETrusted, loadReviewsSource } from "./etrusted-fake.mjs";

console.log(`verify/reviews-mapping.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

const NOW = Date.now();
const source = loadReviewsSource(NOW);
const secretsDir = mkdtempSync(path.join(tmpdir(), "reviews-mapping-"));
writeFileSync(path.join(secretsDir, "fixture-etrusted-secret-a"), "fixture-etrusted-client-secret-a");
writeFileSync(path.join(secretsDir, "fixture-etrusted-secret-b"), "fixture-etrusted-client-secret-b");
const fake = await startFakeETrusted({
  clients: { "fixture-client-a": "fixture-etrusted-client-secret-a", "fixture-client-b": "fixture-etrusted-client-secret-b" },
  channels: source.channels, reviews: source.reviews, contacts: source.contacts,
});
process.env.INGEST_SECRETS_DIR = secretsDir;
process.env.INGEST_ETRUSTED_LOGIN_BASE = fake.url;
process.env.INGEST_ETRUSTED_API_BASE = fake.url;
process.env.INGEST_PACE_FACTOR = "0";
const logs = [];
const { setLogSink } = await import("../src/core/log.mjs");
setLogSink((line) => logs.push(line));
const { reviewOf, channelItem, PUBLISHED_STATE } = await import("../src/adapters/trustedshops/map.mjs");
const { reviewSettings, resetClients, holdUntilOf, endpointOf, tokenFor } = await import("../src/adapters/trustedshops/client.mjs");
const { clientFor, PAGE_SIZE } = await import("../src/adapters/trustedshops/read.mjs");
const { matchReviews } = await import("../src/adapters/trustedshops/match.mjs");
const { pollDue, yearWindows, CADENCE_STREAM } = await import("../src/adapters/trustedshops/reconcile.mjs");
const { JobBudget } = await import("../src/core/budget.mjs");
const { SourceError } = await import("../src/core/http.mjs");

// ---- A. The map --------------------------------------------------------------------------------------
const PERSONAL = ["Invented Reviewer", "@example.com", "+44 20 0000", "Fixture title", "Fixture text", "fullName", "mobile", "comment", "title", "customer"];
const mapped = source.reviews.map(reviewOf);
const kept = mapped.filter(Boolean);
const itemText = JSON.stringify(kept.map((m) => m.item));
expect("A1 no name, email, phone, title or text in any mapped item or its raw", PERSONAL.filter((p) => itemText.includes(p)), [], PERSONAL);
const RAW_KEYS = ["id", "channelRef", "rating", "type", "state", "submittedAt", "updatedAt", "inviteRef", "event", "transaction"];
expect("A2 raw holds the allowed keys only; event its type, transaction its reference",
  [kept.every((m) => Object.keys(m.item.raw).every((k) => RAW_KEYS.includes(k))),
    kept.every((m) => !m.item.raw.event || Object.keys(m.item.raw.event).join() === "type"),
    kept.every((m) => !m.item.raw.transaction || Object.keys(m.item.raw.transaction).join() === "reference")],
  [true, true, true], [false, false, false]);
const order = mapped[0];
expect("A3 the order review: its fields, published, the email beside the item (not in it)",
  [order.item.reviewId, order.item.channelId, order.item.rating, order.item.isPublished, order.item.inviteEventType, order.item.transactionRef,
    order.item.hasReply, order.email, "email" in order.item],
  ["rev-fixture-order-1", "chl-fixture-nl", 5, true, "checkout", "TESTNL-71001", false, "order-buyer@example.com", false],
  ["rev-fixture-order-1", "chl-fixture-nl", 5, true, "checkout", "TESTNL-71001", false, null, true]);
expect("A4 published only in the state APPROVED; a decimal rating kept; a reply that is null is no reply",
  [PUBLISHED_STATE, mapped[6].item.isPublished, mapped[3].item.rating, mapped[2].item.hasReply, reviewOf({ ...source.reviews[2], reply: { comment: "x" } }).item.hasReply],
  ["APPROVED", false, 3.5, false, true], ["APPROVED", true, 3, true, false]);
expect("A5 unreadable reviews refused (rating 0 or 6, no id, no channel, no time, a time that is no ISO time)",
  [mapped[8], reviewOf({ ...source.reviews[0], rating: 6 }), reviewOf({ ...source.reviews[0], id: undefined }), reviewOf({ ...source.reviews[0], channelRef: "" }),
    reviewOf({ ...source.reviews[0], submittedAt: undefined }), reviewOf({ ...source.reviews[0], submittedAt: "yesterday" })],
  [null, null, null, null, null, null], [null, null, null, null, null, {}]);
// A7 (addition 0008zf): a transaction reference is kept only when the connection's pattern accepts it and it holds no @;
// otherwise it is left out of the item and raw, and the review says refDropped (the run counts ref_dropped)
const refOf = (ref, settings = {}) => {
  const m = reviewOf({ ...source.reviews[0], transaction: ref === undefined ? undefined : { reference: ref } }, { refPattern: reviewSettings(settings).refPattern });
  return `${m.item.transactionRef ?? "-"}:${m.item.raw.transaction?.reference ?? "-"}:${m.refDropped}`;
};
expect("A7 the reference: kept when the pattern accepts it and it holds no @, else dropped from the item and raw, flagged",
  [`${mapped[2].item.transactionRef ?? "-"}:${mapped[2].item.raw.transaction?.reference ?? "-"}:${mapped[2].refDropped}`,
    `${mapped[3].item.transactionRef}:${mapped[3].item.raw.transaction?.reference}:${mapped[3].refDropped}`,
    refOf("buyer@example.com"), refOf("P4AUK-990001"), refOf("A B"), refOf(undefined), refOf(""), refOf("x".repeat(101)),
    refOf("SO-12", { transaction_ref_pattern: "^SO-[0-9]+$" }), refOf("P4AUK-1", { transaction_ref_pattern: "^SO-[0-9]+$" }),
    refOf("a@b.example", { transaction_ref_pattern: ".*" }), reviewSettings({ transaction_ref_pattern: "(" }).fallbacks,
    reviewSettings({}).refPattern.source],
  ["-:-:true", "P4AUK-990002:P4AUK-990002:false", "-:-:true", "P4AUK-990001:P4AUK-990001:false", "-:-:true", "-:-:false", "-:-:false",
    "-:-:true", "SO-12:SO-12:false", "-:-:true", "-:-:true", ["transaction_ref_pattern"], "^[A-Za-z0-9#_.:/-]{1,100}$"],
  ["nobody.order@example.com:nobody.order@example.com:false", "-:-:true", "buyer@example.com:buyer@example.com:false", "-:-:true",
    "A B:A B:false", "-:-:true", "-:-:true", "x:x:false", "-:-:true", "P4AUK-1:P4AUK-1:false", "a@b.example:a@b.example:false", [], ""]);
expect("A6 channels: id, name, locale; a channel without an id refused; a long name or a control character left out",
  [channelItem(source.channels[0]), channelItem({ name: "x" }), channelItem({ id: "chl-y", name: "a\u0001b", locale: "en" })],
  [{ channelId: "chl-fixture-nl", name: "shop-nl.example", locale: "nl_NL" }, null, { channelId: "chl-y", name: "chl-y", locale: "en" }],
  [{ channelId: "chl-fixture-nl", name: "shop-nl.example", locale: "nl_NL", url: "https://shop-nl.example" }, null, null]);

// ---- B. The client against the fake ---------------------------------------------------------------------------
const conn = (id, secret) => ({ connectionId: id, tokenSecretName: secret });
const A = conn("00000000-0000-4000-8000-00000000000a", "fixture-etrusted-secret-a");
const A2 = conn("00000000-0000-4000-8000-0000000000a2", "fixture-etrusted-secret-a");
const SET_A = { client_id: "fixture-client-a" };
let budget = new JobBudget({});
let api = clientFor(A, SET_A, budget);
const ch = await api.channels();
const pages = [];
for await (const page of api.reviews("chl-fixture-gb", NOW - 30 * 86_400_000, null)) pages.push(page.length);
expect("B1 the channels; one token for both calls; the audience sent (the fake refuses without it)", [ch.length, fake.state.mints], [3, 1], [3, 2]);
expect("B2 statements asked for: ignoreStatements=false, the star-only review among the GB reviews",
  [fake.state.requests.filter((r) => r.path === "/reviews").at(-1).query.ignoreStatements, pages.reduce((a, b) => a + b, 0)], ["false", 3], [undefined, 2]);
// 237 more on chl-fixture-x besides its fixture review (2.5 hours ago, among the first page): 238 in all, three pages
const many = Array.from({ length: 2 * PAGE_SIZE + 37 }, (_, i) => ({ id: `rev-many-${String(i).padStart(4, "0")}`, channelRef: "chl-fixture-x", rating: 1 + (i % 5),
  type: "SERVICE_REVIEW", state: "APPROVED", submittedAt: new Date(NOW - (i + 1) * 3_600_000).toISOString() }));
fake.state.reviews.push(...many);
const before = fake.state.requests.length;
const sizes = [];
for await (const page of api.reviews("chl-fixture-x", NOW - 400 * 3_600_000, NOW)) sizes.push(page.length);
const asked = fake.state.requests.slice(before).filter((r) => r.path === "/reviews");
expect("B3 paging by the cursor until a short page; totalElements 0 next to the items ignored",
  [sizes, asked.map((r) => r.query.after ?? "-"), asked[0].query.count],
  [[PAGE_SIZE, PAGE_SIZE, 38], ["-", "rev-many-0098", "rev-many-0198"], String(PAGE_SIZE)], [[1], [], "50"]);
fake.state.reviews.splice(fake.state.reviews.length - many.length, many.length);
const api2 = clientFor(A2, SET_A, budget);
await api2.channels();
const apiB = clientFor(conn("00000000-0000-4000-8000-00000000000b", "fixture-etrusted-secret-b"), { client_id: "fixture-client-b" }, budget);
await apiB.channels();
expect("B4 a token per connection, secret name and client id: three connections, three tokens", fake.state.mints, 3, 1);
const noStatements = clientFor(A, { ...SET_A, etrusted_include_statements: false }, budget);
const gb = [];
for await (const page of noStatements.reviews("chl-fixture-gb", NOW - 30 * 86_400_000, null)) gb.push(...page.map((r) => r.id));
expect("B5 etrusted_include_statements false: the parameter left out, the star-only review not answered",
  [fake.state.requests.filter((r) => r.path === "/reviews").at(-1).query.ignoreStatements, gb.includes("rev-fixture-statement-1")], [undefined, false], ["false", true]);
expect("B6 the requests per endpoint on the budget (the token's and the reads')",
  Object.keys(budget.usage().api ?? {}).sort(), ["GET /channels", "GET /reviews", "POST /oauth/token"], ["GET /reviews"]);
fake.state.fail429 = 1;
let code = null;
const t429 = Date.now();
try {
  await api.channels();
} catch (err) {
  code = err instanceof SourceError ? err.code : "other";
}
expect("B7 a 429 → rate_limited, logged with the hold (no data), nothing retried", [code, logs.some((l) => JSON.parse(l).message === "etrusted rate limited"), fake.state.fail429],
  ["rate_limited", true, 0], ["ok", false, 1]);
await api.channels();
expect("B8 the connection held until Retry-After (1 s; the pace factor does not shorten a hold)", Date.now() - t429 >= 900, true, false);
resetClients();
fake.state.expiresIn = 1;
const mints0 = fake.state.mints;
await tokenFor(A, SET_A, AbortSignal.timeout(5000));
await new Promise((r) => setTimeout(r, 700));
await tokenFor(A, SET_A, AbortSignal.timeout(5000));
fake.state.expiresIn = 300;
expect("B9 a token near its expiry is minted again", fake.state.mints - mints0, 2, 1);
const tokenNow = [...fake.state.tokens.keys()].at(-1);
fake.state.tokens.delete(tokenNow);
api = clientFor(A, SET_A, new JobBudget({}));
code = null;
try {
  await api.channels();
} catch (err) {
  code = err.code;
}
await api.channels();
expect("B10 a 401 drops the token: the call fails, the next one mints a new token", [code, fake.state.mints - mints0], ["http_401", 3], ["ok", 2]);
expect("B11 the hold after a 429: Retry-After in seconds, at most two minutes; one minute without it",
  [holdUntilOf({ "retry-after": "5" }, 1000), holdUntilOf({ "retry-after": "900" }, 1000), holdUntilOf({}, 1000), endpointOf("GET", "/reviews?channels=chl-a")],
  [6000, 121000, 61000, "GET /reviews"], [1000, 901000, 1000, "GET /reviews?channels=chl-a"]);
expect("B12 the settings' ranges and defaults; out of range named",
  [reviewSettings({}), reviewSettings({ etrusted_max_per_minute: "120", reviews_poll_interval_minutes: 0, reviews_reconcile_days: 400, etrusted_include_statements: "false", crm_connection_id: " x " })],
  [{ perMinute: 60, intervalMinutes: 60, reconcileDays: 30, includeStatements: true, crmConnectionId: "", refPattern: {}, fallbacks: [] },
    { perMinute: 120, intervalMinutes: 60, reconcileDays: 30, includeStatements: false, crmConnectionId: "x", refPattern: {},
      fallbacks: ["reviews_poll_interval_minutes", "reviews_reconcile_days"] }],
  [{}, {}]);

// ---- C. The contact match, poll cadence, windows -------------------------------------------------------------
const links = [];
const memoryStore = (cursors = {}) => ({
  async setReviewContact(id, crm, contact) { links.push([id, crm, contact]); return "linked"; },
  async config() { return { settings: { reviews_poll_interval_minutes: 60 } }; },
  async cursor(s) { return cursors[s] ?? null; },
});
const side = (answers) => ({ crm: { connectionId: "crm-1" }, adapter: { crm: { async findContactsByEmail({ email }) {
  const a = answers[email];
  if (a instanceof Error) throw a;
  return a ?? [];
} } } });
const emails = new Map([["r1", "one@example.com"], ["r2", "none@example.com"], ["r3", "two@example.com"]]);
let m = await matchReviews({ store: memoryStore(), side: side({ "one@example.com": ["c1"], "two@example.com": ["c2", "c3"] }), emails, budget: new JobBudget({}), pause: false });
expect("C1 one, none, several: the one linked; the map of emails emptied", [m, links, emails.size],
  [{ one: 1, none: 1, several: 1, error: 0, deferred: 0, linked: 1 }, [["r1", "crm-1", "c1"]], 0], [{}, [], 3]);
const floor = new SourceError("daily_floor");
const e2 = new Map([["r1", "a@example.com"], ["r2", "b@example.com"], ["r3", "c@example.com"]]);
m = await matchReviews({ store: memoryStore(), side: side({ "a@example.com": [], "b@example.com": floor }), emails: e2, budget: new JobBudget({}), pause: false });
let paused = null;
const e3 = new Map([["r1", "b@example.com"]]);
try {
  await matchReviews({ store: memoryStore(), side: side({ "b@example.com": floor }), emails: e3, budget: new JobBudget({}), pause: true });
} catch (err) {
  paused = err.code;
}
expect("C2 below the floor: a poll defers the rest and goes on; a backfill pauses (daily_floor); the maps emptied",
  [m.deferred, m.none, e2.size, paused, e3.size], [2, 1, 0, "daily_floor", 0], [0, 0, 3, null, 1]);
const hour = 60 * 60_000;
expect("C3 the poll's cadence: due without a run, after the interval (less the two minutes' slack), not before",
  [await pollDue({ store: memoryStore(), now: NOW }), await pollDue({ store: memoryStore({ [CADENCE_STREAM]: { at: NOW - hour + 60_000 } }), now: NOW }),
    await pollDue({ store: memoryStore({ [CADENCE_STREAM]: { at: NOW - 30 * 60_000 } }), now: NOW })],
  [true, true, false], [false, false, true]);
const w = yearWindows(Date.parse("2024-06-01T00:00:00Z"), Date.parse("2026-03-01T00:00:00Z")).map(([a, b]) => `${new Date(a).toISOString().slice(0, 10)}/${new Date(b).toISOString().slice(0, 10)}`);
expect("C4 the backfill's year windows, oldest first", w, ["2024-06-01/2025-01-01", "2025-01-01/2026-01-01", "2026-01-01/2026-03-01"], []);

// ---- D. The adapter's code -----------------------------------------------------------------------------------
const dir = new URL("../src/adapters/trustedshops/", import.meta.url);
const code_ = readdirSync(dir).filter((f) => f.endsWith(".mjs")).flatMap((f) => readFileSync(new URL(f, dir), "utf8").split("\n")
  .map((line, i) => ({ f, i: i + 1, line: line.replace(/\/\/.*$/, "") })).filter((x) => !/^\s*(\*|\/\*\*)/.test(x.line)));
const named = (re) => code_.filter((x) => re.test(x.line)).map((x) => `${x.f}:${x.i}`);
expect("D1 no code line names the reviewer's name, phone, a title or a text (comments aside)", named(/fullName|mobile|\.title|\.comment|\btitle\b|\bcomment\b/), [], ["map.mjs:1"]);
expect("D2 the email only in the map (taken), the match (searched) and the page (held in memory)",
  [...new Set(named(/email/i).map((x) => x.split(":")[0]))].sort(), ["map.mjs", "match.mjs", "reconcile.mjs"], ["map.mjs"]);
expect("D3 no log line carries an email (no info, warn or error call names one)", named(/\b(info|warn|error)\([^)]*email/i), [], ["x"]);
expect("D4 the logs of this run hold no email, name or token", logs.filter((l) => /@example\.com|Invented|fixture-etrusted-(client-secret|token)/.test(l)).length, 0, 1);

await fake.close();
rmSync(secretsDir, { recursive: true, force: true });
verdict();
