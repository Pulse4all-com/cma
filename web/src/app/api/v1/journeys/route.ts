import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * The journeys of Campaign monitoring (cma.journeys(), addition 0008v): every journey of the tenant but the archived
 * ones, in their order: code, name, summary, market, status, design link and prerequisites. Placeholders as
 * configuration; no figures and no customer data. Needs reports.view or performance.team; the database checks again.
 */
export async function GET() {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    return ok({ journeys: await data().getJourneys(me) });
  });
}
