import { assertSameSiteWrite, forPrincipal, jsonBody, ok, requireAnyPermission, uuidParam } from "@/lib/api/respond";
import { checkLineInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ id: string }> };

/** { lineRef, market, isCounted }: a line's market (null clears) and whether its calls count and are stored (set_telephony_number; switching a line off removes its stored calls, addition 0008f). Answers the connection with its catalogs */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, ["tenant.configure"]);
    const id = uuidParam((await params).id, "id");
    await data().setSourceLine(me, id, checkLineInput(await jsonBody(request)));
    return ok(await data().getSource(me, id));
  });
}
