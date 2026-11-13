"use client";

/**
 * A filter's navigation as a transition (12 November 2026; the pattern of Customers → Active's filters, decision D14):
 * the choice shows something within 100 ms (CLAUDE.md, Performance) while the report's reads run. A change of the
 * address's parameters shows no route skeleton, so without this a choice showed nothing until the answer was there.
 * The filter's row says aria-busy and its controls dim and show a progress cursor, the control that was changed shows
 * the choice at once, and the figures on the screen stay until the new ones are there. No fetch of its own: Next's router and React's transition.
 */
import type { Route } from "next";
import { useRouter } from "next/navigation";
import { useOptimistic, useTransition } from "react";

/**
 * A filter's choice with its optimistic result: [the choice is on its way, what the controls show, choose]. The controls
 * show what was chosen from the moment of the choice (React's useOptimistic over the address's value), not the previous
 * value dimmed; when the answer is there they show the address's value again, which is the choice unless the server
 * answered otherwise. A second choice in the same row while the first is on its way builds on what is shown, so both are
 * kept; a choice in another row of the page (Flash's controls, Forms' answers, the planner's week) builds on the address,
 * as before, and replaces the first. A control whose list depends on another's choice is closed while that choice is on its way
 */
export function usePendingChoice<T>(current: T): [boolean, T, (next: T, href: Route, options?: { scroll?: boolean }) => void] {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [shown, setShown] = useOptimistic(current);
  return [pending, shown, (next, href, options) => startTransition(() => { setShown(next); router.push(href, options); })];
}

/** [the choice is on its way, go to an address as a transition]: for a control that keeps its own value (a date field, a button) */
export function usePendingPush(): [boolean, (href: Route, options?: { scroll?: boolean }) => void] {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  return [pending, (href, options) => startTransition(() => { router.push(href, options); })];
}

/**
 * A filter row's classes: while the row says aria-busy its controls dim and show a progress cursor (as Customers →
 * Active's selects do). On the row, so every control of the row follows without a class of its own
 */
export const PENDING_ROW = "[&[aria-busy=true]_select]:cursor-progress [&[aria-busy=true]_select]:opacity-60 [&[aria-busy=true]_input]:cursor-progress [&[aria-busy=true]_input]:opacity-60 [&[aria-busy=true]_button]:cursor-progress [&[aria-busy=true]_button]:opacity-60";
