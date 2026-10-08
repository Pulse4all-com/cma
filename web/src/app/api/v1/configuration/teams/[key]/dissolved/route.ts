import { assertSameSiteWrite, forPrincipal, ok } from "@/lib/api/respond";
import { checkKey } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ key: string }> };

/** Dissolves the team: its memberships end, its history stays (unknown 404). Answers the current teams */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    await data().dissolveTeam(me, checkKey((await params).key, /^[a-z0-9]+(-[a-z0-9]+)*$/));
    return ok(await data().listTeams(me));
  });
}
