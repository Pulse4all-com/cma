import { forPrincipal, ok, requireAnyPermission, teamRangeParams } from "@/lib/api/respond";
import { CALLBACKS_PERMISSIONS } from "@/lib/callbacks";
import { data } from "@/lib/data";
import { MAX_REPORT_DAYS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Callbacks kept (cma.callbacks_kept_report, addition 0008w; KPI 5) for ?from&to (at most 92 days): per ISO week and in
 * total the callbacks due (a contact and a due time), kept, not kept, still open, and apart those without a contact or a
 * due time; the previous period's total like for like; `connected` false while the tenant counts no callback type;
 * `windowMinutes` (tasks.callback_window_minutes). Counts only. Needs reports.view or performance.team; the database
 * checks again.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, CALLBACKS_PERMISSIONS);
    const { from, to } = teamRangeParams(new URL(request.url).searchParams, MAX_REPORT_DAYS);
    return ok(await data().getCallbacksKept(me, { from, to }));
  });
}
