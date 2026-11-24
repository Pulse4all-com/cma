import { ApiError, forPrincipal, ok, requireAnyPermission, teamRangeParams } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { MAX_REPORT_DAYS, parseCallsFilter, parseSpeedView, REPORT_PERMISSIONS, SPEED_DEALS_PAGE } from "@/lib/reports";

export const dynamic = "force-dynamic";

/** A whole number from a query parameter within its bounds, its default when left out; anything else 400 */
function intParam(sp: URLSearchParams, name: string, min: number, max: number, fallback: number): number {
  const v = sp.get(name);
  if (v === null) return fallback;
  if (!/^[0-9]{1,6}$/.test(v) || Number(v) < min || Number(v) > max) throw new ApiError(400, `invalid_${name}`, `${name} must be a whole number from ${min} to ${max}`);
  return Number(v);
}

/**
 * Speed to lead's deals list (cma.speed_to_lead_deals_of, addition 0009zr) for ?from&to (at most 92 days), the optional
 * &market (a market code or unknown), &view=not_called|called (not_called when left out), &limit (1 to 200, 50) and
 * &offset (0 or more, 0); anything else 400. Newest created first: per deal its ids and record link, market, pipeline,
 * creation, status, the business seconds (to the first attempt, or waited so far), within target, before the cutoff and
 * the cutoff's moment, the owner as a person, the attempts so far and the first 20 of them (start, business seconds
 * after creation, connected, talk seconds, conversation, the tags' meaning keys, the agent as a person), stale, and the
 * timeline's scales; total is the view's count. No phone number, recording, customer name or email; a tag by its meaning
 * only. Needs reports.view or performance.team, here and again in the database.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const sp = new URL(request.url).searchParams;
    const { from, to } = teamRangeParams(sp, MAX_REPORT_DAYS);
    const { filter, problem } = parseCallsFilter(sp.get("market"), null);
    if (problem === "market") throw new ApiError(400, "invalid_market", "market must be a market code or unknown");
    const view = sp.has("view") ? parseSpeedView(sp.get("view")) : "not_called";
    if (!view) throw new ApiError(400, "invalid_view", "view must be not_called or called");
    const limit = intParam(sp, "limit", 1, 200, SPEED_DEALS_PAGE);
    const offset = intParam(sp, "offset", 0, 100_000, 0);
    return ok(await data().getSpeedToLeadDeals(me, { from, to }, filter.market, view, limit, offset));
  });
}
