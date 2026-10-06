import { dateParam, forPrincipal, ok, uuidParam } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

type Params = { params: Promise<{ userId: string; date: string }> };

/**
 * One person's day with every event, effective or not, for the day editor: { day, events }. day is
 * null when the person has no day on that date. Needs workday.team, checked by the database.
 */
export async function GET(_request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    const p = await params;
    const userId = uuidParam(p.userId, "userId");
    const date = dateParam(p.date, "date");
    return ok(await data().getTeamDay(me, userId, date));
  });
}
