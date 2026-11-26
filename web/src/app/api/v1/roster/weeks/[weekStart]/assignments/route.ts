import { type NextRequest } from "next/server";
import { assertSameSiteWrite, dateParam, forPrincipal, jsonBody, ok, uuidParam } from "@/lib/api/respond";
import { blocksParam, teamParam, weekStartParam } from "@/lib/api/roster";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

type Params = { params: Promise<{ weekStart: string }> };

/**
 * The week's current blocks (addition 0009zx), ?team=<key> or none for the whole tenant: the planner's week answer's
 * assignments alone. Needs roster.manage (403 from the database)
 */
export async function GET(request: NextRequest, { params }: Params) {
  return forPrincipal(async (me) => {
    const weekStart = weekStartParam((await params).weekStart);
    return ok((await data().getRosterWeek(me, weekStart, teamParam(request.nextUrl.searchParams.get("team")))).assignments);
  });
}

/**
 * Replaces a person-date's blocks: body { team?, userId, date, blocks: [{ code, start, end, hoursMarket?, note? }], publishOthers? }
 * (cma.roster_set_assignments, D1, D6, D7). Refuses overlap, the grid, outside the shift, a market that is no hours market,
 * the past and a person not on the roster (400), an unknown type or market (404), another roster's shift (409), a caller
 * without roster.manage (403). Answers { status: "saved", kept, ended, added, published, version, blocks }; for today in a
 * published week with other unpublished changes { status: "confirm", otherChanges } until publishOthers is true (D8).
 * Since addition 0010a a block is { absence: "<key>", start, end, note? } for an absence block (E9), a work block written
 * without hoursMarket takes the person's Default market (E10; none: 400), and the at-once publication of today answers 409
 * { status: "refused", emptyShifts: [{ userId, date }] } while a shift of the week dated today or later has no block (E5).
 * Same guards as every write: header x-cma-request: 1, same site
 */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    const weekStart = weekStartParam((await params).weekStart);
    const b = await jsonBody(request);
    const answer = await data().setRosterAssignments(
      me, weekStart, teamParam(b.team), uuidParam(typeof b.userId === "string" ? b.userId : null, "userId"),
      dateParam(typeof b.date === "string" ? b.date : null, "date"), blocksParam(b.blocks), b.publishOthers === true,
    );
    // E5 (addition 0010a): the at-once publication refused while a shift dated today or later has no block; nothing written
    return ok(answer, answer.status === "refused" ? 409 : 200);
  });
}
