import { leadCohortParams } from "@/lib/api/cohorts";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Lead cohorts (cma.lead_cohorts_report, addition 0008zm) for ?from&to (the deals' creation dates, at most 92 days), the optional
 * &market, &pipeline and &source filters as the Funnel's, &period=week|month and &split=none|market|source: the lead deals grouped
 * by the ISO week or month of their creation. `cohorts` (newest first, never split) and `rows` (per market or source channel
 * within each cohort, empty without a split), each with `created`, `notCalledYet`, `ordered`, `medianDaysToOrder`, `partial` and
 * per age of `ages` (cohorts.lead_ages_days) `mature` and the deals `attempted`, with a `conversation`, `ordered` and `lost` by
 * then (null at an age the cohort has not reached; `ordered` null above `leadToOrderDays`); `historyStart`; the filter lists.
 * Needs reports.view or performance.team, as the Funnel, here and again in the database. Counts only, no deal list.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { range, filter, period, split } = leadCohortParams(new URL(request.url).searchParams);
    return ok(await data().getLeadCohorts(me, range, period, split, filter));
  });
}
