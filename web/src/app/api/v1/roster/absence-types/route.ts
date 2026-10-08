import { forPrincipal, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/** The tenant's active absence types in order (cma.absence_types); any person of the tenant */
export async function GET() {
  return forPrincipal(async (me) => ok(await data().listAbsenceTypes(me)));
}
