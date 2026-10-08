import { assertSameSiteWrite, forPrincipal, jsonBody, ok } from "@/lib/api/respond";
import { checkTargetInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/** Every coverage target across teams: { teamKey, skillKey, weekday, minCount }; tenant.configure */
export async function GET() {
  return forPrincipal(async (me) => ok(await data().listCoverageTargets(me)));
}

/** Sets one target: { teamKey, skillKey, weekday 1..7, minCount 0..99 }; 0 clears. Needs roster.manage as well. Answers the list */
export async function PUT(request: Request) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    const t = checkTargetInput(await jsonBody(request));
    await data().setCoverageTarget(me, t.teamKey, t.skillKey, t.weekday, t.minCount);
    return ok(await data().listCoverageTargets(me));
  });
}
