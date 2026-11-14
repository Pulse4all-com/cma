import { activeRowsParams } from "@/lib/api/active";
import { ApiError, csvFile, forPrincipal, requireAnyPermission } from "@/lib/api/respond";
import { ACTIVE_FILE_COLUMNS, activeFileName, activeQuery } from "@/lib/active";
import { exportSettingsFrom, flashCsv, type FlashFileColumn } from "@/lib/csv";
import { data } from "@/lib/data";
import { asOfStamp } from "@/lib/flash";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

const KINDS: Partial<Record<(typeof ACTIVE_FILE_COLUMNS)[number], FlashFileColumn["kind"]>> = {
  customer_start: "date", age_months: "number", subscriptions: "number", devices: "number", monthly_amount: "number", clv: "number",
};

/**
 * The customer list of Customers → Active as a file (addition 0009l; the Flash files' precedent): every active customer
 * under &market, &segment and &channel in the order of &sort and &dir, up to the tenant's flash.file_max_rows, in the
 * tenant's export format; the name active-customers-<market|all>-<segment|all>-<YYYY-MM-DDTHHmm>.csv; the first column
 * as_of, the second the filters, then the list's columns under the API's snake_case names. Ids, codes, dates and amounts
 * only: no name, email, phone or address exists to write, and the contact's link is not written (its id is). Every file
 * read is recorded in the audit log (cma.active_file_record: who, which filters, how many rows; never a row). Needs
 * reports.view or performance.team, here and again in the database. A source not set up gives no file (409 not_set_up),
 * and neither does a tenant without a stored take yet (409 history_not_ready).
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const q = activeRowsParams(new URL(request.url).searchParams, { file: true });
    const [settingsList, list] = await Promise.all([data().listSettings(me), data().getActiveRows(me, q)]);
    if (!list.setUp) throw new ApiError(409, "not_set_up", "the store or the subscriptions are not set up, so there is no customer list");
    const zone = list.timeZone || me.timeZone;
    const chosen = [...Object.entries(activeQuery(q.filter)), ...(q.band ? [["band", q.band]] : [])].map(([k, v]) => `${k}=${v}`);
    let filters = chosen.length > 0 ? chosen.join("; ") : "all";
    if (!list.take) throw new ApiError(409, "history_not_ready", "the stored take the list is read from is being prepared, so there is no customer list yet");
    if (list.total !== null && list.total > list.rows.length) filters = `${filters}; rows ${list.rows.length} of ${list.total}`;
    const rows = list.rows.map((r) => ({
      store_customer: r.storeCustomer, store: r.store, market: r.market, segment: r.segment, channel: r.channel, level: r.level, customer_start: r.customerStart,
      age_months: r.ageMonths, subscriptions: r.subscriptions, devices: r.devices, monthly_amount: r.monthlyAmount, currency: r.currency, clv: r.clv,
      clv_currency: r.clvCurrency, payment_state: r.paymentState, contact_id: r.contactId,
    }));
    const columns: FlashFileColumn[] = ACTIVE_FILE_COLUMNS.map((key) => ({ key, kind: KINDS[key] ?? "text" }));
    const text = flashCsv(list.take.computedAt, filters, columns, rows, exportSettingsFrom(settingsList), zone);
    await data().recordActiveFile(me, q.filter, list.rows.length, q.band ?? null);
    return csvFile(text, activeFileName(q.filter, asOfStamp(null, new Date(list.take.computedAt), zone)));
  });
}
