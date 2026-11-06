import { courtesyParams } from "@/lib/api/courtesy";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Courtesy (cma.courtesy_page, addition 0009a) for ?from&to (at most 92 days), &period=week|month (the order cohorts),
 * &group=day|week|month and the optional &market, &segment and &state filters: a courtesy call per First or Repeat store order
 * (courtesy.order_kinds) from its due day (courtesy.due_days). `setUp` false (courtesy.start_date unset) answers every figure
 * null; `hasStore` false says no store is connected. `now` (every courtesy order since the start date as of now: `orders` with a
 * contact, `dueOpen`, `notDue`, `dueNoAttempt`, `attempted`, `notReached`, `completed`, `noContact`); `completed` and `previous`
 * (the completed courtesy calls of the period and the previous period like for like, distinct calls, per outcome); `byMarket` and
 * `byGroup` (the period's orders); `cohorts` (per ISO week or month at the ages of courtesy.ages_days); `perPerson` (null without
 * performance.team); `list` (`total` and the first follow_up.list_rows rows: ids, codes, dates, counts, the state and the
 * contact's record link, never a name, email, phone or address); `settings`; the filter choices. Needs reports.view or
 * performance.team, here and again in the database.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { range, period, group, filter } = courtesyParams(new URL(request.url).searchParams);
    return ok(await data().getCourtesy(me, range, period, group, filter));
  });
}
