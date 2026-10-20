import { funnelParams } from "@/lib/api/funnel";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Cancellations (cma.cancellations_page, addition 0008zb) for ?from&to (at most 92 days), &group=week|day (week when left
 * out) and the optional &market (a &pipeline or &source is a 400): the records of the kind the tenant's
 * reports.cancellation_kind names, by creation date. It counts the request (the ticket), never the contract. `kind` (null
 * while none is set); `current` and `previous` (requests, open, closed, the median days to close); `byMarket`;
 * `byPeriod` (per day or week and market); `reasonState` and `reasons`; `list` (the newest requests, capped by
 * follow_up.list_rows, with the total); `markets`; `historyStart`. Needs reports.view or performance.team, here and again
 * in the database. Ids, codes, counts, links and times only.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { range, filter, group } = funnelParams(new URL(request.url).searchParams, { marketOnly: true });
    return ok(await data().getCancellations(me, range, group, filter.market));
  });
}
