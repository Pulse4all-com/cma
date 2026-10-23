import { funnelParams } from "@/lib/api/funnel";
import { ApiError, forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { DEALS_PER_PERSON_KEY, DEALS_PER_PERSON_PERMISSION } from "@/lib/funnel";

export const dynamic = "force-dynamic";

/**
 * Deals per person (cma.deals_per_person_page, addition 0008zb) for ?from&to (at most 92 days) and the optional &market,
 * &pipeline and &source filters: per deal owner, by name and never ranked, the sales deals won and lost in the period
 * (by close date) and the amount won per currency, never added up across currencies; the deals of owner ids without a
 * person (or without an owner) as one row with how many owner ids that is (never which); `total`. Needs
 * performance.team, and the tenant's reports.per_person holding deals: while it does not, the route is not there (404),
 * as the section on Reports → Funnel is not; the database refuses the read as well.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    if (!me.perPerson.includes(DEALS_PER_PERSON_KEY)) throw new ApiError(404, "not_found", "no such route");
    requireAnyPermission(me, [DEALS_PER_PERSON_PERMISSION]);
    const { range, filter } = funnelParams(new URL(request.url).searchParams);
    return ok(await data().getDealsPerPerson(me, range, filter));
  });
}
