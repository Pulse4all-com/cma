import { HeaderHint } from "@/components/HeaderHint";
import { HintLabel } from "@/components/HintLabel";
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
  OVERALL_CRM_FIELDS, REPORT_PERMISSIONS, TELEPHONY_FIELDS, type IntakeField, type IntakeTotals,
} from "@/lib/reports";
import { dateKeyInZone, fmtDate } from "@/lib/time";
import { resolve } from "../../access";
import { pickCopy } from "@/lib/copy";

/**
 * Intake (Report, B11): per business date and market the counts of cma.intake_per_day (migration
 * 0007d) with a total row and a small bar per row, a market filter (F), and the telephony and shop
 * columns, each shown as not connected when the tenant has no such source (never 0). Shown to people
 * holding reports.view or performance.team; the database checks again on every read. Counts only.
 * Every column header explains itself in a hint (copy.hints). The table scrolls sideways inside its
 * card where it is wider than the card (1280 px), so the page itself never does.
 *
 * Since addition 0009zp (Martin, 24 November 2026) the columns stand in two groups under a header level of their
 * own: Call center work (leads, lead deals in and closed, tickets in and closed; calls in and out, tagged) and Overall
 * (other deals in; the shop). Overall is the quieter group, never a warning (Pulse4all-Style 2.1, 2.3, 7.1, 7.6): a
 * 16 px gap between the groups in every row (7.1's spacing step), its group label underlined in Border grey where Call
 * center work's has the thin Deep Blue divider (7.1), its header cells on Warm Off-White instead of Background Blue,
 * its labels and figures in Muted text. The Volume bar counts call center work only.
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
    formSubmissions: t.leads, leadDealsCreated: t.leadDealsCreated, leadDealsClosed: t.leadDealsClosed, ticketsCreated: t.ticketsCreated,
    ticketsClosed: t.ticketsClosed, callsIn: t.callsIn, callsOut: t.callsOut, taggedCalls: t.taggedCalls,
    otherDealsCreated: t.otherDealsCreated, newCustomers: t.newCustomers, firstOrders: t.firstOrders, repeatOrders: t.repeatOrders,
    renewals: t.renewals,
  };
  const h = copy.hints;
  const hints: Record<IntakeField, string> = {
    formSubmissions: h.leads, leadDealsCreated: h.leadDealsCreated, leadDealsClosed: h.leadDealsClosed,
    ticketsCreated: h.ticketsCreatedClosed, ticketsClosed: h.ticketsCreatedClosed, callsIn: h.calls, callsOut: h.calls,
    taggedCalls: h.taggedCalls, otherDealsCreated: h.otherDealsCreated, newCustomers: h.shop, firstOrders: h.shop,
    repeatOrders: h.shop, renewals: h.shop,
  };
  const hint = (label: string, text: string) => <HeaderHint label={h.about.replace("{label}", label)} text={text} />;
  const n = (x: number | null) => (x === null ? "" : fmtCount(x, me.locale));
  const th = "h-10 px-2 font-semibold";
  const td = "h-10 whitespace-nowrap px-2";
  const sep = "border-l border-p4a-border";
  // Overall, the quieter group: Warm Off-White header cells, Muted labels and figures
  const quiet = "text-p4a-muted";
  const workSpan = CRM_FIELDS.length + TELEPHONY_FIELDS.length;
  const overallSpan = OVERALL_CRM_FIELDS.length + COMMERCE_FIELDS.length;
  /** The 16 px gap between Call center work and Overall, in every row */
  const gap = (key: string) => <td key={key} className="w-4 min-w-4 p-0" aria-hidden="true" />;
  const gapHead = (key: string) => <th key={key} className="w-4 min-w-4 p-0" aria-hidden="true" data-intake-gap="" />;

  /** A row's figures in the table's order: call center work, the gap, overall; a source not connected is one cell saying so */
  function cells(values: Pick<IntakeTotals, IntakeField>, bold: boolean, rowKey: string) {
    const cls = `${td} tabular text-right ${bold ? "font-semibold" : ""}`;
    return (
      <>
        {CRM_FIELDS.map((f, j) => <td key={f} className={`${cls} ${j === 0 ? sep : ""}`}>{n(values[f])}</td>)}
        {telephony
          ? TELEPHONY_FIELDS.map((f, i) => <td key={f} className={`${cls} ${i === 0 ? sep : ""}`}>{n(values[f])}</td>)
          : <td colSpan={TELEPHONY_FIELDS.length} className={`${td} ${sep} text-center`}><NotConnected label={copy.reports.noTelephony} hint={copy.reports.noTelephonyHint} /></td>}
        {gap(`gap-${rowKey}`)}
        {OVERALL_CRM_FIELDS.map((f) => <td key={f} className={`${cls} ${quiet}`} data-group="overall">{n(values[f])}</td>)}
        {commerce
          ? COMMERCE_FIELDS.map((f, i) => <td key={f} className={`${cls} ${quiet} ${i === 0 ? sep : ""}`} data-group="overall">{n(values[f])}</td>)
          : <td colSpan={COMMERCE_FIELDS.length} className={`${td} ${sep} text-center`} data-group="overall"><NotConnected label={copy.reports.noShop} hint={copy.reports.noShopHint} /></td>}
      </>
    );
  }

  /** A column header: Background Blue in Call center work, Warm Off-White and Muted in Overall */
  const head = (f: IntakeField, first: boolean, overall: boolean) => (
    <th key={f} scope="col" className={`${th} text-right ${overall ? `bg-p4a-offwhite ${quiet}` : "bg-p4a-bgblue"} ${first ? sep : ""}`}>
      <HintLabel label={labels[f]}>{hint(labels[f], hints[f])}</HintLabel>
    </th>
  );

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
        <MarketFilter markets={markets} market={market} query={query} copy={pickCopy(copy, "intake", "reports")} />
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
          // The widest report: at 1280 px the table scrolls sideways inside its card, never the page
          <div className="overflow-x-auto" data-testid="intake-scroll" role="region" aria-label={t.title} tabIndex={0}>
            <table className="w-full border-collapse text-small" data-testid="intake-table">
              <thead>
                <tr className="text-left text-small">
                  <th className="px-2" colSpan={3} />
                  <th scope="colgroup" colSpan={workSpan} className="border-b border-p4a-deepblue px-2 pb-1 font-semibold text-p4a-heading" data-testid="intake-group-work">
                    <HintLabel label={t.groupWork}>{hint(t.groupWork, h.groupWork)}</HintLabel>
                  </th>
                  {gapHead("gap-group")}
                  <th scope="colgroup" colSpan={overallSpan} className={`border-b border-p4a-border px-2 pb-1 font-semibold ${quiet}`} data-testid="intake-group-overall">
                    <HintLabel label={t.groupOverall}>{hint(t.groupOverall, h.groupOverall)}</HintLabel>
                  </th>
                </tr>
                <tr className="text-left text-caption text-p4a-grey">
                  <th className="px-2" colSpan={3} />
                  <th className={`px-2 pb-1 pt-2 font-semibold ${sep}`} colSpan={CRM_FIELDS.length}><HintLabel label={t.sourceCrm}>{hint(t.sourceCrm, h.sourceCrm)}</HintLabel></th>
                  <th className={`px-2 pb-1 pt-2 font-semibold ${sep}`} colSpan={TELEPHONY_FIELDS.length}><HintLabel label={t.sourceTelephony}>{hint(t.sourceTelephony, h.sourceTelephony)}</HintLabel></th>
                  {gapHead("gap-source")}
                  <th className="px-2 pb-1 pt-2 font-semibold" colSpan={OVERALL_CRM_FIELDS.length}><HintLabel label={t.sourceCrm}>{hint(t.sourceCrm, h.sourceCrmOverall)}</HintLabel></th>
                  <th className={`px-2 pb-1 pt-2 font-semibold ${sep}`} colSpan={COMMERCE_FIELDS.length}><HintLabel label={t.sourceShop}>{hint(t.sourceShop, h.sourceShop)}</HintLabel></th>
                </tr>
                <tr className="text-left text-p4a-heading">
                  <th scope="col" className={`${th} bg-p4a-bgblue`}><HintLabel label={copy.reports.date}>{hint(copy.reports.date, h.date)}</HintLabel></th>
                  <th scope="col" className={`${th} bg-p4a-bgblue`}><HintLabel label={copy.reports.market}>{hint(copy.reports.market, h.intakeMarket)}</HintLabel></th>
                  <th scope="col" className={`${th} w-24 bg-p4a-bgblue`}><HintLabel label={t.volume}>{hint(t.volume, h.volume)}</HintLabel></th>
                  {CRM_FIELDS.map((f, i) => head(f, i === 0, false))}
                  {TELEPHONY_FIELDS.map((f, i) => head(f, i === 0, false))}
                  {gapHead("gap-head")}
                  {OVERALL_CRM_FIELDS.map((f) => head(f, false, true))}
                  {COMMERCE_FIELDS.map((f, i) => head(f, i === 0, true))}
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
                    {cells(x, false, `${x.date}:${x.market}`)}
                  </tr>
                ))}
              </tbody>
              <tfoot>
                <tr className="text-p4a-heading" data-testid="intake-total">
                  <td className={`${td} font-semibold`} colSpan={3}>{copy.reports.total}</td>
                  {cells(totals, true, "total")}
                </tr>
              </tfoot>
            </table>
          </div>
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
