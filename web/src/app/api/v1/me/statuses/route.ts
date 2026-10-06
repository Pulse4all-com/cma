import { forPrincipal, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * The work statuses the caller can choose: their tenant's active list, in the tenant's order.
 * Keys and names are tenant configuration; pay and billing flags are not exposed here.
 */
export async function GET() {
  return forPrincipal(async (me) => ok(await data().listStatuses(me)));
}
