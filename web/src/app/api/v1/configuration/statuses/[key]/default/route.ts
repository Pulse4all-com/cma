import { assertSameSiteWrite, forPrincipal, ok } from "@/lib/api/respond";
import { checkKey } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ key: string }> };

/** Makes the status the tenant's default (an active working status, 409 otherwise; unknown 404). Answers the list */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    await data().setDefaultStatus(me, checkKey((await params).key, /^[a-z0-9_]+$/));
    return ok(await data().listConfigStatuses(me));
  });
}
