import { assertSameSiteWrite, forPrincipal, jsonBody, ok, requireAnyPermission, uuidParam } from "@/lib/api/respond";
import { checkPipelineSlaInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ id: string }> };

/**
 * { recordType: "ticket", pipelineId, slaMinutes }: a ticket pipeline's own response time in business minutes
 * (cma.set_pipeline_sla, addition 0008o), or null for the tenant's tickets.sla_minutes. Answers the connection
 * with its catalogs. An unknown pipeline 404, a value outside 1 to 100000 400.
 */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, ["tenant.configure"]);
    const id = uuidParam((await params).id, "id");
    await data().setSourcePipelineSla(me, id, checkPipelineSlaInput(await jsonBody(request)));
    return ok(await data().getSource(me, id));
  });
}
