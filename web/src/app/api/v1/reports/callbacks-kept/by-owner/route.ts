import { forPrincipal, ok, requireAnyPermission, teamRangeParams } from "@/lib/api/respond";
import { CALLBACKS_PER_OWNER_PERMISSION } from "@/lib/callbacks";
import { data } from "@/lib/data";
import { MAX_REPORT_DAYS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Callbacks kept per person (cma.callbacks_kept_per_owner, addition 0008w) for ?from&to (at most 92 days): per task owner
 * by name, never ranked, the owner ids without a person as one row with how many that is (never which), the total last.
 * Needs performance.team, as Follow-up's per person; the database checks again.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, [CALLBACKS_PER_OWNER_PERMISSION]);
    const { from, to } = teamRangeParams(new URL(request.url).searchParams, MAX_REPORT_DAYS);
    return ok(await data().getCallbacksPerOwner(me, { from, to }));
  });
}
