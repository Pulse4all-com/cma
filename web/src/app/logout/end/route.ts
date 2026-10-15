import { getAccess } from "@/lib/auth/identity";
import { PREVIEW_COOKIE } from "@/lib/auth/preview";
import { config } from "@/lib/config";
import { data } from "@/lib/data";
import { logoutLocation } from "@/lib/logout";
import { isSameOriginPost } from "@/lib/origin";
import { dateKeyInZone } from "@/lib/time";

/**
 * POST /logout/end: end the caller's workday if it is open, then send the browser to IAP's cookie-clearing
 * address (verified parameter: gcp-iap-mode=CLEAR_LOGIN_COOKIE, docs "Using query parameters and headers").
 * Where IAP lands afterwards follows CMA_LOGOUT_TARGET (src/lib/logout.ts): /logout/done (legacy, the
 * default) or the static signed-out page outside IAP.
 */
export async function POST(request: Request) {
  // Same-origin only: a cross-site form must not be able to end someone's day
  if (!isSameOriginPost({
    secFetchSite: request.headers.get("sec-fetch-site"),
    origin: request.headers.get("origin"),
    host: request.headers.get("host"),
  })) return new Response("Forbidden", { status: 403 });

  const access = await getAccess();
  if (access?.kind === "granted") {
    const me = access.principal;
    const today = await data().getWorkday(me, dateKeyInZone(new Date(), me.timeZone));
    if (today?.status === "working") await data().endWorkday(me, new Date().toISOString());
  }

  // Relative Location: request.url carries the container's own host behind the
  // load balancer, not the public domain, so an absolute URL would be wrong
  const res = new Response(null, { status: 303, headers: { Location: logoutLocation(config.logoutTarget) } });
  // A preview as role never outlives the session (16 October 2026): Log out clears its cookie with the day
  res.headers.append("Set-Cookie", `${PREVIEW_COOKIE}=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax`);
  return res;
}
