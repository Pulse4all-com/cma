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
    let id: ReturnType<typeof setInterval> | null = null;
    const start = () => {
      if (id === null) id = setInterval(() => router.refresh(), REFRESH_MS);
    };
    const stop = () => {
      if (id !== null) clearInterval(id);
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
