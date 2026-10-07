import { ApiError, assertSameSiteWrite, forPrincipal, jsonBody, ok, uuidParam } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ userId: string }> };
const KEY_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/;

/** The full list of a person's teams: body { "teamKeys": ["…"] }. What is not in it ends. Unknown team 404. */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    const userId = uuidParam((await params).userId, "userId");
    const b = await jsonBody(request);
    const keys = b.teamKeys;
    if (!Array.isArray(keys) || keys.length > 50 || !keys.every((k) => typeof k === "string" && KEY_RE.test(k))) {
      throw new ApiError(400, "invalid_teams", "teamKeys must be an array of team keys");
    }
    await data().setPersonTeams(me, userId, [...new Set(keys as string[])]);
    return ok((await data().listDirectory(me)).find((p) => p.userId === userId) ?? null);
  });
}
