/**
 * Where Log out sends the browser (README, Authentication; Decision log 5 and 15 October 2026). Pure and
 * without runtime imports, so verify/signed-out.mjs tests it without a server.
 *
 *   legacy      /logout/done?gcp-iap-mode=CLEAR_LOGIN_COOKIE: IAP clears its cookie and lands on a page of
 *               the app, behind IAP, which signs a browser with one Google account straight back in
 *   signed-out  /signed-out?gcp-iap-mode=CLEAR_LOGIN_COOKIE: the load balancer sends this one address to
 *               cma-web-backend, IAP clears its cookie and redirects to /signed-out, which the load balancer
 *               serves from the public bucket outside IAP (docs/signed-out/README.md); so nothing signs the
 *               browser in again until the person chooses Log in
 *
 * Both are relative: behind the load balancer the request's own host is the container's, not the public
 * domain. signed-out works only once the bucket and the URL map's route rules exist (docs/signed-out).
 */
export type LogoutTarget = "legacy" | "signed-out";

export const LOGOUT_TARGETS: readonly LogoutTarget[] = ["legacy", "signed-out"];
const CLEAR = "gcp-iap-mode=CLEAR_LOGIN_COOKIE";

/** CMA_LOGOUT_TARGET: unset or empty is legacy; anything else must be one of the two (a typo stops the app, as the other modes do) */
export function parseLogoutTarget(raw: string | undefined): LogoutTarget {
  if (raw === undefined || raw === "") return "legacy";
  if ((LOGOUT_TARGETS as readonly string[]).includes(raw)) return raw as LogoutTarget;
  throw new Error(`CMA_LOGOUT_TARGET must be one of ${LOGOUT_TARGETS.join(", ")}, got "${raw}"`);
}

/** The relative Location of the 303 after /logout/end */
export function logoutLocation(target: LogoutTarget): string {
  return target === "signed-out" ? `/signed-out?${CLEAR}` : `/logout/done?${CLEAR}`;
}

/** "Use another account" on No access yet and the invitation page: the signed-out page, only when it exists */
export function switchAccountHref(target: LogoutTarget): string | null {
  return target === "signed-out" ? `/signed-out?${CLEAR}` : null;
}
