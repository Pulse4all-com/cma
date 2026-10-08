import { forPrincipal, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * Current team memberships of everyone (cma.team_members_now, migration 0004): userId, teamKey,
 * teamName. For people who watch or manage the team (monitoring.live, workday.team, roster.manage,
 * users.manage_agents or users.manage_all), decided by the database (403 otherwise).
 */
export async function GET() {
  return forPrincipal(async (me) => ok(await data().listTeamMembersNow(me)));
}
