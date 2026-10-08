import Link from "next/link";
import { ClockInCard } from "@/components/ClockInCard";
import { Swatch } from "@/components/DashboardCharts";
import { Shell } from "@/components/Shell";
import { Badge, Card, Notice } from "@/components/primitives";
import { agentGroupOf } from "@/lib/dashboard";
import { data, dataIsMock, type AppLink, type MyRosterDay, type TeamHours, type WorkStatus, type Workday } from "@/lib/data";
import { cellLabel } from "@/lib/roster";
import type { Copy, Locale } from "@/lib/copy";
import { addDays, dateKeyInZone, fmtDate, fmtMinutes, fmtTime, hourInZone } from "@/lib/time";
import { resolve } from "./access";

/** The to-do line looks back this many days, today excluded */
const TODO_DAYS = 31;

/**
 * Welcome (increment e, 7 October 2026): the landing page for everyone with a role, built as
 * blocks per permission. A visit opens nothing; Clock in is an action on the card. The blocks:
 * updates for everyone (empty until Messaging, migration 0006), the to-do line for people holding
 * workday.team, a Reports block for performance.team (the one view of all KPIs later, Roadmap
 * step 9), the Clock in card for workday.own, and the tenant's app links. Staff data only.
 */
export default async function WelcomePage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.welcome;
  const now = new Date();
  const today = dateKeyInZone(now, me.timeZone);
  const hasClock = me.permissions.includes("workday.own");
  const hasTeam = me.permissions.includes("workday.team");
  const hasReports = me.permissions.includes("performance.team");
  const hasRoster = me.permissions.includes("roster.view");

  // One read per block the person may see; reading never opens a day
  const [workday, statuses, team, links, roster] = await Promise.all([
    hasClock ? data().getWorkday(me, today) : Promise.resolve(null),
    hasClock ? data().listStatuses(me) : Promise.resolve([] as WorkStatus[]),
    hasTeam ? data().getTeamHours(me, { from: addDays(today, -TODO_DAYS), to: addDays(today, -1) }, null) : Promise.resolve(null),
    data().listAppLinks(me),
    hasRoster ? data().getMyRoster(me, { from: today, to: today }) : Promise.resolve([] as MyRosterDay[]),
  ]);
  // The shift sentence the greeting waited for (migration 0005): from the published roster only
  const todayRoster = roster[0] ?? null;
  const shiftLine = !hasRoster || !todayRoster ? null
    : !todayRoster.isPublished ? t.rosterNotPublished
    : todayRoster.kind === "shift" ? t.shiftToday.replace("{shift}", cellLabel({ kind: "shift", start: todayRoster.start, end: todayRoster.end, absenceName: null }))
    : todayRoster.kind === "absence" ? t.absenceToday.replace("{absence}", todayRoster.absenceName ?? "")
    : t.noShiftToday;

  const hour = hourInZone(now, me.timeZone);
  const greeting = (hour < 12 ? t.morning : hour < 18 ? t.afternoon : t.evening).replace("{name}", me.displayName);

  return (
    <Shell copy={copy} me={me} active="welcome">
      <h1 className="text-title font-bold text-p4a-heading">{greeting}</h1>
      <p className="mt-1 text-body text-p4a-muted">
        {fmtDate(today, me.locale)}
        {shiftLine ? <span data-testid="shift-line">{` · ${shiftLine}`}</span> : null}
      </p>

      <div className="mt-8 grid grid-cols-[1fr_18rem] gap-6">
        <div className="flex flex-col gap-6">
          <Card title={t.updates}>
            <p className="text-body text-p4a-muted">{t.updatesEmpty}</p>
          </Card>
          {team ? <TodoBlock team={team} copy={copy} /> : null}
          {hasReports ? (
            <Card title={t.reports}>
              <p className="text-body">{t.reportsBody}</p>
              <Link href="/reports/dashboard" className="mt-3 inline-block font-semibold text-p4a-deepblue hover:underline">
                {t.openDashboard}
              </Link>
            </Card>
          ) : null}
        </div>

        <div className="flex flex-col gap-6">
          {hasClock ? (
            <DayBlock workday={workday} statuses={statuses} timeZone={me.timeZone} locale={me.locale} now={now} copy={copy} />
          ) : null}
          {links.length > 0 ? <AppLinks links={links} copy={copy} /> : null}
        </div>
      </div>

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}

