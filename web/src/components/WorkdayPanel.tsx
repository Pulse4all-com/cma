"use client";

/**
 * The heart of My day: the running clock. One memorable element, everything
 * else quiet. Ticks every second from the server-provided clock (closed seconds
 * plus the running stretch), so a tab left open all day stays right without
 * polling, and it pauses while the current status is not a working one.
 *
 * Status buttons come from the tenant's own list in its order; no key or name
 * is known here. A change goes through POST /api/v1/me/status, the same path
 * the API verifier proves. Keyboard: S moves focus into the status buttons,
 * arrows move between them, Enter picks one. Bare digits stay with the pages,
 * so a tenant can have any number of statuses without clashing shortcuts.
 *
 * The focus stays where the person works (the IT audit of 17 October 2026): the current status is
 * pressed (aria-pressed, Background Blue fill as the top bar's hints toggle) and not disabled, so it can
 * hold the focus; only the button just clicked is disabled while its change is in flight, and when the
 * change has landed the focus returns to that button (the new current one, or the clicked one after a
 * refusal); a status live region says the new status in words. The current status button takes the
 * focus when the panel mounts, so the person who has just clocked in (the card is replaced by this
 * panel) keeps a place to work from, as the Clock in button had the focus before.
 *
 * Sessions (addition 0008zp): on a day clocked in again, "Started at" keeps the first session's start
 * and a second line says since when the person is back. While the tenant lets people clock in again
 * and the window is still open, End workday says until when that can happen; an ended day that can
 * take another session says so, and the page shows the Clock in card again below it.
 *
 * Hours market (addition 0009zo, D3): a select next to the status buttons lists the tenant's active hours markets and
 * shows the current one beside the current status; M moves the focus to it. Picking a market books a status event with
 * the same status under the new market (POST /api/v1/me/status with the market alone), so the time from that moment
 * counts for it; every later status change keeps it until the person picks another. Time without a market shows as No
 * market. A tenant without hours markets shows no select.
 */
import { useEffect, useOptimistic, useRef, useState, useSyncExternalStore, useTransition } from "react";
import type { KeyboardEvent as ReactKeyboardEvent, MouseEvent as ReactMouseEvent } from "react";
import { useRouter } from "next/navigation";
import type { HoursMarket, WorkStatus, Workday } from "@/lib/data";
import type { Copy, Locale } from "@/lib/copy";
import { agentGroupOf, GROUP_BG } from "@/lib/dashboard";
import { Badge, Button, Card, Keycap } from "./primitives";
import { ConfirmDialog } from "./ConfirmDialog";
import { dayEnded, dayWithStatus, workedSeconds } from "@/lib/live";
import { fmtTime } from "@/lib/time";

/** A one-second clock as an external store: no setState in effects, no hydration mismatch */
function subscribe(onTick: () => void) {
  const id = setInterval(onTick, 1000);
  return () => clearInterval(id);
}
const nowSeconds = () => Math.floor(Date.now() / 1000) * 1000;
const serverNow = () => null;

/**
 * Worked seconds at `now` (ms), or the closed part alone before the client clock starts. The
 * running stretch stops at the day's end (the workday window, 0008b), as the database counts.
 */
function worked(workday: Workday, now: number | null): number {
  return now === null ? workday.clock.closedSeconds : workedSeconds(workday.clock, now, workday.dayEndsAt);
}

function hms(s: number): string {
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  return `${h}:${String(m).padStart(2, "0")}:${String(sec).padStart(2, "0")}`;
}

