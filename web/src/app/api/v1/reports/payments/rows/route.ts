import { paymentsRowsParams } from "@/lib/api/payments";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * The list of Customers → Payments (cma.payment_rows, addition 0009zy): the subscriptions of the stored take in one of
 * the five payment states under the filters and &state (at_risk: an Amount at risk, the default; in_retry, charged_back,
 * awaiting_payment, failed, paid; or all), sorted by &sort (amount_at_risk within its currency, state_since, subscription,
 * market or payment_state; amount_at_risk when left out) and &dir (desc when left out), &page from 1, 50 a page. `total`,
 * `rows`: the app's id and number, store, market, status, payment state with its since and overdue, the chargeback's
 * return code, payment instrument, currency, amount at risk and monthly amount, and the CRM contact's id with its record
 * link. Ids, codes, times, amounts and links only. Needs reports.view or performance.team, here and again in the
 * database. Every read is recorded in the audit log as a file read is (cma.payment_file_record: who, which filters, how
 * many rows; never a row), before the rows are sent.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const q = paymentsRowsParams(new URL(request.url).searchParams, me);
    const list = await data().getPaymentRows(me, q);
    if (list.setUp) await data().recordPaymentFile(me, "rows", q, q.state, list.rows.length);
    return ok(list);
  });
}
