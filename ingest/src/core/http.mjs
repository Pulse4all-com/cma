/**
 * Outbound HTTP for the adapters' read-back, with the error classification the event log keeps:
 * rate_limited (429), timeout (the budget or the call's own timeout), unreachable (network),
 * http_<status> otherwise. Errors carry a code only, never a response body (which could hold data);
 * a 429 also carries the source's rate-limit headers (names with limit, remaining, reset or retry:
 * counts and times, never data), so an adapter can hold its calls until the source's reset.
 *
 * onHeaders, when given, receives every response's headers as they arrive (a 429's too), before the
 * body is read: an adapter's client reads the source's usage headers from them (HubSpot's daily limit,
 * CMA-069). It is called with the headers only, never with a body.
 *
 * errorCodes, when given, maps a source's error types to codes: a failed answer whose body names one of
 * them ({ "error": { "type": T } } or { "error": T }) fails with its code instead of http_<status>. Only a
 * type the map names is read from the body; nothing else of it is kept (Airtable's expired paging,
 * LIST_RECORDS_ITERATOR_NOT_AVAILABLE, is paging_expired).
 *
 * No redirect is followed (redirect: manual, so a 3xx answer is http_3xx like any other status): the
 * hosts are pinned, and a followed redirect would carry a vendor token to another host. A body is read
 * up to MAX_RESPONSE_BYTES; above that the call fails bad_response instead of filling the instance's
 * memory (audit 17 October 2026, 5.2-08).
 */
export class SourceError extends Error {
  constructor(code, status = null, rateLimit = null) {
    super(code);
    this.name = "SourceError";
    this.code = code;
    this.status = status;
    this.rateLimit = rateLimit;
  }
}

const RATE_HEADER = /limit|remaining|reset|retry/i;
export const MAX_RESPONSE_BYTES = 16 * 1024 * 1024;

/** Only https, or plain http to the local machine (the verifiers' fake sources). */
export function checkedBase(url) {
  let u;
  try {
    u = new URL(url);
  } catch {
    throw new Error("invalid API base URL");
  }
  const local = u.hostname === "127.0.0.1" || u.hostname === "localhost";
  if (u.protocol !== "https:" && !(u.protocol === "http:" && local)) throw new Error("API base URL must be https");
  return u.origin;
}

/** The body as text, at most maxBytes; SourceError bad_response above that (the rest is not read). */
async function readText(res, maxBytes) {
  if (!res.body) return "";
  const parts = [];
  let size = 0;
  for await (const chunk of res.body) {
    size += chunk.byteLength;
    if (size > maxBytes) throw new SourceError("bad_response", res.status); // leaving the loop cancels the stream
    parts.push(chunk);
  }
  return new TextDecoder().decode(Buffer.concat(parts));
}

/** The code a failed answer's error type maps to (errorCodes), or null: the type only, nothing else of the body. */
function errorCodeOf(text, errorCodes) {
  if (!errorCodes || !text) return null;
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    return null;
  }
  const type = typeof parsed?.error === "string" ? parsed.error : parsed?.error?.type;
  return typeof type === "string" && Object.hasOwn(errorCodes, type) ? errorCodes[type] : null;
}

/** fetch → parsed JSON; throws SourceError. The caller passes the budget's signal. */
export async function requestJson(url, { method = "GET", headers = {}, body, signal, maxBytes = MAX_RESPONSE_BYTES, onHeaders = null, errorCodes = null } = {}) {
  let res;
  try {
    res = await fetch(url, {
      method,
      headers: { accept: "application/json", ...(body !== undefined ? { "content-type": "application/json" } : {}), ...headers },
      body: body !== undefined ? JSON.stringify(body) : undefined,
      signal,
      redirect: "manual",
    });
  } catch (err) {
    if (err?.name === "TimeoutError" || err?.name === "AbortError") throw new SourceError("timeout");
    throw new SourceError("unreachable");
  }
  onHeaders?.(res.headers);
  if (res.status === 429) {
    const rateLimit = Object.fromEntries([...res.headers].filter(([k]) => RATE_HEADER.test(k)).map(([k, v]) => [k.toLowerCase(), String(v).slice(0, 40)]));
    await res.body?.cancel().catch(() => undefined);
    throw new SourceError("rate_limited", 429, rateLimit);
  }
  let text;
  try {
    text = await readText(res, maxBytes);
  } catch (err) {
    if (err instanceof SourceError) throw err;
    if (err?.name === "TimeoutError" || err?.name === "AbortError") throw new SourceError("timeout");
    throw new SourceError("unreachable");
  }
  // 207 is HubSpot's multi-status for a batch with some ids not found: the body still holds the results
  if (!res.ok && res.status !== 207) throw new SourceError(errorCodeOf(text, errorCodes) ?? `http_${res.status}`, res.status);
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    throw new SourceError("bad_response", res.status);
  }
}
