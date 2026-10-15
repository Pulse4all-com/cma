/**
 * The same-origin rule for the two plain form posts the app takes, /logout/end and /invite/accept (a form
 * cannot add the x-cma-request header the API's writes require). Pure and without runtime imports, so
 * verify/invitations.mjs tests it.
 */

/**
 * A state-changing form POST must come from this site: Sec-Fetch-Site same-origin, or an Origin whose
 * host is the request's host. Anything else, a malformed Origin included, is refused. Used by
 * /logout/end and /invite/accept, which take plain form posts (no custom header is possible).
 */
export function isSameOriginPost(h: { secFetchSite: string | null; origin: string | null; host: string | null }): boolean {
  if (h.secFetchSite === "same-origin") return true;
  if (h.secFetchSite !== null && h.secFetchSite !== "none") return false;
  if (h.origin === null || h.host === null) return false;
  try {
    return new URL(h.origin).host === h.host;
  } catch {
    return false;
  }
}
