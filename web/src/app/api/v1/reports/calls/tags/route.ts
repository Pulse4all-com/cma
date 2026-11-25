import { callsParams } from "@/lib/api/calls";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Calls per tag (cma.calls_per_tag, addition 0009zw; docs/definitions.md, Calls per tag) with the query of
 * /api/v1/reports/calls without the group (?from&to, at most 92 days, &market and &line, each optional; anything the
 * database would refuse is a 400): every call in scope per current tag (any tag, with its name, meaning and whether it
 * counts) by direction, `outbound`, `inbound` and `calls`, a call with two tags under each, by calls; `untagged` the calls
 * without a current tag, missed calls included (the overview's untagged); `totals` the calls in scope, the overview's
 * calls, inbound and outbound (cma.calls_figures_of), not the sum of the rows. Whole period only. `telephony` false: no
 * telephony connected, and no rows. Needs reports.view or performance.team, here and again in the database. Tag names
 * and counts only, never a call id, a number or a hash.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { range, filter } = callsParams(new URL(request.url).searchParams, false);
    const r = await data().getCallsPerTag(me, range, filter, true);
    return ok({ from: r.from, to: r.to, filter: r.filter, telephony: r.telephony, rows: r.rows, untagged: r.untagged, totals: r.totals });
  });
}
