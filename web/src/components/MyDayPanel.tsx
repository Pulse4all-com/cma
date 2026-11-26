"use client";

/**
 * My day when the roster drives the day (addition 0010a, brief B; the screens Arno and Kira approved on 26 November 2026,
 * artboards 1 to 4). Stupid simple for the agent: follow the roster and do nothing between Clock in and End workday; one
 * button, Switch, for every deviation.
 *
 *   Before Clock in   the Scheduled lane alone, the block planned now (or the first) in the status line, and Clock in (E4:
 *                     the session starts on the block of that moment with its market; before the first block on the first)
 *   Working           a chip "CODE · Name", a market chip (none for a pause or an Other status), since and until; on the
 *                     right Started at and Next. The clock as before. Two lanes, Scheduled and Actual, with a Now marker
 *                     across both; an own switch that deviates from the plan gets an orange ring on Actual and a caption
 *                     under the lanes, a deviating Actual block an orange outline; roster switches get no marker
 *   Notices           the roster's switch (E3, light blue, text only, for roster.switch_notice_minutes or until the next
 *                     switch) and Off plan (E7, light yellow, with Back to plan: the planned type and market)
 *   Switch            E6: a panel with Work (the active work types in order: colour dot, code, name; the chosen row gets an
 *                     Hours market select, the person's Default market first chosen, every hours market choosable), Pause
 *                     and Other (the working statuses no type books); one blue button confirms every choice the same way,
 *                     "Switch to GO · SE", "Switch to SB Short break". End workday hides while Switch is open; both 160 px
 *
 * Every change goes through POST /api/v1/me/status (the status write path, cma.set_status with the assignment), the same
 * guarded route as before; the day's answer replaces the screen, a refusal puts it back and says so. The page is read again
 * at the next boundary of the plan and every 30 seconds while the tab is visible and the day is open, so a roster switch
 * and its notice show without a reload (the realtime push service is still an open decision, docs/open-decisions.md;
 * polling is its fallback, Decision log, 11 October 2026). Colours from D13 (lib/assignments' tones); nothing here knows a
 * code, status or market.
 */
import { useEffect, useMemo, useOptimistic, useRef, useState, useSyncExternalStore, useTransition, type ReactNode } from "react";
import { useRouter } from "next/navigation";
import type { Copy, Locale } from "@/lib/copy";
import type { MyDayBlock, MyDayPlan, Workday } from "@/lib/data";
import { TONE_CLASS } from "@/lib/assignments";
import { dayEnded, dayWithStatus, workdayStartsAt, workedSeconds } from "@/lib/live";
import {
  blockItem, chipLabel, itemLabel, itemTone, laneAxis, laneBox, lanePct, laneTicks, stretchItem, switchLabel, type LaneItem,
} from "@/lib/my-day";
import { fmtTime } from "@/lib/time";
import { ConfirmDialog } from "./ConfirmDialog";
import { Badge, Button, Card, Keycap, Notice } from "./primitives";

/** A one-second clock as an external store: no setState in effects, no hydration mismatch */
function subscribe(onTick: () => void) {
  const id = setInterval(onTick, 1000);
  return () => clearInterval(id);
}
const nowSeconds = () => Math.floor(Date.now() / 1000) * 1000;
const serverNow = () => null;

function hms(s: number): string {
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  return `${h}:${String(m).padStart(2, "0")}:${String(sec).padStart(2, "0")}`;
}

/** What a block or stretch is, in the notices' words: "GO · SE General Ops", "SB Short break", "Training" */
function whatText(x: { code: string | null; name: string; kind: string; hoursMarket: string | null }): string {
  if (!x.code) return x.name;
  if (x.kind === "work") return `${x.code}${x.hoursMarket ? ` · ${x.hoursMarket}` : ""} ${x.name}`;
  return `${x.code} ${x.name}`;
}

/** A choice in the Switch panel */
type Choice = { kind: "work" | "pause" | "other"; code: string | null; key: string | null; name: string; market: string | null };

