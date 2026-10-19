/**
 * Email reports (addition 0008t; brief N19-A part 1, 18 October 2026): Reports → Email and Email per agent.
 * The figures come from the database (cma.email_report, cma.email_per_person, cma.email_waiting,
 * cma.email_not_responding); this module mirrors their definitions for the mock and for
 * verify/reports.mjs, and arranges the rows for the screen. Pure, with no runtime imports beyond time.ts
 * and reports.ts, so the verifier runs it under Node's type stripping.
 *
 * The definitions (README, Data model: email reports), one place in the database (cma.email_of,
 * cma.email_openings_of, cma.email_closes_of):
 *   counted     not deleted; an inbox message on a counted inbox, mailbox and channel (one the catalog has
 *               not brought yet counts) of a conversation that is not spam; an engagement whose origin is
 *               none of the connection's inbox-copy origins
 *   received    an inbox message in or forwarded; an engagement in or forwarded is a logged reply, a column
 *               of its own, never added to received
 *   sent        out and sent: automated for an engagement of an automated origin, or an inbox message of a
 *               bot, an AI, the system or an integration; an agent send otherwise. Bounced and failed apart
 *   opening     a conversation's creation, or a reopen whose latest status event before it is a close
 *   first reply per opening: the first incoming message after the close it follows, up to its own close,
 *               then the first agent message out after it that did not fail; business seconds in the
 *               conversation's market, none for an unknown market ("No business hours")
 * Ids, codes, counts and times only: no subject, body, address, name or phone number exists here.
 */
import type {
  DateKey, EmailFigures, EmailFilter, EmailGroup, EmailPerson, EmailRow, EmailSeriesRow, EmailWaitingRow, Instant,
} from "./data/types";
// With their extensions, so verify/reports.mjs can run this module under Node's type stripping
import { round1, timeInZone, type PreviousPeriod } from "./reports.ts";
import { addDays, dateKeyInZone, hourInZone, startOfWeek } from "./time.ts";

export const EMAIL_GROUPS: readonly EmailGroup[] = ["day", "week"];

export function parseEmailGroup(value: unknown): EmailGroup | null {
  return typeof value === "string" && (EMAIL_GROUPS as readonly string[]).includes(value) ? (value as EmailGroup) : null;
}

export function nextEmailGroup(group: EmailGroup): EmailGroup {
  return EMAIL_GROUPS[(EMAIL_GROUPS.indexOf(group) + 1) % EMAIL_GROUPS.length]!;
}

/** Email per agent: performance.team, and the tenant's reports.per_person holding email (cma.assert_per_person) */
export const EMAIL_PER_AGENT_PERMISSION = "performance.team";
export const EMAIL_PER_PERSON_KEY = "email";

/** Whether a person sees a per-person page: the permission, and the tenant's switch for its key */
export function perPersonOpen(me: { permissions: readonly string[]; perPerson: readonly string[] }, key: string): boolean {
  return me.permissions.includes(EMAIL_PER_AGENT_PERMISSION) && me.perPerson.includes(key);
}

const SOURCE_KEY = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[^@\s]{1,100}$/;

/**
 * The report's filters from a query, as cma.email_filters_check takes them: a market is a two-letter code
 * or "unknown", an inbox and a mailbox a connection id ':' source id; empty means all. `problem` names a
 * value the database would refuse; that filter is then left out
 */
export function parseEmailFilter(market: unknown, inbox: unknown, account: unknown): { filter: EmailFilter; problem: null | "market" | "inbox" | "account" } {
  const filter: EmailFilter = { market: null, inbox: null, account: null };
  let problem: null | "market" | "inbox" | "account" = null;
  const text = (v: unknown) => (typeof v === "string" && v.trim() !== "" ? v.trim() : null);
  const m = text(market);
  if (m !== null) {
    if (/^([A-Z]{2}|unknown)$/.test(m)) filter.market = m;
    else problem = "market";
  }
  const i = text(inbox);
  if (i !== null) {
    if (SOURCE_KEY.test(i)) filter.inbox = i;
    else problem ??= "inbox";
  }
  const a = text(account);
  if (a !== null) {
    if (SOURCE_KEY.test(a)) filter.account = a;
    else problem ??= "account";
  }
  return { filter, problem };
}

