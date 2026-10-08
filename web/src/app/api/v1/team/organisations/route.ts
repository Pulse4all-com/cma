import { forPrincipal, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/** The tenant's active employers with the zone a new person follows (cma.organisations); any person of the tenant */
export async function GET() {
  return forPrincipal(async (me) => ok(await data().listOrganisations(me)));
}
