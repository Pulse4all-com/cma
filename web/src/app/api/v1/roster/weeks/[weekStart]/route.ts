import { type NextRequest } from "next/server";
import { forPrincipal, ok } from "@/lib/api/respond";
import { teamParam, weekStartParam } from "@/lib/api/roster";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

type Params = { params: Promise<{ weekStart: string }> };

/**
 * The planner's week: ?team=<key> or none for the whole tenant. Answers { header, people, entries,
 * coverage }: the state of the roster, the people on its grid, the current cells and the planned
 * coverage per work type per day. Needs roster.manage (403 from the database).
 */
export async function GET(request: NextRequest, { params }: Params) {
  return forPrincipal(async (me) => {
    const weekStart = weekStartParam((await params).weekStart);
    return ok(await data().getRosterWeek(me, weekStart, teamParam(request.nextUrl.searchParams.get("team"))));
  });
}
