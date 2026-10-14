import { ApiError, assertSameSiteWrite, forPrincipal, jsonBody, ok, requireAnyPermission } from "@/lib/api/respond";
import { copy } from "@/lib/copy";
import { data } from "@/lib/data";
import { parseInvitationInput } from "@/lib/invitations";

export const dynamic = "force-dynamic";

const PEOPLE = ["users.manage_agents", "users.manage_all"] as const;

/**
 * Invitations by email (addition 0008l). GET lists the invitations the caller may see (users.manage_all
 * every one, users.manage_agents those for a role they may grant), with their state; never a token. The
 * permission is checked here first and again by the database in the same transaction (CMA06 → 403).
 */
export async function GET() {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, PEOPLE);
    return ok(await data().listInvitations(me));
  });
}

/**
 * A new invitation: { email, displayName, locale, roleKey, organisationKey, teamKeys?, skills? }. Answers
 * { invitationId, token, expiresAt } with 201: the only answer besides renew that carries a token, which the
 * screen turns into the link. Shape checks here; the role ceiling, the system role, the catalogs, the scale,
 * a person or a pending invitation with the address and the domain setting are the database's (403, 404,
 * 409, 400).
 */
export async function POST(request: Request) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, PEOPLE);
    const parsed = parseInvitationInput(await jsonBody(request), Object.keys(copy));
    if ("problem" in parsed) throw new ApiError(400, "invalid_invitation", parsed.problem);
    return ok(await data().createInvitation(me, parsed.input), 201);
  });
}
