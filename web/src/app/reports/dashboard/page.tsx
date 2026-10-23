import {
  DayChart, GroupLegend, PersonBars, StatusBars, Tile,
} from "@/components/DashboardCharts";
import { DashboardFilter } from "@/components/DashboardFilter";
import { IntakeRow } from "@/components/ReportParts";
import { PeriodBar } from "@/components/PeriodBar";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { byDay, byPerson, byStatus, peopleOf, share, summarise } from "@/lib/dashboard";
import { data, dataIsMock } from "@/lib/data";
import { resolvePeriod } from "@/lib/period";
import { dateKeyInZone, fmtDate, fmtMinutes, fmtPercent } from "@/lib/time";
import { metricsMore } from "@/lib/metrics";
import { resolve } from "../../access";

/** team_status_time answers at most 92 days per request */
const MAX_DAYS = 92;

/**
 * Dashboard (Report, first page of the Reports group): where the team's time went, per status and
 * per flag group, per day and per person. Shown to people holding performance.team (supervisor,
 * manager and analytics in the default ladder); the database checks that permission again on
 * every read (CMA06). Staff data only, never customer data. One read for the time: the person filter
 * narrows the rows of the period on the server, so its list needs no team list. Since B11 (12 October
 * 2026) the Intake row above the time tiles reads the tenant's intake for the period: counts, speed to
 * lead and the not-connected state of telephony and the shop, never a customer's details. Every tile
 * explains itself in a hint (copy.hints).
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

  // The Intake row (B11, migration 0007d and 0006's crm_records_per_day): the tenant's intake for the
  // period, read next to the time per status; the person filter does not apply to it
  // since addition 0008w with the callbacks kept (KPI 5)
  const [all, intake, records, speed, callbacks] = await Promise.all([
    data().getTeamStatusTime(me, period, null),
    data().getIntake(me, period),
    data().getCrmRecordsPerDay(me, period),
    data().getSpeedToLeadRows(me, period),
    data().getCallbacksKept(me, period),
  ]);
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
  // key: the figure's entry in the metric catalog; the link shows only to a holder of tenant.configure
  const info = (label: string, text: string, key?: string) =>
    ({ about: copy.hints.about.replace("{label}", label), text, more: key ? metricsMore(me.permissions, key, copy.hints.howComputed) : undefined });

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

      <IntakeRow intake={intake} records={records} speed={speed} callbacks={callbacks} copy={copy} locale={me.locale} from={period.from}
        canOpenMetrics={me.permissions.includes("tenant.configure")} />

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
            <Tile label={t.worked} info={info(t.worked, copy.hints.worked, "dashboard.time.worked_minutes")} value={fmtMinutes(summary.workedMinutes)} hint={t.workedHint} />
            <Tile label={t.paid} info={info(t.paid, copy.hints.paid, "dashboard.time.paid_minutes")} value={fmtMinutes(summary.paidMinutes)} hint={t.paidHint} />
            <Tile
              label={t.productive}
              info={info(t.productive, copy.hints.productive, "dashboard.time.productive_share")}
              value={fmtPercent(share(summary.productiveSeconds, summary.workedSeconds), me.locale)}
              hint={t.productiveHint.replace("{time}", fmtMinutes(Math.floor(summary.productiveSeconds / 60)))}
            />
            <Tile
              label={t.people}
              info={info(t.people, copy.hints.people, "dashboard.time.people")}
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
