/**
 * Aircall request authentication (DESIGN §2, §6.1; README Open decisions). Aircall signs nothing: every
 * webhook request carries the webhook's own token as the body's top-level `token` (developer.aircall.io,
 * Webhooks: "unique token for request's authentication"). The token is compared in constant time
 * (crypto.timingSafeEqual on buffers of equal length; a length mismatch is a failure without a
 * compare) with the connection's signing secret, which holds that webhook's token. The opaque key in
 * the path is the second factor, HTTPS the transport, and one webhook per connection pins a request
 * to its connection (an Aircall event names no company).
 *
 * The token is never logged, recorded or returned: the caller gets { ok } or { ok: false, reason }.
 */
import { timingSafeEqual } from "node:crypto";

/** The two tokens are equal, compared in constant time; false for anything that is not two non-empty strings. */
export function sameToken(given, expected) {
  if (typeof given !== "string" || typeof expected !== "string" || !given || !expected) return false;
  const a = Buffer.from(given, "utf8");
  const b = Buffer.from(expected, "utf8");
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

/**
 * { ok: true } or { ok: false, reason } with reason not_json (no JSON object to take a token from),
 * missing_token (no string token) or bad_token (another token, also of another length).
 */
export function verifyToken({ body, secret }) {
  let parsed;
  try {
    parsed = JSON.parse(Buffer.isBuffer(body) ? body.toString("utf8") : String(body ?? ""));
  } catch {
    return { ok: false, reason: "not_json" };
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return { ok: false, reason: "not_json" };
  const token = parsed.token;
  if (typeof token !== "string" || !token) return { ok: false, reason: "missing_token" };
  return sameToken(token, secret) ? { ok: true } : { ok: false, reason: "bad_token" };
}
