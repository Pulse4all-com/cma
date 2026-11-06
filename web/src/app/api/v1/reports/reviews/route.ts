import { reviewsParams } from "@/lib/api/funnel";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Reviews (cma.reviews_page, addition 0008ze) for ?from&to (at most 92 days), &group=week|day (week when left out) and the
 * optional &market (a market code or unknown; a &pipeline or &source is a 400), or for the period All (addition 0008zw):
 * ?range=all&to, from the tenant's first counted review to &to, exempt from the 92 days, grouped by month, with no previous
 * period (previousFrom and previousTo null; `from`, `to` and `all` say which period was read): the review platform's published reviews of
 * counted channels, by the submission's date in the tenant's zone. `current` and `previous` (reviews, averageRating,
 * negative, linkedOrder, linkedContact, unlinked; the previous period like for like); `distribution` (per whole star);
 * `byPeriod`; `byMarket`; `byChannel`; `linkLevels`; `inviteEvents`; `marketStates` (every active market: no_channel,
 * channel_no_reviews, has_reviews); `historyStart`; `negativeMaxRating`; `isSetUp`; `markets`. Needs reports.view or
 * performance.team, here and again in the database. Team figures only; never a reviewer, a title or a text.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { range, market, group } = reviewsParams(new URL(request.url).searchParams);
    return ok(await data().getReviews(me, range, group, market));
  });
}
