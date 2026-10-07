import { redirect } from "next/navigation";
import { Shell } from "@/components/Shell";
import { WorkdayPanel } from "@/components/WorkdayPanel";
import { Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock } from "@/lib/data";
import { firstPage } from "@/lib/nav";
import { fmtDate, fmtTime } from "@/lib/time";
import { resolve } from "./access";

// Login is clock-in: rendering My day opens today's workday if none exists
export default async function MyDayPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  // Someone without a clock (analytics in the default ladder) must never open a workday by
  // visiting: they land on the first page they may see
  if (!me.permissions.includes("workday.own")) redirect(firstPage(me, copy) ?? "/no-access");

  const [workday, statuses] = await Promise.all([
    data().openWorkday(me, new Date().toISOString()),
    data().listStatuses(me),
  ]);

  return (
    <Shell copy={copy} me={me} active="my-day">
      <PageTitle>
        {copy.myDay.title}
        <span className="ml-3 text-small font-normal text-p4a-muted">{fmtDate(workday.date, me.locale)}</span>
      </PageTitle>
      <WorkdayPanel
        workday={workday}
        statuses={statuses}
        startedLabel={fmtTime(workday.startedAt, me.timeZone, me.locale)}
        statusSinceLabel={workday.statusSince ? fmtTime(workday.statusSince, me.timeZone, me.locale) : null}
        endedLabel={workday.endedAt ? fmtTime(workday.endedAt, me.timeZone, me.locale) : null}
        copy={copy}
      />
      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
