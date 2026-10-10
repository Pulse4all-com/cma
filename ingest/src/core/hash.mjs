/**
 * The keyed hash of a phone number (DESIGN §6.3): HMAC-SHA256(pepper, E.164) in lower-case hex.
 *
 * The number is normalised with libphonenumber, using a default region (the line's or the market's
 * country) for numbers written in national format, so "020 0000 0001" in GB and "+44 20 0000 0001"
 * give the same hash. A number that cannot be read as a possible phone number gives null: no hash
 * is better than a hash of garbage. The pepper is per tenant, in Secret Manager
 * (ingest-hash-pepper-<tenant slug>); rotating it breaks old links only.
 *
 * Numbers exist in memory only: callers hash and drop them, and nothing here logs or returns one.
 */
import { createHmac } from "node:crypto";
import { parsePhoneNumberFromString } from "libphonenumber-js";

/** E.164 of a number, or null. defaultRegion: ISO 3166-1 alpha-2 (upper case) or null. */
export function toE164(number, defaultRegion = null) {
  if (typeof number !== "string" && typeof number !== "number") return null;
  const text = String(number).trim();
  if (!text || text.length > 40) return null;
  const region = typeof defaultRegion === "string" && /^[A-Z]{2}$/.test(defaultRegion) ? defaultRegion : undefined;
  let parsed;
  try {
    parsed = parsePhoneNumberFromString(text, region);
  } catch {
    return null;
  }
  if (!parsed || !parsed.isPossible()) return null;
  return parsed.number;
}

/** The keyed hash of a number, or null when the number cannot be normalised or there is no pepper. */
export function hashNumber(pepper, number, defaultRegion = null) {
  if (!pepper) return null;
  const e164 = toE164(number, defaultRegion);
  if (!e164) return null;
  return createHmac("sha256", pepper).update(e164, "utf8").digest("hex");
}
