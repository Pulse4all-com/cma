import { HeaderHint } from "@/components/HeaderHint";
import { PeriodBar } from "@/components/PeriodBar";
import { InboundGroupSwitch, NoReportPermission, NotConnected } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import type { Copy, Locale } from "@/lib/copy";
import { data, dataIsMock, type InboundFigures, type InboundGroup, type InboundServiceRow } from "@/lib/data";
import { holdsAny } from "@/lib/nav";
import { resolvePeriod } from "@/lib/period";
import {
  ANSWERED_CLASS, fillHint, fmtAnswerSeconds, fmtCount, fmtPct, inboundBar, inboundGroupDisplay, MAX_REPORT_DAYS, parseInboundGroup,
  reasonColumns, REPORT_PERMISSIONS, unansweredPct, WAITING_CLASS, type ReasonColumn,
} from "@/lib/reports";
import { dateKeyInZone, fmtDate } from "@/lib/time";
import { resolve } from "../../access";

function groupLabel(row: InboundServiceRow, group: InboundGroup, copy: Copy, locale: Locale): string {
  const d = inboundGroupDisplay(row, group);
  switch (d.kind) {
    case "date": return fmtDate(d.date, locale, "compact");
    case "text": return d.text;
    case "hour": return copy.inbound.hourLabel.replace("{hour}", d.hour);
    case "unknownMarket": return copy.reports.unknownMarket;
    case "unknownLine": return copy.inbound.unknownLine;
  }
}

/** The row's calls as one small stacked bar: answered, then each reason in the columns' colours, then waiting */
function Bar({ f, columns, copy }: { f: InboundFigures; columns: ReasonColumn[]; copy: Copy }) {
  const label = new Map<string, string>([["answered", copy.inbound.answeredLegend], ["waiting", copy.inbound.waitingLegend],
    ...columns.map((c) => [c.code, c.label] as [string, string])]);
  return (
    <div className="flex h-2 w-24 overflow-hidden rounded-full bg-p4a-bgblue" data-testid="inbound-bar">
      {inboundBar(f, columns).map((p) => (
        <div key={p.key} className={`h-2 ${p.className}`} style={{ width: `${(p.share * 100).toFixed(2)}%` }} title={`${label.get(p.key) ?? p.key}: ${p.count}`} />
      ))}
    </div>
  );
}

/**
 * Inbound (Report, addition 0008i, brief B15): the inbound calls on counted lines per day, market, line
 * or hour (G cycles), with the calls offered and answered, the unanswered share, the service level, the
 * average and 80th percentile time to answer and one column per missed reason that occurs, labelled from
 * the tenant's catalog, a total row computed by the database over every call, and a small stacked bar per
 * row (answered, then the reasons in the style's series, never a red). Tables, cards and charts follow
 * docs/style/Pulse4all-Style.md 7.3 to 7.8 (body 14px with a 13px header row, zebra rows, a hover row, the
 * total row Semi Bold Inkt). Shown to people holding reports.view or performance.team; the database
 * checks again on every read. A tenant without telephony sees "No telephony connected", never 0. Counts,
 * codes and line names only: no number, no name, never the caller's hash. Every header explains itself
 * in a hint, the service level's seconds filled in from the tenant's settings. The table scrolls
 * sideways inside its card where it is wider (1280 px).
 */
