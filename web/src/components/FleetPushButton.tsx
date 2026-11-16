"use client";

/**
 * A button of Assets → Fleet management that changes the page's address (a tile, a device's row, the pager, every postcode
 * area again; addition 0009t): a transition, so the click shows something within 100 ms while the server answers
 * (CLAUDE.md, Performance). The button says aria-busy and dims; a button with a pressed state (a tile) shows its new state
 * at once (React's useOptimistic over the address's), and the page does not jump to the top
 */
import type { Route } from "next";
import { useRouter } from "next/navigation";
import { useOptimistic, useTransition, type ReactNode } from "react";

export function FleetPushButton({ href, label, pressed, className, testId, children }: {
  href: string;
  /** The button's name for assistive technology, when its content does not say it all */
  label?: string;
  /** Its pressed state (a tile); style it with aria-pressed: classes, so the optimistic state shows too */
  pressed?: boolean;
  className: string;
  testId?: string;
  children: ReactNode;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [shownPressed, setShownPressed] = useOptimistic(pressed);
  return (
    <button type="button" aria-label={label} aria-pressed={shownPressed} aria-busy={pending || undefined} data-testid={testId}
      className={`${className} aria-busy:cursor-progress aria-busy:opacity-60 focus:outline-none focus-visible:ring-2 focus-visible:ring-p4a-lightblue focus-visible:ring-offset-2`}
      onClick={() => startTransition(() => {
        if (pressed !== undefined) setShownPressed(!pressed);
        router.push(href as Route, { scroll: false });
      })}>
      {children}
    </button>
  );
}
