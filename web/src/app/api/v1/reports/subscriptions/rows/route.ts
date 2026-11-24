import { subscriptionsRowsParams } from "@/lib/api/subscriptions";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * The list of Customers → Subscriptions (cma.subscription_rows, addition 0009zh): the subscriptions of the stored take
 * under the filters and &measure (total, active, failed, paused, unmapped or all; total when left out), sorted by &sort
 * (monthly_amount within its currency, subscription, market, status, payment_state, interval or device_units; monthly_amount
 * when left out) and &dir (desc when left out), &page from 1, 50 a page. `total`, `rows`: the app's id and number, store,
 * market, status, payment state, interval group, monthly amount in its currency, device units, Subscription age in
 * months, propositions, payment instrument, and the CRM contact's id with its record
 * link. Ids, codes, dates, amounts and links only. Needs reports.view or performance.team, here and again in the
 * database. Every read is recorded in the audit log as a file read is (cma.subscription_file_record: who, which filters,
 * how many rows; never a row), before the rows are sent.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const q = subscriptionsRowsParams(new URL(request.url).searchParams, me);
    const list = await data().getSubscriptionRows(me, q);
    if (list.setUp) await data().recordSubscriptionFile(me, "rows", q, q.measure, list.rows.length);
    return ok(list);
  });
}
