/**
 * The follow-up layer's logic (addition 0008o, night run N16-B, 16 October 2026): the permissions of
 * its reads, the filters of Reports → Follow-up, the summary and the per-person figures as
 * cma.follow_up_summary_of and cma.follow_up_by_owner_of compute them (the mock data layer and a page
 * that reads the lists but may not call the summary function use them), the Welcome page's Needs
 * attention lines, the Live board's tiles, and the rules of the four settings as cma.check_tenant_setting
 * applies them, so a form can explain a refusal before it is sent. Pure and without runtime imports, so
 * verify/follow-up.mjs tests it without a browser or a database. Nothing here knows a vendor, a
 * pipeline, a market or a status key.
 */
import type {
  DueState, FollowUpFilterOptions, FollowUpOwner, FollowUpPage, FollowUpSummary, OpenLead, OpenTask, OpenTicket, SlaState,
} from "./data/types";

/** The reads of the open leads, tickets and tasks (cma.open_leads, open_tickets, open_tasks), any one of them */
export const FOLLOW_UP_PERMISSIONS = ["reports.view", "performance.team", "monitoring.live"] as const;
/** cma.follow_up_summary: the Welcome page's Needs attention block and the Live board's tiles */
export const FOLLOW_UP_SUMMARY_PERMISSIONS = ["monitoring.live", "performance.team", "workday.team"] as const;
/** cma.follow_up_by_owner: per-person figures sit under the employee-monitoring point, like Calls per agent */
export const FOLLOW_UP_BY_OWNER_PERMISSION = "performance.team";
/** cma.my_follow_up: the person's own rows (Waiting for you) */
export const MY_FOLLOW_UP_PERMISSIONS = ["leads.accept", "workday.own"] as const;

export const SLA_STATES: readonly SlaState[] = ["ok", "at_risk", "breached", "no_hours"];
export const DUE_STATES: readonly DueState[] = ["overdue", "today", "later", "none"];

// ---- The filters of Reports → Follow-up -------------------------------------------------------

/** "none": rows whose owner maps to nobody or is empty */
export const OWNER_NONE = "none";

