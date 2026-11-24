"use client";

/**
 * The head start after Welcome (night N07, decision D5): mounted once Welcome's blocks have settled (the page streams it
 * after every block's read), it waits until the browser is idle and then prefetches the role's top destinations in full
 * (lib/nav headStartHrefs: the page with its data, router.prefetch of kind full), so the person's next click finds the
 * page there. Only routes of 131's agent class reach it; a report never does. Kept as long as staleTimes.static says
 * (next.config.ts, 30 s); when Next drops a prefetch as stale it is not fetched again until the next visit of Welcome.
 * Renders nothing.
 */
import { useEffect } from "react";
import { useRouter } from "next/navigation";
import { mayFullPrefetch } from "@/lib/nav";

type IdleWindow = Window & { requestIdleCallback?: (cb: () => void, opts?: { timeout: number }) => number; cancelIdleCallback?: (id: number) => void };

export function IdlePrefetch({ hrefs }: { hrefs: readonly string[] }) {
  const router = useRouter();
  const key = hrefs.join(" ");
  useEffect(() => {
    const list = key.split(" ").filter((h) => h !== "" && mayFullPrefetch(h));
    if (list.length === 0) return;
    const w = window as IdleWindow;
    const run = () => {
      for (const href of list) router.prefetch(href, { kind: "full" } as Parameters<typeof router.prefetch>[1]);
    };
    if (w.requestIdleCallback) {
      const id = w.requestIdleCallback(run, { timeout: 3000 });
      return () => w.cancelIdleCallback?.(id);
    }
    const id = setTimeout(run, 500);
    return () => clearTimeout(id);
  }, [key, router]);
  return null;
}
