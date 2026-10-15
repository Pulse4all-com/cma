/**
 * HubSpot conversations (source kind inbox_message; addition 0008m, brief B17b): a connected shared
 * inbox's threads and their messages, polled every minute (no conversation webhooks: their support in
 * a 2026.09 project is unproven), read again by the nightly reconcile, backfilled from
 * cma.email_start_date_of. Scope conversations.read; paths below /conversations/v3/conversations.
 *
 *   catalogs    hourly per connection: inboxes (id, name) and channels (id, name, a canonical kind) into
 *               cma.connection_inbox and _channel; channel accounts (id → inbox id, kept in the cursors,
 *               owners.mjs; their name and delivery identifier, which holds the mailbox's address,
 *               dropped); the owner map (owners.mjs)
 *   threads     GET threads?sort=latestMessageTimestamp&latestMessageTimestampAfter=<cursor>: HubSpot
 *               needs that filter for that sort and then answers ascending (spec
 *               "Conversations Inbox & Messages" v3, the sort parameter). Cursor email:threads
 *               { at, ids }: the newest latestMessageTimestamp written and the threads at it
 *   messages    per changed thread GET threads/{id}/messages, kept only after where the CMA's stored
 *               messages and events stand (cma.ingest_thread_marks): MESSAGE → cma.email_message;
 *               ASSIGNMENT, THREAD_STATUS_CHANGE and THREAD_INBOX_CHANGE → cma.email_thread_event; every
 *               other type (comments, welcome messages) ignored
 *   open check  every ten minutes the source's open threads against the CMA's: a thread closed,
 *               reassigned or moved without a new message is read again, in case such a change does
 *   gone        a held thread the source no longer has (404, also among archived ones) is a
 *               conversation's deletion at the source: cma.ingest_thread_forget
 *
 * Metadata only (R1). A message arrives with its text, rich text, subject, attachments, senders and
 * recipients (names, addresses): messageRows() keeps ids, times, direction, status and kinds, reads
 * the subject and the first sender's domain only while a rule of that kind is active, and drops the
 * message. Actors (R2): only the kind from the actor id's prefix and, for an agent (A-<user id>), the
 * owner id through the owner map; never createdBy, assignedTo or assignedFrom as such.
 */
import { SourceError } from "../../core/http.mjs";
import { warn } from "../../core/log.mjs";
import { hubspotClient, tokenOf } from "./read.mjs";
import { iso } from "./map.mjs";
import { activeRules, ruleNeeds, classify, domainOf } from "./rules.mjs";
import { ownerMap, readMap, writeMap } from "./owners.mjs";
import { emailSettings, tally, writeContacts } from "./email.mjs";

export const THREADS_STREAM = "email:threads";
export const CATALOG_STREAM = "email:catalogs";
export const ACCOUNTS_STREAM = "email:accounts";
export const OPEN_CHECK_STREAM = "email:open-check";
export const CATALOG_EVERY_MS = 60 * 60_000;
export const OPEN_CHECK_EVERY_MS = 10 * 60_000;
const PAGE_CAP = 20;
const MESSAGE_PAGE_CAP = 20;
const REF = /^[^@\s]{1,100}$/;

/**
 * HubSpot's actor id prefixes and the CMA's actor kinds (README, Data model: email activity). The spec
 * types the actors AGENT, BOT, INTEGRATOR, SYSTEM, VISITOR, EMAIL and LLM but does not document the
 * prefixes; these are confirmed in dev (docs/ingest/README.md, section Email). An unknown prefix,
 * the LLM actor's among them until dev shows it, is unknown.
 */
export const ACTOR_PREFIXES = { A: "agent", V: "customer", E: "customer", S: "system", B: "bot", I: "integration" };

// ---- Pure ---------------------------------------------------------------------------------------

const ms = (v) => {
  const t = iso(v);
  return t ? Date.parse(t) : null;
};

