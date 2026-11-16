"use client";

/**
 * A button of Assets → Fleet management that changes the page's address (a tile, a device's row, the pager, back to the
 * devices that need attention; addition 0009t): a transition, so the click shows something within 100 ms (the button's
 * aria-busy dims it) while the server answers, and the page does not jump to the top
 */
import type { Route } from "next";
import type { ReactNode } from "react";
import { usePendingPush } from "./usePendingPush";

export function FleetPushButton({ href, label, pressed, className, testId, children }: {
  href: string;
  /** The button's name for assistive technology, when its content does not say it all */
  label?: string;
  pressed?: boolean;
  className: string;
  testId?: string;
  children: ReactNode;
}) {
  const [pending, push] = usePendingPush();
  return (
    <button type="button" aria-label={label} aria-pressed={pressed} aria-busy={pending || undefined} data-testid={testId}
      className={`${className} aria-busy:cursor-progress aria-busy:opacity-60 focus:outline-none focus-visible:ring-2 focus-visible:ring-p4a-lightblue focus-visible:ring-offset-2`}
      onClick={() => push(href as Route, { scroll: false })}>
      {children}
    </button>
  );
}
