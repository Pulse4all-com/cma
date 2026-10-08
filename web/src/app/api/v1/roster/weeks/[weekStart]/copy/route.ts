import { assertSameSiteWrite, forPrincipal, jsonBody, ok } from "@/lib/api/respond";
import { teamParam, weekStartParam } from "@/lib/api/roster";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

type Params = { params: Promise<{ weekStart: string }> };

/**
 * Copies the cells of another week into this one: body { team?, from: <Monday> }. A source cell
 * overwrites the target cell, an empty source cell leaves the target alone, the past and people no
 * longer on the grid are skipped. Answers { copied }. Needs roster.manage.
 */
export async function POST(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    const weekStart = weekStartParam((await params).weekStart);
    const b = await jsonBody(request);
    const from = weekStartParam(typeof b.from === "string" ? b.from : null);
    return ok({ copied: await data().copyRosterWeek(me, from, weekStart, teamParam(b.team)) });
  });
}
