import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { FOLLOW_UP_SUMMARY_PERMISSIONS } from "@/lib/follow-up";

export const dynamic = "force-dynamic";

/**
 * The follow-up counts right now (cma.follow_up_summary, addition 0008o): leads not called and past the target,
 * tickets at risk, breached and without owner, tasks overdue, due today and with an owner nobody maps to.
 * Needs monitoring.live, performance.team or workday.team, here and again in the database.
 */
export async function GET() {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, FOLLOW_UP_SUMMARY_PERMISSIONS);
    return ok(await data().getFollowUpSummary(me));
  });
}
