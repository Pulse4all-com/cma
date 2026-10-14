import { assertSameSiteWrite, forPrincipal, jsonBody, ok, requireAnyPermission, uuidParam } from "@/lib/api/respond";
import { checkMissedReasonInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ id: string }> };

/**
 * { code, label, countsInServiceLevel, needsCallback }: one missed-call reason of a telephony connection
 * (set_telephony_missed_reason, addition 0008i); a connection of another kind 400. Answers the
 * connection with its catalogs
 */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, ["tenant.configure"]);
    const id = uuidParam((await params).id, "id");
    await data().setSourceMissedReason(me, id, checkMissedReasonInput(await jsonBody(request)));
    return ok(await data().getSource(me, id));
  });
}
