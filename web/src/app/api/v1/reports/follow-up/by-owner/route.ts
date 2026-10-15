import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { FOLLOW_UP_BY_OWNER_PERMISSION } from "@/lib/follow-up";

export const dynamic = "force-dynamic";

/**
 * Per person: open leads, past the target, open tickets, at risk or breached, tasks overdue and due today
 * (cma.follow_up_by_owner, addition 0008o), by name, then one row for everything whose owner maps to nobody.
 * performance.team only: per-person figures sit under the employee-monitoring point (README), like Calls per agent.
 */
export async function GET() {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, [FOLLOW_UP_BY_OWNER_PERMISSION]);
    return ok(await data().getFollowUpByOwner(me));
  });
}
