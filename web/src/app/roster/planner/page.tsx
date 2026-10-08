import { RosterPlanner } from "@/components/RosterPlanner";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock } from "@/lib/data";
import { addDays, dateKeyInZone, isDateKey, startOfWeek } from "@/lib/time";
import { resolve } from "../../access";

/** Saved weeks shown for browsing: this many weeks back and ahead of the week on screen */
const WEEKS_AROUND = 12;

/**
 * Roster planner (Team group, migration 0005): the week per team as a grid of people by days with
 * quick typing, a publish button with the draft and published state, Copy previous week, the
 * coverage per work type per day, a print view. Shown to people holding roster.manage; the
 * database checks that permission on every read and write (CMA06). Staff data only.
 */
export default async function RosterPlannerPage({ searchParams }: PageProps<"/roster/planner">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.roster;

  if (!me.permissions.includes("roster.manage")) {
    return (
      <Shell copy={copy} me={me} active="roster">
        <PageTitle>{t.title}</PageTitle>
        <Card>
          <h2 className="text-panel font-semibold text-p4a-heading">{t.noPermissionTitle}</h2>
          <p className="mt-2 text-body">{t.noPermissionBody}</p>
        </Card>
      </Shell>
    );
  }

  const sp = await searchParams;
  const today = dateKeyInZone(new Date(), me.timeZone);
  const thisWeek = startOfWeek(today);
  const weekStart = isDateKey(sp.week) ? startOfWeek(sp.week) : thisWeek;
  const teams = await data().listTeams(me);
  // The team from the query, else the tenant's first team, else everyone (a tenant without teams)
  const teamParam = typeof sp.team === "string" ? sp.team : null;
  const team = teamParam === "all" ? null : teams.some((x) => x.key === teamParam) ? teamParam : teams[0]?.key ?? null;

  const [week, allWeeks, absences] = await Promise.all([
    data().getRosterWeek(me, weekStart, team),
    data().listRosterWeeks(me, team, { from: addDays(weekStart, -7 * WEEKS_AROUND), to: addDays(weekStart, 7 * WEEKS_AROUND + 6) }),
    data().listAbsenceTypes(me),
  ]);
  // The list is a calendar (one row per week in the range, written or not); the browser shows the written ones
  const weeks = allWeeks.filter((w) => w.version > 0 || w.entryCount > 0);

  return (
    <Shell copy={copy} me={me} active="roster" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>

      <RosterPlanner
        week={week}
        weeks={weeks}
        teams={teams}
        team={team}
        absences={absences}
        today={today}
        thisWeek={thisWeek}
        viewerZone={me.timeZone}
        copy={copy}
        locale={me.locale}
      />

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
