import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * The Live board's inbound part (addition 0008i): today's inbound in the tenant's zone with the calls
 * waiting now (cma.inbound_today), the missed calls not called back, one per caller, oldest first, each
 * with its line, market, reason, time, waiting time, times missed and the record link when the
 * connection has a record_url_call template (cma.missed_callbacks), the anonymous missed calls as a
 * count and the lookback in days. `telephony` false: no telephony connected. Needs monitoring.live, here
 * and again in the database. No number, no name, never the caller's hash. Named after the data.
 */
export async function GET() {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, ["monitoring.live"]);
    return ok(await data().getInboundNow(me));
  });
}
