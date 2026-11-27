/**
 * Every request the browser sends to the Workspace's own routes (polls, writes, the navigation beacon) goes through
 * clientFetch (brief N07, WP8, 25 November 2026).
 *
 * X-Requested-With: XMLHttpRequest makes IAP answer a sign-in that ended with 401 instead of a redirect to Google's
 * sign-in page, which a fetch would follow into an unreadable answer. A 401 means the tab no longer has a signed-in
 * person, whoever answered it (IAP, which marks its own with X-Goog-IAP-Generated-Response, or proxy.ts, or a route's
 * own not_authenticated): the tab is marked signed out once, the event SESSION_EXPIRED_EVENT tells SessionExpiredNotice to
 * show its notice, and from then on no request leaves the tab: clientFetch answers 401 itself, so every poll stops
 * reaching the server (LiveRefresh stops as well). Nothing reloads by itself: a tab that reloaded on its own after Log
 * out would sign the person in again on a shared computer; the notice's button reloads on a click. ("Session" in the
 * code's names means the sign-in; in the Workspace's words a session is a stretch of a workday, docs/definitions.md.)
 */
export const REQUESTED_WITH = { name: "X-Requested-With", value: "XMLHttpRequest" } as const;
export const SESSION_EXPIRED_EVENT = "cma:session-expired";

let expired = false;

/** True once a request of this tab was answered 401 */
export function sessionExpired(): boolean {
  return expired;
}

function markExpired(): void {
  if (expired) return;
  expired = true;
  if (typeof window !== "undefined") window.dispatchEvent(new Event(SESSION_EXPIRED_EVENT));
}

/** fetch with X-Requested-With, the 401 rule above and nothing else changed (same arguments, same answer) */
export async function clientFetch(input: RequestInfo | URL, init: RequestInit = {}): Promise<Response> {
  if (expired) return new Response(null, { status: 401, statusText: "Signed out" });
  const headers = new Headers(init.headers);
  headers.set(REQUESTED_WITH.name, REQUESTED_WITH.value);
  const res = await fetch(input, { ...init, headers });
  if (res.status === 401) markExpired();
  return res;
}

/** For the verifier only: a fresh tab */
export function resetSessionForTest(): void {
  expired = false;
}
