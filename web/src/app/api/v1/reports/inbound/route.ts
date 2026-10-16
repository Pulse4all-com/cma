import { ApiError, forPrincipal, ok, requireAnyPermission, teamRangeParams } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { MAX_REPORT_DAYS, parseInboundGroup, REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Inbound service per group (cma.inbound_service, addition 0008i) for ?from&to (at most 92 days) and
 * &group=day|market|line|hour (day when left out; anything else 400): offered, answered, unanswered and
 * waiting calls, answered within the service level and its denominator, the service level, the average
 * and 80th percentile time to answer (p80AnswerSeconds is returned, not shown: the screen dropped the column on 15 October 2026) and the unanswered calls per reason code; the total over every call
 * (the database's, not a sum), the tenant's missed-reason catalog for the labels, the service level's
 * seconds and `telephony` (false: no telephony connected, and no rows, never 0). Needs reports.view or
 * performance.team, here and again in the database. No number, no name, never the caller's hash.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const sp = new URL(request.url).searchParams;
    const { from, to } = teamRangeParams(sp, MAX_REPORT_DAYS);
    const group = sp.has("group") ? parseInboundGroup(sp.get("group")) : "day";
    if (!group) throw new ApiError(400, "invalid_group", "group must be day, market, line or hour");
    return ok(await data().getInboundService(me, { from, to }, group));
  });
}
