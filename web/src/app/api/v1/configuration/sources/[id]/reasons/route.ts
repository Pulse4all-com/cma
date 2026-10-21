import { assertSameSiteWrite, forPrincipal, jsonBody, ok, requireAnyPermission, uuidParam } from "@/lib/api/respond";
import { checkReasonFlagInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ id: string }> };

/** { recordType, value, isDataQuality }: a person's data-quality flag on a reason option, kept by every refresh (cma.set_reason_data_quality, addition 0008zb). Answers the connection with its catalogs */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, ["tenant.configure"]);
    const id = uuidParam((await params).id, "id");
    await data().setSourceReasonDataQuality(me, id, checkReasonFlagInput(await jsonBody(request)));
    return ok(await data().getSource(me, id));
  });
}
