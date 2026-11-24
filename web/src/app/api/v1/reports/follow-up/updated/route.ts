import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { FOLLOW_UP_PERMISSIONS, FOLLOW_UP_SUMMARY_PERMISSIONS } from "@/lib/follow-up";
import { holdsAny } from "@/lib/nav";

export const dynamic = "force-dynamic";

/**
 * When the follow-up snapshot was computed (night N07, decision D3: Reports → Follow-up's poll): { computedAt }. The page
 * asks every 10 seconds while it is visible and reads itself again only when the snapshot moved (at most about once a
 * minute), instead of re-rendering every 10 seconds, so the client router cache and the rail's prefetches stay. Needs
 * reports.view, performance.team or monitoring.live, here and again in the database. A holder of the summary's
 * permissions reads the snapshot's row alone (cma.follow_up_summary); a reader with reports.view only, whom the database
 * gives no summary, reads it with the page's own read (cma.follow_up_page, without the callbacks). No figure, no row:
 * the instant only.
 */
export async function GET() {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, FOLLOW_UP_PERMISSIONS);
    if (holdsAny(me, FOLLOW_UP_SUMMARY_PERMISSIONS)) return ok({ computedAt: (await data().getFollowUpSummary(me)).computedAt });
    const page = await data().getFollowUpPage(me, { market: null, owner: null, state: null }, null);
    return ok({ computedAt: page.computedAt });
  });
}
