import { assertSameSiteWrite, forPrincipal, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * Clock in: open the caller's own workday today (increment e, 7 October 2026). Answers the day in
 * every case: opened now, already open, or ended and unchanged (an ended day stays ended; resuming
 * is a correction), so a client compares startedAt rather than status codes. The database creates
 * a day only for someone whose time is kept (workday.own): CMA06 is a 403, never decided here.
 * Same guards as /day/end: header x-cma-request: 1 and no cross-site requests.
 */
export async function POST(request: Request) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    return ok(await data().startWorkday(me, new Date().toISOString()));
  });
}
