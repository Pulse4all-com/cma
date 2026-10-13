import { assertSameSiteWrite, forPrincipal, jsonBody, ok, requireAnyPermission, uuidParam } from "@/lib/api/respond";
import { checkLinkedAccountInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ userId: string }> };

/**
 * { system, externalId }: links one id of a person the caller may edit on People (set_user_external_id);
 * externalId null unlinks it (remove_user_external_id). Oneself or a person the caller may not edit 403, an id
 * another person holds 409, an unknown person 404. Answers the linked accounts
 */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, ["users.manage_agents", "users.manage_all"]);
    const userId = uuidParam((await params).userId, "userId");
    const { system, externalId } = checkLinkedAccountInput(await jsonBody(request));
    await data().setLinkedAccount(me, userId, system, externalId);
    return ok(await data().getLinkedAccounts(me));
  });
}
