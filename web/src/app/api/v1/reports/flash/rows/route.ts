import { flashRowsParams } from "@/lib/api/flash";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * The records behind a Flash figure (cma.flash_rows, addition 0008zm): ?overview, &market, &from and &to (a flow's
 * period), &measure (a count measure), a filter per dim as f_<dim>, &sort (the overview's whitelist) and &dir, &limit (1
 * to the tenant's flash.file_max_rows; 500 when left out) and &offset; with &asOf a past month end's frozen list
 * (customers, subscriptions, installed_base; 404 for any other date). `total` (every record before the limit) and
 * `rows`: ids, statuses, codes, amounts with their currency and the CRM's links. Needs reports.view or
 * performance.team, here and again in the database. Never a name, email, phone or address.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    return ok(await data().getFlashRows(me, flashRowsParams(new URL(request.url).searchParams)));
  });
}
