import { assertSameSiteWrite, forPrincipal, jsonBody, ok, requireAnyPermission, uuidParam } from "@/lib/api/respond";
import { checkReviewChannelInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ id: string }> };

/** { channelId, market, isCounted }: one review channel of a reviews connection (cma.set_review_channel, addition 0008ze). Answers the connection with its catalogs */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, ["tenant.configure"]);
    const id = uuidParam((await params).id, "id");
    await data().setSourceReviewChannel(me, id, checkReviewChannelInput(await jsonBody(request)));
    return ok(await data().getSource(me, id));
  });
}
