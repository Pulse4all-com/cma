import { type NextRequest } from "next/server";
import { ApiError, dateParam, daysInclusive, forPrincipal, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/** At most one quarter per request: hours are read per pay period, never in bulk */
const MAX_DAYS = 92;

/** The caller's own hours per day for ?from=YYYY-MM-DD&to=YYYY-MM-DD (dates in the caller's zone) */
export async function GET(request: NextRequest) {
  return forPrincipal(async (me) => {
    const from = dateParam(request.nextUrl.searchParams.get("from"), "from");
    const to = dateParam(request.nextUrl.searchParams.get("to"), "to");
    const days = daysInclusive(from, to);
    if (days < 1) throw new ApiError(400, "invalid_range", "from must not be after to");
    if (days > MAX_DAYS) throw new ApiError(400, "range_too_long", `at most ${MAX_DAYS} days per request`);
    return ok(await data().getHours(me, { from, to }));
  });
}