export function emailFilterQuery(filter: EmailFilter): Record<string, string> {
  const out: Record<string, string> = {};
  if (filter.market) out.market = filter.market;
  if (filter.inbox) out.inbox = filter.inbox;
  if (filter.account) out.account = filter.account;
  return out;
}

// ---- The mock's fixture and the definitions -----------------------------------------------------------

export type EmailActorKind = "agent" | "customer" | "system" | "bot" | "ai" | "integration" | "unknown";

/** One stored email of either source, as the mock holds it (the market already resolved by the chain) */
export interface EmailMessageFixture {
  kind: "crm_email" | "inbox_message";
  connectionId: string;
  sourceSystem: string;
  threadId: string | null;
  inboxId: string | null;
  accountId: string | null;
  channelId: string | null;
  direction: "in" | "out" | "forwarded";
  status: "sent" | "bounced" | "failed" | "scheduled" | "other";
  at: Instant;
  actorKind: EmailActorKind;
  ownerRef: string | null;
  origin: string | null;
  category: string | null;
  /** The market the chain gives (contact, form, record); null hands over to the mailbox and the inbox */
  market: string | null;
  deleted: boolean;
}

export interface EmailThreadFixture {
  connectionId: string;
  sourceSystem: string;
  id: string;
  inboxId: string | null;
  accountId: string | null;
  channelId: string | null;
  createdAt: Instant;
  status: "open" | "closed";
  isSpam: boolean;
  category: string | null;
  market: string | null;
  events: { kind: "closed" | "reopened"; at: Instant; actorKind: EmailActorKind; ownerRef: string | null }[];
}

/** A tenant's conversations catalog and settings as the definitions read them */
export interface EmailCatalog {
  inboxes: { id: string; name: string; isCounted: boolean; market: string | null }[];
  accounts: { id: string; name: string; label: string | null; isCounted: boolean; market: string | null }[];
  channels: { id: string; isCounted: boolean }[];
  /** email_inbox_copy_origins and email_automated_origins, lower case */
  inboxCopyOrigins: readonly string[];
  automatedOrigins: readonly string[];
  /** Each market's zone; a market without one is unknown */
  zones: Readonly<Record<string, string>>;
  tenantZone: string;
  /** Office hours: weekday (1 Monday … 7 Sunday) → [opens, closes] as HH:MM, the same for every market */
  officeHours: Readonly<Record<number, readonly [string, string]>>;
  replyTargetMinutes: number;
}

/** An email as cma.email_of returns it: the labels, the market and its zone's date, week and hour, the flags */
export interface EmailRecord {
  connectionId: string;
  sourceSystem: string;
  kind: "crm_email" | "inbox_message";
  threadId: string | null;
  inboxKey: string | null;
  inboxName: string | null;
  accountKey: string | null;
  accountName: string | null;
  category: string | null;
  at: Instant;
  actorKind: EmailActorKind;
  ownerRef: string | null;
  market: string;
  zone: string;
  date: DateKey;
  week: DateKey;
  localTime: string;
  hour: number;
  isReceived: boolean;
  isLoggedReply: boolean;
  isAgentSend: boolean;
  isAutomated: boolean;
  isBouncedFailed: boolean;
}

export interface EmailOpeningRecord {
  connectionId: string;
  sourceSystem: string;
  threadId: string;
  inboxKey: string | null;
  inboxName: string | null;
  accountKey: string | null;
  accountName: string | null;
  category: string | null;
  kind: "created" | "reopened";
  at: Instant;
  market: string;
  zone: string;
  date: DateKey;
  week: DateKey;
  localTime: string;
  firstReplyAt: Instant | null;
  replyOwnerRef: string | null;
  replySeconds: number | null;
  replyBusinessSeconds: number | null;
  replyWithinTarget: boolean | null;
  closedAt: Instant | null;
  closeSeconds: number | null;
  closeBusinessSeconds: number | null;
}

export interface EmailCloseRecord {
  connectionId: string;
  sourceSystem: string;
  threadId: string;
  inboxKey: string | null;
  inboxName: string | null;
  accountKey: string | null;
  accountName: string | null;
  category: string | null;
  at: Instant;
  actorKind: EmailActorKind;
  ownerRef: string | null;
  market: string;
  zone: string;
  date: DateKey;
  week: DateKey;
  localTime: string;
}

