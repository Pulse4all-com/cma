"use client";

/**
 * The head start after Welcome (night N07, decision D5): mounted once Welcome's blocks have settled (the page streams it
 * after every block's read), it waits until the browser is idle and then prefetches the role's top destinations in full
 * (lib/nav headStartHrefs: the page with its data, router.prefetch of kind full), so the person's next click finds the
 * page there. Only routes of 131's agent class reach it; a report never does. Kept as long as staleTimes.static says
 * (next.config.ts, 30 s); when Next drops a prefetch as stale it is not fetched again until the next visit of Welcome.
 * Renders nothing. It marks the document with what it did, `<html data-head-start>`: the routes it asked for, separated
 * by spaces, once it has asked; "none" when the person's head start is empty (a day not open yet, or a role without
 * one). Route paths only, never an id or a person's data. verify/round-trips.mjs waits for the marker, and in prod
 * `document.documentElement.dataset.headStart` in the browser's console shows it (RUNBOOK 5)
 */
import { useEffect } from "react";
import { useRouter } from "next/navigation";
import { mayFullPrefetch } from "@/lib/nav";

type IdleWindow = Window & { requestIdleCallback?: (cb: () => void, opts?: { timeout: number }) => number; cancelIdleCallback?: (id: number) => void };

/** The head starts this tab already ran (the person and the day's state): at most once each, never again on Welcome's revisits */
const ran = new Set<string>();

export function IdlePrefetch({ hrefs, runKey }: { hrefs: readonly string[]; runKey: string }) {
  const router = useRouter();
  const key = hrefs.join(" ");
  useEffect(() => {
    const list = key.split(" ").filter((h) => h !== "" && mayFullPrefetch(h));
    const mark = document.documentElement.dataset;
    if (list.length === 0) {
      mark.headStart = "none";
      return;
    }
    if (ran.has(runKey)) return;
    // a new head start (after Clock in): the earlier "none" no longer holds until this one has asked
    delete mark.headStart;
    const w = window as IdleWindow;
    const run = () => {
      ran.add(runKey);
      for (const href of list) router.prefetch(href, { kind: "full" } as Parameters<typeof router.prefetch>[1]);
      mark.headStart = list.join(" ");
    };
    if (w.requestIdleCallback) {
      const id = w.requestIdleCallback(run, { timeout: 3000 });
      return () => w.cancelIdleCallback?.(id);
    }
    const id = setTimeout(run, 500);
    return () => clearTimeout(id);
  }, [key, runKey, router]);
  return null;
}
