"use client";

import { useEffect, useRef } from "react";
import { usePathname } from "next/navigation";
import {
  BEACON_PATH, CONTENT_PENDING_SELECTOR, MAX_BEACON_MS, interactionBucketOf, routePatternOf,
  type BeaconKind, type NavigationBeacon as Beacon,
} from "@/lib/telemetry";

/** How long the beacon waits for the destination's content before it reports none (contentMs null) */
const CONTENT_WAIT_MS = 30_000;
/** A click older than this is not the start of the navigation that follows (a link opened in a new tab, a cancelled click) */
const CLICK_TTL_MS = 10_000;

/** The next frame's time: two animation frames, so the frame the change is in has been painted */
function afterNextFrame(): Promise<number> {
  return new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve(performance.now()))));
}

/** The moment the destination's route skeleton is gone (the next frame after), or null after CONTENT_WAIT_MS */
function contentShown(): Promise<number | null> {
  return new Promise((resolve) => {
    if (!document.querySelector(CONTENT_PENDING_SELECTOR)) {
      void afterNextFrame().then(resolve);
      return;
    }
    const timer = setTimeout(() => { observer.disconnect(); resolve(null); }, CONTENT_WAIT_MS);
    const observer = new MutationObserver(() => {
      if (document.querySelector(CONTENT_PENDING_SELECTOR)) return;
      observer.disconnect();
      clearTimeout(timer);
      void afterNextFrame().then(resolve);
    });
    observer.observe(document.body, { childList: true, subtree: true });
  });
}

function send(b: Beacon): void {
  try {
    const body = new Blob([JSON.stringify(b)], { type: "application/json" });
    navigator.sendBeacon?.(BEACON_PATH, body);
  } catch {
    // telemetry never costs the person anything
  }
}

const ms = (x: number) => Math.min(MAX_BEACON_MS, Math.max(0, Math.round(x)));

/**
 * The navigation beacon (brief N07, WP1; src/lib/telemetry.ts): after the page's first load and after each client
 * navigation, one beacon with the route pattern (lib/nav's pages; anything else "other"), the kind, the time to first
 * frame and to content, and the latest interaction's delay in buckets. A navigation starts at the click on a link of
 * this origin (or Back and Forward); a document at the navigation's start (performance's time origin). Renders nothing;
 * mounted once in the root layout, so it survives every navigation.
 */
export function NavigationBeacon() {
  const pathname = usePathname();
  const clickAt = useRef<number | null>(null);
  const interactionMs = useRef<number | null>(null);
  const first = useRef(true);

  // The latest interaction's duration (the Event Timing API; absent in a browser without it: "none")
  useEffect(() => {
    if (typeof PerformanceObserver === "undefined" || !PerformanceObserver.supportedEntryTypes?.includes("event")) return;
    const po = new PerformanceObserver((list) => {
      for (const e of list.getEntries() as (PerformanceEntry & { interactionId?: number })[]) {
        if ((e.interactionId ?? 0) > 0) interactionMs.current = e.duration;
      }
    });
    try {
      po.observe({ type: "event", buffered: true, durationThreshold: 16 } as PerformanceObserverInit);
    } catch {
      return;
    }
    return () => po.disconnect();
  }, []);

  // A navigation's start: a click on a same-origin link (capture phase, before the router acts), Back or Forward
  useEffect(() => {
    const onClick = (e: MouseEvent) => {
      if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
      const a = (e.target as Element | null)?.closest?.("a[href]") as HTMLAnchorElement | null;
      if (a && a.origin === location.origin && !a.target) clickAt.current = performance.now();
    };
    const onPop = () => { clickAt.current = performance.now(); };
    document.addEventListener("click", onClick, true);
    window.addEventListener("popstate", onPop);
    return () => {
      document.removeEventListener("click", onClick, true);
      window.removeEventListener("popstate", onPop);
    };
  }, []);

  useEffect(() => {
    let cancelled = false;
    const kind: BeaconKind = first.current ? "document" : "navigation";
    first.current = false;
    const now = performance.now();
    const clicked = clickAt.current !== null && now - clickAt.current <= CLICK_TTL_MS ? clickAt.current : null;
    clickAt.current = null;
    // A document starts at the time origin (0); a navigation at its click, else at the moment the path changed
    const start = kind === "document" ? 0 : clicked ?? now;
    const route = routePatternOf(pathname);
    void (async () => {
      let firstFrame: number;
      if (kind === "document") {
        const paint = performance.getEntriesByName("first-paint")[0] ?? performance.getEntriesByName("first-contentful-paint")[0];
        firstFrame = paint ? paint.startTime : await afterNextFrame();
      } else {
        firstFrame = await afterNextFrame();
      }
      const content = await contentShown();
      if (cancelled) return;
      send({
        route, kind, firstFrameMs: ms(firstFrame - start),
        contentMs: content === null ? null : ms(Math.max(content, firstFrame) - start),
        interaction: interactionBucketOf(interactionMs.current),
      });
    })();
    return () => { cancelled = true; };
  }, [pathname]);

  return null;
}
