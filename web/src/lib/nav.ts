/**
 * The left navigation as data: Welcome as a page of its own above the groups, then groups of
 * pages, each page with the permission it needs (null: everyone with a role). Shell renders it;
 * pages use firstPage() to send someone without a clock to a page they may see.
 * Screens check a permission, never a role key; the database checks again on every call.
 * No runtime imports beyond types, so a client module may import the cookie prefix from here.
 */
import type { Principal } from "@/lib/auth/identity";
import type { Copy } from "@/lib/copy";

/**
 * Cookie of the rail's open group (19 October 2026): the open group's id, or empty while none is open. At most one
 * group is open (an accordion). It replaces the per-group cookies `cma-nav-<id>` ("open" or "closed", 7 October
 * 2026), which are ignored and expired on the first toggle
 */
export const NAV_OPEN_COOKIE = "cma-nav-open";
/** The name prefix of the retired per-group cookies, so the first toggle can expire them */
export const NAV_COOKIE_PREFIX = "cma-nav-";
/** Cookie of the left rail's fold (16 October 2026): "expanded" (the default) or "collapsed" */
export const RAIL_COOKIE = "cma-rail";
/** Cookie of the keyboard hints (16 October 2026, backlog CMA-004): "shown" (the default) or "hidden" */
export const HINTS_COOKIE = "cma-hints";

/** A browser preference written as the nav groups write theirs: path /, one year, no personal data */
export function prefCookie(name: string, value: string): string {
  return `${name}=${value}; path=/; max-age=31536000; samesite=lax; secure`;
}

/** The same cookie expired at once (max-age=0), for a retired preference */
export function expiredCookie(name: string): string {
  return `${name}=; path=/; max-age=0; samesite=lax; secure`;
}

/** The open group of the rail from the cookie's value: a group the person sees, else none */
export function openGroupOf(value: string | undefined, groupIds: readonly string[]): string | null {
  return value && groupIds.includes(value) ? value : null;
}

export type NavIcon = "home" | "inbox" | "live" | "people" | "clock" | "chart" | "flag" | "gear";
export type ShellPage =
  | "welcome"
  /** Messages (migration 0008): the inbox for everyone and the sender's page, both under the rail's Messages item */
  | "messages" | "messages-send"
  | "live-board" | "people" | "roster" | "my-day" | "my-hours" | "my-schedule" | "team-hours" | "dashboard"
  /** Intake reports (B11, migration 0007d), Inbound (addition 0008i), Calls and Calls per agent (addition 0008j), Forms (addition 0008p) */
  | "speed-to-lead" | "intake" | "inbound" | "calls" | "calls-per-agent" | "forms" | "data-quality"
  /** Email and Email per agent (addition 0008t, brief N19-A part 1) */
  | "email" | "email-per-agent"
  /** First orders and Orders per person (addition 0008u, brief N19-A part 2) */
  | "first-orders" | "orders-per-person"
  /** Attempts per deal and Attempts per agent (addition 0008y, 19 October 2026) */
  | "attempts" | "attempts-per-agent"
  /** Campaign monitoring (addition 0008v, brief N19-A part 3): the journeys, each with its own page under the rail's item */
  | "campaigns"
  /** Follow-up (addition 0008o, 16 October 2026): the report, and the person's own page Waiting for you (no rail item) */
  | "follow-up" | "my-follow-up"
  | "config-statuses" | "config-teams" | "config-absences" | "config-exports" | "config-app-links"
  /** Sources, Markets and Alert rules (addition 0008e, night of 13 October 2026) */
  | "config-sources" | "config-markets" | "config-alert-rules"
  /** System health (addition 0008r, the IT audit of 17 October 2026) */
  | "config-health"
  /** My account (0005b): opened from the name in the top bar, never a rail item */
  | "account";
