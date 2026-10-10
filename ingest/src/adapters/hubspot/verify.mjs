/**
 * HubSpot request validation, signature v3 (developers.hubspot.com/docs/apps/legacy-apps/
 * authentication/validating-requests; DESIGN §2):
 *
 *   X-HubSpot-Signature-v3       base64(HMAC-SHA256(client secret, method + URI + body + timestamp))
 *   X-HubSpot-Request-Timestamp  milliseconds since the epoch; refused when more than 5 minutes off
 *
 * The URI is the full address HubSpot called (the app's targetUrl with any query string), with the
 * percent-encodings HubSpot decodes before signing turned back into their characters. The service
 * cannot know the public address from the request alone behind Cloud Run, so the caller passes the
 * candidates from configuration (INGEST_PUBLIC_URLS). Compared in constant time. Older signature
 * versions are never accepted (no replay protection; NIGHT_NOTES D3).
 */
import { createHmac, timingSafeEqual } from "node:crypto";

export const MAX_AGE_MS = 5 * 60_000;
export const SIGNATURE_HEADER = "x-hubspot-signature-v3";
export const TIMESTAMP_HEADER = "x-hubspot-request-timestamp";

// The encodings HubSpot decodes in the URI before computing the signature
const DECODE = { "%3A": ":", "%2F": "/", "%3F": "?", "%40": "@", "%21": "!", "%24": "$", "%27": "'", "%28": "(", "%29": ")", "%2A": "*", "%2C": ",", "%3B": ";" };

export function hubspotUri(uri) {
  return uri.replace(/%(3A|2F|3F|40|21|24|27|28|29|2A|2C|3B)/gi, (m) => DECODE[m.toUpperCase()]);
}

export function signV3(secret, method, uri, body, timestamp) {
  const source = `${method.toUpperCase()}${hubspotUri(uri)}${Buffer.isBuffer(body) ? body.toString("utf8") : body}${timestamp}`;
  return createHmac("sha256", secret).update(source, "utf8").digest("base64");
}

function same(a, b) {
  const x = Buffer.from(a, "utf8");
  const y = Buffer.from(b, "utf8");
  return x.length === y.length && timingSafeEqual(x, y);
}

/**
 * { ok: true } or { ok: false, reason } with reason missing_header, bad_timestamp, stale_timestamp or
 * bad_signature. uris: the full request URIs to try (one per configured public base URL).
 */
export function verifyV3({ method, uris, body, headers, secret, now = Date.now() }) {
  const signature = headers[SIGNATURE_HEADER];
  const timestamp = headers[TIMESTAMP_HEADER];
  if (typeof signature !== "string" || !signature || typeof timestamp !== "string" || !timestamp) {
    return { ok: false, reason: "missing_header" };
  }
  if (!/^\d{10,16}$/.test(timestamp)) return { ok: false, reason: "bad_timestamp" };
  if (Math.abs(now - Number(timestamp)) > MAX_AGE_MS) return { ok: false, reason: "stale_timestamp" };
  if (!secret) return { ok: false, reason: "bad_signature" };
  let ok = false;
  for (const uri of uris) {
    // every candidate is computed and compared, so the time taken does not depend on which matched
    if (same(signV3(secret, method, uri, body, timestamp), signature)) ok = true;
  }
  return ok ? { ok: true } : { ok: false, reason: "bad_signature" };
}
