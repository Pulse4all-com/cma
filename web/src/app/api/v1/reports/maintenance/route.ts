import { maintenanceParams } from "@/lib/api/maintenance";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Maintenance (cma.maintenance_page, addition 0008zi) for ?from (YYYY-MM-01, the current month or later), &months (1 to 24;
 * 12 when left out) and the optional &market (a market code or unknown), &model (a model's key or unknown) and &scope
 * (field or stock): what comes due on the asset register's tracked devices. `buckets` (past_due, then every month); `cells`
 * (per bucket, market and model: components per kind, componentItems, endOfLife, exchanges); `unknown` and `unknownItems`
 * (due items without a due date); `componentKinds`; `devices`; `bundleWindowDays`; `isSetUp`; `markets`; `models`. Needs
 * reports.view or performance.team, here and again in the database. Team figures only; ids, codes and counts.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    return ok(await data().getMaintenance(me, maintenanceParams(new URL(request.url).searchParams)));
  });
}
