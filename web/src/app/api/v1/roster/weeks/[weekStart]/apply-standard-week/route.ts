import { assertSameSiteWrite, forPrincipal, jsonBody, ok } from "@/lib/api/respond";
import { teamParam, weekStartParam } from "@/lib/api/roster";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

type Params = { params: Promise<{ weekStart: string }> };

/**
 * Apply standard week (D9): body { team? }. Fills the week's empty person-dates from the Standard week with their blocks
 * and never overwrites. Answers the report: { userId, date, outcome, reason, blocks, blocksDropped } per day, the reason
 * past, not_empty, other_roster, absence_not_carried or blocks_dropped. Needs roster.manage
 */
export async function POST(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    const weekStart = weekStartParam((await params).weekStart);
    const b = await jsonBody(request);
    return ok(await data().applyStandardWeek(me, weekStart, teamParam(b.team)));
  });
}
