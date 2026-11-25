import { forPrincipal, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/** The tenant's active assignment types in order (cma.assignment_types, addition 0009zw); any person of the tenant */
export async function GET() {
  return forPrincipal(async (me) => ok((await data().listAssignmentTypes(me)).filter((t) => t.isActive)));
}
