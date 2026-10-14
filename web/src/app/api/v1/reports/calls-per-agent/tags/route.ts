import { callsParams } from "@/lib/api/calls";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { PER_AGENT_PERMISSION } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Each person's split by counted tag (cma.calls_per_person_tags, addition 0008j) with the query of
 * /api/v1/reports/calls-per-agent: per person (and the not-linked calls) the conversations per counted
 * tag, then their untagged conversations (`tagKey` null). A tag that does not count is left out and
 * still makes its conversation tagged. Needs performance.team.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, [PER_AGENT_PERMISSION]);
    const { range, filter } = callsParams(new URL(request.url).searchParams, false);
    return ok(await data().getCallsPerAgentTags(me, range, filter));
  });
}
