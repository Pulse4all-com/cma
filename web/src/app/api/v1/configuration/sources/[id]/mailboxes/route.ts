import { assertSameSiteWrite, forPrincipal, jsonBody, ok, requireAnyPermission, uuidParam } from "@/lib/api/respond";
import { checkMailboxInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ id: string }> };

/** { accountId, label, isCounted, market }: one mailbox, an inbox's channel account (cma.set_inbox_account, addition 0008t); a label with an @ is refused (the CMA keeps no address). Answers the connection with its catalogs */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, ["tenant.configure"]);
    const id = uuidParam((await params).id, "id");
    await data().setSourceMailbox(me, id, checkMailboxInput(await jsonBody(request)));
    return ok(await data().getSource(me, id));
  });
}
