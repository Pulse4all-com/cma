"use client";

/**
 * The two browser preferences of the frame (16 October 2026): the rail folded to icons (cookie cma-rail,
 * a modern sidebar) and the keyboard hints shown or hidden (cookie cma-hints, backlog CMA-004). Each is a
 * data attribute on the frame that globals.css styles, so a click changes the screen at once, and the
 * server renders the next page in the same state from the cookie (Shell), without a flicker. The keys
 * keep working whatever the state: the hook reads data-shortcut, never the keycaps.
 *
 * The rail's toggle takes W. W is free in the whole app's shell; a page control with W (This week on the
 * roster and My schedule) wins over it by the hook's rule (a control inside main comes first), so on
 * those pages W moves to this week and the toggle is a click away. ? toggles the hints: a one-character
 * key the hook accepts (Shift is fine, no Ctrl, Alt or Meta).
 */
import { useEffect, useState } from "react";
import type { Copy } from "@/lib/copy";
import { HINTS_COOKIE, prefCookie, RAIL_COOKIE } from "@/lib/nav";
import { Keycap } from "./primitives";

/** Fired on the window when the rail folds or unfolds, so the toggle follows a group's click */
export const RAIL_CHANGED_EVENT = "cma-rail-changed";

const frame = () => document.querySelector<HTMLElement>("[data-rail]");

/** True while the rail is folded, read from the frame (the cookie's value at render, or the latest click) */
export function railCollapsed(): boolean {
  return frame()?.getAttribute("data-rail") === "collapsed";
}

/** Folds or unfolds the rail: the attribute (the screen), the cookie (the next page) and a word to the toggle */
export function setRailCollapsed(collapsed: boolean) {
  frame()?.setAttribute("data-rail", collapsed ? "collapsed" : "expanded");
  document.cookie = prefCookie(RAIL_COOKIE, collapsed ? "collapsed" : "expanded");
  window.dispatchEvent(new CustomEvent<boolean>(RAIL_CHANGED_EVENT, { detail: collapsed }));
}

/** The button at the foot of the rail: chevron left to fold, chevron right to unfold */
export function RailToggle({ collapsed: initial, copy }: { collapsed: boolean; copy: Copy["shell"] }) {
  const [collapsed, setCollapsed] = useState(initial);
  useEffect(() => {
    const follow = (e: Event) => setCollapsed((e as CustomEvent<boolean>).detail);
    window.addEventListener(RAIL_CHANGED_EVENT, follow);
    return () => window.removeEventListener(RAIL_CHANGED_EVENT, follow);
  }, []);
  const label = collapsed ? copy.expandNav : copy.collapseNav;
  return (
    <button
      type="button"
      onClick={() => setRailCollapsed(!collapsed)}
      aria-expanded={!collapsed}
      aria-label={label}
      title={`${label} (W)`}
      data-shortcut="w"
      aria-keyshortcuts="W"
      data-testid="rail-toggle"
      className="flex h-10 w-full items-center gap-3 rounded-button px-3 text-small font-semibold text-p4a-heading hover:bg-white/60"
    >
      <svg
        aria-hidden="true"
        viewBox="0 0 20 20"
        className={`h-5 w-5 shrink-0 transition-transform ${collapsed ? "rotate-180" : ""}`}
        fill="none"
        stroke="currentColor"
        strokeWidth="1.75"
        strokeLinecap="round"
        strokeLinejoin="round"
      >
        <path d="M12.5 5 7.5 10l5 5" />
      </svg>
      <span data-rail-text className="min-w-0 flex-1 truncate text-left">{label}</span>
      <Keycap data-rail-text>W</Keycap>
    </button>
  );
}

/** The keyboard icon in the top bar: pressed while the hints are hidden */
export function HintsToggle({ hidden: initial, copy }: { hidden: boolean; copy: Copy["shell"] }) {
  const [hidden, setHidden] = useState(initial);
  function toggle() {
    const next = !hidden;
    setHidden(next);
    frame()?.setAttribute("data-hints", next ? "hidden" : "shown");
    document.cookie = prefCookie(HINTS_COOKIE, next ? "hidden" : "shown");
  }
  const label = hidden ? copy.showHints : copy.hideHints;
  return (
    <button
      type="button"
      onClick={toggle}
      aria-pressed={hidden}
      aria-label={label}
      title={label}
      data-shortcut="?"
      aria-keyshortcuts="?"
      data-testid="hints-toggle"
      className="inline-flex h-8 items-center rounded-button px-2 text-p4a-body hover:bg-p4a-bgblue aria-pressed:bg-p4a-bgblue aria-pressed:text-p4a-deepblue"
    >
      <svg aria-hidden="true" viewBox="0 0 20 20" className="h-5 w-5" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round">
        <rect x="2.5" y="5.5" width="15" height="9" rx="1.5" />
        <path d="M5.5 8.5h1M8.5 8.5h1M11.5 8.5h1M14.5 8.5h1M5.5 11.5h1M8 11.5h4M13.5 11.5h1" />
      </svg>
    </button>
  );
}
