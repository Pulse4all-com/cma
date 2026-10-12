/**
 * Pure helpers for messaging (migration 0008): validation of the inbox query, the read and send
 * bodies, the poller's decisions (what to toast, what needs confirming) and small formatting.
 * No runtime imports, so verify/messages.mjs runs them without a server or a database.
 */
import type { MessageTarget, MessageUrgency, MyMessage, SendMessageInput } from "@/lib/data/types";

/** The open Workspace polls every 10 s while visible and every 30 s hidden (README, Messaging: the fallback until the realtime service) */
export const POLL_VISIBLE_MS = 10_000;
export const POLL_HIDDEN_MS = 30_000;
/** A toast stays this long unless opened */
export const TOAST_MS = 8_000;
export const INBOX_LIMIT_DEFAULT = 50;
export const INBOX_LIMIT_MAX = 200;
export const TITLE_MAX = 120;
export const BODY_MAX = 500;
export const IDS_MAX = 500;

export type Validation<T> = { ok: true; value: T } | { ok: false; code: string; message: string };

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const INSTANT_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$/;
const KEY_RE = /^[a-z0-9][a-z0-9_-]{0,99}$/;

const bad = (code: string, message: string): Validation<never> => ({ ok: false, code, message });

/** since (an ISO instant in UTC, optional) and limit (1 to 200, default 50) of GET /api/v1/me/messages */
export function parseInboxQuery(since: string | null, limit: string | null): Validation<{ since: string | null; limit: number }> {
  let s: string | null = null;
  if (since !== null && since !== "") {
    if (!INSTANT_RE.test(since) || Number.isNaN(Date.parse(since))) return bad("invalid_since", "since must be an ISO instant in UTC");
    s = since;
  }
  let n = INBOX_LIMIT_DEFAULT;
  if (limit !== null && limit !== "") {
    if (!/^\d{1,3}$/.test(limit)) return bad("invalid_limit", `limit must be 1 to ${INBOX_LIMIT_MAX}`);
    n = Number(limit);
    if (n < 1 || n > INBOX_LIMIT_MAX) return bad("invalid_limit", `limit must be 1 to ${INBOX_LIMIT_MAX}`);
  }
  return { ok: true, value: { since: s, limit: n } };
}

/** { ids: [uuid, …] } of POST /api/v1/me/messages/read: 1 to 500 ids, lower-cased */
export function parseIds(body: Record<string, unknown>): Validation<string[]> {
  const ids = body.ids;
  if (!Array.isArray(ids) || ids.length < 1 || ids.length > IDS_MAX || !ids.every((x) => typeof x === "string" && UUID_RE.test(x))) {
    return bad("invalid_ids", `ids must be a list of 1 to ${IDS_MAX} message ids`);
  }
  return { ok: true, value: [...new Set(ids.map((x: string) => x.toLowerCase()))] };
}

/**
 * The body of POST /api/v1/messages: title 1 to 120, body at most 500, urgency normal or urgent, and a
 * target naming exactly one of everyone, teams, language or users (the same rules as cma.send_message,
 * checked here so a bad request is a 400 with a code rather than a database round trip).
 */
export function parseSendInput(body: Record<string, unknown>): Validation<SendMessageInput> {
  const title = typeof body.title === "string" ? body.title.trim() : "";
  if (title.length < 1 || title.length > TITLE_MAX) return bad("invalid_title", `title must be 1 to ${TITLE_MAX} characters`);
  const text = body.body === undefined || body.body === null ? "" : body.body;
  if (typeof text !== "string" || text.length > BODY_MAX) return bad("invalid_body_text", `body must be at most ${BODY_MAX} characters`);
  const urgency = body.urgency === undefined ? "normal" : body.urgency;
  if (urgency !== "normal" && urgency !== "urgent") return bad("invalid_urgency", "urgency must be normal or urgent");
  const t = body.target;
  if (!t || typeof t !== "object" || Array.isArray(t)) return bad("invalid_target", "target must be an object");
  const target = t as Record<string, unknown>;
  const groups = ["everyone", "teams", "language", "users"].filter((k) => k in target);
  if (groups.length !== 1) return bad("invalid_target", "target names exactly one of everyone, teams, language or users");
  if ("onlyClockedIn" in target && typeof target.onlyClockedIn !== "boolean") return bad("invalid_target", "onlyClockedIn must be true or false");
  const only = target.onlyClockedIn === true ? { onlyClockedIn: true as const } : {};
  let out: MessageTarget;
  if (groups[0] === "everyone") {
    if (target.everyone !== true) return bad("invalid_target", "everyone must be true");
    out = { everyone: true, ...only };
  } else if (groups[0] === "teams") {
    const teams = target.teams;
    if (!Array.isArray(teams) || teams.length < 1 || teams.length > 50 || !teams.every((k) => typeof k === "string" && KEY_RE.test(k))) {
      return bad("invalid_target", "teams must be a list of 1 to 50 team keys");
    }
    out = { teams: [...new Set(teams as string[])], ...only };
  } else if (groups[0] === "language") {
    const l = target.language as Record<string, unknown> | null;
    if (!l || typeof l !== "object" || typeof l.skill !== "string" || !KEY_RE.test(l.skill)) return bad("invalid_target", "language must be { skill, minLevel }");
    const min = l.minLevel === undefined || l.minLevel === null ? null : l.minLevel;
    if (min !== null && (typeof min !== "number" || !Number.isInteger(min) || min < 1 || min > 9)) return bad("invalid_target", "minLevel must be 1 to 9 or null");
    out = { language: { skill: l.skill, minLevel: min }, ...only };
  } else {
    const users = target.users;
    if (!Array.isArray(users) || users.length < 1 || users.length > IDS_MAX || !users.every((x) => typeof x === "string" && UUID_RE.test(x))) {
      return bad("invalid_target", `users must be a list of 1 to ${IDS_MAX} user ids`);
    }
    out = { users: [...new Set((users as string[]).map((x) => x.toLowerCase()))], ...only };
  }
  return { ok: true, value: { title, body: text, urgency: urgency as MessageUrgency, target: out } };
}

/**
 * The poller's decision on one answer: which messages get a toast (new since the last poll, unread, not
 * urgent) and which need confirming (urgent and not yet acknowledged, on the first poll too, so a
 * message that arrived while the tab was closed still gets its pop-up). `known` is updated in place.
 */
export function arrivals(known: Set<string>, incoming: MyMessage[], firstPoll: boolean): { toasts: MyMessage[]; urgent: MyMessage[] } {
  const toasts: MyMessage[] = [];
  const urgent: MyMessage[] = [];
  // Oldest first, so the pop-ups queue in the order the messages were sent
  for (const m of [...incoming].reverse()) {
    const isNew = !known.has(m.id);
    known.add(m.id);
    if (m.urgency === "urgent" && m.acknowledgedAt === null) urgent.push(m);
    else if (isNew && !firstPoll && m.readAt === null) toasts.push(m);
  }
  return { toasts, urgent };
}

/** The browser title with the unread count in front, or the bare title */
export function titleWithUnread(base: string, unread: number): string {
  const bare = base.replace(/^\(\d+\) /, "");
  return unread > 0 ? `(${unread}) ${bare}` : bare;
}

/** Seconds as m:ss, or an empty mark when there is nothing to show */
export function fmtSeconds(seconds: number | null): string {
  if (seconds === null || seconds < 0) return "–";
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return `${m}:${String(s).padStart(2, "0")}`;
}
