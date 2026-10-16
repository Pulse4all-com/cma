import { formsParams } from "@/lib/api/forms";
import { csvFile, forPrincipal, requireAnyPermission } from "@/lib/api/respond";
import { t } from "@/lib/copy";
import { exportSettingsFrom, formsCsv } from "@/lib/csv";
import { data } from "@/lib/data";
import { formsLines, REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Reports > Forms as a CSV file for ?from&to (at most 92 days) and the report's filters: one row per form
 * and market as the table shows it, with the previous period's submissions and the resolution split. The
 * format follows the tenant's export settings, the column names the caller's language. Needs reports.view
 * or performance.team, here and again in the database. Counts only.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { range, filter } = formsParams(new URL(request.url).searchParams);
    const report = await data().getFormsReport(me, range, "week", filter);
    const settings = exportSettingsFrom(await data().listSettings(me));
    const names = Object.fromEntries(report.categories.map((c) => [c.code, c.name]));
    const text = formsCsv(formsLines(report.totals, report.previous), report.from, report.to, names, settings, t(me.locale).formsFile);
    return csvFile(text, `forms_${report.from}_${report.to}.csv`);
  });
}
