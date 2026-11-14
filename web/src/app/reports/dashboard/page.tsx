import {
  DayChart, GroupLegend, PersonBars, StatusBars, Tile,
} from "@/components/DashboardCharts";
import { DashboardFilter } from "@/components/DashboardFilter";
import { HeaderHint } from "@/components/HeaderHint";
import { Part, ReadsTrace } from "@/components/HeadStart";
import { IntakeRow } from "@/components/IntakeRow";
import { PeriodBar } from "@/components/PeriodBar";
import { Shell } from "@/components/Shell";
import { Card, Keycap, Notice, PageTitle } from "@/components/primitives";
import type { Principal } from "@/lib/auth/identity";
import type { Copy } from "@/lib/copy";
import { byDay, byPerson, byStatus, peopleOf, share, summarise } from "@/lib/dashboard";
import { data, dataIsMock, streamed, type HoursRange, type TeamStatusTime } from "@/lib/data";
import { DASHBOARD_HEAD_MS, DASHBOARD_PARTS, blankNumbers, deadlineIn, headStart } from "@/lib/head-start";
import { resolvePeriod } from "@/lib/period";
import { dateKeyInZone, fmtDate, fmtMinutes, fmtPercent } from "@/lib/time";
import { metricsMore } from "@/lib/metrics";
import { resolve } from "../../access";

/** team_status_time answers at most 92 days per request */
const MAX_DAYS = 92;
/** A person's id as the address carries it: checked against the people of the period once the time is read */
const PERSON = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Dashboard (Report, first page of the Reports group): where the team's time went, per status and
 * per flag group, per day and per person. Shown to people holding performance.team (supervisor,
 * manager and analytics in the default ladder); the database checks that permission again in
 * both of the page's transactions (CMA06). Staff data only, never customer data. One read for the time: the person filter
 * narrows the rows of the period on the server, so its list needs no team list. Since B11 (12 October
 * 2026) the Intake row above the time tiles reads the tenant's intake for the period: counts, speed to
 * lead and the not-connected state of telephony and the shop, never a customer's details. Every tile
 * explains itself in a hint (copy.hints).
 *
 * Since 12 November 2026 the page's three parts arrive on their own with a head start (lib/head-start): the time per
 * status and the Intake row's counts from one transaction (the time handed over first), the speed to lead from a second
 * beside it. What is in within
 * DASHBOARD_HEAD_MS is drawn with the page; a read still on its way streams in behind outlines of its own size, so a
 * long period shows its time at once and the dear intake reads when they land, instead of everything after the slowest.
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
  const asked = typeof sp.person === "string" && PERSON.test(sp.person) ? sp.person : "";

  // The three parts, on two connections side by side, counted as streamed (the first paint's cost is the identity's
  // alone): the time per status, then, in the same transaction, the Intake row's counts (B11, migration 0007d and 0006's
  // crm_records_per_day; since addition 0008w with the callbacks kept, KPI 5), to which the person filter does not apply;
  // beside them the speed to lead, the dearest.
  // late (the test data only): parts held back past the head start, so the outlines can be seen and verified
  const late = dataIsMock && typeof sp.late === "string" ? sp.late.split(",") : [];
  const held = <T,>(part: (typeof DASHBOARD_PARTS)[number], read: Promise<T>) => (late.includes(part) ? read.then(async (v) => { await deadlineIn(3 * DASHBOARD_HEAD_MS); return v; }) : read);
  const deadline = deadlineIn(DASHBOARD_HEAD_MS);
  const reads = streamed(() => data().getDashboardReads(me, period));
  const timeRead = held("time", reads.time);
  const countsRead = held("counts", reads.counts);
  const speedRead = held("speed", reads.speed);
  const [time, counts, speed] = await Promise.all([headStart(timeRead, deadline), headStart(countsRead, deadline), headStart(speedRead, deadline)]);

  // the boundaries' key: what the reads are of
  const k = `${period.from}|${period.to}`;
  // the period links keep the person: the one asked for when the time is still on its way, else only one of the period's people
  const keepPerson = time.ready ? (peopleOf(time.value.rows).some((p) => p.userId === asked) ? asked : "") : asked;
  const query: Record<string, string> =
    range === "custom" && !invalid ? { range, from: period.from, to: period.to } : { range };
  const caption = `${fmtDate(period.from, me.locale)}${period.from !== period.to ? ` – ${fmtDate(period.to, me.locale)}` : ""}`;

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
        keep={{ ...(keepPerson ? { person: keepPerson } : {}), ...(late.length > 0 && typeof sp.late === "string" ? { late: sp.late } : {}) }}
      />

      {invalid ? (
        <div className="mb-6">
          <Notice tone="warning">{invalid === "length" ? t.tooLong : copy.myHours.invalidRange}</Notice>
        </div>
      ) : null}

      <IntakeRow counts={counts} speed={speed} k={k} copy={copy} locale={me.locale} from={period.from}
        canOpenMetrics={me.permissions.includes("tenant.configure")} />

      <Part head={time} k={`time|${k}`} fallback={<TimeOutline me={me} copy={copy} caption={caption} />}>
        {(all) => <TimeSection all={all} asked={asked} me={me} copy={copy} period={period} today={today} query={query} caption={caption} />}
      </Part>

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
      <ReadsTrace reads={[timeRead, countsRead, speedRead]} />
    </Shell>
  );
}

