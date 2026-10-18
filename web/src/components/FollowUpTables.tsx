/**
 * The three tables of Follow-up (addition 0008o): leads not called, tickets against their response time,
 * open tasks. Shared by Reports → Follow-up (every row, with the owner) and Waiting for you (the person's
 * own rows, no owner column). Server components. Ids, codes, counts and the names of the organisation's
 * own people only: a customer's name, number or address never reaches these rows, nor a task's text. An
 * owner not linked to a person reads Not mapped, never as an id. Every header explains itself in a hint
 * (copy.hints). Tables follow docs/style/Pulse4all-Style.md 7.6: rows of at least 40 px, zebra rows, a
 * hover row; the state badges in the palette's tones, no filled red cell. Since addition 0008s the headers
 * stay here and the rows go to the client body FollowUpRows as short formatted cells, so the page's
 * 10-second refresh carries values rather than every cell's markup.
 */
import type { ReactNode } from "react";
import type { Copy, Locale } from "@/lib/copy";
import type { DueState, OpenLead, OpenTask, OpenTicket, SlaState } from "@/lib/data";
import { bucketLabel } from "@/lib/follow-up";
import { fillHint, fmtBusinessMinutes, fmtCount } from "@/lib/reports";
import { fmtDateTime } from "@/lib/time";
import { FollowUpRows, type Cell, type CellRow } from "./FollowUpRows";
import { HeaderHint } from "./HeaderHint";
import { Badge, type BadgeTone } from "./primitives";

const th = "h-10 px-3 py-1 font-semibold";

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

// The rows are drawn by the client body FollowUpRows from short cells (addition 0008s): one entry per column
function ownerCell(r: { ownerUserId: string | null; ownerName: string | null; ownerRef: string | null }, copy: Copy): Cell {
  const t = copy.followUp;
  if (r.ownerUserId !== null) return r.ownerName ?? t.notMapped;
  return { m: r.ownerRef !== null ? t.notMapped : t.noOwner };
}

function marketCell(code: string | null, copy: Copy): Cell {
  return code === null || code === "unknown" ? { m: copy.reports.unknownMarket } : code;
}

function slaTone(state: SlaState, copy: Copy): [BadgeTone, string] {
  const t = copy.followUp;
  switch (state) {
    case "ok": return ["success", t.stateOk];
    case "at_risk": return ["warning", t.stateAtRisk];
    case "breached": return ["error", t.stateBreached];
    case "no_hours": return ["neutral", t.stateNoHours];
  }
}

function dueTone(state: DueState, copy: Copy): [BadgeTone, string] {
  const t = copy.followUp;
  switch (state) {
    case "overdue": return ["error", t.dueOverdue];
    case "today": return ["warning", t.dueToday];
    case "later": return ["neutral", t.dueLater];
    case "none": return ["neutral", t.dueNone];
  }
}

export function slaBadge(state: SlaState, copy: Copy): ReactNode {
  const [tone, label] = slaTone(state, copy);
  return <Badge tone={tone}>{label}</Badge>;
}

export function dueBadge(state: DueState, copy: Copy): ReactNode {
  const [tone, label] = dueTone(state, copy);
  return <Badge tone={tone}>{label}</Badge>;
}

const badge = ([b, v]: [BadgeTone, string]): Cell => ({ b, v });

export function LeadsTable({ rows, ctx, empty, testId = "follow-up-leads" }: { rows: OpenLead[]; ctx: TableContext; empty: string; testId?: string }) {
  const t = ctx.copy.followUp;
  const h = ctx.copy.hints;
  if (rows.length === 0) return <p className="text-body text-p4a-muted" data-testid={`${testId}-empty`}>{empty}</p>;
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
        <FollowUpRows columns={leadColumns(ctx)} rows={rows.map((l) => leadRow(l, ctx))} />
      </table>
    </div>
  );
}

export function TicketsTable({ rows, ctx, empty, testId = "follow-up-tickets" }: { rows: OpenTicket[]; ctx: TableContext; empty: string; testId?: string }) {
  const t = ctx.copy.followUp;
  const h = ctx.copy.hints;
  if (rows.length === 0) return <p className="text-body text-p4a-muted" data-testid={`${testId}-empty`}>{empty}</p>;
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
        <FollowUpRows columns={ticketColumns(ctx)} rows={rows.map((x) => ticketRow(x, ctx))} />
      </table>
    </div>
  );
}

