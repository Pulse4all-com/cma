import { forPrincipal, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * The caller's own details for My account (addition 0005b): name, email, employer, time zone,
 * role, whether their time is kept, current teams and skills with level. Their own row only, never
 * a colleague's (cma.my_profile takes no user id); no permission beyond being an active person.
 */
export async function GET() {
  return forPrincipal(async (me) => ok(await data().getMyProfile(me)));
}
