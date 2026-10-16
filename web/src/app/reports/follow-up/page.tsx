import type { ReactNode } from "react";
import { FollowUpFilters } from "@/components/FollowUpFilters";
import { LeadsTable, TasksTable, TicketsTable, type TableContext } from "@/components/FollowUpTables";
import { HeaderHint } from "@/components/HeaderHint";
import { LiveRefresh } from "@/components/LiveRefresh";
import { NoReportPermission } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import type { Copy } from "@/lib/copy";
import { data, dataIsMock, type FollowUpOwner, type FollowUpSummary } from "@/lib/data";
import {
  filterLeads, filterOptions, filterTasks, filterTickets, FOLLOW_UP_BY_OWNER_PERMISSION, FOLLOW_UP_PERMISSIONS, parseFollowUpFilter, summarise,
} from "@/lib/follow-up";
import { holdsAny } from "@/lib/nav";
import { fillHint, fmtCount } from "@/lib/reports";
import { resolve } from "../../access";

type TileKey = keyof FollowUpSummary;
const TILES: readonly TileKey[] = ["leadsOpenNotCalled", "leadsPastTarget", "ticketsAtRisk", "ticketsBreached", "ticketsWithoutOwner", "tasksOverdue", "tasksDueToday", "tasksUnmappedOwner"];

function Tile({ label, info, value, testId }: { label: string; info: { about: string; text: string }; value: ReactNode; testId: string }) {
  return (
    <div className="rounded-card border border-p4a-border bg-white p-5" data-testid={testId} data-tile="">
      <p className="flex items-start text-small text-p4a-muted" data-hint-anchor="">
        {label}
        <HeaderHint label={info.about} text={info.text} />
      </p>
      <div className="tabular mt-1 whitespace-nowrap text-title font-bold text-p4a-heading">{value}</div>
    </div>
  );
}

/**
 * Follow-up (Reports, addition 0008o, night run N16-B): what is waiting right now, read every 10 seconds
 * while the tab is open (LiveRefresh): the eight counts as tiles, then the open lead deals not called
 * (cma.open_leads), the open tickets against their response time (cma.open_tickets) and the open tasks
 * (cma.open_tasks), each with a link to the record in its own system, and for performance.team the figures
 * per person (cma.follow_up_by_owner; per-person figures sit under the employee-monitoring point, like Calls
 * per agent). The market (K), person (O) and state (S) filters narrow the three lists; the tiles count
 * everything. Shown to people holding reports.view, performance.team or monitoring.live; the database checks
 * again on every read. Ids, codes, counts and the names of the organisation's own people only: no customer
 * name, number or address, never a task's text. Every header explains itself in a hint (copy.hints), the
 * target and the warning share filled in from the tenant's settings.
 */
