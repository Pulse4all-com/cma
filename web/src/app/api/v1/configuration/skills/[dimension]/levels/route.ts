import { assertSameSiteWrite, forPrincipal, jsonBody, ok } from "@/lib/api/respond";
import { checkDimension, checkLevels } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ dimension: string }> };

/** Replaces a dimension's level scale: { levels: [ { level, name } ] }; empty makes it binary; levels in use 409. Answers the catalog */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    const dimension = checkDimension((await params).dimension);
    await data().setSkillLevels(me, dimension, checkLevels(await jsonBody(request)));
    return ok(await data().listSkills(me));
  });
}
