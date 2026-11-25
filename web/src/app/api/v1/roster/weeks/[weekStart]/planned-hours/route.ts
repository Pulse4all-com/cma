import { type NextRequest } from "next/server";
import { forPrincipal, ok } from "@/lib/api/respond";
import { teamParam, weekStartParam } from "@/lib/api/roster";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

type Params = { params: Promise<{ weekStart: string }> };

/**
 * D12 (addition 0009zw): the planned minutes per person, date, assignment type and hours market of the week's current
 * blocks, ?team=<key> or none (cma.roster_planned_hours). A block without a market counts under the person's Default
 * market. Needs roster.manage
 */
export async function GET(request: NextRequest, { params }: Params) {
  return forPrincipal(async (me) => {
    const weekStart = weekStartParam((await params).weekStart);
    return ok(await data().getRosterPlannedHours(me, weekStart, teamParam(request.nextUrl.searchParams.get("team"))));
  });
}
