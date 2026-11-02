import { dataQualityRowsParams } from "@/lib/api/flash";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { DATA_QUALITY_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * A data-quality check's findings (cma.data_quality_rows, addition 0008zn): ?check (any check's key), &market, &limit (1
 * to the tenant's flash.file_max_rows; 500 when left out) and &offset. `total` and `rows`: per finding the record's type
 * and id, the value the check found, its market, where it is fixed (the system's kind and adapter, or the CMA), the
 * record's link and the related record (a store customer's CRM contact; a device's subscription). Needs reports.view or
 * tenant.configure, here and again in the database. Ids, codes and links only.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, DATA_QUALITY_PERMISSIONS);
    return ok(await data().getDataQualityRows(me, dataQualityRowsParams(new URL(request.url).searchParams)));
  });
}
