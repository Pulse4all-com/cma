import { forPrincipal, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/** The tenant's current Standard week (D9) of the people on the roster: per person and ISO weekday. Needs roster.manage */
export async function GET() {
  return forPrincipal(async (me) => ok(await data().getStandardWeek(me)));
}
