/**
 * The three tables of Follow-up (addition 0008o): leads not called, tickets against their response time,
 * open tasks. Shared by Reports → Follow-up (every row, with the owner) and Waiting for you (the person's
 * own rows, no owner column). Server components. Ids, codes, counts and the names of the organisation's
 * own people only: a customer's name, number or address never reaches these rows, nor a task's text. An
 * owner not linked to a person reads Not mapped, never as an id. Every header explains itself in a hint
 * (copy.hints). Tables follow docs/style/Pulse4all-Style.md 7.6: rows of at least 40 px, zebra rows, a
 * hover row; the state badges in the palette's tones, no filled red cell.
 */
import type { ReactNode } from "react";
import type { Copy, Locale } from "@/lib/copy";
import type { DueState, OpenLead, OpenTask, OpenTicket, SlaState } from "@/lib/data";
import { bucketLabel } from "@/lib/follow-up";
import { fillHint, fmtBusinessMinutes, fmtCount } from "@/lib/reports";
import { fmtDateTime } from "@/lib/time";
import { HeaderHint } from "./HeaderHint";
import { RecordLink } from "./ReportParts";
import { Badge } from "./primitives";

const th = "h-10 px-3 py-1 font-semibold";
const td = "h-10 whitespace-nowrap px-3";
const tr = "border-b border-p4a-border last:border-b-0 odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50";

export interface TableContext {
  copy: Copy;
  locale: Locale;
  timeZone: string;
  /** Show the owner column (the report), or leave it out (the person's own rows) */
  withOwner: boolean;
  /** The lead target and the warning share, filled into the hints */
  targetMinutes: number | null;
  warningPct: number | null;
}

function Hint({ ctx, label, text }: { ctx: TableContext; label: string; text: string }) {
  const h = ctx.copy.hints;
  return <HeaderHint label={h.about.replace("{label}", label)} text={fillHint(text, { hours: h.officeHours, target: ctx.targetMinutes, warning: ctx.warningPct }, ctx.locale)} />;
}

function Owner({ ownerUserId, ownerName, ownerRef, copy }: { ownerUserId: string | null; ownerName: string | null; ownerRef: string | null; copy: Copy }) {
  const t = copy.followUp;
  if (ownerUserId !== null) return <>{ownerName ?? t.notMapped}</>;
  if (ownerRef !== null) return <span className="text-p4a-muted">{t.notMapped}</span>;
  return <span className="text-p4a-muted">{t.noOwner}</span>;
}

function market(code: string | null, copy: Copy): ReactNode {
  return code === null || code === "unknown" ? <span className="text-p4a-muted">{copy.reports.unknownMarket}</span> : code;
}

export function slaBadge(state: SlaState, copy: Copy): ReactNode {
  const t = copy.followUp;
  switch (state) {
    case "ok": return <Badge tone="success">{t.stateOk}</Badge>;
    case "at_risk": return <Badge tone="warning">{t.stateAtRisk}</Badge>;
    case "breached": return <Badge tone="error">{t.stateBreached}</Badge>;
    case "no_hours": return <Badge tone="neutral">{t.stateNoHours}</Badge>;
  }
}

export function dueBadge(state: DueState, copy: Copy): ReactNode {
  const t = copy.followUp;
  switch (state) {
    case "overdue": return <Badge tone="error">{t.dueOverdue}</Badge>;
    case "today": return <Badge tone="warning">{t.dueToday}</Badge>;
    case "later": return <Badge tone="neutral">{t.dueLater}</Badge>;
    case "none": return <Badge tone="neutral">{t.dueNone}</Badge>;
  }
}

