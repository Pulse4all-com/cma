import { PeriodBar } from "@/components/PeriodBar";
import { Shell } from "@/components/Shell";
import { TeamHoursView, type HoursRow } from "@/components/TeamHoursView";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock, type TeamDay } from "@/lib/data";
import { offsetMinutesAt } from "@/lib/corrections";
import { resolvePeriod } from "@/lib/period";
import { dateKeyInZone, fmtDate, fmtMinutes, fmtTime, fmtZoneShort } from "@/lib/time";
import { resolve } from "../../access";

/** team_hours answers at most 92 days per request */
const MAX_DAYS = 92;

/**
 * Team hours (Report): clock-in and clock-out per person per day, with Correct a day and Add day.
 * Shown to people holding workday.team; the database checks that permission again on every read
 * and every correction (CMA06). Staff data only, never customer data.
 */
export default async function TeamHoursPage({ searchParams }: PageProps<"/team/hours">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.teamHours;

  if (!me.permissions.includes("workday.team")) {
    return (
      <Shell copy={copy} me={me} active="team-hours">
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

  const people = await data().listTeamPeople(me);
  const person = typeof sp.person === "string" && people.some((p) => p.userId === sp.person) ? sp.person : "";
  const [hours, statuses] = await Promise.all([
    data().getTeamHours(me, period, person || null),
    data().listStatuses(me),
  ]);

  const chips = (d: TeamDay): HoursRow["chips"] => {
    const out: HoursRow["chips"] = [];
    if (d.status === "open" && !d.isCapped) out.push({ tone: "info", label: t.stillClockedIn });
    if (d.isCapped) out.push({ tone: "warning", label: t.notClockedOut });
    else if (d.needsCorrection) out.push({ tone: "warning", label: t.needsCorrection });
    if (d.hasCorrection) out.push({ tone: "neutral", label: t.corrected });
    return out;
  };

  const rows: HoursRow[] = hours.days.map((d) => ({
    key: `${d.userId}:${d.date}`,
    userId: d.userId,
    displayName: d.displayName,
    organisationName: d.organisationName,
    date: d.date,
    dateLabel: fmtDate(d.date, me.locale, "compact"),
    timeZone: d.timeZone,
    inLabel: fmtTime(d.startedAt, d.timeZone, me.locale),
    outLabel: d.endedAt ? fmtTime(d.endedAt, d.timeZone, me.locale) : null,
    // Only when the person's clock differs from the viewer's at that moment (London, not Amsterdam)
    zoneLabel:
      offsetMinutesAt(Date.parse(d.startedAt), d.timeZone) !== offsetMinutesAt(Date.parse(d.startedAt), me.timeZone)
        ? fmtZoneShort(d.startedAt, d.timeZone, me.locale)
        : null,
    workedLabel: fmtMinutes(d.minutes),
    paidLabel: fmtMinutes(d.paidMinutes),
    chips: chips(d),
    own: d.userId === me.userId,
  }));
  const sum = (f: (d: TeamDay) => number) => fmtMinutes(hours.days.reduce((n, d) => n + f(d), 0));

  const query: Record<string, string> =
    range === "custom" && !invalid ? { range, from: period.from, to: period.to } : { range };

  return (
    <Shell copy={copy} me={me} active="team-hours" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>

      <PeriodBar
        pathname="/team/hours"
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

      <Card>
        <p className="mb-4 text-caption text-p4a-grey">
          {fmtDate(period.from, me.locale)}
          {period.from !== period.to ? ` – ${fmtDate(period.to, me.locale)}` : ""}
        </p>
        <TeamHoursView
          rows={rows}
          totals={{ worked: sum((d) => d.minutes), paid: sum((d) => d.paidMinutes) }}
          people={people}
          person={person}
          query={query}
          meId={me.userId}
          today={today}
          statuses={statuses}
          copy={copy}
          locale={me.locale}
        />
      </Card>

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
