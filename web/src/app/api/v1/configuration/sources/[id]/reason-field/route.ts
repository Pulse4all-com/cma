import { assertSameSiteWrite, forPrincipal, jsonBody, ok, requireAnyPermission, uuidParam } from "@/lib/api/respond";
import { checkReasonFieldInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ id: string }> };

/**
 * { recordType, property }: the property a deal's or ticket's reason comes from (cma.set_connection_field, field reason,
 * addition 0008zb); empty removes the mapping. The adapter reads the property's data type on its next sweep: a value is
 * stored only from an enumeration, a text property is refused. Answers the connection with its catalogs
 */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, ["tenant.configure"]);
    const id = uuidParam((await params).id, "id");
    await data().setSourceReasonField(me, id, checkReasonFieldInput(await jsonBody(request)));
    return ok(await data().getSource(me, id));
  });
}
