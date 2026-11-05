/**
 * The left navigation as data: Welcome as a page of its own above the groups, then groups of
 * pages, each page with the permission it needs (null: everyone with a role). Shell renders it;
 * pages use firstPage() to send someone without a clock to a page they may see.
 * Screens check a permission, never a role key; the database checks again on every call.
 * No runtime imports beyond types, so a client module may import the cookie prefix from here.
 * The Live group's pages come from the tenant's contact centers (addition 0008zv), which the caller passes in
 * (Principal.contactCenters, read with the identity), one board per organisation, labelled with its name.
 */
import type { ContactCenter, Principal } from "@/lib/auth/identity";
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

export type NavIcon = "home" | "inbox" | "live" | "people" | "clock" | "chart" | "trend" | "person" | "box" | "flag" | "gear";
export type ShellPage =
  | "welcome"
  /** Messages (migration 0008): the inbox for everyone and the sender's page, both under the rail's Messages item */
  | "messages" | "messages-send"
  /** A contact center's Live board (addition 0008zv): one page per organisation, told apart by its href */
  | "live-board" | "people" | "roster" | "my-day" | "my-hours" | "my-schedule" | "team-hours" | "dashboard"
  /** Intake reports (B11, migration 0007d), Inbound (addition 0008i), Calls and Calls per agent (addition 0008j), Forms (addition 0008p) */
  | "speed-to-lead" | "intake" | "inbound" | "calls" | "calls-per-agent" | "forms" | "data-quality"
  /** Email and Email per agent (addition 0008t, brief N19-A part 1) */
  | "email" | "email-per-agent"
  /** First orders and Orders per person (addition 0008u, brief N19-A part 2) */
  | "first-orders" | "orders-per-person"
  /** Lead cohorts (addition 0008zm): the lead deals by the week or month of their creation, followed at fixed ages */
  | "lead-cohorts"
  /** Attempts per deal and Attempts per agent (addition 0008y, 19 October 2026) */
  | "attempts" | "attempts-per-agent"
  /** Funnel and Cancellations (addition 0008zb): the deals through their stages with the lost reasons, and the cancellation requests */
  | "funnel" | "cancellations"
  /** Reviews (addition 0008ze, brief B18): the review platform's reviews per market, channel and week */
  | "reviews"
  /** Maintenance (addition 0008zi): what comes due on the asset register's devices, per month, market and model */
  | "maintenance"
  /** Installed base (addition 0008zw): Flash's Installed base overview as a page of the Assets group, the same read and files */
  | "installed-base"
  /** Flash (addition 0008zn, brief B21): ten overviews and Data quality, one click each, now or as of a snapshot's date */
  | "flash"
  /** Campaign monitoring (addition 0008v, brief N19-A part 3): the journeys, each with its own page under the rail's item */
  | "campaigns"
  /** Follow-up (addition 0008o, 16 October 2026): the report, and the person's own page Waiting for you (no rail item) */
  | "follow-up" | "my-follow-up"
  | "config-statuses" | "config-teams" | "config-absences" | "config-exports" | "config-app-links"
  /** Sources, Markets and Alert rules (addition 0008e, night of 13 October 2026) */
  | "config-sources" | "config-markets" | "config-alert-rules"
  /** System health (addition 0008r, the IT audit of 17 October 2026) */
  | "config-health"
  /** Metrics (the metric catalog): every figure the Workspace shows, as the code computes it */
  | "config-metrics"
  /** My account (0005b): opened from the name in the top bar, never a rail item */
  | "account";
export type NavHref =
  | "/" | "/messages" | `/live/${string}` | "/team/people" | "/roster/planner" | "/day" | "/hours" | "/schedule" | "/team/hours" | "/reports/dashboard"
  | "/reports/speed-to-lead" | "/reports/attempts" | "/reports/attempts-per-agent" | "/reports/funnel" | "/reports/cancellations" | "/reports/follow-up" | "/reports/intake" | "/reports/inbound" | "/reports/calls" | "/reports/calls-per-agent" | "/reports/forms"
  | "/reports/email" | "/reports/email-per-agent" | "/reports/first-orders" | "/reports/orders-per-person" | "/reports/lead-cohorts" | "/reports/reviews" | "/reports/maintenance"
  | "/reports/installed-base" | "/reports/data-quality" | "/reports/flash" | "/campaigns"
  | "/configuration/statuses" | "/configuration/teams" | "/configuration/absences" | "/configuration/exports" | "/configuration/app-links"
  | "/configuration/sources" | "/configuration/markets" | "/configuration/alert-rules" | "/configuration/metrics" | "/configuration/health";

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
  perPerson?: "email" | "orders" | "attempts" | "deals";
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