export default async function InboundPage({ searchParams }: PageProps<"/reports/inbound">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.inbound;

  if (!holdsAny(me, REPORT_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="inbound">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={copy.reports.noPermissionTitle} body={copy.reports.noPermissionBody} />
      </Shell>
    );
  }

  const sp = await searchParams;
  const today = dateKeyInZone(new Date(), me.timeZone);
  const { range, period, invalid } = resolvePeriod(sp, today, MAX_REPORT_DAYS);
  const group = parseInboundGroup(sp.group) ?? "day";
  const report = await data().getInboundService(me, period, group);
  const columns = reasonColumns(report.rows, report.reasons, t.unknownReason);
  const showWaiting = report.total.waiting > 0;
  const periodQuery: Record<string, string> =
    range === "custom" && !invalid ? { range, from: period.from, to: period.to } : { range };

  const h = copy.hints;
  const fill = (text: string) => fillHint(text, { hours: h.officeHours, seconds: report.serviceLevelSeconds, minutes: report.waitingMaxMinutes }, me.locale);
  const hint = (label: string, text: string) => <HeaderHint label={h.about.replace("{label}", label)} text={fill(text)} />;
  const groupHint: Record<InboundGroup, string> = { day: h.inboundDay, market: h.inboundMarket, line: h.inboundLine, hour: h.inboundHour };
  const n = (x: number) => fmtCount(x, me.locale);
  const th = "h-10 px-2 py-1 font-semibold";
  const td = "h-10 whitespace-nowrap px-2";
  const sep = "border-l border-p4a-border";

  function figures(f: InboundFigures, bold: boolean) {
    const cls = `${td} tabular text-right ${bold ? "font-semibold" : ""}`;
    return (
      <>
        <td className={td}><Bar f={f} columns={columns} copy={copy} /></td>
        <td className={cls}>{n(f.offered)}</td>
        <td className={cls}>{n(f.answered)}</td>
        <td className={cls}>{fmtPct(unansweredPct(f), me.locale)}</td>
        <td className={cls}>{fmtPct(f.serviceLevelPct, me.locale)}</td>
        <td className={cls}>{fmtAnswerSeconds(f.avgAnswerSeconds, me.locale)}</td>
        <td className={cls}>{fmtAnswerSeconds(f.p80AnswerSeconds, me.locale)}</td>
        {showWaiting ? <td className={cls}>{n(f.waiting)}</td> : null}
        {columns.map((c, i) => <td key={c.code} className={`${cls} ${i === 0 ? sep : ""}`}>{n(f.unansweredByReason[c.code] ?? 0)}</td>)}
      </>
    );
  }

  return (
    <Shell copy={copy} me={me} active="inbound" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>

      <PeriodBar pathname="/reports/inbound" range={range} period={period} today={today} copy={copy} keep={{ group }} />

      {invalid ? (
        <div className="mb-6">
          <Notice tone="warning">{invalid === "length" ? copy.reports.tooLong : copy.myHours.invalidRange}</Notice>
        </div>
      ) : null}

      <div className="mb-6 flex items-end justify-between gap-4">
        <InboundGroupSwitch group={group} query={periodQuery} copy={copy} />
        <p className="text-caption text-p4a-grey">
          {fmtDate(period.from, me.locale)}
          {period.from !== period.to ? ` – ${fmtDate(period.to, me.locale)}` : ""}
        </p>
      </div>

      <Card>
        {!report.telephony ? (
          <p className="text-body" data-testid="inbound-not-connected">
            <NotConnected label={copy.reports.noTelephony} hint={copy.reports.noTelephonyHint} />
            <span className="ml-2 text-small text-p4a-muted">{copy.reports.noTelephonyHint}</span>
          </p>
        ) : report.rows.length === 0 ? (
          <p className="text-body text-p4a-muted">{t.empty}</p>
        ) : (
          <>
            <ul className="mb-4 flex flex-wrap items-center gap-x-4 gap-y-2 text-caption text-p4a-grey" aria-label={t.legend} data-testid="inbound-legend">
              <li className="flex items-center gap-2"><span aria-hidden="true" className={`inline-block h-2.5 w-2.5 rounded-full ${ANSWERED_CLASS}`} />{t.answeredLegend}</li>
              {columns.map((c) => (
                <li key={c.code} className="flex items-center gap-2"><span aria-hidden="true" className={`inline-block h-2.5 w-2.5 rounded-full ${c.className}`} />{c.label}</li>
              ))}
              {showWaiting ? <li className="flex items-center gap-2"><span aria-hidden="true" className={`inline-block h-2.5 w-2.5 rounded-full ${WAITING_CLASS}`} />{t.waitingLegend}</li> : null}
            </ul>
            <div className="overflow-x-auto" data-testid="inbound-scroll" role="region" aria-label={t.title} tabIndex={0}>
              <table className="w-full border-collapse text-body" data-testid="inbound-table">
                <thead>
                  <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
                    <th className={th}>{t[group]}{hint(t[group], groupHint[group])}</th>
                    <th className={`${th} w-28`}>{t.calls}{hint(t.calls, h.inboundBar)}</th>
                    <th className={`${th} text-right`}>{t.offered}{hint(t.offered, h.offered)}</th>
                    <th className={`${th} text-right`}>{t.answered}{hint(t.answered, h.answered)}</th>
                    <th className={`${th} text-right`}>{t.unansweredPct}{hint(t.unansweredPct, h.unansweredPct)}</th>
                    <th className={`${th} text-right`}>{t.serviceLevel}{hint(t.serviceLevel, h.serviceLevel)}</th>
                    <th className={`${th} text-right`}>{t.avgAnswer}{hint(t.avgAnswer, h.avgAnswer)}</th>
                    <th className={`${th} text-right`}>{t.p80Answer}{hint(t.p80Answer, h.p80Answer)}</th>
                    {showWaiting ? <th className={`${th} text-right`}>{t.waiting}{hint(t.waiting, h.inboundWaiting)}</th> : null}
                    {columns.map((c, i) => (
                      <th key={c.code} className={`${th} text-right ${i === 0 ? sep : ""}`} data-reason={c.code}>
                        <span className="inline-flex items-center gap-1">
                          <span aria-hidden="true" className={`inline-block h-2.5 w-2.5 shrink-0 rounded-full ${c.className}`} />
                          {c.label}
                        </span>
                        {hint(c.label, c.countsInServiceLevel ? h.reason : `${h.reason} ${t.notInServiceLevel}.`)}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {report.rows.map((x) => (
                    <tr key={x.groupKey} className="border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50">
                      <td className={`${td} font-semibold`}>{groupLabel(x, group, copy, me.locale)}</td>
                      {figures(x, false)}
                    </tr>
                  ))}
                </tbody>
                <tfoot>
                  <tr className="text-p4a-body" data-testid="inbound-total">
                    <td className={`${td} font-semibold`}>{copy.reports.total}</td>
                    {figures(report.total, true)}
                  </tr>
                </tfoot>
              </table>
            </div>
            <p className="mt-4 text-caption text-p4a-grey">{fill(t.slNote)}</p>
          </>
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