export function LeadsTable({ rows, ctx, empty, testId = "follow-up-leads" }: { rows: OpenLead[]; ctx: TableContext; empty: string; testId?: string }) {
  const { copy, locale, timeZone } = ctx;
  const t = copy.followUp;
  const h = copy.hints;
  if (rows.length === 0) return <p className="text-body text-p4a-muted" data-testid={`${testId}-empty`}>{empty}</p>;
  const n = (x: number) => fmtCount(x, locale);
  return (
    <div className="overflow-x-auto">
      <table className="w-full border-collapse text-body leading-table" data-testid={testId}>
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            <th className={th}>{t.deal}<Hint ctx={ctx} label={t.deal} text={h.fuDeal} /></th>
            <th className={th}>{t.pipeline}<Hint ctx={ctx} label={t.pipeline} text={h.fuPipeline} /></th>
            <th className={th}>{t.market}<Hint ctx={ctx} label={t.market} text={h.fuMarket} /></th>
            {ctx.withOwner ? <th className={th}>{t.owner}<Hint ctx={ctx} label={t.owner} text={h.fuOwner} /></th> : null}
            <th className={th}>{t.created}<Hint ctx={ctx} label={t.created} text={h.fuCreated} /></th>
            <th className={`${th} text-right`}>{t.waiting}<Hint ctx={ctx} label={t.waiting} text={h.fuWaiting} /></th>
            <th className={th}>{t.age}<Hint ctx={ctx} label={t.age} text={h.fuAge} /></th>
            <th className={th}>{t.target}<Hint ctx={ctx} label={t.target} text={h.fuTarget} /></th>
            <th className={th}>{t.lastCall}<Hint ctx={ctx} label={t.lastCall} text={h.fuLastCall} /></th>
            {/* relative: the read-out-only name is absolutely positioned and would otherwise escape the table's scroll container at 1280 px */}
            <th className={`${th} relative w-12`}><span className="sr-only">{t.open}</span><Hint ctx={ctx} label={t.open} text={h.fuOpenLink} /></th>
          </tr>
        </thead>
        <tbody>
          {rows.map((l) => {
            const bucket = bucketLabel(l.bucketFrom, l.bucketTo);
            return (
              <tr key={l.dealId} className={tr}>
                <td className={`${td} font-semibold`}>{l.dealSourceId}</td>
                <td className={td}>{l.pipelineLabel}</td>
                <td className={td}>{market(l.market, copy)}</td>
                {ctx.withOwner ? <td className={td}><Owner ownerUserId={l.ownerUserId} ownerName={l.ownerName} ownerRef={l.ownerRef} copy={copy} /></td> : null}
                <td className={`${td} tabular`}>{fmtDateTime(l.createdAt, timeZone, locale)}</td>
                <td className={`${td} tabular text-right`}>{fmtBusinessMinutes(l.waitingBusinessSeconds === null ? null : Math.floor(l.waitingBusinessSeconds / 60), locale)}</td>
                <td className={td}>{bucket === null ? <span className="text-p4a-muted">{t.noHours}</span> : t.ageDays.replace("{bucket}", bucket)}</td>
                <td className={td}>
                  {l.pastTarget === true ? <Badge tone="error">{t.pastTarget}</Badge>
                    : l.pastTarget === false ? <Badge tone="success">{t.withinTarget}</Badge>
                    : <Badge tone="neutral">{t.noHours}</Badge>}
                </td>
                <td className={`${td} tabular`}>
                  {l.lastCallDays === null ? <span className="text-p4a-muted">{t.lastCallNone}</span>
                    : l.lastCallDays === 0 ? t.lastCallToday : l.lastCallDays === 1 ? t.lastCallDaysOne : t.lastCallDays.replace("{n}", n(l.lastCallDays))}
                </td>
                <td className={`${td} text-right`}><RecordLink url={l.recordUrl} label={t.openRecord.replace("{type}", t.deal.toLowerCase()).replace("{id}", l.dealSourceId)} /></td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

export function TicketsTable({ rows, ctx, empty, testId = "follow-up-tickets" }: { rows: OpenTicket[]; ctx: TableContext; empty: string; testId?: string }) {
  const { copy, locale } = ctx;
  const t = copy.followUp;
  const h = copy.hints;
  if (rows.length === 0) return <p className="text-body text-p4a-muted" data-testid={`${testId}-empty`}>{empty}</p>;
  const n = (x: number) => fmtCount(x, locale);
  return (
    <div className="overflow-x-auto">
      <table className="w-full border-collapse text-body leading-table" data-testid={testId}>
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            <th className={th}>{t.ticket}<Hint ctx={ctx} label={t.ticket} text={h.fuTicket} /></th>
            <th className={th}>{t.pipeline}<Hint ctx={ctx} label={t.pipeline} text={h.fuTicketPipeline} /></th>
            <th className={th}>{t.stage}<Hint ctx={ctx} label={t.stage} text={h.fuStage} /></th>
            <th className={th}>{t.market}<Hint ctx={ctx} label={t.market} text={h.fuTicketMarket} /></th>
            {ctx.withOwner ? <th className={th}>{t.owner}<Hint ctx={ctx} label={t.owner} text={h.fuTicketOwner} /></th> : null}
            <th className={`${th} text-right`}>{t.openFor}<Hint ctx={ctx} label={t.openFor} text={h.fuOpenFor} /></th>
            <th className={`${th} text-right`}>{t.responseTime}<Hint ctx={ctx} label={t.responseTime} text={h.fuResponseTime} /></th>
            <th className={th}>{t.state}<Hint ctx={ctx} label={t.state} text={h.fuState} /></th>
            <th className={`${th} text-right`}>{t.timeLeft}<Hint ctx={ctx} label={t.timeLeft} text={h.fuTimeLeft} /></th>
            {/* relative: the read-out-only name is absolutely positioned and would otherwise escape the table's scroll container at 1280 px */}
            <th className={`${th} relative w-12`}><span className="sr-only">{t.open}</span><Hint ctx={ctx} label={t.open} text={h.fuOpenLink} /></th>
          </tr>
        </thead>
        <tbody>
          {rows.map((x) => (
            <tr key={x.ticketId} className={tr}>
              <td className={`${td} font-semibold`}>{x.ticketSourceId}</td>
              <td className={td}>{x.pipelineLabel}</td>
              <td className={td}>{x.stageLabel ?? <span className="text-p4a-muted">–</span>}</td>
              <td className={td}>{market(x.market, copy)}</td>
              {ctx.withOwner ? <td className={td}><Owner ownerUserId={x.ownerUserId} ownerName={x.ownerName} ownerRef={x.ownerRef} copy={copy} /></td> : null}
              <td className={`${td} tabular text-right`}>{fmtBusinessMinutes(x.openBusinessSeconds === null ? null : Math.floor(x.openBusinessSeconds / 60), locale)}</td>
              <td className={`${td} tabular text-right`}>{t.minutes.replace("{n}", n(x.slaMinutes))}</td>
              <td className={td}>{slaBadge(x.slaState, copy)}</td>
              <td className={`${td} tabular text-right`}>
                {x.minutesToBreach === null ? <span className="text-p4a-muted">–</span>
                  : x.minutesToBreach < 0 ? <span className="text-p4a-error">{t.minutesOver.replace("{n}", n(-x.minutesToBreach))}</span>
                  : t.minutes.replace("{n}", n(x.minutesToBreach))}
              </td>
              <td className={`${td} text-right`}><RecordLink url={x.recordUrl} label={t.openRecord.replace("{type}", t.ticket.toLowerCase()).replace("{id}", x.ticketSourceId)} /></td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function TasksTable({ rows, ctx, empty, testId = "follow-up-tasks" }: { rows: OpenTask[]; ctx: TableContext; empty: string; testId?: string }) {
  const { copy, locale, timeZone } = ctx;
  const t = copy.followUp;
  const h = copy.hints;
  if (rows.length === 0) return <p className="text-body text-p4a-muted" data-testid={`${testId}-empty`}>{empty}</p>;
  const record = (k: OpenTask): ReactNode => {
    if (k.recordType === "deal") return t.recordDeal.replace("{id}", k.recordSourceId ?? "");
    if (k.recordType === "ticket") return t.recordTicket.replace("{id}", k.recordSourceId ?? "");
    return <span className="text-p4a-muted">{t.noRecord}</span>;
  };
  return (
    <div className="overflow-x-auto">
      <table className="w-full border-collapse text-body leading-table" data-testid={testId}>
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            <th className={th}>{t.task}<Hint ctx={ctx} label={t.task} text={h.fuTask} /></th>
            <th className={th}>{t.type}<Hint ctx={ctx} label={t.type} text={h.fuType} /></th>
            <th className={th}>{t.priority}<Hint ctx={ctx} label={t.priority} text={h.fuPriority} /></th>
            <th className={th}>{t.status}<Hint ctx={ctx} label={t.status} text={h.fuStatus} /></th>
            {ctx.withOwner ? <th className={th}>{t.owner}<Hint ctx={ctx} label={t.owner} text={h.fuTaskOwner} /></th> : null}
            <th className={th}>{t.due}<Hint ctx={ctx} label={t.due} text={h.fuDue} /></th>
            <th className={th}>{t.when}<Hint ctx={ctx} label={t.when} text={h.fuWhen} /></th>
            <th className={th}>{t.record}<Hint ctx={ctx} label={t.record} text={h.fuRecord} /></th>
            {/* relative: the read-out-only name is absolutely positioned and would otherwise escape the table's scroll container at 1280 px */}
            <th className={`${th} relative w-12`}><span className="sr-only">{t.open}</span><Hint ctx={ctx} label={t.open} text={h.fuOpenLink} /></th>
          </tr>
        </thead>
        <tbody>
          {rows.map((k) => (
            <tr key={k.taskId} className={tr}>
              <td className={`${td} font-semibold`}>{k.taskSourceId}</td>
              <td className={td}>
                {k.typeLabel}
                {k.isCallback ? <span className="ml-2"><Badge tone="info">{t.callback}</Badge></span> : null}
              </td>
              <td className={td}>{k.priorityRef ?? <span className="text-p4a-muted">–</span>}</td>
              <td className={td}>{k.statusLabel}</td>
              {ctx.withOwner ? <td className={td}><Owner ownerUserId={k.ownerUserId} ownerName={k.ownerName} ownerRef={k.ownerRef} copy={copy} /></td> : null}
              <td className={`${td} tabular`}>{k.dueAt ? fmtDateTime(k.dueAt, timeZone, locale) : <span className="text-p4a-muted">–</span>}</td>
              <td className={td}>{dueBadge(k.dueState, copy)}</td>
              <td className={td}>{record(k)}</td>
              <td className={`${td} text-right`}><RecordLink url={k.recordUrl} label={t.openRecord.replace("{type}", t.task.toLowerCase()).replace("{id}", k.taskSourceId)} /></td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
