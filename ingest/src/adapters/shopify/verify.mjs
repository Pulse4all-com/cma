/**
 * Shopify request authentication (DESIGN §2, §6.1; shopify.dev, Webhooks, "Verify deliveries",
 * checked 13 October 2026): every webhook carries X-Shopify-Hmac-Sha256, the base64 HMAC-SHA256 of
 * the raw request body keyed with the app's client secret. The digest is computed over the bytes as
 * received (never a re-serialised body) and compared with the header as two base64 strings of equal
 * length in constant time (crypto.timingSafeEqual; another length is a failure without a compare).
 * After a secret rotation Shopify may sign with the old secret for up to an hour, so the runbook
 * rotates by adding a version and waiting (docs/ingest/README.md, Shopify).
 *
 * The secret is never logged, recorded or returned: the caller gets { ok } or { ok: false, reason }.
 */
import { createHmac, timingSafeEqual } from "node:crypto";

export const HMAC_HEADER = "x-shopify-hmac-sha256";
const BASE64 = /^[A-Za-z0-9+/]{43}=$/;

/** base64(HMAC-SHA256(secret, body)): what Shopify sends for this body. */
export function signBody(secret, body) {
  return createHmac("sha256", secret).update(Buffer.isBuffer(body) ? body : Buffer.from(String(body), "utf8")).digest("base64");
}

/** The two base64 strings are equal, compared in constant time; false for anything else. */
export function sameDigest(given, expected) {
  if (typeof given !== "string" || typeof expected !== "string") return false;
  const a = Buffer.from(given, "utf8");
  const b = Buffer.from(expected, "utf8");
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

/**
 * { ok: true } or { ok: false, reason } with reason missing_header (no HMAC header, or one that is
 * not a base64 SHA-256 digest) or bad_signature (another secret, or a body changed on the way).
 */
export function verifyHmac({ body, headers, secret }) {
  const given = headers?.[HMAC_HEADER];
  if (typeof given !== "string" || !BASE64.test(given.trim())) return { ok: false, reason: "missing_header" };
  if (!secret) return { ok: false, reason: "bad_signature" };
  return sameDigest(given.trim(), signBody(secret, body ?? Buffer.alloc(0))) ? { ok: true } : { ok: false, reason: "bad_signature" };
}
