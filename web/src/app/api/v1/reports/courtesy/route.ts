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
 * contact, `dueOpen`, `notDue`, `dueNoAttempt`, `attempted`, `unreachable`, `completed`, `noContact`); `completed` and `previous`
 * (since addition 0009d `orders`, `positive`, `neutral`, `negative`: the courtesy orders completed in the period by completion
 * date, placed on any date, and the previous period like for like); `byMarket` (the period's orders by order date with `due`,
 * of which due, and `completed`, of which courtesy completed; and `completedInPeriod`, the orders completed in the period, each
 * in its own market) with `marketsTotal` (its total row, whose `completedInPeriod` equals `completed.orders`; null while not
 * set up); `byGroup` (the period's orders by order date with `due`); `settings.completedTags` (the tenant's completed tags);
 * `cohorts` (per ISO week or month at the ages of courtesy.ages_days); `perPerson` (`orders` and the outcomes per person; null
 * without performance.team); `list` (`total` and the first follow_up.list_rows rows: ids, codes, dates, counts, the state and the
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
