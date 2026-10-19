import { firstOrderParams } from "@/lib/api/first-orders";
import { csvFile, forPrincipal, requireAnyPermission } from "@/lib/api/respond";
import { t } from "@/lib/copy";
import { exportSettingsFrom, firstOrdersCsv } from "@/lib/csv";
import { data, type FirstOrderLevel } from "@/lib/data";
import { LEVELS } from "@/lib/first-orders";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Reports > First orders as a CSV file for ?from&to (at most 92 days) and the report's filters: one row per first
 * order as the list shows it (the deal id, when, market, level, attribution, each piece of evidence, the amount and
 * its currency, the days from the first touch), up to 500 rows. The format follows the tenant's export settings, the
 * column names the caller's language. Needs reports.view or performance.team, here and again in the database. No
 * name, address or phone number exists to export.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { range, filter } = firstOrderParams(new URL(request.url).searchParams);
    const rows = await data().getFirstOrdersExport(me, range, filter);
    const settings = exportSettingsFrom(await data().listSettings(me));
    const copy = t(me.locale);
    const levelNames = Object.fromEntries(LEVELS.map((l) => [l, copy.firstOrders[`level_${l}`]])) as Record<FirstOrderLevel, string>;
    const text = firstOrdersCsv(rows, range.from, range.to, me.timeZone, settings, copy.firstOrdersFile, levelNames);
    return csvFile(text, `first_orders_${range.from}_${range.to}.csv`);
  });
}
