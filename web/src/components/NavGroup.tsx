"use client";

/**
 * A group in the left navigation (Live, Team, Time, Reports, Sales, Customers, Campaigns, Configuration): one button that opens and
 * closes its pages. The rail is an accordion (19 October 2026): at most one group is open, opening a group closes
 * the open one, and a click on the open group closes it, so none is open. NavAccordion, around the whole frame
 * (the rail and, since addition 0008zv, the top bar's inbox), holds the open group's id and writes it to the cookie cma-nav-open (an empty value for none; Shell reads it on
 * the server, so a page renders with that group open and never flickers); the retired per-group cookies
 * cma-nav-<id> are expired on the first toggle. A closed group that holds the current page is highlighted, so the
 * person still sees where they are. The pages keep their own digit keys whether a group is open or closed. A
 * group's letter (Configuration's C) is a click on its button and focuses the first page once it opens. In the
 * folded rail (16 October 2026) the button shows its icon only, named by title and aria-label; it then unfolds the
 * rail and opens its group (closing the other), and a folded group that holds the current page keeps its white pill.
 *
 * A bare rail page closes the open group (Martin, 5 November 2026; addition 0008zv): Welcome and Messages render through
 * NavBareLink, whose click (a digit key is the same click, hooks/useKeyboardShortcuts) sets the open group to none, and
 * the top bar's inbox (MessageCenter) does the same through useCloseNavGroup(); the cookie then holds no group, so a
 * reload opens none. NavAccordion therefore wraps the whole frame in Shell, the top bar included.
 */
import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { createContext, useCallback, useContext, useEffect, useRef, useState, type ComponentProps, type ReactNode } from "react";
import { currentHrefOf, expiredCookie, HOVER_PREFETCH_MS, mayFullPrefetch, NAV_COOKIE_PREFIX, NAV_OPEN_COOKIE, prefCookie, type NavIcon } from "@/lib/nav";
import { Keycap } from "./primitives";
import { railCollapsed, setRailCollapsed } from "./ShellPrefs";

const OpenGroup = createContext<{ open: string | null; setOpen: (id: string | null) => void }>({ open: null, setOpen: () => {} });

/**
 * The current rail item (night N07, decision D2): the frame renders once for every page of the route group and stays on
 * the screen across navigations, so the item marked current follows the address on the client (lib/nav currentHrefOf)
 * instead of the page that rendered the frame. `hrefs` are the rail items the person sees; `fixed` names the item for a
 * page outside the group that draws the frame itself (Log out: Welcome, as before)
 */
const CurrentHref = createContext<string | null>(null);

export function NavCurrent({ hrefs, fixed, children }: { hrefs: readonly string[]; fixed?: string | null; children: ReactNode }) {
  const pathname = usePathname() ?? "/";
  const current = fixed !== undefined ? fixed : currentHrefOf(pathname, hrefs);
  return <CurrentHref.Provider value={current}>{children}</CurrentHref.Provider>;
}

/** The rail item marked current, from NavCurrent */
export function useCurrentHref(): string | null {
  return useContext(CurrentHref);
}

/** Whether the address is this path or under it (the top bar's inbox on Messages and Send a message, My account) */
export function usePathUnder(path: string): boolean {
  const pathname = usePathname() ?? "/";
  return pathname === path || pathname.startsWith(`${path}/`);
}

/**
 * A full prefetch on intent (decision D5): a pointer or the focus resting on the link for HOVER_PREFETCH_MS starts a
 * prefetch of the whole page with its data (router.prefetch of kind full), so the click finds it there; only for the
 * routes lib/nav mayFullPrefetch allows (the agent class of db/131). Every other link keeps Next's default, the route's
 * loading boundary. Answers the handlers to spread on the link
 */
export function useIntentPrefetch(href: string) {
  const router = useRouter();
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const done = useRef(false);
  useEffect(() => () => { if (timer.current) clearTimeout(timer.current); }, []);
  if (!mayFullPrefetch(href)) return {};
  const start = () => {
    if (done.current || timer.current) return;
    timer.current = setTimeout(() => {
      timer.current = null;
      done.current = true;
      // kind "full": the page with its data, cached as staleTimes.static says (next.config.ts: 30 s, as dynamic)
      router.prefetch(href, { kind: "full", onInvalidate: () => { done.current = false; } } as Parameters<typeof router.prefetch>[1]);
    }, HOVER_PREFETCH_MS);
  };
  const cancel = () => {
    if (timer.current) clearTimeout(timer.current);
    timer.current = null;
  };
  return { onMouseEnter: start, onMouseLeave: cancel, onFocus: start, onBlur: cancel };
}

/**
 * A link of the rail (D2, D5): marked current from the address (aria-current and the current classes), with the full
 * prefetch on intent where the route allows it. `bare`: a bare rail page (Welcome, Messages), whose click closes the
 * open group as NavBareLink does
 */
