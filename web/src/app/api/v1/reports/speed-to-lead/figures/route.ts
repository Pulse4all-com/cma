import { ApiError, forPrincipal, ok, requireAnyPermission, teamRangeParams } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { MAX_REPORT_DAYS, parseCallsFilter, REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Speed to lead's cockpit figures (cma.speed_to_lead_figures, addition 0009zu) for ?from&to (at most 92 days) and the
 * optional &market (a market code or unknown; anything else 400): the period's and the previous period's (the same
 * length before it, cut at now's time of day while the period reaches today, as Attempts per deal compares) deals,
 * called, % within target, % before the next working day's cutoff, median business minutes, open deals not called yet
 * and the longest wait among them, deals closed before the first call, attempts per deal (mean and median) and the
 * share with a Conversation; with the settings they are shown against (the target, the cutoff, the two goals or null,
 * the stale days). Counts and shares only. Needs reports.view or performance.team, here and again in the database.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const sp = new URL(request.url).searchParams;
    const { from, to } = teamRangeParams(sp, MAX_REPORT_DAYS);
    const { filter, problem } = parseCallsFilter(sp.get("market"), null);
    if (problem === "market") throw new ApiError(400, "invalid_market", "market must be a market code or unknown");
    return ok(await data().getSpeedToLeadFigures(me, { from, to }, filter.market));
  });
}
