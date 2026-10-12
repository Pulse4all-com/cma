import { forPrincipal, ok, requireAnyPermission, teamRangeParams } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { MAX_REPORT_DAYS, REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * One row per lead deal created in ?from&to (at most 92 days; cma.speed_to_lead_rows, migration 0007d):
 * the deal's and the first call's ids in the CRM, market, pipeline, status, the call times, the agent's
 * user id (null when the owner is not mapped), the measures and the record link from the connection's
 * template (cma.record_url). Ids, times and codes only: no name, email or phone number. Needs
 * reports.view or performance.team, here and again in the database.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { from, to } = teamRangeParams(new URL(request.url).searchParams, MAX_REPORT_DAYS);
    return ok({ from, to, rows: await data().getSpeedToLeadRows(me, { from, to }) });
  });
}
