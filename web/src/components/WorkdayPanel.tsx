"use client";

/**
 * The heart of My day: the running clock. One memorable element, everything
 * else quiet. Ticks every second from the server-provided start instant, so a
 * tab left open all day stays right without polling.
 */
import { useState, useSyncExternalStore, useTransition } from "react";
import { useRouter } from "next/navigation";
import type { Workday } from "@/lib/data";
import type { Copy } from "@/lib/copy";
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

function elapsed(from: string, to: number): string {
  const s = Math.max(0, Math.floor((to - Date.parse(from)) / 1000));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  return `${h}:${String(m).padStart(2, "0")}:${String(sec).padStart(2, "0")}`;
}

export function WorkdayPanel({
  workday,
  startedLabel,
  endedLabel,
  copy,
}: {
  workday: Workday;
  /** Pre-formatted in the user's zone and locale on the server */
  startedLabel: string;
  endedLabel: string | null;
  copy: Copy;
}) {
  const router = useRouter();
  const now = useSyncExternalStore(subscribe, nowSeconds, serverNow);
  const [confirming, setConfirming] = useState(false);
  const [pending, startTransition] = useTransition();
  const working = workday.status === "working";

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
        <Badge tone="success">{copy.myDay.working}</Badge>
        <span className="text-small text-p4a-muted">
          {copy.myDay.workingSince} <span className="tabular text-p4a-body">{startedLabel}</span>
        </span>
      </div>
      <p className="mt-6 text-caption text-p4a-grey">{copy.myDay.workedToday}</p>
      <p
        data-testid="workday-clock"
        className="tabular text-clock font-semibold text-p4a-heading"
        aria-live="off"
      >
        {now === null ? elapsed(workday.startedAt, Date.parse(workday.startedAt)) : elapsed(workday.startedAt, now)}
      </p>
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