/** An actor id → { kind, ownerRef }: the kind from the prefix, and for an agent the owner id of its user id. */
export function actorOf(actorId, owners) {
  const m = /^([A-Z]{1,3})-(.+)$/.exec(String(actorId ?? ""));
  const kind = (m && ACTOR_PREFIXES[m[1]]) || "unknown";
  if (kind !== "agent") return { kind, ownerRef: null };
  const owner = /^\d{1,30}$/.test(m[2]) ? (owners?.get(m[2]) ?? null) : null;
  return { kind, ownerRef: owner && REF.test(owner) ? owner : null };
}

/** A channel's canonical kind from its name (the defaults of a new channel only; configuration from then on). */
export function channelKind(name) {
  const n = String(name ?? "").toLowerCase();
  if (/e-?mail/.test(n)) return "email";
  if (/whats\s?app/.test(n)) return "whatsapp";
  if (/messenger|facebook|instagram/.test(n)) return "messenger";
  if (/chat/.test(n)) return "chat";
  if (/\bsms\b|text message/.test(n)) return "sms";
  if (/form/.test(n)) return "form";
  if (/call|voice|phone/.test(n)) return "phone";
  return "other";
}

/** A catalog name: trimmed, at most 200 characters; one that holds an address gives way to the id. */
export function catalogName(name, id) {
  const s = String(name ?? "").trim();
  return s && !s.includes("@") ? s.slice(0, 200) : String(id);
}

export function inboxItems(inboxes) {
  return (inboxes ?? []).filter((i) => i?.id !== undefined && i.archived !== true && REF.test(String(i.id)))
    .map((i) => ({ inboxId: String(i.id), name: catalogName(i.name, i.id) }));
}

export function channelItems(channels) {
  return (channels ?? []).filter((c) => c?.id !== undefined && REF.test(String(c.id)))
    .map((c) => ({ channelId: String(c.id), name: catalogName(c.name, c.id), kind: channelKind(c.name) }));
}

/** Channel accounts → [[account id, inbox id]]; the name and the delivery identifier are not read. */
export function accountPairs(accounts) {
  return (accounts ?? []).filter((a) => a?.id !== undefined && a?.inboxId !== undefined).map((a) => [String(a.id), String(a.inboxId)]);
}

/** A thread → an ingest_upsert_threads item (readAt: the adapter's version), or null without an id or status. */
export function threadItem(t, { owners, readAt }) {
  const id = String(t?.id ?? "");
  const status = { OPEN: "open", CLOSED: "closed" }[String(t?.status ?? "").toUpperCase()];
  if (!REF.test(id) || !status) return null;
  const ref = (v) => (v !== undefined && v !== null && REF.test(String(v)) ? String(v) : null);
  const assignee = t.assignedTo ? actorOf(t.assignedTo, owners) : null;
  return {
    sourceId: id,
    inboxId: ref(t.inboxId),
    channelId: ref(t.originalChannelId),
    status,
    createdAt: iso(t.createdAt),
    closedAt: status === "closed" ? iso(t.closedAt) : null,
    ownerRef: assignee?.kind === "agent" ? assignee.ownerRef : null,
    contactId: ref(t.associatedContactId),
    ticketId: ref(t.threadAssociations?.associatedTicketId),
    isSpam: t.spam === true,
    isArchived: t.archived === true,
    latestReceivedAt: iso(t.latestMessageReceivedTimestamp),
    latestSentAt: iso(t.latestMessageSentTimestamp),
    updatedAt: readAt,
    raw: { status: String(t.status).toUpperCase(), spam: t.spam === true, archived: t.archived === true },
  };
}

/** Whether the CMA holds the thread exactly as the item says (then it is not written again). */
export function threadSame(stored, item) {
  if (!stored || stored.forgotten) return Boolean(stored?.forgotten);
  return stored.status === item.status && (stored.ownerRef ?? null) === (item.ownerRef ?? null)
    && (stored.inboxId ?? null) === (item.inboxId ?? stored.inboxId ?? null) && (stored.channelId ?? null) === (item.channelId ?? stored.channelId ?? null)
    && (stored.contactId ?? null) === (item.contactId ?? null) && (stored.ticketId ?? null) === (item.ticketId ?? null)
    && stored.isSpam === item.isSpam && stored.isArchived === item.isArchived;
}

