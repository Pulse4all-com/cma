import { ApiError, forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * The Live board's inbound part (addition 0008i): today's inbound in the tenant's zone with, since addition 0009k, the
 * talk time of today's answered inbound calls (inboundTalkSeconds, over the same calls as the other figures: those
 * started in the tenant's day; in place of waitingNow) (cma.inbound_now), the missed calls not called back, one per caller, oldest first, each
 * with its line, market, reason, time, waiting time, times missed and the record link when the
 * connection has a record_url_call template (cma.missed_callbacks), the anonymous missed calls as a
 * count and the lookback in days. `telephony` false: no telephony connected. Needs monitoring.live, here
 * and again in the database. No number, no name, never the caller's hash. Named after the data.
 *
 * Since addition 0009q (cma.inbound_now_first): `callbacksTotal` is how many callers the list holds; ?first=<n> answers
 * the oldest n of them alone (0: their count and no caller; a whole number from 0 to 10000, else 400 invalid_first);
 * without it every caller, as before.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, ["monitoring.live"]);
    const raw = new URL(request.url).searchParams.get("first");
    if (raw !== null && !/^(0|[1-9][0-9]{0,3}|10000)$/.test(raw)) throw new ApiError(400, "invalid_first", "first takes a whole number from 0 to 10000");
    return ok(await data().getInboundNow(me, raw === null ? null : Number(raw)));
  });
}
