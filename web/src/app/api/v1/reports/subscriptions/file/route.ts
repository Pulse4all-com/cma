import { subscriptionsFilePart, subscriptionsPageParams, subscriptionsRowsParams } from "@/lib/api/subscriptions";
import { ApiError, csvFile, forPrincipal, requireAnyPermission } from "@/lib/api/respond";
import { exportSettingsFrom, flashCsv, type FlashFileColumn } from "@/lib/csv";
import { data } from "@/lib/data";
import { asOfStamp } from "@/lib/flash";
import { REPORT_PERMISSIONS } from "@/lib/reports";
import {
  monthAddress, SUBSCRIPTIONS_AMOUNT_KINDS, SUBSCRIPTIONS_BRIDGE, SUBSCRIPTIONS_FILE_COLUMNS, SUBSCRIPTIONS_MONTHS_COLUMNS, subscriptionsFileName,
  subscriptionsQuery,
} from "@/lib/subscriptions";

export const dynamic = "force-dynamic";

const KINDS: Partial<Record<string, FlashFileColumn["kind"]>> = {
  monthly_amount: "number", device_units: "number", age_months: "number", propositions: "list",
};

/**
 * Customers → Subscriptions as a file (addition 0009zh; the Flash and Active files' precedent), in the tenant's export
 * format: &part=records (the default: the list under the filters and &measure, in the order of &sort and &dir, up to the
 * tenant's flash.file_max_rows) or &part=months (per month of &from to &to the counts per movement kind and the complete
 * stores' rate parts). The name subscriptions-<part>-<market|all>-<YYYY-MM-DDTHHmm>.csv; the first column as_of (the
 * take's Refreshed at), the second the filters, then the columns under the API's snake_case names. Ids, codes, dates,
 * counts and amounts only: the contact's link is not written (its id is). Every file is recorded in the audit log
 * (cma.subscription_file_record: who, which part, filters and measure, how many rows; never a row) before it is sent.
 * Needs reports.view or performance.team, here and again in the database. A source not set up gives no file (409
 * not_set_up), and neither does a tenant without a stored take yet (409 history_not_ready).
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const sp = new URL(request.url).searchParams;
    const part = subscriptionsFilePart(sp);
    // the tenant's export format is read beside the rows, not before them
    const settingsRead = data().listSettings(me).then(exportSettingsFrom);
    settingsRead.catch(() => undefined);
    if (part === "months") {
      const q = subscriptionsPageParams(sp, me);
      const [page, settings] = await Promise.all([data().getSubscriptionsPage(me, q), settingsRead]);
      if (!page.setUp) throw new ApiError(409, "not_set_up", "no subscriptions connection is set up, so there is no file");
      if (!page.take) throw new ApiError(409, "history_not_ready", "the stored take is being prepared, so there is no file yet");
      const filters = [...Object.entries(subscriptionsQuery(q)).map(([k, v]) => `${k}=${v}`), `from=${monthAddress(page.from)}`, `to=${monthAddress(page.to)}`].join("; ");
      const rows = page.months.map((m) => ({
        month: m.month, ...Object.fromEntries([...SUBSCRIPTIONS_BRIDGE, ...SUBSCRIPTIONS_AMOUNT_KINDS].map((k) => [k, m.counts ? m.counts[k] ?? 0 : null])),
        rate_base: m.complete?.base ?? null, rate_churned: m.complete?.churned ?? null, rate_moved_to_failed: m.complete?.movedToFailed ?? null,
      }));
      const columns: FlashFileColumn[] = SUBSCRIPTIONS_MONTHS_COLUMNS.map((key) => ({ key, kind: key === "month" ? "date" : "number" }));
      const zone = page.timeZone || me.timeZone;
      const text = flashCsv(page.take.computedAt, filters, columns, rows, settings, zone);
      await data().recordSubscriptionFile(me, "months", q, q.measure, rows.length, { from: page.from, to: page.to });
      return csvFile(text, subscriptionsFileName("months", q, asOfStamp(null, new Date(page.take.computedAt), zone)));
    }
    const q = subscriptionsRowsParams(sp, me, { file: true });
    const [list, settings] = await Promise.all([data().getSubscriptionRows(me, q), settingsRead]);
    if (!list.setUp) throw new ApiError(409, "not_set_up", "no subscriptions connection is set up, so there is no file");
    if (!list.history) throw new ApiError(409, "history_not_ready", "the stored take is being prepared, so there is no file yet");
    const zone = list.timeZone || me.timeZone;
    let filters = [...Object.entries(subscriptionsQuery(q)).map(([k, v]) => `${k}=${v}`), `measure=${q.measure}`].join("; ");
    if (list.total > list.rows.length) filters = `${filters}; rows ${list.rows.length} of ${list.total}`;
    const rows = list.rows.map((r) => ({
      source_id: r.sourceId, number: r.number, store: r.store, market: r.market, status: r.status, payment_state: r.paymentState, interval: r.interval,
      monthly_amount: r.monthlyAmount, currency: r.currency, device_units: r.deviceUnits,
      age_months: r.ageMonths, propositions: r.propositions, instrument: r.instrument, contact_id: r.contactId,
    }));
    const columns: FlashFileColumn[] = SUBSCRIPTIONS_FILE_COLUMNS.map((key) => ({ key, kind: KINDS[key] ?? "text" }));
    // as_of: the take's moment (Refreshed at), as Customers → Active's file
    const asOf = list.computedAt ?? new Date().toISOString();
    const text = flashCsv(asOf, filters, columns, rows, settings, zone);
    await data().recordSubscriptionFile(me, "records", q, q.measure, list.rows.length);
    return csvFile(text, subscriptionsFileName("records", q, asOfStamp(null, new Date(asOf), zone)));
  });
}
