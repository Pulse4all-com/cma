import { type NextRequest } from "next/server";
import { ApiError, dateParam, daysInclusive, forPrincipal, ok, uuidParam } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/** At most one quarter per request, as /me/hours */
const MAX_DAYS = 92;

/**
 * Hours per person per day for ?from=YYYY-MM-DD&to=YYYY-MM-DD, optionally &userId=<id> for one
 * person. Needs workday.team, checked by the database (403 without it). Dates are business dates in
 * each day's own zone.
 */
export async function GET(request: NextRequest) {
  return forPrincipal(async (me) => {
    const sp = request.nextUrl.searchParams;
    const from = dateParam(sp.get("from"), "from");
    const to = dateParam(sp.get("to"), "to");
    const days = daysInclusive(from, to);
    if (days < 1) throw new ApiError(400, "invalid_range", "from must not be after to");
    if (days > MAX_DAYS) throw new ApiError(400, "range_too_long", `at most ${MAX_DAYS} days per request`);
    const userId = sp.has("userId") ? uuidParam(sp.get("userId"), "userId") : null;
    return ok(await data().getTeamHours(me, { from, to }, userId));
  });
}
