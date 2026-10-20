import { forPrincipal, ok, requireAnyPermission, uuidParam } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * One sales deal's attempts in time order (cma.attempts_of_deal, addition 0008z), as the definition counts them now: n, the
 * start, answered, talk time, reached and by what (outcome or talk_time), the outcome's label from the catalog, and the
 * agent's name only while the tenant's reports.per_person holds attempts and the caller holds performance.team (null
 * otherwise). Never a call id, a number, a hash or a recording. {dealId} is the CMA's id of the deal (the list's dealId);
 * another tenant's, an unknown one or a deal that is no sales deal is a 404 (CMA02). Needs reports.view or
 * performance.team, here and again in the database.
 */
type Params = { params: Promise<{ dealId: string }> };

export async function GET(_request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { dealId } = await params;
    return ok(await data().getDealAttempts(me, uuidParam(dealId, "dealId")));
  });
}