const AUTOMATED_ACTORS: readonly EmailActorKind[] = ["bot", "ai", "system", "integration"];

function inboxOf(c: EmailCatalog, id: string | null) {
  return id === null ? undefined : c.inboxes.find((x) => x.id === id);
}
function accountOf(c: EmailCatalog, id: string | null) {
  return id === null ? undefined : c.accounts.find((x) => x.id === id);
}
function channelOf(c: EmailCatalog, id: string | null) {
  return id === null ? undefined : c.channels.find((x) => x.id === id);
}
const knownMarket = (c: EmailCatalog, m: string | null | undefined): string | null => (m && c.zones[m] ? m : null);

/** A conversation's (or a message's) inbox, mailbox and channel all count; one not in the catalog counts */
function countedRefs(c: EmailCatalog, inboxId: string | null, accountId: string | null, channelId: string | null): boolean {
  return (inboxOf(c, inboxId)?.isCounted ?? true) && (accountOf(c, accountId)?.isCounted ?? true) && (channelOf(c, channelId)?.isCounted ?? true);
}

/** The market of the chain: the resolved one (contact, form, record), else the mailbox's, else the inbox's, else unknown */
function marketOf(c: EmailCatalog, resolved: string | null, accountId: string | null, inboxId: string | null): string {
  return knownMarket(c, resolved) ?? knownMarket(c, accountOf(c, accountId)?.market) ?? knownMarket(c, inboxOf(c, inboxId)?.market) ?? "unknown";
}

function placed(c: EmailCatalog, market: string, at: Instant) {
  const zone = c.zones[market] ?? c.tenantZone;
  const date = dateKeyInZone(at, zone);
  return { zone, date, week: startOfWeek(date), localTime: timeInZone(at, zone), hour: hourInZone(at, zone) };
}

/** The emails cma.email_of counts, from the stored ones (any period: the callers narrow it) */
export function emailRecords(messages: readonly EmailMessageFixture[], threads: readonly EmailThreadFixture[], c: EmailCatalog): EmailRecord[] {
  const threadOf = new Map(threads.map((t) => [`${t.connectionId}:${t.id}`, t]));
  const out: EmailRecord[] = [];
  for (const m of messages) {
    if (m.deleted) continue;
    const th = m.kind === "inbox_message" && m.threadId ? threadOf.get(`${m.connectionId}:${m.threadId}`) : undefined;
    const accountId = m.accountId ?? (m.kind === "inbox_message" ? th?.accountId ?? null : null);
    const inboxId = m.inboxId ?? (m.kind === "inbox_message" ? th?.inboxId ?? null : null);
    if (m.kind === "inbox_message") {
      if (!countedRefs(c, m.inboxId, accountId, m.channelId) || th?.isSpam) continue;
    } else if (m.origin !== null && c.inboxCopyOrigins.includes(m.origin.toLowerCase())) {
      continue;
    }
    const automated = m.kind === "crm_email"
      ? m.origin !== null && c.automatedOrigins.includes(m.origin.toLowerCase())
      : AUTOMATED_ACTORS.includes(m.actorKind);
    const market = marketOf(c, m.market ?? th?.market ?? null, accountId, inboxId);
    const inbox = inboxOf(c, m.inboxId);
    const account = accountOf(c, accountId);
    out.push({
      connectionId: m.connectionId, sourceSystem: m.sourceSystem, kind: m.kind, threadId: m.threadId,
      inboxKey: m.inboxId ? `${m.connectionId}:${m.inboxId}` : null, inboxName: inbox?.name ?? m.inboxId,
      accountKey: accountId ? `${m.connectionId}:${accountId}` : null, accountName: account ? account.label ?? account.name : accountId,
      category: m.category, at: m.at, actorKind: m.actorKind, ownerRef: m.ownerRef, market, ...placed(c, market, m.at),
      isReceived: m.kind === "inbox_message" && (m.direction === "in" || m.direction === "forwarded"),
      isLoggedReply: m.kind === "crm_email" && (m.direction === "in" || m.direction === "forwarded"),
      isAgentSend: m.direction === "out" && m.status === "sent" && !automated,
      isAutomated: m.direction === "out" && m.status === "sent" && automated,
      isBouncedFailed: m.direction === "out" && (m.status === "bounced" || m.status === "failed"),
    });
  }
  return out;
}

