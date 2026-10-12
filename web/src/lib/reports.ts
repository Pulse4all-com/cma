/**
 * The intake reports' logic (B11, 12 October 2026): the speed-to-lead grouping and period figures,
 * intake totals with the not-connected states, the data-quality order and the formats. The figures
 * themselves come from the database (migration 0007d); this module only arranges them, and mirrors
 * cma.speed_to_lead_summary where the Dashboard needs one figure for a whole period (a median over
 * the period cannot be added up from the groups). Pure, with no runtime imports beyond time.ts, so
 * verify/reports.mjs tests it without a browser or a database.
 *
 * Not connected: a telephony or commerce figure is null when the tenant has no such source, and a
 * screen says so ("No telephony connected", "No shop connected"); it never shows 0 for a source
 * that is not there.
 */
import type {
  DataQualityCheck, IntakeDay, SourceConnections, SpeedToLeadGroup, SpeedToLeadRow, SpeedToLeadSummaryRow,
} from "./data/types";
import { daysBetween, fmtMinutes } from "./time.ts";

/** Every report function answers at most 92 days per request; the app refuses a longer range too */
export const MAX_REPORT_DAYS = 92;

/**
 * The permissions of the report functions (0007d), any one of each list: the screens, the nav and the
 * routes check them, and the database checks again on every call
 */
export const REPORT_PERMISSIONS = ["reports.view", "performance.team"] as const;
export const DATA_QUALITY_PERMISSIONS = ["reports.view", "tenant.configure"] as const;

export const SPEED_TO_LEAD_GROUPS: readonly SpeedToLeadGroup[] = ["day", "market", "agent", "pipeline"];

/** The group named in a query, or null when it is none of the four */
export function parseGroup(value: unknown): SpeedToLeadGroup | null {
  return typeof value === "string" && (SPEED_TO_LEAD_GROUPS as readonly string[]).includes(value) ? (value as SpeedToLeadGroup) : null;
}

/** The group G moves to: day, market, agent, pipeline, then day again */
export function nextGroup(group: SpeedToLeadGroup): SpeedToLeadGroup {
  return SPEED_TO_LEAD_GROUPS[(SPEED_TO_LEAD_GROUPS.indexOf(group) + 1) % SPEED_TO_LEAD_GROUPS.length]!;
}

/** Why a range is refused: "order" when it runs backwards, "length" beyond 92 days, else null */
export function rangeProblem(from: string, to: string): null | "order" | "length" {
  if (to < from) return "order";
  return daysBetween(from, to) + 1 > MAX_REPORT_DAYS ? "length" : null;
}

// ---- Speed to lead -----------------------------------------------------------------------------

/** percentile_cont as PostgreSQL computes it: linear between the two nearest ranks; null for no values */
export function percentileCont(values: number[], p: number): number | null {
  if (values.length === 0) return null;
  const v = [...values].sort((a, b) => a - b);
  const pos = p * (v.length - 1);
  const lo = Math.floor(pos);
  const hi = Math.ceil(pos);
  return v[lo]! + (v[hi]! - v[lo]!) * (pos - lo);
}

/** round(x, 1) as numeric rounds: half away from zero */
function round1(x: number): number {
  return Math.sign(x) * Math.round(Math.abs(x) * 10 + 1e-9) / 10;
}

/**
 * One group's figures from its rows, as cma.speed_to_lead_summary computes them: business minutes
 * over the called deals, the percentages over the deals whose outcome is known (null while none is).
 */
export function speedFigures(rows: SpeedToLeadRow[]): Omit<SpeedToLeadSummaryRow, "groupKey" | "groupLabel"> {
  const seconds = rows.map((r) => r.businessSeconds).filter((s): s is number => s !== null);
  const pct = (flags: (boolean | null)[]) => {
    const known = flags.filter((f) => f !== null);
    return known.length === 0 ? null : round1((100 * known.filter(Boolean).length) / known.length);
  };
  const median = percentileCont(seconds, 0.5);
  const p80 = percentileCont(seconds, 0.8);
  return {
    deals: rows.length,
    called: rows.filter((r) => r.status === "called").length,
    medianBusinessMinutes: median === null ? null : round1(median / 60),
    p80BusinessMinutes: p80 === null ? null : round1(p80 / 60),
    withinTargetPct: pct(rows.map((r) => r.withinTarget)),
    beforeNextNoonPct: pct(rows.map((r) => r.beforeNextNoon)),
    openNotCalled: rows.filter((r) => r.status === "not_called_open").length,
  };
}

/**
 * The rows grouped as cma.speed_to_lead_summary groups them, ordered by key. `agentName` gives a
 * mapped agent's display name; an agent who is not mapped is the key "unknown" with no label.
 */
