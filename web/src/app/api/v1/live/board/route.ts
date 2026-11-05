import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * The Live board in one read (addition 0008zr's web, night N06; the IT audit's 5.6-01): the team now with the
 * tenant's status flags, the current team memberships, today's published shifts, the settings the board needs,
 * today's inbound with the missed callers and the follow-up counts, read in one transaction. The board polls this
 * route every 10 seconds while its tab is visible and updates itself from the answer instead of rendering the page
 * again. Needs monitoring.live, here and again in the database (cma.team_now refuses first). Staff data, references
 * and counts only, never customer data; no-store: a live view is never cached.
 */
export async function GET() {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, ["monitoring.live"]);
    return ok(await data().getLiveBoard(me));
  });
}
