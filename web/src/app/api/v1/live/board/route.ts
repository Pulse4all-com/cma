import { ApiError, forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { boardOfOrganisation } from "@/lib/live";

export const dynamic = "force-dynamic";

/**
 * The Live board in one read (addition 0008zr's web, night N06; the IT audit's 5.6-01): the team now with the
 * tenant's status flags, the current team memberships, today's published shifts, the settings the board needs,
 * today's inbound with the missed callers (since addition 0009k with inboundTalkSeconds, the talk time of today's
 * answered inbound calls, in place of waitingNow), today's outbound (addition 0009h: attempts, connected, the connected rate, the
 * outbound conversations, talk time and its average; null without telephony) and the follow-up counts, read in one transaction. The board polls this
 * route every 10 seconds while its tab is visible and updates itself from the answer instead of rendering the page
 * again. Needs monitoring.live, here and again in the database (cma.team_now refuses first). Staff data, references
 * and counts only, never customer data; no-store: a live view is never cached.
 *
 * ?organisation=<key> (addition 0008zv): one contact center's board, as /live/<key> shows it: the people, their team
 * memberships and shifts only of that organisation's people (lib/live boardOfOrganisation); the status flags, inbound, outbound,
 * the missed callers and follow-up stay tenant-wide. A key that is no contact center of the caller's tenant (an unknown
 * organisation, or one not flagged) is a 404, after the permission check. Without the parameter the whole tenant's
 * board, as before.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, ["monitoring.live"]);
    const key = new URL(request.url).searchParams.get("organisation");
    if (key === null) return ok(await data().getLiveBoard(me));
    if (!me.contactCenters.some((c) => c.key === key)) {
      throw new ApiError(404, "not_found", "organisation is not a contact center of this tenant");
    }
    return ok(boardOfOrganisation(await data().getLiveBoard(me), key));
  });
}
