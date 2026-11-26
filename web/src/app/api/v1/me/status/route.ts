import { ApiError, assertSameSiteWrite, forPrincipal, jsonBody, ok } from "@/lib/api/respond";
import { hoursMarketOrNull } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * Set the caller's own status, hours market or both on today's workday: body { "key": "<key from /api/v1/me/statuses>",
 * "hoursMarket": "<code>" }, either may be left out or null but not both (addition 0009zo, D3). Without a key the status
 * in force is booked again under the new market; without a market the market in force is kept. Answers the day with its
 * new status and market. No day today, an unknown key or a market the tenant lacks is a 404, a market that is no active
 * hours market a 400, an ended day a 409 (changing an ended day is a correction). Same guards as /day/end: header
 * x-cma-request: 1 and no cross-site requests.
 *
 * Switch (addition 0010a, E6): body { "assignment": "<code>", "hoursMarket": "<code>" } books an active assignment type with
 * its own status, a work or extra type under the market (without one: the person's Default market; none at all is a 400), a
 * pause without a market (a market given: 400); an assignment and a key together are a 400. A key alone in a tenant that
 * has assignment types books a pause status or an Other status (Training, Meeting, Coaching) without a market, and a market
 * alone re-books the assignment in force under it.
 */
export async function POST(request: Request) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    const body = await jsonBody(request);
    const key = body.key === undefined || body.key === null ? null : body.key;
    if (key !== null && (typeof key !== "string" || key.length < 1 || key.length > 100)) {
      throw new ApiError(400, "invalid_status", "key must be a status key from /api/v1/me/statuses");
    }
    const hoursMarket = body.hoursMarket === undefined ? null : hoursMarketOrNull(body.hoursMarket, "hoursMarket");
    const assignment = body.assignment === undefined || body.assignment === null ? null : body.assignment;
    if (assignment !== null && (typeof assignment !== "string" || !/^[A-Za-z0-9]{1,6}$/.test(assignment))) {
      throw new ApiError(400, "invalid_status", "assignment must be an assignment type code from /api/v1/me/day/plan");
    }
    if (assignment !== null && key !== null) throw new ApiError(400, "invalid_status", "an assignment books its own status: give one of key and assignment");
    if (key === null && hoursMarket === null && assignment === null) {
      throw new ApiError(400, "invalid_status", "a change needs an assignment, a key, an hoursMarket or a combination");
    }
    return ok(await data().setStatus(me, { key, hoursMarket, assignment: assignment === null ? null : (assignment as string).toUpperCase() }, new Date().toISOString()));
  });
}
