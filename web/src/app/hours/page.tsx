import Link from "next/link";
import { Shell } from "@/components/Shell";
import { Card, Keycap, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock, type HoursRange } from "@/lib/data";
import { addDays, dateKeyInZone, endOfMonth, fmtDate, fmtMinutes, fmtTime, isDateKey, startOfMonth, startOfWeek } from "@/lib/time";
import { resolve } from "../access";

type Range = "today" | "week" | "month" | "custom";
const ranges: Range[] = ["today", "week", "month", "custom"];

export default async function MyHoursPage({ searchParams }: PageProps<"/hours">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;

  const sp = await searchParams;
  const rangeParam = typeof sp.range === "string" ? sp.range : "today";
  const range: Range = (ranges as string[]).includes(rangeParam) ? (rangeParam as Range) : "today";
  const today = dateKeyInZone(new Date(), me.timeZone);

  let period: HoursRange;
  let invalid = false;
  switch (range) {
    case "today":
      period = { from: today, to: today };
      break;
    case "week":
      period = { from: startOfWeek(today), to: addDays(startOfWeek(today), 6) };
      break;
    case "month":
      period = { from: startOfMonth(today), to: endOfMonth(today) };
      break;
    case "custom": {
      const from = isDateKey(sp.from) ? sp.from : addDays(today, -6);
      const to = isDateKey(sp.to) ? sp.to : today;
      invalid = from > to;
      period = invalid ? { from: today, to: today } : { from, to };
    }
  }

  // Own hours only: the principal is the caller, there is no user parameter
  const hours = await data().getHours(me, period);
  const labels: Record<Range, string> = {
    today: copy.myHours.today,
    week: copy.myHours.week,
    month: copy.myHours.month,
    custom: copy.myHours.custom,
  };
  const keys: Record<Range, string> = { today: "T", week: "W", month: "M", custom: "C" };

  return (
    <Shell copy={copy} me={me} active="my-hours">
      <PageTitle>{copy.myHours.title}</PageTitle>

      <nav aria-label={copy.myHours.title} className="mb-6 flex gap-2">
        {ranges.map((k) => (
          <Link
            key={k}
            href={{ pathname: "/hours", query: { range: k } }}
            aria-current={k === range ? "page" : undefined}
            data-shortcut={keys[k].toLowerCase()}
            className={[
              "inline-flex h-10 items-center gap-2 rounded-button border px-4 text-body font-semibold",
              k === range
                ? "border-p4a-deepblue bg-p4a-deepblue text-white"
                : "border-p4a-border text-p4a-deepblue hover:bg-p4a-bgblue",
            ].join(" ")}
          >
            {labels[k]}
            <Keycap>{keys[k]}</Keycap>
          </Link>
        ))}
      </nav>

      {range === "custom" ? (
        <form method="get" action="/hours" className="mb-6 flex items-end gap-4">
          <input type="hidden" name="range" value="custom" />
          <label className="flex flex-col gap-2 text-small font-semibold">
            {copy.myHours.from}
            <input
              type="date"
              name="from"
              defaultValue={period.from}
              max={today}
              autoFocus
              className="h-10 rounded-input border border-p4a-border bg-white px-3 font-normal text-p4a-body focus:border-p4a-deepblue"
            />
          </label>
          <label className="flex flex-col gap-2 text-small font-semibold">
            {copy.myHours.to}
            <input
              type="date"
              name="to"
              defaultValue={period.to}
              max={today}
              className="h-10 rounded-input border border-p4a-border bg-white px-3 font-normal text-p4a-body focus:border-p4a-deepblue"
            />
          </label>
          <button type="submit" className="h-10 rounded-button bg-p4a-deepblue px-4 font-semibold text-white hover:bg-p4a-denim">
            {copy.myHours.show}
          </button>
        </form>
      ) : null}

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
