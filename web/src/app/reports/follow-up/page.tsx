import type { ReactNode } from "react";
import { CallbackOwnersTable, CallbackWeeksTable } from "@/components/CallbacksTables";
import { FollowUpFilters } from "@/components/FollowUpFilters";
import { LeadsTable, TasksTable, TicketsTable, type TableContext } from "@/components/FollowUpTables";
import { HeaderHint } from "@/components/HeaderHint";
import { HintLabel } from "@/components/HintLabel";
import { LiveRefresh } from "@/components/LiveRefresh";
import { NoReportPermission, NotConnected } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import type { Copy, Locale } from "@/lib/copy";
import { data, dataIsMock, type FollowUpList, type FollowUpOwner, type FollowUpSummary } from "@/lib/data";
import { CALLBACKS_PER_OWNER_PERMISSION, CALLBACKS_PERMISSIONS, callbackWeeksRange } from "@/lib/callbacks";
import { agoText, FOLLOW_UP_BY_OWNER_PERMISSION, FOLLOW_UP_PERMISSIONS, isStale, parseFollowUpFilter } from "@/lib/follow-up";
import { holdsAny } from "@/lib/nav";
import { fillHint, fmtCount } from "@/lib/reports";
import { dateKeyInZone, fmtDateTime, startOfWeek } from "@/lib/time";
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
 * Follow-up (Reports, addition 0008o, night run N16-B): what is waiting, read every 10 seconds while the tab
 * is open (LiveRefresh): the eight counts as tiles, then the open lead deals not called, the open tickets
 * against their response time and the open tasks, each with a link to the record in its own system, and for
 * performance.team the figures per person (per-person figures sit under the employee-monitoring point, like
 * Calls per agent). The market (K), person (O) and state (S) filters narrow the three lists; the tiles count
 * everything. Since addition 0008s (Decision log, 18 October 2026) the page makes one read, cma.follow_up_page:
 * the figures come from a snapshot computed once a minute ("Updated …" under the title, Muted once older than
 * three minutes), the filters run in the database, and each list shows its first follow_up.list_rows rows with
 * "Showing n of total" and, when there are more, a hint to narrow it with the filters. Shown to people holding
 * reports.view, performance.team or monitoring.live; the database checks again. Ids, codes, counts and the names
 * of the organisation's own people only: no customer name, number or address, never a task's text. Every header
 * explains itself in a hint (copy.hints), the target and the warning share filled in from the tenant's settings.
 * Since addition 0008w (brief N19-A part 4) below the lists the callbacks kept of the last eight ISO weeks, per week
 * for reports.view or performance.team and per person for performance.team, or "No callback type set" in words.
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
  // One read: the snapshot's counts, per person, the filter choices and the three lists after the filter
  const page = await data().getFollowUpPage(me, filter);
  // Per person only for performance.team as the page is seen (a preview narrows it); the database decides for the real person
  const byOwner = me.permissions.includes(FOLLOW_UP_BY_OWNER_PERMISSION) ? page.byOwner : null;
  // Callbacks kept (0008w): the last eight ISO weeks, for the report permissions; per person for performance.team
  const span = callbackWeeksRange(dateKeyInZone(new Date(), me.timeZone));
  const callbacks = holdsAny(me, CALLBACKS_PERMISSIONS) ? await data().getCallbacksKept(me, span) : null;
  const callbackOwners = callbacks?.connected && me.permissions.includes(CALLBACKS_PER_OWNER_PERMISSION) ? await data().getCallbacksPerOwner(me, span) : null;
  const ctx: TableContext = {
    copy, locale: me.locale, timeZone: me.timeZone, withOwner: true,
    targetMinutes: page.settings.targetMinutes, warningPct: page.settings.warningPct,
  };
  // The tiles count everything waiting; the filters narrow the lists below them
  const summary = page.summary;
  const now = new Date();
  const stale = isStale(page.computedAt, now);
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
      <p className={`-mt-2 mb-2 text-small ${stale ? "text-p4a-muted" : "text-p4a-body"}`} data-testid="follow-up-updated" data-stale={stale ? "true" : "false"}>
        <time dateTime={page.computedAt} title={fmtDateTime(page.computedAt, me.timeZone, me.locale)}>
          {t.updated.replace("{when}", agoText(page.computedAt, now, me.locale))}
        </time>
      </p>
      <p className="mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>

      <div className="mb-6 grid grid-cols-4 gap-4 2xl:grid-cols-8" data-testid="follow-up-summary">
        {TILES.map((key) => (
          <Tile key={key} testId={`follow-up-tile-${key}`} label={tileCopy[key].label}
            info={{ about: h.about.replace("{label}", tileCopy[key].label), text: fill(tileCopy[key].hint) }} value={fmtCount(summary[key], me.locale)} />
        ))}
      </div>

      <div className="mb-6">
        <FollowUpFilters options={page.options} filter={filter} t={t} unknownMarket={copy.reports.unknownMarket} />
      </div>

      <div className="flex flex-col gap-6">
        <Card title={t.leadsTitle}>
          <LeadsTable rows={page.leads.rows} ctx={ctx} empty={empty(page.counts.leads, t.leadsEmpty)} />
          <Showing list={page.leads} t={t} locale={me.locale} testId="follow-up-leads-showing" />
        </Card>
        <Card title={t.ticketsTitle}>
          <TicketsTable rows={page.tickets.rows} ctx={ctx} empty={empty(page.counts.tickets, t.ticketsEmpty)} />
          <Showing list={page.tickets} t={t} locale={me.locale} testId="follow-up-tickets-showing" />
        </Card>
        <Card title={t.tasksTitle}>
          <TasksTable rows={page.tasks.rows} ctx={ctx} empty={empty(page.counts.tasks, t.tasksEmpty)} />
          <Showing list={page.tasks} t={t} locale={me.locale} testId="follow-up-tasks-showing" />
        </Card>
        {byOwner ? (
          <Card title={t.byOwnerTitle}>
            <p className="-mt-2 mb-4 text-caption text-p4a-grey">{t.byOwnerIntro}</p>
            <ByOwnerTable rows={byOwner} copy={copy} ctx={ctx} />
          </Card>
        ) : null}
        {callbacks ? (
          <section id="callbacks" className="rounded-card border border-p4a-border bg-white p-6" data-testid="callbacks-kept">
            <h2 className="mb-4 text-panel font-semibold text-p4a-heading">{t.callbacksTitle}</h2>
            {!callbacks.connected ? (
              <p className="text-body" data-testid="callbacks-not-connected">
                <NotConnected label={copy.reports.noCallbacks} hint={copy.reports.noCallbacksHint} />
                <span className="ml-2 text-small text-p4a-muted">{copy.reports.noCallbacksHint}</span>
              </p>
            ) : (
              <>
                <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted">{t.callbacksIntro.replace("{minutes}", fmtCount(callbacks.windowMinutes, me.locale))}</p>
                {callbacks.total.callbacks + callbacks.total.noContact + callbacks.total.noDue === 0 ? <p className="text-body text-p4a-muted">{t.callbacksEmpty}</p> : (
                  <CallbackWeeksTable weeks={callbacks.weeks} from={span.from} to={startOfWeek(span.to)} total={callbacks.total} minutes={callbacks.windowMinutes}
                    copy={copy} locale={me.locale} />
                )}
              </>
            )}
          </section>
        ) : null}
        {callbacks && callbackOwners ? (
          <Card title={t.callbacksByOwnerTitle}>
            <p className="-mt-2 mb-4 max-w-3xl text-caption text-p4a-grey">{t.callbacksByOwnerIntro}</p>
            <CallbackOwnersTable rows={callbackOwners} minutes={callbacks.windowMinutes} copy={copy} locale={me.locale} />
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

/** Under a list: "Showing n of total", and when the list holds more than it shows, how to narrow it */
function Showing({ list, t, locale, testId }: { list: FollowUpList<unknown>; t: Copy["followUp"]; locale: Locale; testId: string }) {
  if (list.total === 0) return null;
  return (
    <p className="mt-3 text-small text-p4a-muted" data-testid={testId}>
      <span className="tabular">{t.showing.replace("{n}", fmtCount(list.rows.length, locale)).replace("{total}", fmtCount(list.total, locale))}</span>
      {list.total > list.rows.length ? <span>{` · ${t.showingHint}`}</span> : null}
    </p>
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
          <th className={th}><HintLabel label={t.person}>{hint(t.person, h.fuPerson)}</HintLabel></th>
          <th className={`${th} text-right`}><HintLabel label={t.byOpenLeads}>{hint(t.byOpenLeads, h.fuByOpenLeads)}</HintLabel></th>
          <th className={`${th} text-right`}><HintLabel label={t.byLeadsPast}>{hint(t.byLeadsPast, h.fuByLeadsPast)}</HintLabel></th>
          <th className={`${th} text-right`}><HintLabel label={t.byOpenTickets}>{hint(t.byOpenTickets, h.fuByOpenTickets)}</HintLabel></th>
          <th className={`${th} text-right`}><HintLabel label={t.byTicketsRisk}>{hint(t.byTicketsRisk, h.fuByTicketsRisk)}</HintLabel></th>
          <th className={`${th} text-right`}><HintLabel label={t.byTasksOverdue}>{hint(t.byTasksOverdue, h.fuByTasksOverdue)}</HintLabel></th>
          <th className={`${th} text-right`}><HintLabel label={t.byTasksToday}>{hint(t.byTasksToday, h.fuByTasksToday)}</HintLabel></th>
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
