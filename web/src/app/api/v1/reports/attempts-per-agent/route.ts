import { attemptParams } from "@/lib/api/attempts";
import { ApiError, forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { ATTEMPTS_PER_AGENT_KEY, ATTEMPTS_PER_AGENT_PERMISSION } from "@/lib/attempts";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * Attempts per agent (cma.attempts_per_person_page, addition 0008y; for sales since 0008z) for ?from&to (at most 92
 * days) and the optional &market, &pipeline, &attempted and &outcome filters (a &scope is a 400): per deal owner, by name
 * and never ranked, the sales deals they own with their attempts (by anyone), the average per deal, the share with a
 * conversation (addition 0008zc), the median speed to lead, the talk time on conversations and the open deals never attempted; the deals of owner
 * ids without a person (or without an owner) as one row with how many owner ids that is (never which); `total`. Needs
 * performance.team, and the tenant's reports.per_person holding attempts: while it does not, the route is not there
 * (404), as the page and its rail item are not; the database refuses the read as well.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    if (!me.perPerson.includes(ATTEMPTS_PER_AGENT_KEY)) throw new ApiError(404, "not_found", "no such route");
    requireAnyPermission(me, [ATTEMPTS_PER_AGENT_PERMISSION]);
    const { range, filter } = attemptParams(new URL(request.url).searchParams);
    return ok(await data().getAttemptsPerAgent(me, range, filter));
  });
}
