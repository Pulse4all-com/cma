import { activeRowsParams } from "@/lib/api/active";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * The customer list of Customers → Active (cma.active_rows, addition 0009l): the active customers under &market, &segment
 * and &channel, sorted by &sort (monthly_amount, clv, store_customer, store, market, segment, customer_start, age_months,
 * subscriptions, devices, channel or level; monthly_amount when left out) and &dir (desc when left out), &limit rows (1 to
 * 200; 50 when left out) from &offset. `total` (the customers there are) and `rows`: the store's id of the customer, store,
 * market, segment, Customer start, Customer age in months, subscriptions, devices, the Monthly recurring amount in its
 * currency, Customer lifetime value (realised) in the store's currency, the worst payment state, the acquisition channel
 * with First orders' level, and the CRM contact's id with its record link. Ids, codes, dates, amounts and links only: never
 * a name, email, phone or address. Needs reports.view or performance.team, here and again in the database. Every read is
 * recorded in the audit log as a file read is (cma.active_file_record: who, which filters, how many rows; never a row),
 * before the rows are sent.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const q = activeRowsParams(new URL(request.url).searchParams);
    const list = await data().getActiveRows(me, q);
    await data().recordActiveFile(me, q.filter, list.rows.length);
    return ok(list);
  });
}
