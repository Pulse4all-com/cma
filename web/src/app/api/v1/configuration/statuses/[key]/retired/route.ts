import { assertSameSiteWrite, forPrincipal, ok } from "@/lib/api/respond";
import { checkKey } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ key: string }> };

/** Retires the status: it keeps its history and cannot be chosen. The default and the last working status are refused (409). Answers the list */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    await data().retireStatus(me, checkKey((await params).key, /^[a-z0-9_]+$/));
    return ok(await data().listConfigStatuses(me));
  });
}
