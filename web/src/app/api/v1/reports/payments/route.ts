import { paymentsPageParams } from "@/lib/api/payments";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Customers → Payments (cma.payments_page, addition 0009zw) for Customers → Subscriptions' filters, the optional &market
 * (a market code or unknown), &store (a subscriptions connection's id), &proposition (a proposition's code or none),
 * &interval (monthly, quarterly, yearly, other or unknown), &from and &to (months as YYYY-MM; the last twelve complete
 * months and the current one when left out), and the list's &state (at_risk, in_retry, charged_back, awaiting_payment,
 * failed, paid or all; at_risk when left out), &sort and &dir. Read from the subscription facts' stored takes: `setUp`
 * (false, and nothing more, while no subscriptions connection is set up), `history` (false while no take is stored),
 * `take` (computedAt: Refreshed at), `settings`, the filters' choices, `tiles` (the page's base: the subscriptions in one
 * of the five payment states Paid, In retry, Charged back, Awaiting payment and Failed; per state its subscriptions; the
 * overdue Awaiting payment; the Amount at risk per currency with its subscriptions and the indicative euros; the last
 * complete month's Failed rate parts), `months` (the complete stores' Failed rate parts), `rates` per market and complete
 * month, `storeStarts`, `ratesStartMonth`, `cross` (per payment state and payment instrument its subscriptions) and the
 * list's first page. The months and the rates follow the market and store filters only (the month take is per store);
 * the proposition and interval filters narrow the tiles, the cross table and the list. Needs reports.view or
 * performance.team, here and again in the database. Ids, codes, counts, months, amounts and links only. The answer's list
 * is recorded in the audit log before it is sent (cma.payment_file_record, part rows), as /rows.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const q = paymentsPageParams(new URL(request.url).searchParams, me);
    const page = await data().getPaymentsPage(me, q);
    // the answer carries the list's first page (ids and the contact's link): recorded in the audit log as the list's
    // route records a page, before it is sent
    if (page.list) await data().recordPaymentFile(me, "rows", q, q.state, page.list.rows.length);
    return ok(page);
  });
}
