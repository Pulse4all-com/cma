import { ApiError, csvFile, forPrincipal, requireAnyPermission } from "@/lib/api/respond";
import { flashRowsParams } from "@/lib/api/flash";
import { exportSettingsFrom, flashCsv, type FlashFileColumn } from "@/lib/csv";
import { data } from "@/lib/data";
import {
  asOfStamp, breakdownColumns, breakdownRows, dataQualityRowShown, FLASH_FROZEN_COLUMNS, FLASH_LIST_COLUMNS, filtersText, flashFileName, overviewOf,
} from "@/lib/flash";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * A Flash file (addition 0008zn; decision 7, the Reports > Maintenance precedent): ?part=rows (the default) the records
 * behind a figure with the query of /rows, up to the tenant's flash.file_max_rows (50,000 for Pulse4all); ?part=breakdown
 * the overview's figures per grouping set, one column per measure and per currency of an amount. The tenant's export
 * format; the name flash-<overview>-<market|all>-<YYYY-MM-DD or YYYY-MM-DDTHHmm>.csv; the first column as_of, the second
 * the filters. Every file read is recorded in the audit log (cma.flash_file_record: who, which overview, which filters,
 * how many rows; never a row). Needs reports.view or performance.team, here and again in the database. No name, email,
 * phone or address exists to write. A source not set up gives no file (409 not_set_up); a file cut at the row limit says
 * "rows <n> of <total>" in its filters cell; its instants and its name follow the tenant's time zone.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const sp = new URL(request.url).searchParams;
    const part = sp.get("part") ?? "rows";
    if (part !== "rows" && part !== "breakdown") throw new ApiError(400, "invalid_part", "part must be rows or breakdown");
    const settingsList = await data().listSettings(me);
    const maxRows = Number(settingsList.find((s) => s.key === "flash.file_max_rows")?.value ?? "") || undefined;
    const q = flashRowsParams(sp, { file: true, maxRows });
    const def = overviewOf(q.overview)!;
    const settings = exportSettingsFrom(settingsList);
    // the market named by the address, or by the list's market filter alone (market wins over f_market: lib/api/flash)
    const market = q.market ?? q.filters.market ?? null;
    let filters = filtersText(market, def.kind === "flow" ? q.from : null, def.kind === "flow" ? q.to : null, part === "rows" ? q.filters : {});
    let text: string;
    let rows: number;
    let asOf: string;
    // the tenant's zone, as the database answers it: a file's instants and its name's stamp follow the tenant, not the reader
    let zone = me.timeZone;
    if (part === "breakdown") {
      // as the page reads it: a stock as stored for As of, a flow over its period (from its snapshots when As of is given)
      const doc = await data().getFlashOverview(me, q.overview, q.market, q.asOf, q.from, q.to);
      // a source not set up has no figures, never zeros: no file either
      if (!doc.setUp) throw new ApiError(409, "not_set_up", "this overview's source is not set up, so it has no figures");
      zone = doc.timeZone || me.timeZone;
      // the totals first (the document holds them apart: the market's own when one is chosen), then every set's rows
      const all = doc.totals ? [{ dims: {}, measures: doc.totals }, ...doc.rows] : doc.rows;
      const columns: FlashFileColumn[] = breakdownColumns(def, all);
      const lines = breakdownRows(def, all);
      asOf = doc.mode === "snapshot" && doc.asOfDate ? doc.asOfDate : doc.asOf;
      text = flashCsv(asOf, filters, columns, lines, settings, zone);
      rows = lines.length;
    } else {
      // a flow's records are the mirror's over its period; As of picks a stock's month-end frozen list only
      const list = await data().getFlashRows(me, def.kind === "flow" ? { ...q, asOf: null } : q);
      if (!list.setUp) throw new ApiError(409, "not_set_up", "this overview's source is not set up, so it has no records");
      zone = list.timeZone || me.timeZone;
      // a file cut at the row limit says so in its filters cell: the rows written of the records there are
      if (list.total > list.rows.length) filters = `${filters}; rows ${list.rows.length} of ${list.total}`;
      const columns = list.mode === "snapshot" ? FLASH_FROZEN_COLUMNS : FLASH_LIST_COLUMNS[def.key];
      asOf = list.mode === "snapshot" && q.asOf ? q.asOf : list.asOf;
      // the links outside the CRM are never written (FLASH_LINKS_LEFT_OUT are no columns; a finding's link for a CRM record only)
      const shown = def.key === "data_quality" && list.mode === "live" ? list.rows.map(dataQualityRowShown) : list.rows;
      text = flashCsv(asOf, filters, [...columns], shown, settings, zone);
      rows = list.rows.length;
    }
    // what was applied, no more: a breakdown takes no list filters; a flow's As of reads its period's snapshots, a stock's its date
    await data().recordFlashFile(me, { overview: def.key, part, filters: part === "rows" ? q.filters : {}, market: q.market,
      asOf: part === "rows" && def.kind === "flow" ? null : q.asOf, from: def.kind === "flow" ? q.from : null, to: def.kind === "flow" ? q.to : null, rows });
    const stamp = /^\d{4}-\d{2}-\d{2}$/.test(asOf) ? asOf : asOfStamp(null, new Date(asOf), zone);
    return csvFile(text, flashFileName(def.key, market, stamp, part));
  });
}
