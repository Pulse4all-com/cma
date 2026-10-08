import { type NextRequest } from "next/server";
import { forPrincipal, ok, teamRangeParams } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

const MAX_DAYS = 92;

/**
 * The caller's own schedule for ?from=&to=: one row per date with the published entry, or none,
 * and whether a published roster covers the person that day. Published entries only, the person's
 * own, never a colleague's (cma.my_roster, roster.view). At most 92 days.
 */
export async function GET(request: NextRequest) {
  return forPrincipal(async (me) => {
    const { from, to } = teamRangeParams(request.nextUrl.searchParams, MAX_DAYS);
    return ok(await data().getMyRoster(me, { from, to }));
  });
}