export function TasksTable({ rows, ctx, empty, testId = "follow-up-tasks" }: { rows: OpenTask[]; ctx: TableContext; empty: string; testId?: string }) {
  const t = ctx.copy.followUp;
  const h = ctx.copy.hints;
  if (rows.length === 0) return <p className="text-body text-p4a-muted" data-testid={`${testId}-empty`}>{empty}</p>;
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
        <FollowUpRows columns={taskColumns(ctx)} rows={rows.map((k) => taskRow(k, ctx))} />
      </table>
    </div>
  );
}

// ---- The cells of each row, in the header's column order ------------------------------------------

function leadColumns(ctx: TableContext): string[] {
  return ["font-semibold", "", "", ...(ctx.withOwner ? [""] : []), "tabular", "tabular text-right", "", "", "tabular", "text-right"];
}

function leadRow(l: OpenLead, ctx: TableContext): CellRow {
  const { copy, locale, timeZone } = ctx;
  const t = copy.followUp;
  const bucket = bucketLabel(l.bucketFrom, l.bucketTo);
  const n = (x: number) => fmtCount(x, locale);
  return {
    k: l.dealId,
    c: [
      l.dealSourceId,
      l.pipelineLabel,
      marketCell(l.market, copy),
      ...(ctx.withOwner ? [ownerCell(l, copy)] : []),
      fmtDateTime(l.createdAt, timeZone, locale),
      fmtBusinessMinutes(l.waitingBusinessSeconds === null ? null : Math.floor(l.waitingBusinessSeconds / 60), locale),
      bucket === null ? { m: t.noHours } : t.ageDays.replace("{bucket}", bucket),
      l.pastTarget === true ? { b: "error", v: t.pastTarget } : l.pastTarget === false ? { b: "success", v: t.withinTarget } : { b: "neutral", v: t.noHours },
      l.lastCallDays === null ? { m: t.lastCallNone }
        : l.lastCallDays === 0 ? t.lastCallToday : l.lastCallDays === 1 ? t.lastCallDaysOne : t.lastCallDays.replace("{n}", n(l.lastCallDays)),
      { u: l.recordUrl, l: t.openRecord.replace("{type}", t.deal.toLowerCase()).replace("{id}", l.dealSourceId) },
    ],
  };
}

function ticketColumns(ctx: TableContext): string[] {
  return ["font-semibold", "", "", "", ...(ctx.withOwner ? [""] : []), "tabular text-right", "tabular text-right", "", "tabular text-right", "text-right"];
}

function ticketRow(x: OpenTicket, ctx: TableContext): CellRow {
  const { copy, locale } = ctx;
  const t = copy.followUp;
  const n = (v: number) => fmtCount(v, locale);
  return {
    k: x.ticketId,
    c: [
      x.ticketSourceId,
      x.pipelineLabel,
      x.stageLabel ?? { m: "–" },
      marketCell(x.market, copy),
      ...(ctx.withOwner ? [ownerCell(x, copy)] : []),
      fmtBusinessMinutes(x.openBusinessSeconds === null ? null : Math.floor(x.openBusinessSeconds / 60), locale),
      t.minutes.replace("{n}", n(x.slaMinutes)),
      badge(slaTone(x.slaState, copy)),
      x.minutesToBreach === null ? { m: "–" }
        : x.minutesToBreach < 0 ? { e: t.minutesOver.replace("{n}", n(-x.minutesToBreach)) }
        : t.minutes.replace("{n}", n(x.minutesToBreach)),
      { u: x.recordUrl, l: t.openRecord.replace("{type}", t.ticket.toLowerCase()).replace("{id}", x.ticketSourceId) },
    ],
  };
}

function taskColumns(ctx: TableContext): string[] {
  return ["font-semibold", "", "", "", ...(ctx.withOwner ? [""] : []), "tabular", "", "", "text-right"];
}

function taskRow(k: OpenTask, ctx: TableContext): CellRow {
  const { copy, locale, timeZone } = ctx;
  const t = copy.followUp;
  return {
    k: k.taskId,
    c: [
      k.taskSourceId,
      k.isCallback ? { v: k.typeLabel, tag: ["info", t.callback] } : k.typeLabel,
      k.priorityRef ?? { m: "–" },
      k.statusLabel,
      ...(ctx.withOwner ? [ownerCell(k, copy)] : []),
      k.dueAt ? fmtDateTime(k.dueAt, timeZone, locale) : { m: "–" },
      badge(dueTone(k.dueState, copy)),
      k.recordType === "deal" ? t.recordDeal.replace("{id}", k.recordSourceId ?? "")
        : k.recordType === "ticket" ? t.recordTicket.replace("{id}", k.recordSourceId ?? "") : { m: t.noRecord },
      { u: k.recordUrl, l: t.openRecord.replace("{type}", t.task.toLowerCase()).replace("{id}", k.taskSourceId) },
    ],
  };
}