export interface FollowUpFilter {
  /** A market code ("unknown" for rows without one), or null for every market */
  market: string | null;
  /** A person's id, OWNER_NONE, or null for everyone */
  owner: string | null;
  /** "attention": leads past the target, tickets at risk or breached, tasks overdue; null for everything waiting */
  state: "attention" | null;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The filter named in a query; anything ill-formed is no filter */
export function parseFollowUpFilter(sp: Record<string, string | string[] | undefined> | URLSearchParams): FollowUpFilter {
  const get = (k: string): string | null => {
    const v = sp instanceof URLSearchParams ? sp.get(k) : sp[k];
    return typeof v === "string" && v !== "" ? v : null;
  };
  const market = get("market");
  const owner = get("owner");
  return {
    market: market !== null && /^[A-Za-z0-9_-]{1,20}$/.test(market) ? market : null,
    owner: owner !== null && (owner === OWNER_NONE || UUID_RE.test(owner)) ? (owner === OWNER_NONE ? OWNER_NONE : owner.toLowerCase()) : null,
    state: get("state") === "attention" ? "attention" : null,
  };
}

/** The filter as a query string's entries, without the empty ones */
export function filterQuery(f: FollowUpFilter): Record<string, string> {
  return { ...(f.market ? { market: f.market } : {}), ...(f.owner ? { owner: f.owner } : {}), ...(f.state ? { state: f.state } : {}) };
}

type Owned = { ownerUserId: string | null; market: string | null };

function ownerMatches(row: Owned, owner: string | null): boolean {
  if (owner === null) return true;
  if (owner === OWNER_NONE) return row.ownerUserId === null;
  return row.ownerUserId === owner;
}

function marketMatches(row: Owned, market: string | null): boolean {
  return market === null || (row.market ?? "unknown") === market;
}

export function leadNeedsAttention(l: OpenLead): boolean {
  return l.pastTarget === true;
}

export function ticketNeedsAttention(t: OpenTicket): boolean {
  return t.slaState === "at_risk" || t.slaState === "breached";
}

export function taskNeedsAttention(k: OpenTask): boolean {
  return k.dueState === "overdue";
}

export function filterLeads(rows: OpenLead[], f: FollowUpFilter): OpenLead[] {
  return rows.filter((r) => marketMatches(r, f.market) && ownerMatches(r, f.owner) && (f.state !== "attention" || leadNeedsAttention(r)));
}

export function filterTickets(rows: OpenTicket[], f: FollowUpFilter): OpenTicket[] {
  return rows.filter((r) => marketMatches(r, f.market) && ownerMatches(r, f.owner) && (f.state !== "attention" || ticketNeedsAttention(r)));
}

export function filterTasks(rows: OpenTask[], f: FollowUpFilter): OpenTask[] {
  return rows.filter((r) => marketMatches(r, f.market) && ownerMatches(r, f.owner) && (f.state !== "attention" || taskNeedsAttention(r)));
}

/** The choices of the filters (types.ts FollowUpFilterOptions) */
export type FilterOptions = FollowUpFilterOptions;

/** The choices of the filters, from every row before filtering, so a choice never disappears while it is made */
export function filterOptions(leads: OpenLead[], tickets: OpenTicket[], tasks: OpenTask[]): FilterOptions {
  const rows: (Owned & { ownerName: string | null })[] = [...leads, ...tickets, ...tasks];
  const markets = [...new Set(rows.map((r) => r.market ?? "unknown"))].sort((a, b) => (a === "unknown" ? 1 : b === "unknown" ? -1 : a.localeCompare(b)));
  const owners = new Map<string, string | null>();
  for (const r of rows) if (r.ownerUserId !== null && !owners.has(r.ownerUserId)) owners.set(r.ownerUserId, r.ownerName);
  return {
    markets,
    owners: [...owners.entries()].map(([id, name]) => ({ id, name })).sort((a, b) => (a.name ?? "").localeCompare(b.name ?? "") || a.id.localeCompare(b.id)),
    hasUnowned: rows.some((r) => r.ownerUserId === null),
  };
}

// ---- The counts, as the database computes them ------------------------------------------------

/** cma.follow_up_summary_of over the three lists */
export function summarise(leads: OpenLead[], tickets: OpenTicket[], tasks: OpenTask[]): FollowUpSummary {
  return {
    leadsOpenNotCalled: leads.length,
    leadsPastTarget: leads.filter((l) => l.pastTarget === true).length,
    ticketsAtRisk: tickets.filter((t) => t.slaState === "at_risk").length,
    ticketsBreached: tickets.filter((t) => t.slaState === "breached").length,
    ticketsWithoutOwner: tickets.filter((t) => t.ownerRef === null).length,
    tasksOverdue: tasks.filter((k) => k.dueState === "overdue").length,
    tasksDueToday: tasks.filter((k) => k.dueState === "today").length,
    tasksUnmappedOwner: tasks.filter((k) => k.ownerRef !== null && k.ownerUserId === null).length,
  };
}

/**
 * cma.follow_up_by_owner_of over the three lists: one row per person with something waiting, by name,
 * then one row without a person for every row whose owner maps to nobody or is empty; nobody with nothing
 */
export function byOwner(leads: OpenLead[], tickets: OpenTicket[], tasks: OpenTask[]): FollowUpOwner[] {
  const rows = new Map<string | null, FollowUpOwner>();
  const of = (id: string | null, name: string | null): FollowUpOwner => {
    let r = rows.get(id);
    if (!r) {
      r = { ownerUserId: id, displayName: id === null ? null : name, openLeads: 0, leadsPastTarget: 0, openTickets: 0, ticketsAtRiskOrBreached: 0, tasksOverdue: 0, tasksDueToday: 0 };
      rows.set(id, r);
    }
    return r;
  };
  for (const l of leads) {
    const r = of(l.ownerUserId, l.ownerName);
    r.openLeads++;
    if (l.pastTarget === true) r.leadsPastTarget++;
  }
  for (const t of tickets) {
    const r = of(t.ownerUserId, t.ownerName);
    r.openTickets++;
    if (ticketNeedsAttention(t)) r.ticketsAtRiskOrBreached++;
  }
  for (const k of tasks) {
    const r = of(k.ownerUserId, k.ownerName);
    if (k.dueState === "overdue") r.tasksOverdue++;
    if (k.dueState === "today") r.tasksDueToday++;
  }
  return [...rows.values()].sort((a, b) => {
    if (a.ownerUserId === null) return 1;
    if (b.ownerUserId === null) return -1;
    return (a.displayName ?? "").localeCompare(b.displayName ?? "") || a.ownerUserId.localeCompare(b.ownerUserId);
  });
}

/** The person's own rows: the ones whose owner maps to them */
export function ownRows<T extends { ownerUserId: string | null }>(rows: T[], userId: string): T[] {
  return rows.filter((r) => r.ownerUserId === userId);
}

// ---- The snapshot (addition 0008s) ---------------------------------------------------------------

/** follow_up.list_rows: the rows each list shows after its filters, as cma.follow_up_page bounds it */
export const FOLLOW_UP_LIST_ROWS_DEFAULT = 100;
export const FOLLOW_UP_LIST_ROWS_MAX = 500;
/** Figures older than this read as stale: "Updated …" turns Muted (the refresh runs every minute) */
export const FOLLOW_UP_STALE_MS = 3 * 60_000;

/** The rows a list shows: the setting's value within 1 to 500, the default when it is not a whole number */
export function listRowsOf(value: string | number | null | undefined): number {
  const n = typeof value === "number" ? value : value !== null && value !== undefined && /^\d{1,6}$/.test(value) ? Number(value) : FOLLOW_UP_LIST_ROWS_DEFAULT;
  return Math.min(FOLLOW_UP_LIST_ROWS_MAX, Math.max(1, Math.trunc(n)));
}

/**
 * cma.follow_up_page over the three lists (the mock data layer): the summary of every row, per person for
 * performance.team only, the filter choices from every row, each list after the filter with its total and its
 * first rows, and the counts before the filters
 */
export function followUpPage(
  leads: OpenLead[], tickets: OpenTicket[], tasks: OpenTask[], filter: FollowUpFilter,
  opts: { rows: number; canByOwner: boolean; computedAt: string; durationMs: number; targetMinutes: number | null; warningPct: number | null },
): FollowUpPage {
  const cap = listRowsOf(opts.rows);
  const list = <T>(shown: T[]) => ({ total: shown.length, rows: shown.slice(0, cap) });
  return {
    computedAt: opts.computedAt,
    durationMs: opts.durationMs,
    rows: cap,
    summary: summarise(leads, tickets, tasks),
    byOwner: opts.canByOwner ? byOwner(leads, tickets, tasks) : null,
    options: filterOptions(leads, tickets, tasks),
    settings: { targetMinutes: opts.targetMinutes, warningPct: opts.warningPct },
    counts: { leads: leads.length, tickets: tickets.length, tasks: tasks.length },
    leads: list(filterLeads(leads, filter)),
    tickets: list(filterTickets(tickets, filter)),
    tasks: list(filterTasks(tasks, filter)),
  };
}

/** True when the figures are older than FOLLOW_UP_STALE_MS at now */
export function isStale(computedAt: string, now: Date): boolean {
  return now.getTime() - Date.parse(computedAt) > FOLLOW_UP_STALE_MS;
}

/** How long ago the figures were computed, in words: "now", "20 seconds ago", "2 minutes ago", "1 hour ago" (the locale's own) */
export function agoText(computedAt: string, now: Date, locale: string): string {
  const s = Math.max(0, Math.round((now.getTime() - Date.parse(computedAt)) / 1000));
  const rtf = new Intl.RelativeTimeFormat(locale, { numeric: "auto" });
  if (s < 10) return rtf.format(0, "second");
  if (s < 60) return rtf.format(-s, "second");
  if (s < 3600) return rtf.format(-Math.floor(s / 60), "minute");
  if (s < 86_400) return rtf.format(-Math.floor(s / 3600), "hour");
  return rtf.format(-Math.floor(s / 86_400), "day");
}

// ---- Welcome's Needs attention and the Live board's tiles --------------------------------------

export type AttentionKey = "daysNotEnded" | "leadsPastTarget" | "ticketsAtRiskOrBreached" | "tasksOverdue" | "missedCallbacks";

/** Team hours filtered to the days to correct (needsCorrection or isCapped), as the Needs attention line opens it */
export const TEAM_HOURS_TO_CORRECT = "/team/hours?range=month&needs=correction";

export interface AttentionLine {
  key: AttentionKey;
  count: number;
  href: typeof TEAM_HOURS_TO_CORRECT | "/reports/follow-up?state=attention" | "/live/board";
}

/**
 * The lines of the Needs attention block, in order, each with where to act: the days not clocked out (only
 * for a person who may correct them: null leaves the line out; the link lands on the rows to correct, not on
 * the whole month: the IT audit of 17 October 2026), the summary's three figures, and the missed callers not
 * called back (null without monitoring.live or without telephony)
 */
export function attentionLines(summary: FollowUpSummary, daysNotEnded: number | null, missedCallbacks: number | null): AttentionLine[] {
  const out: AttentionLine[] = [];
  if (daysNotEnded !== null) out.push({ key: "daysNotEnded", count: daysNotEnded, href: TEAM_HOURS_TO_CORRECT });
  out.push({ key: "leadsPastTarget", count: summary.leadsPastTarget, href: "/reports/follow-up?state=attention" });
  out.push({ key: "ticketsAtRiskOrBreached", count: summary.ticketsAtRisk + summary.ticketsBreached, href: "/reports/follow-up?state=attention" });
  out.push({ key: "tasksOverdue", count: summary.tasksOverdue, href: "/reports/follow-up?state=attention" });
  if (missedCallbacks !== null) out.push({ key: "missedCallbacks", count: missedCallbacks, href: "/live/board" });
  return out;
}

export type FollowUpTileKey = "leadsOpenNotCalled" | "leadsPastTarget" | "ticketsAtRisk" | "ticketsBreached" | "tasksOverdue" | "tasksDueToday";
/** The Live board's strip: six counts, in this order */
export const FOLLOW_UP_TILES: readonly FollowUpTileKey[] = ["leadsOpenNotCalled", "leadsPastTarget", "ticketsAtRisk", "ticketsBreached", "tasksOverdue", "tasksDueToday"];

// ---- Formats -----------------------------------------------------------------------------------

/** The age bucket in words: "0–1", "2–5", "5+" (the open last bucket); null for a lead without business hours */
export function bucketLabel(from: number | null, to: number | null): string | null {
  if (from === null) return null;
  return to === null ? `${from}+` : `${from}–${to}`;
}

/** Whole days since an instant, in the person's zone, from the two dates (today is 0) */
export function daysSince(date: string, today: string): number {
  const ms = Date.parse(`${today}T00:00:00Z`) - Date.parse(`${date}T00:00:00Z`);
  return Math.max(0, Math.round(ms / 86_400_000));
}

// ---- The settings, as cma.check_tenant_setting applies them -------------------------------------

export const FOLLOW_UP_SETTING_KEYS = ["tickets.sla_minutes", "tickets.sla_warning_pct", "leads.age_buckets_business_days", "tasks.callback_window_minutes",
  "follow_up.list_rows"] as const;
export type FollowUpSettingKey = (typeof FOLLOW_UP_SETTING_KEYS)[number];

/** cma.is_bucket_list: one to five increasing whole numbers from 1, comma-separated (spaces are stripped first, as the trigger does) */
export function normaliseBucketList(text: string): string | null {
  const v = text.replace(/\s+/g, "");
  if (!/^[1-9][0-9]{0,3}(,[1-9][0-9]{0,3}){0,4}$/.test(v)) return null;
  const edges = v.split(",").map(Number);
  for (let i = 1; i < edges.length; i++) if (edges[i]! <= edges[i - 1]!) return null;
  return v;
}

/** A whole number within the setting's bounds, or null: 1 to 100000 business minutes, 1 to 100 %, 0 to 10080 minutes, 1 to 500 rows */
export function parseFollowUpSetting(key: FollowUpSettingKey, text: string): string | null {
  if (key === "leads.age_buckets_business_days") return normaliseBucketList(text);
  const t = text.trim();
  if (!/^\d{1,6}$/.test(t)) return null;
  const n = Number(t);
  const [min, max] = key === "tickets.sla_minutes" ? [1, 100000] : key === "tickets.sla_warning_pct" ? [1, 100]
    : key === "follow_up.list_rows" ? [1, FOLLOW_UP_LIST_ROWS_MAX] : [0, 10080];
  return n >= min && n <= max ? String(n) : null;
}

/** A pipeline's own response time: 1 to 100000 business minutes, or null (empty) for the tenant default; undefined when ill-formed */
export function parsePipelineSla(text: string): number | null | undefined {
  const t = text.trim();
  if (t === "") return null;
  if (!/^\d{1,6}$/.test(t)) return undefined;
  const n = Number(t);
  return n >= 1 && n <= 100000 ? n : undefined;
}

/** The connection setting of the unlinked-calls check (data quality, 0008o): skip or check every call */
export const DQ_UNLINKED_SKIP_KEY = "dq_unlinked_skip";
export const DQ_UNLINKED_SKIP_DEFAULT = "outbound_unanswered_untagged";
export const DQ_UNLINKED_SKIP_NONE = "none";

/** The value in force for a telephony connection: the stored value, else the default for kind telephony */
export function unlinkedSkipOf(settings: Record<string, unknown>, kind: string | null): string {
  const v = settings[DQ_UNLINKED_SKIP_KEY];
  if (typeof v === "string" && v !== "") return v;
  return kind === "telephony" ? DQ_UNLINKED_SKIP_DEFAULT : DQ_UNLINKED_SKIP_NONE;
}
