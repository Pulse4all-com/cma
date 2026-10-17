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
 * that is not there. Since addition 0008i Inbound, since 0008j Calls and Calls per agent (brief B16),
 * since 0008p Forms (brief B17d).
 */
import type {
  CallsFigures, CallsFilter, CallsGroup, CallsPerson, CallsPersonTag, CallsRow, DataQualityCheck, DateKey, FormAnswerRow, FormCategory, FormsFilter,
  FormsGroup, FormsResolution, FormsRow, HoursRange, InboundFigures, InboundGroup, InboundServiceRow, Instant, IntakeDay, MissedReason,
  SourceConnections, SpeedToLeadGroup, SpeedToLeadRow, SpeedToLeadSummaryRow, TagUseRow,
} from "./data/types";
// With their extensions, so verify/reports.mjs can run this module under Node's type stripping
import { isoWeek } from "./roster.ts";
import { addDays, dateKeyInZone, daysBetween, fmtMinutes, hourInZone, startOfWeek } from "./time.ts";

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
export function round1(x: number): number {
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

/**
 * The outbox guard's row (brief A5; sixth Gemini audit FIND-05, 13 October 2026). ingest-outbox runs
 * without a schedule since 0008h, so an outbox action of an active connection still waiting
 * OUTBOX_LATE_MINUTES after it fell due is one no outbox run claimed; the sweep counts and logs the
 * same (ingest/src/jobs/sweep.mjs, OUTBOX_LATE). Not a check of cma.data_quality() (no migration): the
 * row follows the database's checks, and only while the count is above 0.
 */
export const OUTBOX_PENDING_CHECK = "outbox_pending";
export const OUTBOX_LATE_MINUTES = 10;

export function withOutboxPending(checks: DataQualityCheck[], pending: number): DataQualityCheck[] {
  if (!(pending > 0)) return checks;
  return [...checks, {
    key: OUTBOX_PENDING_CHECK,
    description: `Outbox actions not delivered ${OUTBOX_LATE_MINUTES} minutes after they fell due (ingest-outbox unscheduled or not running)`,
    total: pending,
  }];
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

// ---- Inbound service (addition 0008i, brief B15) -------------------------------------------------
//
// The figures come from the database (cma.inbound_service, cma.inbound_today); the functions below
// mirror its definitions for the mock and for verify/reports.mjs, and arrange the rows for the screen.
// No call here carries a number, a name or the caller's hash.

export const INBOUND_GROUPS: readonly InboundGroup[] = ["day", "market", "line", "hour"];

/** The group named in a query, or null when it is none of the four */
export function parseInboundGroup(value: unknown): InboundGroup | null {
  return typeof value === "string" && (INBOUND_GROUPS as readonly string[]).includes(value) ? (value as InboundGroup) : null;
}

/** The group G moves to: day, market, line, hour, then day again */
export function nextInboundGroup(group: InboundGroup): InboundGroup {
  return INBOUND_GROUPS[(INBOUND_GROUPS.indexOf(group) + 1) % INBOUND_GROUPS.length]!;
}

/** The code of an unanswered inbound call without a reason */
export const UNKNOWN_REASON = "unknown";

/**
 * A reason as the catalog says, or the defaults for a code without a row: the code as label, in the
 * service level and needing a callback, so a new code of the telephony system never disappears
 */
export function missedReasonOf(sourceSystem: string, code: string, catalog: readonly MissedReason[]): MissedReason {
  return catalog.find((r) => r.sourceSystem === sourceSystem && r.code === code)
    ?? { sourceSystem, code, label: code, countsInServiceLevel: true, needsCallback: true };
}

/** One telephony call as the fixture and the verifier hold it: what the database stores, without the hash */
export interface TelephonyCallFixture {
  sourceId: string;
  connectionId: string;
  sourceSystem: string;
  direction: "inbound" | "outbound";
  startedAt: Instant;
  answeredAt: Instant | null;
  endedAt: Instant | null;
  missedReason: string | null;
  lineRef: string | null;
  deleted?: boolean;
  /** The telephony user who took or made the call (addition 0008j); a staff id, never shown */
  userRef?: string | null;
  /** The call's current tags, refs of its connection's catalog (addition 0008j) */
  tagRefs?: string[];
}

/** A line of the catalog: its name and market; a line without a row counts and has neither */
export interface InboundLine {
  connectionId: string;
  lineRef: string;
  name: string;
  /** A catalog market code, or null */
  market: string | null;
  /** The market's zone, or null for a line without a market */
  zone: string | null;
  isCounted: boolean;
}

/** One inbound call as cma.inbound_calls_of gives it */
export interface InboundCall {
  sourceId: string;
  connectionId: string;
  lineKey: string;
  lineName: string | null;
  market: string;
  date: DateKey;
  hour: number;
  isAnswered: boolean;
  isWaiting: boolean;
  answerSeconds: number | null;
  /** For an unanswered call only: its reason ("unknown" without one) */
  reasonCode: string | null;
  reasonLabel: string | null;
  needsCallback: boolean | null;
  inServiceLevel: boolean;
  startedAt: Instant;
}

/**
 * The inbound calls of a fixture as cma.inbound_calls_of classifies them: inbound, not deleted, with a
 * start, on a counted line (a line not in the catalog counts); the zone of the line's market, else the
 * tenant's; waiting while not answered, not ended and younger than waitingMaxMinutes
 */
export function inboundCalls(
  calls: readonly TelephonyCallFixture[], lines: readonly InboundLine[], catalog: readonly MissedReason[],
  tenantZone: string, waitingMaxMinutes: number, nowMs: number,
): InboundCall[] {
  const out: InboundCall[] = [];
  for (const c of calls) {
    if (c.direction !== "inbound" || c.deleted || !c.startedAt) continue;
    const line = lines.find((l) => l.connectionId === c.connectionId && l.lineRef === c.lineRef);
    if (line && !line.isCounted) continue;
    const zone = line?.zone ?? tenantZone;
    const started = Date.parse(c.startedAt);
    const isAnswered = c.answeredAt !== null;
    const isWaiting = !isAnswered && c.endedAt === null && started >= nowMs - Math.max(0, waitingMaxMinutes) * 60_000;
    const unanswered = !isAnswered && !isWaiting;
    const reason = unanswered ? missedReasonOf(c.sourceSystem, c.missedReason?.trim() || UNKNOWN_REASON, catalog) : null;
    out.push({
      sourceId: c.sourceId,
      connectionId: c.connectionId,
      lineKey: `${c.connectionId}:${c.lineRef ?? ""}`,
      lineName: line?.name ?? c.lineRef,
      market: line?.market ?? "unknown",
      date: dateKeyInZone(c.startedAt, zone),
      hour: hourInZone(c.startedAt, zone),
      isAnswered,
      isWaiting,
      answerSeconds: isAnswered ? Math.max(0, (Date.parse(c.answeredAt!) - started) / 1000) : null,
      reasonCode: reason?.code ?? null,
      reasonLabel: reason?.label ?? null,
      needsCallback: reason?.needsCallback ?? null,
      inServiceLevel: isAnswered || (reason?.countsInServiceLevel ?? false),
      startedAt: c.startedAt,
    });
  }
  return out;
}

/** The measures of a set of calls, as the database computes them */
export function inboundFigures(calls: readonly InboundCall[], serviceLevelSeconds: number): InboundFigures {
  const n = Math.max(0, serviceLevelSeconds);
  const answers = calls.filter((c) => c.isAnswered).map((c) => c.answerSeconds!);
  const within = answers.filter((s) => s <= n).length;
  const base = calls.filter((c) => c.inServiceLevel).length;
  const p80 = percentileCont(answers, 0.8);
  const byReason: Record<string, number> = {};
  for (const c of calls) if (c.reasonCode !== null) byReason[c.reasonCode] = (byReason[c.reasonCode] ?? 0) + 1;
  return {
    offered: calls.length,
    answered: answers.length,
    unanswered: calls.filter((c) => !c.isAnswered && !c.isWaiting).length,
    waiting: calls.filter((c) => c.isWaiting).length,
    answeredWithinTarget: within,
    serviceLevelBase: base,
    serviceLevelPct: base === 0 ? null : round1((100 * within) / base),
    avgAnswerSeconds: answers.length === 0 ? null : round1(answers.reduce((a, b) => a + b, 0) / answers.length),
    p80AnswerSeconds: p80 === null ? null : round1(p80),
    unansweredByReason: byReason,
  };
}

/** The key and label of a call's group, as cma.inbound_service_of groups */
function inboundGroupOf(c: InboundCall, group: InboundGroup): [string, string | null] {
  switch (group) {
    case "day": return [c.date, c.date];
    case "market": return [c.market, c.market];
    case "line": return [c.lineKey, c.lineName];
    case "hour": { const h = String(c.hour).padStart(2, "0"); return [h, h]; }
  }
}

/** The calls of business dates from..to grouped as cma.inbound_service groups them (lines by name), with the total */
export function groupInbound(
  calls: readonly InboundCall[], from: DateKey, to: DateKey, group: InboundGroup, serviceLevelSeconds: number,
): { rows: InboundServiceRow[]; total: InboundFigures } {
  const inRange = calls.filter((c) => c.date >= from && c.date <= to);
  const groups = new Map<string, { label: string | null; calls: InboundCall[] }>();
  for (const c of inRange) {
    const [key, label] = inboundGroupOf(c, group);
    const g = groups.get(key) ?? { label, calls: [] };
    g.calls.push(c);
    groups.set(key, g);
  }
  const rows = [...groups.entries()].map(([groupKey, g]) => ({ groupKey, groupLabel: g.label, ...inboundFigures(g.calls, serviceLevelSeconds) }));
  rows.sort((a, b) =>
    (group === "line" ? (a.groupLabel ?? "\uffff").localeCompare(b.groupLabel ?? "\uffff") : 0) || (a.groupKey < b.groupKey ? -1 : a.groupKey > b.groupKey ? 1 : 0));
  return { rows, total: inboundFigures(inRange, serviceLevelSeconds) };
}

/** Unanswered calls as a share of the calls with an outcome (answered or unanswered), 0 to 100; null without one */
export function unansweredPct(f: Pick<InboundFigures, "answered" | "unanswered">): number | null {
  const outcome = f.answered + f.unanswered;
  return outcome === 0 ? null : round1((100 * f.unanswered) / outcome);
}

/**
 * The series for missed reasons, in order (palette tokens only, written out so Tailwind finds them):
 * the series order of docs/style/Pulse4all-Style.md 7.7 without Leaf Green, which reads as Available on
 * the Live board, then the neutral grey, with Denim moved last because it sits too close to Deep Blue to
 * tell apart in a row's small bar: Deep Blue, Light Blue, Soft Rose, Inkt, Neutral, Denim (Martin,
 * B15.1, 14 October 2026). Each reason keeps its colour by code (`reasonColours`). Never the error red
 * or the warning amber: a reason is a category, not a verdict. No text sits on a Light Blue or Soft Rose
 * segment (7.8); the segments carry none, the label is in the column header and the legend. Answered
 * calls are Leaf Green next to them.
 */
export const REASON_SERIES: readonly string[] = ["bg-p4a-deepblue", "bg-p4a-lightblue", "bg-p4a-rose", "bg-p4a-inkt", "bg-p4a-muted", "bg-p4a-denim"];
export const ANSWERED_CLASS = "bg-p4a-green";
export const WAITING_CLASS = "bg-p4a-bgblue-dark";

/** A reason as a column of the report: its code, its label from the catalog and its colour */
export interface ReasonColumn {
  code: string;
  label: string;
  total: number;
  className: string;
  countsInServiceLevel: boolean;
}

const byCode = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);

/**
 * Each reason's colour, fixed by its code so that it keeps the colour across periods, groupings and
 * markets (Martin, review of B15.1): the catalog's codes sorted by code take the series in order, and the
 * codes without a catalog row that occur follow after the catalog, by code; both cycle through the series
 */
export function reasonColours(codes: readonly string[], catalog: readonly MissedReason[]): Map<string, string> {
  const known = [...new Set(catalog.map((r) => r.code))].sort(byCode);
  const others = [...new Set(codes)].filter((c) => !known.includes(c)).sort(byCode);
  return new Map([...known, ...others].map((code, i) => [code, REASON_SERIES[i % REASON_SERIES.length]!]));
}

/**
 * One column per reason that occurs in the rows, the most frequent first (then by code), labelled from
 * the catalog: a code means the same in every telephony system of a tenant, and the first source
 * system's row gives its label; without a row the code is its own label ("unknown" as `unknownLabel`).
 * The colour comes from the code, not the column's place (`reasonColours`)
 */
export function reasonColumns(rows: readonly Pick<InboundFigures, "unansweredByReason">[], catalog: readonly MissedReason[], unknownLabel: string): ReasonColumn[] {
  const totals = new Map<string, number>();
  for (const r of rows) for (const [code, n] of Object.entries(r.unansweredByReason)) if (n > 0) totals.set(code, (totals.get(code) ?? 0) + n);
  const sorted = [...catalog].sort((a, b) => a.sourceSystem.localeCompare(b.sourceSystem) || a.code.localeCompare(b.code));
  const colours = reasonColours([...totals.keys()], catalog);
  return [...totals.entries()]
    .sort(([a, x], [b, y]) => y - x || byCode(a, b))
    .map(([code, total]) => {
      const row = sorted.find((r) => r.code === code);
      return {
        code, total, className: colours.get(code)!,
        label: row?.label ?? (code === UNKNOWN_REASON ? unknownLabel : code),
        countsInServiceLevel: row?.countsInServiceLevel ?? true,
      };
    });
}

/** A row's inline bar: answered, then each reason in the columns' order, then waiting, as shares of the offered calls */
export function inboundBar(f: InboundFigures, columns: readonly ReasonColumn[]): { key: string; share: number; count: number; className: string }[] {
  if (f.offered === 0) return [];
  const parts = [
    { key: "answered", count: f.answered, className: ANSWERED_CLASS },
    ...columns.map((c) => ({ key: c.code, count: f.unansweredByReason[c.code] ?? 0, className: c.className })),
    { key: "waiting", count: f.waiting, className: WAITING_CLASS },
  ];
  return parts.filter((p) => p.count > 0).map((p) => ({ ...p, share: p.count / f.offered }));
}

/** What a group's label means on screen; the page turns it into words */
export type InboundGroupDisplay =
  | { kind: "date"; date: DateKey }
  | { kind: "text"; text: string }
  | { kind: "hour"; hour: string }
  | { kind: "unknownMarket" }
  | { kind: "unknownLine" };

export function inboundGroupDisplay(row: Pick<InboundServiceRow, "groupKey" | "groupLabel">, group: InboundGroup): InboundGroupDisplay {
  switch (group) {
    case "day": return { kind: "date", date: row.groupKey };
    case "market": return row.groupKey === "unknown" ? { kind: "unknownMarket" } : { kind: "text", text: row.groupKey };
    case "line": return row.groupLabel ? { kind: "text", text: row.groupLabel } : { kind: "unknownLine" };
    case "hour": return { kind: "hour", hour: row.groupKey };
  }
}

/** Seconds to answer: "17 s" under a minute, "1m 05s" from a minute, a dash for none */
export function fmtAnswerSeconds(seconds: number | null, locale: string): string {
  if (seconds === null) return "–";
  if (seconds < 59.5) return `${new Intl.NumberFormat(intlLocale[locale] ?? locale, { maximumFractionDigits: 0 }).format(seconds)} s`;
  const s = Math.round(seconds);
  return `${Math.floor(s / 60)}m ${String(s % 60).padStart(2, "0")}s`;
}

/**
 * What no inbound answer may hold (brief B15: no number, no name, never the hash): a key that names a
 * hash, a phone, an email, digits, a caller or a contact, a key with "name" other than a line's, a
 * string of 64 hex characters (a hash) or an E.164 number. Answers the paths it found. Since addition
 * 0008j the Calls answers are checked the same way with `calls`: a tag's name and a person's own name
 * (the organisation's staff, never a customer) are allowed, and a call id, a source id or a telephony
 * user id is not.
 */
export function personalDataIn(value: unknown, path = "$", calls = false): string[] {
  if (typeof value === "string") {
    return /^[0-9a-f]{64}$/i.test(value) || /^\+[1-9][0-9]{6,14}$/.test(value.replace(/[\s().-]/g, "")) ? [path] : [];
  }
  if (Array.isArray(value)) return value.flatMap((v, i) => personalDataIn(v, `${path}[${i}]`, calls));
  if (value && typeof value === "object") {
    const names = calls ? ["lineName", "tagName", "name"] : ["lineName"];
    return Object.entries(value).flatMap(([k, v]) => {
      const bad = /hash|phone|e164|email|digits|counterpart|caller|contact/i.test(k) || (/name/i.test(k) && !names.includes(k))
        || (calls && /^(callId|sourceId|userRef|user_ref|call_id|source_id)$/.test(k));
      return [...(bad ? [`${path}.${k}`] : []), ...personalDataIn(v, `${path}.${k}`, calls)];
    });
  }
  return [];
}

// ---- Calls overview and calls per agent (addition 0008j, brief B16) -----------------------------
//
// The figures come from the database (cma.calls_overview, cma.calls_tag_use, cma.calls_per_person,
// cma.calls_per_person_tags); the functions below mirror its definitions for the mock and for
// verify/reports.mjs, and arrange the rows for the two screens. Talk time runs from the answer to the
// end (no ringing, unlike the telephony system's duration); an outbound call is connected from
// telephony.connected_min_seconds of talk time; a conversation is an answered inbound or a connected
// outbound call; untagged is a conversation without any current tag. No call here carries a number, a
// customer's name, a call id or a telephony user id on screen, and never the caller's hash.

export const CALLS_GROUPS: readonly CallsGroup[] = ["day", "week", "market", "line"];

/** The group named in a query, or null when it is none of the four */
export function parseCallsGroup(value: unknown): CallsGroup | null {
  return typeof value === "string" && (CALLS_GROUPS as readonly string[]).includes(value) ? (value as CallsGroup) : null;
}

/** The group G moves to: day, week, market, line, then day again */
export function nextCallsGroup(group: CallsGroup): CallsGroup {
  return CALLS_GROUPS[(CALLS_GROUPS.indexOf(group) + 1) % CALLS_GROUPS.length]!;
}

/** Calls per agent: the per-person reads need performance.team, here and in the database (README Decision log, 14 October 2026) */
export const PER_AGENT_PERMISSION = "performance.team";

const LINE_KEY = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:.{0,100}$/;

/**
 * The market and line filters from a query, as cma.calls_filters_check takes them: a market is a
 * two-letter code or "unknown", a line a connection id ':' line ref; empty means all. `problem` names
 * a value the database would refuse; that filter is then left out.
 */
export function parseCallsFilter(market: unknown, line: unknown): { filter: CallsFilter; problem: null | "market" | "line" } {
  const m = typeof market === "string" && market !== "" ? market : null;
  const l = typeof line === "string" && line !== "" ? line : null;
  const badMarket = m !== null && !/^([A-Z]{2}|unknown)$/.test(m);
  const badLine = l !== null && !LINE_KEY.test(l);
  return {
    filter: { market: badMarket ? null : m, line: badLine ? null : l },
    problem: badMarket ? "market" : badLine ? "line" : null,
  };
}

/** The query values of a filter, only the ones set */
export function filterQuery(filter: CallsFilter): Record<string, string> {
  return { ...(filter.market ? { market: filter.market } : {}), ...(filter.line ? { line: filter.line } : {}) };
}

/** A tag of a telephony connection's catalog, as the fixture and the verifier hold it */
export interface CallTagFixture {
  connectionId: string;
  tagRef: string;
  name: string;
  isCounted: boolean;
}

/** One call as cma.calls_of gives it: no call id, no hash, no number */
export interface CallRecord {
  connectionId: string;
  sourceSystem: string;
  direction: "inbound" | "outbound";
  lineKey: string;
  lineName: string | null;
  market: string;
  /** The zone of the line's market, else the tenant's: the date and the time of day are in it */
  zone: string;
  date: DateKey;
  /** The Monday of the date's ISO week */
  weekStart: DateKey;
  /** The time of day in the call's zone, "HH:MM:SS" */
  localTime: string;
  userRef: string | null;
  isAnsweredInbound: boolean;
  isConnectedOutbound: boolean;
  isConversation: boolean;
  talkSeconds: number | null;
  tagRefs: string[];
  isTagged: boolean;
}

const timeFormatters = new Map<string, Intl.DateTimeFormat>();

/** "HH:MM:SS" of an instant in a zone */
export function timeInZone(instant: Instant, timeZone: string): string {
  let f = timeFormatters.get(timeZone);
  if (!f) {
    f = new Intl.DateTimeFormat("en-GB", { timeZone, hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23" });
    timeFormatters.set(timeZone, f);
  }
  return f.format(new Date(instant));
}

/**
 * The calls of a fixture as cma.calls_of classifies them: not deleted, with a start, on a counted line (a
 * line not in the catalog counts), either direction; the date and time in the line's market zone, else
 * the tenant's; talk time in whole seconds from the answer to the end; then narrowed by the filter
 */
export function callRecords(
  calls: readonly TelephonyCallFixture[], lines: readonly InboundLine[], tenantZone: string, connectedMinSeconds: number,
  filter: CallsFilter = { market: null, line: null },
): CallRecord[] {
  const min = Math.max(0, connectedMinSeconds);
  const out: CallRecord[] = [];
  for (const c of calls) {
    if (c.deleted || !c.startedAt) continue;
    const line = lines.find((l) => l.connectionId === c.connectionId && l.lineRef === c.lineRef);
    if (line && !line.isCounted) continue;
    const zone = line?.zone ?? tenantZone;
    const talk = c.answeredAt !== null && c.endedAt !== null ? Math.max(0, Math.floor((Date.parse(c.endedAt) - Date.parse(c.answeredAt)) / 1000)) : null;
    const answeredIn = c.direction === "inbound" && c.answeredAt !== null;
    const connectedOut = c.direction === "outbound" && talk !== null && talk >= min;
    const tagRefs = [...new Set(c.tagRefs ?? [])].sort();
    const date = dateKeyInZone(c.startedAt, zone);
    const r: CallRecord = {
      connectionId: c.connectionId, sourceSystem: c.sourceSystem, direction: c.direction,
      lineKey: `${c.connectionId}:${c.lineRef ?? ""}`, lineName: line?.name ?? c.lineRef, market: line?.market ?? "unknown", zone,
      date, weekStart: startOfWeek(date), localTime: timeInZone(c.startedAt, zone), userRef: c.userRef ?? null,
      isAnsweredInbound: answeredIn, isConnectedOutbound: connectedOut, isConversation: answeredIn || connectedOut,
      talkSeconds: talk, tagRefs, isTagged: tagRefs.length > 0,
    };
    if (filter.market !== null && r.market !== filter.market) continue;
    if (filter.line !== null && r.lineKey !== filter.line) continue;
    out.push(r);
  }
  return out;
}

const sum = (xs: number[]) => xs.reduce((a, b) => a + b, 0);
const avg1 = (xs: number[]) => (xs.length === 0 ? null : round1(sum(xs) / xs.length));

/** The figures of a set of calls, as cma.calls_figures_of computes them */
export function callsFigures(calls: readonly CallRecord[]): CallsFigures {
  const outbound = calls.filter((c) => c.direction === "outbound").length;
  const connected = calls.filter((c) => c.isConnectedOutbound);
  const talk = calls.filter((c) => c.isConversation && c.talkSeconds !== null).map((c) => c.talkSeconds!);
  const outTalk = connected.map((c) => c.talkSeconds!);
  return {
    calls: calls.length,
    inbound: calls.filter((c) => c.direction === "inbound").length,
    outbound,
    answeredInbound: calls.filter((c) => c.isAnsweredInbound).length,
    connectedOutbound: connected.length,
    connectedPct: outbound === 0 ? null : round1((100 * connected.length) / outbound),
    conversations: calls.filter((c) => c.isConversation).length,
    talkSeconds: sum(talk),
    talkAvgSeconds: avg1(talk),
    outboundTalkSeconds: sum(outTalk),
    outboundTalkAvgSeconds: avg1(outTalk),
    untaggedConversations: calls.filter((c) => c.isConversation && !c.isTagged).length,
  };
}

/** A call's group key and label, as cma.calls_figures_of groups */
function callsGroupOf(c: CallRecord, group: CallsGroup): [string, string | null] {
  switch (group) {
    case "day": return [c.date, c.date];
    case "week": return [c.weekStart, c.weekStart];
    case "market": return [c.market, c.market];
    case "line": return [c.lineKey, c.lineName ?? "unknown"];
  }
}

function inPeriod<T extends { date: DateKey }>(calls: readonly T[], from: DateKey, to: DateKey): T[] {
  return calls.filter((c) => c.date >= from && c.date <= to);
}

/** Groups in the database's order: lines by name, the others by key */
function groupOrder(group: CallsGroup) {
  return (a: { groupKey: string | null; groupLabel: string | null }, b: { groupKey: string | null; groupLabel: string | null }) =>
    (group === "line" ? (a.groupLabel ?? "").localeCompare(b.groupLabel ?? "") : 0) || byCode(a.groupKey ?? "", b.groupKey ?? "");
}

/** The calls of business dates from..to grouped as cma.calls_overview groups them, with the total over every call */
export function groupCalls(calls: readonly CallRecord[], from: DateKey, to: DateKey, group: CallsGroup): { rows: CallsRow[]; total: CallsFigures } {
  const period = inPeriod(calls, from, to);
  const groups = new Map<string, { label: string | null; calls: CallRecord[] }>();
  for (const c of period) {
    const [key, label] = callsGroupOf(c, group);
    const g = groups.get(key) ?? { label, calls: [] };
    g.calls.push(c);
    groups.set(key, g);
  }
  const rows = [...groups.entries()].map(([groupKey, g]) => ({ groupKey, groupLabel: g.label, ...callsFigures(g.calls) })).sort(groupOrder(group));
  return { rows, total: callsFigures(period) };
}

/** The previous period the deltas compare with: its dates, and whether it is cut to the same point */
export interface PreviousPeriod extends HoursRange {
  /** The period reaches today: the previous one holds the same elapsed dates, the last up to the time of day */
  partial: boolean;
}

/**
 * The previous period, like for like, as cma.calls_overview_of picks it (README Decision log, 14 October
 * 2026): it starts as many dates before `from` as the period holds. A period that ended before today
 * compares with the whole previous equal period, ending the day before `from`; one that reaches today
 * with the same elapsed span (its dates up to today, shifted back by the period's length), and on that
 * span's last date only up to the time of day (previousCalls). A period that starts after today has no
 * elapsed date, so `to` falls before `from` and it compares with nothing. `today` is in the zone the page
 * resolves its period in.
 */
export function previousPeriod(range: HoursRange, today: DateKey): PreviousPeriod {
  const days = daysBetween(range.from, range.to) + 1;
  const partial = range.to >= today;
  return { from: addDays(range.from, -days), to: addDays(partial ? today : range.to, -days), partial };
}

/**
 * The start of the telephony history, as cma.telephony_history_start_of gives it (addition 0008k): the
 * earliest business date of the calls, each in its line's zone; the calls as callRecords classifies
 * them (deleted calls, calls without a start and calls on a line that does not count are not among
 * them) and without a filter, since the history start is tenant-wide. Null without a call
 */
export function historyStartOf(calls: readonly CallRecord[]): DateKey | null {
  return calls.reduce<DateKey | null>((first, c) => (first === null || c.date < first ? c.date : first), null);
}

/**
 * Whether the previous span starts before the telephony history (README Decision log, 14 October 2026,
 * brief B16.1): the span then holds dates without data, so a change against it means nothing (prod's
 * This month read "↑ 358,900 %" against a month before the first call), and every tile says "No history
 * to compare yet" instead. A span that starts on the history's first date or later compares as before;
 * without a history start (no call stored yet) the changes show as before too
 */
export function previousBeforeHistory(previousFrom: DateKey, historyStart: DateKey | null): boolean {
  return historyStart !== null && previousFrom < historyStart;
}

/**
 * The calls of the previous period, as cma.calls_figures_of counts them for the deltas: its dates, and
 * when it is cut, on its last date only the calls up to `now`'s time of day in each call's own zone
 */
export function previousCalls(calls: readonly CallRecord[], prev: PreviousPeriod, now: Instant): CallRecord[] {
  return inPeriod(calls, prev.from, prev.to).filter((c) => !prev.partial || c.date < prev.to || c.localTime <= timeInZone(now, c.zone));
}

/**
 * Conversations per group and current tag, as cma.calls_tag_use: any tag, counted or not (with the
 * catalog's name and switch), tagKey null for the untagged ones; a conversation with two tags counts
 * under each. Within a group the most used tag first, untagged last; then the whole period (groupKey null)
 */
export function callsTagUse(calls: readonly CallRecord[], from: DateKey, to: DateKey, group: CallsGroup, tags: readonly CallTagFixture[]): TagUseRow[] {
  const conversations = inPeriod(calls, from, to).filter((c) => c.isConversation);
  const tagOf = (connectionId: string, ref: string) => tags.find((t) => t.connectionId === connectionId && t.tagRef === ref);
  const count = (list: CallRecord[], groupKey: string | null, groupLabel: string | null): TagUseRow[] => {
    const n = new Map<string | null, { name: string | null; isCounted: boolean | null; n: number }>();
    for (const c of list) {
      for (const ref of c.isTagged ? c.tagRefs : [null]) {
        const key = ref === null ? null : `${c.connectionId}:${ref}`;
        const t = ref === null ? null : tagOf(c.connectionId, ref);
        const e = n.get(key) ?? { name: ref === null ? null : (t?.name ?? ref), isCounted: ref === null ? null : (t?.isCounted ?? true), n: 0 };
        e.n++;
        n.set(key, e);
      }
    }
    return [...n.entries()]
      .map(([tagKey, e]) => ({ groupKey, groupLabel, tagKey, tagName: e.name, isCounted: e.isCounted, conversations: e.n }))
      .sort((a, b) => Number(a.tagKey === null) - Number(b.tagKey === null) || b.conversations - a.conversations
        || (a.tagName ?? "").localeCompare(b.tagName ?? "") || byCode(a.tagKey ?? "", b.tagKey ?? ""));
  };
  const groups = new Map<string, { label: string | null; calls: CallRecord[] }>();
  for (const c of conversations) {
    const [key, label] = callsGroupOf(c, group);
    const g = groups.get(key) ?? { label, calls: [] };
    g.calls.push(c);
    groups.set(key, g);
  }
  const ordered = [...groups.entries()].map(([groupKey, g]) => ({ groupKey, groupLabel: g.label, calls: g.calls })).sort(groupOrder(group));
  return [...ordered.flatMap((g) => count(g.calls, g.groupKey, g.groupLabel)), ...count(conversations, null, null)];
}

/** Who a telephony user is: the person linked to `<source system>_user` with the user's id, or null */
export type PersonOf = (sourceSystem: string, userRef: string | null) => { userId: string; name: string } | null;

/** A person's calls, as cma.calls_people_of: their answered inbound and their outbound calls of the period */
function peopleCalls(calls: readonly CallRecord[], from: DateKey, to: DateKey, personOf: PersonOf) {
  return inPeriod(calls, from, to)
    .filter((c) => c.isAnsweredInbound || c.direction === "outbound")
    .map((c) => ({ c, p: personOf(c.sourceSystem, c.userRef) }));
}

const hhmm = (t: string | undefined) => (t === undefined ? null : t.slice(0, 5));

function personFigures(kind: CallsPerson["kind"], userId: string | null, name: string | null, calls: CallRecord[]): CallsPerson {
  const inbound = calls.filter((c) => c.isAnsweredInbound);
  const outbound = calls.filter((c) => c.direction === "outbound");
  const connected = outbound.filter((c) => c.isConnectedOutbound);
  const inTalk = inbound.filter((c) => c.talkSeconds !== null).map((c) => c.talkSeconds!);
  const outTalk = connected.map((c) => c.talkSeconds!);
  const times = calls.map((c) => c.localTime).sort();
  return {
    kind, userId, name,
    unlinkedUsers: kind === "notLinked" ? new Set(calls.map((c) => c.userRef).filter((u) => u !== null)).size : null,
    answeredInbound: inbound.length,
    inboundTalkSeconds: sum(inTalk),
    inboundTalkAvgSeconds: avg1(inTalk),
    outboundCalls: outbound.length,
    connectedOutbound: connected.length,
    outboundTalkSeconds: sum(outTalk),
    outboundTalkAvgSeconds: avg1(outTalk),
    conversations: calls.filter((c) => c.isConversation).length,
    untaggedConversations: calls.filter((c) => c.isConversation && !c.isTagged).length,
    firstCallTime: hhmm(times[0]),
    lastCallTime: hhmm(times[times.length - 1]),
  };
}

/**
 * The figures per person as cma.calls_per_person: the people by name (never ranked), then the calls of
 * telephony users without a person as one row with their count, then the total over every call
 */
export function callsPerPerson(calls: readonly CallRecord[], from: DateKey, to: DateKey, personOf: PersonOf): { rows: CallsPerson[]; total: CallsPerson } {
  const list = peopleCalls(calls, from, to, personOf);
  const people = new Map<string, { name: string; calls: CallRecord[] }>();
  const unlinked: CallRecord[] = [];
  for (const { c, p } of list) {
    if (!p) { unlinked.push(c); continue; }
    const e = people.get(p.userId) ?? { name: p.name, calls: [] };
    e.calls.push(c);
    people.set(p.userId, e);
  }
  const rows = [...people.entries()]
    .map(([userId, e]) => personFigures("person", userId, e.name, e.calls))
    .sort((a, b) => (a.name ?? "").localeCompare(b.name ?? "") || byCode(a.userId ?? "", b.userId ?? ""));
  if (unlinked.length > 0) rows.push(personFigures("notLinked", null, null, unlinked));
  return { rows, total: personFigures("total", null, null, list.map((x) => x.c)) };
}

/**
 * Per person (and the not-linked calls) the conversations per counted tag, then their untagged
 * conversations, as cma.calls_per_person_tags; a tag that does not count is left out, and still makes
 * its conversation tagged
 */
export function callsPerPersonTags(
  calls: readonly CallRecord[], from: DateKey, to: DateKey, personOf: PersonOf, tags: readonly CallTagFixture[],
): CallsPersonTag[] {
  const list = peopleCalls(calls, from, to, personOf).filter((x) => x.c.isConversation);
  const owners = new Map<string, { kind: CallsPersonTag["kind"]; userId: string | null; name: string | null; calls: CallRecord[] }>();
  for (const { c, p } of list) {
    const k = p ? p.userId : "";
    const e = owners.get(k) ?? { kind: p ? "person" : "notLinked", userId: p?.userId ?? null, name: p?.name ?? null, calls: [] };
    e.calls.push(c);
    owners.set(k, e);
  }
  const ordered = [...owners.values()].sort((a, b) =>
    Number(a.kind === "notLinked") - Number(b.kind === "notLinked") || (a.name ?? "").localeCompare(b.name ?? "") || byCode(a.userId ?? "", b.userId ?? ""));
  return ordered.flatMap((o) => {
    const n = new Map<string, { name: string; n: number }>();
    for (const c of o.calls) {
      for (const ref of c.tagRefs) {
        const t = tags.find((x) => x.connectionId === c.connectionId && x.tagRef === ref);
        if (t && !t.isCounted) continue;
        const key = `${c.connectionId}:${ref}`;
        const e = n.get(key) ?? { name: t?.name ?? ref, n: 0 };
        e.n++;
        n.set(key, e);
      }
    }
    const tagged = [...n.entries()]
      .map(([tagKey, e]) => ({ kind: o.kind, userId: o.userId, tagKey, tagName: e.name, conversations: e.n }))
      .sort((a, b) => b.conversations - a.conversations || a.tagName.localeCompare(b.tagName) || byCode(a.tagKey, b.tagKey));
    return [...tagged, { kind: o.kind, userId: o.userId, tagKey: null, tagName: null, conversations: o.calls.filter((c) => !c.isTagged).length }];
  });
}

// The screens ------------------------------------------------------------------------------------

/**
 * Inbound and outbound in the style's series order (docs/style/Pulse4all-Style.md 7.7): Deep Blue, then
 * Leaf Green; the conversations and the untagged ones on Calls per agent in the third, Light Blue. A
 * counted tag's bar is Deep Blue, a tag that does not count Neutral, Other Light Blue; no text sits on a
 * Light Blue bar (7.8). Never the error red: a volume is no verdict.
 */
export const INBOUND_CLASS = "bg-p4a-deepblue";
export const OUTBOUND_CLASS = "bg-p4a-green";
export const CONVERSATION_CLASS = "bg-p4a-lightblue";
export const TAG_CLASS = "bg-p4a-deepblue";
export const TAG_NOT_COUNTED_CLASS = "bg-p4a-muted";
export const OTHER_TAGS_CLASS = "bg-p4a-lightblue";
export const UNTAGGED_CLASS = "bg-p4a-lightblue";

/**
 * A figure against the previous equal period: up, down or the same, with the change in percent (one
 * decimal; null when the previous figure was 0 and this one is not, "new"); "none" without both figures.
 * A volume's change is neither good nor bad, so the screen shows it in Muted (style 7.7 colours a delta
 * only when its direction has a meaning)
 */
export function callsDelta(current: number | null, previous: number | null): { direction: "up" | "down" | "same" | "none"; pct: number | null } {
  if (current === null || previous === null) return { direction: "none", pct: null };
  if (current === previous) return { direction: "same", pct: 0 };
  return { direction: current > previous ? "up" : "down", pct: previous === 0 ? null : round1((100 * Math.abs(current - previous)) / previous) };
}

/**
 * What a tile says against the previous period: "noHistory" when that span starts before the telephony
 * history (previousBeforeHistory: no change at all, whatever the figures), else the change as callsDelta
 * gives it
 */
export function callsChange(current: number | null, previous: number | null, previousFrom: DateKey, historyStart: DateKey | null):
  { direction: "up" | "down" | "same" | "none" | "noHistory"; pct: number | null } {
  return previousBeforeHistory(previousFrom, historyStart) ? { direction: "noHistory", pct: null } : callsDelta(current, previous);
}

/** Untagged conversations as a share of the conversations, 0 to 100; null without one */
export function untaggedPct(f: Pick<CallsFigures, "conversations" | "untaggedConversations">): number | null {
  return f.conversations === 0 ? null : round1((100 * f.untaggedConversations) / f.conversations);
}

/** A group without calls, for the chart's axis */
const NO_CALLS: CallsFigures = {
  calls: 0, inbound: 0, outbound: 0, answeredInbound: 0, connectedOutbound: 0, connectedPct: null, conversations: 0, talkSeconds: 0,
  talkAvgSeconds: null, outboundTalkSeconds: 0, outboundTalkAvgSeconds: null, untaggedConversations: 0,
};

/**
 * The chart's groups: by day every date of the period up to `last` (today), by week every week's Monday,
 * a group without calls at 0, so the axis has no gaps; markets and lines as they are
 */
export function chartGroups(rows: readonly CallsRow[], group: CallsGroup, from: DateKey, to: DateKey, last: DateKey): CallsRow[] {
  if (group !== "day" && group !== "week") return [...rows];
  const end = to < last ? to : last;
  const keys: DateKey[] = [];
  for (let d = group === "day" ? from : startOfWeek(from); d <= end; d = addDays(d, group === "day" ? 1 : 7)) keys.push(d);
  const known = new Map(rows.map((r) => [r.groupKey, r]));
  return [...keys.map((k) => known.get(k) ?? { groupKey: k, groupLabel: k, ...NO_CALLS }), ...rows.filter((r) => !keys.includes(r.groupKey))]
    .sort((a, b) => byCode(a.groupKey, b.groupKey));
}

/** Each group's inbound and outbound calls as shares of the busiest group, for the stacked bars */
export function callsBars(rows: readonly CallsRow[]): { key: string; inbound: number; outbound: number }[] {
  const largest = Math.max(0, ...rows.map((r) => r.calls));
  return rows.map((r) => ({ key: r.groupKey, inbound: largest === 0 ? 0 : r.inbound / largest, outbound: largest === 0 ? 0 : r.outbound / largest }));
}

/** At most this many tags get a bar or a column of their own; the rest are added up as Other */
export const TOP_TAGS = 12;

export interface TagBar {
  key: string;
  name: string;
  isCounted: boolean;
  count: number;
  /** Of the conversations, 0 to 1; null without one */
  share: number | null;
  /** Of the longest bar, 0 to 1 */
  length: number;
}

/**
 * The whole period's tags as horizontal bars, largest first (then by name), the first TOP_TAGS on
 * their own and the rest added up as Other with how many tags it holds
 */
export function topTags(rows: readonly TagUseRow[], conversations: number, n = TOP_TAGS): { bars: TagBar[]; other: (TagBar & { tags: number }) | null } {
  const tags = rows.filter((r) => r.groupKey === null && r.tagKey !== null)
    .sort((a, b) => b.conversations - a.conversations || (a.tagName ?? "").localeCompare(b.tagName ?? "") || byCode(a.tagKey!, b.tagKey!));
  const top = tags.slice(0, n);
  const rest = tags.slice(n);
  const otherCount = sum(rest.map((r) => r.conversations));
  const longest = Math.max(0, ...top.map((r) => r.conversations), otherCount);
  const share = (x: number) => (conversations === 0 ? null : x / conversations);
  const length = (x: number) => (longest === 0 ? 0 : x / longest);
  return {
    bars: top.map((r) => ({ key: r.tagKey!, name: r.tagName ?? r.tagKey!, isCounted: r.isCounted !== false, count: r.conversations, share: share(r.conversations), length: length(r.conversations) })),
    other: rest.length === 0 ? null : { key: "other", name: "", isCounted: true, count: otherCount, share: share(otherCount), length: length(otherCount), tags: rest.length },
  };
}

export interface TagCell {
  count: number;
  /** Of the group's conversations, 0 to 1; null without one */
  share: number | null;
}

/**
 * The groups by tags: the whole period's top TOP_TAGS tags as columns (as `topTags`), Other for the rest,
 * then the untagged conversations; one line per group of the overview, in its order, with counts and
 * shares of the group's conversations
 */
export function tagTable(rows: readonly TagUseRow[], groups: readonly CallsRow[], n = TOP_TAGS): {
  columns: { key: string; name: string; isCounted: boolean }[];
  hasOther: boolean;
  lines: { groupKey: string; groupLabel: string | null; conversations: number; cells: TagCell[]; other: TagCell; untagged: TagCell }[];
} {
  const { bars, other } = topTags(rows, 0, n);
  const columns = bars.map((b) => ({ key: b.key, name: b.name, isCounted: b.isCounted }));
  const shown = new Set(columns.map((c) => c.key));
  const cell = (count: number, of: number): TagCell => ({ count, share: of === 0 ? null : count / of });
  return {
    columns,
    hasOther: other !== null,
    lines: groups.map((g) => {
      const mine = rows.filter((r) => r.groupKey === g.groupKey);
      const countOf = (key: string | null) => mine.find((r) => r.tagKey === key)?.conversations ?? 0;
      return {
        groupKey: g.groupKey, groupLabel: g.groupLabel, conversations: g.conversations,
        cells: columns.map((c) => cell(countOf(c.key), g.conversations)),
        other: cell(sum(mine.filter((r) => r.tagKey !== null && !shown.has(r.tagKey)).map((r) => r.conversations)), g.conversations),
        untagged: cell(countOf(null), g.conversations),
      };
    }),
  };
}

/** The columns of Calls per agent that carry an inline bar, each scaled to its column's largest value */
export const PER_AGENT_BARS = [
  "answeredInbound", "inboundTalkSeconds", "inboundTalkAvgSeconds", "outboundCalls", "connectedOutbound", "outboundTalkSeconds",
  "outboundTalkAvgSeconds", "untaggedConversations",
] as const;
export type PerAgentBar = (typeof PER_AGENT_BARS)[number];

/** The bar colour of each column: inbound Deep Blue, outbound Leaf Green, the untagged conversations Light Blue (series order, 7.7) */
export const PER_AGENT_BAR_CLASS: Record<PerAgentBar, string> = {
  answeredInbound: INBOUND_CLASS, inboundTalkSeconds: INBOUND_CLASS, inboundTalkAvgSeconds: INBOUND_CLASS,
  outboundCalls: OUTBOUND_CLASS, connectedOutbound: OUTBOUND_CLASS, outboundTalkSeconds: OUTBOUND_CLASS, outboundTalkAvgSeconds: OUTBOUND_CLASS,
  untaggedConversations: CONVERSATION_CLASS,
};

/** Each column's largest value over the people and the not-linked row (the total row is not a person) */
export function columnMaxima(rows: readonly CallsPerson[]): Record<PerAgentBar, number> {
  const out = {} as Record<PerAgentBar, number>;
  for (const k of PER_AGENT_BARS) out[k] = Math.max(0, ...rows.filter((r) => r.kind !== "total").map((r) => r[k] ?? 0));
  return out;
}

/** A value as a share of its column's largest, 0 to 1 */
export function barShare(value: number | null, largest: number): number {
  return value === null || largest <= 0 ? 0 : Math.min(1, value / largest);
}

/**
 * One person's (or the not-linked calls') split by counted tag: each tag with its count and its share of
 * their conversations, in the database's order, the untagged ones last
 */
export function personSplit(tags: readonly CallsPersonTag[], person: Pick<CallsPerson, "kind" | "userId" | "conversations">): {
  key: string | null; name: string | null; count: number; share: number | null; length: number;
}[] {
  const mine = tags.filter((t) => (person.kind === "notLinked" ? t.kind === "notLinked" : t.kind === "person" && t.userId === person.userId));
  const longest = Math.max(0, ...mine.map((t) => t.conversations));
  return mine.map((t) => ({
    key: t.tagKey, name: t.tagName, count: t.conversations,
    share: person.conversations === 0 ? null : t.conversations / person.conversations,
    length: longest === 0 ? 0 : t.conversations / longest,
  }));
}

/** A row's identity on screen: a person's name, Not linked, or the total */
export function personKey(p: Pick<CallsPerson, "kind" | "userId">): string {
  return p.kind === "person" ? `person:${p.userId}` : p.kind;
}

/** A count axis with at most five steps of 1, 2 or 5 times a power of ten, for the calls chart */
export function countAxis(largest: number): { top: number; step: number } {
  if (!(largest > 0)) return { top: 4, step: 1 };
  for (let mag = 1; ; mag *= 10) {
    for (const s of [1, 2, 5]) {
      const step = s * mag;
      if (Math.ceil(largest / step) <= 5) return { top: Math.ceil(largest / step) * step, step };
    }
  }
}

/** The ISO week number of a week's Monday, for the week groups */
export function weekNumber(monday: DateKey): number {
  return isoWeek(monday);
}

/** Talk time: "45 s" under a minute, "3m 05s" under an hour, "2h 05m" from an hour, a dash for none */
export function fmtTalk(seconds: number | null, locale: string): string {
  if (seconds === null) return "–";
  const s = Math.round(seconds);
  if (s < 60) return `${new Intl.NumberFormat(intlLocale[locale] ?? locale, { maximumFractionDigits: 0 }).format(s)} s`;
  if (s < 3600) return `${Math.floor(s / 60)}m ${String(s % 60).padStart(2, "0")}s`;
  return fmtMinutes(Math.floor(s / 60));
}

/** A share of 0 to 1 in whole percents with the locale; "< 1%" for a small share that is not zero, a dash for none */
export function fmtShare(share: number | null, locale: string): string {
  return share === null ? "–" : fmtPct(round1(share * 100), locale);
}

// ---- Header hints ------------------------------------------------------------------------------

/** The speed-to-lead target in whole business minutes, from the rows (the tenant's setting); null without rows */
export function targetMinutesOf(rows: Pick<SpeedToLeadRow, "targetSeconds">[]): number | null {
  const s = rows.find((x) => x.targetSeconds !== null)?.targetSeconds;
  return s === null || s === undefined ? null : Math.round(s / 60);
}

/**
 * A header hint's text with its values filled in: {hours} the office hours (per market, tenant
 * configuration), {target} the speed-to-lead target, and since 0008i {seconds} the service level's
 * seconds, {days} the callback lookback and {minutes} the longest a call counts as waiting, and since
 * 0008j {threshold} the seconds of talk time from which an outbound call is connected, each from the
 * tenant's settings and a dash when unknown. The copy never holds any of these values.
 */
export function fillHint(
  text: string,
  values: { hours: string; target?: number | null; seconds?: number | null; days?: number | null; minutes?: number | null; threshold?: number | null; warning?: number | null },
  locale: string,
): string {
  const num = (x: number | null | undefined) => (x === null || x === undefined ? "–" : fmtCount(x, locale));
  // {warning}: the share of the response time from which a ticket is at risk (Follow-up, 0008o)
  return text.replaceAll("{hours}", values.hours).replaceAll("{target}", num(values.target))
    .replaceAll("{seconds}", num(values.seconds)).replaceAll("{days}", num(values.days)).replaceAll("{minutes}", num(values.minutes))
    .replaceAll("{threshold}", num(values.threshold)).replaceAll("{warning}", num(values.warning));
}

// ---- Forms (addition 0008p; brief B17d, 16 October 2026) -------------------------------------------

export const FORMS_GROUPS: readonly FormsGroup[] = ["day", "week"];

export function parseFormsGroup(value: unknown): FormsGroup | null {
  return typeof value === "string" && (FORMS_GROUPS as readonly string[]).includes(value) ? (value as FormsGroup) : null;
}

export function nextFormsGroup(group: FormsGroup): FormsGroup {
  return FORMS_GROUPS[(FORMS_GROUPS.indexOf(group) + 1) % FORMS_GROUPS.length]!;
}

const FORM_KEY = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:.{1,100}$/;
const CATEGORY_CODE = /^[a-z][a-z0-9_]{0,39}$/;
const FIELD_NAME = /^[A-Za-z0-9_.-]{1,100}$/;

/**
 * The report's filters from a query, as cma.forms_filters_check takes them: a market is a two-letter code
 * or "unknown", a category a category code or "none" (forms without one), a form a connection id ':' form
 * id; empty means all. `problem` names a value the database would refuse; that filter is then left out.
 */
export function parseFormsFilter(market: unknown, category: unknown, form: unknown): { filter: FormsFilter; problem: null | "market" | "category" | "form" } {
  const text = (v: unknown) => (typeof v === "string" && v !== "" ? v : null);
  const m = text(market);
  const c = text(category);
  const f = text(form);
  const badMarket = m !== null && !/^([A-Z]{2}|unknown)$/.test(m);
  const badCategory = c !== null && !CATEGORY_CODE.test(c);
  const badForm = f !== null && !FORM_KEY.test(f);
  return {
    filter: { market: badMarket ? null : m, category: badCategory ? null : c, form: badForm ? null : f },
    problem: badMarket ? "market" : badCategory ? "category" : badForm ? "form" : null,
  };
}

/** The answers' field and value filters from a query: a field name and a value of 1 to 200 characters; a malformed one left out */
export function parseAnswerFilter(field: unknown, value: unknown): { field: string | null; value: string | null; problem: boolean } {
  const f = typeof field === "string" && field !== "" ? field : null;
  const v = typeof value === "string" && value !== "" ? value : null;
  const badField = f !== null && !FIELD_NAME.test(f);
  const badValue = v !== null && v.length > 200;
  return { field: badField ? null : f, value: badField || badValue ? null : v, problem: badField || badValue };
}

/** The query values of the forms filter, only the ones set */
export function formsFilterQuery(filter: FormsFilter): Record<string, string> {
  return {
    ...(filter.market ? { market: filter.market } : {}),
    ...(filter.category ? { category: filter.category } : {}),
    ...(filter.form ? { form: filter.form } : {}),
  };
}

/**
 * A stored submission as cma.form_submissions_of gives it (the mock's fixture, the verifier): its form,
 * category, market (the form's, else the market field's answer, else the contact's country, else unknown),
 * zone, business date, ISO week and time of day there, the contact resolution and the kept answers
 * (option values; a multiple-checkboxes answer as a list)
 */
export interface FormSubmissionRecord {
  formKey: string;
  formName: string;
  category: string | null;
  market: string;
  zone: string;
  date: DateKey;
  localTime: string;
  resolution: "resolved" | "not_found" | "ambiguous" | "no_email" | "pending";
  answers: Record<string, string | string[]>;
}

const NO_SUBMISSIONS: FormsResolution & { submissions: number } = { submissions: 0, resolved: 0, notFound: 0, ambiguous: 0, noEmail: 0, pending: 0 };

function addSubmission(acc: FormsResolution & { submissions: number }, r: Pick<FormSubmissionRecord, "resolution">): void {
  acc.submissions += 1;
  if (r.resolution === "resolved") acc.resolved += 1;
  else if (r.resolution === "not_found") acc.notFound += 1;
  else if (r.resolution === "ambiguous") acc.ambiguous += 1;
  else if (r.resolution === "no_email") acc.noEmail += 1;
  else acc.pending += 1;
}

/** Whether a record passes the filters, as cma.forms_figures_of narrows before counting */
function formsFilterPasses(r: FormSubmissionRecord, filter: FormsFilter): boolean {
  return (filter.market === null || r.market === filter.market)
    && (filter.category === null || (r.category ?? "none") === filter.category)
    && (filter.form === null || r.formKey === filter.form);
}

/**
 * The submissions of the business dates [from, to] per day or ISO week, form and market, then the period's
 * totals per form and market (groupKey null), as cma.forms_figures_of. With `until` (the previous span of a
 * period that reaches today) the submissions of `to` count only up to its time of day in each one's zone
 */
export function formsFigures(records: readonly FormSubmissionRecord[], from: DateKey, to: DateKey, group: FormsGroup, filter: FormsFilter,
  until: Instant | null = null): FormsRow[] {
  const groups = new Map<string, FormsRow>();
  const totals = new Map<string, FormsRow>();
  const rowOf = (map: Map<string, FormsRow>, key: string, groupKey: DateKey | null, r: FormSubmissionRecord) => {
    let row = map.get(key);
    if (!row) map.set(key, row = { groupKey, formKey: r.formKey, formName: r.formName, category: r.category, market: r.market, ...NO_SUBMISSIONS });
    return row;
  };
  for (const r of records) {
    if (r.date < from || r.date > to || !formsFilterPasses(r, filter)) continue;
    if (until !== null && r.date === to && r.localTime > timeInZone(until, r.zone)) continue;
    const g = group === "week" ? startOfWeek(r.date) : r.date;
    addSubmission(rowOf(groups, `${g}|${r.formKey}|${r.market}`, g, r), r);
    addSubmission(rowOf(totals, `${r.formKey}|${r.market}`, null, r), r);
  }
  const order = (a: FormsRow, b: FormsRow) => byCode(a.groupKey ?? "", b.groupKey ?? "") || byCode(a.formName, b.formName)
    || byCode(a.formKey, b.formKey) || byCode(a.market, b.market);
  return [...[...groups.values()].sort(order), ...[...totals.values()].sort(order)];
}

/** The previous period's totals per form and market, like for like (previousPeriod), as cma.forms_report_of */
export function previousForms(records: readonly FormSubmissionRecord[], prev: PreviousPeriod, filter: FormsFilter, now: Instant): FormsRow[] {
  return formsFigures(records, prev.from, prev.to, "day", filter, prev.partial ? now : null).filter((r) => r.groupKey === null);
}

/** The answers per form, market, field and value over the dates (and a cut last date, as previousForms), as cma.forms_answers_of */
export function formsAnswersOf(records: readonly FormSubmissionRecord[], from: DateKey, to: DateKey, filter: FormsFilter, field: string | null,
  value: string | null, period: FormAnswerRow["period"], until: Instant | null = null): FormAnswerRow[] {
  const out = new Map<string, FormAnswerRow>();
  for (const r of records) {
    if (r.date < from || r.date > to || !formsFilterPasses(r, filter)) continue;
    if (until !== null && r.date === to && r.localTime > timeInZone(until, r.zone)) continue;
    for (const [f, answer] of Object.entries(r.answers)) {
      if (field !== null && f !== field) continue;
      for (const v of Array.isArray(answer) ? answer : [answer]) {
        if (value !== null && v !== value) continue;
        const key = `${r.formKey}|${r.market}|${f}|${v}`;
        const row = out.get(key) ?? { period, formKey: r.formKey, formName: r.formName, category: r.category, market: r.market, field: f, value: v, submissions: 0 };
        row.submissions += 1;
        out.set(key, row);
      }
    }
  }
  return [...out.values()].sort((a, b) => byCode(a.formName, b.formName) || byCode(a.formKey, b.formKey) || byCode(a.market, b.market)
    || byCode(a.field, b.field) || b.submissions - a.submissions || byCode(a.value, b.value));
}

/** The earliest business date of the records, as cma.forms_history_start (tenant-wide, no filter); null without one */
export function formsHistoryStart(records: readonly FormSubmissionRecord[]): DateKey | null {
  return records.reduce<DateKey | null>((first, r) => (first === null || r.date < first ? r.date : first), null);
}

/** The submissions and their resolution summed over rows (counts add up, unlike shares) */
export function formsSum(rows: readonly (FormsResolution & { submissions: number })[]): FormsResolution & { submissions: number } {
  const acc = { ...NO_SUBMISSIONS };
  for (const r of rows) {
    acc.submissions += r.submissions;
    acc.resolved += r.resolved;
    acc.notFound += r.notFound;
    acc.ambiguous += r.ambiguous;
    acc.noEmail += r.noEmail;
    acc.pending += r.pending;
  }
  return acc;
}

/** The share of the submissions whose contact was found (0 to 1), null without a submission */
export function resolvedShare(sum: FormsResolution & { submissions: number }): number | null {
  return sum.submissions === 0 ? null : sum.resolved / sum.submissions;
}

/** A form in a market with the period's and the previous period's submissions, for the table and the file */
export interface FormsLine extends FormsResolution {
  formKey: string;
  formName: string;
  category: string | null;
  market: string;
  submissions: number;
  previous: number;
}

/**
 * The table's lines: every form and market with submissions in the period or the previous one, the period's
 * figures and the previous period's submissions, by form name, then market (unknown last)
 */
export function formsLines(totals: readonly FormsRow[], previous: readonly FormsRow[]): FormsLine[] {
  const lines = new Map<string, FormsLine>();
  for (const r of totals) {
    lines.set(`${r.formKey}|${r.market}`, { formKey: r.formKey, formName: r.formName, category: r.category, market: r.market, submissions: r.submissions,
      resolved: r.resolved, notFound: r.notFound, ambiguous: r.ambiguous, noEmail: r.noEmail, pending: r.pending, previous: 0 });
  }
  for (const r of previous) {
    const key = `${r.formKey}|${r.market}`;
    const line = lines.get(key) ?? { formKey: r.formKey, formName: r.formName, category: r.category, market: r.market, ...NO_SUBMISSIONS, previous: 0 };
    line.previous += r.submissions;
    lines.set(key, line);
  }
  return [...lines.values()].sort((a, b) => byCode(a.formName, b.formName) || byCode(a.formKey, b.formKey) || byMarket(a.market, b.market));
}

/** Market codes in order, "unknown" last */
function byMarket(a: string, b: string): number {
  return a === b ? 0 : a === "unknown" ? 1 : b === "unknown" ? -1 : byCode(a, b);
}

/** Totals per category: in the catalog's order, a code the catalog lacks after them, forms without a category last */
export function formsByCategory(lines: readonly FormsLine[], categories: readonly FormCategory[]):
  { code: string | null; name: string | null; submissions: number; previous: number }[] {
  const out = new Map<string | null, { code: string | null; name: string | null; submissions: number; previous: number }>();
  for (const l of lines) {
    const t = out.get(l.category) ?? { code: l.category, name: categories.find((c) => c.code === l.category)?.name ?? null, submissions: 0, previous: 0 };
    t.submissions += l.submissions;
    t.previous += l.previous;
    out.set(l.category, t);
  }
  const rank = (code: string | null) => (code === null ? Number.MAX_SAFE_INTEGER : categories.find((c) => c.code === code)?.sortOrder ?? Number.MAX_SAFE_INTEGER - 1);
  return [...out.values()].sort((a, b) => rank(a.code) - rank(b.code) || byCode(a.code ?? "", b.code ?? ""));
}

/** Totals per market, by code, unknown last */
export function formsByMarket(lines: readonly FormsLine[]): { market: string; submissions: number; previous: number }[] {
  const out = new Map<string, { market: string; submissions: number; previous: number }>();
  for (const l of lines) {
    const t = out.get(l.market) ?? { market: l.market, submissions: 0, previous: 0 };
    t.submissions += l.submissions;
    t.previous += l.previous;
    out.set(l.market, t);
  }
  return [...out.values()].sort((a, b) => byMarket(a.market, b.market));
}

/**
 * The chart's columns: the submissions per day (every date of the period up to `last`, today) or per ISO
 * week (every week's Monday), a column without submissions at 0, so the axis has no gaps
 */
export function formsSeries(rows: readonly FormsRow[], group: FormsGroup, from: DateKey, to: DateKey, last: DateKey): { key: DateKey; submissions: number }[] {
  const end = to < last ? to : last;
  const sums = new Map<string, number>();
  for (const r of rows) if (r.groupKey !== null) sums.set(r.groupKey, (sums.get(r.groupKey) ?? 0) + r.submissions);
  const keys: DateKey[] = [];
  for (let d = group === "day" ? from : startOfWeek(from); d <= end; d = addDays(d, group === "day" ? 1 : 7)) keys.push(d);
  for (const k of sums.keys()) if (!keys.includes(k)) keys.push(k);
  return keys.sort(byCode).map((key) => ({ key, submissions: sums.get(key) ?? 0 }));
}

/**
 * The table's forms: each form with its period's and previous period's submissions over its markets, then
 * its lines per market as formsLines orders them
 */
export function formsTableGroups(lines: readonly FormsLine[]): {
  formKey: string; formName: string; category: string | null; total: FormsLine; markets: FormsLine[];
}[] {
  const out = new Map<string, { formKey: string; formName: string; category: string | null; total: FormsLine; markets: FormsLine[] }>();
  for (const l of lines) {
    const g = out.get(l.formKey) ?? { formKey: l.formKey, formName: l.formName, category: l.category,
      total: { ...l, market: "", ...NO_SUBMISSIONS, previous: 0 }, markets: [] };
    g.markets.push(l);
    g.total.submissions += l.submissions;
    g.total.previous += l.previous;
    g.total.resolved += l.resolved;
    g.total.notFound += l.notFound;
    g.total.ambiguous += l.ambiguous;
    g.total.noEmail += l.noEmail;
    g.total.pending += l.pending;
    out.set(l.formKey, g);
  }
  return [...out.values()];
}

/**
 * The answers arranged per form (its markets summed; the market filter narrows them), then per field, each
 * value with the period's and the previous period's submissions, most answered first
 */
export function answerGroups(rows: readonly FormAnswerRow[]): {
  formKey: string; formName: string;
  fields: { field: string; values: { value: string; submissions: number; previous: number }[] }[];
}[] {
  const forms = new Map<string, { formKey: string; formName: string; fields: Map<string, Map<string, { value: string; submissions: number; previous: number }>> }>();
  for (const r of rows) {
    const f = forms.get(r.formKey) ?? { formKey: r.formKey, formName: r.formName, fields: new Map() };
    const values = f.fields.get(r.field) ?? new Map();
    const v = values.get(r.value) ?? { value: r.value, submissions: 0, previous: 0 };
    if (r.period === "current") v.submissions += r.submissions;
    else v.previous += r.submissions;
    values.set(r.value, v);
    f.fields.set(r.field, values);
    forms.set(r.formKey, f);
  }
  return [...forms.values()]
    .sort((a, b) => byCode(a.formName, b.formName) || byCode(a.formKey, b.formKey))
    .map((f) => ({
      formKey: f.formKey, formName: f.formName,
      fields: [...f.fields.entries()].sort(([a], [b]) => byCode(a, b)).map(([field, values]) => ({
        field,
        values: [...values.values()].sort((a, b) => b.submissions - a.submissions || b.previous - a.previous || byCode(a.value, b.value)),
      })),
    }));
}
