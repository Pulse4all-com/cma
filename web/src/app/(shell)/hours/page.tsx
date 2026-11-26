import { redirect } from "next/navigation";
import { Shell } from "@/components/Shell";
import { WeekBar } from "@/components/WeekBar";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { TONE_CLASS } from "@/lib/assignments";
import { data, dataIsMock } from "@/lib/data";
import { hoursMinutes, itemLabel, itemTone, laneAxis, laneBox, type LaneItem } from "@/lib/my-day";
import { firstPage } from "@/lib/nav";
import { dateKeyInZone, fmtDate, isDateKey, startOfWeek } from "@/lib/time";
import { resolve } from "@/app/access";

/**
 * My hours (addition 0010a, brief B; Arno's and Kira's artboard 5): the person's own week per assignment and market, read
 * only (E11). The week: worked against planned, one row per assignment and market (dot, code, name, market chip, time and
 * a bar in the type's colour), the pauses apart, not worked. Per day: the Actual lane and the split "MC SE 30m · SL SE
 * 4h 05m · …" with the day's worked total; today "Today, so far"; a day without time "No time kept". Corrections are made
 * in Team hours: the page says whom to ask. Own hours only: the principal is the caller, there is no user parameter, and
 * the database answers the acting user's days alone (cma.my_hours, workday.own). Before 0010a the page showed a period
 * table; the same figures stay on GET /api/v1/me/hours.
 */
export default async function MyHoursPage({ searchParams }: PageProps<"/hours">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  // Own hours exist only for people whose time is kept
  if (!me.permissions.includes("workday.own")) redirect(firstPage(me, copy) ?? "/no-access");
  const t = copy.myHours;

  const sp = await searchParams;
  const today = dateKeyInZone(new Date(), me.timeZone);
  const thisWeek = startOfWeek(today);
  const weekStart = isDateKey(sp.week) ? startOfWeek(sp.week) : thisWeek;
  const week = await data().getMyHoursWeek(me, weekStart);
  const most = Math.max(1, ...week.rows.map((x) => x.seconds));

  return (
    <Shell copy={copy} me={me} active="my-hours">
      <PageTitle>{t.title}</PageTitle>

      <WeekBar pathname="/hours" weekStart={weekStart} thisWeek={thisWeek} copy={copy} locale={me.locale} />

      <div className="flex max-w-[900px] flex-col gap-4">
        <Card>
          <div className="flex flex-wrap items-baseline justify-between gap-3">
            <h2 className="text-panel font-semibold text-p4a-heading">{weekStart === thisWeek ? t.week : `${fmtDate(weekStart, me.locale, "compact")} – ${fmtDate(week.days[6]?.date ?? weekStart, me.locale, "compact")}`}</h2>
            <p className="text-small text-p4a-muted" data-testid="my-hours-week">
              {t.weekWorked.replace("{worked}", hoursMinutes(week.workedSeconds)).replace("{planned}", hoursMinutes(week.plannedMinutes * 60))}
            </p>
          </div>
          {week.rows.length > 0 ? (
            <ul aria-label={t.weekRows} className="mt-4 flex flex-col gap-2" data-testid="my-hours-rows">
              {week.rows.map((x) => {
                const item: LaneItem = { code: x.code, name: x.name, kind: x.code ? "work" : "other", workArea: x.workArea, market: x.market, from: 0, to: 0 };
                return (
                  <li key={`${x.code ?? x.name}/${x.market ?? ""}`} className="grid grid-cols-[minmax(0,220px)_48px_80px_minmax(0,1fr)] items-center gap-3 text-small">
                    <span className="flex items-center gap-2 truncate">
                      <span aria-hidden="true" className={`inline-block h-2 w-2 shrink-0 rounded-full ${TONE_CLASS[itemTone(item)]}`} />
                      {x.code ? <b className="w-9 shrink-0 font-semibold">{x.code}</b> : null}
                      <span className="truncate">{x.name}</span>
                    </span>
                    <span>{x.market ? <span className="rounded-button bg-p4a-neutral-surface px-2 py-0.5 text-caption font-semibold">{x.market}</span> : null}</span>
                    <span className="tabular text-right">{hoursMinutes(x.seconds)}</span>
                    <span className="h-2 overflow-hidden rounded-button bg-p4a-neutral-surface" aria-hidden="true">
                      <span className={`block h-2 ${TONE_CLASS[itemTone(item)]}`} style={{ width: `${(x.seconds / most) * 100}%` }} />
                    </span>
                  </li>
                );
              })}
            </ul>
          ) : (
            <p className="mt-4 text-body text-p4a-muted">{t.empty}</p>
          )}
          {week.pauses.length > 0 ? (
            <p className="mt-4 flex flex-wrap items-center gap-x-4 gap-y-1 text-small text-p4a-muted" data-testid="my-hours-pauses">
              <span>{t.pausesNotWorked}</span>
              {week.pauses.map((p) => (
                <span key={p.code ?? p.name} className="inline-flex items-center gap-1.5 text-p4a-body">
                  <span aria-hidden="true" className={`inline-block h-2 w-2 rounded-full ${TONE_CLASS.pause}`} />
                  {p.code ? `${p.code} ${p.name}` : p.name} <b className="tabular font-semibold">{hoursMinutes(p.seconds)}</b>
                </span>
              ))}
            </p>
          ) : null}
        </Card>

        <Card>
          <ol className="flex flex-col divide-y divide-p4a-border" data-testid="my-hours-days">
            {week.days.map((d) => {
              const items: LaneItem[] = d.segments.map((g) => ({
                code: g.code, name: g.name, kind: g.kind, workArea: g.workArea, market: g.market, from: Date.parse(g.fromAt), to: Date.parse(g.toAt),
              }));
              const axis = laneAxis([], items, null);
              return (
                <li key={d.date} className="grid grid-cols-[170px_minmax(0,1fr)_120px] items-center gap-4 py-3 text-small">
                  <span>
                    <span className="font-semibold text-p4a-body">{fmtDate(d.date, me.locale)}</span>
                    {d.isToday ? <span className="block text-caption text-p4a-muted">{t.todaySoFar}</span> : null}
                  </span>
                  {d.hasTime ? (
                    <span className="flex flex-col gap-1">
                      <span className="relative h-5 rounded-button bg-p4a-neutral-surface" aria-hidden="true">
                        {items.map((x) => {
                          const box = laneBox(x, axis);
                          return box.width > 0 ? (
                            <span key={x.from} title={itemLabel(x)}
                              className={`absolute top-0 flex h-5 items-center overflow-hidden whitespace-nowrap rounded-[3px] pl-1 text-caption font-semibold ${TONE_CLASS[itemTone(x)]}`}
                              style={{ left: `${box.left}%`, width: `${box.width}%` }}>{itemLabel(x)}</span>
                          ) : null;
                        })}
                      </span>
                      <span className="text-caption text-p4a-muted" data-testid="my-hours-split">
                        {d.split.map((x) => `${x.code ?? x.name}${x.market ? ` ${x.market}` : ""} ${hoursMinutes(x.seconds)}`).join(" · ")}
                      </span>
                    </span>
                  ) : (
                    <span className="text-p4a-muted">{t.noTimeKept}</span>
                  )}
                  <span className="tabular text-right text-p4a-body">{d.hasTime ? t.dayWorked.replace("{time}", hoursMinutes(d.workedSeconds)) : "–"}</span>
                </li>
              );
            })}
          </ol>
        </Card>

        <p className="text-small text-p4a-muted">{t.askManager}</p>
      </div>

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