export default async function FollowUpPage({ searchParams }: PageProps<"/reports/follow-up">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.followUp;

  if (!holdsAny(me, FOLLOW_UP_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="follow-up">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={t.noPermissionTitle} body={t.noPermissionBody} />
      </Shell>
    );
  }

  const filter = parseFollowUpFilter(await searchParams);
  const canByOwner = me.permissions.includes(FOLLOW_UP_BY_OWNER_PERMISSION);
  const [leads, tickets, tasks, byOwner, settings] = await Promise.all([
    data().getOpenLeads(me), data().getOpenTickets(me), data().getOpenTasks(me),
    canByOwner ? data().getFollowUpByOwner(me) : Promise.resolve(null),
    data().listSettings(me),
  ]);
  const setting = (key: string): number | null => {
    const v = settings.find((x) => x.key === key)?.value;
    return v === undefined || !/^\d+$/.test(v) ? null : Number(v);
  };
  const ctx: TableContext = {
    copy, locale: me.locale, timeZone: me.timeZone, withOwner: true,
    targetMinutes: setting("speed_to_lead.target_minutes"), warningPct: setting("tickets.sla_warning_pct"),
  };
  // The tiles count everything waiting; the filters narrow the lists below them
  const summary = summarise(leads, tickets, tasks);
  const options = filterOptions(leads, tickets, tasks);
  const shownLeads = filterLeads(leads, filter);
  const shownTickets = filterTickets(tickets, filter);
  const shownTasks = filterTasks(tasks, filter);
  const h = copy.hints;
  const fill = (text: string) => fillHint(text, { hours: h.officeHours, target: ctx.targetMinutes, warning: ctx.warningPct }, me.locale);
  const tileCopy: Record<TileKey, { label: string; hint: string }> = {
    leadsOpenNotCalled: { label: t.tileLeadsOpen, hint: h.fuLeadsOpen },
    leadsPastTarget: { label: t.tileLeadsPast, hint: h.fuLeadsPast },
    ticketsAtRisk: { label: t.tileTicketsAtRisk, hint: h.fuTicketsAtRisk },
    ticketsBreached: { label: t.tileTicketsBreached, hint: h.fuTicketsBreached },
    ticketsWithoutOwner: { label: t.tileTicketsNoOwner, hint: h.fuTicketsNoOwner },
    tasksOverdue: { label: t.tileTasksOverdue, hint: h.fuTasksOverdue },
    tasksDueToday: { label: t.tileTasksToday, hint: h.fuTasksToday },
    tasksUnmappedOwner: { label: t.tileTasksUnmapped, hint: h.fuTasksUnmapped },
  };
  const empty = (all: number, text: string) => (all === 0 ? text : t.filteredEmpty);

  return (
    <Shell copy={copy} me={me} active="follow-up" wide>
      <LiveRefresh />
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>

      <div className="mb-6 grid grid-cols-4 gap-4 2xl:grid-cols-8" data-testid="follow-up-summary">
        {TILES.map((key) => (
          <Tile key={key} testId={`follow-up-tile-${key}`} label={tileCopy[key].label}
            info={{ about: h.about.replace("{label}", tileCopy[key].label), text: fill(tileCopy[key].hint) }} value={fmtCount(summary[key], me.locale)} />
        ))}
      </div>

      <div className="mb-6">
        <FollowUpFilters options={options} filter={filter} copy={copy} />
      </div>

      <div className="flex flex-col gap-6">
        <Card title={t.leadsTitle}>
          <LeadsTable rows={shownLeads} ctx={ctx} empty={empty(leads.length, t.leadsEmpty)} />
        </Card>
        <Card title={t.ticketsTitle}>
          <TicketsTable rows={shownTickets} ctx={ctx} empty={empty(tickets.length, t.ticketsEmpty)} />
        </Card>
        <Card title={t.tasksTitle}>
          <TasksTable rows={shownTasks} ctx={ctx} empty={empty(tasks.length, t.tasksEmpty)} />
        </Card>
        {byOwner ? (
          <Card title={t.byOwnerTitle}>
            <p className="-mt-2 mb-4 text-caption text-p4a-grey">{t.byOwnerIntro}</p>
            <ByOwnerTable rows={byOwner} copy={copy} ctx={ctx} />
          </Card>
        ) : null}
      </div>

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}

function ByOwnerTable({ rows, copy, ctx }: { rows: FollowUpOwner[]; copy: Copy; ctx: TableContext }) {
  const t = copy.followUp;
  const h = copy.hints;
  if (rows.length === 0) return <p className="text-body text-p4a-muted" data-testid="follow-up-by-owner-empty">{t.byOwnerEmpty}</p>;
  const hint = (label: string, text: string) => (
    <HeaderHint label={h.about.replace("{label}", label)} text={fillHint(text, { hours: h.officeHours, target: ctx.targetMinutes, warning: ctx.warningPct }, ctx.locale)} />
  );
  const n = (x: number) => fmtCount(x, ctx.locale);
  const th = "h-10 px-3 py-1 font-semibold";
  const td = "h-10 whitespace-nowrap px-3";
  return (
    <div className="overflow-x-auto">
    <table className="w-full border-collapse text-body leading-table" data-testid="follow-up-by-owner">
      <thead>
        <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
          <th className={th}>{t.person}{hint(t.person, h.fuPerson)}</th>
          <th className={`${th} text-right`}>{t.byOpenLeads}{hint(t.byOpenLeads, h.fuByOpenLeads)}</th>
          <th className={`${th} text-right`}>{t.byLeadsPast}{hint(t.byLeadsPast, h.fuByLeadsPast)}</th>
          <th className={`${th} text-right`}>{t.byOpenTickets}{hint(t.byOpenTickets, h.fuByOpenTickets)}</th>
          <th className={`${th} text-right`}>{t.byTicketsRisk}{hint(t.byTicketsRisk, h.fuByTicketsRisk)}</th>
          <th className={`${th} text-right`}>{t.byTasksOverdue}{hint(t.byTasksOverdue, h.fuByTasksOverdue)}</th>
          <th className={`${th} text-right`}>{t.byTasksToday}{hint(t.byTasksToday, h.fuByTasksToday)}</th>
        </tr>
      </thead>
      <tbody>
        {rows.map((o) => (
          <tr key={o.ownerUserId ?? "none"} className="border-b border-p4a-border last:border-b-0 odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50">
            <td className={`${td} font-semibold`}>{o.ownerUserId === null ? <span className="font-normal text-p4a-muted">{t.notLinkedRow}</span> : o.displayName ?? t.notMapped}</td>
            <td className={`${td} tabular text-right`}>{n(o.openLeads)}</td>
            <td className={`${td} tabular text-right`}>{n(o.leadsPastTarget)}</td>
            <td className={`${td} tabular text-right`}>{n(o.openTickets)}</td>
            <td className={`${td} tabular text-right`}>{n(o.ticketsAtRiskOrBreached)}</td>
            <td className={`${td} tabular text-right`}>{n(o.tasksOverdue)}</td>
            <td className={`${td} tabular text-right`}>{n(o.tasksDueToday)}</td>
          </tr>
        ))}
      </tbody>
    </table>
    </div>
  );
}
