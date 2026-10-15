import { FollowUpLive } from "@/components/FollowUpLive";
import { InboundLive } from "@/components/InboundLive";
import { LiveBoard, type BoardRow } from "@/components/LiveBoard";
import { LiveRefresh } from "@/components/LiveRefresh";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock, type TeamNowPerson, type TodayShift } from "@/lib/data";
import { employersOf, liveRows, teamKeysByUser, teamsOf, tiles } from "@/lib/live";
import { adherence, cellLabel } from "@/lib/roster";
import { dateKeyInZone, fmtDate, fmtTime, fmtZoneShort, sameOffset } from "@/lib/time";
import { resolve } from "../../access";

/** The planned shift and the flag next to it, from today's published entry and the day's clock */
function shiftLine(
  shift: TodayShift | undefined, person: TeamNowPerson, nowMs: number, tolerance: number,
): BoardRow["shift"] {
  if (!shift || !shift.isPublished) return { label: null, published: false, flag: null };
  const planned = shift.kind ? { kind: shift.kind, start: shift.start, end: shift.end } : null;
  const flag = adherence(planned, { startedAt: person.day?.startedAt ?? null, endedAt: person.day?.endedAt ?? null }, shift.date, person.timeZone, nowMs, tolerance);
  return {
    label: planned ? cellLabel({ kind: planned.kind, start: planned.start, end: planned.end, absenceName: shift.absenceName }) : null,
    published: true,
    flag,
  };
}

/**
 * Live board (Live, first page of the Live group): who is on the clock right now, in which status
 * and since when, with a tile per group. Shown to people holding monitoring.live (supervisor,
 * manager and analytics in the default ladder); the database checks that permission again on
 * every read (CMA06). Today only, Postgres only (the realtime service comes later): the page
 * reads once and the client re-reads it every 10 seconds while the tab is visible. Staff data,
 * never customer data, and no ranking. Since addition 0008i it opens with today's inbound tiles and
 * the missed calls not called back (InboundLive): line names, codes and counts, never a number,
 * a name or the caller's hash.
 */
export default async function LiveBoardPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.live;

  if (!me.permissions.includes("monitoring.live")) {
    return (
      <Shell copy={copy} me={me} active="live-board">
        <PageTitle>{t.title}</PageTitle>
        <Card>
          <h2 className="text-panel font-semibold text-p4a-heading">{t.noPermissionTitle}</h2>
          <p className="mt-2 text-body">{t.noPermissionBody}</p>
        </Card>
      </Shell>
    );
  }

  // Four reads: the team now, the current team memberships (0004), today's published shifts and the
  // adherence tolerance (0005); the flags are derived here from the plan and the clock
  const [now, memberships, shifts, settings, inbound, followUp] = await Promise.all([
    data().getTeamNow(me), data().listTeamMembersNow(me), data().getRosterToday(me), data().listSettings(me), data().getInboundNow(me),
    // the follow-up counts (addition 0008o): leads not called, tickets against their response time, tasks
    data().getFollowUpSummary(me),
  ]);
  const tolerance = Number(settings.find((x) => x.key === "roster.adherence_tolerance_minutes")?.value ?? 5);
  const numberSetting = (key: string): number | null => {
    const v = settings.find((x) => x.key === key)?.value;
    return v === undefined || !/^\d+$/.test(v) ? null : Number(v);
  };
  const shiftOf = new Map(shifts.map((x) => [x.userId, x]));
  const nowMs = new Date().getTime();
  const rows = liveRows(now.people);
  const teamKeys = teamKeysByUser(memberships);
  const teamName = new Map(memberships.map((m) => [m.teamKey, m.teamName]));
  const viewerZone = me.timeZone;
  const board: BoardRow[] = rows.map(({ person, group }) => ({
    userId: person.userId,
    displayName: person.displayName,
    organisationKey: person.organisationKey ?? "",
    organisationName: person.organisationName,
    group,
    statusName: person.status?.name ?? null,
    statusActive: person.status?.isActive ?? true,
    statusSince: person.day?.statusSince ?? null,
    // The clock's inputs; an ended day has nothing running, so its figure stands still
    clock: person.day?.clock ?? null,
    // Times in the person's own zone, as Team hours shows them, with the zone's short name when
    // its clock differs from the viewer's (Madrid and Amsterdam share one, London does not)
    inLabel: person.day ? fmtTime(person.day.startedAt, person.timeZone, me.locale) : null,
    outLabel: person.day?.endedAt ? fmtTime(person.day.endedAt, person.timeZone, me.locale) : null,
    zoneLabel: person.day && !sameOffset(person.day.startedAt, person.timeZone, viewerZone)
      ? fmtZoneShort(person.day.startedAt, person.timeZone, me.locale) : null,
    teams: (teamKeys.get(person.userId) ?? []).map((key) => ({ key, name: teamName.get(key) ?? key })),
    shift: shiftLine(shiftOf.get(person.userId), person, nowMs, tolerance),
  }));

  return (
    <Shell copy={copy} me={me} active="live-board" wide>
      <PageTitle>
        {t.title}
        <span className="ml-3 text-small font-normal text-p4a-muted">{fmtDate(dateKeyInZone(new Date(), me.timeZone), me.locale)}</span>
      </PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>
      <LiveRefresh />

      <div className="mb-8">
        <InboundLive inbound={inbound} copy={copy} locale={me.locale} timeZone={me.timeZone} />
      </div>

      <div className="mb-8">
        <FollowUpLive summary={followUp} copy={copy} locale={me.locale}
          targetMinutes={numberSetting("speed_to_lead.target_minutes")} warningPct={numberSetting("tickets.sla_warning_pct")} />
      </div>

      <h2 className="mb-4 text-panel font-semibold text-p4a-heading">{t.teamTitle}</h2>
      {rows.length === 0 ? (
        <Card>
          <p className="text-body text-p4a-muted">{t.noPeople}</p>
        </Card>
      ) : (
        <LiveBoard
          rows={board}
          tiles={tiles(rows, now.statusFlags)}
          employers={employersOf(rows)}
          teams={teamsOf(rows, memberships)}
          copy={copy}
        />
      )}

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
