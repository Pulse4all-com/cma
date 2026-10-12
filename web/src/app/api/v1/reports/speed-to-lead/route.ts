import { ApiError, forPrincipal, ok, requireAnyPermission, teamRangeParams } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { MAX_REPORT_DAYS, parseGroup, REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Speed to lead per group (cma.speed_to_lead_summary, migration 0007d) for ?from&to (at most 92 days)
 * and &group=day|market|agent|pipeline (day when left out; anything else 400): deals, called, median
 * and 80th percentile business minutes over the called deals, % within target and % before the next
 * noon over the deals whose outcome is known, open not called. Needs reports.view or performance.team,
 * here and again in the database. An agent who is not mapped is the key "unknown" with a null label.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const sp = new URL(request.url).searchParams;
    const { from, to } = teamRangeParams(sp, MAX_REPORT_DAYS);
    const group = sp.has("group") ? parseGroup(sp.get("group")) : "day";
    if (!group) throw new ApiError(400, "invalid_group", "group must be day, market, agent or pipeline");
    return ok(await data().getSpeedToLeadSummary(me, { from, to }, group));
  });
}
