import { assertSameSiteWrite, forPrincipal, jsonBody, ok } from "@/lib/api/respond";
import { teamParam, weekStartParam } from "@/lib/api/roster";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

type Params = { params: Promise<{ weekStart: string }> };

/**
 * Publishes the week as it stands: body { team? }. Answers the header with its new version. Needs roster.manage. Since
 * addition 0010a (E5) it refuses while a shift of the week dated today or later holds no block: 409
 * { status: "refused", emptyShifts: [{ userId, date }] }, and nothing is published.
 */
export async function POST(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    const weekStart = weekStartParam((await params).weekStart);
    const b = await jsonBody(request);
    const answer = await data().publishRoster(me, weekStart, teamParam(b.team));
    return answer.status === "published" ? ok(answer.header) : ok({ status: "refused", emptyShifts: answer.emptyShifts }, 409);
  });
}
