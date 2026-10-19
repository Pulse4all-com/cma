import { ApiError, forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ code: string }> };

/** One journey of Campaign monitoring by its code (addition 0008v); an archived or unknown one is not found (404) */
export async function GET(_request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { code } = await params;
    const journey = (await data().getJourneys(me)).find((j) => j.code === code);
    if (!journey) throw new ApiError(404, "not_found", "no such journey");
    return ok({ journey });
  });
}
