import { assertSameSiteWrite, forPrincipal, jsonBody, ok, requireAnyPermission, uuidParam } from "@/lib/api/respond";
import { checkRecordKindRuleInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ id: string }> };

/**
 * { kindKey, pipelineId, category, active }: a rule that gives this connection's records a kind, by a pipeline, a category
 * value or both; active false archives it (cma.set_record_kind_rule, addition 0008zb). Answers the tenant's kinds
 */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, ["tenant.configure"]);
    const id = uuidParam((await params).id, "id");
    await data().setRecordKindRule(me, id, checkRecordKindRuleInput(await jsonBody(request)));
    return ok(await data().getRecordKinds(me));
  });
}
