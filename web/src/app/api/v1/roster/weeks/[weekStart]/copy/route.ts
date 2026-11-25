import { assertSameSiteWrite, forPrincipal, jsonBody, ok } from "@/lib/api/respond";
import { teamParam, weekStartParam } from "@/lib/api/roster";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

type Params = { params: Promise<{ weekStart: string }> };

/**
 * Copies the cells of another week into this one: body { team?, from: <Monday> }. A source shift
 * overwrites the target cell with its blocks; an absence goes along only when its type carries over
 * (D10, addition 0009zw); an empty source cell leaves the target alone; the past, people no longer on
 * the grid and people planned on another roster are skipped. Answers { copied, report }, the report one
 * row per source cell: { userId, date, outcome, reason, blocks, blocksDropped }. Needs roster.manage.
 */
export async function POST(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    const weekStart = weekStartParam((await params).weekStart);
    const b = await jsonBody(request);
    const from = weekStartParam(typeof b.from === "string" ? b.from : null);
    const report = await data().copyRosterWeek(me, from, weekStart, teamParam(b.team));
    return ok({ copied: report.filter((r) => r.outcome === "done").length, report });
  });
}
