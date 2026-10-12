import { ApiError, assertSameSiteWrite, forPrincipal, jsonBody, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { parseIds } from "@/lib/messages";

export const dynamic = "force-dynamic";

/**
 * Marks the caller's own deliveries read: body { "ids": ["<message id>", …] }. Ids of messages not
 * delivered to the caller and rows already read change nothing; the answer says how many did.
 * Same guards as every write: header x-cma-request: 1 and no cross-site requests.
 */
export async function POST(request: Request) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    const ids = parseIds(await jsonBody(request));
    if (!ids.ok) throw new ApiError(400, ids.code, ids.message);
    return ok({ changed: await data().markMessagesRead(me, ids.value) });
  });
}
