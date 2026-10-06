import { PeriodBar } from "@/components/PeriodBar";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock } from "@/lib/data";
import { resolvePeriod } from "@/lib/period";
import { dateKeyInZone, fmtDate, fmtMinutes, fmtTime } from "@/lib/time";
import { resolve } from "../access";

export default async function MyHoursPage({ searchParams }: PageProps<"/hours">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;

  const sp = await searchParams;
  const today = dateKeyInZone(new Date(), me.timeZone);
  const { range, period, invalid } = resolvePeriod(sp, today);

  // Own hours only: the principal is the caller, there is no user parameter
  const hours = await data().getHours(me, period);
  return (
    <Shell copy={copy} me={me} active="my-hours">
      <PageTitle>{copy.myHours.title}</PageTitle>

      <PeriodBar pathname="/hours" range={range} period={period} today={today} copy={copy} />

      {invalid ? (
        <div className="mb-6">
          <Notice tone="warning">{copy.myHours.invalidRange}</Notice>
        </div>
      ) : null}

      <Card>
        <p className="mb-4 text-caption text-p4a-grey">
          {fmtDate(period.from, me.locale)}
          {period.from !== period.to ? ` – ${fmtDate(period.to, me.locale)}` : ""}
          {" · "}
          {copy.myHours.ownHoursOnly}
        </p>
        {hours.days.length === 0 ? (
          <p className="text-body text-p4a-muted">{copy.myHours.empty}</p>
        ) : (
          <table className="w-full border-collapse text-body">
            <thead>
              <tr className="bg-p4a-bgblue text-left text-small font-semibold text-p4a-heading">
                <th className="h-10 px-3 font-semibold">{copy.myHours.date}</th>
                <th className="h-10 px-3 text-right font-semibold">{copy.myHours.start}</th>
                <th className="h-10 px-3 text-right font-semibold">{copy.myHours.end}</th>
                <th className="h-10 px-3 text-right font-semibold">{copy.myHours.duration}</th>
              </tr>
            </thead>
            <tbody>
              {hours.days.map((d) => (
                <tr key={d.date} className="h-10 border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50">
                  <td className="px-3">{fmtDate(d.date, me.locale)}</td>
                  <td className="tabular px-3 text-right">{d.startedAt ? fmtTime(d.startedAt, me.timeZone, me.locale) : ""}</td>
                  <td className="tabular px-3 text-right">
                    {d.endedAt ? fmtTime(d.endedAt, me.timeZone, me.locale) : <span className="text-p4a-muted">{copy.myHours.stillWorking}</span>}
                  </td>
                  <td className="tabular px-3 text-right">{fmtMinutes(d.minutes)}</td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr className="h-10 font-semibold">
                <td className="px-3" colSpan={3}>{copy.myHours.total}</td>
                <td className="tabular px-3 text-right">{fmtMinutes(hours.totalMinutes)}</td>
              </tr>
            </tfoot>
          </table>
        )}
      </Card>

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
