import { type NextRequest } from "next/server";
import { dateParam, forPrincipal, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { dateKeyInZone } from "@/lib/time";

export const dynamic = "force-dynamic";

/**
 * The caller's own My day for ?date=YYYY-MM-DD, default today in the caller's zone (cma.my_day, addition 0010a, brief B):
 * { workday, plan } where plan holds the published shift and blocks (Scheduled), the day's stretches (Actual), the own
 * switches that deviate, the block in force now and the next, the roster switch notice (E3), Off plan (E7) and the Switch
 * choices (E6). Reading never clocks in. Needs workday.own (403 from the database).
 */
export async function GET(request: NextRequest) {
  return forPrincipal(async (me) => {
    const raw = request.nextUrl.searchParams.get("date");
    const date = raw === null ? dateKeyInZone(new Date().toISOString(), me.timeZone) : dateParam(raw, "date");
    return ok(await data().getMyDay(me, date));
  });
}
