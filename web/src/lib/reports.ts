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
  DataQualityCheck, DateKey, InboundFigures, InboundGroup, InboundServiceRow, Instant, IntakeDay, MissedReason, SourceConnections,
  SpeedToLeadGroup, SpeedToLeadRow, SpeedToLeadSummaryRow,
} from "./data/types";
import { dateKeyInZone, daysBetween, fmtMinutes, hourInZone } from "./time.ts";

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
 * B15.1, 14 October 2026). Never the error red or the warning amber: a reason is a category, not a
 * verdict. No text sits on a Light Blue or Soft Rose segment (7.8); the segments carry none, the label is
 * in the column header and the legend. Answered calls are Leaf Green next to them.
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

/**
 * One column per reason that occurs in the rows, the most frequent first (then by code), labelled from
 * the catalog: a code means the same in every telephony system of a tenant, and the first source
 * system's row gives its label; without a row the code is its own label ("unknown" as `unknownLabel`)
 */
export function reasonColumns(rows: readonly Pick<InboundFigures, "unansweredByReason">[], catalog: readonly MissedReason[], unknownLabel: string): ReasonColumn[] {
  const totals = new Map<string, number>();
  for (const r of rows) for (const [code, n] of Object.entries(r.unansweredByReason)) if (n > 0) totals.set(code, (totals.get(code) ?? 0) + n);
  const sorted = [...catalog].sort((a, b) => a.sourceSystem.localeCompare(b.sourceSystem) || a.code.localeCompare(b.code));
  return [...totals.entries()]
    .sort(([a, x], [b, y]) => y - x || (a < b ? -1 : a > b ? 1 : 0))
    .map(([code, total], i) => {
      const row = sorted.find((r) => r.code === code);
      return {
        code, total, className: REASON_SERIES[i % REASON_SERIES.length]!,
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
 * string of 64 hex characters (a hash) or an E.164 number. Answers the paths it found.
 */
export function personalDataIn(value: unknown, path = "$"): string[] {
  if (typeof value === "string") {
    return /^[0-9a-f]{64}$/i.test(value) || /^\+[1-9][0-9]{6,14}$/.test(value.replace(/[\s().-]/g, "")) ? [path] : [];
  }
  if (Array.isArray(value)) return value.flatMap((v, i) => personalDataIn(v, `${path}[${i}]`));
  if (value && typeof value === "object") {
    return Object.entries(value).flatMap(([k, v]) => {
      const bad = /hash|phone|e164|email|digits|counterpart|caller|contact/i.test(k) || (/name/i.test(k) && k !== "lineName");
      return [...(bad ? [`${path}.${k}`] : []), ...personalDataIn(v, `${path}.${k}`)];
    });
  }
  return [];
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
 * seconds, {days} the callback lookback and {minutes} the longest a call counts as waiting, each from
 * the tenant's settings and a dash when unknown. The copy never holds any of these values.
 */
export function fillHint(
  text: string,
  values: { hours: string; target?: number | null; seconds?: number | null; days?: number | null; minutes?: number | null },
  locale: string,
): string {
  const num = (x: number | null | undefined) => (x === null || x === undefined ? "–" : fmtCount(x, locale));
  return text.replaceAll("{hours}", values.hours).replaceAll("{target}", num(values.target))
    .replaceAll("{seconds}", num(values.seconds)).replaceAll("{days}", num(values.days)).replaceAll("{minutes}", num(values.minutes));
}
