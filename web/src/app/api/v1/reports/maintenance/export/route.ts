import { maintenanceRowsParams } from "@/lib/api/maintenance";
import { csvFile, forPrincipal, requireAnyPermission } from "@/lib/api/respond";
import { t } from "@/lib/copy";
import { exportSettingsFrom, maintenanceCsv } from "@/lib/csv";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Reports > Maintenance's device list as a CSV file (addition 0008zi): the query of /rows, with &bucket all (overdue and
 * every month of the horizon) and up to 5000 rows when left out. One row per row of the list, as the page shows it; the
 * format follows the tenant's export settings, the column names and the components' names the caller's language. Needs
 * reports.view or performance.team, here and again in the database. No name, email, phone or address exists to export.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { filter, bucket, view, limit } = maintenanceRowsParams(new URL(request.url).searchParams, { file: true });
    const [list, report] = await Promise.all([data().getMaintenanceRows(me, filter, bucket, view, limit), data().getMaintenance(me, filter)]);
    const settings = exportSettingsFrom(await data().listSettings(me));
    const copy = t(me.locale);
    const m = copy.maintenance;
    const components: Record<string, string> = Object.fromEntries([...report.componentKinds.map((k) => [k.key, k.name]), ["device", m.component_device]]);
    const bases: Record<string, string> = { recorded: m.basis_recorded, rule: m.basis_rule, unknown: m.basis_unknown };
    const text = maintenanceCsv(list.rows, settings, { ...copy.maintenanceFile, unknownMarket: copy.reports.unknownMarket }, { components, bases });
    return csvFile(text, `maintenance_${bucket}_${filter.fromMonth}.csv`);
  });
}
