import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * Linked accounts (addition 0008e): the ids a person can hold in the tenant's customer-record and telephony
 * systems, and the ids held by the people the caller may see on People. users.manage_agents or
 * users.manage_all, here and in the database; never a sign-in id.
 */
export async function GET() {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, ["users.manage_agents", "users.manage_all"]);
    return ok(await data().getLinkedAccounts(me));
  });
}
