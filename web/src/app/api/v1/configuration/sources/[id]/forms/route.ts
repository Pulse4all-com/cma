import { assertSameSiteWrite, forPrincipal, jsonBody, ok, requireAnyPermission, uuidParam } from "@/lib/api/respond";
import { checkFormChanges } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ id: string }> };

/** { forms: [ { formId, isCounted, leadSource, market } ] }: 1 to 500 forms in one transaction (set_form, kept fields kept); an unknown market 404 writes nothing. Answers the connection with its catalogs */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, ["tenant.configure"]);
    const id = uuidParam((await params).id, "id");
    await data().setSourceForms(me, id, checkFormChanges(await jsonBody(request)));
    return ok(await data().getSource(me, id));
  });
}
