/**
 * Verifier (pure: no database, no network beyond localhost): the CMA's use of HubSpot's API (backlog
 * CMA-069, 18 October 2026). Invented values only.
 *
 *   node verify/api-budget.mjs             every check must PASS
 *   node verify/api-budget.mjs --provoke   every check must FAIL
 *
 * Part A runs the forms poll and the email poll minute by minute with a mocked HubSpot client (every
 * call counted per endpoint as the real client counts it) and an in-memory store: 28 counted forms and
 * 22 polled-only forms, three inbox threads, one email engagement. It proves that an idle minute makes
 * at most 28 + 5 + 1 forms and threads calls (the counted forms, that minute's share of the polled-only
 * forms, one threads call, no open check), even from a source that hands a next page on every listing;
 * that over five minutes every polled-only form is read exactly once; that the 15th minute adds the open
 * check; that a busy minute still reads every new submission (a counted form's at once, over two pages;
 * a polled-only form's at the latest within the next interval) and every changed thread with its new
 * messages; that the nightly reconcile reads every polled form and writes a submission the poll missed
 * (one HubSpot listed late, older than its form's cursor) as the poll writes it, skips held ones without
 * a search and writes nothing the second time; the probe (forms_poll_probe) both ways; and that settings
 * out of range fall back to their defaults with one log line per run naming them.
 *
 * Part B runs the real client against a local fake that states the daily limit in HubSpot's headers:
 * endpoint templates without ids, the daily reading (or not_received), the floor guard pausing a backfill
 * and a reconcile (finished as succeeded with error daily_floor, resumed from the backfill's cursor and
 * from the paused reconcile's start) and never a poll.
 */
import http from "node:http";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, verdict, PROVOKE } from "./lib.mjs";

