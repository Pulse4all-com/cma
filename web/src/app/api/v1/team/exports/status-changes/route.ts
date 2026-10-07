import { type NextRequest } from "next/server";
import { csvFile, forPrincipal, teamRangeParams } from "@/lib/api/respond";
import { t } from "@/lib/copy";
import { exportSettingsFrom, statusChangesCsv } from "@/lib/csv";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * Status changes as a CSV file: one row per stretch in a status, from its change to the next, for
 * ?from=YYYY-MM-DD&to=YYYY-MM-DD, optionally &userId=<id>. Needs workday.export, checked by the
 * database (403 without it). Format from the tenant's settings. At most 92 days per file.
 */
export async function GET(request: NextRequest) {
  return forPrincipal(async (me) => {
    const { from, to, userId } = teamRangeParams(request.nextUrl.searchParams, 92);
    const { settings, rows } = await data().exportStatusChanges(me, { from, to }, userId);
    const text = statusChangesCsv(rows, exportSettingsFrom(settings), t(me.locale).exports);
    return csvFile(text, `status-changes_${from}_${to}.csv`);
  });
}
