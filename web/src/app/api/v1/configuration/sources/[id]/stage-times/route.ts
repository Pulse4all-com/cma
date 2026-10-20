import { assertSameSiteWrite, forPrincipal, jsonBody, ok, requireAnyPermission, uuidParam } from "@/lib/api/respond";
import { checkStageReadTimesInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ id: string }> };

/** { pipelineId, stageId, readTimes }: whether the adapter reads a deal stage's entry and exit times (cma.set_stage_read_times, addition 0008za). Answers the connection with its catalogs */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, ["tenant.configure"]);
    const id = uuidParam((await params).id, "id");
    await data().setSourceStageReadTimes(me, id, checkStageReadTimesInput(await jsonBody(request)));
    return ok(await data().getSource(me, id));
  });
}
