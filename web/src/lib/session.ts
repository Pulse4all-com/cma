/**
 * Welcome on open (addition 0008z, Martin 20 October 2026): the Workspace opens on Welcome (/), whichever way it is
 * opened: after signing in, from the root address, from the installed app (the manifest's start_url is /) and in a new
 * browser session. The browser session is the cookie `cma-session` (no Max-Age, so it ends with the browser session;
 * HttpOnly, no personal data: its value is 1). A page opened as a document without it goes to / with a 303, and / sets
 * it; from then on every address opens as asked, so a deep link while signed in still works. Log out expires it, so the
 * next sign-in starts on Welcome. There is no "return to the last page" anywhere: the app never stores where a person was.
 *
 * Not redirected: anything but a GET document navigation (fetches, RSC requests and prefetches, API calls, assets), the
 * API, an invitation's address (/invite/...), the Log out pages (/logout/...) and No access yet, which work without a
 * session. In mock mode a request carrying x-cma-mock-subject (the verifiers) and ?as= (its 303 keeps the path and starts
 * the session) are not redirected either.
 *
 * Signing in today is IAP's (README, Authentication): Google sends the browser back to the address it asked for, and in a
 * new browser session that address is answered with the 303 to Welcome. A sign-in of the CMA's own later (an OAuth
 * callback for a tenant's identity provider) must send to / after its callback and must not keep a return address.
 * No runtime imports, so verify/signed-out.mjs runs it without a server.
 */
export const SESSION_COOKIE = "cma-session";

/** The cookie as Set-Cookie writes it: a session cookie, path /, HttpOnly, Secure, SameSite=Lax */
export const SESSION_COOKIE_OPTIONS = { httpOnly: true, sameSite: "lax", secure: true, path: "/" } as const;

/** The header that expires it, as Log out sends it */
export const SESSION_COOKIE_CLEAR = `${SESSION_COOKIE}=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax`;

/** Paths that work without a browser session: the API, an invitation, the Log out pages, No access yet */
const OPEN_PATHS = [/^\/api(\/|$)/, /^\/invite(\/|$)/, /^\/logout(\/|$)/, /^\/no-access(\/|$)/];

export interface OpenRequest {
  method: string;
  pathname: string;
  /** Sec-Fetch-Dest, null when the client sends none */
  fetchDest: string | null;
  accept: string | null;
  /** The request carries Next's RSC or prefetch header */
  rsc: boolean;
  hasSession: boolean;
  /** Mock mode and the verifiers' x-cma-mock-subject header */
  mockHeader: boolean;
}

/** A browser loading a page: a GET whose destination is a document (or, without Sec-Fetch-Dest, that asks for HTML) */
export function isDocumentNavigation(r: Pick<OpenRequest, "method" | "fetchDest" | "accept" | "rsc">): boolean {
  if (r.method !== "GET" || r.rsc) return false;
  if (r.fetchDest !== null) return r.fetchDest === "document";
  return (r.accept ?? "").toLowerCase().startsWith("text/html");
}

/**
 * What the gate does with a request once its identity is known: "welcome" sends it to / with a 303, "start" passes it and
 * sets the session cookie (Welcome itself), "pass" passes it as it is
 */
export function onOpen(r: OpenRequest): "welcome" | "start" | "pass" {
  if (r.hasSession || r.mockHeader || !isDocumentNavigation(r)) return "pass";
  if (r.pathname === "/") return "start";
  if (OPEN_PATHS.some((re) => re.test(r.pathname))) return "pass";
  return "welcome";
}
