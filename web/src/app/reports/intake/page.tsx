import { MarketFilter } from "@/components/MarketFilter";
import { PeriodBar } from "@/components/PeriodBar";
import { NoReportPermission, NotConnected } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock } from "@/lib/data";
import { holdsAny } from "@/lib/nav";
import { resolvePeriod } from "@/lib/period";
import {
  barShares, COMMERCE_FIELDS, CRM_FIELDS, filterMarket, fmtCount, intakeMarkets, intakeTotals, MAX_REPORT_DAYS,
  REPORT_PERMISSIONS, TELEPHONY_FIELDS, type IntakeField, type IntakeTotals,
} from "@/lib/reports";
import { dateKeyInZone, fmtDate } from "@/lib/time";
import { resolve } from "../../access";

/**
 * Intake (Report, B11): per business date and market the counts of cma.intake_per_day (migration
 * 0007d) with a total row and a small bar per row, a market filter (F), and the telephony and shop
 * columns, each shown as not connected when the tenant has no such source (never 0). Shown to people
 * holding reports.view or performance.team; the database checks again on every read. Counts only.
 */
export default async function IntakePage({ searchParams }: PageProps<"/reports/intake">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.intake;

  if (!holdsAny(me, REPORT_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="intake">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={copy.reports.noPermissionTitle} body={copy.reports.noPermissionBody} />
      </Shell>
    );
  }

  const sp = await searchParams;
  const today = dateKeyInZone(new Date(), me.timeZone);
  const { range, period, invalid } = resolvePeriod(sp, today, MAX_REPORT_DAYS);
  const intake = await data().getIntake(me, period);
  const markets = intakeMarkets(intake.rows);
  const market = typeof sp.market === "string" && markets.includes(sp.market) ? sp.market : "";
  const rows = filterMarket(intake.rows, market);
  const totals = intakeTotals(rows, intake.connections);
  const shares = barShares(rows);
  const { telephony, commerce } = intake.connections;
  const query: Record<string, string> =
    range === "custom" && !invalid ? { range, from: period.from, to: period.to } : { range };

  const labels: Record<IntakeField, string> = {
    formSubmissions: t.leads, dealsCreated: t.dealsCreated, dealsClosed: t.dealsClosed, ticketsCreated: t.ticketsCreated,
    ticketsClosed: t.ticketsClosed, callsIn: t.callsIn, callsOut: t.callsOut, taggedCalls: t.taggedCalls,
    newCustomers: t.newCustomers, firstOrders: t.firstOrders, repeatOrders: t.repeatOrders, renewals: t.renewals,
  };
  const n = (x: number | null) => (x === null ? "" : fmtCount(x, me.locale));
  const th = "h-10 px-2 font-semibold";
  const td = "h-10 whitespace-nowrap px-2";
  const sep = "border-l border-p4a-border";

  /** The telephony and shop cells of a row: the counts, or one cell saying the source is not connected */
  function sourceCells(values: Pick<IntakeTotals, IntakeField>, bold: boolean) {
    const cls = `${td} tabular text-right ${bold ? "font-semibold" : ""}`;
    return (
      <>
        {telephony
          ? TELEPHONY_FIELDS.map((f, i) => <td key={f} className={`${cls} ${i === 0 ? sep : ""}`}>{n(values[f])}</td>)
          : <td colSpan={TELEPHONY_FIELDS.length} className={`${td} ${sep} text-center`}><NotConnected label={copy.reports.noTelephony} hint={copy.reports.noTelephonyHint} /></td>}
        {commerce
          ? COMMERCE_FIELDS.map((f, i) => <td key={f} className={`${cls} ${i === 0 ? sep : ""}`}>{n(values[f])}</td>)
          : <td colSpan={COMMERCE_FIELDS.length} className={`${td} ${sep} text-center`}><NotConnected label={copy.reports.noShop} hint={copy.reports.noShopHint} /></td>}
      </>
    );
  }

  return (
    <Shell copy={copy} me={me} active="intake" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>

      <PeriodBar pathname="/reports/intake" range={range} period={period} today={today} copy={copy} keep={market ? { market } : {}} />

      {invalid ? (
        <div className="mb-6">
          <Notice tone="warning">{invalid === "length" ? copy.reports.tooLong : copy.myHours.invalidRange}</Notice>
        </div>
      ) : null}

      <div className="mb-6 flex items-end justify-between gap-4">
        <MarketFilter markets={markets} market={market} query={query} copy={copy} />
        <p className="text-caption text-p4a-grey">
          {fmtDate(period.from, me.locale)}
          {period.from !== period.to ? ` – ${fmtDate(period.to, me.locale)}` : ""}
        </p>
      </div>

      {intake.startDate && period.from < intake.startDate ? (
        <div className="mb-6">
          <Notice tone="info">{t.startNote.replace("{date}", fmtDate(intake.startDate, me.locale))}</Notice>
        </div>
      ) : null}

      <Card>
        {rows.length === 0 ? (
          <p className="text-body text-p4a-muted">{t.empty}</p>
        ) : (
          <table className="w-full border-collapse text-small" data-testid="intake-table">
            <thead>
              <tr className="text-left text-caption text-p4a-grey">
                <th className="px-2" colSpan={3} />
                <th className={`px-2 pb-1 font-semibold ${sep}`} colSpan={CRM_FIELDS.length}>{t.sourceCrm}</th>
                <th className={`px-2 pb-1 font-semibold ${sep}`} colSpan={TELEPHONY_FIELDS.length}>{t.sourceTelephony}</th>
                <th className={`px-2 pb-1 font-semibold ${sep}`} colSpan={COMMERCE_FIELDS.length}>{t.sourceShop}</th>
              </tr>
              <tr className="bg-p4a-bgblue text-left text-p4a-heading">
                <th className={th}>{copy.reports.date}</th>
                <th className={th}>{copy.reports.market}</th>
                <th className={`${th} w-24`} title={t.volumeHint}>{t.volume}</th>
                {CRM_FIELDS.map((f, i) => <th key={f} className={`${th} text-right ${i === 0 ? sep : ""}`}>{labels[f]}</th>)}
                {TELEPHONY_FIELDS.map((f, i) => <th key={f} className={`${th} text-right ${i === 0 ? sep : ""}`}>{labels[f]}</th>)}
                {COMMERCE_FIELDS.map((f, i) => <th key={f} className={`${th} text-right ${i === 0 ? sep : ""}`}>{labels[f]}</th>)}
              </tr>
            </thead>
            <tbody>
              {rows.map((x, i) => (
                <tr key={`${x.date}:${x.market}`} className="border-b border-p4a-border">
                  <td className={`${td} tabular`}>{fmtDate(x.date, me.locale, "compact")}</td>
                  <td className={td}>{x.market === "unknown" ? copy.reports.unknownMarket : x.market}</td>
                  <td className={td} title={t.volumeHint}>
                    <div className="h-2 w-20 rounded-full bg-p4a-bgblue">
                      <div className="h-2 rounded-full bg-p4a-deepblue" style={{ width: `${Math.round(shares[i]! * 100)}%` }} />
                    </div>
                  </td>
                  {CRM_FIELDS.map((f, j) => <td key={f} className={`${td} tabular text-right ${j === 0 ? sep : ""}`}>{n(x[f])}</td>)}
                  {sourceCells(x, false)}
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr className="text-p4a-heading" data-testid="intake-total">
                <td className={`${td} font-semibold`} colSpan={3}>{copy.reports.total}</td>
                {CRM_FIELDS.map((f, j) => <td key={f} className={`${td} tabular text-right font-semibold ${j === 0 ? sep : ""}`}>{n(totals[f])}</td>)}
                {sourceCells(totals, true)}
              </tr>
            </tfoot>
          </table>
        )}
      </Card>

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
