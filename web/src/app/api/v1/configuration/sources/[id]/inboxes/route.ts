import { assertSameSiteWrite, forPrincipal, jsonBody, ok, requireAnyPermission, uuidParam } from "@/lib/api/respond";
import { checkInboxInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ id: string }> };

/** { inboxId, isCounted, market }: one inbox of a CRM connection's conversations (cma.set_inbox, addition 0008m; its work type and channel kept). Answers the connection with its catalogs */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, ["tenant.configure"]);
    const id = uuidParam((await params).id, "id");
    await data().setSourceInbox(me, id, checkInboxInput(await jsonBody(request)));
    return ok(await data().getSource(me, id));
  });
}
