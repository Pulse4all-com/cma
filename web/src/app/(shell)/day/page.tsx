import { redirect } from "next/navigation";
import { ClockInCard } from "@/components/ClockInCard";
import { MyDayPanel } from "@/components/MyDayPanel";
import { Shell } from "@/components/Shell";
import { WorkdayPanel } from "@/components/WorkdayPanel";
import { Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock } from "@/lib/data";
import { firstPage } from "@/lib/nav";
import { dateKeyInZone, fmtDate, fmtTime } from "@/lib/time";
import { resolve } from "@/app/access";

/**
 * My day: the clock and the status buttons. Rendering reads today's day and never opens one
 * (increment e, 7 October 2026): without a day the page shows the Clock in card, the same one as
 * on Welcome, so page 2 never dead-ends on an empty status grid. An ended day the person may clock
 * in again on (addition 0008zp) shows the ended day and, below it, the same card in its "again" variant.
 *
 * Since addition 0010a (brief B) the roster drives the day: the day and its plan against actual (cma.my_day) are read in one
 * transaction, and a tenant with assignment types gets MyDayPanel (Clock in on the plan, the Scheduled and Actual lanes,
 * Switch, Back to plan, the roster's notices). A tenant without assignment types keeps the status buttons and the market
 * select of before (WorkdayPanel): nothing is planned there to follow.
 */
export default async function MyDayPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  // Someone without a clock (analytics in the default ladder) has no day to show: they land on
  // the first page they may see
  if (!me.permissions.includes("workday.own")) redirect(firstPage(me, copy) ?? "/no-access");

  const today = dateKeyInZone(new Date(), me.timeZone);
  // The day and its plan against actual in one transaction (addition 0010a); the Switch choices come with the plan
  const { workday, plan, statusChoices } = await data().getMyDay(me, today);

  if (plan.usesAssignments) {
    return (
      <Shell copy={copy} me={me} active="my-day">
        <PageTitle>
          {copy.myDay.title}
          <span className="ml-3 text-small font-normal text-p4a-muted">{fmtDate(workday?.date ?? today, me.locale)}</span>
        </PageTitle>
        <div className="max-w-[772px]">
          <MyDayPanel workday={workday} plan={plan} timeZone={me.timeZone} locale={me.locale} copy={{ myDay: copy.myDay, welcome: copy.welcome }}
            againUntil={workday?.status === "ended" && workday.canClockInAgain ? fmtTime(workday.dayEndsAt, me.timeZone, me.locale) : null} />
          {workday?.status === "ended" && workday.canClockInAgain ? (
            <div className="mt-6 max-w-md">
              <ClockInCard defaultStatusName={plan.planNow?.name ?? ""} copy={{ welcome: copy.welcome }} againUntil={fmtTime(workday.dayEndsAt, me.timeZone, me.locale)} />
            </div>
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

  // A tenant without assignment types: the status buttons and the market select (0009zo), read in getMyDay's transaction
  const { statuses, hoursMarkets } = statusChoices ?? { statuses: [], hoursMarkets: [] };
  const defaultStatus = statuses.find((s) => s.isDefault);

  return (
    <Shell copy={copy} me={me} active="my-day">
      <PageTitle>
        {copy.myDay.title}
        <span className="ml-3 text-small font-normal text-p4a-muted">{fmtDate(workday?.date ?? today, me.locale)}</span>
      </PageTitle>
      {workday ? (
        <>
          <WorkdayPanel
            workday={workday}
            statuses={statuses}
            hoursMarkets={hoursMarkets}
            startedLabel={fmtTime(workday.startedAt, me.timeZone, me.locale)}
            statusSinceLabel={workday.statusSince ? fmtTime(workday.statusSince, me.timeZone, me.locale) : null}
            endedLabel={workday.endedAt ? fmtTime(workday.endedAt, me.timeZone, me.locale) : null}
            sessionStartedLabel={workday.sessions > 1 ? fmtTime(workday.sessionStartedAt, me.timeZone, me.locale) : null}
            dayEndsLabel={fmtTime(workday.dayEndsAt, me.timeZone, me.locale)}
            timeZone={me.timeZone}
            locale={me.locale}
            copy={{ myDay: copy.myDay }}
          />
          {workday.status === "ended" && workday.canClockInAgain ? (
            <div className="mt-6 max-w-md">
              <ClockInCard defaultStatusName={defaultStatus?.name ?? ""} copy={{ welcome: copy.welcome }} againUntil={fmtTime(workday.dayEndsAt, me.timeZone, me.locale)} />
            </div>
          ) : null}
        </>
      ) : (
        <div className="max-w-md">
          <ClockInCard defaultStatusName={defaultStatus?.name ?? ""} copy={{ welcome: copy.welcome }} />
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
