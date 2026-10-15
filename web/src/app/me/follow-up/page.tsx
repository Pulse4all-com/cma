import { LeadsTable, TasksTable, TicketsTable, type TableContext } from "@/components/FollowUpTables";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock } from "@/lib/data";
import { MY_FOLLOW_UP_PERMISSIONS } from "@/lib/follow-up";
import { holdsAny } from "@/lib/nav";
import { resolve } from "../../access";

/**
 * Waiting for you (addition 0008o, night run N16-B): the person's own rows from cma.my_follow_up: the leads
 * nobody has called whose owner is linked to them on People, their open tickets against their response time
 * and their open tasks, each with a link to the record in its own system. Opened from the Welcome card; no
 * rail item (breadcrumbs: Welcome › Waiting for you). Shown to people holding leads.accept or workday.own;
 * the database checks again and answers the caller's own rows only, whatever role an admin previews as.
 * Ids, codes and counts only: no customer data, never a task's text.
 */
export default async function MyFollowUpPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.followUp;

  if (!holdsAny(me, MY_FOLLOW_UP_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="my-follow-up">
        <PageTitle>{t.myTitle}</PageTitle>
        <Card>
          <h2 className="text-panel font-semibold text-p4a-heading">{t.myNoPermissionTitle}</h2>
          <p className="mt-2 text-body">{t.myNoPermissionBody}</p>
        </Card>
      </Shell>
    );
  }

  const [mine, settings] = await Promise.all([data().getMyFollowUp(me), data().listSettings(me)]);
  const setting = (key: string): number | null => {
    const v = settings.find((x) => x.key === key)?.value;
    return v === undefined || !/^\d+$/.test(v) ? null : Number(v);
  };
  const ctx: TableContext = {
    copy, locale: me.locale, timeZone: me.timeZone, withOwner: false,
    targetMinutes: setting("speed_to_lead.target_minutes"), warningPct: setting("tickets.sla_warning_pct"),
  };
  const total = mine.leads.length + mine.tickets.length + mine.tasks.length;

  return (
    <Shell copy={copy} me={me} active="my-follow-up" wide>
      <PageTitle>{t.myTitle}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.myIntro}</p>
      {total === 0 ? (
        <Card>
          <p className="text-body text-p4a-muted" data-testid="my-follow-up-empty">{t.myEmpty}</p>
        </Card>
      ) : (
        <div className="flex flex-col gap-6">
          <Card title={t.leadsTitle}>
            <LeadsTable rows={mine.leads} ctx={ctx} empty={t.leadsEmpty} testId="my-leads" />
          </Card>
          <Card title={t.ticketsTitle}>
            <TicketsTable rows={mine.tickets} ctx={ctx} empty={t.ticketsEmpty} testId="my-tickets" />
          </Card>
          <Card title={t.tasksTitle}>
            <TasksTable rows={mine.tasks} ctx={ctx} empty={t.tasksEmpty} testId="my-tasks" />
          </Card>
        </div>
      )}
      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
