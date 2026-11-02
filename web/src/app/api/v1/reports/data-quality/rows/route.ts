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
 * tenant.configure, here and again in the database. Ids, codes and links only. Every read is recorded in the audit log
 * as a Flash file read is (cma.flash_file_record: overview data_quality, part rows, the check and market as filters).
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, DATA_QUALITY_PERMISSIONS);
    const q = dataQualityRowsParams(new URL(request.url).searchParams);
    const list = await data().getDataQualityRows(me, q);
    // in the audit log as a file read is (decision 7): the check and the market as the filters, the rows given
    await data().recordFlashFile(me, { overview: "data_quality", part: "rows", filters: { check: q.check, ...(q.market ? { market: q.market } : {}) },
      market: q.market, asOf: null, from: null, to: null, rows: list.rows.length });
    return ok(list);
  });
}
