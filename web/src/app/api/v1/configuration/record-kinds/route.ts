import { assertSameSiteWrite, forPrincipal, jsonBody, ok, requireAnyPermission } from "@/lib/api/respond";
import { checkRecordKindInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/** The tenant's record kinds with their rules and whether reports.cancellation_kind names each (cma.record_kinds, addition 0008zb). tenant.configure */
export async function GET() {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, ["tenant.configure"]);
    return ok(await data().getRecordKinds(me));
  });
}

/**
 * { key, label, recordType, sortOrder?, isActive? }: adds a kind or changes its label and order, its record type set once
 * (cma.set_record_kind), and, when isActive is given, switches it on or off (cma.set_record_kind_status), in one transaction.
 * tenant.configure.
 * Answers the kinds
 */
export async function PUT(request: Request) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, ["tenant.configure"]);
    await data().setRecordKind(me, checkRecordKindInput(await jsonBody(request)));
    return ok(await data().getRecordKinds(me));
  });
}