export type NavHref =
  | "/" | "/messages" | "/live/board" | "/team/people" | "/roster/planner" | "/day" | "/hours" | "/schedule" | "/team/hours" | "/reports/dashboard"
  | "/reports/speed-to-lead" | "/reports/attempts" | "/reports/attempts-per-agent" | "/reports/follow-up" | "/reports/intake" | "/reports/inbound" | "/reports/calls" | "/reports/calls-per-agent" | "/reports/forms"
  | "/reports/email" | "/reports/email-per-agent" | "/reports/first-orders" | "/reports/orders-per-person" | "/reports/data-quality" | "/campaigns"
  | "/configuration/statuses" | "/configuration/teams" | "/configuration/absences" | "/configuration/exports" | "/configuration/app-links"
  | "/configuration/sources" | "/configuration/markets" | "/configuration/alert-rules" | "/configuration/health";

export interface NavItem {
  page: ShellPage;
  href: NavHref;
  label: string;
  /**
   * The permission that shows the page; null means every person with a role. A list means any
   * one of them (the Team screen: users.manage_agents or users.manage_all, migration 0004).
   */
  permission: string | readonly string[] | null;
  /**
   * A per-person report page (addition 0008t): shown only while the tenant's reports.per_person holds this key
   * (Principal.perPerson), besides the permission; absent otherwise, with its route
   */
  perPerson?: "email" | "orders" | "attempts";
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
  /**
   * A group whose pages carry no digit key (Configuration, 0005a: the admin's rail already has nine
   * numbered pages). It opens from the rail and with its own letter, which a page's own control of
   * the same letter wins over (hooks/useKeyboardShortcuts).
   */
  shortcut?: string;
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
      // Messages (migration 0008, 11 October 2026): a bare page right after Welcome, so every person's
      // inbox is key 2 and the keys of the groups below move by one for everyone alike. Every active
      // person can receive a message; sending is a button on the page for messages.send.
      kind: "page",
      icon: "inbox",
      item: { page: "messages", href: "/messages", label: copy.nav.messages, permission: null },
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
        // The order since addition 0008z (Martin, README Decision log, 20 October 2026): the reports a team lead reads first,
        // then the follow-up and the attempts behind them, then intake, inbound and orders, Data quality last. Each report
        // keeps its own permissions; the digit keys follow the visible order, so they moved for everyone who sees Reports.
        // The intake reports (B11, 12 October 2026) carry their function's permissions (migration 0007d), the same lists
        // as REPORT_PERMISSIONS and DATA_QUALITY_PERMISSIONS in lib/reports (written out here, because this module has no
        // runtime imports)
        { page: "speed-to-lead", href: "/reports/speed-to-lead", label: copy.nav.speedToLead, permission: ["reports.view", "performance.team"] },
        // Calls (addition 0008j, brief B16): the calls, conversations, talk time and tags; Calls per agent the same per
        // person, for performance.team only (README Decision log, 14 October 2026)
        { page: "calls", href: "/reports/calls", label: copy.nav.calls, permission: ["reports.view", "performance.team"] },
        { page: "calls-per-agent", href: "/reports/calls-per-agent", label: copy.nav.callsPerAgent, permission: "performance.team" },
        // Email (addition 0008t, brief N19-A part 1): received per inbox and mailbox, sent, first replies, as Calls; Email per
        // agent the same per person, for performance.team while the tenant's reports.per_person holds email (Yordi agreed,
        // README Decision log, 18 October 2026)
        { page: "email", href: "/reports/email", label: copy.nav.email, permission: ["reports.view", "performance.team"] },
        { page: "email-per-agent", href: "/reports/email-per-agent", label: copy.nav.emailPerAgent, permission: "performance.team", perPerson: "email" },
        // Follow-up (addition 0008o, 16 October 2026): what is waiting right now, for the permissions of cma.open_leads
        // (reports.view, performance.team or monitoring.live)
        { page: "follow-up", href: "/reports/follow-up", label: copy.nav.followUp, permission: ["reports.view", "performance.team", "monitoring.live"] },
        // Attempts per deal (addition 0008y; for sales since 0008z): the attempts on the sales deals until they are won,
        // lost or ordered another way; Attempts per agent the same per deal owner, for performance.team while the tenant's
        // reports.per_person holds attempts (off for Pulse4all until Yordi agrees, README Open decisions)
        { page: "attempts", href: "/reports/attempts", label: copy.nav.attempts, permission: ["reports.view", "performance.team"] },
        { page: "attempts-per-agent", href: "/reports/attempts-per-agent", label: copy.nav.attemptsPerAgent, permission: "performance.team", perPerson: "attempts" },
        // Forms (addition 0008p, brief B17d): every polled form's submissions per form and market, as Calls
        { page: "forms", href: "/reports/forms", label: copy.nav.forms, permission: ["reports.view", "performance.team"] },
        { page: "intake", href: "/reports/intake", label: copy.nav.intake, permission: ["reports.view", "performance.team"] },
        // Inbound (addition 0008i, brief B15): the service level and the missed calls per reason, as Intake
        { page: "inbound", href: "/reports/inbound", label: copy.nav.inbound, permission: ["reports.view", "performance.team"] },
        // First orders (addition 0008u, brief N19-A part 2): self-service or call center, as Email; Orders per person the
        // credited first orders per person, for performance.team while the tenant's reports.per_person holds orders
        // (off for Pulse4all until Yordi confirms it, README Open decisions)
        { page: "first-orders", href: "/reports/first-orders", label: copy.nav.firstOrders, permission: ["reports.view", "performance.team"] },
        { page: "orders-per-person", href: "/reports/orders-per-person", label: copy.nav.ordersPerPerson, permission: "performance.team", perPerson: "orders" },
        { page: "data-quality", href: "/reports/data-quality", label: copy.nav.dataQuality, permission: ["reports.view", "tenant.configure"] },
      ],
    },
    {
      // Campaigns (addition 0008v, brief N19-A part 3): Campaign monitoring, the journeys as placeholders for the
      // compliance and campaign monitors, for the report permissions; after Reports, so no key above it moves
      kind: "group",
      id: "campaigns",
      label: copy.nav.campaigns,
      icon: "flag",
      items: [
        { page: "campaigns", href: "/campaigns", label: copy.nav.campaignMonitoring, permission: ["reports.view", "performance.team"] },
      ],
    },
    {
      // Configuration (0005a): tenant.configure only (the admin); agents, supervisors and managers never
      // see the group. No digit keys: the group opens with C (page-first) and Enter opens a page.
      kind: "group",
      id: "configuration",
      label: copy.nav.configuration,
      icon: "gear",
      shortcut: "c",
      items: [
        // The order since addition 0008z (Martin, README Decision log, 20 October 2026): the team and its skills first, then
        // statuses, absences and coverage, the markets and sources the reports read, app links, exports, alert rules and
        // System health
        { page: "config-teams", href: "/configuration/teams", label: copy.nav.configTeams, permission: "tenant.configure" },
        { page: "config-statuses", href: "/configuration/statuses", label: copy.nav.configStatuses, permission: "tenant.configure" },
        { page: "config-absences", href: "/configuration/absences", label: copy.nav.configAbsences, permission: "tenant.configure" },
        // The intake configuration (addition 0008e): what Martin set by SQL on 12 October 2026, now on screens
        { page: "config-markets", href: "/configuration/markets", label: copy.nav.configMarkets, permission: "tenant.configure" },
        { page: "config-sources", href: "/configuration/sources", label: copy.nav.configSources, permission: "tenant.configure" },
        { page: "config-app-links", href: "/configuration/app-links", label: copy.nav.configAppLinks, permission: "tenant.configure" },
        { page: "config-exports", href: "/configuration/exports", label: copy.nav.configExports, permission: "tenant.configure" },
        { page: "config-alert-rules", href: "/configuration/alert-rules", label: copy.nav.configAlertRules, permission: "tenant.configure" },
        // System health (addition 0008r): sources, jobs, the heartbeat and the outbox from what the jobs leave behind; the audit documents
        { page: "config-health", href: "/configuration/health", label: copy.nav.configHealth, permission: "tenant.configure" },
      ],
    },
  ];
}

