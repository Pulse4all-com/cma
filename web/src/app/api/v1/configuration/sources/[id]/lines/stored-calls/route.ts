import { ApiError, forPrincipal, ok, requireAnyPermission, uuidParam } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ id: string }> };

/**
 * ?lineRef: the stored calls of one line of a telephony connection and the first one's start
 * (cma.telephony_number_stored_calls, addition 0008y; backlog CMA-020), which switching the line off removes; the
 * switch-off dialog shows them. Counts and a time only. tenant.configure; an unknown line 404 (CMA02)
 */
export async function GET(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, ["tenant.configure"]);
    const id = uuidParam((await params).id, "id");
    const lineRef = new URL(request.url).searchParams.get("lineRef")?.trim() ?? "";
    if (lineRef === "" || lineRef.length > 100) throw new ApiError(400, "invalid_line", "lineRef must name a line of 1 to 100 characters");
    return ok(await data().getSourceLineStoredCalls(me, id, lineRef));
  });
}
