import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { filterTasks, FOLLOW_UP_PERMISSIONS, parseFollowUpFilter } from "@/lib/follow-up";

export const dynamic = "force-dynamic";

/**
 * The open tasks (cma.open_tasks, addition 0008o): type, priority, status, owner, due time and whether it is
 * overdue, due today or later, the deal or ticket it belongs to by id; due first. ?market=&owner=&state=attention
 * narrow the list. Needs reports.view, performance.team or monitoring.live. Never a task's body or subject. Since
 * addition 0008s from the snapshot: every row after the filter (no cap), and computedAt, when it was computed.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, FOLLOW_UP_PERMISSIONS);
    const filter = parseFollowUpFilter(new URL(request.url).searchParams);
    const all = await data().getOpenTasks(me);
    return ok({ filter, rows: filterTasks(all.rows, filter), computedAt: all.computedAt });
  });
}
