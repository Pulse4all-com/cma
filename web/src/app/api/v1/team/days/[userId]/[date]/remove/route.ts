import { ApiError, assertSameSiteWrite, dateParam, forPrincipal, jsonBody, ok, uuidParam } from "@/lib/api/respond";
import { REMOVE_REFUSAL } from "@/lib/corrections";
import { data } from "@/lib/data";
import { CmaDbError } from "@/lib/data/errors";

export const dynamic = "force-dynamic";

type Params = { params: Promise<{ userId: string; date: string }> };

/**
 * Remove day (addition 0009g): body { "reason": "…" }. Voids every effective event of the person's day on that
 * date in one correction with the reason (cma.remove_workday); the caller is the approver. The day keeps its
 * events and corrections and is no longer listed. Answers { day, events } as the day now stands: day is null.
 *
 * Keyed by person and date like the day's other routes (the day editor holds no workday id; the database finds
 * the day). 400 a reason outside 3 to 500 characters, 403 without workday.team or for one's own day, 404 no day
 * on that date, 409 day_removed (already removed) or day_open (end the day first). Same guards as the other
 * writes: header x-cma-request: 1 and no cross-site requests.
 */
export async function POST(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    const p = await params;
    const userId = uuidParam(p.userId, "userId");
    const date = dateParam(p.date, "date");
    const body = await jsonBody(request);
    const reason = typeof body.reason === "string" ? body.reason.trim() : "";
    if (reason.length < 3 || reason.length > 500) {
      throw new ApiError(400, "invalid_reason", "reason must be 3 to 500 characters");
    }
    try {
      return ok(await data().removeWorkday(me, userId, date, reason));
    } catch (e) {
      if (e instanceof CmaDbError && e.sqlState === "CMA04" && e.message === REMOVE_REFUSAL.removed) {
        throw new ApiError(409, "day_removed", e.message);
      }
      if (e instanceof CmaDbError && e.sqlState === "CMA04" && e.message === REMOVE_REFUSAL.open) {
        throw new ApiError(409, "day_open", e.message);
      }
      throw e;
    }
  });
}
