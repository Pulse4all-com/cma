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
 */
import { useRef, useState, useSyncExternalStore, useTransition } from "react";
import type { KeyboardEvent as ReactKeyboardEvent, MouseEvent as ReactMouseEvent } from "react";
import { useRouter } from "next/navigation";
import type { WorkStatus, Workday } from "@/lib/data";
import type { Copy } from "@/lib/copy";
import { agentGroupOf, GROUP_BG } from "@/lib/dashboard";
import { Badge, Button, Card } from "./primitives";
import { ConfirmDialog } from "./ConfirmDialog";
import { endWorkdayAction } from "@/app/actions";

/** A one-second clock as an external store: no setState in effects, no hydration mismatch */
function subscribe(onTick: () => void) {
  const id = setInterval(onTick, 1000);
  return () => clearInterval(id);
}
const nowSeconds = () => Math.floor(Date.now() / 1000) * 1000;
const serverNow = () => null;

/** Worked seconds at `now` (ms), or the closed part alone before the client clock starts */
function worked(clock: Workday["clock"], now: number | null): number {
  if (now === null || !clock.runningSince) return clock.closedSeconds;
  return clock.closedSeconds + Math.max(0, Math.floor((now - Date.parse(clock.runningSince)) / 1000));
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
  const working = workday.status === "working";
  const current = statuses.find((s) => s.key === workday.statusKey);
  const group = useRef<HTMLDivElement>(null);

  /** The buttons that can be chosen now (the current status is disabled) */
  function choosable(): HTMLButtonElement[] {
    return Array.from(group.current?.querySelectorAll<HTMLButtonElement>("button:not([disabled])") ?? []);
  }

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
    setStatusFailed(false);
    startTransition(async () => {
      const res = await fetch("/api/v1/me/status", {
        method: "POST",
        headers: { "content-type": "application/json", "x-cma-request": "1" },
        body: JSON.stringify({ key }),
      });
      if (!res.ok) setStatusFailed(true);
      // Also after a refusal: the day may have ended in another tab
      router.refresh();
    });
  }

  function confirmEnd() {
    startTransition(async () => {
      await endWorkdayAction();
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
            {current?.name ?? copy.myDay.working}
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
        {hms(worked(workday.clock, now))}
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
                disabled={isCurrent || pending}
                onClick={() => changeStatus(s.key)}
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
