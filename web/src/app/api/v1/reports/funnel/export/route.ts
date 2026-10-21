import { funnelParams } from "@/lib/api/funnel";
import { csvFile, forPrincipal, requireAnyPermission } from "@/lib/api/respond";
import { t } from "@/lib/copy";
import { exportSettingsFrom, funnelStagesCsv } from "@/lib/csv";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Reports > Funnel's stages as a CSV file for ?from&to (at most 92 days) and the report's filters (&market, &pipeline,
 * &source): one row per stage as the table shows it. The format follows the tenant's export settings, the column names
 * the caller's language. Needs reports.view or performance.team, here and again in the database. Counts and days only.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { range, filter } = funnelParams(new URL(request.url).searchParams);
    const report = await data().getFunnel(me, range, filter);
    const settings = exportSettingsFrom(await data().listSettings(me));
    return csvFile(funnelStagesCsv(report.stages, report.from, report.to, settings, t(me.locale).funnelFile), `funnel_${report.from}_${report.to}.csv`);
  });
}
