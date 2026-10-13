/**
 * Outbound HTTP for the adapters' read-back, with the error classification the event log keeps:
 * rate_limited (429), timeout (the budget or the call's own timeout), unreachable (network),
 * http_<status> otherwise. Errors carry a code only, never a response body (which could hold data);
 * a 429 also carries the source's rate-limit headers (names with limit, remaining, reset or retry:
 * counts and times, never data), so an adapter can hold its calls until the source's reset.
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

/** fetch → parsed JSON; throws SourceError. The caller passes the budget's signal. */
export async function requestJson(url, { method = "GET", headers = {}, body, signal } = {}) {
  let res;
  try {
    res = await fetch(url, {
      method,
      headers: { accept: "application/json", ...(body !== undefined ? { "content-type": "application/json" } : {}), ...headers },
      body: body !== undefined ? JSON.stringify(body) : undefined,
      signal,
    });
  } catch (err) {
    if (err?.name === "TimeoutError" || err?.name === "AbortError") throw new SourceError("timeout");
    throw new SourceError("unreachable");
  }
  if (res.status === 429) {
    const rateLimit = Object.fromEntries([...res.headers].filter(([k]) => RATE_HEADER.test(k)).map(([k, v]) => [k.toLowerCase(), String(v).slice(0, 40)]));
    await res.body?.cancel().catch(() => undefined);
    throw new SourceError("rate_limited", 429, rateLimit);
  }
  let text;
  try {
    text = await res.text();
  } catch (err) {
    if (err?.name === "TimeoutError" || err?.name === "AbortError") throw new SourceError("timeout");
    throw new SourceError("unreachable");
  }
  // 207 is HubSpot's multi-status for a batch with some ids not found: the body still holds the results
  if (!res.ok && res.status !== 207) throw new SourceError(`http_${res.status}`, res.status);
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    throw new SourceError("bad_response", res.status);
  }
}
