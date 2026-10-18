/**
 * Verifier (pure: no database, no network beyond localhost): the email poll of brief B17b. What it
 * keeps of HubSpot's email engagements and inbox conversations, and what it never keeps. Invented
 * values only (verify/fixtures/hubspot/email-source.json, email-rules.json).
 *
 *   node verify/email-mapping.mjs             every check must PASS
 *   node verify/email-mapping.mjs --provoke   every check must FAIL
 *
 * Proves: engagements mapped (direction, status, actor kinds, the owner, the CRM thread id and the
 * automation origin by configuration, the category), the properties asked for (the subject and the
 * sender only while a rule needs them; never text, html, headers or recipients); the rule logic on the
 * shared fixtures that verify/email-flow.mjs runs through cma.email_words_match and
 * cma.email_category_of; actor ids to kinds and owner ids (R2); the catalogs (names holding an
 * address dropped); threads, messages and the three event kinds; the cursor's boundary; the owner map
 * kept in cursors; the contact's country slots; the mailboxes (channel accounts: a name holding an
 * address replaced by the id, the delivery identifier never read), a message's and a thread's mailbox
 * and an engagement's origin code (addition 0008t); then a whole poll against a fake HubSpot with an
 * in-memory store: what it writes and logs holds none of the fixture's names, addresses, subjects or
 * texts, a second poll reads no message again and writes nothing, a re-read writes only an engagement held without
 * the origin it now carries (0008t), a 429 leaves the engagements'
 * cursor while the conversations still run, and a thread gone at the source is forgotten.
 */
import { readFileSync } from "node:fs";
import { expect, verdict, PROVOKE } from "./lib.mjs";
import { loadSource, startFakeHubSpot } from "./email-fake.mjs";

