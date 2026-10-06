import { ApiError, assertSameSiteWrite, forPrincipal, jsonBody, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * Set the caller's own status on today's workday: body { "key": "<key from /api/v1/me/statuses>" }.
 * Answers the day with its new status. No day today or an unknown key is a 404, an ended day a 409
 * (changing an ended day is a correction). Same guards as /day/end: header x-cma-request: 1 and no
 * cross-site requests.
 */
export async function POST(request: Request) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    const { key } = await jsonBody(request);
    if (typeof key !== "string" || key.length < 1 || key.length > 100) {
      throw new ApiError(400, "invalid_status", "key must be a status key from /api/v1/me/statuses");
    }
    return ok(await data().setStatus(me, key, new Date().toISOString()));
  });
}