const MESSAGE_STATUS = { FAILED: "failed", SENT: "sent", READ: "sent", RECEIVED: "sent" };

/**
 * A thread's messages → { emails, events, ignored, firstCategory }, keeping those after afterMs (the
 * thread's mark; null: all). thread: the thread as listed; accounts: channel account → inbox.
 */
export function messageRows(messages, { thread, owners, accounts, rules, afterMs = null }) {
  const out = { emails: [], events: [], ignored: 0, firstCategory: null };
  const needs = ruleNeeds(rules ?? []);
  const threadId = String(thread.id);
  const inboxOf = (m) => accounts?.get(String(m.channelAccountId ?? "")) ?? (REF.test(String(thread.inboxId ?? "")) ? String(thread.inboxId) : null);
  const sorted = [...(messages ?? [])].sort((a, b) => (ms(a?.createdAt) ?? 0) - (ms(b?.createdAt) ?? 0));
  for (const m of sorted) {
    const at = ms(m?.createdAt);
    const id = String(m?.id ?? "");
    if (at === null || !REF.test(id) || (afterMs !== null && at <= afterMs)) {
      if (at === null || !REF.test(id)) out.ignored += 1;
      continue;
    }
    const actor = actorOf(m.createdBy, owners);
    const occurredAt = new Date(at).toISOString();
    const type = String(m.type ?? "").toUpperCase();
    if (type === "MESSAGE") {
      const direction = { INCOMING: "in", OUTGOING: "out" }[String(m.direction ?? "").toUpperCase()];
      if (!direction) {
        out.ignored += 1;
        continue;
      }
      let category = null;
      if (rules?.length) {
        const sender = needs.senderDomain
          ? (m.senders ?? []).find((s) => String(s?.deliveryIdentifier?.type ?? "") === "HS_EMAIL_ADDRESS")?.deliveryIdentifier?.value
          : null;
        category = classify({ subject: needs.subject && typeof m.subject === "string" ? m.subject : null, senderDomain: domainOf(sender) }, rules);
      }
      out.firstCategory ??= category;
      const statusType = String(m.status?.statusType ?? "").toUpperCase();
      const raw = { type };
      if (/^[A-Z_]{1,40}$/.test(statusType)) raw.statusType = statusType;
      if (/^[A-Z_]{1,40}$/.test(String(m.client?.clientType ?? ""))) raw.clientType = String(m.client.clientType);
      if (/^[A-Z_]{1,40}$/.test(String(m.truncationStatus ?? ""))) raw.truncationStatus = String(m.truncationStatus);
      out.emails.push({
        sourceKind: "inbox_message",
        sourceId: id,
        threadId,
        inboxId: inboxOf(m),
        channelId: REF.test(String(m.channelId ?? "")) ? String(m.channelId) : null,
        direction,
        status: statusType === "FAILED" ? "failed" : direction === "out" ? (MESSAGE_STATUS[statusType] ?? "other") : "other",
        occurredAt,
        actorKind: actor.kind,
        ownerRef: actor.ownerRef,
        category,
        contactId: REF.test(String(thread.associatedContactId ?? "")) ? String(thread.associatedContactId) : null,
        createdAt: occurredAt,
        updatedAt: iso(m.updatedAt) ?? occurredAt,
        raw,
      });
    } else if (type === "ASSIGNMENT") {
      const to = m.assignedTo ? actorOf(m.assignedTo, owners) : null;
      out.events.push({ sourceId: id, threadId, kind: "assigned", occurredAt, actorKind: actor.kind, ownerRef: actor.ownerRef,
        toActorKind: to?.kind ?? null, toOwnerRef: to?.ownerRef ?? null });
    } else if (type === "THREAD_STATUS_CHANGE") {
      const kind = { CLOSED: "closed", OPEN: "reopened" }[String(m.newStatus ?? "").toUpperCase()];
      if (kind) out.events.push({ sourceId: id, threadId, kind, occurredAt, actorKind: actor.kind, ownerRef: actor.ownerRef });
      else out.ignored += 1;
    } else if (type === "THREAD_INBOX_CHANGE") {
      out.events.push({ sourceId: id, threadId, kind: "moved_inbox", occurredAt, actorKind: actor.kind, ownerRef: actor.ownerRef,
        fromInboxId: REF.test(String(m.fromInboxId ?? "")) ? String(m.fromInboxId) : null,
        toInboxId: REF.test(String(m.toInboxId ?? "")) ? String(m.toInboxId) : null });
    } else {
      out.ignored += 1;
    }
  }
  return out;
}

