import { forPrincipal, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/** The tenant's skill catalog with the level scale per dimension; any person of the tenant */
export async function GET() {
  return forPrincipal(async (me) => ok(await data().listSkills(me)));
}