/** The person's own day: Clock in when there is none, the open day's state, or the ended day */
function DayBlock({
  workday, statuses, timeZone, locale, now, copy,
}: {
  workday: Workday | null;
  statuses: WorkStatus[];
  timeZone: string;
  locale: Locale;
  now: Date;
  copy: Copy;
}) {
  const t = copy.welcome;
  if (!workday) {
    const defaultStatus = statuses.find((s) => s.isDefault);
    return <ClockInCard defaultStatusName={defaultStatus?.name ?? ""} copy={copy} />;
  }
  if (workday.status === "ended") {
    return (
      <Card>
        <Badge tone="neutral">{t.dayEnded}</Badge>
        <dl className="mt-4 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-small">
          <dt className="text-p4a-muted">{t.clockedInAt}</dt>
          <dd className="tabular">{fmtTime(workday.startedAt, timeZone, locale)}</dd>
          <dt className="text-p4a-muted">{t.clockedOutAt}</dt>
          <dd className="tabular">{workday.endedAt ? fmtTime(workday.endedAt, timeZone, locale) : ""}</dd>
        </dl>
      </Card>
    );
  }
  const current = statuses.find((s) => s.key === workday.statusKey);
  const running = workday.clock.runningSince ? Math.max(0, now.getTime() - Date.parse(workday.clock.runningSince)) / 1000 : 0;
  const workedMinutes = Math.floor((workday.clock.closedSeconds + running) / 60);
  return (
    <Card>
      <div className="flex items-center gap-3">
        <Badge tone="info">{t.clockedIn}</Badge>
        {current ? (
          <span className="inline-flex items-center gap-2 text-small">
            <Swatch group={agentGroupOf(current)} />
            {current.name}
          </span>
        ) : workday.statusName ? (
          // A status no longer in the choosable list: its name as stored, no colour (no flags here)
          <span className="text-small">{workday.statusName}</span>
        ) : null}
      </div>
      <p className="mt-4 text-small text-p4a-muted">
        {t.clockedInAt} <span className="tabular text-p4a-body">{fmtTime(workday.startedAt, timeZone, locale)}</span>
        {" · "}
        <span className="tabular text-p4a-body">{fmtMinutes(workedMinutes)}</span> {t.workedSoFar}
      </p>
      <Link href="/day" className="mt-4 inline-block font-semibold text-p4a-deepblue hover:underline">
        {t.openMyDay}
      </Link>
    </Card>
  );
}

/** Steam's "to do before today's shift", from Team hours: days not clocked out in the last 31 days */
function TodoBlock({ team, copy }: { team: TeamHours; copy: Copy }) {
  const t = copy.welcome;
  const n = team.days.filter((d) => d.needsCorrection).length;
  const line = n === 0 ? t.notClockedOutNone : n === 1 ? t.notClockedOutOne : t.notClockedOut.replace("{n}", String(n));
  return (
    <Card title={t.todo}>
      <p className="flex items-center gap-3 text-body">
        <Badge tone={n === 0 ? "success" : "warning"}>{n}</Badge>
        {line}
      </p>
      <Link href="/team/hours?range=month" className="mt-3 inline-block font-semibold text-p4a-deepblue hover:underline">
        {t.openTeamHours}
      </Link>
    </Card>
  );
}

/** The tenant's app links, already filtered by the database to what this person may see */
function AppLinks({ links, copy }: { links: AppLink[]; copy: Copy }) {
  const t = copy.welcome;
  return (
    <Card title={t.apps}>
      <ul className="flex flex-col gap-2">
        {links.map((l) => (
          <li key={l.key}>
            <a
              href={l.address}
              target="_blank"
              rel="noopener noreferrer"
              className="flex h-10 items-center justify-between rounded-button border border-p4a-deepblue px-4 font-semibold text-p4a-deepblue no-underline hover:bg-p4a-bgblue"
            >
              {l.label}
              <span aria-hidden="true">↗</span>
            </a>
          </li>
        ))}
      </ul>
      <p className="mt-3 text-caption text-p4a-grey">{t.appsHint}</p>
    </Card>
  );
}
