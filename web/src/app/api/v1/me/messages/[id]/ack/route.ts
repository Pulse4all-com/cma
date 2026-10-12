import { assertSameSiteWrite, forPrincipal, ok, uuidParam } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * Acknowledges one of the caller's own messages (the urgent pop-up's Confirm); acknowledging also
 * reads it, and a second acknowledgement changes nothing. A message not delivered to the caller is
 * a 404, the database's answer (CMA02).
 */
type Params = { params: Promise<{ id: string }> };

export async function POST(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    const { id } = await params;
    await data().acknowledgeMessage(me, uuidParam(id, "id"));
    return ok({ acknowledged: true });
  });
}