console.log(`verify/api-budget.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

process.env.INGEST_PACE_FACTOR = "0";
const secretsDir = mkdtempSync(path.join(tmpdir(), "api-budget-"));
writeFileSync(path.join(secretsDir, "ingest-hubspot-budget-token"), "fixture-budget-token");
process.env.INGEST_SECRETS_DIR = secretsDir;

const logs = [];
const { setLogSink } = await import("../src/core/log.mjs");
setLogSink((line) => logs.push(line));
const { JobBudget } = await import("../src/core/budget.mjs");
const { SourceError } = await import("../src/core/http.mjs");
const { endpointOf, dailyOf, usageSettings, formSlots, dueInRun, openCheckDue, minuteOf } = await import("../src/adapters/hubspot/usage.mjs");
const { pollForms, reconcileForms } = await import("../src/adapters/hubspot/forms.mjs");
const { RECONCILE_OBJECTS } = await import("../src/adapters/hubspot/reconcile.mjs");
const { pollEmail } = await import("../src/adapters/hubspot/email-poll.mjs");
const { hubspotClient, RATES } = await import("../src/adapters/hubspot/read.mjs");
const { hubspot } = await import("../src/adapters/hubspot/index.mjs");
const { withRun } = await import("../src/jobs/runner.mjs");
const { reconcileStream, resumeStream } = await import("../src/jobs/reconcile.mjs");

// A minute boundary ahead of the clock, so the email poll's 40-second deadline lies in the future
const T0 = (Math.floor(Date.now() / 60_000) + 1) * 60_000 + 5_000;
const at = (k) => T0 + k * 60_000;
const iso = (ms) => new Date(ms).toISOString();
const connection = { connectionId: "00000000-0000-4000-8000-0000000000b1", adapter: "hubspot", tokenSecretName: "ingest-hubspot-budget-token" };

// ---- The pure rules --------------------------------------------------------------------------------
expect("endpoint: a form's guid replaced, the query left out", endpointOf("get", "/form-integrations/v1/submissions/forms/3f2a9c1e-0000-4000-8000-000000000001?limit=50&after=abc"),
  "GET /form-integrations/v1/submissions/forms/{id}", "GET /form-integrations/v1/submissions/forms/3f2a9c1e-0000-4000-8000-000000000001");
expect("endpoint: a thread id replaced, versions kept (v3, 2026-09)", [endpointOf("GET", "/conversations/v3/conversations/threads/8800000001/messages"),
  endpointOf("GET", "/crm/objects/2026-09/contacts/batch/read")],
["GET /conversations/v3/conversations/threads/{id}/messages", "GET /crm/objects/2026-09/contacts/batch/read"],
["GET /conversations/{id}/conversations/threads/8800000001/messages", "GET /crm/objects/{id}/contacts/batch/read"]);
const headers = (o) => new Headers(o);
expect("daily limit: HubSpot's two headers read", dailyOf(headers({ "X-HubSpot-RateLimit-Daily": "1000000", "X-HubSpot-RateLimit-Daily-Remaining": "826556" })),
  { limit: 1000000, remaining: 826556 }, null);
expect("daily limit: none without both headers or with no whole numbers", [dailyOf(headers({ "X-HubSpot-RateLimit-Daily": "1000" })),
  dailyOf(headers({ "X-HubSpot-RateLimit-Daily": "1000", "X-HubSpot-RateLimit-Daily-Remaining": "-3" })), dailyOf(headers({}))], [null, null, null],
[{ limit: 1000, remaining: 0 }, null, null]);
const defaults = usageSettings({ settings: {} });
expect("settings: the defaults (5, 15, 25, probe off)", [defaults.formsIntervalMinutes, defaults.openCheckMinutes, defaults.floorPct, defaults.probe, defaults.fallbacks],
  [5, 15, 25, false, []], [1, 10, 0, true, []]);
const odd = usageSettings({ settings: { forms_poll_interval_minutes: 0, email_open_check_minutes: "every hour", api_daily_floor_pct: 95, forms_poll_probe: "maybe" } });
expect("settings: each out of range falls back to its default and is named", [odd.formsIntervalMinutes, odd.openCheckMinutes, odd.floorPct, odd.probe, odd.fallbacks],
  [5, 15, 25, false, ["forms_poll_interval_minutes", "email_open_check_minutes", "api_daily_floor_pct", "forms_poll_probe"]], [0, 15, 95, false, []]);
const edges = usageSettings({ settings: { forms_poll_interval_minutes: "1440", email_open_check_minutes: 1, api_daily_floor_pct: "90", forms_poll_probe: "true" } });
expect("settings: the range's ends taken, digits as text and true as text too", [edges.formsIntervalMinutes, edges.openCheckMinutes, edges.floorPct, edges.probe, edges.fallbacks],
  [1440, 1, 90, true, []], [5, 15, 25, false, ["forms_poll_interval_minutes"]]);
const slots = formSlots(Array.from({ length: 22 }, (_, i) => `f${String(i).padStart(2, "0")}`), 5);
expect("slots: 22 forms over 5 minutes hold 5, 5, 4, 4, 4", [0, 1, 2, 3, 4].map((s) => [...slots.values()].filter((x) => x === s).length), [5, 5, 4, 4, 4], [22, 0, 0, 0, 0]);
expect("cadence: due in its minute, not in the next; a skipped minute's slot read by the next run; a whole interval reads all",
  [dueInRun(2, 5, 6 * 60_000, 7 * 60_000), dueInRun(2, 5, 7 * 60_000, 8 * 60_000), dueInRun(2, 5, 6 * 60_000, 8 * 60_000), dueInRun(4, 5, 0, 5 * 60_000), dueInRun(4, 5, null, 0)],
  [true, false, true, true, true], [false, true, false, false, false]);
expect("open check: due first, then after its interval only", [openCheckDue(15, null, 0), openCheckDue(15, 0, 14 * 60_000 + 59_999), openCheckDue(15, 0, 15 * 60_000)],
  [true, false, true], [false, true, false]);

// ---- A. The polls minute by minute, a mocked client -----------------------------------------------------
const pad = (i) => String(i).padStart(12, "0");
const COUNTED = Array.from({ length: 28 }, (_, i) => `11111111-0000-4000-8000-${pad(i)}`);
const ONLY = Array.from({ length: 22 }, (_, i) => `22222222-0000-4000-8000-${pad(i)}`);
const sub = (formId, n, ms, email = `person${n}@example.invalid`) => ({
  conversionId: `${formId.slice(0, 8)}-${n}`, submittedAt: ms, pageUrl: "https://www.example.com/form",
  values: email ? [{ name: "email", value: email }] : [],
});

function makeWorld(settings) {
  const w = {
    settings,
    catalog: [...COUNTED, ...ONLY].map((id, i) => ({ id, name: `Form ${i}`, fieldGroups: [{ fields: [{ name: "email", fieldType: "email", objectTypeId: "0-1" }] }] })),
    subs: new Map([...COUNTED, ...ONLY].map((id, i) => [id, [sub(id, 1000 + i, T0 - 3 * 3600_000 + i * 1000)]])),
    conversions: [],
    emails: [{ id: "4500000001", updatedAt: iso(T0 - 2 * 3600_000),
      properties: { hs_lastmodifieddate: iso(T0 - 2 * 3600_000), hs_timestamp: iso(T0 - 2 * 3600_000), hs_createdate: iso(T0 - 2 * 3600_000), hs_email_direction: "EMAIL" } }],
    threads: new Map(),
    messages: new Map(),
    log: [],
  };
  for (const [i, minutesAgo] of [[1, 90], [2, 60], [3, 30]]) addThread(w, `880000000${i}`, T0 - minutesAgo * 60_000, 2);
  return w;
}

function addThread(w, id, latestMs, messages) {
  w.threads.set(id, { id, status: "OPEN", inboxId: "1500000001", originalChannelId: "1002", createdAt: iso(latestMs - 60_000), latestMessageTimestamp: iso(latestMs),
    associatedContactId: `43000001${id.slice(-2)}`, spam: false, archived: false });
  w.messages.set(id, []);
  for (let k = messages - 1; k >= 0; k -= 1) addMessage(w, id, latestMs - k * 1000);
}

function addMessage(w, id, ms) {
  const list = w.messages.get(id);
  list.push({ type: "MESSAGE", id: `m${id}${String(list.length).padStart(3, "0")}`, createdAt: iso(ms), createdBy: "V-1000000001", direction: "INCOMING",
    channelId: "1002", channelAccountId: "1600000001", status: { statusType: "RECEIVED" } });
  w.threads.get(id).latestMessageTimestamp = iso(Math.max(ms, Date.parse(w.threads.get(id).latestMessageTimestamp)));
}

/** The mocked client: each method as the real one calls HubSpot, every call guarded and counted by the budget as the real client does */
function mockClient(w, budget) {
  const hit = (method, p, what = null) => {
    budget.guard?.();
    budget.count?.(endpointOf(method, p));
    w.log.push({ endpoint: endpointOf(method, p), what });
  };
  const page = (list, after, size, always = false) => {
    const o = Number(after ?? 0);
    const more = o + size < list.length || always;
    return { results: list.slice(o, o + size), ...(more ? { paging: { next: { after: String(o + size) } } } : {}) };
  };
  return {
    async forms(after) { hit("GET", "/marketing/v3/forms"); return page(w.catalog, after, 100); },
    async form(id) { hit("GET", `/marketing/v3/forms/${id}`); return w.catalog.find((f) => f.id === id); },
    async submissions(formId, after) { hit("GET", `/form-integrations/v1/submissions/forms/${formId}`, formId); return page(w.subs.get(formId) ?? [], after, 50); },
    async contactIdsWhere() { hit("POST", "/crm/v3/objects/contacts/search", "contact"); return ["4300000001"]; },
    async search(type, body) {
      const from = Number(body.filterGroups[0].filters[0].value);
      if (type === "contact") {
        hit("POST", "/crm/v3/objects/contacts/search", "probe");
        const found = w.conversions.filter((ms) => ms >= from);
        return { total: found.length, results: found.slice(0, 1).map(() => ({ id: "4300000009" })) };
      }
      hit("POST", "/crm/v3/objects/emails/search", "engagements");
      const list = w.emails.filter((e) => Date.parse(e.properties.hs_lastmodifieddate) >= from).sort((a, b) => a.properties.hs_lastmodifieddate.localeCompare(b.properties.hs_lastmodifieddate));
      return page(list, body.after, 100);
    },
    async batchRead(_type, ids) { hit("POST", "/crm/v3/objects/contacts/batch/read"); return ids.map((id) => ({ id, properties: {} })); },
    async associations(from, to, ids) { hit("POST", `/crm/v4/associations/${from}/${to}/batch/read`); return new Map(ids.map((id) => [id, []])); },
    async owners() { hit("GET", "/crm/v3/owners"); return { results: [{ id: "5100000001", userId: "9100000001" }] }; },
    async conversations(p, query = {}) {
      if (p === "inboxes") { hit("GET", `/conversations/v3/conversations/${p}`); return { results: [{ id: "1500000001", name: "Support (test)" }] }; }
      if (p === "channels") { hit("GET", `/conversations/v3/conversations/${p}`); return { results: [{ id: "1002", name: "Email" }] }; }
      if (p === "channel-accounts") { hit("GET", `/conversations/v3/conversations/${p}`); return { results: [{ id: "1600000001", inboxId: "1500000001" }] }; }
      if (p === "threads" && query.sort) {
        hit("GET", "/conversations/v3/conversations/threads", "walk");
        const from = Date.parse(query.latestMessageTimestampAfter);
        const list = [...w.threads.values()].filter((t) => Date.parse(t.latestMessageTimestamp) >= from)
          .sort((a, b) => a.latestMessageTimestamp.localeCompare(b.latestMessageTimestamp) || a.id.localeCompare(b.id));
        // a source that hands a next page on every listing: the walk must stop on its own
        return page(list, query.after, Number(query.limit ?? 100), true);
      }
      if (p === "threads" && query.threadStatus) {
        hit("GET", "/conversations/v3/conversations/threads", "open");
        return page([...w.threads.values()].filter((t) => t.status === query.threadStatus), query.after, 100);
      }
      const m = /^threads\/(\d+)(\/messages)?$/.exec(p);
      if (m && m[2]) { hit("GET", `/conversations/v3/conversations/${p}`, "messages"); return page(w.messages.get(m[1]) ?? [], query.after, 100); }
      if (m) { hit("GET", `/conversations/v3/conversations/${p}`, "thread"); return w.threads.get(m[1]); }
      throw new SourceError("http_404", 404);
    },
  };
}

function memoryStore(w) {
  const s = { cursors: new Map(), subs: new Map(), emails: new Map(), threads: new Map(), events: new Map(), contacts: new Map(), assoc: new Map(), runs: [] };
  const count = (list) => list.reduce((o, k) => ({ ...o, [k]: (o[k] ?? 0) + 1 }), {});
  const put = (map, key, item) => {
    const had = map.has(key);
    map.set(key, item);
    return had ? "updated" : "inserted";
  };
  return {
    state: s,
    async config() { return { settings: w.settings, fields: [], emailRules: [] }; },
    async settings() { return { "intake.start_date": "2026-10-01" }; },
    async tenantStartOf() { return new Date(T0 - 10 * 86_400_000); },
    async emailStartOf() { return "2026-10-01"; },
    async cursor(stream) { return s.cursors.get(stream) ?? null; },
    async setCursor(stream, value) { s.cursors.set(stream, JSON.parse(JSON.stringify(value))); },
    async runStart(job, stream, from, to) { s.runs.push({ job, stream, from, to, status: "running" }); return s.runs.length - 1; },
    async runFinish(id, status, counts, error) { Object.assign(s.runs[id], { status, counts: { ...counts }, error }); },
    async forms() {
      return [...COUNTED.map((id) => [id, true]), ...ONLY.map((id) => [id, false])]
        .map(([formId, isCounted]) => ({ formId, name: formId, isCounted, isPolled: true, keptFields: [], status: "active", described: true, fields: [] }));
    },
    async upsertForms(items) { return items.length; },
    async upsertSubmissions(items) { return count(items.map((i) => (s.subs.has(i.sourceId) ? "known" : (s.subs.set(i.sourceId, i), "inserted")))); },
    async storedSubmissions(ids) { return new Set(ids.filter((id) => s.subs.has(id))); },
    async emailVersions(kind, ids) { return new Map(ids.filter((id) => s.emails.has(`${kind}:${id}`)).map((id) => [id, Date.parse(s.emails.get(`${kind}:${id}`).updatedAt)])); },
    async upsertEmails(items) { return count(items.map((i) => put(s.emails, `${i.sourceKind}:${i.sourceId}`, i))); },
    async currentAssociations() { return []; },
    async upsertAssociations(items) { return count(items.map(() => "added")); },
    async storedContacts(ids) { return new Set(ids.filter((id) => s.contacts.has(id))); },
    async upsertContacts(items) { return count(items.map((i) => put(s.contacts, i.sourceId, i))); },
    async threadMarks(ids) {
      const marks = new Map();
      for (const id of ids.filter((x) => s.threads.has(x))) {
        const times = [...s.emails.values()].filter((e) => e.threadId === id).map((e) => Date.parse(e.occurredAt));
        marks.set(id, { lastAt: times.length ? Math.max(...times) : null, messages: times.length, events: 0, isForgotten: false });
      }
      return marks;
    },
    async threadStates(ids) {
      return new Map(ids.filter((id) => s.threads.has(id)).map((id) => {
        const x = s.threads.get(id);
        return [id, { status: x.status, ownerRef: x.ownerRef, inboxId: x.inboxId, channelId: x.channelId, contactId: x.contactId, ticketId: x.ticketId,
          isSpam: x.isSpam, isArchived: x.isArchived, forgotten: false }];
      }));
    },
    async upsertThreads(items) { return count(items.map((i) => put(s.threads, i.sourceId, i))); },
    async upsertThreadEvents(items) { return count(items.map((i) => put(s.events, i.sourceId, i))); },
    async upsertInboxes(items) { return items.length; },
    async upsertInboxChannels(items) { return items.length; },
    async threadForget() { return { threads: 0, messages: 0 }; },
    async openThreadIds() { return [...s.threads.values()].filter((x) => x.status === "open").map((x) => x.sourceId); },
    async archivedThreadIds() { return []; },
  };
}

/** One minute: the forms poll, then the email poll, each with its own budget as its job has. Answers what each called. */
async function minute(w, store, k) {
  const out = {};
  for (const job of ["forms", "email"]) {
    const budget = new JobBudget(RATES);
    const api = mockClient(w, budget);
    const before = w.log.length;
    const r = job === "forms"
      ? await pollForms({ connection, store, budget, now: at(k), api })
      : await pollEmail({ connection, store, budget, config: await store.config(), now: at(k), api });
    const calls = w.log.slice(before);
    out[job] = { r, calls, usage: budget.usage() };
  }
  const reads = out.forms.calls.filter((c) => c.endpoint.startsWith("GET /form-integrations/"));
  return {
    ...out,
    readCalls: reads.length,
    formsRead: new Set(reads.map((c) => c.what)).size,
    counted: reads.filter((c) => COUNTED.includes(c.what)).length,
    only: reads.filter((c) => ONLY.includes(c.what)).map((c) => c.what),
    walks: out.email.calls.filter((c) => c.what === "walk").length,
    openChecks: out.email.calls.filter((c) => c.what === "open").length,
    engagements: out.email.calls.filter((c) => c.what === "engagements").length,
    probes: out.forms.calls.filter((c) => c.what === "probe").length,
    total: (out.forms.usage.apiCalls ?? 0) + (out.email.usage.apiCalls ?? 0),
  };
}

const w1 = makeWorld({ email_poll: true });
const s1 = memoryStore(w1);
const m0 = await minute(w1, s1, 0);
expect("minute 0 (first run): every form read once, the catalogs, the threads and their messages stored",
  [m0.counted, m0.only.length, s1.state.subs.size, s1.state.threads.size, [...s1.state.emails.keys()].filter((k) => k.startsWith("inbox_message")).length, m0.openChecks],
  [28, 22, 50, 3, 6, 1], [28, 0, 28, 0, 0, 0]);

const idle = [];
for (let k = 1; k <= 15; k += 1) idle.push(await minute(w1, s1, k));
const quiet = idle.slice(0, 14);
expect("an idle minute: at most 28 + 5 + 1 forms and threads calls (minutes 1 to 14)", Math.max(...quiet.map((m) => m.counted + m.only.length + m.walks + m.openChecks)) <= 28 + 5 + 1,
  true, false);
expect("…every counted form each minute, at most 5 polled-only forms, one threads call, no open check",
  [quiet.every((m) => m.counted === 28), Math.max(...quiet.map((m) => m.only.length)), quiet.every((m) => m.walks === 1), quiet.every((m) => m.openChecks === 0)],
  [true, 5, true, true], [true, 22, false, false]);
expect("…one call per form read: a form whose newest submission is its cursor stops after one call",
  quiet.every((m) => m.readCalls === m.formsRead && m.formsRead === m.counted + m.only.length), true, false);
expect("…the email poll adds one engagements search and nothing else; nothing is written",
  [quiet.every((m) => m.engagements === 1 && m.email.calls.length === 2), quiet.reduce((n, m) => n + m.forms.r.counts.upserted + m.email.r.counts.upserted, 0)], [true, 0], [false, 1]);
const firstFive = new Map(ONLY.map((id) => [id, 0]));
for (const m of idle.slice(0, 5)) for (const id of m.only) firstFive.set(id, firstFive.get(id) + 1);
expect("over minutes 1 to 5 every polled-only form is read exactly once", [...new Set(firstFive.values())], [1], [5]);
expect("…and minutes 6 to 10 read each once again", (() => {
  const c = new Map();
  for (const m of idle.slice(5, 10)) for (const id of m.only) c.set(id, (c.get(id) ?? 0) + 1);
  return [c.size, [...new Set(c.values())]];
})(), [22, [1]], [22, [2]]);
expect("the 15th minute adds the open check (minutes 1 to 14 none)", [idle.map((m) => m.openChecks).findIndex((n) => n > 0) + 1, idle[14].openChecks], [15, 1], [10, 0]);
expect("an idle minute in all, the engagements' search included: 34 or 35 calls (about 34.4 on average)",
  [Math.min(...quiet.map((m) => m.total)), Math.max(...quiet.map((m) => m.total))], [34, 35], [79, 80]);
expect("the run's usage: per endpoint, ids replaced, and no reading from a source that sends none", [Object.keys(idle[0].forms.usage.api), idle[0].forms.usage.daily],
  [["GET /form-integrations/v1/submissions/forms/{id}"], "not_received"], [["GET /form-integrations/v1/submissions/forms/11111111-0000-4000-8000-000000000000"], null]);

// A busy minute: new submissions on counted forms (one over two pages), on a polled-only form in this minute's slot and on one whose slot is four minutes on; two changed threads, one new
const k16 = minuteOf(at(16));
const onlySlots = formSlots(ONLY, 5);
const inSlot = ONLY.find((id) => onlySlots.get(id) === k16 % 5);
const lastSlot = ONLY.find((id) => onlySlots.get(id) === (k16 + 4) % 5);
const added = [];
const addSub = (formId, n, ms) => {
  const x = sub(formId, n, ms);
  w1.subs.get(formId).unshift(x);
  added.push(x.conversionId);
  return x.conversionId;
};
addSub(COUNTED[0], 1, at(16) - 30_000);
addSub(COUNTED[0], 2, at(16) - 20_000);
for (let i = 0; i < 60; i += 1) addSub(COUNTED[7], 100 + i, at(16) - 59_000 + i * 100);
const inSlotId = addSub(inSlot, 3, at(16) - 10_000);
const lastSlotId = addSub(lastSlot, 4, at(16) - 10_000);
addMessage(w1, "88000000" + "01", at(16) - 15_000);
addMessage(w1, "88000000" + "02", at(16) - 12_000);
addThread(w1, "8800000004", at(16) - 5_000, 2);
const m16 = await minute(w1, s1, 16);
const has = (id) => s1.state.subs.has(id);
expect("busy minute: every new submission of a counted form stored at once (one form over two pages)",
  [added.filter((id) => !id.startsWith("22222222")).every(has), m16.forms.calls.filter((c) => c.what === COUNTED[7]).length], [true, 2], [false, 1]);
expect("…the polled-only form in this minute's slot read now, the other not yet", [has(inSlotId), has(lastSlotId)], [true, false], [false, true]);
const after16 = [];
for (let k = 17; k <= 20; k += 1) after16.push(await minute(w1, s1, k));
expect("…the other at the latest in the next interval (its slot, minute 20), read once", [has(lastSlotId), after16.map((m) => m.only.includes(lastSlot))],
  [true, [false, false, false, true]], [false, [true, true, true, true]]);
const msgs = (id) => [...s1.state.emails.values()].filter((e) => e.threadId === id).length;
expect("…every changed thread with its new messages, the new thread with both", [msgs("8800000001"), msgs("8800000002"), msgs("8800000003"), msgs("8800000004")],
  [3, 3, 2, 2], [2, 2, 2, 0]);
expect("…the walk stops at the page with nothing after the cursor, though the source hands another", m16.walks, 2, 1);

// The nightly reconcile reads forms too: a submission HubSpot listed late (older than its form's cursor) is one the poll never reads
const late = sub(COUNTED[3], 5, T0 - 4 * 3600_000);
const lateList = w1.subs.get(COUNTED[3]);
const latePos = lateList.findIndex((x) => x.submittedAt < late.submittedAt);
lateList.splice(latePos < 0 ? lateList.length : latePos, 0, late); // in time order, as HubSpot lists it
const lateId = late.conversionId;
const pollMissed = await minute(w1, s1, 21);
const storedByPoll = s1.state.subs.has(lateId);
const afterRun = addSub(COUNTED[4], 6, at(21) + 30_000);
const recCounts = { fetched: 0, upserted: 0, stale: 0, skipped: 0, failed: 0 };
const recBudget = new JobBudget(RATES);
const recApi = mockClient(w1, recBudget);
const recMark = w1.log.length;
const rec1 = await reconcileForms({ connection, store: s1, budget: recBudget, sinceMs: at(21) - 26 * 3600_000, untilMs: at(21), counts: recCounts, api: recApi });
const recCalls = w1.log.slice(recMark);
expect("reconcile: forms are one of its streams", RECONCILE_OBJECTS.includes("form_submission"), true, false);
expect("…the poll never reads a submission older than its form's cursor", [pollMissed.counted, storedByPoll], [28, false], [28, true]);
expect("reconcile: the submission the poll missed is written, as the poll writes it (its contact searched)",
  [rec1, recCounts.upserted, s1.state.subs.get(lateId)?.contactId, recCalls.filter((c) => c.what === "contact").length], [undefined, 1, "4300000001", 1], [{ error: "x" }, 0, null, 0]);
expect("…every held submission of the window counted, skipped without a search; one newer than the run left to the poll",
  [recCounts.fetched === s1.state.subs.size, recCounts.skipped === recCounts.fetched - 1, s1.state.subs.has(afterRun)], [true, true, false], [false, false, true]);
expect("…every polled form read, the one with 61 submissions over two pages", [new Set(recCalls.filter((c) => c.what && c.what.includes("-0000-4000-")).map((c) => c.what)).size,
  recCalls.filter((c) => c.what === COUNTED[7]).length], [50, 2], [28, 1]);
const recCounts2 = { fetched: 0, upserted: 0, stale: 0, skipped: 0, failed: 0 };
await reconcileForms({ connection, store: s1, budget: new JobBudget(RATES), sinceMs: at(21) - 26 * 3600_000, untilMs: at(21), counts: recCounts2, api: mockClient(w1, new JobBudget(RATES)) });
expect("…a second reconcile writes nothing: 0 shows the cadence lost nothing", [recCounts2.upserted, recCounts2.skipped === recCounts2.fetched], [0, true], [1, false]);

// The probe (forms_poll_probe true): no conversion → the counted forms wait for their slots; a conversion → all of them
const w2 = makeWorld({ email_poll: true, forms_poll_probe: true });
const s2 = memoryStore(w2);
const p0 = await minute(w2, s2, 0);
const p1 = await minute(w2, s2, 1);
expect("probe: the first run reads every counted form (no cursor yet), the next one searches once and reads a slot's share",
  [p0.counted, p1.probes, p1.counted <= 6, p1.counted > 0], [28, 1, true, true], [0, 0, false, false]);
w2.conversions.push(at(2) - 20_000);
const conv = addSubTo(w2, COUNTED.find((id) => formSlots(COUNTED, 5).get(id) !== minuteOf(at(2)) % 5), 7, at(2) - 20_000);
const p2 = await minute(w2, s2, 2);
expect("probe: a conversion found → every counted form read, the new submission stored", [p2.counted, s2.state.subs.has(conv)], [28, true], [6, false]);
for (let k = 3; k <= 5; k += 1) await minute(w2, s2, k);
// A submission without an email address gives no contact a conversion: the probe never finds it, its form's slot does
const k6 = minuteOf(at(6));
const quietForm = COUNTED.find((id) => formSlots(COUNTED, 5).get(id) === (k6 + 2) % 5);
const noEmail = addSubTo(w2, quietForm, 8, at(6) - 30_000, null);
const later = [];
for (let k = 6; k <= 10; k += 1) {
  const m = await minute(w2, s2, k);
  later.push({ probes: m.probes, stored: s2.state.subs.has(noEmail) ? 1 : 0 });
}
expect("probe: a submission without an email address waits for its form's slot (two minutes on), within one interval",
  [later.map((m) => m.probes), later.map((m) => m.stored)], [[1, 1, 1, 1, 1], [0, 0, 1, 1, 1]], [[0, 0, 0, 0, 0], [1, 1, 1, 1, 1]]);
expect("probe: off by default", usageSettings({ settings: {} }).probe, false, true);

function addSubTo(w, formId, n, ms, email) {
  const x = sub(formId, n, ms, email === undefined ? `person${n}@example.invalid` : email);
  w.subs.get(formId).unshift(x);
  return x.conversionId;
}

// Settings out of range: the defaults, one log line per run naming them
const w3 = makeWorld({ email_poll: true, forms_poll_interval_minutes: 0, forms_poll_probe: "maybe", email_open_check_minutes: 99999 });
const s3 = memoryStore(w3);
await minute(w3, s3, 0);
const logMark = logs.length;
const q1 = await minute(w3, s3, 1);
const lines = logs.slice(logMark).map((l) => JSON.parse(l)).filter((l) => l.message === "settings out of range, defaults used");
expect("settings out of range: one line per run naming them, the defaults in force (5 minutes, probe off)",
  [lines.map((l) => [l.job, l.settings]), q1.only.length <= 5, q1.probes],
  [[["forms_poll", ["forms_poll_interval_minutes", "forms_poll_probe"]], ["email_poll", ["email_open_check_minutes"]]], true, 0],
  [[], false, 1]);
expect("nothing logged holds a form id, a thread id or an email address", logs.some((l) => /11111111-|22222222-|880000000\d|@example\.invalid/.test(l)), false, true);

// ---- B. The real client against a local fake that states the daily limit --------------------------------
const fake = { limit: 1000, remaining: 900, send: true, requests: [], dealPages: 3, onDealPage: null };
const server = http.createServer((req, res) => {
  let body = "";
  req.on("data", (c) => { body += c; });
  req.on("end", () => {
    const url = new URL(req.url, "http://localhost");
    const parsed = body ? JSON.parse(body) : null;
    fake.requests.push({ method: req.method, path: url.pathname, body: parsed });
    let out = { results: [] };
    if (url.pathname === "/crm/v3/objects/deals/search") {
      const from = Number(parsed.filterGroups[0].filters[0].value);
      const offset = Number(parsed.after ?? 0);
      const all = Array.from({ length: fake.dealPages * 100 }, (_, i) => from + (i + 1) * 1000);
      out = { results: all.slice(offset, offset + 100).map((t, i) => ({ id: String(4100000000 + offset + i),
        properties: { createdate: String(t), closedate: String(t), hs_lastmodifieddate: iso(t) } })),
      ...(offset + 100 < all.length ? { paging: { next: { after: String(offset + 100) } } } : {}) };
      // a hook lowers the remaining calls as of this page: the response states it
      fake.onDealPage?.();
    }
    const h = { "content-type": "application/json" };
    if (fake.send) Object.assign(h, { "X-HubSpot-RateLimit-Daily": String(fake.limit), "X-HubSpot-RateLimit-Daily-Remaining": String(fake.remaining) });
    res.writeHead(200, h).end(JSON.stringify(out));
  });
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
process.env.INGEST_HUBSPOT_API_BASE = `http://127.0.0.1:${server.address().port}`;
const floorBudget = () => new JobBudget(RATES, undefined, { floorPct: 25 });

const b1 = new JobBudget(RATES);
const c1 = hubspotClient("fixture-budget-token", b1);
await c1.submissions("3f2a9c1e-0000-4000-8000-000000000001");
await c1.conversations("threads/8800000001/messages", { limit: 100 });
await c1.search("deal", { filterGroups: [{ filters: [{ propertyName: "createdate", operator: "GTE", value: "0" }] }], limit: 100 });
const u1 = b1.usage();
expect("real client: every request counted per endpoint, no id in a key", [u1.apiCalls, Object.keys(u1.api), /8800000001|3f2a9c1e/.test(JSON.stringify(u1))],
  [3, ["GET /conversations/v3/conversations/threads/{id}/messages", "GET /form-integrations/v1/submissions/forms/{id}", "POST /crm/v3/objects/deals/search"], false],
  [2, [], true]);
expect("real client: the daily limit taken from the response", u1.daily, { limit: 1000, remaining: 900 }, "not_received");
fake.send = false;
const b2 = new JobBudget(RATES, undefined, { floorPct: 25 });
const c2 = hubspotClient("fixture-budget-token", b2);
for (let i = 0; i < 3; i += 1) await c2.submissions("3f2a9c1e-0000-4000-8000-000000000001");
expect("without the headers: daily not_received, and the floor never pauses", [b2.usage().daily, b2.usage().apiCalls], ["not_received", 3], [{ limit: 1000, remaining: 900 }, 1]);
fake.send = true;

const tries = async (client, n) => {
  let made = 0;
  try {
    for (let i = 0; i < n; i += 1) {
      await client.submissions("3f2a9c1e-0000-4000-8000-000000000001");
      made += 1;
    }
    return [made, null];
  } catch (err) {
    return [made, err instanceof SourceError ? err.code : "other"];
  }
};
fake.remaining = 240;
const n0 = fake.requests.length;
const bf = floorBudget();
expect("below the floor (240 of 1,000 left, floor 25%): one request reads the limit, the next pauses before it is sent",
  [await tries(hubspotClient("fixture-budget-token", bf), 5), fake.requests.length - n0], [[1, "daily_floor"], 1], [[5, null], 5]);
fake.remaining = 10;
expect("…a poll's budget (no floor) never pauses, even with 10 left", await tries(hubspotClient("fixture-budget-token", new JobBudget(RATES)), 5), [5, null], [1, "daily_floor"]);
fake.remaining = 250;
expect("…at the floor exactly it goes on", await tries(hubspotClient("fixture-budget-token", floorBudget()), 3), [3, null], [1, "daily_floor"]);

// The forms poll with the real client, its job's budget and 10 calls left: not paused
const sp = memoryStore(makeWorld({}));
fake.remaining = 10;
const n3 = fake.requests.length;
const pollRun = await withRun(sp, { job: "forms_poll", stream: "forms" }, async (counts) => {
  const p = await pollForms({ connection, store: sp, budget: new JobBudget(RATES), now: at(30) });
  for (const k of Object.keys(counts)) counts[k] += p.counts[k] ?? 0;
  return { error: p.error };
});
expect("the forms poll never pauses: every form read with 10 calls left", [pollRun.ok, pollRun.paused, fake.requests.slice(n3).filter((r) => r.path.startsWith("/form-integrations")).length],
  [true, false, 50], [false, true, 1]);
const jobSource = ["poll-forms.mjs", "poll-email.mjs", "sweep.mjs"].map((f) => readFileSync(new URL(`../src/jobs/${f}`, import.meta.url), "utf8")).join("\n");
expect("the poll jobs and the sweep give their budgets no floor", /floorPct|dailyFloor/.test(jobSource), false, true);

// A backfill paused below the floor and resumed from its cursor
const sb = memoryStore(makeWorld({}));
const processed = [];
const stub = async (type, items) => processed.push(items.length);
fake.remaining = 900;
fake.onDealPage = () => { fake.remaining = 200; };
const fromMs = Date.parse("2026-10-01T00:00:00Z");
const untilMs = Date.now();
const bb1 = floorBudget();
const run1 = await withRun(sb, { job: "backfill", stream: "deal" }, (counts) => hubspot.backfill({ connection, store: sb, budget: bb1, object: "deal", fromMs, untilMs, process: stub, counts }));
const cur1 = sb.state.cursors.get("backfill:deal:createdate");
expect("backfill below the floor: paused after its first page, finished as succeeded with error daily_floor",
  [run1.ok, run1.paused, sb.state.runs.at(-1).status, sb.state.runs.at(-1).error, processed.length], [true, true, "succeeded", "daily_floor", 1], [false, false, "failed", null, 3]);
expect("…its cursor holds where it stood", [cur1?.done, cur1?.value], [false, fromMs + 100 * 1000], [true, null]);
fake.onDealPage = null;
fake.remaining = 900;
const n1 = fake.requests.length;
const run2 = await withRun(sb, { job: "backfill", stream: "deal" }, (counts) => hubspot.backfill({ connection, store: sb, budget: floorBudget(), object: "deal", fromMs, untilMs, process: stub, counts }));
const first2 = fake.requests.slice(n1).find((r) => r.path === "/crm/v3/objects/deals/search");
expect("…the next run resumes from the cursor and finishes", [run2.ok, run2.paused, Number(first2?.body.filterGroups[0].filters[0].value), sb.state.cursors.get("backfill:deal:createdate")?.done],
  [true, false, fromMs + 100 * 1000, true], [false, true, fromMs, false]);

// A reconcile stream paused below the floor and resumed from the paused run's start
const sr = memoryStore(makeWorld({}));
const lookback1 = Date.now() - 26 * 3600_000;
fake.remaining = 900;
fake.onDealPage = () => { fake.remaining = 200; };
const rr1 = await reconcileStream({ adapter: hubspot, connection, store: sr, budget: floorBudget(), object: "deal", lookbackFrom: lookback1, untilMs: Date.now(),
  process: () => stub });
expect("reconcile below the floor: the stream paused, finished as succeeded with error daily_floor, its resume cursor at the run's start",
  [rr1.r.paused, sr.state.runs.at(-1).status, sr.state.runs.at(-1).error, sr.state.cursors.get(resumeStream("deal"))?.from], [true, "succeeded", "daily_floor", lookback1],
  [false, "failed", null, null]);
expect("…its log carries the stream's requests and the reading", [rr1.usage.apiCalls, rr1.usage.daily], [1, { limit: 1000, remaining: 200 }], [0, "not_received"]);
fake.onDealPage = null;
fake.remaining = 900;
const n2 = fake.requests.length;
const lookback2 = lookback1 + 24 * 3600_000;
const rr2 = await reconcileStream({ adapter: hubspot, connection, store: sr, budget: floorBudget(), object: "deal", lookbackFrom: lookback2, untilMs: Date.now(),
  process: () => stub });
const first3 = fake.requests.slice(n2).find((r) => r.path === "/crm/v3/objects/deals/search");
expect("…the next night starts at the paused run's start, finishes and clears the cursor",
  [rr2.r.ok, rr2.r.paused, Number(first3?.body.filterGroups[0].filters[0].value), sr.state.cursors.get(resumeStream("deal"))?.from], [true, false, lookback1, null],
  [false, true, lookback2, lookback1]);
const rr3 = await reconcileStream({ adapter: hubspot, connection, store: sr, budget: new JobBudget(RATES), object: "deal", lookbackFrom: lookback2, untilMs: Date.now(),
  process: () => stub });
expect("…a budget without a floor neither reads nor writes the resume cursor", [rr3.r.ok, sr.state.runs.at(-1).from.getTime()], [true, lookback2], [false, lookback1]);

server.close();
verdict();
