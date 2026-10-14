import { assertSameSiteWrite, forPrincipal, ok, requireAnyPermission, uuidParam } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ id: string }> };

/**
 * A new link for an open or expired invitation (cma.renew_invitation): a new token, the old one stops working,
 * the expiry starts again and the caller becomes the inviter of the link. Answers { invitationId, token,
 * expiresAt }; accepted or revoked 409, a role above the caller's ceiling 403, unknown 404.
 */
export async function POST(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, ["users.manage_agents", "users.manage_all"]);
    const id = uuidParam((await params).id, "id");
    return ok(await data().renewInvitation(me, id));
  });
}
