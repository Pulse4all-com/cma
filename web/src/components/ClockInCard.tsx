"use client";

/**
 * Clock in: an action, never a visit (increment e, 7 October 2026). Shown on Welcome and on
 * My day when there is no workday today for a person whose time is kept. The button calls
 * POST /api/v1/me/day/start, the path the API verifier proves, and the page re-renders with the
 * open day. The card names the tenant's default status; no status name is in code or copy.
 * The button has focus when the page opens, so Enter clocks in (keyboard-first, as on Log out).
 * Before the workday window starts the database refuses (0008b): the card then says when the day
 * starts, with the time the database gave, and the button stays. While the clock-in is in flight the
 * button is busy (aria-busy, dimmed), not disabled, so it keeps the focus until the open day replaces
 * the card and the person can press Enter again after a refusal (the IT audit of 17 October 2026).
 */
import { useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import type { Copy } from "@/lib/copy";
import { workdayStartsAt } from "@/lib/live";
import { Badge, Card, Keycap, Notice } from "./primitives";

export function ClockInCard({ defaultStatusName, copy }: { defaultStatusName: string; copy: Copy }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [failed, setFailed] = useState(false);
  const [startsAt, setStartsAt] = useState<string | null>(null);
  /** One clock-in at a time: a second Enter while the first is in flight does nothing */
  const inFlight = useRef(false);

  function clockIn() {
    if (inFlight.current) return;
    inFlight.current = true;
    setFailed(false);
    setStartsAt(null);
    startTransition(async () => {
      const res = await fetch("/api/v1/me/day/start", { method: "POST", headers: { "x-cma-request": "1" } }).catch(() => null);
      if (!res?.ok) {
        const body = res ? ((await res.json().catch(() => null)) as { error?: { message?: string } } | null) : null;
        const at = workdayStartsAt(body?.error?.message);
        if (at) setStartsAt(at);
        else setFailed(true);
      }
      // Also after a refusal: the day may have been opened in another tab
      router.refresh();
      inFlight.current = false;
    });
  }

  return (
    <Card>
      <Badge tone="neutral">{copy.welcome.notClockedIn}</Badge>
      <p className="mt-4 text-body">{copy.welcome.clockInBody.replace("{status}", defaultStatusName)}</p>
      <button
        type="button"
        autoFocus
        aria-busy={pending}
        onClick={clockIn}
        data-testid="clock-in"
        className="mt-6 inline-flex h-12 w-full items-center justify-center gap-3 rounded-button bg-p4a-deepblue px-6 font-semibold text-white hover:bg-p4a-denim aria-busy:opacity-60"
      >
        {copy.welcome.clockIn}
        <Keycap>Enter</Keycap>
      </button>
      {startsAt ? (
        <div className="mt-3" data-testid="clock-in-too-early">
          <Notice tone="info">{copy.welcome.clockInTooEarly.replace("{time}", startsAt)}</Notice>
        </div>
      ) : null}
      {failed ? (
        <p role="alert" className="mt-3 text-small text-p4a-body">
          {copy.welcome.clockInFailed}
        </p>
      ) : null}
    </Card>
  );
}
