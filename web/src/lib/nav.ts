/**
 * The left navigation as data: Welcome as a page of its own above the groups, then groups of
 * pages, each page with the permission it needs (null: everyone with a role). Shell renders it;
 * pages use firstPage() to send someone without a clock to a page they may see.
 * Screens check a permission, never a role key; the database checks again on every call.
 * No runtime imports beyond types, so a client module may import the cookie prefix from here.
 */
import type { Principal } from "@/lib/auth/identity";
import type { Copy } from "@/lib/copy";

/** Cookie name prefix for the left navigation's groups; the value is "open" or "closed" */
export const NAV_COOKIE_PREFIX = "cma-nav-";

export type NavIcon = "home" | "live" | "people" | "clock" | "chart";
export type ShellPage = "welcome" | "live-board" | "people" | "roster" | "my-day" | "my-hours" | "my-schedule" | "team-hours" | "dashboard";
export type NavHref = "/" | "/live/board" | "/team/people" | "/roster/planner" | "/day" | "/hours" | "/schedule" | "/team/hours" | "/reports/dashboard";

export interface NavItem {
  page: ShellPage;
  href: NavHref;
  label: string;
  /**
   * The permission that shows the page; null means every person with a role. A list means any
   * one of them (the Team screen: users.manage_agents or users.manage_all, migration 0004).
   */
  permission: string | readonly string[] | null;
}

/** A page that stands on its own in the rail, with its icon */
export interface NavPage {
  kind: "page";
  item: NavItem;
  icon: NavIcon;
}

/** A group of pages that opens and closes */
export interface NavGroupEntry {
  kind: "group";
  id: string;
  label: string;
  icon: NavIcon;
  items: NavItem[];
}

export type NavEntry = NavPage | NavGroupEntry;

/** Every page and group in rail order; a new module adds its group here */
export function navEntries(copy: Copy): NavEntry[] {
  return [
    {
      kind: "page",
      icon: "home",
      item: { page: "welcome", href: "/", label: copy.nav.welcome, permission: null },
    },
    {
      // Live before Time (Martin, 7 October 2026): the screen a supervisor keeps open. Agents do not
      // hold monitoring.live, so their keys do not move.
      kind: "group",
      id: "live",
      label: copy.nav.live,
      icon: "live",
      items: [
        { page: "live-board", href: "/live/board", label: copy.nav.liveBoard, permission: "monitoring.live" },
      ],
    },
    {
      // Team (night build, 7 October 2026): the people and, with 0005, the roster. After Live and before
      // Time, so an agent's keys (Welcome, My day, My hours) do not move: agents hold none of these.
      kind: "group",
      id: "team",
      label: copy.nav.team,
      icon: "people",
      items: [
        { page: "people", href: "/team/people", label: copy.nav.people, permission: ["users.manage_agents", "users.manage_all"] },
        { page: "roster", href: "/roster/planner", label: copy.nav.roster, permission: "roster.manage" },
      ],
    },
    {
      kind: "group",
      id: "time",
      label: copy.nav.time,
      icon: "clock",
      items: [
        { page: "my-day", href: "/day", label: copy.nav.myDay, permission: "workday.own" },
        { page: "my-hours", href: "/hours", label: copy.nav.myHours, permission: "workday.own" },
        { page: "my-schedule", href: "/schedule", label: copy.nav.mySchedule, permission: "roster.view" },
        { page: "team-hours", href: "/team/hours", label: copy.nav.teamHours, permission: "workday.team" },
      ],
    },
    {
      kind: "group",
      id: "reports",
      label: copy.nav.reports,
      icon: "chart",
      items: [
        { page: "dashboard", href: "/reports/dashboard", label: copy.nav.dashboard, permission: "performance.team" },
      ],
    },
  ];
}

export type VisibleItem = NavItem & { key: string };
export type VisibleEntry =
  | { kind: "page"; icon: NavIcon; item: VisibleItem }
  | { kind: "group"; id: string; label: string; icon: NavIcon; items: VisibleItem[] };

/** True when the person holds the permission, or any of a list of them */
export function holdsAny(me: Pick<Principal, "permissions">, permission: string | readonly string[] | null): boolean {
  if (permission === null) return true;
  if (typeof permission === "string") return me.permissions.includes(permission);
  return permission.some((p) => me.permissions.includes(p));
}

function mayOpen(me: Principal, item: NavItem): boolean {
  return holdsAny(me, item.permission);
}

/**
 * The pages and groups this person may see. Keys follow the visible order across the rail, so
 * every person's pages are numbered 1, 2, 3 without gaps, whether a group is open or closed.
 */
export function visibleNav(me: Principal, copy: Copy): VisibleEntry[] {
  let n = 0;
  const out: VisibleEntry[] = [];
  for (const entry of navEntries(copy)) {
    if (entry.kind === "page") {
      if (mayOpen(me, entry.item)) out.push({ kind: "page", icon: entry.icon, item: { ...entry.item, key: String(++n) } });
      continue;
    }
    const items = entry.items.filter((i) => mayOpen(me, i)).map((i) => ({ ...i, key: String(++n) }));
    if (items.length > 0) out.push({ kind: "group", id: entry.id, label: entry.label, icon: entry.icon, items });
  }
  return out;
}

/** Every visible page in order, for numbering checks and the first page */
export function visiblePages(me: Principal, copy: Copy): VisibleItem[] {
  return visibleNav(me, copy).flatMap((e) => (e.kind === "page" ? [e.item] : e.items));
}

/** The first page this person may see, or null when there is none */
export function firstPage(me: Principal, copy: Copy): NavHref | null {
  return visiblePages(me, copy)[0]?.href ?? null;
}
