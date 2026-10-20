import { attemptParams } from "@/lib/api/attempts";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Attempts per deal (cma.attempts_per_deal_page, addition 0008y) for ?from&to (at most 92 days),
 * &group=day|week|market|pipeline (day when left out) and the optional &market, &pipeline and &scope (lead, the
 * default, or counted) filters: `current` and `previous` (the previous equal period, like for like) with the deals,
 * those attempted, the attempts, the average and median per deal, those reached on the first attempt, the open deals
 * never attempted, won and lost; `buckets` (deals per number of attempts up to attempts.max_bucket, first connected
 * there, won and lost); `groups`; `sinceLast` (the open deals by business days since their last attempt); `list`
 * (open deals first, the longest waiting first, capped by follow_up.list_rows, with the total); the filter lists;
 * `historyStart` and `settings`. Needs reports.view or performance.team, here and again in the database. Ids, codes,
 * counts, links and times only.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { range, filter, group } = attemptParams(new URL(request.url).searchParams);
    return ok(await data().getAttempts(me, range, group, filter));
  });
}
