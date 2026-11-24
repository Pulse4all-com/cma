import { ApiError, forPrincipal, ok, requireAnyPermission, teamRangeParams } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { MAX_REPORT_DAYS, parseCallsFilter, parseGroup, REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Speed to lead per group (cma.speed_to_lead_summary, migration 0007d; one function since 0009zq) for ?from&to (at most
 * 92 days), &group=day|market|agent|pipeline (day when left out; anything else 400) and the optional &market (a market
 * code or unknown; anything else 400), which narrows every group to the deal's market: deals, called (a first Attempt
 * before the close or the contacts' first order), median and 80th percentile business minutes over the called deals (p80BusinessMinutes is
 * returned, not shown: the screen dropped the column on 15 October 2026), % within target and % before the next
 * working day's cutoff over the deals whose outcome is known, open not called yet, and closedBeforeFirstCall (closed
 * or ordered before any attempt, in neither share nor the median); and nextDayCutoff, the tenant's
 * speed_to_lead.next_day_cutoff (HH:MM) the cutoff share is measured against. Needs reports.view or performance.team, here and again in the
 * database. A caller whose phone user is not mapped is the key "unknown" with a null label; the deals without an
 * attempt the key "no_attempt" with a null label.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const sp = new URL(request.url).searchParams;
    const { from, to } = teamRangeParams(sp, MAX_REPORT_DAYS);
    const group = sp.has("group") ? parseGroup(sp.get("group")) : "day";
    if (!group) throw new ApiError(400, "invalid_group", "group must be day, market, agent or pipeline");
    const { filter, problem } = parseCallsFilter(sp.get("market"), null);
    if (problem === "market") throw new ApiError(400, "invalid_market", "market must be a market code or unknown");
    return ok(await data().getSpeedToLeadSummary(me, { from, to }, group, filter.market));
  });
}
