"use client";

/**
 * The pending mark of a period link (12 November 2026; the pattern of Customers → Active's LinkMark, decision D14): a
 * dot in the link's corner from the click until the answer is on the screen, so a click shows something within 100 ms
 * (CLAUDE.md, Performance) while the period's reads run. It sits over the link, outside the text's flow, so no link
 * changes its width and nothing moves. No fetch, no data: Next's link status alone. Rendered inside a <Link>.
 */
import { useLinkStatus } from "next/link";

export function LinkPending() {
  const { pending } = useLinkStatus();
  return (
    <span aria-hidden="true" data-link-pending={pending ? "true" : undefined}
      className={`pointer-events-none absolute right-1 top-1 h-1.5 w-1.5 rounded-full bg-current ${pending ? "animate-pulse opacity-80" : "opacity-0"}`} />
  );
}
