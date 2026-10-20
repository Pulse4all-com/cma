import { funnelParams } from "@/lib/api/funnel";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * The funnel (cma.deal_funnel_page, addition 0008zb) for ?from&to (at most 92 days) and the optional &market, &pipeline
 * (a lead pipeline) and &source (a source channel) filters. Only the sales deals count (0008z: the lead pipelines, never
 * one of orders). `stages`: per stage of the pipelines in their order, whether its times are read and, for those that
 * are, the deals that entered it in the period, still there, moved on, the median and 80th percentile of days in the
 * stage of those that moved on, reached won and its share, entered in the previous period; `byPipeline` (rows and total,
 * current and previous: created, won, lost, the win rate by close date, the median days to won and to lost);
 * `previousFrom`, `previousTo`, `previousPartial`; `historyStart` (deals and stage times); `timedStages`; the filter
 * lists. Needs reports.view or performance.team, here and again in the database. Ids, codes, counts and times only.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { range, filter } = funnelParams(new URL(request.url).searchParams);
    return ok(await data().getFunnel(me, range, filter));
  });
}
