import { forPrincipal, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/** The tenant's role ladder with whether the caller may assign each role; users.manage_agents or users.manage_all (403 otherwise) */
export async function GET() {
  return forPrincipal(async (me) => ok(await data().listRoles(me)));
}