/** The poll's step after a page: the newest latestMessageTimestamp and the ids at it. */
export function advance(cursor, threads) {
  let at = cursor?.at ?? null;
  let ids = [...(cursor?.ids ?? [])];
  for (const t of threads ?? []) {
    const m = ms(t?.latestMessageTimestamp);
    if (m === null) continue;
    if (at === null || m > at) {
      at = m;
      ids = [String(t.id)];
    } else if (m === at && !ids.includes(String(t.id))) {
      ids.push(String(t.id));
    }
  }
  return { at, ids: ids.slice(-50) };
}

/** Threads of a page that the cursor already holds (at its time, by id) are left out. */
export function afterCursor(threads, cursor) {
  if (!cursor || cursor.at === null || cursor.at === undefined) return threads ?? [];
  const ids = new Set(cursor.ids ?? []);
  return (threads ?? []).filter((t) => !(ms(t?.latestMessageTimestamp) === cursor.at && ids.has(String(t.id))));
}

// ---- With HubSpot and the database ----------------------------------------------------------------

const isGone = (err) => err instanceof SourceError && err.code === "http_404";

/** Every page of a listing (at most cap pages). */
async function listAll(api, path, query, cap = PAGE_CAP) {
  const out = [];
  let after;
  for (let i = 0; i < cap; i += 1) {
    const r = await api.conversations(path, { ...query, after });
    out.push(...(r?.results ?? []));
    after = r?.paging?.next?.after;
    if (!after) break;
  }
  return out;
}

/** One thread by id, also when it is archived; null when the source no longer has it. */
async function readThread(api, id) {
  for (const archived of [undefined, true]) {
    try {
      return await api.conversations(`threads/${encodeURIComponent(id)}`, { association: "TICKET", archived });
    } catch (err) {
      if (!isGone(err)) throw err;
    }
  }
  return null;
}

/** A thread's messages, or null when the thread is gone. */
async function readMessages(api, id) {
  try {
    return await listAll(api, `threads/${encodeURIComponent(id)}/messages`, { limit: 100 }, MESSAGE_PAGE_CAP);
  } catch (err) {
    if (isGone(err)) return null;
    throw err;
  }
}

/** Catalogs (hourly): inboxes, channels, channel accounts. Answers the account → inbox map. */
export async function refreshCatalogs(api, store, now) {
  const head = await store.cursor(CATALOG_STREAM);
  if (head?.refreshedAt && now - Date.parse(head.refreshedAt) < CATALOG_EVERY_MS) {
    return (await readMap(store, ACCOUNTS_STREAM, now, Number.POSITIVE_INFINITY)) ?? new Map();
  }
  const inboxes = inboxItems(await listAll(api, "inboxes", { limit: 100 }));
  const channels = channelItems(await listAll(api, "channels", { limit: 100 }));
  const accounts = accountPairs(await listAll(api, "channel-accounts", { limit: 100 }));
  if (inboxes.length > 500 || channels.length > 500) warn("conversations catalog over 500; the rest is not refreshed", { inboxes: inboxes.length, channels: channels.length });
  await store.upsertInboxes(inboxes.slice(0, 500));
  await store.upsertInboxChannels(channels.slice(0, 500));
  const map = await writeMap(store, ACCOUNTS_STREAM, accounts, now);
  await store.setCursor(CATALOG_STREAM, { refreshedAt: new Date(now).toISOString() });
  return map;
}

/**
 * Writes listed threads: per thread its messages after the CMA's mark (when it changed since, or
 * force), the thread when it changed, then messages, events and the contacts they point to. A thread
 * the source no longer has is forgotten.
 */
