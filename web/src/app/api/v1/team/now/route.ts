import { forPrincipal, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * The team now (addition 0003e): one entry per person whose time is kept, with today's day in the
 * person's zone (as GET /api/v1/me/day shapes it) and the current status with its flags, plus the
 * tenant's status flags for the board's tiles. No parameters: today only, the whole tenant until
 * teams exist. Needs monitoring.live, checked by the database (403 without it). Named after the
 * data, not the screen, so other tools can use it. no-store: a live view is never cached.
 */
export async function GET() {
  return forPrincipal(async (me) => ok(await data().getTeamNow(me)));
}
