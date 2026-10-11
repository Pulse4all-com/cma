/**
 * The automation adapter: messages to agents from Make, n8n or a CRM workflow (README Features 7,
 * addition 0008a). Route: POST /automation/<connection key>, no events, no read-back: the body is
 * handed to cma.ingest_send_message() per message under the connection's tenant and Ingest user.
 *
 * Authentication: `Authorization: Bearer <secret>`, compared in constant time with the connection's
 * signing secret (Secret Manager, signing_secret_name). The key in the path only finds the
 * connection; the bearer is the proof. A body of { "messages": [ { title, body?, urgency?, target,
 * ref? } ] } with 1 to 50 messages; target as cma.ingest_send_message takes it (everyone, teams,
 * language, users, owners { system, ids }, emails; onlyClockedIn); ref { system, type, id }.
 */
import { createHash, timingSafeEqual } from "node:crypto";
import { getSecret } from "../../core/secrets.mjs";
import { withTenant, dbErrorCode } from "../../core/db.mjs";
import { contextOf } from "../../core/connection.mjs";

export const MAX_MESSAGES = 50;

function sameSecret(a, b) {
  const ha = createHash("sha256").update(String(a)).digest();
  const hb = createHash("sha256").update(String(b)).digest();
  return timingSafeEqual(ha, hb);
}

/** The shape checks the database repeats (CMA04); here so a bad request is a 400 with a code before any query */
export function parseMessages(body) {
  let parsed;
  try {
    parsed = JSON.parse(body.toString("utf8"));
  } catch {
    return { ok: false, code: "bad_json" };
  }
  const list = parsed?.messages;
  if (!Array.isArray(list) || list.length < 1 || list.length > MAX_MESSAGES) return { ok: false, code: "messages_1_to_50" };
  const out = [];
  for (const m of list) {
    if (!m || typeof m !== "object" || Array.isArray(m)) return { ok: false, code: "message_not_an_object" };
    const title = typeof m.title === "string" ? m.title.trim() : "";
    if (!title || title.length > 120) return { ok: false, code: "title_1_to_120" };
    const text = m.body === undefined || m.body === null ? "" : m.body;
    if (typeof text !== "string" || text.length > 500) return { ok: false, code: "body_at_most_500" };
    const urgency = m.urgency === undefined ? "normal" : m.urgency;
    if (urgency !== "normal" && urgency !== "urgent") return { ok: false, code: "urgency_normal_or_urgent" };
    if (!m.target || typeof m.target !== "object" || Array.isArray(m.target)) return { ok: false, code: "target_object" };
    let ref = null;
    if (m.ref !== undefined && m.ref !== null) {
      const r = m.ref;
      if (!r || typeof r !== "object" || typeof r.system !== "string" || typeof r.type !== "string" || typeof r.id !== "string") return { ok: false, code: "ref_system_type_id" };
      ref = { system: r.system, type: r.type, id: r.id };
    }
    out.push({ title, body: text, urgency, target: m.target, ref });
  }
  return { ok: true, value: out };
}

export const automation = {
  name: "automation",
  kind: "messages",

  /** Bearer token against the connection's signing secret; SecretUnavailable propagates (the server answers 500). */
  async authenticate({ headers, connection }) {
    const secret = await getSecret(connection.signingSecretName);
    const header = String(headers.authorization ?? "");
    const m = /^Bearer\s+(\S+)$/i.exec(header);
    if (!m) return { ok: false, reason: "no_bearer" };
    return sameSecret(m[1], secret) ? { ok: true } : { ok: false, reason: "wrong_bearer" };
  },

  parseMessages,

  /**
   * Sends every message in its own short transaction; one refused message (nobody reached, an unknown
   * team or person, a bad target) does not stop the others. Answers { sent: [...], refused: [...] }.
   */
  async send(connection, messages) {
    const ctx = contextOf(connection);
    const sent = [];
    const refused = [];
    for (const [index, m] of messages.entries()) {
      try {
        const r = await withTenant(ctx, async (q) => (await q.query(
          "select message_id, recipients from cma.ingest_send_message($1, $2, $3, $4, $5::jsonb, $6, $7, $8)",
          [connection.connectionId, m.title, m.body, m.urgency, JSON.stringify(m.target), m.ref?.system ?? null, m.ref?.type ?? null, m.ref?.id ?? null],
        )).rows[0]);
        sent.push({ index, id: r.message_id, recipients: Number(r.recipients) });
      } catch (err) {
        const code = dbErrorCode(err);   // db_<SQLSTATE>: the database's refusal is the automation's answer, never its text
        if (code === "db_CMA04" || code === "db_CMA02") refused.push({ index, code: code === "db_CMA02" ? "not_found" : "invalid" });
        else throw err;
      }
    }
    return { sent, refused };
  },
};
