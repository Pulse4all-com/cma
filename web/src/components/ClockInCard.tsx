"use client";

/**
 * Clock in: an action, never a visit (increment e, 7 October 2026). Shown on Welcome and on
 * My day when there is no workday today for a person whose time is kept. The button calls
 * POST /api/v1/me/day/start, the path the API verifier proves, and the page re-renders with the
 * open day. The card names the tenant's default status; no status name is in code or copy.
 * The button has focus when the page opens, so Enter clocks in (keyboard-first, as on Log out).
 */
import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import type { Copy } from "@/lib/copy";
import { Badge, Card, Keycap } from "./primitives";

export function ClockInCard({ defaultStatusName, copy }: { defaultStatusName: string; copy: Copy }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [failed, setFailed] = useState(false);

  function clockIn() {
    setFailed(false);
    startTransition(async () => {
      const res = await fetch("/api/v1/me/day/start", { method: "POST", headers: { "x-cma-request": "1" } });
      if (!res.ok) setFailed(true);
      // Also after a refusal: the day may have been opened in another tab
      router.refresh();
    });
  }

  return (
    <Card>
      <Badge tone="neutral">{copy.welcome.notClockedIn}</Badge>
      <p className="mt-4 text-body">{copy.welcome.clockInBody.replace("{status}", defaultStatusName)}</p>
      <button
        type="button"
        autoFocus
        disabled={pending}
        onClick={clockIn}
        data-testid="clock-in"
        className="mt-6 inline-flex h-12 w-full items-center justify-center gap-3 rounded-button bg-p4a-deepblue px-6 font-semibold text-white hover:bg-p4a-denim disabled:opacity-60"
      >
        {copy.welcome.clockIn}
        <Keycap>Enter</Keycap>
      </button>
      {failed ? (
        <p role="alert" className="mt-3 text-small text-p4a-body">
          {copy.welcome.clockInFailed}
        </p>
      ) : null}
    </Card>
  );
}
