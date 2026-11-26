import { assertSameSiteWrite, dateParam, forPrincipal, jsonBody, ok, uuidParam } from "@/lib/api/respond";
import { cellParam, teamParam, weekStartParam } from "@/lib/api/roster";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

type Params = { params: Promise<{ weekStart: string }> };

/**
 * Sets one cell of the roster: body { team?, userId, date, cell } with cell as
 * { kind: "shift", start, end, note? }, { kind: "absence", absenceKey, note? } or { kind: "clear" }.
 * The database keeps the history (a new version, the old one ended) and refuses the past, a date
 * outside the week, a person not on the grid and bad times (400), an entry on another roster that
 * day (409), an unknown absence type (404), and a caller without roster.manage (403). Answers the
 * current cell with its blocks and how many blocks ended with a shortened shift (assignments,
 * endedAssignments; addition 0009zx), null after a clear (which ends every block of the day). D8
 * (cma.roster_set_cell): a change to the person's today in a published week publishes the week at
 * once (published: true); while other changes wait it answers { status: "confirm", otherChanges }
 * and writes nothing, until the body says publishOthers: true. Same guards as every write: header
 * x-cma-request: 1, same site.
 */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    const weekStart = weekStartParam((await params).weekStart);
    const b = await jsonBody(request);
    const answer = await data().setRosterEntry(
      me, weekStart, teamParam(b.team), uuidParam(typeof b.userId === "string" ? b.userId : null, "userId"),
      dateParam(typeof b.date === "string" ? b.date : null, "date"), cellParam(b.cell), b.publishOthers === true,
    );
    if (answer.status === "confirm") return ok({ status: "confirm", otherChanges: answer.otherChanges });
    // E5 (addition 0010a): the at-once publication refused while a shift dated today or later has no block; nothing written
    if (answer.status === "refused") return ok({ status: "refused", emptyShifts: answer.emptyShifts }, 409);
    return ok(answer.entry ? { ...answer.entry, assignments: answer.assignments, endedAssignments: answer.endedAssignments, published: answer.published } : null);
  });
}
