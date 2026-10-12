import { HeaderHint } from "@/components/HeaderHint";
import { PeriodBar } from "@/components/PeriodBar";
import { GroupSwitch, NoReportPermission, RecordLink } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import type { Copy, Locale } from "@/lib/copy";
import { data, dataIsMock, type SpeedToLeadGroup, type SpeedToLeadSummaryRow } from "@/lib/data";
import { holdsAny } from "@/lib/nav";
import { resolvePeriod } from "@/lib/period";
import {
  fillHint, fmtBusinessMinutes, fmtCount, fmtPct, groupDisplay, MAX_REPORT_DAYS, openNotCalled, parseGroup, REPORT_PERMISSIONS,
  summaryTotals, targetMinutesOf,
} from "@/lib/reports";
import { dateKeyInZone, fmtDate, fmtTime } from "@/lib/time";
import { resolve } from "../../access";

function groupLabel(row: SpeedToLeadSummaryRow, group: SpeedToLeadGroup, copy: Copy, locale: Locale): string {
  const d = groupDisplay(row, group);
  switch (d.kind) {
    case "date": return fmtDate(d.date, locale, "compact");
    case "text": return d.text;
    case "notMapped": return copy.speedToLead.notMapped;
    case "unknownMarket": return copy.reports.unknownMarket;
    case "unknownPipeline": return copy.speedToLead.unknownPipeline;
  }
}

/**
 * Speed to lead (Report, B11): how fast new lead deals got their first outbound call, in office time of
 * the deal's market (cma.speed_to_lead_summary and cma.speed_to_lead_rows, migration 0007d), grouped
 * by day, market, agent or pipeline (G cycles), then the open deals not called with a link to the
 * record. Shown to people holding reports.view or performance.team; the database checks again on
 * every read. Deal ids, codes and counts only: no customer name, email or phone number. An agent
 * whose owner is not mapped shows as Not mapped, never as an owner id. Every header explains itself in
 * a hint (copy.hints), the target and office hours filled in from the tenant's settings.
 */
