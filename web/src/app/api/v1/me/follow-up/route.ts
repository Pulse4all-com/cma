import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { MY_FOLLOW_UP_PERMISSIONS } from "@/lib/follow-up";

export const dynamic = "force-dynamic";

/**
 * The caller's own rows (cma.my_follow_up, addition 0008o): the leads not called, the tickets and the tasks
 * whose owner is linked to them on People, each with its record link. Needs leads.accept or workday.own, here
 * and again in the database. Always the caller's own: a preview as another role never changes whose rows.
 */
export async function GET() {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, MY_FOLLOW_UP_PERMISSIONS);
    return ok(await data().getMyFollowUp(me));
  });
}
