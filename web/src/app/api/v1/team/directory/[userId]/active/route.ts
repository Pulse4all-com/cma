import { ApiError, assertSameSiteWrite, forPrincipal, jsonBody, ok, uuidParam } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ userId: string }> };

/** Deactivate or reactivate: body { "active": true | false }. Oneself is refused by the database (403). */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    const userId = uuidParam((await params).userId, "userId");
    const b = await jsonBody(request);
    if (typeof b.active !== "boolean") throw new ApiError(400, "invalid_active", "active must be true or false");
    await data().setPersonActive(me, userId, b.active);
    return ok((await data().listDirectory(me)).find((p) => p.userId === userId) ?? null);
  });
}
