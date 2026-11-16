import { fleetPageParams } from "@/lib/api/fleet";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Assets → Fleet management's page in one read (cma.fleet_page, addition 0009u; brief B38, E6) for the optional ?market (a
 * market code or unknown), &model (a model's key or unknown), &state (a tile) and &area (a postcode area's id): the
 * document of the areas' route (`setUp`, `filter`, `today`, `timeZone`, `markets`, `models`, `areas`, `pastDueNotInField`),
 * the `tiles` as the database sums them (Devices past due split into `past_due_in_field` and `past_due_not_in_field`), and
 * the `list`'s first page as the rows' route answers it (the devices that need attention when neither a state nor an area
 * is chosen). The same answers as the two routes it replaces for the page, from one computation of the devices. Needs
 * reports.view or performance.team, here and again in the database. Ids, codes and counts only.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const page = await data().getFleetPage(me, fleetPageParams(new URL(request.url).searchParams));
    return ok(page.setUp ? page : { setUp: false });
  });
}
