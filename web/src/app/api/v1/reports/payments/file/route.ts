import { paymentsFilePart, paymentsPageParams, paymentsRowsParams } from "@/lib/api/payments";
import { ApiError, csvFile, forPrincipal, requireAnyPermission } from "@/lib/api/respond";
import { exportSettingsFrom, flashCsv, type FlashFileColumn } from "@/lib/csv";
import { data } from "@/lib/data";
import { asOfStamp } from "@/lib/flash";
import { PAYMENTS_FILE_COLUMNS, PAYMENTS_MONTHS_COLUMNS, paymentsFileName } from "@/lib/payments";
import { REPORT_PERMISSIONS } from "@/lib/reports";
import { monthAddress, subscriptionsQuery } from "@/lib/subscriptions";

export const dynamic = "force-dynamic";

const KINDS: Partial<Record<string, FlashFileColumn["kind"]>> = { amount_at_risk: "number", monthly_amount: "number", state_since: "instant", overdue: "flag" };

/**
 * Customers → Payments as a file (addition 0009zy; the Subscriptions file's precedent), in the tenant's export format:
 * &part=records (the default: the list under the filters and &state, in the order of &sort and &dir, up to the tenant's
 * flash.file_max_rows) or &part=months (per month of &from to &to the complete stores' Failed rate parts). The name
 * payments-<part>-<market|all>-<YYYY-MM-DDTHHmm>.csv; the first column as_of (the take's Refreshed at), the second the
 * filters, then the columns under the API's snake_case names. Ids, codes, times, counts and amounts only: the contact's
 * link is not written (its id is). Every file is recorded in the audit log (cma.payment_file_record: who, which part,
 * filters and state, how many rows; never a row) before it is sent. Needs reports.view or performance.team, here and again
 * in the database. A source not set up gives no file (409 not_set_up), and neither does a tenant without a stored take
 * yet (409 history_not_ready).
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const sp = new URL(request.url).searchParams;
    const part = paymentsFilePart(sp);
    // the tenant's export format is read beside the rows, not before them
    const settingsRead = data().listSettings(me).then(exportSettingsFrom);
    settingsRead.catch(() => undefined);
    if (part === "months") {
      const q = paymentsPageParams(sp, me);
      const [page, settings] = await Promise.all([data().getPaymentsPage(me, q), settingsRead]);
      if (!page.setUp) throw new ApiError(409, "not_set_up", "no subscriptions connection is set up, so there is no file");
      if (!page.take) throw new ApiError(409, "history_not_ready", "the stored take is being prepared, so there is no file yet");
      const filters = [...Object.entries(subscriptionsQuery(q)).map(([k, v]) => `${k}=${v}`), `from=${monthAddress(page.from)}`, `to=${monthAddress(page.to)}`].join("; ");
      const rows = page.months.map((m) => ({ month: m.month, rate_base: m.complete?.base ?? null, rate_moved_to_failed: m.complete?.movedToFailed ?? null }));
      const columns: FlashFileColumn[] = PAYMENTS_MONTHS_COLUMNS.map((key) => ({ key, kind: key === "month" ? "date" : "number" }));
      const zone = page.timeZone || me.timeZone;
      const text = flashCsv(page.take.computedAt, filters, columns, rows, settings, zone);
      await data().recordPaymentFile(me, "months", q, q.state, rows.length, { from: page.from, to: page.to });
      return csvFile(text, paymentsFileName("months", q, asOfStamp(null, new Date(page.take.computedAt), zone)));
    }
    const q = paymentsRowsParams(sp, me, { file: true });
    const [list, settings] = await Promise.all([data().getPaymentRows(me, q), settingsRead]);
    if (!list.setUp) throw new ApiError(409, "not_set_up", "no subscriptions connection is set up, so there is no file");
    if (!list.history) throw new ApiError(409, "history_not_ready", "the stored take is being prepared, so there is no file yet");
    const zone = list.timeZone || me.timeZone;
    let filters = [...Object.entries(subscriptionsQuery(q)).map(([k, v]) => `${k}=${v}`), `state=${q.state}`].join("; ");
    if (list.total > list.rows.length) filters = `${filters}; rows ${list.rows.length} of ${list.total}`;
    const rows = list.rows.map((r) => ({
      source_id: r.sourceId, number: r.number, store: r.store, market: r.market, status: r.status, payment_state: r.paymentState,
      state_since: r.stateSince, overdue: r.overdue, return_code: r.returnCode, instrument: r.instrument,
      amount_at_risk: r.amountAtRisk, monthly_amount: r.monthlyAmount, currency: r.currency, contact_id: r.contactId,
    }));
    const columns: FlashFileColumn[] = PAYMENTS_FILE_COLUMNS.map((key) => ({ key, kind: KINDS[key] ?? "text" }));
    // as_of: the take's moment (Refreshed at), as the Subscriptions file
    const asOf = list.computedAt ?? new Date().toISOString();
    const text = flashCsv(asOf, filters, columns, rows, settings, zone);
    await data().recordPaymentFile(me, "records", q, q.state, list.rows.length);
    return csvFile(text, paymentsFileName("records", q, asOfStamp(null, new Date(asOf), zone)));
  });
}
