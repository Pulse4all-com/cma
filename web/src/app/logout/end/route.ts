import { getAccess } from "@/lib/auth/identity";
import { data } from "@/lib/data";
import { dateKeyInZone } from "@/lib/time";

/**
 * POST /logout/end: end the caller's workday if it is open, then send the
 * browser to IAP's cookie-clearing address. IAP clears its cookie and lands on
 * /logout/done, which asks for a fresh login (verified parameter:
 * gcp-iap-mode=CLEAR_LOGIN_COOKIE, docs "Using query parameters and headers").
 */
export async function POST(request: Request) {
  // Same-origin only: a cross-site form must not be able to end someone's day
  const site = request.headers.get("sec-fetch-site");
  const origin = request.headers.get("origin");
  const host = request.headers.get("host");
  const sameOrigin = site === "same-origin" || (origin !== null && host !== null && new URL(origin).host === host);
  if (!sameOrigin) return new Response("Forbidden", { status: 403 });

  const access = await getAccess();
  if (access?.kind === "granted") {
    const me = access.principal;
    const today = await data().getWorkday(me, dateKeyInZone(new Date(), me.timeZone));
    if (today?.status === "working") await data().endWorkday(me, new Date().toISOString());
  }

  // Relative Location: request.url carries the container's own host behind the
  // load balancer, not the public domain, so an absolute URL would be wrong
  return new Response(null, {
    status: 303,
    headers: { Location: "/logout/done?gcp-iap-mode=CLEAR_LOGIN_COOKIE" },
  });
}
