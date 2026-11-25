import { type NextRequest } from "next/server";
import { dateParam, forPrincipal, ok } from "@/lib/api/respond";
import { teamParam } from "@/lib/api/roster";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

type Params = { params: Promise<{ date: string }> };

/**
 * D12 (addition 0009zw): per slot of the planner zone's day, the people working and the people per assignment type and
 * hours market, ?team=<key> or none (cma.roster_slot_coverage); a slot without a block has no row. Needs roster.manage
 */
export async function GET(request: NextRequest, { params }: Params) {
  return forPrincipal(async (me) => {
    const date = dateParam((await params).date, "date");
    return ok(await data().getRosterSlotCoverage(me, date, teamParam(request.nextUrl.searchParams.get("team"))));
  });
}
