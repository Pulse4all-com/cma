"use client";

/**
 * The one small client component of Customers → Active beside its filters (decision D14 of addendum B, 11 November 2026,
 * which narrows D6): it marks a link while its navigation is pending, and it knows when every streamed part of the page
 * is on the screen. No fetch of its own, no data: Next's link status and the marks the server's parts leave behind.
 *
 * LinkMark     inside a <Link>: a dot that shows from the click until the answer is on the screen (CLAUDE.md,
 *              Performance: a click shows something within 100 ms). It keeps its place while idle, so nothing moves
 * Streamed     rendered at the end of a streamed part: says "this part of this view is on the screen"
 * PrintWhenReady   the Print button (X), disabled with the hint "Loading…" until every part of the view has streamed
 *              (decision D15: the print CSS prints only a complete page)
 */
import { useLinkStatus } from "next/link";
import { useEffect, useSyncExternalStore } from "react";
import { Button } from "./primitives";

export function LinkMark() {
  const { pending } = useLinkStatus();
  return (
    <span aria-hidden="true" data-link-pending={pending ? "true" : undefined}
      className={`ml-1 inline-block h-1.5 w-1.5 shrink-0 rounded-full bg-current align-middle ${pending ? "animate-pulse opacity-80" : "opacity-0"}`} />
  );
}

// The parts on the screen, per view (the view's key is its address's parameters): a set of part names
const seen = new Map<string, Set<string>>();
const listeners = new Set<() => void>();
const tell = () => { for (const l of listeners) l(); };
const subscribe = (l: () => void) => { listeners.add(l); return () => { listeners.delete(l); }; };

export function Streamed({ part, view }: { part: string; view: string }) {
  useEffect(() => {
    const parts = seen.get(view) ?? new Set<string>();
    parts.add(part);
    seen.set(view, parts);
    tell();
    return () => {
      seen.get(view)?.delete(part);
      if (seen.get(view)?.size === 0) seen.delete(view);
      tell();
    };
  }, [part, view]);
  return null;
}

export function PrintWhenReady({ label, loading, view, parts }: { label: string; loading: string; view: string; parts: readonly string[] }) {
  const ready = useSyncExternalStore(subscribe, () => parts.every((p) => seen.get(view)?.has(p) === true), () => false);
  return (
    <Button variant="primary" shortcut="X" data-shortcut="x" disabled={!ready} title={ready ? undefined : loading} aria-busy={!ready || undefined}
      data-testid="active-print" data-ready={ready ? "true" : "false"} onClick={() => window.print()}>
      {ready ? label : loading}
    </Button>
  );
}