/** key: the digit that opens the page, or null in an unnumbered group and from the tenth page on */
export type VisibleItem = NavItem & { key: string | null };
export type VisibleEntry =
  | { kind: "page"; icon: NavIcon; item: VisibleItem }
  | { kind: "group"; id: string; label: string; icon: NavIcon; items: VisibleItem[]; shortcut?: string };

/** True when the person holds the permission, or any of a list of them */
export function holdsAny(me: Pick<Principal, "permissions">, permission: string | readonly string[] | null): boolean {
  if (permission === null) return true;
  if (typeof permission === "string") return me.permissions.includes(permission);
  return permission.some((p) => me.permissions.includes(p));
}

function mayOpen(me: Principal, item: NavItem): boolean {
  return holdsAny(me, item.permission) && (item.perPerson === undefined || me.perPerson.includes(item.perPerson));
}

/** A digit key is one keypress: only the first nine numbered pages get one (the IT audit of 17 October 2026) */
export const MAX_DIGIT_KEYS = 9;

/**
 * The pages and groups this person may see. Keys follow the visible order across the rail, so
 * every person's pages are numbered 1, 2, 3 without gaps, whether a group is open or closed. The
 * tenth page and every page after it get no key (null: no keycap, no shortcut), because the hook
 * reads one keypress and "10" can never be pressed.
 */