export function MyDayPanel({ workday, plan, timeZone, locale, copy, againUntil = null }: {
  workday: Workday | null;
  plan: MyDayPlan;
  timeZone: string;
  locale: Locale;
  /** The My day words and Clock in's (slices of the copy object, never the whole: they ride in the page's payload) */
  copy: Pick<Copy, "myDay" | "welcome">;
  /** An ended day that may take another session: the window end, pre-formatted (the Clock in card shows below) */
  againUntil?: string | null;
}) {
  const t = copy.myDay;
  const router = useRouter();
  const now = useSyncExternalStore(subscribe, nowSeconds, serverNow);
  const [pending, startTransition] = useTransition();
  const [failed, setFailed] = useState<string | null>(null);
  const [announced, setAnnounced] = useState<string | null>(null);
  const [open, setOpen] = useState(false);
  const [chosen, setChosen] = useState<Choice | null>(null);
  const [confirming, setConfirming] = useState(false);
  const [startsAt, setStartsAt] = useState<string | null>(null);
  /** The Switch button gets the focus back after a switch or Esc (the panel's controls go away) */
  const focusSwitch = () => document.querySelector<HTMLButtonElement>('[data-testid="my-day-switch"]')?.focus();
  // The day as the server last answered it, with the change in flight shown at once over it (night N07, D3)
  const [served, setServed] = useState<{ from: Workday | null; day: Workday | null }>({ from: workday, day: workday });
  if (served.from !== workday) setServed({ from: workday, day: workday });
  const [day, showDay] = useOptimistic(served.from === workday ? served.day : workday);
  const [shownCurrent, showCurrent] = useOptimistic(plan.current);
  const time = (instant: string | null | undefined) => (instant ? fmtTime(instant, timeZone, locale) : "");
  const working = day?.status === "working";

  // ---- the page read again: at the plan's next boundary (the minute job writes the switch) and every 30 s while visible
  const router_ = useRef(router);
  useEffect(() => { router_.current = router; });
  const lastRead = useRef(0);
  useEffect(() => { lastRead.current = Date.now(); }, [plan]);
  useEffect(() => {
    if (!working) return;
    const refresh = () => { if (!document.hidden) startTransition(() => router_.current.refresh()); };
    const poll = setInterval(refresh, 30_000);
    // agents work in other tabs (the telephony, the CRM): coming back reads the day again when the last read is 10 s old
    const visible = () => { if (!document.hidden && Date.now() - lastRead.current > 10_000) refresh(); };
    document.addEventListener("visibilitychange", visible);
    const timers: ReturnType<typeof setTimeout>[] = [];
    const at = (instant: string | null | undefined, lagMs: number) => {
      if (!instant) return;
      const wait = Date.parse(instant) + lagMs - Date.now();
      if (wait > 0 && wait < 12 * 3_600_000) timers.push(setTimeout(refresh, wait));
    };
    at(plan.planNext?.startAt, 65_000);   // the job runs once a minute
    return () => { clearInterval(poll); timers.forEach(clearTimeout); document.removeEventListener("visibilitychange", visible); };
  }, [working, plan.planNext?.startAt]);

  // ---- the lanes ------------------------------------------------------------------------------------------------
  const scheduled = useMemo(() => plan.plan.map(blockItem), [plan.plan]);
  const nowMs = now ?? Date.parse(day?.statusSince ?? day?.startedAt ?? plan.date);
  const actual = useMemo(() => plan.actual.map((a) => stretchItem(a, nowMs)), [plan.actual, nowMs]);
  const live = !!day && plan.isToday;
  const axis = laneAxis(scheduled, live ? actual : [], live ? nowMs : null);
  const ticks = laneTicks(axis);

  // ---- the status line --------------------------------------------------------------------------------------------
  const current = working ? shownCurrent : null;
  const onPlan = current && plan.planNow && plan.planNow.kind !== "absence" && !plan.offPlan;
  const nextBlock = plan.planNext;

  // ---- writes -----------------------------------------------------------------------------------------------------
  async function post(body: Record<string, unknown>): Promise<Workday | null> {
    const res = await fetch("/api/v1/me/status", {
      method: "POST", headers: { "content-type": "application/json", "x-cma-request": "1" }, body: JSON.stringify(body),
    }).catch(() => null);
    const answer = res?.ok ? ((await res.json().catch(() => null)) as { data?: Workday | null } | null)?.data ?? null : null;
    return answer;
  }

  function doSwitch(c: Choice) {
    setFailed(null);
    setOpen(false);
    const label = c.kind === "work" ? `${c.code}${c.market ? ` · ${c.market}` : ""}` : c.kind === "pause" ? `${c.code} ${c.name}` : c.name;
    startTransition(async () => {
      // At once (D3): the chip, the market and the clock as the database will count them
      if (day) showDay(dayWithStatus(day, { key: c.key ?? c.code ?? "", name: c.name, isWorking: c.kind !== "pause" }, Date.now(), c.kind === "work" ? c.market : null));
      showCurrent({ code: c.code, name: c.name, kind: c.kind, statusKey: c.key ?? "", statusName: c.name, workArea: null, hoursMarket: c.kind === "work" ? c.market : null,
        since: new Date().toISOString(), source: "user" });
      const answer = await post(c.key ? { key: c.key } : { assignment: c.code, hoursMarket: c.kind === "work" ? c.market : null });
      if (!answer) setFailed(t.switchFailed);
      else { setServed({ from: workday, day: answer }); setAnnounced(t.switched.replace("{what}", label)); }
      setChosen(null);
      startTransition(() => router.refresh());
      focusSwitch();
    });
  }

  function backToPlan() {
    const p = plan.offPlan;
    if (!p) return;
    doSwitch({ kind: p.kind, code: p.code, key: null, name: p.name, market: p.hoursMarket });
  }

  function confirmEnd() {
    setFailed(null);
    startTransition(async () => {
      if (day) showDay(dayEnded(day, Date.now()));
      setConfirming(false);
      const res = await fetch("/api/v1/me/day/end", { method: "POST", headers: { "x-cma-request": "1" } }).catch(() => null);
      const answer = res?.ok ? ((await res.json().catch(() => null)) as { data?: Workday | null } | null)?.data ?? null : null;
      if (answer) setServed({ from: workday, day: answer });
      else if (res?.status !== 409) setFailed(t.statusFailed);
      startTransition(() => router.refresh());
    });
  }

  /** One clock-in at a time: a second Enter while the first is in flight does nothing */
  const clockingIn = useRef(false);
  function clockIn() {
    if (clockingIn.current) return;
    clockingIn.current = true;
    setFailed(null);
    setStartsAt(null);
    startTransition(async () => {
      // At once (night N07, D3): the day running from now on the block planned now (E4), the clock started unless it is a
      // pause; the server's answer and the page's read replace it, a refusal drops it when the transition ends
      const at = new Date().toISOString();
      const b = plan.planNow && plan.planNow.kind !== "absence" ? plan.planNow : plan.planNext ?? plan.plan.find((x) => x.kind !== "absence") ?? null;
      const runs = b?.kind !== "pause";
      showDay({
        date: plan.date, status: "working", startedAt: at, endedAt: null, statusKey: null, statusName: b?.name ?? null, statusSince: at,
        clock: { closedSeconds: 0, runningSince: runs ? at : null }, dayEndsAt: plan.shift?.endAt ?? new Date(Date.now() + 12 * 3_600_000).toISOString(),
        sessions: 1, sessionStartedAt: at, clockInAgain: false, canClockInAgain: false, hoursMarket: b?.kind === "work" ? b.hoursMarket : null,
      });
      if (b) {
        showCurrent({ code: b.code, name: b.name, kind: b.kind === "pause" ? "pause" : "work", statusKey: "", statusName: b.name, workArea: b.workArea,
          hoursMarket: b.kind === "work" ? b.hoursMarket : null, since: at, source: "user" });
      }
      const res = await fetch("/api/v1/me/day/start", { method: "POST", headers: { "x-cma-request": "1" } }).catch(() => null);
      if (!res?.ok) {
        const body = res ? ((await res.json().catch(() => null)) as { error?: { message?: string } } | null) : null;
        const at = workdayStartsAt(body?.error?.message);
        if (at) setStartsAt(at);
        else setFailed(copy.welcome.clockInFailed);
      }
      // also after a refusal: the day may have been opened in another tab; the optimistic day holds until this read lands
      router.refresh();
      clockingIn.current = false;
    });
  }

  // ---- the parts ----------------------------------------------------------------------------------------------------
  const chip = (x: { code: string | null; name: string; kind: string; workArea: LaneItem["workArea"]; isExtra?: boolean }) => (
    <span className="inline-flex items-center gap-1.5 rounded-button bg-p4a-neutral-surface px-2 py-0.5 text-caption font-semibold text-p4a-body" data-testid="my-day-chip">
      <span aria-hidden="true" className={`inline-block h-2 w-2 rounded-full ${TONE_CLASS[itemTone({ kind: x.kind as LaneItem["kind"], workArea: x.workArea, isExtra: x.isExtra })]}`} />
      {chipLabel(x)}
    </span>
  );
  const marketChip = (m: string | null) => (m ? (
    <span className="inline-flex items-center rounded-button bg-p4a-neutral-surface px-2 py-0.5 text-caption font-semibold text-p4a-body" data-testid="my-day-market">{m}</span>
  ) : null);
  const strong = (s: string) => <b className="font-semibold text-p4a-body">{s}</b>;
  const words = (text: string, parts: Record<string, ReactNode>): ReactNode[] => {
    // a sentence with {name} parts filled in by nodes, so a part may be bold without HTML in the copy
    const out: ReactNode[] = [];
    let rest = text;
    for (;;) {
      const m = /\{(\w+)\}/.exec(rest);
      if (!m) { out.push(rest); break; }
      out.push(rest.slice(0, m.index), <span key={`${m[1]}-${out.length}`}>{parts[m[1]!] ?? m[0]}</span>);
      rest = rest.slice(m.index + m[0].length);
    }
    return out;
  };

  const shownBlock: MyDayBlock | null = plan.planNow ?? plan.plan.find((b) => b.kind !== "absence") ?? null;

  return (
    <Card>
      <div className="flex flex-col gap-5" data-testid="my-day">
        {working && plan.notice && (now === null || now < Date.parse(plan.notice.until)) ? (
          <div role="status" className="rounded-button border border-p4a-lightblue bg-p4a-bgblue px-4 py-2.5 text-small text-p4a-body" data-testid="my-day-notice">
            {words(t.rosterSwitched, { what: strong(whatText({ ...plan.notice, kind: plan.notice.kind ?? "other" })), time: time(plan.notice.at) })}
          </div>
        ) : null}
        {working && plan.offPlan ? (
          <div role="status" className="flex flex-wrap items-center justify-between gap-3 rounded-button border border-p4a-warning/40 bg-p4a-warning-surface px-4 py-2.5 text-small text-p4a-body" data-testid="my-day-off-plan">
            <span>
              {plan.offPlan.nextAt
                ? words(t.plannedNowNext, {
                  what: strong(whatText(plan.offPlan)), time: time(plan.offPlan.since), next: time(plan.offPlan.nextAt),
                  nextWhat: itemLabel({ code: plan.offPlan.nextCode, name: plan.offPlan.nextName ?? "", kind: plan.offPlan.nextKind ?? "work", market: plan.offPlan.nextHoursMarket }),
                })
                : words(t.plannedNow, { what: strong(whatText(plan.offPlan)), time: time(plan.offPlan.since) })}
            </span>
            <Button variant="outlined" size="sm" disabled={pending} onClick={backToPlan} data-testid="my-day-back-to-plan">{t.backToPlan}</Button>
          </div>
        ) : null}

        {/* the status line */}
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div className="flex flex-wrap items-center gap-2">
            {working && current ? (
              <>
                {chip(current)}
                {current.kind === "work" ? marketChip(current.hoursMarket) : null}
                <span className="text-small text-p4a-muted">
                  {onPlan && plan.planNow
                    ? words(t.sinceUntil, { since: strong(time(current.since)), until: time(plan.planNow.endAt) })
                    : words(t.since, { since: strong(time(current.since)) })}
                </span>
              </>
            ) : !day && shownBlock ? (
              <>
                {chip(shownBlock)}
                {shownBlock.kind === "work" ? marketChip(shownBlock.hoursMarket) : null}
                <span className="text-small text-p4a-muted">
                  {plan.planNow ? t.plannedNowUntil.replace("{until}", time(plan.planNow.endAt)) : t.plannedFrom.replace("{time}", time(shownBlock.startAt))}
                </span>
              </>
            ) : !day ? <span className="text-small text-p4a-muted">{t.noPlan}</span> : <Badge tone="neutral">{t.dayEnded}</Badge>}
          </div>
          <div className="text-right text-small leading-6 text-p4a-muted">
            {day ? (
              <>
                {t.startedAt} {strong(time(day.startedAt))}
                {working && nextBlock ? (
                  <span className="block" data-testid="my-day-next">{t.next} {strong(whatText(nextBlock))} {t.nextAt.replace("{time}", time(nextBlock.startAt))}</span>
                ) : null}
              </>
            ) : plan.shift?.kind === "shift" ? (
              <>{t.today} {strong(`${plan.shift.start} – ${plan.shift.end}`)}</>
            ) : plan.shift?.absenceName ? <>{t.today} {strong(plan.shift.absenceName)}</> : null}
          </div>
        </div>

        {day ? (
          <div>
            <p className="text-caption text-p4a-grey">{t.workedToday}</p>
            <p data-testid="workday-clock" className="tabular text-clock font-semibold text-p4a-heading" aria-live="off">
              {hms(now === null ? day.clock.closedSeconds : workedSeconds(day.clock, now, day.dayEndsAt))}
            </p>
          </div>
        ) : null}

        {/* the lanes */}
        {scheduled.length > 0 || actual.length > 0 ? (
          <div className="flex flex-col gap-1.5" data-testid="my-day-lanes">
            <div className={`grid grid-cols-[74px_minmax(0,1fr)] items-center gap-x-2.5 gap-y-1.5 ${live && now !== null ? "mt-6" : ""}`}>
              <span className="text-caption text-p4a-muted">{t.scheduled}</span>
              <Lane items={scheduled} axis={axis} testId="lane-scheduled">
                {live && now !== null && now >= axis.from && now <= axis.to ? (
                  <div className="pointer-events-none absolute -top-6 z-10 flex -translate-x-1/2 flex-col items-center" style={{ left: `${lanePct(now, axis)}%` }} data-testid="my-day-now">
                    <span className="inline-flex items-center gap-1.5 whitespace-nowrap rounded-button border border-p4a-lightblue/60 bg-p4a-bgblue px-2 py-px text-caption font-semibold text-p4a-deepblue">
                      <span aria-hidden="true" className="my-day-pulse inline-block h-1.5 w-1.5 rounded-full bg-p4a-denim" />
                      {t.now.replace("{time}", time(new Date(now).toISOString()))}
                    </span>
                    <span aria-hidden="true" className="mt-0.5 h-[60px] w-[3px] rounded-full bg-p4a-denim" />
                  </div>
                ) : null}
              </Lane>
              {live ? (
                <>
                  <span className="text-caption text-p4a-muted">{t.actual}</span>
                  <Lane items={actual} axis={axis} testId="lane-actual">
                    {plan.marks.map((m) => (
                      <span key={m.at} title={t.youSwitched.replace("{what}", itemLabel({ code: m.code, name: m.statusName, kind: "work", market: m.hoursMarket }))
                        .replace("{planned}", itemLabel({ code: m.plannedCode, name: "", kind: "work", market: m.plannedHoursMarket }))}
                        aria-hidden="true" className="absolute top-[5px] z-[1] h-3.5 w-3.5 -translate-x-1/2 rounded-full border-2 border-p4a-warning bg-white"
                        style={{ left: `${lanePct(Date.parse(m.at), axis)}%` }} />
                    ))}
                  </Lane>
                </>
              ) : null}
              <span />
              <div className="tabular flex justify-between text-caption text-p4a-muted" aria-hidden="true">
                {ticks.map((x) => <span key={x}>{time(new Date(x).toISOString())}</span>)}
              </div>
            </div>
            {live ? plan.marks.map((m) => (
              <p key={m.at} className="flex items-center gap-2 pl-[84px] text-caption text-p4a-body" data-testid="my-day-mark">
                <span aria-hidden="true" className="inline-block h-2.5 w-2.5 rounded-full border-2 border-p4a-warning" />
                <b className="tabular font-semibold">{time(m.at)}</b>
                <span className="text-p4a-muted">
                  {t.youSwitched.replace("{what}", itemLabel({ code: m.code, name: m.statusName, kind: "work", market: m.hoursMarket }))
                    .replace("{planned}", itemLabel({ code: m.plannedCode, name: "", kind: "work", market: m.plannedHoursMarket }))}
                </span>
              </p>
            )) : null}
          </div>
        ) : null}

        {/* the buttons */}
        {!day ? (
          <div className="flex flex-col gap-3">
            <div>
              <button type="button" autoFocus aria-busy={pending} onClick={clockIn} data-testid="clock-in"
                className="inline-flex h-9 items-center gap-3 rounded-button bg-p4a-deepblue px-5 font-semibold text-white hover:bg-p4a-denim aria-busy:opacity-60">
                {copy.welcome.clockIn}
                <Keycap>Enter</Keycap>
              </button>
            </div>
            {startsAt ? <Notice tone="info">{copy.welcome.clockInTooEarly.replace("{time}", startsAt)}</Notice> : null}
          </div>
        ) : working ? (
          <div className="flex flex-col gap-2">
            <div>
              <Button variant="outlined" size="sm" className="w-40 justify-center" aria-expanded={open} aria-controls="my-day-switch"
                data-shortcut="s" data-testid="my-day-switch" disabled={pending}
                onClick={() => { setOpen((o) => !o); setChosen(null); }}>
                <span className="inline-flex items-center gap-2">
                  {t.switch}
                  <svg width="10" height="10" viewBox="0 0 12 12" aria-hidden="true"><path d={open ? "M2 8l4-4 4 4" : "M2 4l4 4 4-4"} fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" /></svg>
                </span>
              </Button>
            </div>
            {open ? (
              <SwitchPanel plan={plan} chosen={chosen} onChoose={setChosen} onConfirm={doSwitch} onClose={() => { setOpen(false); focusSwitch(); }} copy={copy} busy={pending} />
            ) : (
              <div>
                <Button variant="outlined" size="sm" className="w-40 justify-center" data-shortcut="e" onClick={() => setConfirming(true)}>{t.endWorkday}</Button>
              </div>
            )}
          </div>
        ) : (
          <p className="text-body">{againUntil ? t.sessionEndedBody : t.dayEndedBody}</p>
        )}
        {failed ? <p role="alert" className="text-small text-p4a-body">{failed}</p> : null}
        <p role="status" aria-live="polite" className="sr-only" data-testid="status-announcement">{announced ?? ""}</p>
      </div>
      <ConfirmDialog
        open={confirming}
        title={t.confirmTitle}
        confirmLabel={t.confirmYes}
        cancelLabel={t.confirmNo}
        onConfirm={confirmEnd}
        onCancel={() => setConfirming(false)}
        busy={pending}
      >
        {day?.clockInAgain && now !== null && now < Date.parse(day.dayEndsAt) ? t.confirmBodyAgain.replace("{time}", time(day.dayEndsAt)) : t.confirmBody}
      </ConfirmDialog>
    </Card>
  );
}

