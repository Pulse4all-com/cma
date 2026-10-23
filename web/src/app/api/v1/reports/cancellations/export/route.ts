import { funnelParams } from "@/lib/api/funnel";
import { csvFile, forPrincipal, requireAnyPermission } from "@/lib/api/respond";
import { t } from "@/lib/copy";
import { cancellationsCsv, exportSettingsFrom } from "@/lib/csv";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Reports > Cancellations as a CSV file for ?from&to (at most 92 days), &group=week|day and the optional &market: one row
 * per day or week and market with the requests, open, closed and the median days to close. It counts requests, never
 * contracts. Needs reports.view or performance.team, here and again in the database. Counts and days only.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { range, filter, group } = funnelParams(new URL(request.url).searchParams, { marketOnly: true });
    const report = await data().getCancellations(me, range, group, filter.market);
    const settings = exportSettingsFrom(await data().listSettings(me));
    return csvFile(cancellationsCsv(report.byPeriod, group, settings, t(me.locale).cancellationsFile), `cancellations_${report.from}_${report.to}.csv`);
  });
}
