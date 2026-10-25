import { assertSameSiteWrite, forPrincipal, jsonBody, ok, requireAnyPermission, uuidParam } from "@/lib/api/respond";
import { checkTagInput, checkTagMeaningInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ id: string }> };

/** { tagRef, isCounted }: whether calls with a tag count (set_telephony_tag). Answers the connection with its catalogs */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, ["tenant.configure"]);
    const id = uuidParam((await params).id, "id");
    await data().setSourceTag(me, id, checkTagInput(await jsonBody(request)));
    return ok(await data().getSource(me, id));
  });
}

/**
 * { tagRef, meaning }: what a tag means (set_telephony_tag_meaning, addition 0008zc; incorrect_data 0008zd): not_reached,
 * incorrect_data, call_type, courtesy_attempt, courtesy_completed_positive, courtesy_completed_neutral or
 * courtesy_completed_negative, or null for none. The same gate as is_counted. Answers the connection with its catalogs
 */
export async function PATCH(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, ["tenant.configure"]);
    const id = uuidParam((await params).id, "id");
    await data().setSourceTagMeaning(me, id, checkTagMeaningInput(await jsonBody(request)));
    return ok(await data().getSource(me, id));
  });
}