export function groupSpeedToLead(
  rows: SpeedToLeadRow[], group: SpeedToLeadGroup, agentName: (userId: string) => string | null,
): SpeedToLeadSummaryRow[] {
  const groups = new Map<string, { label: string | null; rows: SpeedToLeadRow[] }>();
  for (const r of rows) {
    const [key, label] =
      group === "day" ? [r.date, r.date]
      : group === "market" ? [r.market, r.market]
      : group === "agent" ? (r.agentUserId ? [r.agentUserId, agentName(r.agentUserId) ?? "unknown"] : ["unknown", null])
      : [`${r.connectionId}:${r.pipelineId ?? ""}`, r.pipelineLabel ?? "unknown"];
    const g = groups.get(key) ?? { label, rows: [] };
    g.rows.push(r);
    groups.set(key, g);
  }
  return [...groups.entries()]
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([groupKey, g]) => ({ groupKey, groupLabel: g.label, ...speedFigures(g.rows) }));
}

/** What a group's label means on screen; the page turns it into words */
export type GroupDisplay =
  | { kind: "date"; date: string }
  | { kind: "text"; text: string }
  | { kind: "notMapped" }
  | { kind: "unknownMarket" }
  | { kind: "unknownPipeline" };

/** An agent without a mapping is "Not mapped", never an owner id; an unknown market or pipeline says so */
export function groupDisplay(row: Pick<SpeedToLeadSummaryRow, "groupKey" | "groupLabel">, group: SpeedToLeadGroup): GroupDisplay {
  switch (group) {
    case "day":
      return { kind: "date", date: row.groupKey };
    case "market":
      return row.groupKey === "unknown" ? { kind: "unknownMarket" } : { kind: "text", text: row.groupKey };
    case "agent":
      return row.groupKey === "unknown" || !row.groupLabel ? { kind: "notMapped" } : { kind: "text", text: row.groupLabel };
    case "pipeline":
      return !row.groupLabel || row.groupLabel === "unknown" ? { kind: "unknownPipeline" } : { kind: "text", text: row.groupLabel };
  }
}

/** The summary's totals over its groups: counts add up, medians and percentages do not, so those are left out */
export function summaryTotals(rows: SpeedToLeadSummaryRow[]): { deals: number; called: number; openNotCalled: number } {
  return rows.reduce((t, r) => ({ deals: t.deals + r.deals, called: t.called + r.called, openNotCalled: t.openNotCalled + r.openNotCalled }),
    { deals: 0, called: 0, openNotCalled: 0 });
}

/** Open deals not called, the longest waiting first (a deal without business time last), then by id */
export function openNotCalled(rows: SpeedToLeadRow[]): SpeedToLeadRow[] {
  return rows
    .filter((r) => r.status === "not_called_open")
    .sort((a, b) => (b.waitingBusinessSeconds ?? -1) - (a.waitingBusinessSeconds ?? -1) || a.createdAt.localeCompare(b.createdAt) || a.dealSourceId.localeCompare(b.dealSourceId));
}

// ---- Intake ------------------------------------------------------------------------------------

/** A row of cma.intake_per_day as the database answers it, every figure a count */
export type IntakeCounts = { [K in keyof IntakeDay]: IntakeDay[K] extends number | null ? number : IntakeDay[K] };

export const TELEPHONY_FIELDS = ["callsIn", "callsOut", "taggedCalls"] as const;
export const COMMERCE_FIELDS = ["newCustomers", "firstOrders", "repeatOrders", "renewals"] as const;
export const CRM_FIELDS = ["formSubmissions", "dealsCreated", "dealsClosed", "ticketsCreated", "ticketsClosed"] as const;
export type IntakeField = (typeof CRM_FIELDS)[number] | (typeof TELEPHONY_FIELDS)[number] | (typeof COMMERCE_FIELDS)[number];
export const INTAKE_FIELDS: readonly IntakeField[] = [...CRM_FIELDS, ...TELEPHONY_FIELDS, ...COMMERCE_FIELDS];

/** The telephony figures become null without telephony, the commerce figures without a shop */
export function applyConnections(rows: IntakeCounts[], c: SourceConnections): IntakeDay[] {
  return rows.map((r) => ({
    ...r,
    callsIn: c.telephony ? r.callsIn : null,
    callsOut: c.telephony ? r.callsOut : null,
    taggedCalls: c.telephony ? r.taggedCalls : null,
    newCustomers: c.commerce ? r.newCustomers : null,
    firstOrders: c.commerce ? r.firstOrders : null,
    repeatOrders: c.commerce ? r.repeatOrders : null,
    renewals: c.commerce ? r.renewals : null,
  }));
}

export type IntakeTotals = Record<IntakeField, number | null>;

