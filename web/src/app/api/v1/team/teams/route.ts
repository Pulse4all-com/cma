import { forPrincipal, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/** The tenant's current teams with their markets and member counts; any person of the tenant */
export async function GET() {
  return forPrincipal(async (me) => ok(await data().listTeams(me)));
}
