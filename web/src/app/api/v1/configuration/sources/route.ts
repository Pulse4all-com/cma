import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * Every connection of the tenant with its kind, non-secret settings, secret names (never values),
 * events and catalog sizes (cma.sources, addition 0008e). tenant.configure, here and in the database.
 */
export async function GET() {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, ["tenant.configure"]);
    return ok(await data().listSources(me));
  });
}
