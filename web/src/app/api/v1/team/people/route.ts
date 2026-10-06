import { forPrincipal, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * The people whose time is kept (active, holding workday.own), with employer and zone, for Add day
 * and the person filter. Needs workday.team, checked by the database (403 without it).
 */
export async function GET() {
  return forPrincipal(async (me) => ok(await data().listTeamPeople(me)));
}
