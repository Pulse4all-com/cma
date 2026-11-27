"use client";

/**
 * The Live board's poll: router.refresh() every 10 seconds while the tab is visible, paused while it is
 * hidden and once more when it comes back (the fallback until the realtime service; README: Roadmap
 * step 2). One per page, so the people board, the inbound tiles and the missed calls (addition 0008i)
 * are read again together, also on a board without people. Once the tab's sign-in has ended (a request answered 401,
 * src/lib/client-fetch.ts) it stops for good: a refresh would follow IAP's answer to Google's sign-in by itself.
 */
import { useEffect } from "react";
import { useRouter } from "next/navigation";
import { SESSION_EXPIRED_EVENT, sessionExpired } from "@/lib/client-fetch";

export const REFRESH_MS = 10_000;

export function LiveRefresh() {
  const router = useRouter();
  useEffect(() => {
    // A timeout chain, not an interval: the next tick is armed after the refresh was requested, so a slow
    // render never overlaps the next one (the IT audit of 17 October 2026, finding 5.6-11)
    let id: ReturnType<typeof setTimeout> | null = null;
    const tick = () => {
      if (sessionExpired()) return stop();
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
      if (sessionExpired()) return stop();
      if (document.visibilityState === "visible") {
        router.refresh();
        start();
      } else {
        stop();
      }
    };
    if (document.visibilityState === "visible" && !sessionExpired()) start();
    document.addEventListener("visibilitychange", onVisibility);
    window.addEventListener(SESSION_EXPIRED_EVENT, stop);
    return () => {
      stop();
      document.removeEventListener("visibilitychange", onVisibility);
      window.removeEventListener(SESSION_EXPIRED_EVENT, stop);
    };
  }, [router]);
  return null;
}
