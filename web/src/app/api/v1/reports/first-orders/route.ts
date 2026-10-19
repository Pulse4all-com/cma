import { firstOrderParams } from "@/lib/api/first-orders";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * First orders (cma.first_orders_report and its companions, addition 0008u) for ?from&to (at most 92 days),
 * &group=day|week|market|level (day when left out) and the optional &market and &level filters: `rows` per group,
 * `total` and `previous` (the previous equal period, like for like) with the first orders via the call center and
 * by self-service, the kinds counted apart and the median days from the first touch; the same per level and per
 * market; `amounts` and `amountsByMarket` per currency (never summed across); `list` (the first orders, newest
 * first, capped by follow_up.list_rows, with the total); `historyStart` and `phoneStart`; the attribution
 * `settings`; and `connected` (false: no order pipeline, no rows, never 0). Needs reports.view or
 * performance.team, here and again in the database. Ids, codes, counts, amounts and times only.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { range, filter, group } = firstOrderParams(new URL(request.url).searchParams);
    return ok(await data().getFirstOrders(me, range, group, filter));
  });
}
