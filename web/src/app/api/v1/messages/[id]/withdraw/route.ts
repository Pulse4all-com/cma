import { assertSameSiteWrite, forPrincipal, ok, requireAnyPermission, uuidParam } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { WITHDRAW_PERMISSION } from "@/lib/messages";

export const dynamic = "force-dynamic";

/**
 * Withdraws (deletes for everyone) a message of the tenant, manual or alert (cma.withdraw_message, addition 0008z): the
 * message keeps its row and its audit, gets withdrawn_at and withdrawn_by, and no recipient sees it again on Messages or in
 * the top bar's inbox; a delivery not yet made never happens. A second withdrawal changes nothing and answers the first
 * time. Needs messages.withdraw (a 403 here and in the database, CMA06); an unknown or another tenant's message is a 404
 * (CMA02). Answers { withdrawnAt }.
 */
type Params = { params: Promise<{ id: string }> };

export async function POST(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, [WITHDRAW_PERMISSION]);
    const { id } = await params;
    return ok(await data().withdrawMessage(me, uuidParam(id, "id")));
  });
}
