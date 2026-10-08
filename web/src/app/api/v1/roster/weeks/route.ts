import { type NextRequest } from "next/server";
import { forPrincipal, ok, teamRangeParams } from "@/lib/api/respond";
import { teamParam } from "@/lib/api/roster";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/** At most two years of weeks per request */
const MAX_DAYS = 732;

/**
 * The weeks of a roster for browsing: ?team=<key> (or none for the whole tenant), from and to as
 * dates; one row per week that has been written, with its state, version and counts. Needs
 * roster.manage (403 from the database). Named after the data (migration 0005).
 */
export async function GET(request: NextRequest) {
  return forPrincipal(async (me) => {
    const sp = request.nextUrl.searchParams;
    const { from, to } = teamRangeParams(sp, MAX_DAYS);
    return ok(await data().listRosterWeeks(me, teamParam(sp.get("team")), { from, to }));
  });
}