export async function writeThreads(ctx, threads, { force = false } = {}) {
  const { api, store, config, owners, accounts, counts, detail } = ctx;
  if (!threads.length) return;
  const rules = activeRules(config);
  const readAt = new Date().toISOString();
  const ids = threads.map((t) => String(t?.id ?? "")).filter((id) => REF.test(id));
  const marks = await store.threadMarks(ids);
  const states = await store.threadStates(ids);
  const items = [];
  const emails = [];
  const events = [];
  for (const t of threads) {
    counts.fetched += 1;
    const item = threadItem(t, { owners, readAt });
    if (!item) {
      counts.skipped += 1;
      continue;
    }
    const mark = marks.get(item.sourceId);
    const latest = ms(t.latestMessageTimestamp);
    const changed = force || !mark || mark.lastAt === null || (latest !== null && latest > mark.lastAt);
    if (changed) {
      const messages = await readMessages(api, item.sourceId);
      if (messages === null) {
        if (states.has(item.sourceId)) tally(counts, detail, "forgotten", { forgotten: (await store.threadForget(item.sourceId))?.threads ?? 0 });
        continue;
      }
      const rows = messageRows(messages, { thread: t, owners, accounts, rules, afterMs: mark?.lastAt ?? null });
      if (!mark || mark.messages === 0) item.category = rows.firstCategory;
      emails.push(...rows.emails);
      events.push(...rows.events);
      counts.skipped += rows.ignored;
    }
    if (changed || !threadSame(states.get(item.sourceId), item)) items.push(item);
    else counts.skipped += 1;
  }
  if (items.length) tally(counts, detail, "threads", await store.upsertThreads(items));
  if (emails.length) tally(counts, detail, "messages", await store.upsertEmails(emails));
  if (events.length) tally(counts, detail, "events", await store.upsertThreadEvents(events));
  await writeContacts(api, store, config, items.map((i) => i.contactId), counts, detail);
}

const threadQuery = (fromMs, after) => ({ sort: "latestMessageTimestamp", latestMessageTimestampAfter: new Date(fromMs).toISOString(),
  limit: 100, association: "TICKET", after });

/**
 * Threads by their latest message from the cursor on, page by page; the cursor (and its ids at the
 * boundary) moves after each page written. untilMs: stop past it (the backfill).
 */
async function walkThreads(ctx, cursor, { deadline = Number.POSITIVE_INFINITY, untilMs = null, save }) {
  let cur = cursor;
  let after;
  for (let i = 0; i < 10_000; i += 1) {
    // The paging token belongs to the query it came from: the filter stays the walk's start
    const r = await ctx.api.conversations("threads", threadQuery(cursor.at, after));
    const results = (r?.results ?? []).filter((t) => untilMs === null || (ms(t?.latestMessageTimestamp) ?? 0) <= untilMs);
    await writeThreads(ctx, afterCursor(results, cursor));
    cur = advance(cur, results);
    await save(cur);
    after = r?.paging?.next?.after;
    if (!after || results.length < (r?.results ?? []).length || Date.now() > deadline) return cur;
  }
  return cur;
}

/** The poll's threads: from the cursor (on the first poll the last 26 hours, not before the email start). */
export async function pollThreads(ctx, { now, floorMs, deadline }) {
  const cur = await ctx.store.cursor(THREADS_STREAM);
  const start = Number.isFinite(cur?.at) ? { at: cur.at, ids: cur.ids ?? [] } : { at: Math.max(floorMs ?? 0, now - 26 * 60 * 60_000), ids: [] };
  await walkThreads(ctx, start, { deadline, save: (c) => ctx.store.setCursor(THREADS_STREAM, c) });
}

/**
 * Every ten minutes: the source's open threads against the CMA's. A thread the CMA holds whose status,
 * agent, inbox, channel, contact, ticket, spam or archived state differs, or that the CMA holds open
 * while the source does not list it open, is read again with its messages after the mark.
 */
