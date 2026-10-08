import { redirect } from "next/navigation";
import { Shell } from "@/components/Shell";
import { WeekBar } from "@/components/WeekBar";
import { Badge, Card, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock } from "@/lib/data";
import { firstPage } from "@/lib/nav";
import { cellLabel, shiftMinutes, weekDays } from "@/lib/roster";
import { dateKeyInZone, fmtDate, fmtMinutes, isDateKey, startOfWeek } from "@/lib/time";
import { resolve } from "../access";

/**
 * My schedule (Time group, migration 0005): the person's own week from the published rosters,
 * read only, in their own zone; a week that is not published yet says so. Shown to people
 * holding roster.view; the database answers only the caller's own rows (cma.my_roster, CMA06
 * without the permission). Never a colleague's schedule: that is the planner's.
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
                      cellLabel({ kind: "shift", start: d.start, end: d.end, absenceName: null })
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
