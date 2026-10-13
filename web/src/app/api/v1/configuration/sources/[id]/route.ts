import { assertSameSiteWrite, forPrincipal, jsonBody, ok, requireAnyPermission, uuidParam } from "@/lib/api/respond";
import { checkSourceConnectionInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ id: string }> };

/** One connection with its pipelines, forms, call outcomes, lines, tags, fields, write-back fields and store; unknown 404 */
export async function GET(_request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, ["tenant.configure"]);
    return ok(await data().getSource(me, uuidParam((await params).id, "id")));
  });
}

/** { name?, isActive?, kind? }: a kind the connection's rows contradict 409. Answers the connection with its catalogs */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, ["tenant.configure"]);
    const id = uuidParam((await params).id, "id");
    await data().setSourceConnection(me, id, checkSourceConnectionInput(await jsonBody(request)));
    return ok(await data().getSource(me, id));
  });
}