export default async function SpeedToLeadPage({ searchParams }: PageProps<"/reports/speed-to-lead">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.speedToLead;

  if (!holdsAny(me, REPORT_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="speed-to-lead">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={copy.reports.noPermissionTitle} body={copy.reports.noPermissionBody} />
      </Shell>
    );
  }

  const sp = await searchParams;
  const today = dateKeyInZone(new Date(), me.timeZone);
  const { range, period, invalid } = resolvePeriod(sp, today, MAX_REPORT_DAYS);
  const group = parseGroup(sp.group) ?? "day";

  const [summary, rows] = await Promise.all([
    data().getSpeedToLeadSummary(me, period, group),
    data().getSpeedToLeadRows(me, period),
  ]);
  const totals = summaryTotals(summary.rows);
  const open = openNotCalled(rows);
  const targetMinutes = targetMinutesOf(rows);
  const h = copy.hints;
  const hint = (label: string, text: string) => (
    <HeaderHint label={h.about.replace("{label}", label)} text={fillHint(text, { hours: h.officeHours, target: targetMinutes }, me.locale)} />
  );
  const groupHint: Record<SpeedToLeadGroup, string> = { day: h.day, market: h.market, agent: h.agent, pipeline: h.pipeline };
  const periodQuery: Record<string, string> =
    range === "custom" && !invalid ? { range, from: period.from, to: period.to } : { range };
  const n = (x: number) => fmtCount(x, me.locale);
  // Headers may wrap at 1280 px, so the label and its info mark fit without widening the table
  const th = "h-10 px-3 py-1 font-semibold";
  const td = "h-10 whitespace-nowrap px-3";

  return (
    <Shell copy={copy} me={me} active="speed-to-lead" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>

      <PeriodBar pathname="/reports/speed-to-lead" range={range} period={period} today={today} copy={copy} keep={{ group }} />

      {invalid ? (
        <div className="mb-6">
          <Notice tone="warning">{invalid === "length" ? copy.reports.tooLong : copy.myHours.invalidRange}</Notice>
        </div>
      ) : null}

      <div className="mb-6 flex items-end justify-between gap-4">
        <GroupSwitch group={group} query={periodQuery} copy={copy} />
        <p className="text-caption text-p4a-grey">
          {fmtDate(period.from, me.locale)}
          {period.from !== period.to ? ` – ${fmtDate(period.to, me.locale)}` : ""}
        </p>
      </div>

      <div className="flex flex-col gap-6">
        <Card>
          {summary.rows.length === 0 ? (
            <p className="text-body text-p4a-muted">{t.empty}</p>
          ) : (
            <>
              <table className="w-full border-collapse text-body" data-testid="speed-summary">
                <thead>
                  <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
                    <th className={th}>{t[group]}{hint(t[group], groupHint[group])}</th>
                    <th className={`${th} text-right`}>{t.deals}{hint(t.deals, h.deals)}</th>
                    <th className={`${th} text-right`}>{t.called}{hint(t.called, h.called)}</th>
                    <th className={`${th} text-right`}>{t.median}{hint(t.median, h.median)}</th>
                    <th className={`${th} text-right`}>{t.p80}{hint(t.p80, h.p80)}</th>
                    <th className={`${th} text-right`}>{t.withinTarget}{hint(t.withinTarget, h.withinTarget)}</th>
                    <th className={`${th} text-right`}>{t.beforeNoon}{hint(t.beforeNoon, h.beforeNoon)}</th>
                    <th className={`${th} text-right`}>{t.openNotCalled}{hint(t.openNotCalled, h.openNotCalled)}</th>
                  </tr>
                </thead>
                <tbody>
                  {summary.rows.map((x) => (
                    <tr key={x.groupKey} className="border-b border-p4a-border">
                      <td className={`${td} font-semibold`}>{groupLabel(x, group, copy, me.locale)}</td>
                      <td className={`${td} tabular text-right`}>{n(x.deals)}</td>
                      <td className={`${td} tabular text-right`}>{n(x.called)}</td>
                      <td className={`${td} tabular text-right`}>{fmtBusinessMinutes(x.medianBusinessMinutes, me.locale)}</td>
                      <td className={`${td} tabular text-right`}>{fmtBusinessMinutes(x.p80BusinessMinutes, me.locale)}</td>
                      <td className={`${td} tabular text-right`}>{fmtPct(x.withinTargetPct, me.locale)}</td>
                      <td className={`${td} tabular text-right`}>{fmtPct(x.beforeNextNoonPct, me.locale)}</td>
                      <td className={`${td} tabular text-right`}>{n(x.openNotCalled)}</td>
                    </tr>
                  ))}
                </tbody>
                <tfoot>
                  <tr className="font-semibold text-p4a-heading" title={t.totalNote}>
                    <td className={td}>{copy.reports.total}</td>
                    <td className={`${td} tabular text-right`}>{n(totals.deals)}</td>
                    <td className={`${td} tabular text-right`}>{n(totals.called)}</td>
                    <td className={`${td} text-right text-p4a-muted`} colSpan={4}>
                      <span className="sr-only">{t.totalNote}</span>
                    </td>
                    <td className={`${td} tabular text-right`}>{n(totals.openNotCalled)}</td>
                  </tr>
                </tfoot>
              </table>
              <p className="mt-4 text-caption text-p4a-grey">
                {t.minutesNote.replace("{n}", targetMinutes !== null ? n(targetMinutes) : "–")}
              </p>
            </>
          )}
        </Card>

        <Card title={t.openTitle}>
          <p className="-mt-2 mb-4 text-caption text-p4a-grey">{t.openHint}</p>
          {open.length === 0 ? (
            <p className="text-body text-p4a-muted">{t.openEmpty}</p>
          ) : (
            <table className="w-full border-collapse text-body" data-testid="open-not-called">
              <thead>
                <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
                  <th className={th}>{t.deal}{hint(t.deal, h.deal)}</th>
                  <th className={th}>{t.created}{hint(t.created, h.created)}</th>
                  <th className={th}>{copy.reports.market}{hint(copy.reports.market, h.market)}</th>
                  <th className={th}>{t.pipeline}{hint(t.pipeline, h.pipeline)}</th>
                  <th className={`${th} text-right`}>{t.waiting}{hint(t.waiting, h.waiting)}</th>
                  <th className={`${th} w-12`}><span className="sr-only">{t.openTitle}</span></th>
                </tr>
              </thead>
              <tbody>
                {open.map((x) => (
                  <tr key={x.dealId} className="border-b border-p4a-border last:border-b-0">
                    <td className={`${td} tabular`}>{x.dealSourceId}</td>
                    <td className={`${td} tabular`}>
                      {fmtDate(x.date, me.locale, "compact")} {fmtTime(x.createdAt, me.timeZone, me.locale)}
                    </td>
                    <td className={td}>{x.market === "unknown" ? copy.reports.unknownMarket : x.market}</td>
                    <td className={td}>{x.pipelineLabel ?? t.unknownPipeline}</td>
                    <td className={`${td} tabular text-right`}>
                      {x.waitingBusinessSeconds === null ? (
                        <span className="text-small text-p4a-muted" title={t.noBusinessHoursHint}>{t.noBusinessHours}</span>
                      ) : (
                        fmtBusinessMinutes(Math.floor(x.waitingBusinessSeconds / 60), me.locale)
                      )}
                    </td>
                    <td className={`${td} text-right`}>
                      <RecordLink url={x.recordUrl} label={t.openRecord.replace("{id}", x.dealSourceId)} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </Card>
      </div>

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