export function WorkdayPanel({
  workday,
  statuses,
  hoursMarkets = [],
  startedLabel,
  statusSinceLabel,
  endedLabel,
  sessionStartedLabel = null,
  dayEndsLabel,
  timeZone,
  locale,
  copy,
}: {
  workday: Workday;
  /** The person's zone and language, for the time of a change shown before the server's answer (D3) */
  timeZone: string;
  locale: Locale;
  /** The tenant's active statuses, in the tenant's order */
  statuses: WorkStatus[];
  /** The tenant's active hours markets, in the markets' order (addition 0009zo); none: no select */
  hoursMarkets?: HoursMarket[];
  /** Pre-formatted in the user's zone and locale on the server */
  startedLabel: string;
  statusSinceLabel: string | null;
  endedLabel: string | null;
  /** The latest session's start, on a day with more than one session */
  sessionStartedLabel?: string | null;
  /** The window end of the day (dayEndsAt), for "until" when the person can clock in again */
  dayEndsLabel: string;
  /** The My day words (a slice of the copy object, never the whole: it rides in the page's payload) */
  copy: Pick<Copy, "myDay">;
}) {
  const router = useRouter();
  const now = useSyncExternalStore(subscribe, nowSeconds, serverNow);
  const [confirming, setConfirming] = useState(false);
  const [pending, startTransition] = useTransition();
  const [statusFailed, setStatusFailed] = useState(false);
  /** The status whose change is in flight: that button alone is disabled */
  const [pendingKey, setPendingKey] = useState<string | null>(null);
  /** The name of the status just set, for the live region */
  const [announced, setAnnounced] = useState<string | null>(null);
  /** The hours market whose change is in flight (addition 0009zo): the select is busy meanwhile */
  const [pendingMarket, setPendingMarket] = useState<string | null>(null);
  const [marketFailed, setMarketFailed] = useState(false);
  /** The market just set, for the live region */
  const [announcedMarket, setAnnouncedMarket] = useState<string | null>(null);
  /**
   * The day as the server last answered it (night N07, decision D3): the page's own read, replaced by a write's answer
   * (POST /api/v1/me/status and /day/end answer the day from the write's transaction, as GET /api/v1/me/day reads it), and
   * by the page's next read when it arrives. `day` is that answer with the change in flight shown at once over it
   * (useOptimistic): the new status, its colour and the clock as the database will count it within the click's frame; a
   * refusal drops it when the transition ends and the problem line says so
   */
  const [served, setServed] = useState<{ from: Workday; day: Workday }>({ from: workday, day: workday });
  if (served.from !== workday) setServed({ from: workday, day: workday });
  const [day, showDay] = useOptimistic(served.from === workday ? served.day : workday);
  /** Since when the status runs, in the person's zone: the server's label, or the change's own time while it is new */
  const statusSinceShown = day.statusSince === workday.statusSince ? statusSinceLabel : day.statusSince ? fmtTime(day.statusSince, timeZone, locale) : null;
  /** The status whose button gets the focus back once the change has landed */
  const refocus = useRef<string | null>(null);
  const working = day.status === "working";
  // Whether ending now still leaves room to clock in again today: the setting on, the window open
  const againAfterEnd = day.clockInAgain && now !== null && now < Date.parse(day.dayEndsAt);
  const current = statuses.find((s) => s.key === day.statusKey);
  const group = useRef<HTMLDivElement>(null);

  /** The buttons that can be chosen now (the current, pressed status and the one in flight are not) */
  function choosable(): HTMLButtonElement[] {
    return Array.from(group.current?.querySelectorAll<HTMLButtonElement>('button:not([disabled]):not([aria-pressed="true"])') ?? []);
  }

  // The change has landed (or was refused): the focus goes back to the button it left, unless the person
  // has moved on to something else in the meantime
  useEffect(() => {
    if (pending || refocus.current === null) return;
    const key = refocus.current;
    refocus.current = null;
    const active = document.activeElement;
    if (active && active !== document.body && !group.current?.contains(active)) return;
    Array.from(group.current?.querySelectorAll<HTMLButtonElement>("button") ?? []).find((b) => b.dataset.statusKey === key)?.focus();
  }, [pending, day.statusKey]);

  /** The S shortcut clicks the group itself: move focus to the first choosable status */
  function enterGroup(e: ReactMouseEvent<HTMLDivElement>) {
    if (e.target !== e.currentTarget) return;
    choosable()[0]?.focus();
  }

  function moveInGroup(e: ReactKeyboardEvent<HTMLDivElement>) {
    const buttons = choosable();
    if (buttons.length === 0) return;
    if (e.key === "Escape") {
      (document.activeElement as HTMLElement | null)?.blur();
      return;
    }
    const i = buttons.indexOf(document.activeElement as HTMLButtonElement);
    const last = buttons.length - 1;
    const next =
      e.key === "ArrowRight" || e.key === "ArrowDown" ? (i < 0 || i === last ? 0 : i + 1)
      : e.key === "ArrowLeft" || e.key === "ArrowUp" ? (i <= 0 ? last : i - 1)
      : e.key === "Home" ? 0
      : e.key === "End" ? last
      : -1;
    if (next < 0) return;
    e.preventDefault();
    buttons[next]?.focus();
  }

  function changeStatus(key: string) {
    if (pendingKey !== null) return;
    setStatusFailed(false);
    setPendingKey(key);
    const status = statuses.find((s) => s.key === key) ?? null;
    startTransition(async () => {
      // At once, within the click's frame (D3): the new status pressed, its badge, its time and the clock
      showDay(dayWithStatus(day, status, Date.now()));
      const res = await fetch("/api/v1/me/status", {
        method: "POST",
        headers: { "content-type": "application/json", "x-cma-request": "1" },
        body: JSON.stringify({ key }),
      }).catch(() => null);
      const answer = res?.ok ? await answerOf(res) : null;
      if (!answer) setStatusFailed(true);
      else {
        setServed({ from: workday, day: answer });
        setAnnounced(status?.name ?? key);
      }
      refocus.current = key;
      setPendingKey(null);
      // The page read again after the answer is on the screen, in a transition: the labels formatted on the server and a
      // Back within 30 seconds (the client router cache, D4) show the new day; also after a refusal, since the day may
      // have ended in another tab
      startTransition(() => router.refresh());
    });
  }

  function changeMarket(code: string) {
    if (pendingKey !== null || pendingMarket !== null || !code || code === day.hoursMarket) return;
    setMarketFailed(false);
    setStatusFailed(false);
    setPendingMarket(code);
    startTransition(async () => {
      showDay(dayWithStatus(day, null, Date.now(), code));
      // The market alone: the database books the status in force again under it (addition 0009zo, D3)
      const res = await fetch("/api/v1/me/status", {
        method: "POST",
        headers: { "content-type": "application/json", "x-cma-request": "1" },
        body: JSON.stringify({ hoursMarket: code }),
      }).catch(() => null);
      const answer = res?.ok ? await answerOf(res) : null;
      if (!answer) setMarketFailed(true);
      else {
        setServed({ from: workday, day: answer });
        setAnnouncedMarket(hoursMarkets.find((m) => m.code === code)?.name ?? code);
      }
      setPendingMarket(null);
      // Also after a refusal: the day may have ended in another tab, or the market gone inactive
      startTransition(() => router.refresh());
    });
  }

  function confirmEnd() {
    setStatusFailed(false);
    startTransition(async () => {
      // At once (D3): the day shown ended, the clock stopped; the dialog closes with it
      showDay(dayEnded(day, Date.now()));
      setConfirming(false);
      // The same guarded route the API verifier covers (assertSameSiteWrite), not a server action: one
      // write rule for every write (the IT audit of 17 October 2026). A refusal shows the status problem
      // line; the refresh then shows the day as the database has it (ended in another tab, for example)
      const res = await fetch("/api/v1/me/day/end", { method: "POST", headers: { "x-cma-request": "1" } }).catch(() => null);
      const answer = res?.ok ? await answerOf(res) : null;
      if (answer) setServed({ from: workday, day: answer });
      else if (res?.status !== 409) setStatusFailed(true);
      // The page follows: the Clock in card again on a day that may take another session
      startTransition(() => router.refresh());
    });
  }

  if (!working) {
    return (
      <Card>
        <div className="flex items-center gap-3">
          <Badge tone="neutral">{copy.myDay.dayEnded}</Badge>
        </div>
        <p className="mt-4 text-body">{day.canClockInAgain ? copy.myDay.sessionEndedBody : copy.myDay.dayEndedBody}</p>
        <dl className="mt-6 grid grid-cols-[auto_1fr] gap-x-6 gap-y-1 text-small">
          <dt className="text-p4a-muted">{copy.myDay.startedAt}</dt>
          <dd className="tabular">{startedLabel}</dd>
          <dt className="text-p4a-muted">{copy.myDay.endedAt}</dt>
          <dd className="tabular">{endedLabel}</dd>
        </dl>
      </Card>
    );
  }

  return (
    <Card>
      <div className="flex items-center gap-3">
        <Badge tone="neutral">
          <span className="inline-flex items-center gap-2">
            {current ? <StatusDot status={current} /> : null}
            {current?.name ?? day.statusName ?? copy.myDay.working}
          </span>
        </Badge>
        {hoursMarkets.length > 0 ? (
          <Badge tone="neutral">
            <span data-testid="current-hours-market">{day.hoursMarket ?? copy.myDay.noMarket}</span>
          </Badge>
        ) : null}
        {statusSinceShown ? (
          <span className="text-small text-p4a-muted">
            {copy.myDay.workingSince} <span className="tabular text-p4a-body">{statusSinceShown}</span>
          </span>
        ) : null}
        <span className="ml-auto text-small text-p4a-muted">
          {copy.myDay.startedAt} <span className="tabular text-p4a-body">{startedLabel}</span>
          {sessionStartedLabel ? (
            <span className="block" data-testid="back-since">
              {copy.myDay.backSince} <span className="tabular text-p4a-body">{sessionStartedLabel}</span>
            </span>
          ) : null}
        </span>
      </div>
      <p className="mt-6 text-caption text-p4a-grey">{copy.myDay.workedToday}</p>
      <p
        data-testid="workday-clock"
        className="tabular text-clock font-semibold text-p4a-heading"
        aria-live="off"
      >
        {hms(worked(day, now))}
      </p>
      <div className="mt-6">
        <p className="text-caption text-p4a-grey">{copy.myDay.statusLabel}</p>
        <div
          ref={group}
          className="mt-2 flex flex-wrap gap-2"
          role="group"
          aria-label={copy.myDay.statusLabel}
          tabIndex={-1}
          data-shortcut="s"
          onClick={enterGroup}
          onKeyDown={moveInGroup}
        >
          {statuses.map((s) => {
            const isCurrent = s.key === day.statusKey;
            return (
              <Button
                key={s.key}
                variant="outlined"
                size="md"
                aria-pressed={isCurrent}
                autoFocus={isCurrent}
                disabled={pendingKey === s.key}
                data-status-key={s.key}
                className="aria-pressed:bg-p4a-bgblue"
                onClick={() => { if (!isCurrent) changeStatus(s.key); }}
              >
                <span className="inline-flex items-center gap-2">
                  <StatusDot status={s} />
                  {s.name}
                </span>
              </Button>
            );
          })}
        </div>
        {statusFailed ? (
          <p role="alert" className="mt-2 text-small text-p4a-body">
            {copy.myDay.statusFailed}
          </p>
        ) : null}
        {hoursMarkets.length > 0 ? (
          <label className="mt-4 flex max-w-sm flex-col gap-2 text-small font-semibold text-p4a-body" aria-busy={pendingMarket !== null || undefined}>
            <span className="flex items-center gap-2">
              {copy.myDay.hoursMarket} <Keycap>M</Keycap>
            </span>
            <select
              value={day.hoursMarket ?? ""}
              data-shortcut="m"
              data-testid="hours-market-select"
              disabled={pendingMarket !== null}
              onChange={(e) => changeMarket(e.target.value)}
              className="h-10 rounded-input border border-p4a-border bg-white px-3 font-normal text-body text-p4a-body focus:border-p4a-deepblue"
            >
              {day.hoursMarket === null ? <option value="" disabled>{copy.myDay.noMarket}</option> : null}
              {day.hoursMarket !== null && !hoursMarkets.some((m) => m.code === day.hoursMarket) ? (
                // A market no longer offered: shown as booked, not choosable
                <option value={day.hoursMarket} disabled>{day.hoursMarket}</option>
              ) : null}
              {hoursMarkets.map((m) => (
                <option key={m.code} value={m.code}>
                  {m.code} · {m.name}
                </option>
              ))}
            </select>
            <span className="font-normal text-caption text-p4a-grey">{copy.myDay.hoursMarketHint}</span>
          </label>
        ) : null}
        {marketFailed ? (
          <p role="alert" className="mt-2 text-small text-p4a-body">
            {copy.myDay.marketFailed}
          </p>
        ) : null}
        <p role="status" aria-live="polite" className="sr-only" data-testid="market-announcement">
          {announcedMarket ? copy.myDay.marketChanged.replace("{market}", announcedMarket) : ""}
        </p>
        {/* Always in the DOM, so assistive tech notices the text when it changes */}
        <p role="status" aria-live="polite" className="sr-only" data-testid="status-announcement">
          {announced ? copy.myDay.statusChanged.replace("{status}", announced) : ""}
        </p>
      </div>
      <div className="mt-6">
        <Button
          variant="outlined"
          size="md"
          shortcut="E"
          data-shortcut="e"
          onClick={() => setConfirming(true)}
        >
          {copy.myDay.endWorkday}
        </Button>
      </div>
      <ConfirmDialog
        open={confirming}
        title={copy.myDay.confirmTitle}
        confirmLabel={copy.myDay.confirmYes}
        cancelLabel={copy.myDay.confirmNo}
        onConfirm={confirmEnd}
        onCancel={() => setConfirming(false)}
        busy={pending}
      >
        {againAfterEnd ? copy.myDay.confirmBodyAgain.replace("{time}", dayEndsLabel) : copy.myDay.confirmBody}
      </ConfirmDialog>
    </Card>
  );
}

/**
 * The status colour from its flags and work area (lib/dashboard, the Dashboard's groups): Sales,
 * Operations, productive, other work, or a pause. Whether a pause is paid is not shown to agents. Always next to the name.
 */
function StatusDot({ status }: { status: WorkStatus }) {
  return <span aria-hidden="true" className={`inline-block h-2.5 w-2.5 shrink-0 rounded-full ${GROUP_BG[agentGroupOf(status)]}`} />;
}

/** A write's answer: the day from the write's own transaction ({ data: Workday }), or null when it cannot be read */
async function answerOf(res: Response): Promise<Workday | null> {
  const body = (await res.json().catch(() => null)) as { data?: Workday | null } | null;
  return body?.data ?? null;
}
