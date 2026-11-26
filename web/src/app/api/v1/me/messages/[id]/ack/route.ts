import { assertSameSiteWrite, forPrincipal, ok, uuidParam } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * Acknowledges one of the caller's own messages (the urgent pop-up's Confirm); acknowledging also
 * reads it, and a second acknowledgement changes nothing. A message not delivered to the caller is
 * a 404, the database's answer (CMA02). Answers the caller's unread count after it, from the same transaction (night N07,
 * D3), so the inbox and the top bar take it without another read.
 */
type Params = { params: Promise<{ id: string }> };

export async function POST(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    const { id } = await params;
    const { unreadCount } = await data().acknowledgeMessage(me, uuidParam(id, "id"));
    return ok({ acknowledged: true, unreadCount });
  });
}