export function visibleNav(me: Principal, copy: Copy): VisibleEntry[] {
  let n = 0;
  const out: VisibleEntry[] = [];
  const nextKey = (): string | null => (++n <= MAX_DIGIT_KEYS ? String(n) : null);
  for (const entry of navEntries(copy)) {
    if (entry.kind === "page") {
      if (mayOpen(me, entry.item)) out.push({ kind: "page", icon: entry.icon, item: { ...entry.item, key: nextKey() } });
      continue;
    }
    const items = entry.items.filter((i) => mayOpen(me, i)).map((i) => ({ ...i, key: entry.shortcut ? null : nextKey() }));
    if (items.length > 0) out.push({ kind: "group", id: entry.id, label: entry.label, icon: entry.icon, items, shortcut: entry.shortcut });
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

/** One crumb of the trail above the content; the last one is where the person is and has no link */
export interface Crumb {
  label: string;
  href?: string;
}

/**
 * The breadcrumbs of a page (16 October 2026): Welcome › the group's label (a link to the group's first
 * page this person may see; no link when they may see none) › the page's label, from the navigation
 * model; a bare page is Welcome › the page. My account and Send a message are no rail items and get
 * their own trail; Welcome shows none. A page's own trail (the connection's name on Sources) is appended,
 * and the page's crumb becomes a link; a journey's page (0008v) is Welcome › Campaigns › the journey. The last
 * crumb is never a link.
 */
export function breadcrumbs(me: Principal, copy: Copy, active: ShellPage, trail: Crumb[] = []): Crumb[] {
  if (active === "welcome") return [];
  let own: Crumb[] = [];
  if (active === "account") own = [{ label: copy.account.title, href: "/account" }];
  else if (active === "my-follow-up") own = [{ label: copy.followUp.myTitle, href: "/me/follow-up" }];
  else if (active === "messages-send") own = [{ label: copy.nav.messages, href: "/messages" }, { label: copy.messages.composeTitle, href: "/messages/send" }];
  // A journey's page (addition 0008v): Campaigns › the journey's name, the group's one page being the list of journeys
  else if (active === "campaigns" && trail.length > 0) own = [{ label: copy.nav.campaigns, href: "/campaigns" }];
  else {
    for (const entry of navEntries(copy)) {
      if (entry.kind === "page") {
        if (entry.item.page === active) own = [{ label: entry.item.label, href: entry.item.href }];
        continue;
      }
      const item = entry.items.find((i) => i.page === active);
      if (!item) continue;
      const first = entry.items.find((i) => mayOpen(me, i));
      own = [{ label: entry.label, href: first?.href }, { label: item.label, href: item.href }];
    }
  }
  const all: Crumb[] = [{ label: copy.nav.welcome, href: "/" }, ...own, ...trail];
  return all.map((c, i) => (i === all.length - 1 ? { label: c.label } : c));
}
