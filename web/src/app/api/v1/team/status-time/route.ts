import { type NextRequest } from "next/server";
import { forPrincipal, ok, teamRangeParams } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/** At most one quarter per request, as the other team reads */
const MAX_DAYS = 92;

/**
 * Time per status (addition 0003c) for ?from=YYYY-MM-DD&to=YYYY-MM-DD, optionally &userId=<id>:
 * one row per person per business date per status, with the status's key, name, order and four
 * flags, seconds, stretches and whether a stretch was capped. Needs performance.team, checked by
 * the database (403 without it). Named after the data, not the screen, so other tools can use it.
 */
export async function GET(request: NextRequest) {
  return forPrincipal(async (me) => {
    const { from, to, userId } = teamRangeParams(request.nextUrl.searchParams, MAX_DAYS);
    return ok(await data().getTeamStatusTime(me, { from, to }, userId));
  });
}
