import { assertSameSiteWrite, forPrincipal, ok, requireAnyPermission, uuidParam } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ id: string }> };

/**
 * Revokes an open or expired invitation (cma.revoke_invitation); its link stops working and the row stays.
 * Revoking again changes nothing; accepted 409, a role above the caller's ceiling 403, unknown 404. Answers
 * the invitations as the database now holds them, never a token.
 */
export async function POST(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, ["users.manage_agents", "users.manage_all"]);
    const id = uuidParam((await params).id, "id");
    await data().revokeInvitation(me, id);
    return ok(await data().listInvitations(me));
  });
}