/**
 * Every page and group in rail order; a new module adds its group here. contactCenters: the tenant's contact-center
 * organisations (Principal.contactCenters), each one a Live board; none, and the Live group has no page, so it is absent
 */
export function navEntries(copy: Copy, contactCenters: readonly ContactCenter[]): NavEntry[] {
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
      // hold monitoring.live, so their keys do not move. Since addition 0008zv (Martin, 5 November 2026) one board per
      // contact-center organisation, labelled with its name, in the order the identity read gives (by name); a tenant
      // without one has no Live group. Each board takes a digit key, so a second contact center moves the keys after it
      kind: "group",
      id: "live",
      label: copy.nav.live,
      icon: "live",
      items: contactCenters.map((c): NavItem => ({ page: "live-board", href: `/live/${c.key}`, label: c.name, permission: "monitoring.live" })),
    },
    {
      // Time: a person's own day, hours and schedule, and the team's hours; after Live since addition 0008zw (Team follows it)
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
      // Team (night build, 7 October 2026): the people and, with 0005, the roster. After Time since addition 0008zw
      // (Martin, 5 November 2026; after Live and before Time before), so the keys of Time's pages come first for a
      // manager and an admin; an agent's keys (Welcome, Messages, My day, My hours) do not move: agents hold none of these.
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
      // Reports, Sales and Customers (Martin, 5 November 2026; addition 0008zv): the report pages in three groups, replacing
      // the one Reports group in the order of 20 October 2026 (addition 0008z). Reports holds the overviews and the
      // channels (calls, inbound, email, intake, forms) with Data quality last; Sales the leads and deals through to the
      // first order, Funnel before Attempts per deal; Customers what happens after the order. Every page keeps its href,
      // its permission and its per-person key; a group none of whose pages a person may see is absent. The digit keys
      // follow the visible order, so they move for everyone who sees these groups. The permissions are the lists of
      // REPORT_PERMISSIONS and DATA_QUALITY_PERMISSIONS in lib/reports (written out here, because this module has no runtime
      // imports): reports.view or performance.team, a per-person page performance.team with the tenant's reports.per_person
      kind: "group",
      id: "reports",
      label: copy.nav.reports,
      icon: "chart",
      items: [
        // Flash (addition 0008zn, brief B21, 1 November 2026): first in Reports, the ten overviews and Data quality in one
        // click each for an auditor, the CFO or the COO; reports.view or performance.team, as every report's team figures
        { page: "flash", href: "/reports/flash", label: copy.nav.flash, permission: ["reports.view", "performance.team"] },
        { page: "dashboard", href: "/reports/dashboard", label: copy.nav.dashboard, permission: "performance.team" },
        // Calls (addition 0008j, brief B16): the calls, conversations, talk time and tags; Calls per agent the same per
        // person, for performance.team only (README Decision log, 14 October 2026)
        { page: "calls", href: "/reports/calls", label: copy.nav.calls, permission: ["reports.view", "performance.team"] },
        { page: "calls-per-agent", href: "/reports/calls-per-agent", label: copy.nav.callsPerAgent, permission: "performance.team" },
        // Inbound (addition 0008i, brief B15): the service level and the missed calls per reason, after the calls
        { page: "inbound", href: "/reports/inbound", label: copy.nav.inbound, permission: ["reports.view", "performance.team"] },
        // Email (addition 0008t, brief N19-A part 1): received per inbox and mailbox, sent, first replies, as Calls; Email per
        // agent the same per person, for performance.team while the tenant's reports.per_person holds email (Yordi agreed,
        // README Decision log, 18 October 2026)
        { page: "email", href: "/reports/email", label: copy.nav.email, permission: ["reports.view", "performance.team"] },
        { page: "email-per-agent", href: "/reports/email-per-agent", label: copy.nav.emailPerAgent, permission: "performance.team", perPerson: "email" },
        // The intake reports (B11, 12 October 2026) carry their function's permissions (migration 0007d); Forms (addition
        // 0008p, brief B17d): every polled form's submissions per form and market, as Calls
        { page: "intake", href: "/reports/intake", label: copy.nav.intake, permission: ["reports.view", "performance.team"] },
        { page: "forms", href: "/reports/forms", label: copy.nav.forms, permission: ["reports.view", "performance.team"] },
        { page: "data-quality", href: "/reports/data-quality", label: copy.nav.dataQuality, permission: ["reports.view", "tenant.configure"] },
      ],
    },
    {
      // Sales (addition 0008zv): the leads and the deals, from the first call to the first order
      kind: "group",
      id: "sales",
      label: copy.nav.sales,
      icon: "trend",
      items: [
        { page: "speed-to-lead", href: "/reports/speed-to-lead", label: copy.nav.speedToLead, permission: ["reports.view", "performance.team"] },
        // Follow-up (addition 0008o, 16 October 2026): what is waiting right now, for the permissions of cma.open_leads
        // (reports.view, performance.team or monitoring.live)
        { page: "follow-up", href: "/reports/follow-up", label: copy.nav.followUp, permission: ["reports.view", "performance.team", "monitoring.live"] },
        // Funnel (addition 0008zb, Kira's KPI 4): the sales deals through their stages with why they are lost (deals per
        // person on the page for performance.team while reports.per_person holds deals); before the attempts behind it
        { page: "funnel", href: "/reports/funnel", label: copy.nav.funnel, permission: ["reports.view", "performance.team"] },
        // Attempts per deal (addition 0008y; for sales since 0008z): the attempts on the sales deals until they are won,
        // lost or ordered another way; Attempts per agent the same per deal owner, for performance.team while the tenant's
        // reports.per_person holds attempts (off for Pulse4all until Yordi agrees, README Open decisions)
        { page: "attempts", href: "/reports/attempts", label: copy.nav.attempts, permission: ["reports.view", "performance.team"] },
        { page: "attempts-per-agent", href: "/reports/attempts-per-agent", label: copy.nav.attemptsPerAgent, permission: "performance.team", perPerson: "attempts" },
        // Lead cohorts (addition 0008zm; KPIs 1 and 12): the lead deals by the week or month of their creation, followed at the
        // ages of cohorts.lead_ages_days; team figures only, for the funnel's permissions
        { page: "lead-cohorts", href: "/reports/lead-cohorts", label: copy.nav.leadCohorts, permission: ["reports.view", "performance.team"] },
        // First orders (addition 0008u, brief N19-A part 2): self-service or call center, as Email; Orders per person the
        // credited first orders per person, for performance.team while the tenant's reports.per_person holds orders
        // (off for Pulse4all until Yordi confirms it, README Open decisions)
        { page: "first-orders", href: "/reports/first-orders", label: copy.nav.firstOrders, permission: ["reports.view", "performance.team"] },
        { page: "orders-per-person", href: "/reports/orders-per-person", label: copy.nav.ordersPerPerson, permission: "performance.team", perPerson: "orders" },
      ],
    },
    {
      // Customers (addition 0008zv): what happens after the order; team figures only, as every report. Since addition
      // 0008zw (Martin, 5 November 2026) Maintenance is Assets'
      kind: "group",
      id: "customers",
      label: copy.nav.customers,
      icon: "person",
      items: [
        // Cancellations (addition 0008zb, Kira's KPI 5): the cancellation requests of the tenant's cancellation kind per
        // market and week
        { page: "cancellations", href: "/reports/cancellations", label: copy.nav.cancellations, permission: ["reports.view", "performance.team"] },
        // Reviews (addition 0008ze, brief B18; KPI 3): the review platform's reviews per market, channel and week with the
        // average rating, the negative reviews and how they link to an order or a contact
        { page: "reviews", href: "/reports/reviews", label: copy.nav.reviews, permission: ["reports.view", "performance.team"] },
      ],
    },
    {
      // Assets (addition 0008zw, Martin, 5 November 2026): the devices the asset register holds, after Customers. Team
      // figures only, for the report permissions, as Flash
      kind: "group",
      id: "assets",
      label: copy.nav.assets,
      icon: "box",
      items: [
        // Installed base: Flash's Installed base overview (cma.flash_overview and its first page of records, the same
        // filters, As of and files) as a page of its own; Flash keeps its own overview
        { page: "installed-base", href: "/reports/installed-base", label: copy.nav.installedBase, permission: ["reports.view", "performance.team"] },
        // Maintenance (addition 0008zi; in Customers from 0008zv to 0008zw): the asset register's devices' due components
        // and end of life per month, market and model, bundled into planned exchanges, with the device list of a cell
        { page: "maintenance", href: "/reports/maintenance", label: copy.nav.maintenance, permission: ["reports.view", "performance.team"] },
      ],
    },
    {
      // Campaigns (addition 0008v, brief N19-A part 3): Campaign monitoring, the journeys as placeholders for the
      // compliance and campaign monitors, for the report permissions; after Customers since addition 0008zv (after
      // Reports before) and after Assets since 0008zw, so no key above it moves
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
        // The metric catalog: every figure the Workspace shows, as the code computes it, rendered from
        // docs/metrics/catalog.json at build time; before System health, so the two reference pages sit together last
        { page: "config-metrics", href: "/configuration/metrics", label: copy.nav.configMetrics, permission: "tenant.configure" },
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

/**
 * The rail's item for the page being shown: its ShellPage, and its href when several items share the page (a contact
 * center's Live board, addition 0008zv); without an href, the first item of the page
 */
export function isCurrent(item: Pick<NavItem, "page" | "href">, active: ShellPage, activeHref?: string): boolean {
  return item.page === active && (activeHref === undefined || item.href === activeHref);
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
  for (const entry of navEntries(copy, me.contactCenters)) {
    if (entry.kind === "page") {
      if (mayOpen(me, entry.item)) out.push({ kind: "page", icon: entry.icon, item: { ...entry.item, key: nextKey() } });
      continue;
    }
    const items = entry.items.filter((i) => mayOpen(me, i)).map((i) => ({ ...i, key: entry.shortcut ? null : nextKey() }));
    if (items.length > 0) out.push({ kind: "group", id: entry.id, label: entry.label, icon: entry.icon, items, shortcut: entry.shortcut });
  }
  return out;
}

/**
 * The hrefs of the bare rail pages a person sees (Welcome, Messages): a link to one, in the rail or in the breadcrumbs,
 * closes the open group (addition 0008zv; the crumbs since Martin's decision of 5 November 2026)
 */
export function bareHrefsOf(nav: readonly VisibleEntry[]): string[] {
  return nav.flatMap((e) => (e.kind === "page" ? [e.item.href] : []));
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
 * crumb is never a link. A contact center's Live board (addition 0008zv) is Welcome › Live › the organisation's name,
 * found by its href (activeHref) among the Live group's boards.
 */
export function breadcrumbs(me: Principal, copy: Copy, active: ShellPage, trail: Crumb[] = [], activeHref?: string): Crumb[] {
  if (active === "welcome") return [];
  let own: Crumb[] = [];
  if (active === "account") own = [{ label: copy.account.title, href: "/account" }];
  else if (active === "my-follow-up") own = [{ label: copy.followUp.myTitle, href: "/me/follow-up" }];
  else if (active === "messages-send") own = [{ label: copy.nav.messages, href: "/messages" }, { label: copy.messages.composeTitle, href: "/messages/send" }];
  // A journey's page (addition 0008v): Campaigns › the journey's name, the group's one page being the list of journeys
  else if (active === "campaigns" && trail.length > 0) own = [{ label: copy.nav.campaigns, href: "/campaigns" }];
  else {
    for (const entry of navEntries(copy, me.contactCenters)) {
      if (entry.kind === "page") {
        if (isCurrent(entry.item, active, activeHref)) own = [{ label: entry.item.label, href: entry.item.href }];
        continue;
      }
      const item = entry.items.find((i) => isCurrent(i, active, activeHref));
      if (!item) continue;
      const first = entry.items.find((i) => mayOpen(me, i));
      own = [{ label: entry.label, href: first?.href }, { label: item.label, href: item.href }];
    }
  }
  const all: Crumb[] = [{ label: copy.nav.welcome, href: "/" }, ...own, ...trail];
  return all.map((c, i) => (i === all.length - 1 ? { label: c.label } : c));
}
