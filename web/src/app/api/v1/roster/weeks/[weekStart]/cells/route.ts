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
 * current cell, null after a clear. Same guards as every write: header x-cma-request: 1, same site.
 */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    const weekStart = weekStartParam((await params).weekStart);
    const b = await jsonBody(request);
    const entry = await data().setRosterEntry(
      me, weekStart, teamParam(b.team), uuidParam(typeof b.userId === "string" ? b.userId : null, "userId"),
      dateParam(typeof b.date === "string" ? b.date : null, "date"), cellParam(b.cell),
    );
    return ok(entry);
  });
}
