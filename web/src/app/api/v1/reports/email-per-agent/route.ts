import { emailParams } from "@/lib/api/email";
import { ApiError, forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { EMAIL_PER_AGENT_PERMISSION, EMAIL_PER_PERSON_KEY } from "@/lib/email";

export const dynamic = "force-dynamic";

/**
 * Email per agent (cma.email_per_person, addition 0008t) for ?from&to (at most 92 days) and the optional &market,
 * &inbox and &account filters: per person, by name and never ranked, the emails sent, the conversations they
 * replied to first with the medians and the share within the target, the conversations they closed, and the sends
 * per hour of the day; the actions of owner ids without a person as one row with how many owner ids that is (never
 * which); `total`. Needs performance.team, and the tenant's reports.per_person holding email: while it does not,
 * the route is not there (404), as the page and its rail item are not; the database refuses the read as well
 * (README Decision log, 18 October 2026).
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    if (!me.perPerson.includes(EMAIL_PER_PERSON_KEY)) throw new ApiError(404, "not_found", "no such route");
    requireAnyPermission(me, [EMAIL_PER_AGENT_PERMISSION]);
    const { range, filter } = emailParams(new URL(request.url).searchParams);
    return ok(await data().getEmailPerAgent(me, range, filter));
  });
}