/** An instant for a local date and time in a zone (the earlier one when it occurs twice) */
export function zonedInstant(date: DateKey, time: string, zone: string): number {
  const guess = Date.parse(`${date}T${time}:00Z`);
  let ms = guess;
  for (let i = 0; i < 3; i++) {
    const local = Date.parse(`${dateKeyInZone(new Date(ms), zone)}T${timeInZone(new Date(ms).toISOString(), zone)}Z`);
    ms += guess - local;
  }
  return ms;
}

/** Office seconds between two instants in a market's zone, as cma.business_seconds_of; null for an unknown market */
export function businessSeconds(c: EmailCatalog, market: string, from: Instant, to: Instant): number | null {
  const zone = c.zones[market];
  if (!zone) return null;
  const a = Date.parse(from);
  const b = Date.parse(to);
  if (b <= a) return 0;
  let total = 0;
  for (let d = dateKeyInZone(from, zone); d <= dateKeyInZone(to, zone); d = addDays(d, 1)) {
    const dow = new Date(`${d}T12:00:00Z`).getUTCDay() || 7;
    const hours = c.officeHours[dow];
    if (!hours) continue;
    const opens = zonedInstant(d, hours[0], zone);
    const closes = zonedInstant(d, hours[1], zone);
    total += Math.max(0, Math.min(closes, b) - Math.max(opens, a));
  }
  return Math.round(total / 1000);
}

/** The openings cma.email_openings_of gives, with the first reply and the close of each (any period) */
export function emailOpenings(messages: readonly EmailMessageFixture[], threads: readonly EmailThreadFixture[], c: EmailCatalog): EmailOpeningRecord[] {
  const out: EmailOpeningRecord[] = [];
  const target = Math.max(1, c.replyTargetMinutes) * 60;
  for (const t of threads) {
    if (t.isSpam || !countedRefs(c, t.inboxId, t.accountId, t.channelId)) continue;
    const market = marketOf(c, t.market, t.accountId, t.inboxId);
    const status = [...t.events].sort((x, y) => x.at.localeCompare(y.at));
    const opens: { kind: "created" | "reopened"; at: Instant; from: number }[] = [{ kind: "created", at: t.createdAt, from: -Infinity }];
    status.forEach((e, i) => {
      const before = status.slice(0, i).filter((x) => Date.parse(x.at) < Date.parse(e.at));
      const last = before[before.length - 1];
      if (e.kind === "reopened" && last?.kind === "closed") opens.push({ kind: "reopened", at: e.at, from: Date.parse(last.at) });
    });
    const mine = messages.filter((m) => m.kind === "inbox_message" && m.connectionId === t.connectionId && m.threadId === t.id && !m.deleted)
      .sort((x, y) => x.at.localeCompare(y.at));
    const inbox = inboxOf(c, t.inboxId);
    const account = accountOf(c, t.accountId);
    for (const o of opens) {
      const close = status.find((e) => e.kind === "closed" && Date.parse(e.at) >= Date.parse(o.at));
      const until = close ? Date.parse(close.at) : Infinity;
      const firstIn = mine.find((m) => (m.direction === "in" || m.direction === "forwarded") && Date.parse(m.at) > o.from && Date.parse(m.at) <= until);
      const reply = firstIn ? mine.find((m) => m.direction === "out" && m.actorKind === "agent" && m.status !== "failed"
        && Date.parse(m.at) > Date.parse(firstIn.at) && Date.parse(m.at) <= until) : undefined;
      const rb = firstIn && reply ? businessSeconds(c, market, firstIn.at, reply.at) : null;
      out.push({
        connectionId: t.connectionId, sourceSystem: t.sourceSystem, threadId: t.id,
        inboxKey: t.inboxId ? `${t.connectionId}:${t.inboxId}` : null, inboxName: inbox?.name ?? t.inboxId,
        accountKey: t.accountId ? `${t.connectionId}:${t.accountId}` : null, accountName: account ? account.label ?? account.name : t.accountId,
        category: t.category, kind: o.kind, at: o.at, market, zone: placed(c, market, o.at).zone, date: placed(c, market, o.at).date,
        week: placed(c, market, o.at).week, localTime: placed(c, market, o.at).localTime,
        firstReplyAt: reply?.at ?? null, replyOwnerRef: reply?.ownerRef ?? null,
        replySeconds: firstIn && reply ? Math.round((Date.parse(reply.at) - Date.parse(firstIn.at)) / 1000) : null,
        replyBusinessSeconds: rb, replyWithinTarget: rb === null ? null : rb <= target,
        closedAt: close?.at ?? null,
        closeSeconds: close ? Math.round((Date.parse(close.at) - Date.parse(o.at)) / 1000) : null,
        closeBusinessSeconds: close ? businessSeconds(c, market, o.at, close.at) : null,
      });
    }
  }
  return out;
}

