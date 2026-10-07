import {
  DayChart, GroupLegend, PersonBars, StatusBars, Tile,
} from "@/components/DashboardCharts";
import { DashboardFilter } from "@/components/DashboardFilter";
import { PeriodBar } from "@/components/PeriodBar";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { byDay, byPerson, byStatus, peopleOf, share, summarise } from "@/lib/dashboard";
import { data, dataIsMock } from "@/lib/data";
import { resolvePeriod } from "@/lib/period";
import { dateKeyInZone, fmtDate, fmtMinutes, fmtPercent } from "@/lib/time";
import { resolve } from "../../access";

/** team_status_time answers at most 92 days per request */
const MAX_DAYS = 92;

/**
 * Dashboard (Report, first page of the Reports group): where the team's time went, per status and
 * per flag group, per day and per person. Shown to people holding performance.team (supervisor,
 * manager and analytics in the default ladder); the database checks that permission again on
 * every read (CMA06). Staff data only, never customer data. One read per page: the person filter
 * narrows the rows of the period on the server, so its list needs no team list.
 */
export default async function DashboardPage({ searchParams }: PageProps<"/reports/dashboard">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.dashboard;

  if (!me.permissions.includes("performance.team")) {
    return (
      <Shell copy={copy} me={me} active="dashboard">
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
  const { range, period, invalid } = resolvePeriod(sp, today, MAX_DAYS);

  const all = await data().getTeamStatusTime(me, period, null);
  const people = peopleOf(all.rows);
  const person = typeof sp.person === "string" && people.some((p) => p.userId === sp.person) ? sp.person : "";
  const rows = person ? all.rows.filter((x) => x.userId === person) : all.rows;

  const summary = summarise(rows);
  const statuses = byStatus(rows);
  // The day chart stops at today: days still to come have no time yet
  const days = byDay(rows, period.from, period.to < today ? period.to : today);
  const persons = byPerson(rows);
  const query: Record<string, string> =
    range === "custom" && !invalid ? { range, from: period.from, to: period.to } : { range };

  return (
    <Shell copy={copy} me={me} active="dashboard" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>

      <PeriodBar
        pathname="/reports/dashboard"
        range={range}
        period={period}
        today={today}
        copy={copy}
        keep={person ? { person } : {}}
      />

      {invalid ? (
        <div className="mb-6">
          <Notice tone="warning">{invalid === "length" ? t.tooLong : copy.myHours.invalidRange}</Notice>
        </div>
      ) : null}

      <div className="mb-6 flex items-end justify-between gap-4">
        <DashboardFilter people={people} person={person} query={query} copy={copy} />
        <p className="text-caption text-p4a-grey">
          {fmtDate(period.from, me.locale)}
          {period.from !== period.to ? ` – ${fmtDate(period.to, me.locale)}` : ""}
        </p>
      </div>

      {rows.length === 0 ? (
        <Card>
          <p className="text-body text-p4a-muted">{t.empty}</p>
        </Card>
      ) : (
        <div className="flex flex-col gap-6">
          {summary.cappedDays > 0 ? (
            <Notice tone="warning">
              {summary.cappedDays === 1 ? t.cappedNoteOne : t.cappedNote.replace("{n}", String(summary.cappedDays))}
            </Notice>
          ) : null}

          <div className="grid grid-cols-4 gap-4">
            <Tile label={t.worked} value={fmtMinutes(summary.workedMinutes)} hint={t.workedHint} />
            <Tile label={t.paid} value={fmtMinutes(summary.paidMinutes)} hint={t.paidHint} />
            <Tile
              label={t.productive}
              value={fmtPercent(share(summary.productiveSeconds, summary.workedSeconds), me.locale)}
              hint={t.productiveHint.replace("{time}", fmtMinutes(Math.floor(summary.productiveSeconds / 60)))}
            />
            <Tile
              label={t.people}
              value={String(summary.people)}
              hint={summary.personDays === 1 ? t.peopleHintOne : t.peopleHint.replace("{n}", String(summary.personDays))}
            />
          </div>

          <Card>
            <GroupLegend groups={summary.groups} copy={copy} />
          </Card>

          <Card title={t.byStatus}>
            <p className="-mt-2 mb-4 text-caption text-p4a-grey">{t.byStatusHint}</p>
            <StatusBars statuses={statuses} clockedSeconds={summary.clockedSeconds} copy={copy} locale={me.locale} />
          </Card>

          {days.length > 1 ? (
            <Card title={t.byDay}>
              <DayChart days={days} copy={copy} locale={me.locale} />
            </Card>
          ) : null}

          <Card title={t.byPerson}>
            <p className="-mt-2 mb-4 text-caption text-p4a-grey">{t.byPersonHint}</p>
            <PersonBars people={persons} copy={copy} />
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
