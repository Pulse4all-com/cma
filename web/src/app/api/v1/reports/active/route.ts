import { mergeActive, withActiveNow } from "@/lib/active";
import { activeParams } from "@/lib/api/active";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Customers → Active (cma.active_top, cma.active_rest and cma.active_now side by side, addition 0009l) for ?fromMonth (the history's first month, YYYY-MM-01; as far back
 * as customers.history_months allows when left out, which also caps an earlier one), &grouping=month|quarter (the customer
 * cohorts) and the optional &market, &segment and &channel (indirect, direct or unknown) filters: the active customer base
 * in one document. `setUp` says whether the store and the subscriptions are connected; while either is not, `figures` is
 * false and every figure is null or empty ("Not set up", never zeros). `tiles` (Flash's Active customers and Total
 * subscriptions with their splits, the Monthly recurring amount per currency with its customers and average, the
 * indicative euros only while reports.fx_eur_rates holds a rate for every currency shown, Customer age, Customer lifetime
 * and Customer lifetime value (realised) per currency; `prevMonth` and `prevYear` the value at the previous month's end and
 * twelve months before it, null where the history does not reach); `unitEconomics` (the placeholders' keys with status
 * pending and no figure; `churned30d`); `months` (per month end: customers with `bySegment`, subscriptions, inflow with
 * `inflowByChannel`, outflow, net, amounts per currency; the running month is `isNow` and equals the headline); `markets`
 * with `marketsTotal`; `comparison` (the first two segments side by side: a, b, unknown, difference and ratio per measure);
 * `survival` (Kaplan–Meier per segment, per channel and over all); `ageBands`; `cohorts` with `cohortSplits`; `mix`;
 * `notes`; `filters` (the choices); `settings`. The tiles that state the present (Active customers, Total subscriptions,
 * the Monthly recurring amount, the euros) are live here (`presentAt` is their moment; decision D16: the page shows the
 * stored ones first and these after); everything else is read from the stored take the scheduler refreshes (decision
 * D13), the churn count and the split by acquisition channel included (null while there is no take, never a zero).
 * `take` says when it was computed (`computedAt`), whether it is
 * `stale` (a setting it depends on changed since) or `late` (older than customers.history_notice_minutes), and `history`
 * is false while no take exists yet: then the present is answered and every figure over time is null or empty ("History
 * is being prepared", never zeros). Amounts are per currency and never added across currencies. Team figures
 * only: counts, codes, dates and amounts, never a customer's name, email, phone or address. Needs reports.view or
 * performance.team, here and again in the database.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { fromMonth, grouping, filter } = activeParams(new URL(request.url).searchParams);
    // the page's reads of the report, side by side, as one document: the stored answers with the live present in the
    // places of the tiles that state it
    const [top, rest, now] = await Promise.all([data().getActiveTop(me, fromMonth, filter), data().getActiveRest(me, fromMonth, filter, grouping),
      data().getActiveNow(me, filter)]);
    return ok(mergeActive(withActiveNow(top, now), rest));
  });
}
