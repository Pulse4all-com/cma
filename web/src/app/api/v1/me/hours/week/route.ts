import { type NextRequest } from "next/server";
import { ApiError, dateParam, forPrincipal, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { dateKeyInZone, startOfWeek } from "@/lib/time";

export const dynamic = "force-dynamic";

/**
 * The caller's own hours of one ISO week, ?week=YYYY-MM-DD (a Monday; default this week in the caller's zone), per
 * assignment and market (cma.my_hours, addition 0010a, E11): the week's rows and pauses, per day the Actual lane and the
 * split, the planned minutes. Read only: corrections are made in Team hours. Needs workday.own (403 from the database).
 */
export async function GET(request: NextRequest) {
  return forPrincipal(async (me) => {
    const raw = request.nextUrl.searchParams.get("week");
    const week = raw === null ? startOfWeek(dateKeyInZone(new Date().toISOString(), me.timeZone)) : dateParam(raw, "week");
    if (startOfWeek(week) !== week) throw new ApiError(400, "invalid_week", "week must be a Monday");
    return ok(await data().getMyHoursWeek(me, week));
  });
}
