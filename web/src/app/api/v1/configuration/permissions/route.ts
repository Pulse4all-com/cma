import { forPrincipal, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/** The permission catalog, for the app link's permission choice; tenant.configure */
export async function GET() {
  return forPrincipal(async (me) => ok(await data().listPermissions(me)));
}
