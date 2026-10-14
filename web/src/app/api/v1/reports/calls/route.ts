import { callsParams } from "@/lib/api/calls";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * The calls overview (cma.calls_overview, addition 0008j) for ?from&to (at most 92 days), &group=day|week|
 * market|line (day when left out; anything else 400) and the optional &market and &line filters: per
 * group the calls, inbound and outbound, answered inbound, connected outbound and its share, conversations
 * with their talk time (answer to end, no ringing), the connected outbound calls' talk time and the
 * untagged conversations; `total` over every call (the database's, not a sum), `previous` the same over
 * the previous equal period, `historyStart` the business date of the tenant's earliest stored call
 * (addition 0008k; tenant-wide, null without one: a previous period that starts before it has nothing
 * to compare with), the threshold's seconds, the markets and lines for the filters, and
 * `telephony` (false: no telephony connected, and no rows, never 0). Needs reports.view or
 * performance.team, here and again in the database. No number, no customer name, no call id, never the hash.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { range, filter, group } = callsParams(new URL(request.url).searchParams, true);
    return ok(await data().getCallsOverview(me, range, group, filter));
  });
}
