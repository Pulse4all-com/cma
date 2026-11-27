import { assertSameSiteWrite, forPrincipal, jsonBody, ok } from "@/lib/api/respond";
import { teamParam, weekStartParam } from "@/lib/api/roster";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

type Params = { params: Promise<{ weekStart: string }> };

/**
 * Save as standard week (D9): body { team? }. The week replaces the Standard week of the people on its grid; an absence
 * goes along only when its type carries over (D10). Answers the report, one row per day: { userId, date, outcome, reason,
 * blocks, blocksDropped }. Needs roster.manage
 */
export async function POST(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    const weekStart = weekStartParam((await params).weekStart);
    const b = await jsonBody(request);
    return ok(await data().saveStandardWeek(me, weekStart, teamParam(b.team)));
  });
}
