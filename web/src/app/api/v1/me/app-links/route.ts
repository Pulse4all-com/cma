import { forPrincipal, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * The app links the caller may see (addition 0003d): the tenant's buttons to other applications,
 * filtered by the database on the caller's permissions, in the tenant's order. Deep links only,
 * never customer data.
 */
export async function GET() {
  return forPrincipal(async (me) => ok(await data().listAppLinks(me)));
}
