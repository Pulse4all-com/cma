import { forPrincipal, ok, requireAnyPermission, teamRangeParams } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { MAX_REPORT_DAYS, REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * One row per lead deal created in ?from&to (at most 92 days; cma.speed_to_lead_rows, migration 0007d; one function
 * since 0009zq): the deal's id and the first outbound CRM call's id in the CRM, market, pipeline, status (called,
 * not_called_open, closed_before_first_call), the call times, the first Attempt (its call's id in the Workspace and its
 * start: the measure's end) and the attempts so far, the agent's user id (the person who made the first attempt; null
 * without an attempt or a mapping), the deal owner's user id apart, the measures and the record link from the
 * connection's template (cma.record_url). Ids, times and codes only: no name, email or phone number. Needs
 * reports.view or performance.team, here and again in the database.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { from, to } = teamRangeParams(new URL(request.url).searchParams, MAX_REPORT_DAYS);
    return ok({ from, to, rows: await data().getSpeedToLeadRows(me, { from, to }) });
  });
}
