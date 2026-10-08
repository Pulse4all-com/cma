import { forPrincipal, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * Today's published roster entry per person whose time is kept, in each person's own zone
 * (cma.roster_today), for the Live board's shift line. Needs monitoring.live (403 from the database).
 */
export async function GET() {
  return forPrincipal(async (me) => ok(await data().getRosterToday(me)));
}
