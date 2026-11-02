import { flashSnapshotsParams } from "@/lib/api/flash";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Flash's snapshots (cma.flash_snapshots, addition 0008zm): for ?from to &to (business dates) the dates with a
 * succeeded snapshot and their runs' counts and dates missed, the first and latest snapshot dates, and the open watch
 * findings (aggregates and codes only, never a record's id). Needs reports.view or performance.team, here and again in
 * the database.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { from, to } = flashSnapshotsParams(new URL(request.url).searchParams);
    return ok(await data().getFlashSnapshots(me, from, to));
  });
}
