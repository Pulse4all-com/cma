import { callsParams } from "@/lib/api/calls";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { PER_AGENT_PERMISSION } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Calls per agent (cma.calls_per_person, addition 0008j) for ?from&to (at most 92 days) and the optional
 * &market and &line filters: per person, by name and never ranked, the answered inbound calls with their
 * talk time, the outbound calls, the connected ones with their talk time, the conversations and the
 * untagged ones, the first and last call's time of day; the calls of telephony users without a person
 * as one row with how many users that is (never who); `total`. Needs performance.team, here and again in
 * the database (README Decision log, 14 October 2026). No telephony user id, call id or number.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, [PER_AGENT_PERMISSION]);
    const { range, filter } = callsParams(new URL(request.url).searchParams, false);
    return ok(await data().getCallsPerAgent(me, range, filter));
  });
}
