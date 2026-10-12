import { forPrincipal, ok, teamRangeParams } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * Per message sent in a business-date range (?from&to, at most 92 days): recipients, delivered, read,
 * acknowledged and the median seconds to read (cma.message_stats). Needs messages.send or
 * performance.team; the database decides (CMA06). Titles only, never a recipient's name.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    const { from, to } = teamRangeParams(new URL(request.url).searchParams, 92);
    return ok(await data().getMessageStats(me, { from, to }));
  });
}
