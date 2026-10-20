import { funnelParams } from "@/lib/api/funnel";
import { csvFile, forPrincipal, requireAnyPermission } from "@/lib/api/respond";
import { t } from "@/lib/copy";
import { exportSettingsFrom, lostReasonsCsv } from "@/lib/csv";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Reports > Funnel's lost reasons as a CSV file for ?from&to (at most 92 days) and the report's filters: one row per
 * real reason, per data-quality reason and one for no reason, with the lost deals and the share. The option's label and
 * value only, never free text. Needs reports.view or performance.team, here and again in the database.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { range, filter, group } = funnelParams(new URL(request.url).searchParams);
    const report = await data().getLostReasons(me, range, group, filter);
    const settings = exportSettingsFrom(await data().listSettings(me));
    const text = lostReasonsCsv(report.reasons, report.dataQualityReasons, report.noReason, report.from, report.to, settings, t(me.locale).lostReasonsFile);
    return csvFile(text, `lost_reasons_${report.from}_${report.to}.csv`);
  });
}