/** The closes cma.email_closes_of gives (any period) */
export function emailCloses(threads: readonly EmailThreadFixture[], c: EmailCatalog): EmailCloseRecord[] {
  const out: EmailCloseRecord[] = [];
  for (const t of threads) {
    if (t.isSpam || !countedRefs(c, t.inboxId, t.accountId, t.channelId)) continue;
    const market = marketOf(c, t.market, t.accountId, t.inboxId);
    const inbox = inboxOf(c, t.inboxId);
    const account = accountOf(c, t.accountId);
    for (const e of t.events) {
      if (e.kind !== "closed") continue;
      const p = placed(c, market, e.at);
      out.push({
        connectionId: t.connectionId, sourceSystem: t.sourceSystem, threadId: t.id,
        inboxKey: t.inboxId ? `${t.connectionId}:${t.inboxId}` : null, inboxName: inbox?.name ?? t.inboxId,
        accountKey: t.accountId ? `${t.connectionId}:${t.accountId}` : null, accountName: account ? account.label ?? account.name : t.accountId,
        category: t.category, at: e.at, actorKind: e.actorKind, ownerRef: e.ownerRef, market, zone: p.zone, date: p.date, week: p.week, localTime: p.localTime,
      });
    }
  }
  return out;
}

/** The records of business dates [from, to], cut on `to` at `until`'s time of day in each row's own zone (the previous span), narrowed by the filter */
export function emailInPeriod<T extends { date: DateKey; localTime: string; zone: string; market: string; inboxKey: string | null; accountKey: string | null }>(
  rows: readonly T[], from: DateKey, to: DateKey, filter: EmailFilter, until: Instant | null = null,
): T[] {
  return rows.filter((r) => r.date >= from && r.date <= to
    && (until === null || r.date < to || r.localTime <= timeInZone(until, r.zone))
    && (filter.market === null || r.market === filter.market)
    && (filter.inbox === null || r.inboxKey === filter.inbox)
    && (filter.account === null || r.accountKey === filter.account));
}

/** The records of the previous span, like for like (as previousCalls) */
export function emailPrevious<T extends { date: DateKey; localTime: string; zone: string; market: string; inboxKey: string | null; accountKey: string | null }>(
  rows: readonly T[], prev: PreviousPeriod, filter: EmailFilter, now: Instant,
): T[] {
  return emailInPeriod(rows, prev.from, prev.to, filter, prev.partial ? now : null);
}

/** The median as percentile_cont(0.5) gives it, to one decimal; null without values */
function median(values: readonly number[]): number | null {
  if (values.length === 0) return null;
  const v = [...values].sort((a, b) => a - b);
  const mid = (v.length - 1) / 2;
  return round1((v[Math.floor(mid)]! + v[Math.ceil(mid)]!) / 2);
}

