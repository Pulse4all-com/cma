"use client";

/**
 * The Live board's poll: router.refresh() every 10 seconds while the tab is visible, paused while it is
 * hidden and once more when it comes back (the fallback until the realtime service; README: Roadmap
 * step 2). One per page, so the people board, the inbound tiles and the missed calls (addition 0008i)
 * are read again together, also on a board without people.
 */
import { useEffect } from "react";
import { useRouter } from "next/navigation";

export const REFRESH_MS = 10_000;

export function LiveRefresh() {
  const router = useRouter();
  useEffect(() => {
    // A timeout chain, not an interval: the next tick is armed after the refresh was requested, so a slow
    // render never overlaps the next one (the IT audit of 17 October 2026, finding 5.6-11)
    let id: ReturnType<typeof setTimeout> | null = null;
    const tick = () => {
      router.refresh();
      id = setTimeout(tick, REFRESH_MS);
    };
    const start = () => {
      if (id === null) id = setTimeout(tick, REFRESH_MS);
    };
    const stop = () => {
      if (id !== null) clearTimeout(id);
      id = null;
    };
    const onVisibility = () => {
      if (document.visibilityState === "visible") {
        router.refresh();
        start();
      } else {
        stop();
      }
    };
    if (document.visibilityState === "visible") start();
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      stop();
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, [router]);
  return null;
}
