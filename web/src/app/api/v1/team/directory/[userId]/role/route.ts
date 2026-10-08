import { ApiError, assertSameSiteWrite, forPrincipal, jsonBody, ok, uuidParam } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ userId: string }> };

/**
 * One role per person: body { "roleKey": "…" } from /api/v1/team/roles. The database refuses
 * one's own role and a managing role for a caller without users.manage_all (CMA06 → 403), an
 * unknown role (404). Answers the person as the directory now lists them.
 */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    const userId = uuidParam((await params).userId, "userId");
    const b = await jsonBody(request);
    if (typeof b.roleKey !== "string" || !/^[a-z_]+$/.test(b.roleKey)) throw new ApiError(400, "invalid_role", "roleKey must be a role key");
    await data().setPersonRole(me, userId, b.roleKey);
    return ok((await data().listDirectory(me)).find((p) => p.userId === userId) ?? null);
  });
}