/** Where the team's time went: the person filter over the period's rows, the four tiles, the groups, per status, per day, per person */
function TimeSection({ all, asked, me, copy, period, today, query, caption }: {
  all: TeamStatusTime; asked: string; me: Principal; copy: Copy; period: HoursRange; today: string; query: Record<string, string>; caption: string;
}) {
  const t = copy.dashboard;
  const people = peopleOf(all.rows);
  const person = people.some((p) => p.userId === asked) ? asked : "";
  const rows = person ? all.rows.filter((x) => x.userId === person) : all.rows;

  const summary = summarise(rows);
  const statuses = byStatus(rows);
  // The day chart stops at today: days still to come have no time yet
  const days = byDay(rows, period.from, period.to < today ? period.to : today);
  const persons = byPerson(rows);
  // key: the figure's entry in the metric catalog; the link shows only to a holder of tenant.configure
  const info = (label: string, text: string, key?: string) =>
    ({ about: copy.hints.about.replace("{label}", label), text, more: key ? metricsMore(me.permissions, key, copy.hints.howComputed) : undefined });

  return (
    <div data-testid="dashboard-time">
      <div className="mb-6 flex items-end justify-between gap-4">
        <DashboardFilter people={people} person={person} query={query} labels={{ person: t.person, everyone: t.everyone }} />
        <p className="text-caption text-p4a-grey">{caption}</p>
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
    </div>
  );
}

/**
 * The time section while its read is on its way: the filter's place, the period, the four tiles with their labels and
 * an outline for each figure, and the first cards' places. Nothing stands below it, so what it becomes moves nothing
 */
function TimeOutline({ me, copy, caption }: { me: Principal; copy: Copy; caption: string }) {
  const t = copy.dashboard;
  const wait = <span className="inline-block w-16 animate-pulse rounded-input bg-p4a-border" aria-hidden="true">&nbsp;</span>;
  // the tile as the figures' one draws it (DashboardCharts Tile): its label and info mark, an outline for the figure,
  // the hint's words with its number left blank at a number's width
  const tile = (label: string, text: string, key: string, hint: string) => (
    <div className="rounded-card border border-p4a-border bg-white p-5" data-tile="" data-tile-waiting="" aria-busy="true">
      <p className="flex items-start text-caption text-p4a-grey" data-hint-anchor="">
        {label}
        <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} more={metricsMore(me.permissions, key, copy.hints.howComputed)} />
      </p>
      <p className="tabular mt-1 text-title font-bold text-p4a-heading">{wait}</p>
      <p className="mt-1 text-small text-p4a-muted">{blankNumbers(hint).map((part, i) => (part.blank ? <span key={i} className="invisible">{part.text}</span> : part.text))}</p>
    </div>
  );
  return (
    <div data-testid="dashboard-time-outline" aria-busy="true">
      <div className="mb-6 flex items-end justify-between gap-4">
        <div className="flex flex-col gap-2 text-small font-semibold">
          <span className="flex items-center gap-2">{t.person} <Keycap>P</Keycap></span>
          <div className="h-10 min-w-64 animate-pulse rounded-input border border-p4a-border bg-white" aria-hidden="true" />
        </div>
        <p className="text-caption text-p4a-grey">{caption}</p>
      </div>
      <div className="flex flex-col gap-6">
        <div className="grid grid-cols-4 gap-4">
          {tile(t.worked, copy.hints.worked, "dashboard.time.worked_minutes", t.workedHint)}{tile(t.paid, copy.hints.paid, "dashboard.time.paid_minutes", t.paidHint)}
          {tile(t.productive, copy.hints.productive, "dashboard.time.productive_share", t.productiveHint)}{tile(t.people, copy.hints.people, "dashboard.time.people", t.peopleHint)}
        </div>
        <div className="h-24 animate-pulse rounded-card border border-p4a-border bg-white" aria-hidden="true" />
        <div className="h-64 animate-pulse rounded-card border border-p4a-border bg-white" aria-hidden="true" />
      </div>
    </div>
  );
}
