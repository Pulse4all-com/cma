import { assertSameSiteWrite, forPrincipal, jsonBody, ok, requireAnyPermission, uuidParam } from "@/lib/api/respond";
import { checkStageOutcomeInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ id: string }> };

/** { pipelineId, stageId, outcome }: a deal stage's outcome, won, lost or none, kept over every later read (cma.set_stage_outcome, addition 0008u). Answers the connection with its catalogs */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, ["tenant.configure"]);
    const id = uuidParam((await params).id, "id");
    await data().setSourceStageOutcome(me, id, checkStageOutcomeInput(await jsonBody(request)));
    return ok(await data().getSource(me, id));
  });
}
