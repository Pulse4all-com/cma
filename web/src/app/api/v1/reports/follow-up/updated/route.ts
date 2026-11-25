import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { FOLLOW_UP_PERMISSIONS } from "@/lib/follow-up";

export const dynamic = "force-dynamic";

/**
 * When the follow-up snapshot was computed (night N07, decision D3: Reports → Follow-up's poll): { computedAt }. The page
 * asks every 10 seconds while it is visible and reads itself again only when the snapshot moved (at most about once a
 * minute), instead of re-rendering every 10 seconds, so the client router cache and the rail's prefetches stay. Needs
 * reports.view, performance.team or monitoring.live, here and again in the database. One scalar for every caller
 * (cma.follow_up_computed_at()): no figure, no row, the instant only.
 */
export async function GET() {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, FOLLOW_UP_PERMISSIONS);
    return ok({ computedAt: await data().getFollowUpComputedAt(me) });
  });
}