/** Each figure added up; null stays null (a source that is not connected has no total, not 0) */
export function intakeTotals(rows: IntakeDay[], c: SourceConnections): IntakeTotals {
  const out = {} as IntakeTotals;
  for (const f of INTAKE_FIELDS) {
    const connected = (TELEPHONY_FIELDS as readonly string[]).includes(f) ? c.telephony
      : (COMMERCE_FIELDS as readonly string[]).includes(f) ? c.commerce : true;
    out[f] = connected ? rows.reduce((n, r) => n + (r[f] ?? 0), 0) : null;
  }
  return out;
}

/** The markets in the rows, catalog codes in order and "unknown" last */
export function intakeMarkets(rows: Pick<IntakeDay, "market">[]): string[] {
  return [...new Set(rows.map((r) => r.market))].sort((a, b) => (a === "unknown" ? 1 : b === "unknown" ? -1 : a.localeCompare(b)));
}

/** The rows of one market, or all of them for "" */
export function filterMarket<T extends Pick<IntakeDay, "market">>(rows: T[], market: string): T[] {
  return market ? rows.filter((r) => r.market === market) : rows;
}

/** A row's inline bar: what came in (forms, deals and tickets created), as a share of the largest row */
export function intakeVolume(r: IntakeDay): number {
  return r.formSubmissions + r.dealsCreated + r.ticketsCreated;
}

export function barShares(rows: IntakeDay[]): number[] {
  const largest = Math.max(0, ...rows.map(intakeVolume));
  return rows.map((r) => (largest === 0 ? 0 : intakeVolume(r) / largest));
}

/** What a figure shows: the count, or the reason there is none */
export type Cell = { kind: "count"; value: number } | { kind: "noTelephony" } | { kind: "noShop" };

export function cellOf(field: IntakeField, value: number | null): Cell {
  if (value !== null) return { kind: "count", value };
  return (TELEPHONY_FIELDS as readonly string[]).includes(field) ? { kind: "noTelephony" } : { kind: "noShop" };
}

/** Records of one type in the rows of cma.crm_records_per_day */
export function recordsOfType(rows: { recordType: string; records: number }[], recordType: string): number {
  return rows.reduce((n, r) => n + (r.recordType === recordType ? r.records : 0), 0);
}

// ---- Data quality ------------------------------------------------------------------------------

/** CRM owners without a person come first (attribution waits on them), the rest in the database's order */
export const FIRST_CHECKS: readonly string[] = ["owner_without_person"];

export function orderChecks(checks: DataQualityCheck[]): DataQualityCheck[] {
  const first = FIRST_CHECKS.flatMap((k) => checks.filter((c) => c.key === k));
  return [...first, ...checks.filter((c) => !FIRST_CHECKS.includes(c.key))];
}

/** A check with nothing to fix (0, or a source not installed) is shown muted */
export function isMuted(c: DataQualityCheck): boolean {
  return c.total === null || c.total === 0;
}

// ---- Formats -----------------------------------------------------------------------------------

const intlLocale: Record<string, string> = { en: "en-GB", nl: "nl-NL" };

/** A whole count with the locale's grouping */
export function fmtCount(n: number, locale: string): string {
  return new Intl.NumberFormat(intlLocale[locale] ?? locale).format(n);
}

/** Business minutes: "7,5 min" under an hour (one decimal at most), "1h 05m" from an hour, a dash for none */
export function fmtBusinessMinutes(minutes: number | null, locale: string): string {
  if (minutes === null) return "–";
  if (minutes < 60) return `${new Intl.NumberFormat(intlLocale[locale] ?? locale, { maximumFractionDigits: 1 }).format(minutes)} min`;
  return fmtMinutes(Math.round(minutes));
}

/** A percentage the database gave with one decimal (0 to 100), shown in whole percents; a dash for none */
export function fmtPct(pct: number | null, locale: string): string {
  if (pct === null) return "–";
  const f = new Intl.NumberFormat(intlLocale[locale] ?? locale, { style: "percent", maximumFractionDigits: 0 });
  return pct > 0 && pct < 0.5 ? `< ${f.format(0.01)}` : f.format(pct / 100);
}

// ---- Header hints ------------------------------------------------------------------------------

/** The speed-to-lead target in whole business minutes, from the rows (the tenant's setting); null without rows */
export function targetMinutesOf(rows: Pick<SpeedToLeadRow, "targetSeconds">[]): number | null {
  const s = rows.find((x) => x.targetSeconds !== null)?.targetSeconds;
  return s === null || s === undefined ? null : Math.round(s / 60);
}

/**
 * A header hint's text with its values filled in: {hours} the office hours (per market, tenant
 * configuration) and {target} the speed-to-lead target from the tenant's settings, a dash when the
 * period has no rows to carry it. The copy never holds either value.
 */
export function fillHint(text: string, values: { hours: string; target?: number | null }, locale: string): string {
  const target = values.target === null || values.target === undefined ? "–" : fmtCount(values.target, locale);
  return text.replaceAll("{hours}", values.hours).replaceAll("{target}", target);
}
