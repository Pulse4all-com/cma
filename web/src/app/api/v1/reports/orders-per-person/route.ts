import { firstOrderParams } from "@/lib/api/first-orders";
import { ApiError, forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { ORDERS_PER_PERSON_KEY, ORDERS_PER_PERSON_PERMISSION } from "@/lib/first-orders";

export const dynamic = "force-dynamic";

/**
 * Orders per person (cma.first_orders_per_person, addition 0008u) for ?from&to (at most 92 days) and the optional
 * &market and &level filters: per person, by name and never ranked, the first orders via the call center credited
 * to them (the owner of the latest assisted touch), per level, with the median days from the first touch; the
 * credited orders of owner ids without a person as one row with how many owner ids that is (never which); `total`.
 * Needs performance.team, and the tenant's reports.per_person holding orders: while it does not, the route is not
 * there (404), as the page and its rail item are not; the database refuses the read as well.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    if (!me.perPerson.includes(ORDERS_PER_PERSON_KEY)) throw new ApiError(404, "not_found", "no such route");
    requireAnyPermission(me, [ORDERS_PER_PERSON_PERMISSION]);
    const { range, filter } = firstOrderParams(new URL(request.url).searchParams);
    return ok(await data().getOrdersPerPerson(me, range, filter));
  });
}
