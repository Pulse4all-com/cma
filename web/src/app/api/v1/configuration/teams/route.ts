import { assertSameSiteWrite, forPrincipal, jsonBody, ok } from "@/lib/api/respond";
import { checkTeamInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/** Adds or changes a team: { key, name, markets, sortOrder }; a dissolved key is revived. Answers the current teams */
export async function PUT(request: Request) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    await data().upsertTeam(me, checkTeamInput(await jsonBody(request)));
    return ok(await data().listTeams(me));
  });
}
