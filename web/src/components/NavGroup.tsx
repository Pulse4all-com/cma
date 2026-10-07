"use client";

/**
 * A group in the left navigation (Time, Reports, later Roster, Messages, …): one button that opens and
 * closes its pages. Closed by default; the browser remembers the choice per group in a cookie
 * (no personal data, one year), so every page renders the group as it was left. A closed group
 * that holds the current page is highlighted, so the person still sees where they are. The pages
 * keep their own digit keys whether the group is open or closed.
 */
import { useState, type ReactNode } from "react";
import { NAV_COOKIE_PREFIX, type NavIcon } from "@/lib/nav";

export function NavGroup({
  id,
  label,
  icon,
  defaultOpen,
  current,
  children,
}: {
  id: string;
  label: string;
  icon: NavIcon;
  defaultOpen: boolean;
  /** One of the group's pages is the current page */
  current: boolean;
  children: ReactNode;
}) {
  const [open, setOpen] = useState(defaultOpen);

  function toggle() {
    const next = !open;
    setOpen(next);
    document.cookie = `${NAV_COOKIE_PREFIX}${id}=${next ? "open" : "closed"}; path=/; max-age=31536000; samesite=lax; secure`;
  }
  return (
    <li>
      <button
        type="button"
        aria-expanded={open}
        aria-controls={`nav-group-${id}`}
        onClick={toggle}
        className={[
          "flex h-10 w-full items-center gap-3 rounded-button px-3 text-body font-semibold text-p4a-heading",
          !open && current ? "bg-white" : "hover:bg-white/60",
        ].join(" ")}
      >
        <NavIconMark name={icon} />
        <span className="flex-1 text-left">{label}</span>
        <svg
          aria-hidden="true"
          viewBox="0 0 16 16"
          className={`h-4 w-4 transition-transform ${open ? "rotate-180" : ""}`}
          fill="none"
          stroke="currentColor"
          strokeWidth="1.75"
          strokeLinecap="round"
          strokeLinejoin="round"
        >
          <path d="M4 6l4 4 4-4" />
        </svg>
      </button>
      <ul id={`nav-group-${id}`} className={open ? "mt-1 flex flex-col gap-1 pl-3" : "hidden"}>
        {children}
      </ul>
    </li>
  );
}

/** Line icons drawn in the text colour, so they follow the palette; shared with the bare rail items */
export function NavIconMark({ name }: { name: NavIcon }) {
  switch (name) {
    case "home":
      return (
        <svg
          aria-hidden="true"
          viewBox="0 0 20 20"
          className="h-5 w-5"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.75"
          strokeLinecap="round"
          strokeLinejoin="round"
        >
          <path d="M3.5 9.5 10 4l6.5 5.5" />
          <path d="M5.5 8.5v7.5h3.5v-4h2v4h3.5V8.5" />
        </svg>
      );
    case "live":
      return (
        <svg
          aria-hidden="true"
          viewBox="0 0 20 20"
          className="h-5 w-5"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.75"
          strokeLinecap="round"
          strokeLinejoin="round"
        >
          <circle cx="10" cy="10" r="2" />
          <path d="M6.25 13.75a5.3 5.3 0 0 1 0-7.5" />
          <path d="M13.75 6.25a5.3 5.3 0 0 1 0 7.5" />
          <path d="M4 16a8.5 8.5 0 0 1 0-12" />
          <path d="M16 4a8.5 8.5 0 0 1 0 12" />
        </svg>
      );
    case "people":
      return (
        <svg
          aria-hidden="true"
          viewBox="0 0 20 20"
          className="h-5 w-5"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.75"
          strokeLinecap="round"
          strokeLinejoin="round"
        >
          <circle cx="7.5" cy="7" r="2.75" />
          <path d="M2.5 16a5 5 0 0 1 10 0" />
          <circle cx="14" cy="8" r="2.25" />
          <path d="M13.5 16.5h4a3.75 3.75 0 0 0-3-3.7" />
        </svg>
      );
    case "clock":
      return (
        <svg
          aria-hidden="true"
          viewBox="0 0 20 20"
          className="h-5 w-5"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.75"
          strokeLinecap="round"
          strokeLinejoin="round"
        >
          <circle cx="10" cy="10" r="7.25" />
          <path d="M10 6v4l2.75 1.75" />
        </svg>
      );
    case "chart":
      return (
        <svg
          aria-hidden="true"
          viewBox="0 0 20 20"
          className="h-5 w-5"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.75"
          strokeLinecap="round"
          strokeLinejoin="round"
        >
          <path d="M3.5 16.5h13" />
          <path d="M6 13.5v-4" />
          <path d="M10 13.5v-8" />
          <path d="M14 13.5v-6" />
        </svg>
      );
  }
}
