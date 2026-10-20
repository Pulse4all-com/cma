import { funnelParams } from "@/lib/api/funnel";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Lost reasons (cma.lost_reasons_page, addition 0008zb) for ?from&to (at most 92 days), &group=week|day (week when left
 * out) and the optional &market, &pipeline and &source filters: the sales deals lost in the period by close date.
 * `current` and `previous` (lost, with a reason, no reason, data quality, real); `reasons` (the real reasons, each with
 * its share of the real lost deals); `dataQualityReasons` (each with its share of every lost deal); `noReason`;
 * `byMarket` and `bySource` (with the top 3 real reasons); `byPeriod` (each real reason's count by its value);
 * `reasonState` (none, unchecked, enumeration or refused: a reason comes from an enumeration property only); `list` (the
 * lost deals without a reason, the newest close first, capped by follow_up.list_rows, with the total); `historyStart`;
 * the filter lists. Needs reports.view or performance.team, here and again in the database. Option values and labels,
 * ids, codes, counts, links and times only: never free text.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { range, filter, group } = funnelParams(new URL(request.url).searchParams);
    return ok(await data().getLostReasons(me, range, group, filter));
  });
}
