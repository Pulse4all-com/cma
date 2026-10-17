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
 */
import { useEffect, useRef, useState, useSyncExternalStore, useTransition } from "react";
import type { KeyboardEvent as ReactKeyboardEvent, MouseEvent as ReactMouseEvent } from "react";
import { useRouter } from "next/navigation";
import type { WorkStatus, Workday } from "@/lib/data";
import type { Copy } from "@/lib/copy";
import { agentGroupOf, GROUP_BG } from "@/lib/dashboard";
import { Badge, Button, Card } from "./primitives";
import { ConfirmDialog } from "./ConfirmDialog";
import { workedSeconds } from "@/lib/live";

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
  startedLabel,
  statusSinceLabel,
  endedLabel,
  copy,
}: {
  workday: Workday;
  /** The tenant's active statuses, in the tenant's order */
  statuses: WorkStatus[];
  /** Pre-formatted in the user's zone and locale on the server */
  startedLabel: string;
  statusSinceLabel: string | null;
  endedLabel: string | null;
  copy: Copy;
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
  /** The status whose button gets the focus back once the change has landed */
  const refocus = useRef<string | null>(null);
  const working = workday.status === "working";
  const current = statuses.find((s) => s.key === workday.statusKey);
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
  }, [pending, workday.statusKey]);

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
    startTransition(async () => {
      const res = await fetch("/api/v1/me/status", {
        method: "POST",
        headers: { "content-type": "application/json", "x-cma-request": "1" },
        body: JSON.stringify({ key }),
      }).catch(() => null);
      if (!res?.ok) setStatusFailed(true);
      else setAnnounced(statuses.find((s) => s.key === key)?.name ?? key);
      refocus.current = key;
      // Also after a refusal: the day may have ended in another tab
      router.refresh();
      setPendingKey(null);
    });
  }

  function confirmEnd() {
    setStatusFailed(false);
    startTransition(async () => {
      // The same guarded route the API verifier covers (assertSameSiteWrite), not a server action: one
      // write rule for every write (the IT audit of 17 October 2026). A refusal shows the status problem
      // line; the refresh then shows the day as the database has it (ended in another tab, for example)
      const res = await fetch("/api/v1/me/day/end", { method: "POST", headers: { "x-cma-request": "1" } });
      if (!res.ok && res.status !== 409) setStatusFailed(true);
      setConfirming(false);
      router.refresh();
    });
  }

  if (!working) {
    return (
      <Card>
        <div className="flex items-center gap-3">
          <Badge tone="neutral">{copy.myDay.dayEnded}</Badge>
        </div>
        <p className="mt-4 text-body">{copy.myDay.dayEndedBody}</p>
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
            {current?.name ?? workday.statusName ?? copy.myDay.working}
          </span>
        </Badge>
        {statusSinceLabel ? (
          <span className="text-small text-p4a-muted">
            {copy.myDay.workingSince} <span className="tabular text-p4a-body">{statusSinceLabel}</span>
          </span>
        ) : null}
        <span className="ml-auto text-small text-p4a-muted">
          {copy.myDay.startedAt} <span className="tabular text-p4a-body">{startedLabel}</span>
        </span>
      </div>
      <p className="mt-6 text-caption text-p4a-grey">{copy.myDay.workedToday}</p>
      <p
        data-testid="workday-clock"
        className="tabular text-clock font-semibold text-p4a-heading"
        aria-live="off"
      >
        {hms(worked(workday, now))}
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
            const isCurrent = s.key === workday.statusKey;
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
        {copy.myDay.confirmBody}
      </ConfirmDialog>
    </Card>
  );
}

/**
 * The status colour from its flags (lib/dashboard, the Dashboard's groups): productive, other work,
 * or a pause. Whether a pause is paid is not shown to agents. Always next to the name.
 */
function StatusDot({ status }: { status: WorkStatus }) {
  return <span aria-hidden="true" className={`inline-block h-2.5 w-2.5 shrink-0 rounded-full ${GROUP_BG[agentGroupOf(status)]}`} />;
}
