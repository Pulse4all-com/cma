import { attemptParams } from "@/lib/api/attempts";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Attempts per deal (cma.attempts_per_deal_page, addition 0008y; for sales since 0008z) for ?from&to (at most 92 days),
 * &group=day|week|market|pipeline (day when left out) and the optional &market, &pipeline (a lead pipeline), &attempted
 * (all, none, some) and &outcome (all, open, won, lost, ordered) filters; a &scope is a 400 since 0008z. Only the deals of
 * the lead pipelines count. `current` and `previous` (the previous equal period, like for like) with the deals, those
 * attempted, the attempts, the average and median per deal, those reached and first reached, the median speed to lead,
 * called before the next noon, the open deals never attempted, won, lost, ordered, the talk time, the attempts without
 * an outcome and the calls logged without a telephony call; `buckets` (deals per number of attempts up to
 * attempts.max_bucket, first reached there, won and lost); `outcomes` (won against lost and the deals not decided);
 * `speedBuckets` (won and lost by business minutes to the first attempt); `groups`; `sinceLast` (the open deals by
 * business days since their last attempt); `list` (open deals first, the longest waiting first, then the decided ones
 * newest first, capped by follow_up.list_rows, with the total); the filter lists; `historyStart` and `settings`. One
 * deal's attempts: /api/v1/reports/attempts/deals/{dealId}. Needs reports.view or performance.team, here and again in
 * the database. Ids, codes, counts, links and times only.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { range, filter, group } = attemptParams(new URL(request.url).searchParams);
    return ok(await data().getAttempts(me, range, group, filter));
  });
}
