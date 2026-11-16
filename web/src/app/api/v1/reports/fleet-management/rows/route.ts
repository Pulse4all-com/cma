import { fleetRowsParams } from "@/lib/api/fleet";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * A page of 50 of Fleet management's devices (cma.fleet_rows, addition 0009t): the page's query plus &state (a tile),
 * &area (a postcode area's id), &attention=1 (the devices that need attention: Needs attention, No connection or past due)
 * and &page (from 1). `setUp`, `page`, `pageSize`, `total`, `timeZone` and `rows`: per device its id, serial, model, market,
 * postcode area (id, code, place name), monitoring state, reason, last self-test date, last contact, past-due items and
 * location source. Sorted Needs attention, No connection, past due, then serial. Needs reports.view or performance.team.
 * Never a customer reference, name, email, phone or address.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const page = await data().getFleetRows(me, fleetRowsParams(new URL(request.url).searchParams));
    return ok(page.setUp ? page : { setUp: false });
  });
}
