import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { filterLeads, FOLLOW_UP_PERMISSIONS, parseFollowUpFilter } from "@/lib/follow-up";

export const dynamic = "force-dynamic";

/**
 * The open lead deals not called (cma.open_leads, addition 0008o), longest waiting first, each with its owner as
 * a person (or Not mapped), market, age bucket, whether the target has passed, the last call and the record link.
 * ?market=&owner=&state=attention narrow the list (lib/follow-up). Needs reports.view, performance.team or
 * monitoring.live, here and again in the database. Deal ids only: no customer data.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, FOLLOW_UP_PERMISSIONS);
    const filter = parseFollowUpFilter(new URL(request.url).searchParams);
    return ok({ filter, rows: filterLeads(await data().getOpenLeads(me), filter) });
  });
}