export function RailLink({ href, bare = false, className, currentClassName, idleClassName, children, ...props }:
  Omit<ComponentProps<typeof Link>, "href" | "className"> & { href: string; bare?: boolean; className: string; currentClassName: string; idleClassName: string }) {
  const current = useCurrentHref() === href;
  const intent = useIntentPrefetch(href);
  const close = useCloseNavGroup();
  return (
    <Link
      {...props}
      {...intent}
      href={href}
      aria-current={current ? "page" : undefined}
      className={`${className} ${current ? currentClassName : idleClassName}`}
      onClick={bare ? () => close() : undefined}
    >
      {children}
    </Link>
  );
}

/** The top bar's link to My account, marked current on that page (D2) */
export function AccountLink(props: Omit<ComponentProps<typeof Link>, "href">) {
  const current = usePathUnder("/account");
  const intent = useIntentPrefetch("/account");
  return <Link {...props} {...intent} href="/account" aria-current={current ? "page" : undefined} />;
}

/** The rail's open group, for the groups inside it; `initial` is the cookie's group as Shell read it */
export function NavAccordion({ initial, children }: { initial: string | null; children: ReactNode }) {
  const [open, setState] = useState<string | null>(initial);
  const retired = useRef(false);
  const setOpen = useCallback((id: string | null) => {
    setState(id);
    document.cookie = prefCookie(NAV_OPEN_COOKIE, id ?? "");
    if (!retired.current) {
      // the per-group cookies of 7 October 2026: ignored since the accordion, expired once
      retired.current = true;
      for (const part of document.cookie.split(";")) {
        const name = part.split("=")[0]?.trim() ?? "";
        if (name.startsWith(NAV_COOKIE_PREFIX) && name !== NAV_OPEN_COOKIE) document.cookie = expiredCookie(name);
      }
    }
  }, []);
  return <OpenGroup.Provider value={{ open, setOpen }}>{children}</OpenGroup.Provider>;
}

/** Closes the rail's open group, for a link to a bare rail page outside the rail (the top bar's inbox) */
export function useCloseNavGroup(): () => void {
  const { setOpen } = useContext(OpenGroup);
  return useCallback(() => setOpen(null), [setOpen]);
}

/**
 * A bare rail page's link (Welcome, Messages): a click, or its digit key, closes the open group before it navigates
 * (addition 0008zv), so the rail shows no group open on the bare page and after a reload
 */
export function NavBareLink({ onClick, ...props }: ComponentProps<typeof Link>) {
  const close = useCloseNavGroup();
  return (
    <Link
      {...props}
      onClick={(e) => {
        close();
        onClick?.(e);
      }}
    />
  );
}

