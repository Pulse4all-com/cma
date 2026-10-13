import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { DATA_QUALITY_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Every data-quality check with its current total, in the database's order (cma.data_quality, migration
 * 0007d): key, description, total (null for a check whose source is not installed), then the outbox
 * guard's row (outbox_pending, brief A5) while its count is above 0. Counts only. Needs reports.view or
 * tenant.configure, here and again in the database.
 */
export async function GET() {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, DATA_QUALITY_PERMISSIONS);
    return ok(await data().getDataQuality(me));
  });
}