/** One lane: its items in their colours with their words, a deviating Actual block outlined in orange */
function Lane({ items, axis, testId, children }: { items: LaneItem[]; axis: { from: number; to: number }; testId: string; children?: ReactNode }) {
  return (
    <div className="relative h-6 rounded-button bg-p4a-neutral-surface" data-testid={testId}>
      {items.map((x) => {
        const box = laneBox(x, axis);
        if (box.width <= 0) return null;
        return (
          <div key={`${x.from}-${x.code ?? x.name}`} title={itemLabel(x)}
            className={`absolute top-0 flex h-6 items-center overflow-hidden whitespace-nowrap rounded-[3px] pl-1.5 text-caption font-semibold ${TONE_CLASS[itemTone(x)]} ${x.deviates ? "!border-2 !border-p4a-warning shadow-[0_0_0_2px_var(--color-p4a-warning-surface)]" : "border-white"}`}
            style={{ left: `${box.left}%`, width: `${box.width}%` }} data-deviates={x.deviates || undefined}>
            {itemLabel(x)}
          </div>
        );
      })}
      {children}
    </div>
  );
}

/** E6's panel: Work, Pause and Other; a work row takes its market; one button confirms */
function SwitchPanel({ plan, chosen, onChoose, onConfirm, onClose, copy, busy }: {
  plan: MyDayPlan; chosen: Choice | null; onChoose: (c: Choice) => void; onConfirm: (c: Choice) => void; onClose: () => void;
  copy: Pick<Copy, "myDay">; busy: boolean;
}) {
  const t = copy.myDay;
  const c = plan.choices;
  const markets = c.hoursMarkets;
  // the person's Default market first chosen (E6); without one, the agent chooses: nothing is booked under a guess
  const firstMarket = c.defaultMarket ?? null;
  const row = (choice: Choice, dot: string, code: string | null, name: string, market?: ReactNode) => {
    const on = chosen && chosen.kind === choice.kind && chosen.code === choice.code && chosen.key === choice.key;
    return (
      <div key={`${choice.kind}-${choice.code ?? choice.key}`} className={`flex items-center rounded-button ${on ? "bg-p4a-bgblue" : ""}`}>
        <button type="button" aria-pressed={!!on} onClick={() => onChoose(on ? chosen! : choice)}
          className="flex h-8 flex-1 items-center gap-2.5 rounded-button px-2.5 text-left text-small text-p4a-body hover:bg-p4a-bgblue"
          data-testid={`switch-${choice.kind}-${choice.code ?? choice.key}`}>
          <span aria-hidden="true" className={`inline-block h-2 w-2 shrink-0 rounded-full ${dot}`} />
          <b className="w-9 shrink-0 font-semibold">{code ?? ""}</b>
          <span className="truncate">{name}</span>
        </button>
        {on ? market : null}
      </div>
    );
  };
  return (
    <div id="my-day-switch" className="flex w-[340px] flex-col gap-px rounded-button border border-p4a-border bg-white p-1.5 shadow-[0_4px_16px_rgba(11,19,61,0.08)]"
      onKeyDown={(e) => { if (e.key === "Escape") { e.preventDefault(); onClose(); } }} data-testid="my-day-switch-panel">
      {c.work.length > 0 ? <p className="px-2.5 pb-0.5 pt-2 text-caption font-semibold text-p4a-muted">{t.groupWork}</p> : null}
      {c.work.map((w) => row({ kind: "work", code: w.code, key: null, name: w.name, market: chosen?.code === w.code ? chosen.market : firstMarket },
        w.isExtra ? "border border-dashed border-p4a-inkt" : TONE_CLASS[itemTone({ kind: "work", workArea: w.workArea })], w.code, w.name,
        <select aria-label={t.marketFor.replace("{name}", w.name)} value={chosen?.code === w.code ? chosen.market ?? "" : firstMarket ?? ""}
          onChange={(e) => onChoose({ kind: "work", code: w.code, key: null, name: w.name, market: e.target.value || null })}
          className="mr-1 h-7 rounded-button border border-p4a-lightblue bg-white px-1.5 text-caption font-bold text-p4a-deepblue" data-testid="switch-market">
          {(chosen?.code === w.code ? chosen.market : firstMarket) ? null : <option value="" disabled>{t.chooseHoursMarket}</option>}
          {markets.map((m) => <option key={m.code} value={m.code}>{m.code}</option>)}
        </select>))}
      {c.pause.length > 0 ? <p className="px-2.5 pb-0.5 pt-2 text-caption font-semibold text-p4a-muted">{t.groupPause}</p> : null}
      {c.pause.map((p) => row({ kind: "pause", code: p.code, key: null, name: p.name, market: null }, TONE_CLASS.pause, p.code, p.name))}
      {c.other.length > 0 ? <p className="px-2.5 pb-0.5 pt-2 text-caption font-semibold text-p4a-muted">{t.groupOther}</p> : null}
      {c.other.map((o) => row({ kind: "other", code: null, key: o.key, name: o.name, market: null }, TONE_CLASS[itemTone({ kind: "other", workArea: o.workArea })], null, o.name))}
      <div className="mt-1 border-t border-p4a-border px-1 pb-1 pt-2">
        <Button variant="primary" size="sm" className="w-full justify-center" disabled={!chosen || busy || (chosen.kind === "work" && !chosen.market)}
          onClick={() => chosen && onConfirm(chosen)} data-testid="my-day-switch-confirm">
          {chosen ? switchLabel(t.switchTo, chosen) : t.switch}
        </Button>
      </div>
    </div>
  );
}