/** The figures of a set of emails, openings and closes, as cma.email_figures_of aggregates them */
export function emailFigures(emails: readonly EmailRecord[], openings: readonly EmailOpeningRecord[], closes: readonly unknown[]): EmailFigures {
  const replied = openings.filter((o) => o.firstReplyAt !== null);
  const closed = openings.filter((o) => o.closedAt !== null);
  return {
    received: emails.filter((e) => e.isReceived).length,
    loggedReplies: emails.filter((e) => e.isLoggedReply).length,
    sentAgent: emails.filter((e) => e.isAgentSend).length,
    sentAutomated: emails.filter((e) => e.isAutomated).length,
    bouncedFailed: emails.filter((e) => e.isBouncedFailed).length,
    threadsOpened: openings.length,
    threadsClosed: closes.length,
    replied: replied.length,
    replyMedianSeconds: median(replied.map((o) => o.replySeconds!)),
    replyMedianBusinessSeconds: median(replied.filter((o) => o.replyBusinessSeconds !== null).map((o) => o.replyBusinessSeconds!)),
    withinTarget: replied.filter((o) => o.replyWithinTarget === true).length,
    targetKnown: replied.filter((o) => o.replyBusinessSeconds !== null).length,
    noHours: replied.filter((o) => o.replyBusinessSeconds === null).length,
    closeMedianSeconds: median(closed.map((o) => o.closeSeconds!)),
    closeMedianBusinessSeconds: median(closed.filter((o) => o.closeBusinessSeconds !== null).map((o) => o.closeBusinessSeconds!)),
  };
}

export type EmailDimension = EmailGroup | "market" | "inbox" | "account" | "category";

function keyOf(r: { date: DateKey; week: DateKey; market: string; inboxKey: string | null; inboxName: string | null; accountKey: string | null;
  accountName: string | null; category: string | null }, d: EmailDimension): { key: string; label: string | null } {
  switch (d) {
    case "day": return { key: r.date, label: r.date };
    case "week": return { key: r.week, label: r.week };
    case "market": return { key: r.market, label: r.market };
    case "inbox": return { key: r.inboxKey ?? "none", label: r.inboxName };
    case "account": return { key: r.accountKey ?? "none", label: r.accountName };
    case "category": return { key: r.category ?? "none", label: r.category };
  }
}

/** The figures per group of one dimension, as cma.email_by_dimension and the overview give them ('none' last, else by label) */
export function emailGroups(emails: readonly EmailRecord[], openings: readonly EmailOpeningRecord[], closes: readonly EmailCloseRecord[],
  d: EmailDimension): EmailRow[] {
  const groups = new Map<string, { label: string | null; e: EmailRecord[]; o: EmailOpeningRecord[]; c: EmailCloseRecord[] }>();
  const at = (k: { key: string; label: string | null }) => {
    let g = groups.get(k.key);
    if (!g) groups.set(k.key, (g = { label: k.label, e: [], o: [], c: [] }));
    else if (g.label === null) g.label = k.label;
    return g;
  };
  for (const e of emails) at(keyOf(e, d)).e.push(e);
  for (const o of openings) at(keyOf(o, d)).o.push(o);
  for (const c of closes) at(keyOf(c, d)).c.push(c);
  const rows = [...groups.entries()].map(([groupKey, g]) => ({ groupKey, groupLabel: g.label, ...emailFigures(g.e, g.o, g.c) }));
  const dated = d === "day" || d === "week";
  return rows.sort((a, b) => (dated ? a.groupKey.localeCompare(b.groupKey)
    : Number(a.groupKey === "none") - Number(b.groupKey === "none") || (a.groupLabel ?? "").localeCompare(b.groupLabel ?? "") || a.groupKey.localeCompare(b.groupKey)));
}

/** Received inbox messages per date (or week) and inbox or mailbox, as cma.email_received_series */
export function emailSeries(emails: readonly EmailRecord[], group: EmailGroup, split: "inbox" | "account"): EmailSeriesRow[] {
  const m = new Map<string, EmailSeriesRow>();
  for (const e of emails) {
    if (!e.isReceived) continue;
    const groupKey = group === "week" ? e.week : e.date;
    const seriesKey = (split === "inbox" ? e.inboxKey : e.accountKey) ?? "none";
    const k = `${groupKey}|${seriesKey}`;
    const row = m.get(k) ?? { groupKey, seriesKey, seriesLabel: split === "inbox" ? e.inboxName : e.accountName, received: 0 };
    row.received += 1;
    m.set(k, row);
  }
  return [...m.values()].sort((a, b) => a.groupKey.localeCompare(b.groupKey) || (a.seriesLabel ?? "").localeCompare(b.seriesLabel ?? "") || a.seriesKey.localeCompare(b.seriesKey));
}

/** Whose an owner id is: the person holding '<adapter>_owner' with it, or null (not linked) */
export type EmailPersonOf = (sourceSystem: string, ownerRef: string | null) => { userId: string; name: string } | null;

