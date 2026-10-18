import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { filterTickets, FOLLOW_UP_PERMISSIONS, parseFollowUpFilter } from "@/lib/follow-up";

export const dynamic = "force-dynamic";

/**
 * The open tickets of counted pipelines against their response time (cma.open_tickets, addition 0008o): the
 * response time in force, ok, at_risk, breached or no_hours, the minutes to breach; the least time left first,
 * no business hours last. ?market=&owner=&state=attention narrow the list. Needs reports.view, performance.team
 * or monitoring.live. Ticket ids only. Since addition 0008s from the snapshot: every row after the filter (no cap),
 * and computedAt, when it was computed (at most about a minute ago).
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, FOLLOW_UP_PERMISSIONS);
    const filter = parseFollowUpFilter(new URL(request.url).searchParams);
    const all = await data().getOpenTickets(me);
    return ok({ filter, rows: filterTickets(all.rows, filter), computedAt: all.computedAt });
  });
}
