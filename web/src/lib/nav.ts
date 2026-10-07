/**
 * The left navigation as data: groups of pages, each page with the permission it needs. Shell
 * renders it; pages use firstPage() to send someone without a clock to a page they may see.
 * Screens check a permission, never a role key; the database checks again on every call.
 * No runtime imports beyond types, so a client module may import the cookie prefix from here.
 */
import type { Principal } from "@/lib/auth/identity";
import type { Copy } from "@/lib/copy";

/** Cookie name prefix for the left navigation's groups; the value is "open" or "closed" */
export const NAV_COOKIE_PREFIX = "cma-nav-";

export type NavIcon = "clock" | "chart";
export type ShellPage = "my-day" | "my-hours" | "team-hours" | "dashboard";
export type NavHref = "/" | "/hours" | "/team/hours" | "/reports/dashboard";

export interface NavItem {
  page: ShellPage;
  href: NavHref;
  label: string;
  permission: string;
}

export interface NavSection {
  id: string;
  label: string;
  icon: NavIcon;
  items: NavItem[];
}

/** Every group and page; a new module adds its group here */
export function navSections(copy: Copy): NavSection[] {
  return [
    {
      id: "time",
      label: copy.nav.time,
      icon: "clock",
      items: [
        { page: "my-day", href: "/", label: copy.nav.myDay, permission: "workday.own" },
        { page: "my-hours", href: "/hours", label: copy.nav.myHours, permission: "workday.own" },
        { page: "team-hours", href: "/team/hours", label: copy.nav.teamHours, permission: "workday.team" },
      ],
    },
    {
      id: "reports",
      label: copy.nav.reports,
      icon: "chart",
      items: [
        { page: "dashboard", href: "/reports/dashboard", label: copy.nav.dashboard, permission: "performance.team" },
      ],
    },
  ];
}

export type VisibleSection = Omit<NavSection, "items"> & { items: (NavItem & { key: string })[] };

/**
 * The groups and pages this person may see. Keys follow the visible order across all groups, so
 * every person's pages are numbered 1, 2, 3 without gaps, whether a group is open or closed.
 */
export function visibleNav(me: Principal, copy: Copy): VisibleSection[] {
  let n = 0;
  return navSections(copy)
    .map((section) => ({
      ...section,
      items: section.items
        .filter((i) => me.permissions.includes(i.permission))
        .map((i) => ({ ...i, key: String(++n) })),
    }))
    .filter((section) => section.items.length > 0);
}

/** The first page this person may see, or null when there is none */
export function firstPage(me: Principal, copy: Copy): NavHref | null {
  return visibleNav(me, copy)[0]?.items[0]?.href ?? null;
}