console.log(`verify/email-mapping.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

const NOW = Date.now();
const source = loadSource(NOW);
const RULES = JSON.parse(readFileSync(new URL("./fixtures/hubspot/email-rules.json", import.meta.url), "utf8"));
const fake = await startFakeHubSpot(source);
process.env.INGEST_HUBSPOT_API_BASE = fake.url;
process.env.INGEST_PACE_FACTOR = "0";
const secretsDir = (await import("node:fs")).mkdtempSync((await import("node:path")).join((await import("node:os")).tmpdir(), "email-mapping-"));
(await import("node:fs")).writeFileSync(`${secretsDir}/ingest-hubspot-mapping-token`, "fixture-mapping-token");
process.env.INGEST_SECRETS_DIR = secretsDir;

const logs = [];
const { setLogSink } = await import("../src/core/log.mjs");
setLogSink((line) => logs.push(line));
const { emailSettings, emailProperties, emailFromObject, emailStatus, EMAIL_PROPERTIES, backfillEmails } = await import("../src/adapters/hubspot/email.mjs");
const { wordsMatch, classify, activeRules, domainOf } = await import("../src/adapters/hubspot/rules.mjs");
const { actorOf, channelKind, inboxItems, channelItems, accountPairs, accountItems, threadItem, messageRows, advance, afterCursor, threadSame } =
  await import("../src/adapters/hubspot/conversations.mjs");
const { ownerPairs, packMap, unpackMap } = await import("../src/adapters/hubspot/owners.mjs");
const { contactFromObject, contactAttributes } = await import("../src/adapters/hubspot/map.mjs");
const { hubspot } = await import("../src/adapters/hubspot/index.mjs");
const { JobBudget } = await import("../src/core/budget.mjs");

const rulesConfig = RULES.rules.map((r, i) => ({ id: `r${i}`, ...r }));
const CONFIG = {
  settings: { email_poll: true, email_thread_property: "fixture_thread_id", email_origin_property: "fixture_origin", email_automated_origins: "automation_fixture, other_auto" },
  emailRules: rulesConfig,
  fields: [
    { entity: "contact", field: "country", slot: 1, property: "contact_country" },
    { entity: "contact", field: "country", slot: 2, property: "country_dropdown" },
    { entity: "contact", field: "language", slot: 1, property: "contact_language" },
  ],
};
const settings = emailSettings(CONFIG);
const rules = activeRules(CONFIG);
const forbiddenIn = (text) => source.forbidden.filter((f) => text.includes(f));

// ---- A. Settings and the properties asked for ------------------------------------------------------
expect("settings: email_poll true, thread and origin properties, automated origins lower case",
  [settings.enabled, settings.threadProperty, settings.originProperty, [...settings.automated]],
  [true, "fixture_thread_id", "fixture_origin", ["automation_fixture", "other_auto"]], [false, null, null, []]);
expect("settings: email_poll must be the boolean true (a string is off)", emailSettings({ settings: { email_poll: "true" } }).enabled, false, true);
expect("settings: a property name that is not a plain name is ignored", emailSettings({ settings: { email_thread_property: "hs thread; drop" } }).threadProperty, null, "hs thread; drop");
expect("active rules only, in their order", rules.map((r) => r.category), ["billing", "partner", "reminder"], ["orders", "billing", "partner", "reminder"]);
const noRules = emailProperties(settings, []);
expect("no rule: structural properties, thread and origin only", noRules, [...EMAIL_PROPERTIES, "fixture_origin", "fixture_thread_id"].sort(),
  [...noRules, "hs_email_subject"].sort());
const withRules = emailProperties(settings, rules);
expect("a subject and a sender domain rule: the subject and the sender's address asked for too",
  ["hs_email_subject", "hs_email_from_email"].every((p) => withRules.includes(p)), true, false);
expect("only a subject rule: the sender's address is not asked for",
  emailProperties(settings, rules.filter((r) => r.appliesTo === "subject")).includes("hs_email_from_email"), false, true);
expect("never text, html, headers, recipients or names", withRules.filter((p) => /text|html|header|_to_|recipient|name|cc|bcc|attach/.test(p)), [], ["hs_email_text"]);

// ---- B. Engagements ----------------------------------------------------------------------------------
const eng = (id) => emailFromObject({ id, properties: source.engagements[id], updatedAt: source.engagements[id].hs_lastmodifieddate }, settings, rules);
const shape = (e) => e && [e.direction, e.status, e.actorKind, e.ownerRef, e.category, e.threadId];
expect("EMAIL → out, sent, the owner's agent, billing, the CRM thread id", shape(eng("4500000001")), ["out", "sent", "agent", "7100000001", "billing", "th-9000001"],
  ["out", "sent", "agent", null, null, null]);
expect("INCOMING_EMAIL → in, other, customer without an owner, partner by the sender's domain", shape(eng("4500000002")), ["in", "other", "customer", null, "partner", "th-9000001"],
  ["in", "other", "agent", "7100000001", null, "th-9000001"]);
expect("FORWARDED_EMAIL → forwarded, bounced, agent, no category", shape(eng("4500000003")), ["forwarded", "bounced", "agent", "7100000002", null, null],
  ["out", "other", "agent", "7100000002", null, null]);
expect("an automated origin → system, no owner; the reminder rule (billing excluded by its word)", shape(eng("4500000004")), ["out", "sent", "system", null, "reminder", null],
  ["out", "sent", "agent", "7100000002", "billing", null]);
expect("an unknown direction is skipped (null)", eng("4500000005"), null, { direction: "out" });
expect("no owner → unknown; a thread id with @ dropped; scheduled", shape(eng("4500000006")), ["out", "scheduled", "unknown", null, "partner", null],
  ["out", "scheduled", "agent", null, "partner", "bad@thread"]);
expect("statuses: the CMA's four in any case, else other", ["SENT", "Bounced", "failed", "SCHEDULED", "SENDING", "", null].map(emailStatus),
  ["sent", "bounced", "failed", "scheduled", "other", "other", "other"], ["sent", "bounced", "failed", "scheduled", "sending", "other", "other"]);
const engText = JSON.stringify(Object.keys(source.engagements).map(eng));
expect("an engagement item holds no subject, text, html, header, address or name", forbiddenIn(engText), [], ["something"]);
expect("raw holds direction, status and origin codes only", eng("4500000004").raw, { direction: "EMAIL", status: "SENT", origin: "AUTOMATION_FIXTURE" }, {});
expect("without rules no category is computed", emailFromObject({ id: "4500000001", properties: source.engagements["4500000001"] }, settings, []).category, null, "billing");
// Addition 0008t: the origin's code on the item (the database tells an inbox copy and an automation apart by configuration)
const copy = emailFromObject({ id: "4500000091", properties: { ...source.engagements["4500000001"], fixture_origin: "CONVERSATIONS" } }, settings, []);
expect("the origin's code on the item: an automation's, an inbox copy's (still the agent's: the database leaves it out), none without one",
  [eng("4500000004").origin, copy.origin, copy.actorKind, eng("4500000001").origin],
  ["AUTOMATION_FIXTURE", "CONVERSATIONS", "agent", null], [undefined, undefined, "system", "CONVERSATIONS"]);
expect("an origin that is no code (a space, an @) is not sent", emailFromObject({ id: "4500000092", properties: { ...source.engagements["4500000001"],
  fixture_origin: "CRM UI@x" } }, settings, []).origin, null, "CRM UI@x");

// ---- C. The rules: the shared fixtures --------------------------------------------------------------
const wordResults = RULES.words.map((c) => wordsMatch(c.value, c.words, c.exclude));
expect(`words: the ${RULES.words.length} shared cases as cma.email_words_match answers them`, wordResults, RULES.words.map((c) => c.match), RULES.words.map((c) => !c.match));
const catResults = RULES.categories.map((c) => classify({ subject: c.subject, senderDomain: c.senderDomain }, rules));
expect(`categories: the ${RULES.categories.length} shared cases as cma.email_category_of answers them`, catResults, RULES.categories.map((c) => c.category),
  RULES.categories.map(() => "billing"));
expect("the sender's domain: lower case, from a display address, never the local part", ["Invented Customer <Customer.Invented@Example.ORG>", "x@y", "no-at", null].map(domainOf),
  ["example.org", null, null, null], ["customer.invented@example.org", "y", null, null]);

// ---- D. Actors and catalogs -------------------------------------------------------------------------
const owners = unpackMap(packMap(ownerPairs([...source.owners.archived, ...source.owners.active])));
expect("the owner map: user id → owner id, archived owners too", [owners.get("7000000001"), owners.get("7000000003")], ["7100000001", "7100000003"], ["7000000001", null]);
expect("actor prefixes: A agent, V and E customer, S system, B bot, I integration, others unknown",
  ["A-7000000001", "V-123456", "E-customer.invented@example.net", "S-hubspot", "B-1", "I-55", "L-9", "X-unknown-prefix", "garbage", null].map((a) => actorOf(a, owners).kind),
  ["agent", "customer", "customer", "system", "bot", "integration", "unknown", "unknown", "unknown", "unknown"],
  ["agent", "visitor", "email", "system", "bot", "integrator", "ai", "unknown", "unknown", "unknown"]);
expect("an agent's owner id through its user id; an unmapped agent has none", [actorOf("A-7000000002", owners), actorOf("A-7000009999", owners)],
  [{ kind: "agent", ownerRef: "7100000002" }, { kind: "agent", ownerRef: null }], [{ kind: "agent", ownerRef: "7000000002" }, { kind: "agent", ownerRef: "7000009999" }]);
expect("no actor result holds the actor id", JSON.stringify(["A-7000000001", "E-customer.invented@example.net"].map((a) => actorOf(a, owners))).includes("customer.invented"), false, true);
expect("channel kinds from names", ["Email", "Live chat", "WhatsApp", "Facebook Messenger", "Forms", "Calling", "Custom"].map(channelKind),
  ["email", "chat", "whatsapp", "messenger", "form", "phone", "other"], ["email", "email", "email", "email", "email", "email", "email"]);
expect("inboxes: archived left out, a name holding an address replaced by the id", inboxItems(source.inboxes),
  [{ inboxId: "1500000001", name: "Support inbox (test)" }, { inboxId: "1500000002", name: "1500000002" }], source.inboxes);
expect("channels with their kind", channelItems(source.channels).map((c) => c.kind), ["email", "chat", "whatsapp"], ["other", "other", "other"]);
expect("channel accounts: ids only (no name, no delivery identifier)", accountPairs(source.channelAccounts), [["1600000001", "1500000001"], ["1600000002", "1500000002"]], [["1600000001", "support.invented@example.com"]]);
expect("mailboxes (0008t): a name holding an address replaced by the id, inbox and channel, no delivery identifier; an archived one left out",
  accountItems([...source.channelAccounts, { id: "1600000009", channelId: "1002", inboxId: "1500000001", name: "Old box", archived: true }]),
  [{ accountId: "1600000001", name: "1600000001", inboxId: "1500000001", channelId: "1002" }, { accountId: "1600000002", name: "Sales mailbox", inboxId: "1500000002", channelId: "1002" }],
  source.channelAccounts);
const parts = packMap(Array.from({ length: 300 }, (_, i) => [String(7000000000 + i), String(7100000000 + i)]));
expect("the map in parts under the cursor's 2 kB, read back whole", [parts.length > 1, parts.every((p) => p.length <= 1800), unpackMap(parts).size], [true, true, 300], [false, true, 299]);
expect("owner pairs hold ids only (no email, no name)", JSON.stringify(ownerPairs(source.owners.active)), '[["7000000001","7100000001"],["7000000002","7100000002"]]',
  JSON.stringify(source.owners.active));

// ---- E. Threads and messages --------------------------------------------------------------------------
const readAt = new Date(NOW).toISOString();
const th = (id) => threadItem({ id, ...source.threads[id] }, { owners, readAt });
const tShape = (t) => [t.status, t.ownerRef, t.contactId, t.ticketId, t.isSpam, t.inboxId, t.channelId, t.closedAt !== null];
expect("an open thread: agent's owner id, contact, ticket", tShape(th("8800000001")), ["open", "7100000001", "4300000103", "4200000101", false, "1500000001", "1002", false],
  ["open", "A-7000000001", "4300000103", null, false, "1500000001", "1002", false]);
expect("a closed thread: its close time; the assignee an archived owner", tShape(th("8800000002")), ["closed", "7100000003", "4300000102", null, false, "1500000002", "1002", true],
  ["closed", null, "4300000102", null, false, "1500000002", "1002", false]);
expect("a spam thread stored with is_spam, no agent", tShape(th("8800000003")), ["open", null, null, null, true, "1500000001", "1002", false],
  ["open", null, null, null, false, "1500000001", "1002", false]);
expect("an agent without an owner leaves the thread's agent empty", th("8800000004").ownerRef, null, "7000009999");
expect("a thread's mailbox: the channel account it started on (0008t)", ["8800000001", "8800000002"].map((id) => th(id).accountId), ["1600000001", "1600000002"], [null, null]);
expect("a thread held exactly so is not written again", threadSame({ status: "open", ownerRef: "7100000001", inboxId: "1500000001", channelId: "1002", contactId: "4300000103",
  ticketId: "4200000101", isSpam: false, isArchived: false, forgotten: false }, th("8800000001")), true, false);
expect("…and a change of agent is", threadSame({ status: "open", ownerRef: "7100000002", inboxId: "1500000001", channelId: "1002", contactId: "4300000103",
  ticketId: "4200000101", isSpam: false, isArchived: false, forgotten: false }, th("8800000001")), false, true);
const heldNoMailbox = { status: "open", ownerRef: "7100000001", inboxId: "1500000001", channelId: "1002", contactId: "4300000103", ticketId: "4200000101", isSpam: false,
  isArchived: false, forgotten: false };
expect("a thread held without its mailbox: written again by the poll (account), the open check's comparison unchanged",
  [threadSame(heldNoMailbox, th("8800000001"), { account: true }), threadSame(heldNoMailbox, th("8800000001")),
    threadSame({ ...heldNoMailbox, accountId: "1600000001" }, th("8800000001"), { account: true })], [false, true, true], [true, true, false]);
const accounts = new Map(accountPairs(source.channelAccounts));
const rows = (id, afterMs = null) => messageRows(source.messages[id], { thread: { id, ...source.threads[id] }, owners, accounts, rules, afterMs });
const r1 = rows("8800000001");
expect("thread 1: two messages (in from the customer, out by the agent), one assignment, the comment ignored",
  [r1.emails.map((e) => [e.direction, e.actorKind, e.ownerRef, e.status]), r1.events.map((e) => [e.kind, e.actorKind, e.toActorKind, e.toOwnerRef]), r1.ignored],
  [[["in", "customer", null, "other"], ["out", "agent", "7100000001", "sent"]], [["assigned", "system", "agent", "7100000001"]], 1],
  [[["in", "customer", null, "other"]], [], 0]);
expect("thread 1: the first message's category billing (its subject), the contact and inbox of the thread", [r1.firstCategory, r1.emails[0].contactId, r1.emails[0].inboxId],
  ["billing", "4300000103", "1500000001"], [null, null, null]);
expect("a message's mailbox: the channel account it went through (0008t)", r1.emails.map((e) => e.accountId), ["1600000001", "1600000001"], [null, null]);
const r2 = rows("8800000002");
expect("thread 2: moved inbox, assigned (agent to agent), closed; the welcome message ignored",
  [r2.events.map((e) => [e.kind, e.actorKind, e.ownerRef, e.toOwnerRef ?? null, e.fromInboxId ?? null, e.toInboxId ?? null]), r2.ignored],
  [[["moved_inbox", "agent", "7100000002", null, "1500000001", "1500000002"], ["assigned", "agent", "7100000002", "7100000003", null, null],
    ["closed", "agent", "7100000003", null, null, null]], 1], [[], 0]);
expect("thread 2: a visitor's message is the customer's, partner by its sender's domain", [r2.emails[0].actorKind, r2.emails[0].category], ["customer", "partner"], ["visitor", null]);
const r3 = rows("8800000003");
expect("thread 3: an unknown prefix → unknown; an assignment without assignee → no target", [r3.emails[0].actorKind, r3.events[0].kind, r3.events[0].toActorKind, r3.events[0].actorKind],
  ["unknown", "assigned", null, "bot"], ["customer", "assigned", "agent", "unknown"]);
const r4 = rows("8800000004");
expect("thread 4: closed then reopened; a failed outgoing message; an integration's incoming one",
  [r4.events.map((e) => e.kind), r4.emails.map((e) => [e.direction, e.actorKind, e.status])],
  [["closed", "reopened"], [["in", "integration", "other"], ["out", "agent", "failed"]]], [["closed", "closed"], []]);
const markAt = Date.parse(source.messages["8800000001"][0].createdAt);
expect("after the thread's mark only the later messages and events", rows("8800000001", markAt).emails.map((e) => e.sourceId).concat(rows("8800000001", markAt).events.map((e) => e.sourceId)),
  ["m1d0000000000000000000000000004", "m1b0000000000000000000000000002"], ["m1a0000000000000000000000000001"]);
const allRows = JSON.stringify(["8800000001", "8800000002", "8800000003", "8800000004"].map((id) => [rows(id), th(id)]));
expect("no message row or thread item holds a name, address, subject, text or raw actor id", forbiddenIn(allRows), [], ["x"]);
const t = (min) => new Date(NOW - min * 60_000).toISOString();
const cur = advance({ at: null, ids: [] }, [{ id: "1", latestMessageTimestamp: t(10) }, { id: "2", latestMessageTimestamp: t(5) }, { id: "3", latestMessageTimestamp: t(5) }]);
expect("the cursor: the newest latest-message time and the threads at it", cur, { at: Date.parse(t(5)), ids: ["2", "3"] }, { at: Date.parse(t(10)), ids: ["1"] });
expect("…which the next page leaves out, a newer thread at that time kept", afterCursor([{ id: "2", latestMessageTimestamp: t(5) }, { id: "4", latestMessageTimestamp: t(5) }], cur).map((x) => x.id),
  ["4"], ["2", "4"]);

// ---- F. The contact's country slots ---------------------------------------------------------------------
const c1 = contactFromObject({ id: "4300000101", properties: source.contacts["4300000101"] }, CONFIG);
expect("two country slots: countries per slot (slot 1 empty, slot 2 the dropdown), no single country", [c1.countries, c1.country], [[null, "United Kingdom"], undefined],
  [undefined, "United Kingdom"]);
expect("one country slot keeps sending country", contactFromObject({ id: "4300000104", properties: source.contacts["4300000104"] },
  { fields: [{ entity: "contact", field: "country", slot: 1, property: "contact_country" }] }).country, "GB", null);
expect("a record's fallback country: the first non-empty slot", contactAttributes({ id: "4300000101", properties: source.contacts["4300000101"] }, CONFIG).country,
  "United Kingdom", null);
expect("a contact item holds only the configured properties (no email, no name)", forbiddenIn(JSON.stringify(c1)), [], ["x"]);

// ---- G. A whole poll against the fake HubSpot, with an in-memory store ----------------------------------
function memoryStore(config) {
  const s = { cursors: new Map(), emails: new Map(), threads: new Map(), events: new Map(), contacts: new Map(), assoc: new Map(), inboxes: [], channels: [], mailboxes: [], writes: [],
    forgotten: [] };
  const write = (kind, items) => s.writes.push({ kind, items: JSON.parse(JSON.stringify(items)) });
  const outcome = (map, key, item) => {
    const had = map.has(key);
    map.set(key, item);
    return had ? "updated" : "inserted";
  };
  const count = (list) => list.reduce((o, k) => ({ ...o, [k]: (o[k] ?? 0) + 1 }), {});
  return {
    state: s,
    async config() { return config; },
    async cursor(stream) { return s.cursors.get(stream) ?? null; },
    async setCursor(stream, value) { s.cursors.set(stream, JSON.parse(JSON.stringify(value))); },
    async emailStartOf() { return "2026-10-01"; },
    async tenantStartOf(date) { return new Date(`${date}T00:00:00Z`); },
    async emailVersions(kind, ids) {
      return new Map(ids.filter((id) => s.emails.has(`${kind}:${id}`))
        .map((id) => [id, { at: Date.parse(s.emails.get(`${kind}:${id}`).updatedAt), origin: s.emails.get(`${kind}:${id}`).origin ?? null }]));
    },
    async upsertEmails(items) { write("emails", items); return count(items.map((i) => outcome(s.emails, `${i.sourceKind}:${i.sourceId}`, i))); },
    async currentAssociations(type, ids) { return [...s.assoc.values()].filter((a) => a.fromType === type && ids.includes(a.fromId) && !a.removed); },
    async upsertAssociations(items) { write("associations", items); return count(items.map((i) => outcome(s.assoc, `${i.fromType}:${i.fromId}:${i.toType}:${i.toId}`, i) === "inserted" ? "added" : "readded")); },
    async storedContacts(ids) { return new Set(ids.filter((id) => s.contacts.has(id))); },
    async upsertContacts(items) { write("contacts", items); return count(items.map((i) => outcome(s.contacts, i.sourceId, i))); },
    async threadMarks(ids) {
      const marks = new Map();
      for (const id of ids) {
        if (!s.threads.has(id)) continue;
        const times = [...s.emails.values()].filter((e) => e.sourceKind === "inbox_message" && e.threadId === id).map((e) => Date.parse(e.occurredAt))
          .concat([...s.events.values()].filter((e) => e.threadId === id).map((e) => Date.parse(e.occurredAt)));
        marks.set(id, { lastAt: times.length ? Math.max(...times) : null, messages: [...s.emails.values()].filter((e) => e.threadId === id && e.sourceKind === "inbox_message").length,
          events: 0, isForgotten: Boolean(s.threads.get(id).forgotten) });
      }
      return marks;
    },
    async threadStates(ids) {
      return new Map(ids.filter((id) => s.threads.has(id)).map((id) => {
        const x = s.threads.get(id);
        return [id, { status: x.status, ownerRef: x.ownerRef, inboxId: x.inboxId, channelId: x.channelId, accountId: x.accountId, contactId: x.contactId, ticketId: x.ticketId,
          isSpam: x.isSpam, isArchived: x.isArchived, forgotten: Boolean(x.forgotten) }];
      }));
    },
    async upsertThreads(items) { write("threads", items); return count(items.map((i) => outcome(s.threads, i.sourceId, i))); },
    async upsertThreadEvents(items) { write("events", items); return count(items.map((i) => (s.events.has(i.sourceId) ? "known" : (s.events.set(i.sourceId, i), "inserted")))); },
    async upsertInboxes(items) { write("inboxes", items); s.inboxes = items; return items.length; },
    async upsertInboxChannels(items) { write("channels", items); s.channels = items; return items.length; },
    async upsertInboxAccounts(items) { write("mailboxes", items); s.mailboxes = items; return items.length; },
    async threadForget(id) { s.forgotten.push(id); const x = s.threads.get(id); if (x) { x.forgotten = true; x.contactId = null; } return { threads: x ? 1 : 0, messages: 0 }; },
    async openThreadIds() { return [...s.threads.values()].filter((x) => x.status === "open" && !x.forgotten).map((x) => x.sourceId); },
    async archivedThreadIds() { return [...s.threads.values()].filter((x) => x.isArchived && !x.forgotten).map((x) => x.sourceId); },
  };
}
const connection = { connectionId: "00000000-0000-4000-8000-0000000000e1", adapter: "hubspot", tokenSecretName: "ingest-hubspot-mapping-token" };
const store = memoryStore(CONFIG);
const budget = () => new JobBudget(hubspot.rates);
const reqMark = () => fake.state.requests.length;
const since = (n) => fake.state.requests.slice(n);

let n0 = reqMark();
const p1 = await hubspot.pollEmail({ connection, store, budget: budget(), config: CONFIG, now: NOW });
const firstReqs = since(n0);
const written = JSON.stringify(store.state.writes) + JSON.stringify([...store.state.cursors.entries()]);
expect("poll 1: succeeded without an error", p1.error, null, "rate_limited");
expect("poll 1: five engagements written (the unknown direction skipped)", [...store.state.emails.values()].filter((e) => e.sourceKind === "crm_email").map((e) => e.sourceId).sort(),
  ["4500000001", "4500000002", "4500000003", "4500000004", "4500000006"], ["4500000001"]);
expect("poll 1: four threads, six inbox messages, seven events", [store.state.threads.size, [...store.state.emails.values()].filter((e) => e.sourceKind === "inbox_message").length,
  store.state.events.size], [4, 6, 7], [4, 0, 0]);
expect("poll 1: the email's contact read once, after the emails; the one nothing points to never",
  [[...store.state.contacts.keys()].sort(), store.state.writes.findIndex((w) => w.kind === "contacts") > store.state.writes.findIndex((w) => w.kind === "emails"),
    firstReqs.some((r) => r.path === "/crm/v3/objects/contacts/batch/read" && JSON.stringify(r.body).includes("4300000199"))],
  [["4300000101", "4300000102", "4300000103", "4300000104"], true, false], [["4300000199"], false, true]);
expect("poll 1: contacts asked for the configured properties only", [...new Set(firstReqs.filter((r) => r.path === "/crm/v3/objects/contacts/batch/read").flatMap((r) => r.body.properties))].sort(),
  ["contact_country", "contact_language", "country_dropdown"], ["email", "firstname"]);
expect("poll 1: the contact sent with its slots", store.state.contacts.get("4300000101").countries, [null, "United Kingdom"], null);
expect("poll 1: associations email → contact, deal, ticket", [...store.state.assoc.values()].map((a) => `${a.fromId}>${a.toType}:${a.toId}`).sort(),
  ["4500000001>contact:4300000101", "4500000001>deal:4100000101", "4500000002>contact:4300000102", "4500000002>ticket:4200000101",
    "4500000003>contact:4300000101", "4500000004>contact:4300000101"], []);
expect("poll 1: the search asked for no text, html, header or recipient", firstReqs.filter((r) => r.path.endsWith("/emails/search"))
  .flatMap((r) => r.body.properties).filter((p) => /text|html|header|_to_/.test(p)), [], ["hs_email_text"]);
expect("poll 1: threads listed by latest message with the required filter, tickets included", firstReqs.filter((r) => r.path.endsWith("/conversations/threads") && r.query.sort)
  .every((r) => r.query.sort === "latestMessageTimestamp" && r.query.latestMessageTimestampAfter && r.query.association === "TICKET"), true, false);
expect("poll 1: catalogs written (two inboxes, three channels, two mailboxes) and the owner map read once each way",
  [store.state.inboxes.length, store.state.channels.length, store.state.mailboxes.length, firstReqs.filter((r) => r.path === "/crm/v3/owners").length],
  [2, 3, 2, 2], [3, 3, 0, 0]);
expect("poll 1: the mailboxes by id, inbox and channel; the address-like name never written, the second's name kept",
  store.state.mailboxes.map((m) => `${m.accountId}:${m.name}:${m.inboxId}:${m.channelId}`), ["1600000001:1600000001:1500000001:1002", "1600000002:Sales mailbox:1500000002:1002"], []);
expect("poll 1: messages and threads carry their mailbox", [[...store.state.emails.values()].filter((e) => e.sourceKind === "inbox_message" && e.accountId).length,
  [...store.state.threads.values()].filter((t) => t.accountId).length], [6, 4], [0, 0]);
expect("poll 1: nothing written, kept in a cursor or logged holds a name, address, subject, text or raw actor id",
  forbiddenIn(written + logs.join("\n") + JSON.stringify(p1)), [], ["x"]);
expect("poll 1: the run's counts and outcomes are counts only", Object.values(p1.counts).every((v) => Number.isInteger(v)) && JSON.stringify(p1.detail).match(/"\d{6,}"/) === null, true, false);

const writesBefore = store.state.writes.length;
n0 = reqMark();
const p2 = await hubspot.pollEmail({ connection, store, budget: budget(), config: CONFIG, now: NOW + 60_000 });
expect("poll 2 (nothing changed): no message read again, nothing written", [since(n0).filter((r) => r.path.endsWith("/messages")).length, store.state.writes.length - writesBefore, p2.error],
  [0, 0, null], [4, 3, null]);
expect("poll 2: the catalogs and the owner map not read again within the hour", since(n0).filter((r) => r.path === "/crm/v3/owners" || r.path.endsWith("/inboxes")).length, 0, 2);

// A re-read fills the origin of an engagement stored before the connection named its origin property (addition 0008t):
// held at its version without an origin, it is written again; the others, held as they are, are not
store.state.emails.get("crm_email:4500000004").origin = null;
const writesRe = store.state.writes.length;
await backfillEmails({ connection, store, budget: budget(), fromMs: NOW - 30 * 86_400_000, untilMs: NOW + 60_000, counts: { fetched: 0, skipped: 0 } });
expect("a re-read writes only the engagement held without its origin, and fills it",
  [store.state.writes.slice(writesRe).filter((w) => w.kind === "emails").flatMap((w) => w.items.map((i) => i.sourceId)), store.state.emails.get("crm_email:4500000004").origin],
  [["4500000004"], "AUTOMATION_FIXTURE"], [[], null]);

// A new message on thread 1, a 429 on the engagements' search
const newAt = new Date(NOW + 90_000).toISOString();
source.messages["8800000001"].push({ type: "MESSAGE", id: "m1e0000000000000000000000000005", conversationsThreadId: "8800000001", createdAt: newAt, createdBy: "E-customer.invented@example.net",
  direction: "INCOMING", channelId: "1002", channelAccountId: "1600000001", subject: "Invoice question INVENTED", text: "secret body text", status: { statusType: "RECEIVED" } });
source.threads["8800000001"].latestMessageTimestamp = newAt;
fake.state.failSearch = { status: 429 };
const engCursor = JSON.stringify(store.state.cursors.get("email:engagements"));
n0 = reqMark();
const p3 = await hubspot.pollEmail({ connection, store, budget: budget(), config: CONFIG, now: NOW + 120_000 });
expect("poll 3: a 429 on the search → the run's error rate_limited, the engagements' cursor unchanged",
  [p3.error, JSON.stringify(store.state.cursors.get("email:engagements")) === engCursor], ["rate_limited", true], [null, false]);
expect("poll 3: …and the conversations still ran: only thread 1's messages read, the new message stored",
  [[...new Set(since(n0).filter((r) => r.path.endsWith("/messages")).map((r) => r.path.split("/")[5]))], store.state.emails.has("inbox_message:m1e0000000000000000000000000005")],
  [["8800000001"], true], [[], false]);
expect("poll 3: the warning carries the part and the code only", logs.slice(-5).some((l) => /email poll part stopped/.test(l) && /"code":"rate_limited"/.test(l) && /"part":"engagements"/.test(l)),
  true, false);

// The open check: thread 4 closed at the source without a new message, thread 3 gone
source.threads["8800000004"].status = "CLOSED";
source.threads["8800000004"].closedAt = new Date(NOW + 150_000).toISOString();
fake.state.gone.add("8800000003");
n0 = reqMark();
await hubspot.pollEmail({ connection, store, budget: budget(), config: CONFIG, now: NOW + 11 * 60_000 });
expect("open check: a thread closed without a message is read again and stored closed", store.state.threads.get("8800000004").status, "closed", "open");
expect("open check: a thread gone at the source (404, also archived) is forgotten", [store.state.forgotten, since(n0).filter((r) => r.path.endsWith("/threads/8800000003")).map((r) => r.query.archived ?? "")],
  [["8800000003"], ["", "true"]], [[], []]);

// ---- H. The dev check script (docs/ingest/hubspot-email-check.mjs) against the fake, with a fake gcloud --
const { spawn } = await import("node:child_process");
const { join } = await import("node:path");
const { writeFileSync, chmodSync, mkdtempSync } = await import("node:fs");
const { tmpdir } = await import("node:os");
const binDir = mkdtempSync(join(tmpdir(), "email-check-bin-"));
writeFileSync(join(binDir, "gcloud"), "#!/bin/bash\n[ \"$1 $2 $3\" = \"secrets versions access\" ] && { printf 'fixture-check-token-0001'; exit 0; }\nexit 3\n");
chmodSync(join(binDir, "gcloud"), 0o755);
const CHECK = new URL("../../docs/ingest/hubspot-email-check.mjs", import.meta.url).pathname;
// Asynchronous: the fake HubSpot answers from this process's event loop
const runCheck = (args) => new Promise((resolve) => {
  const child = spawn(process.execPath, [CHECK, ...args], { env: { ...process.env, PATH: `${binDir}:${process.env.PATH}`, INGEST_HUBSPOT_API_BASE: fake.url } });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (c) => { stdout += c; });
  child.stderr.on("data", (c) => { stderr += c; });
  child.on("close", (status) => resolve({ status, stdout, stderr }));
});
const chk = await runCheck(["--project", "p4a-cma-verify", "--token-secret", "ingest-hubspot-verify-token", "--days", "30"]);
const line = (re) => chk.stdout.split("\n").find((l) => re.test(l)) ?? "";
expect("check script: exit 0; the status values and a missing property named", [chk.status, /options: SENT, BOUNCED, FIXTURE_STATUS/.test(line(/^hs_email_status /)),
  /MISSING/.test(line(/^hs_email_from_email /))], [0, true, true], [1, false, false]);
expect("check script: the thread and origin candidates, an option holding an address left out", [/fixture_thread_id/.test(chk.stdout), /fixture_origin.*AUTOMATION_FIXTURE, MANUAL_FIXTURE$/m.test(chk.stdout),
  /fixture_unrelated/.test(chk.stdout)], [true, true, false], [false, false, true]);
expect("check script: actor prefixes with HubSpot's types, counted", ["A AGENT", "E EMAIL", "V VISITOR", "S SYSTEM", "B BOT", "I INTEGRATOR"]
  .map((x) => new RegExp(`^${x.split(" ")[0]}\\s+${x.split(" ")[1]}\\s+\\d+$`, "m").test(chk.stdout)), [true, true, true, true, true, true], [false, false, false, false, false, false]);
expect("check script: no actor id, name, address, subject or the token printed", [forbiddenIn(chk.stdout + chk.stderr), /fixture-check-token/.test(chk.stdout + chk.stderr)],
  [[], false], [["x"], true]);
expect("check script: inboxes and channels by id and name, an inbox named by an address not shown", [/^inbox\s+1500000001\s+"Support inbox \(test\)"$/m.test(chk.stdout),
  /^inbox\s+1500000002\s+\(the name holds an address; not shown\)$/m.test(chk.stdout), /^inbox\s+1500000009 .*archived$/m.test(chk.stdout), /^channel\s+1002\s+"Email"$/m.test(chk.stdout)],
  [true, true, true, true], [false, false, false, false]);
expect("check script: refuses without its arguments (exit 2)", (await runCheck([])).status, 2, 0);

await fake.close();
verdict();