/**
 * Per person, as cma.email_per_person: the agent sends (the sender), the first replies (the replying agent)
 * and the closes by an agent (the closing agent); owner ids without a person, and sends without an owner,
 * as one not-linked row with how many owner ids that is, never which; by name, the not-linked row last
 */
export function emailPerPerson(emails: readonly EmailRecord[], openings: readonly EmailOpeningRecord[], closes: readonly EmailCloseRecord[],
  personOf: EmailPersonOf): { rows: EmailPerson[]; total: EmailPerson } {
  type Acc = { kind: "person" | "notLinked"; userId: string | null; name: string | null; owners: Set<string>; sent: number; replies: number; closed: number;
    rs: number[]; rbs: number[]; within: number; known: number; hours: number[] };
  const by = new Map<string, Acc>();
  const total: Acc = { kind: "person", userId: null, name: null, owners: new Set(), sent: 0, replies: 0, closed: 0, rs: [], rbs: [], within: 0, known: 0,
    hours: Array(24).fill(0) };
  const accOf = (sourceSystem: string, ownerRef: string | null): Acc => {
    const p = personOf(sourceSystem, ownerRef);
    const k = p ? `person:${p.userId}` : "notLinked";
    let a = by.get(k);
    if (!a) by.set(k, (a = { kind: p ? "person" : "notLinked", userId: p?.userId ?? null, name: p?.name ?? null, owners: new Set(), sent: 0, replies: 0,
      closed: 0, rs: [], rbs: [], within: 0, known: 0, hours: Array(24).fill(0) }));
    if (!p && ownerRef !== null) a.owners.add(ownerRef);
    return a;
  };
  for (const e of emails) {
    if (!e.isAgentSend) continue;
    for (const a of [accOf(e.sourceSystem, e.ownerRef), total]) {
      a.sent += 1;
      a.hours[e.hour]! += 1;
    }
  }
  for (const o of openings) {
    if (o.firstReplyAt === null) continue;
    for (const a of [accOf(o.sourceSystem, o.replyOwnerRef), total]) {
      a.replies += 1;
      a.rs.push(o.replySeconds!);
      if (o.replyBusinessSeconds !== null) {
        a.rbs.push(o.replyBusinessSeconds);
        a.known += 1;
        if (o.replyWithinTarget) a.within += 1;
      }
    }
  }
  for (const c of closes) {
    if (c.actorKind !== "agent") continue;
    for (const a of [accOf(c.sourceSystem, c.ownerRef), total]) a.closed += 1;
  }
  const out = (a: Acc, kind: EmailPerson["kind"]): EmailPerson => ({
    kind, userId: kind === "person" ? a.userId : null, name: kind === "person" ? a.name : null, unlinkedOwners: kind === "notLinked" ? a.owners.size : null,
    sent: a.sent, replies: a.replies, threadsClosed: a.closed, replyMedianSeconds: median(a.rs), replyMedianBusinessSeconds: median(a.rbs),
    withinTarget: a.within, targetKnown: a.known, sentByHour: a.hours,
  });
  const rows = [...by.values()].map((a) => out(a, a.kind))
    .sort((a, b) => Number(a.kind === "notLinked") - Number(b.kind === "notLinked") || (a.name ?? "").localeCompare(b.name ?? "") || (a.userId ?? "").localeCompare(b.userId ?? ""));
  return { rows, total: out(total, "total") };
}

/**
 * The conversations waiting now, as cma.email_waiting_of: open, counted, not spam, whose latest incoming
 * message is later than their latest agent message out (not failed); waiting since the first incoming
 * message after that agent message, in business and elapsed seconds; longest waiting first
 */
