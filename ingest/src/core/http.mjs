/**
 * Outbound HTTP for the adapters' read-back, with the error classification the event log keeps:
 * rate_limited (429), timeout (the budget or the call's own timeout), unreachable (network),
 * http_<status> otherwise. Errors carry a code only, never a response body (which could hold data).
 */
export class SourceError extends Error {
  constructor(code, status = null) {
    super(code);
    this.name = "SourceError";
    this.code = code;
    this.status = status;
  }
}

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
    await res.body?.cancel().catch(() => undefined);
    throw new SourceError("rate_limited", 429);
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
