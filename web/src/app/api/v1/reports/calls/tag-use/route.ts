import { callsParams } from "@/lib/api/calls";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Tag use (cma.calls_tag_use, addition 0008j) with the query of /api/v1/reports/calls: per group and per
 * current tag (any tag, with its name and whether it counts) the conversations carrying it, `tagKey` null
 * for the untagged ones, then the same over the whole period (`groupKey` null). Needs reports.view or
 * performance.team. Tag names and counts only, never a call id.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { range, filter, group } = callsParams(new URL(request.url).searchParams, true);
    return ok(await data().getCallsTagUse(me, range, group, filter));
  });
}
