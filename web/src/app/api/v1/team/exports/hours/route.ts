import { type NextRequest } from "next/server";
import { csvFile, forPrincipal, teamRangeParams } from "@/lib/api/respond";
import { t } from "@/lib/copy";
import { exportSettingsFrom, hoursCsv } from "@/lib/csv";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * Hours per person per day as a CSV file for ?from=YYYY-MM-DD&to=YYYY-MM-DD, optionally
 * &userId=<id>. Needs workday.export, checked by the database (403 without it). The format follows
 * the tenant's settings, the column names the caller's language. At most 92 days per file.
 */
export async function GET(request: NextRequest) {
  return forPrincipal(async (me) => {
    const { from, to, userId } = teamRangeParams(request.nextUrl.searchParams, 92);
    const { settings, rows } = await data().exportHours(me, { from, to }, userId);
    const text = hoursCsv(rows, exportSettingsFrom(settings), t(me.locale).exports);
    return csvFile(text, `hours_${from}_${to}.csv`);
  });
}