export async function openCheck(ctx, { now }) {
  const head = await ctx.store.cursor(OPEN_CHECK_STREAM);
  if (head?.refreshedAt && now - Date.parse(head.refreshedAt) < OPEN_CHECK_EVERY_MS) return;
  const open = new Map((await listAll(ctx.api, "threads", { threadStatus: "OPEN", limit: 100, association: "TICKET" }))
    .filter((t) => REF.test(String(t?.id ?? ""))).map((t) => [String(t.id), t]));
  const states = await ctx.store.threadStates([...open.keys()]);
  const readAt = new Date().toISOString();
  const again = [...open.values()].filter((t) => {
    const s = states.get(String(t.id));
    return s && !s.forgotten && !threadSame(s, threadItem(t, { owners: ctx.owners, readAt }) ?? {});
  });
  for (const id of (await ctx.store.openThreadIds()).filter((x) => !open.has(x))) {
    const t = await readThread(ctx.api, id);
    if (t) again.push(t);
    else tally(ctx.counts, ctx.detail, "forgotten", { forgotten: (await ctx.store.threadForget(id))?.threads ?? 0 });
  }
  await writeThreads(ctx, again, { force: true });
  await ctx.store.setCursor(OPEN_CHECK_STREAM, { refreshedAt: new Date(now).toISOString() });
}

/** The context the thread functions share: the API, the configuration, the owner and account maps. */
export async function conversationsContext({ api, store, config, now, counts, detail }) {
  const owners = await ownerMap(api, store, now);
  const accounts = await refreshCatalogs(api, store, now);
  return { api, store, config, owners, accounts, counts, detail };
}

async function jobContext(connection, store, budget, counts) {
  const config = await store.config();
  if (!emailSettings(config).enabled) return null;
  const api = hubspotClient(await tokenOf(connection), budget);
  return conversationsContext({ api, store, config, now: Date.now(), counts, detail: {} });
}

/**
 * The nightly reconcile: threads whose latest message falls in the look-back, as the poll writes them;
 * then the source's trash (archived threads): a held thread found there is marked archived, a held
 * archived thread found neither there nor by id is forgotten, one restored is written as it is.
 */
export async function reconcileThreads({ connection, store, budget, sinceMs, untilMs, counts }) {
  const ctx = await jobContext(connection, store, budget, counts);
  if (!ctx) return;
  await walkThreads(ctx, { at: sinceMs, ids: [] }, { untilMs, save: async () => undefined });
  const trash = new Map((await listAll(ctx.api, "threads", { archived: true, limit: 100, association: "TICKET" }, 50))
    .filter((t) => REF.test(String(t?.id ?? ""))).map((t) => [String(t.id), t]));
  const states = await store.threadStates([...trash.keys()]);
  await writeThreads(ctx, [...trash.values()].filter((t) => states.has(String(t.id))));
  const again = [];
  for (const id of (await store.archivedThreadIds()).filter((x) => !trash.has(x))) {
    const t = await readThread(ctx.api, id);
    if (t) again.push(t);
    else tally(counts, ctx.detail, "forgotten", { forgotten: (await store.threadForget(id))?.threads ?? 0 });
  }
  await writeThreads(ctx, again);
}

/**
 * The backfill: threads whose latest message is from fromMs up to the run's start, with their
 * messages, resumable through backfill:inbox_thread ({ from, at, ids, done }) after every page.
 */
export async function backfillThreads({ connection, store, budget, fromMs, untilMs, counts }) {
  const ctx = await jobContext(connection, store, budget, counts);
  if (!ctx) throw new SourceError("email_poll_not_enabled");
  const stream = "backfill:inbox_thread";
  const cur = await store.cursor(stream);
  if (cur?.from === fromMs && cur.done) return;
  const start = cur?.from === fromMs && Number.isFinite(cur.at) ? { at: cur.at, ids: cur.ids ?? [] } : { at: fromMs, ids: [] };
  const end = await walkThreads(ctx, start, { untilMs, save: (c) => store.setCursor(stream, { from: fromMs, ...c, done: false }) });
  await store.setCursor(stream, { from: fromMs, ...end, done: true });
}
