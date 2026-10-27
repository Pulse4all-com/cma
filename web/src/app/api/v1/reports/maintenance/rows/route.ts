import { maintenanceRowsParams } from "@/lib/api/maintenance";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * The device list of one cell of Maintenance (cma.maintenance_rows, addition 0008zi): the page's query plus &bucket
 * (overdue, unknown, all or a month of the horizon as YYYY-MM-01), &view (exchanges or components; exchanges when left
 * out) and &limit (1 to 5000; 500 when left out). `total` (every row of the cell) and `rows`: per device (and planned
 * exchange) the serial, model, market, device status, components due, due date, bases, action date, the exchange's first
 * action date, the customer and subscription ids, the CRM contact's id and the links of the connections' templates. Needs
 * reports.view or performance.team, here and again in the database. Never a name, email, phone or address.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { filter, bucket, view, limit } = maintenanceRowsParams(new URL(request.url).searchParams);
    return ok(await data().getMaintenanceRows(me, filter, bucket, view, limit));
  });
}