export function emailWaiting(messages: readonly EmailMessageFixture[], threads: readonly EmailThreadFixture[], c: EmailCatalog, now: Instant):
  Omit<EmailWaitingRow, "recordUrl">[] {
  const out: Omit<EmailWaitingRow, "recordUrl">[] = [];
  for (const t of threads) {
    if (t.status !== "open" || t.isSpam || !countedRefs(c, t.inboxId, t.accountId, t.channelId)) continue;
    const mine = messages.filter((m) => m.kind === "inbox_message" && m.connectionId === t.connectionId && m.threadId === t.id && !m.deleted);
    const lastOut = Math.max(-Infinity, ...mine.filter((m) => m.direction === "out" && m.actorKind === "agent" && m.status !== "failed").map((m) => Date.parse(m.at)));
    const incoming = mine.filter((m) => (m.direction === "in" || m.direction === "forwarded") && Date.parse(m.at) > lastOut).sort((x, y) => x.at.localeCompare(y.at));
    const first = incoming[0];
    if (!first) continue;
    const market = marketOf(c, t.market, t.accountId, t.inboxId);
    const account = accountOf(c, t.accountId);
    out.push({
      connectionId: t.connectionId, threadId: t.id, inboxName: inboxOf(c, t.inboxId)?.name ?? t.inboxId, accountName: account ? account.label ?? account.name : t.accountId,
      market, waitingSince: first.at, waitedSeconds: Math.max(0, Math.round((Date.parse(now) - Date.parse(first.at)) / 1000)),
      waitedBusinessSeconds: businessSeconds(c, market, first.at, now),
    });
  }
  return out.sort((a, b) => a.waitingSince.localeCompare(b.waitingSince) || a.threadId.localeCompare(b.threadId));
}

/** Replies within the target as a share of those whose market has office hours, 0 to 1; null without one */
export function withinShare(f: Pick<EmailFigures, "withinTarget" | "targetKnown">): number | null {
  return f.targetKnown === 0 ? null : f.withinTarget / f.targetKnown;
}

// ---- The screen ------------------------------------------------------------------------------------------

/** The series colours of the style (docs/style/Pulse4all-Style.md 7.7), in its order; Other last in Light Blue's neighbour Neutral */
export const SERIES_CLASSES = ["bg-p4a-deepblue", "bg-p4a-green", "bg-p4a-lightblue", "bg-p4a-denim", "bg-p4a-rose", "bg-p4a-inkt"] as const;
export const SERIES_FILLS = ["fill-p4a-deepblue", "fill-p4a-green", "fill-p4a-lightblue", "fill-p4a-denim", "fill-p4a-rose", "fill-p4a-inkt"] as const;
export const OTHER_SERIES_CLASS = "bg-p4a-muted";
export const OTHER_SERIES_FILL = "fill-p4a-muted";
export const AGENT_SEND_CLASS = "bg-p4a-deepblue";
export const AUTOMATED_CLASS = "bg-p4a-green";

/**
 * Columns per date (or week) with one stacked part per series (an inbox or a mailbox): the series with the
 * most received messages in the style's order, the rest as Other; every date of the period up to `last`
 * (today), a date without messages at 0, so the axis has no gaps
 */
export function seriesColumns(rows: readonly EmailSeriesRow[], group: EmailGroup, from: DateKey, to: DateKey, last: DateKey, max = SERIES_CLASSES.length - 1):
  { keys: DateKey[]; series: { key: string; label: string | null; index: number | null }[]; values: Map<string, number> } {
  const totals = new Map<string, { label: string | null; n: number }>();
  for (const r of rows) {
    const t = totals.get(r.seriesKey) ?? { label: r.seriesLabel, n: 0 };
    t.n += r.received;
    totals.set(r.seriesKey, t);
  }
  const ranked = [...totals.entries()].sort((a, b) => b[1].n - a[1].n || (a[1].label ?? "").localeCompare(b[1].label ?? "") || a[0].localeCompare(b[0]));
  const shown = ranked.slice(0, ranked.length > max + 1 ? max : max + 1);
  const series: { key: string; label: string | null; index: number | null }[] = shown.map(([key, t], i) => ({ key, label: t.label, index: i }));
  const other = ranked.length > shown.length;
  if (other) series.push({ key: "other", label: null, index: null });
  const shownKeys = new Set(shown.map(([k]) => k));
  const keys: DateKey[] = [];
  const end = to < last ? to : last;
  for (let d = group === "day" ? from : startOfWeek(from); d <= end; d = addDays(d, group === "day" ? 1 : 7)) keys.push(d);
  const values = new Map<string, number>();
  for (const r of rows) {
    const s = shownKeys.has(r.seriesKey) ? r.seriesKey : "other";
    const k = `${r.groupKey}|${s}`;
    values.set(k, (values.get(k) ?? 0) + r.received);
  }
  return { keys, series, values };
}
