import { fleetParams } from "@/lib/api/fleet";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { fleetTilesOf } from "@/lib/fleet-management";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Assets → Fleet management (cma.fleet_areas, addition 0009t) for the optional ?market (a market code or unknown) and
 * &model (a model's key or unknown): `setUp` (false, and nothing more, while the tenant's fleet_management.dummy_preview is
 * off), `filter`, `today`, `timeZone`, the filters' `markets` and `models`, the `tiles` summed here from the areas (inField
 * and pastDue as Installed base counts them; monitored and the four states dummy data), the `areas` (per postcode area
 * its code, place name, centre and counts; the row with areaId null: the devices In the field without an area) and
 * `pastDueNotInField` (the devices past due outside the field, in the tile Devices past due, not on the map). Needs reports.view
 * or performance.team, here and again in the database. Ids, codes and counts only.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const page = await data().getFleetAreas(me, fleetParams(new URL(request.url).searchParams));
    return ok(page.setUp ? { ...page, tiles: fleetTilesOf(page.areas, page.pastDueNotInField) } : { setUp: false });
  });
}
