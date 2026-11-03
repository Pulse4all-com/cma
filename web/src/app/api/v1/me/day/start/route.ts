import { assertSameSiteWrite, forPrincipal, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * Clock in: open the caller's own workday today (increment e, 7 October 2026). Answers the day in
 * every case: opened now, already open, clocked in again (addition 0008zp: an ended day the person
 * may clock in again on, canClockInAgain, gets a new session and comes back open with startedAt
 * unchanged, sessionStartedAt new and sessions one more), or ended and unchanged (outside that rule
 * an ended day stays ended; resuming is a correction), so a client compares the day's fields rather
 * than status codes. The database creates a day only for someone whose time is kept (workday.own):
 * CMA06 is a 403, never decided here. Same guards as /day/end: header x-cma-request: 1 and no
 * cross-site requests.
 */
export async function POST(request: Request) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    return ok(await data().startWorkday(me, new Date().toISOString()));
  });
}
