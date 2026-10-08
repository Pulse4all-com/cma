import { assertSameSiteWrite, forPrincipal, jsonBody, ok } from "@/lib/api/respond";
import { checkSkillInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/** Adds, changes, retires or reactivates a skill: { dimension, key, name, sortOrder, active }. Answers the catalog */
export async function PUT(request: Request) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    const { input, active } = checkSkillInput(await jsonBody(request));
    await data().upsertSkill(me, input, active);
    return ok(await data().listSkills(me));
  });
}
