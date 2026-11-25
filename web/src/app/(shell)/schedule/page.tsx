import { redirect } from "next/navigation";
import { Shell } from "@/components/Shell";
import { WeekBar } from "@/components/WeekBar";
import { Badge, Card, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock } from "@/lib/data";
import { firstPage } from "@/lib/nav";
import { cellLabel, shiftMinutes, weekDays } from "@/lib/roster";
import { dateKeyInZone, fmtDate, fmtMinutes, isDateKey, startOfWeek } from "@/lib/time";
import { resolve } from "@/app/access";
import { instantOf, pct, toMinutes, toneOf, TONE_CLASS } from "@/lib/assignments";
import { localParts } from "@/lib/corrections";
import type { PublishedAssignment } from "@/lib/data";

/**
 * My schedule (Time group, migration 0005): the person's own week from the published rosters,
 * read only, in their own zone; a week that is not published yet says so. Shown to people
 * holding roster.view; the database answers only the caller's own rows (cma.my_roster, CMA06
 * without the permission). Never a colleague's schedule: that is the planner's. Since addition
 * 0009zx each day shows its published assignments as the planner's bar (D13) with the blocks and
 * times listed under it, in the person's zone; a block whose hours market lies in another zone that
 * day (GB for Spain) shows the market's own time after it in brackets.
 */
export default async function MySchedulePage({ searchParams }: PageProps<"/schedule">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.mySchedule;

  if (!me.permissions.includes("roster.view")) {
    const first = firstPage(me, copy);
    if (first && first !== "/schedule") redirect(first);
    return (
      <Shell copy={copy} me={me} active="my-schedule">
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
  const days = weekDays(weekStart);
  const rows = await data().getMyRoster(me, { from: days[0]!, to: days[6]! });
  const plannedMinutes = rows.reduce((n, d) => n + (d.kind === "shift" && d.start && d.end ? shiftMinutes(d.start, d.end) : 0), 0);

  return (
    <Shell copy={copy} me={me} active="my-schedule">
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>

      <WeekBar pathname="/schedule" weekStart={weekStart} thisWeek={thisWeek} copy={copy} locale={me.locale} />

      <Card>
        <table className="w-full border-collapse text-body">
          <tbody>
            {rows.map((d) => {
              const isToday = d.date === today;
              return (
                <tr key={d.date} className={`h-10 border-b border-p4a-border ${isToday ? "bg-p4a-bgblue" : "odd:bg-p4a-offwhite"}`}>
                  <td className="whitespace-nowrap px-3 font-semibold">
                    {fmtDate(d.date, me.locale)}
                    {isToday ? <span className="ml-2"><Badge tone="info">{t.today}</Badge></span> : null}
                  </td>
                  <td className="tabular px-3">
                    {!d.isPublished ? (
                      <span className="text-p4a-muted">{t.notPublished}</span>
                    ) : d.kind === null ? (
                      <span className="text-p4a-muted">{t.noShift}</span>
                    ) : d.kind === "shift" ? (
                      <>
                        {cellLabel({ kind: "shift", start: d.start, end: d.end, absenceName: null })}
                        {d.assignments.length > 0 && d.start && d.end ? (
                          <DayBlocks date={d.date} start={d.start} end={d.end} blocks={d.assignments} zone={me.timeZone} label={copy.assignments.scheduleAssignments} />
                        ) : null}
                      </>
                    ) : (
                      <Badge tone="neutral">{d.absenceName ?? ""}</Badge>
                    )}
                  </td>
                  <td className="px-3 text-small text-p4a-muted">{d.note ?? ""}</td>
                  <td className="whitespace-nowrap px-3 text-right text-small text-p4a-muted">{d.teamName ?? ""}</td>
                </tr>
              );
            })}
          </tbody>
          <tfoot>
            <tr className="text-small font-semibold text-p4a-heading">
              <td className="px-3 py-3">{t.plannedTotal}</td>
              <td className="tabular px-3 py-3">{fmtMinutes(plannedMinutes)}</td>
              <td colSpan={2} />
            </tr>
          </tfoot>
        </table>
      </Card>

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}

/**
 * A day's published blocks (addition 0009zx): the bar across the shift in the planner's colours (D13), then each block
 * with its times, code and name; the code is always text, so colour never carries meaning alone. A block under an hours
 * market whose zone differs from the person's that day shows the market's time in brackets (GB for an agent in Spain)
 */
function DayBlocks({ date, start, end, blocks, zone, label }: { date: string; start: string; end: string; blocks: PublishedAssignment[]; zone: string; label: string }) {
  const s = toMinutes(start);
  const span = Math.max(1, toMinutes(end) - s);
  const there = (b: PublishedAssignment, time: string) => {
    if (!b.hoursMarket || !b.hoursMarketZone || b.hoursMarketZone === zone) return null;
    const at = instantOf(date, time, zone);
    if (at === null) return null;
    const p = localParts(at, b.hoursMarketZone);
    const own = localParts(at, zone);
    return p.time === own.time ? null : p.time;
  };
  return (
    <div className="mt-2 flex flex-col gap-1 pb-2" data-testid="schedule-blocks">
      <div className="relative h-2 w-full max-w-md overflow-hidden rounded-button bg-p4a-neutral-surface" aria-hidden="true">
        {blocks.map((b) => (
          <span key={`${b.start}-${b.code}`} className={`absolute inset-y-0 ${TONE_CLASS[toneOf({ ...b, statusIsProductive: null })]}`}
            style={{ left: `${pct(toMinutes(b.start) - s, span)}%`, width: `${pct(toMinutes(b.end) - toMinutes(b.start), span)}%` }} />
        ))}
      </div>
      <ul aria-label={label} className="flex flex-col text-small">
        {blocks.map((b) => {
          const a = there(b, b.start);
          const z = there(b, b.end);
          return (
            <li key={`${b.start}-${b.code}`} className="tabular">
              {b.start}–{b.end}
              {a && z ? <span className="text-p4a-muted"> ({a}–{z} {b.hoursMarket})</span> : null}
              <span className="ml-2 font-semibold">{b.code}</span> {b.name}
              {b.hoursMarket && !b.ownMarket ? <span className="text-p4a-muted"> · {b.hoursMarket}</span> : null}
            </li>
          );
        })}
      </ul>
    </div>
  );
}