export function NavGroup({
  id,
  label,
  icon,
  hrefs,
  shortcut,
  children,
}: {
  id: string;
  label: string;
  icon: NavIcon;
  /** The group's pages: one of them is the current page when the address is under it (NavCurrent, D2) */
  hrefs: readonly string[];
  /** A letter that opens the group and focuses its first page (an unnumbered group, 0005a) */
  shortcut?: string;
  children: ReactNode;
}) {
  const accordion = useContext(OpenGroup);
  const open = accordion.open === id;
  const currentHref = useCurrentHref();
  const current = currentHref !== null && hrefs.includes(currentHref);
  const list = useRef<HTMLUListElement>(null);

  function toggle() {
    if (railCollapsed()) {
      // Folded: unfold the rail and open this group, closing the other; never close a group from here
      setRailCollapsed(false);
      if (!open) accordion.setOpen(id);
      return;
    }
    accordion.setOpen(open ? null : id);
    // Opened by its letter: the first page gets the focus, so Enter opens it and the arrows move
    if (!open && shortcut) requestAnimationFrame(() => list.current?.querySelector<HTMLAnchorElement>("a")?.focus());
  }
  const name = shortcut ? `${label} (${shortcut.toUpperCase()})` : label;
  return (
    <li>
      <button
        type="button"
        aria-expanded={open}
        aria-controls={`nav-group-${id}`}
        data-shortcut={shortcut}
        aria-keyshortcuts={shortcut ? shortcut.toUpperCase() : undefined}
        data-current={current}
        data-nav-group={id}
        title={name}
        aria-label={name}
        onClick={toggle}
        className={[
          "flex h-10 w-full items-center gap-3 rounded-button px-3 text-body font-semibold text-p4a-heading",
          !open && current ? "bg-white" : "hover:bg-white/60",
        ].join(" ")}
      >
        <NavIconMark name={icon} />
        <span data-rail-text className="min-w-0 flex-1 truncate text-left">{label}</span>
        {/* The letter works open or closed; its keycap shows only while the group is open (Martin, 9 October 2026) */}
        {shortcut && open ? <Keycap data-rail-text>{shortcut.toUpperCase()}</Keycap> : null}
        <svg
          data-rail-text
          aria-hidden="true"
          viewBox="0 0 16 16"
          className={`h-4 w-4 shrink-0 transition-transform ${open ? "rotate-180" : ""}`}
          fill="none"
          stroke="currentColor"
          strokeWidth="1.75"
          strokeLinecap="round"
          strokeLinejoin="round"
        >
          <path d="M4 6l4 4 4-4" />
        </svg>
      </button>
      <ul ref={list} id={`nav-group-${id}`} data-rail-pages className={open ? "mt-1 flex flex-col gap-1 pl-3" : "hidden"}>
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
          className="h-5 w-5 shrink-0"
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
    case "inbox":
      return (
        <svg
          aria-hidden="true"
          viewBox="0 0 20 20"
          className="h-5 w-5 shrink-0"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.75"
          strokeLinecap="round"
          strokeLinejoin="round"
        >
          <path d="M3 11.5V15a1.5 1.5 0 0 0 1.5 1.5h11A1.5 1.5 0 0 0 17 15v-3.5" />
          <path d="M3 11.5 5.3 4.6A1 1 0 0 1 6.25 4h7.5a1 1 0 0 1 .95.6L17 11.5" />
          <path d="M3 11.5h4l1 2h4l1-2h4" />
        </svg>
      );
    case "live":
      return (
        <svg
          aria-hidden="true"
          viewBox="0 0 20 20"
          className="h-5 w-5 shrink-0"
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
          className="h-5 w-5 shrink-0"
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
          className="h-5 w-5 shrink-0"
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
    case "gear":
      return (
        <svg
          aria-hidden="true"
          viewBox="0 0 20 20"
          className="h-5 w-5 shrink-0"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.75"
          strokeLinecap="round"
          strokeLinejoin="round"
        >
          <path d="M8.41 4.73L8.61 2.73L11.39 2.73L11.59 4.73A5.5 5.5 0 0 1 13.77 5.99L13.77 5.99L15.60 5.16L16.99 7.57L15.35 8.74A5.5 5.5 0 0 1 15.35 11.26L15.35 11.26L16.99 12.43L15.60 14.84L13.77 14.01A5.5 5.5 0 0 1 11.59 15.27L11.59 15.27L11.39 17.27L8.61 17.27L8.41 15.27A5.5 5.5 0 0 1 6.23 14.01L6.23 14.01L4.40 14.84L3.01 12.43L4.65 11.26A5.5 5.5 0 0 1 4.65 8.74L4.65 8.74L3.01 7.57L4.40 5.16L6.23 5.99A5.5 5.5 0 0 1 8.41 4.73Z" />
          <circle cx="10" cy="10" r="2.25" />
        </svg>
      );
    case "flag":
      // Campaigns (addition 0008v): a flag on its pole
      return (
        <svg
          aria-hidden="true"
          viewBox="0 0 20 20"
          className="h-5 w-5 shrink-0"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.75"
          strokeLinecap="round"
          strokeLinejoin="round"
        >
          <path d="M4.5 17.5v-14" />
          <path d="M4.5 3.5h9.5l-2 3.25 2 3.25h-9.5" />
        </svg>
      );
    case "trend":
      // Sales (addition 0008zv): a line rising to an arrow
      return (
        <svg
          aria-hidden="true"
          viewBox="0 0 20 20"
          className="h-5 w-5 shrink-0"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.75"
          strokeLinecap="round"
          strokeLinejoin="round"
        >
          <path d="M3.5 14.5l4.5-4.5 3 3 5.5-6" />
          <path d="M12.5 7h4v4" />
        </svg>
      );
    case "box":
      // Assets (addition 0008zw): a box, the devices the asset register holds
      return (
        <svg
          aria-hidden="true"
          viewBox="0 0 20 20"
          className="h-5 w-5 shrink-0"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.75"
          strokeLinecap="round"
          strokeLinejoin="round"
        >
          <path d="M10 2.75l6.5 3.5v7.5L10 17.25l-6.5-3.5v-7.5z" />
          <path d="M3.5 6.25L10 9.75l6.5-3.5" />
          <path d="M10 9.75v7.5" />
        </svg>
      );
    case "person":
      // Customers (addition 0008zv): one person, apart from Team's two
      return (
        <svg
          aria-hidden="true"
          viewBox="0 0 20 20"
          className="h-5 w-5 shrink-0"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.75"
          strokeLinecap="round"
          strokeLinejoin="round"
        >
          <circle cx="10" cy="7" r="3" />
          <path d="M4.5 16.5a5.5 5.5 0 0 1 11 0" />
        </svg>
      );
    case "chart":
      return (
        <svg
          aria-hidden="true"
          viewBox="0 0 20 20"
          className="h-5 w-5 shrink-0"
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
