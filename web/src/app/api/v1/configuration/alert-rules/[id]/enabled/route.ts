import { ApiError, assertSameSiteWrite, forPrincipal, jsonBody, ok, requireAnyPermission, uuidParam } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ id: string }> };

/** { enabled }: switches a rule on or off (set_message_rule_enabled; a rule is never deleted). Answers the rules */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, ["tenant.configure"]);
    const id = uuidParam((await params).id, "id");
    const body = await jsonBody(request);
    if (typeof body.enabled !== "boolean") throw new ApiError(400, "invalid_enabled", "enabled must be true or false");
    await data().setAlertRuleEnabled(me, id, body.enabled);
    return ok(await data().getAlertRules(me));
  });
}
