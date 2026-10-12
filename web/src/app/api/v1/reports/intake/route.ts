import { forPrincipal, ok, requireAnyPermission, teamRangeParams } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { MAX_REPORT_DAYS, REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Intake per business date and market for ?from&to (at most 92 days; cma.intake_per_day, migration
 * 0007d): form submissions, deals and tickets created and closed, calls in and out and tagged calls,
 * new customers, first and repeat orders and renewals, with `connections` (telephony, commerce) and the
 * tenant's `startDate`. A telephony figure is null when the tenant has no telephony connected, a
 * commerce figure null without a shop: never 0 for a source that is not there. Needs reports.view or
 * performance.team, here and again in the database.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { from, to } = teamRangeParams(new URL(request.url).searchParams, MAX_REPORT_DAYS);
    return ok(await data().getIntake(me, { from, to }));
  });
}
