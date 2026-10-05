import { type NextRequest } from "next/server";
import { dateParam, forPrincipal, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { dateKeyInZone } from "@/lib/time";

export const dynamic = "force-dynamic";

/**
 * The caller's own workday for ?date=YYYY-MM-DD, default today in the caller's zone.
 * Reading never clocks in: only the login (opening the app) opens a day. data is null when
 * there is no workday on that date.
 */
export async function GET(request: NextRequest) {
  return forPrincipal(async (me) => {
    const raw = request.nextUrl.searchParams.get("date");
    const date = raw === null ? dateKeyInZone(new Date().toISOString(), me.timeZone) : dateParam(raw, "date");
    return ok(await data().getWorkday(me, date));
  });
}
