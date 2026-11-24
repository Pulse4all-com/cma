"use client";

/**
 * Reports → Follow-up's poll (night N07, decision D3; the N06 remainder): every 10 seconds while the tab is visible, and
 * once when it comes back, it asks GET /api/v1/reports/follow-up/updated when the snapshot was computed, as the Live board
 * polls its API route; only when the snapshot moved (at most about once a minute, the refresh job's cadence) the page is
 * read again, in a transition, so the filters and the scroll stay. Before, router.refresh() ran every 10 seconds, which
 * also emptied the client router cache and made every visible rail link prefetch again; the rail's prefetch exception
 * for this page is gone with it. A failed poll waits twice as long, up to a minute.
 */
import { useEffect, useRef, useTransition } from "react";
import { useRouter } from "next/navigation";

export const FOLLOW_UP_POLL_MS = 10_000;
const MAX_WAIT_MS = 60_000;

export function FollowUpPoll({ computedAt }: { computedAt: string }) {
  const router = useRouter();
  const [, startTransition] = useTransition();
  const shown = useRef(computedAt);
  useEffect(() => {
    shown.current = computedAt;
  }, [computedAt]);
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | null = null;
    let stopped = false;
    let failures = 0;
    const tick = async () => {
      timer = null;
      if (document.hidden) return;
      try {
        const res = await fetch("/api/v1/reports/follow-up/updated", { cache: "no-store" });
        if (!res.ok) throw new Error(String(res.status));
        failures = 0;
        const at = ((await res.json()) as { data?: { computedAt?: string } }).data?.computedAt;
        // a later snapshot than the one on the screen: the page is read again
        if (at && Date.parse(at) > Date.parse(shown.current)) startTransition(() => router.refresh());
      } catch {
        failures += 1;
      }
      if (!stopped && !document.hidden) timer = setTimeout(tick, Math.min(MAX_WAIT_MS, FOLLOW_UP_POLL_MS * 2 ** failures));
    };
    const onVisibility = () => {
      if (timer) clearTimeout(timer);
      timer = null;
      if (!document.hidden) void tick();
    };
    timer = setTimeout(tick, FOLLOW_UP_POLL_MS);
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      stopped = true;
      if (timer) clearTimeout(timer);
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, [router]);
  return null;
}
