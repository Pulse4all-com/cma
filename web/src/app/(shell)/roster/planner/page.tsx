import { RosterPlanner } from "@/components/RosterPlanner";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock } from "@/lib/data";
import { absenceKeywordList, plannerNeedsTeams, plannerTeam, rosterTeamArg } from "@/lib/roster";
import { addDays, dateKeyInZone, isDateKey, startOfWeek } from "@/lib/time";
import { resolve } from "@/app/access";
import { pickCopy } from "@/lib/copy";
import { plannerWeek } from "@/lib/assignments";

/** Saved weeks shown for browsing: this many weeks back and ahead of the week on screen */
const WEEKS_AROUND = 12;

/**
 * Roster planner (Team group, migration 0005): the week per team as a grid of people by days with
 * quick typing, a publish button with the draft and published state, Copy previous week, the
 * coverage per work type per day, a print view. Since addition 0009zw a Week | Day switch
 * (?view=day&date=): the Day view paints assignments per slot (brief A); the week's read brings the
 * blocks, the planner settings and the type catalog in the same transaction. Shown to people holding roster.manage; the
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
  // One team per page view (brief B41): the team the query names, else Everyone (D1); every read and every control
  // below takes this one key (D2), and the planner writes it into the address when the query lacked it. Everyone
  // needs no team list to resolve, so on Everyone (the rail's default) every read starts at once
  const teamsRead = data().listTeams(me);
  const team = plannerTeam(sp.team, plannerNeedsTeams(sp.team) ? await teamsRead : []);
  const read = rosterTeamArg(team);

  const [teams, week, allWeeks, absences] = await Promise.all([
    teamsRead,
    data().getRosterWeek(me, weekStart, read),
    data().listRosterWeeks(me, read, { from: addDays(weekStart, -7 * WEEKS_AROUND), to: addDays(weekStart, 7 * WEEKS_AROUND + 6) }),
    data().listAbsenceTypes(me),
  ]);
  // The list is a calendar (one row per week in the range, written or not); the browser shows the written ones
  const weeks = allWeeks.filter((w) => w.version > 0 || w.entryCount > 0);

  return (
    <Shell copy={copy} me={me} active="roster" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">
        {t.intro} <span data-testid="absence-keywords">{t.absenceKeywords.replace("{list}", absenceKeywordList(absences.filter((a) => a.isActive)))}</span>
      </p>

      {/* Keyed by the week and the team: another week or team is a new grid, never the previous one's cells under new props */}
      <RosterPlanner
        key={`${weekStart}:${team}`}
        week={plannerWeek(week)}
        weeks={weeks}
        teams={teams}
        team={team}
        absences={absences}
        today={today}
        thisWeek={thisWeek}
        viewerZone={me.timeZone}
        copy={sp.view === "day" ? pickCopy(copy, "dayEditor", "roster", "assignments", "assignmentsDay") : pickCopy(copy, "dayEditor", "roster", "assignments")}
        locale={me.locale}
        view={sp.view === "day" ? "day" : "week"}
        day={isDateKey(sp.date) ? sp.date : undefined}
      />

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
