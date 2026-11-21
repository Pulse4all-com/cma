import { subscriptionsPageParams } from "@/lib/api/subscriptions";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Customers → Subscriptions (cma.subscriptions_page, addition 0009zh) for the optional &market (a market code or unknown),
 * &store (a subscriptions connection's id), &proposition (a proposition's code or none), &interval (monthly, quarterly,
 * yearly, other or unknown), &from and &to (months as YYYY-MM; the last twelve complete months and the current one when
 * left out) and the list's &measure, &sort and &dir. Read from the subscription facts' stored takes: `setUp` (false, and
 * nothing more, while no subscriptions connection is set up), `history` (false while no take is stored), `take`
 * (computedAt: Refreshed at; amountsFrom: amounts of movements are known from then), `settings`, the filters' choices,
 * `tiles` (Total subscriptions with its split per holding status, Paused, the Monthly recurring amount per currency and
 * the indicative euros, the last complete month's rate parts, Device units with the unmapped, and `sourceCounts`: null
 * until the subscription app's own counts are stored, never a zero), `months` (counts per movement kind, amounts per
 * currency, the complete stores' rate parts), `rates` per market and complete month, `storeStarts`, `survival`, `mix` and
 * the list's first page. The movements and the rates follow the market and store filters only (the month take is per
 * store); the proposition and interval filters narrow the tiles, the mix, the list and (the interval) survival. Needs
 * reports.view or performance.team, here and again in the database. Ids, codes, counts, months, amounts and links only.
 * The answer's list is recorded in the audit log before it is sent (cma.subscription_file_record, part rows), as /rows.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const q = subscriptionsPageParams(new URL(request.url).searchParams, me);
    const page = await data().getSubscriptionsPage(me, q);
    // the answer carries the list's first page (ids and the contact's link): recorded in the audit log as the list's
    // route records a page, before it is sent
    if (page.list) await data().recordSubscriptionFile(me, "rows", q, q.measure, page.list.rows.length);
    return ok(page);
  });
}
