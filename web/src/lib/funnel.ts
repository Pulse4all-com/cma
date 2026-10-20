/**
 * Funnel, lost reasons and cancellations (addition 0008zb, 20 October 2026; backlog CMA-043, CMA-048, CMA-049 without
 * CCL): Reports → Funnel and Reports → Cancellations, Kira's KPIs 4 and 5. How the sales deals move through their stages,
 * why they are lost, and how many cancellation requests come in per market. The figures come from the database
 * (cma.deal_funnel_page, cma.lost_reasons_page, cma.cancellations_page, cma.deals_per_person_page); this module mirrors
 * their definitions for the mock and for verify/reports.mjs, and arranges the rows for the screens. Pure, with no runtime
 * imports beyond time.ts and reports.ts, so the verifier runs it under Node's type stripping.
 *
 * The definitions (README, Data model: reasons, kinds and the funnel), one place in the database (98_funnel.sql):
 *   deal          0008z's sales deal: a counted lead pipeline that is no order pipeline, not deleted, created on or after
 *                 intake.start_date; its creation and close as business dates and times in the tenant's zone
 *   won, lost     the current stage's outcome, by the close's business date; the win rate won over won and lost
 *   entered       a deal whose stage entry (its latest, HubSpot's calculated stage property) falls in the period, of a
 *                 stage that reads times; still there when the deal's current stage is the stage, moved on otherwise
 *   days in stage of the deals that moved on, from the entry to the exit (an exit after the entry)
 *   lost reason   the option's internal value of the mapped enumeration property: real, data quality (a person's flag in
 *                 the catalog: the lead was never a lead) or none (KPI 11)
 *   cancellation  a ticket of the kind reports.cancellation_kind names, matched by an active rule of a pipeline, a
 *                 category value or both, of a counted pipeline, created on or after intake.start_date. It counts the
 *                 request (the ticket), never the contract: the shop and the subscription system own the contract
 * Ids, codes, counts, links and times only: no name, address, phone number or free text of a customer exists here.
 */
import type {
  CancellationFigures, CancellationListRow, CancellationsReport, DateKey, DealPerson, DealPersonFigures, FunnelFigures, FunnelFilter,
  FunnelGroup, FunnelLists, FunnelPipelineRow, FunnelReport, FunnelStageRow, Instant, LostFigures, LostGroupRow, LostListRow, LostPeriodRow,
  LostReasonRow, LostReasonsReport, ReasonState, RecordKind,
} from "./data/types";
import type { Copy } from "./copy";
// With their extensions, so verify/reports.mjs can run this module under Node's type stripping
import { percentileCont, round1, timeInZone } from "./reports.ts";
import { addDays, dateKeyInZone, startOfWeek } from "./time.ts";

export const FUNNEL_GROUPS: readonly FunnelGroup[] = ["week", "day"];

export function parseFunnelGroup(value: unknown): FunnelGroup | null {
  return typeof value === "string" && (FUNNEL_GROUPS as readonly string[]).includes(value) ? (value as FunnelGroup) : null;
}

export function nextFunnelGroup(group: FunnelGroup): FunnelGroup {
  return FUNNEL_GROUPS[(FUNNEL_GROUPS.indexOf(group) + 1) % FUNNEL_GROUPS.length]!;
}

/** Deals per person: performance.team, and the tenant's reports.per_person holding deals (cma.assert_per_person) */
export const DEALS_PER_PERSON_PERMISSION = "performance.team";
export const DEALS_PER_PERSON_KEY = "deals";

const PIPELINE_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[^\s:]{1,100}$/;

export type FunnelFilterProblem = null | "market" | "pipeline" | "source";

/**
 * The filters from a query, as cma.funnel_filters_check takes them: a market is a two-letter code or "unknown", a
 * pipeline a connection id and a pipeline id joined by ':', a source channel 1 to 100 characters without control
 * characters; empty means all. `problem` names a value the database would refuse; that filter is then left out
 */
export function parseFunnelFilter(market: unknown, pipeline: unknown, source: unknown): { filter: FunnelFilter; problem: FunnelFilterProblem } {
  const filter: FunnelFilter = { market: null, pipeline: null, sourceChannel: null };
  let problem: FunnelFilterProblem = null;
  const text = (v: unknown) => (typeof v === "string" && v.trim() !== "" ? v.trim() : null);
  const m = text(market);
  if (m !== null) {
    if (/^([A-Z]{2}|unknown)$/.test(m)) filter.market = m;
    else problem = "market";
  }
  const p = text(pipeline);
  if (p !== null) {
    if (PIPELINE_RE.test(p)) filter.pipeline = p;
    else problem ??= "pipeline";
  }
  const s = text(source);
  if (s !== null) {
    if (s.length <= 100 && !/[\u0000-\u001f\u007f]/.test(s)) filter.sourceChannel = s;
    else problem ??= "source";
  }
  return { filter, problem };
}

/** The filter as query parameters (keys market, pipeline, source); the empty ones left out */
export function funnelFilterQuery(filter: FunnelFilter): Record<string, string> {
  const out: Record<string, string> = {};
  if (filter.market) out.market = filter.market;
  if (filter.pipeline) out.pipeline = filter.pipeline;
  if (filter.sourceChannel) out.source = filter.sourceChannel;
  return out;
}

// ---- The mock's fixture and the definitions -----------------------------------------------------------

/** A deal stage as the catalog holds it (connection_stage, 0008u and 0008za) */
export interface FunnelStageFixture {
  stageId: string;
  label: string;
  order: number;
  isClosed: boolean;
  outcome: "won" | "lost" | null;
  /** A person's choice (connection_stage.read_times); null: the pipeline's counted flag decides */
  readTimes: boolean | null;
  isActive: boolean;
}

/** A deal pipeline as the catalog holds it (connection_pipeline) */
export interface FunnelPipelineFixture {
  connectionId: string;
  pipelineId: string;
  label: string;
  isCounted: boolean;
  isLead: boolean;
  isOrder: boolean;
  isActive: boolean;
  stages: FunnelStageFixture[];
}

/** One deal's stored entry and exit of a stage (crm_record_stage, 0008za) */
export interface FunnelStageTime {
  stageId: string;
  enteredAt: Instant | null;
  exitedAt: Instant | null;
}

/** One deal as the mock or a verifier holds it */
export interface FunnelDealFixture {
  dealId: string;
  connectionId: string;
  dealSourceId: string;
  pipelineId: string;
  stageId: string | null;
  /** 0007d's market ("unknown" when none) */
  market: string;
  sourceChannel: string | null;
  /** The stored option value (crm_record.reason) */
  reason: string | null;
  ownerRef: string | null;
  createdAt: Instant;
  closedAt: Instant | null;
  isClosed: boolean;
  amount: number | null;
  /** The deal's own currency; null: its market's */
  currency: string | null;
  recordUrl: string | null;
  stages: FunnelStageTime[];
}

/** A sales deal as cma.funnel_deals_of gives it (cma.funnel_deal) */
export interface FunnelDeal {
  dealId: string;
  connectionId: string;
  dealSourceId: string;
  pipelineId: string;
  pipelineLabel: string;
  stageId: string | null;
  market: string;
  sourceChannel: string | null;
  reason: string | null;
  ownerRef: string | null;
  ownerUserId: string | null;
  createdAt: Instant;
  createdDate: DateKey;
  createdTime: string;
  closedAt: Instant | null;
  closedDate: DateKey | null;
  closedTime: string | null;
  /** The current stage's outcome while the deal is closed */
  stageOutcome: "won" | "lost" | null;
  amount: number | null;
  currency: string | null;
  recordUrl: string | null;
  stages: FunnelStageTime[];
}

/** What the definitions read besides the deals, as the mock or a verifier has them */
export interface FunnelOptions {
  tenantZone: string;
  /** intake.start_date */
  startDate: DateKey;
  now: Instant;
  ownerUserOf: (ownerRef: string | null) => string | null;
  /** A market's currency (cma.market.currency); null for an unknown market */
  currencyOf: (market: string) => string | null;
}

/** The previous span the deltas compare with (cma.forms_previous_of): its dates and, while the period runs, the instant its last date is cut at */
export interface FunnelPrevious {
  from: DateKey;
  to: DateKey;
  until: Instant | null;
}

/** A reason option of the tenant by value (cma.deal_reasons_of): the label and the data-quality flag */
export interface FunnelReasonOption {
  value: string;
  label: string;
  isDataQuality: boolean;
  sortOrder: number;
}

const pipeKey = (connectionId: string, pipelineId: string) => `${connectionId}:${pipelineId}`;
const cmp = (a: string, b: string) => a.localeCompare(b);
/** round(x, 4) as numeric rounds a share (0 to 1) */
const round4 = (x: number) => Math.round(x * 10_000 + 1e-9) / 10_000;
const share4 = (part: number, whole: number) => (whole === 0 ? null : round4(part / whole));
const days = (from: Instant, to: Instant) => (Date.parse(to) - Date.parse(from)) / 86_400_000;
const median1 = (values: number[]) => {
  const m = percentileCont(values, 0.5);
  return m === null ? null : round1(m);
};

/** Whether a business date and time lie in [from, to], the last date cut at `untilTime` (cma.in_period) */
export function inPeriod(date: DateKey, time: string, from: DateKey, to: DateKey, untilTime: string | null): boolean {
  return date >= from && date <= to && (untilTime === null || date < to || time <= untilTime);
}

/** The read_times in force for a stage (cma.read_times_of): a person's choice, else on for a counted pipeline's stage */
export function readTimesOf(readTimes: boolean | null, pipelineCounted: boolean | null): boolean {
  return readTimes ?? pipelineCounted ?? true;
}

/** The sales deals as cma.funnel_deals_of gives them, as of `now` */
export function funnelDeals(deals: readonly FunnelDealFixture[], pipelines: readonly FunnelPipelineFixture[], o: FunnelOptions): FunnelDeal[] {
  const now = Date.parse(o.now);
  const pipe = new Map(pipelines.map((p) => [pipeKey(p.connectionId, p.pipelineId), p]));
  return deals.flatMap((d): FunnelDeal[] => {
    const p = pipe.get(pipeKey(d.connectionId, d.pipelineId));
    if (!p || !p.isCounted || !p.isLead || p.isOrder) return [];
    const createdDate = dateKeyInZone(d.createdAt, o.tenantZone);
    if (createdDate < o.startDate || Date.parse(d.createdAt) > now) return [];
    const stage = p.stages.find((s) => s.stageId === d.stageId);
    return [{
      dealId: d.dealId, connectionId: d.connectionId, dealSourceId: d.dealSourceId, pipelineId: d.pipelineId, pipelineLabel: p.label, stageId: d.stageId,
      market: d.market, sourceChannel: d.sourceChannel, reason: d.reason, ownerRef: d.ownerRef, ownerUserId: o.ownerUserOf(d.ownerRef),
      createdAt: d.createdAt, createdDate, createdTime: timeInZone(d.createdAt, o.tenantZone), closedAt: d.closedAt,
      closedDate: d.closedAt ? dateKeyInZone(d.closedAt, o.tenantZone) : null, closedTime: d.closedAt ? timeInZone(d.closedAt, o.tenantZone) : null,
      stageOutcome: d.isClosed ? stage?.outcome ?? null : null, amount: d.amount, currency: d.currency ?? o.currencyOf(d.market), recordUrl: d.recordUrl,
      stages: d.stages,
    }];
  });
}

/** The deals the filters keep (cma.funnel_filter) */
export function funnelFilter(rows: readonly FunnelDeal[], filter: FunnelFilter): FunnelDeal[] {
  return rows.filter((r) => (filter.pipeline === null || pipeKey(r.connectionId, r.pipelineId) === filter.pipeline)
    && (filter.market === null || r.market === filter.market)
    && (filter.sourceChannel === null || r.sourceChannel === filter.sourceChannel));
}

/** The filter lists from the deals without the filters (cma.funnel_filter_lists_from) */
export function funnelLists(rows: readonly FunnelDeal[]): FunnelLists {
  const markets = [...new Set(rows.map((r) => r.market))].sort((a, b) => (a === "unknown" ? 1 : b === "unknown" ? -1 : cmp(a, b)));
  const pipes = new Map<string, string>();
  for (const r of rows) {
    const k = pipeKey(r.connectionId, r.pipelineId);
    const label = pipes.get(k);
    if (label === undefined || r.pipelineLabel > label) pipes.set(k, r.pipelineLabel);
  }
  return {
    markets,
    pipelines: [...pipes.entries()].map(([key, label]) => ({ key, label })).sort((a, b) => cmp(a.label, b.label) || cmp(a.key, b.key)),
    sourceChannels: [...new Set(rows.flatMap((r) => (r.sourceChannel === null ? [] : [r.sourceChannel])))].sort(cmp),
  };
}

const untilTimeOf = (prev: FunnelPrevious, zone: string) => (prev.until === null ? null : timeInZone(prev.until, zone));

/** The figures of a set of deals in [from, to], the last date cut at `untilTime` (cma.funnel_figures_from) */
export function funnelFigures(rows: readonly FunnelDeal[], from: DateKey, to: DateKey, untilTime: string | null): FunnelFigures {
  const closedIn = rows.filter((r) => r.closedDate !== null && inPeriod(r.closedDate, r.closedTime!, from, to, untilTime));
  const won = closedIn.filter((r) => r.stageOutcome === "won");
  const lost = closedIn.filter((r) => r.stageOutcome === "lost");
  return {
    created: rows.filter((r) => inPeriod(r.createdDate, r.createdTime, from, to, untilTime)).length,
    won: won.length, lost: lost.length, winRate: share4(won.length, won.length + lost.length),
    medianDaysToWon: median1(won.map((r) => days(r.createdAt, r.closedAt!))), medianDaysToLost: median1(lost.map((r) => days(r.createdAt, r.closedAt!))),
  };
}

/** Per pipeline (by label) and in total, the period and the previous span (cma.funnel_pipelines_from) */
export function funnelPipelines(rows: readonly FunnelDeal[], from: DateKey, to: DateKey, prev: FunnelPrevious, zone: string): FunnelReport["byPipeline"] {
  const until = untilTimeOf(prev, zone);
  const groups = new Map<string, { label: string; rows: FunnelDeal[] }>();
  for (const r of rows) {
    const k = pipeKey(r.connectionId, r.pipelineId);
    const g = groups.get(k) ?? { label: r.pipelineLabel, rows: [] };
    if (r.pipelineLabel > g.label) g.label = r.pipelineLabel;
    g.rows.push(r);
    groups.set(k, g);
  }
  const rowsOut: FunnelPipelineRow[] = [...groups.entries()].sort((a, b) => cmp(a[1].label, b[1].label) || cmp(a[0], b[0]))
    .map(([key, g]) => ({ key, label: g.label, current: funnelFigures(g.rows, from, to, null), previous: funnelFigures(g.rows, prev.from, prev.to, until) }));
  return { rows: rowsOut, total: { current: funnelFigures(rows, from, to, null), previous: funnelFigures(rows, prev.from, prev.to, until) } };
}

/**
 * Per stage of the deals' pipelines and of every active counted lead pipeline that is no order pipeline (one pipeline with
 * a pipeline filter), in the pipeline's order (cma.funnel_stages_of)
 */
export function funnelStages(rows: readonly FunnelDeal[], pipelines: readonly FunnelPipelineFixture[], pipelineFilter: string | null,
  from: DateKey, to: DateKey, prev: FunnelPrevious, zone: string): FunnelStageRow[] {
  const until = untilTimeOf(prev, zone);
  const lo = from < prev.from ? from : prev.from;
  const has = new Set(rows.map((r) => pipeKey(r.connectionId, r.pipelineId)));
  const pl = pipelines.filter((p) => ((p.isActive && p.isCounted && p.isLead && !p.isOrder) || has.has(pipeKey(p.connectionId, p.pipelineId)))
    && (pipelineFilter === null || pipeKey(p.connectionId, p.pipelineId) === pipelineFilter));
  // the entries from the earlier first date to the period's last, each with its deal's current stage and outcome
  const entries = rows.flatMap((d) => d.stages.flatMap((s) => {
    if (s.enteredAt === null) return [];
    const date = dateKeyInZone(s.enteredAt, zone);
    if (date < lo || date > to) return [];
    return [{ connectionId: d.connectionId, stageId: s.stageId, enteredAt: s.enteredAt, exitedAt: s.exitedAt, date, time: timeInZone(s.enteredAt, zone),
      current: d.stageId, outcome: d.stageOutcome }];
  }));
  const st = pl.flatMap((p) => p.stages.filter((s) => s.isActive).map((s) => ({ p, s, reads: readTimesOf(s.readTimes, p.isCounted) })))
    .sort((a, b) => cmp(a.p.label, b.p.label) || cmp(a.p.connectionId, b.p.connectionId) || a.s.order - b.s.order || cmp(a.s.label, b.s.label)
      || cmp(a.s.stageId, b.s.stageId));
  return st.map(({ p, s, reads }) => {
    const mine = entries.filter((e) => e.connectionId === p.connectionId && e.stageId === s.stageId);
    const cur = mine.filter((e) => inPeriod(e.date, e.time, from, to, null));
    const moved = cur.filter((e) => e.current !== e.stageId);
    const timed = moved.filter((e) => e.exitedAt !== null && Date.parse(e.exitedAt) >= Date.parse(e.enteredAt));
    const spans = timed.map((e) => days(e.enteredAt, e.exitedAt!));
    const won = cur.filter((e) => e.outcome === "won").length;
    const figure = (x: number | null) => (reads ? x : null);
    return {
      pipeline: pipeKey(p.connectionId, p.pipelineId), pipelineLabel: p.label, stageId: s.stageId, label: s.label, order: s.order, isClosed: s.isClosed,
      outcome: s.outcome, readsTimes: reads, entered: figure(cur.length), stillThere: figure(cur.length - moved.length), movedOn: figure(moved.length),
      timed: figure(timed.length), medianDays: figure(median1(spans)), reachedWon: figure(won),
      wonShare: figure(share4(won, cur.length)),
      enteredPrevious: figure(mine.filter((e) => inPeriod(e.date, e.time, prev.from, prev.to, until)).length),
    };
  });
}

/** When the histories start (cma.funnel_history_start_of): the deals' (the later of the start date and the first deal) and the stage times' */
export function funnelHistoryStart(all: readonly FunnelDeal[], startDate: DateKey, stageEntries: readonly Instant[], zone: string): FunnelReport["historyStart"] {
  const first = all.reduce<DateKey | null>((m, r) => (m === null || r.createdDate < m ? r.createdDate : m), null);
  const entry = stageEntries.reduce<Instant | null>((m, x) => (m === null || Date.parse(x) < Date.parse(m) ? x : m), null);
  return { deals: first === null || first < startDate ? startDate : first, stages: entry === null ? null : dateKeyInZone(entry, zone) };
}

/** The deal stages that read times (the page's timed_stages): every active deal stage of the catalog with read_times in force */
export function timedStages(pipelines: readonly FunnelPipelineFixture[]): number {
  return pipelines.reduce((n, p) => n + p.stages.filter((s) => s.isActive && readTimesOf(s.readTimes, p.isCounted)).length, 0);
}

/** The funnel page as cma.deal_funnel_page_of answers it */
export function funnelReport(all: readonly FunnelDeal[], pipelines: readonly FunnelPipelineFixture[], o: FunnelOptions, from: DateKey, to: DateKey,
  filter: FunnelFilter, prev: FunnelPrevious, stageEntries: readonly Instant[]): FunnelReport {
  const rows = funnelFilter(all, filter);
  return {
    from, to, filter, stages: funnelStages(rows, pipelines, filter.pipeline, from, to, prev, o.tenantZone),
    byPipeline: funnelPipelines(rows, from, to, prev, o.tenantZone), previousFrom: prev.from, previousTo: prev.to, previousPartial: prev.until !== null,
    historyStart: funnelHistoryStart(all, o.startDate, stageEntries, o.tenantZone), timedStages: timedStages(pipelines), ...funnelLists(all),
  };
}

// ---- Lost reasons -----------------------------------------------------------------------------------------

/** The lost deals of a set in [from, to], the last date cut at `untilTime`, by the close's business date (cma.funnel_lost_in) */
export function lostIn(rows: readonly FunnelDeal[], from: DateKey, to: DateKey, untilTime: string | null): FunnelDeal[] {
  return rows.filter((r) => r.stageOutcome === "lost" && r.closedDate !== null && inPeriod(r.closedDate, r.closedTime!, from, to, untilTime))
    .sort((a, b) => cmp(a.closedAt!, b.closedAt!) || cmp(a.dealId, b.dealId));
}

type ReasonKind = "real" | "data_quality" | "none";
const kindOf = (reason: string | null, options: ReadonlyMap<string, FunnelReasonOption>): ReasonKind =>
  reason === null ? "none" : options.get(reason)?.isDataQuality ? "data_quality" : "real";

/** The figures of a set of lost deals (cma.lost_figures_from) */
export function lostFigures(rows: readonly FunnelDeal[], options: readonly FunnelReasonOption[]): LostFigures {
  const o = new Map(options.map((x) => [x.value, x]));
  const k = rows.map((r) => kindOf(r.reason, o));
  return {
    lost: rows.length, withReason: k.filter((x) => x !== "none").length, noReason: k.filter((x) => x === "none").length,
    dataQuality: k.filter((x) => x === "data_quality").length, real: k.filter((x) => x === "real").length,
  };
}

/** The lost deals of the period per reason, market, source channel and day or ISO week, and the list without a reason (cma.lost_reasons_from) */
export function lostReasons(rows: readonly FunnelDeal[], options: readonly FunnelReasonOption[], group: FunnelGroup, limit: number):
  Pick<LostReasonsReport, "reasons" | "dataQualityReasons" | "noReason" | "byMarket" | "bySource" | "byPeriod" | "list"> {
  const o = new Map(options.map((x) => [x.value, x]));
  const k = rows.map((r) => ({ r, kind: kindOf(r.reason, o), label: r.reason === null ? null : o.get(r.reason)?.label ?? r.reason,
    period: group === "week" ? startOfWeek(r.closedDate!) : r.closedDate! }));
  const realN = k.filter((x) => x.kind === "real").length;
  const count = (list: typeof k, kind: ReasonKind) => list.filter((x) => x.kind === kind).length;
  const perReason = (list: typeof k, kind: ReasonKind) => {
    const m = new Map<string, { label: string; deals: number }>();
    for (const x of list.filter((y) => y.kind === kind)) {
      const v = m.get(x.r.reason!) ?? { label: x.label!, deals: 0 };
      v.deals += 1;
      m.set(x.r.reason!, v);
    }
    return [...m.entries()].map(([value, v]) => ({ value, ...v })).sort((a, b) => b.deals - a.deals || cmp(a.label, b.label) || cmp(a.value, b.value));
  };
  const groupRows = (keyOf: (x: (typeof k)[number]) => string | null, order: (a: string | null, b: string | null) => number): LostGroupRow[] => {
    const m = new Map<string | null, typeof k>();
    for (const x of k) m.set(keyOf(x), [...(m.get(keyOf(x)) ?? []), x]);
    return [...m.entries()].sort((a, b) => order(a[0], b[0])).map(([key, list]) => ({
      key, lost: list.length, real: count(list, "real"), noReason: count(list, "none"), dataQuality: count(list, "data_quality"),
      top: perReason(list, "real").slice(0, 3),
    }));
  };
  const periods = new Map<DateKey, typeof k>();
  for (const x of k) periods.set(x.period, [...(periods.get(x.period) ?? []), x]);
  const none = k.filter((x) => x.kind === "none").sort((a, b) => cmp(b.r.closedAt!, a.r.closedAt!) || cmp(a.r.dealSourceId, b.r.dealSourceId));
  return {
    reasons: perReason(k, "real").map((x): LostReasonRow => ({ ...x, share: share4(x.deals, realN) })),
    dataQualityReasons: perReason(k, "data_quality").map((x): LostReasonRow => ({ ...x, share: share4(x.deals, k.length) })),
    noReason: { deals: none.length, share: share4(none.length, k.length) },
    byMarket: groupRows((x) => x.r.market, (a, b) => (a === "unknown" ? 1 : b === "unknown" ? -1 : cmp(a!, b!))),
    bySource: groupRows((x) => x.r.sourceChannel, (a, b) => (a === null ? 1 : b === null ? -1 : cmp(a, b))),
    byPeriod: [...periods.entries()].sort((a, b) => cmp(a[0], b[0])).map(([key, list]): LostPeriodRow => ({
      key, lost: list.length, real: count(list, "real"), noReason: count(list, "none"), dataQuality: count(list, "data_quality"),
      reasons: Object.fromEntries(perReason(list, "real").map((x) => [x.value, x.deals])),
    })),
    list: {
      total: none.length,
      rows: none.slice(0, limit).map(({ r }): LostListRow => ({ dealId: r.dealId, dealSourceId: r.dealSourceId, recordUrl: r.recordUrl, pipelineLabel: r.pipelineLabel,
        market: r.market, createdAt: r.createdAt, closedAt: r.closedAt! })),
    },
  };
}

/** The lost reasons page as cma.lost_reasons_page_of answers it */
export function lostReasonsReport(all: readonly FunnelDeal[], options: readonly FunnelReasonOption[], reasonState: ReasonState, o: FunnelOptions,
  from: DateKey, to: DateKey, group: FunnelGroup, filter: FunnelFilter, prev: FunnelPrevious, limit: number): LostReasonsReport {
  const rows = funnelFilter(all, filter);
  const lost = lostIn(rows, from, to, null);
  return {
    from, to, group, filter, current: lostFigures(lost, options), previous: lostFigures(lostIn(rows, prev.from, prev.to, untilTimeOf(prev, o.tenantZone)), options),
    previousFrom: prev.from, previousTo: prev.to, previousPartial: prev.until !== null, reasonState,
    historyStart: funnelHistoryStart(all, o.startDate, [], o.tenantZone).deals, ...lostReasons(lost, options, group, limit), ...funnelLists(all),
  };
}

/** The state of a reason field from its mapping (cma.reason_state_of) */
export function reasonStateOf(property: string | null, sourceType: string | null): ReasonState {
  return property === null ? "none" : sourceType === null ? "unchecked" : sourceType === "enumeration" ? "enumeration" : "refused";
}

// ---- Cancellations -------------------------------------------------------------------------------------------

/** A ticket as the mock or a verifier holds it, with its market resolved as 0007d's rule gives it ("unknown" when none) */
export interface CancellationTicketFixture {
  recordId: string;
  connectionId: string;
  recordType: "deal" | "ticket";
  sourceId: string;
  pipelineId: string | null;
  pipelineLabel: string | null;
  /** The pipeline counts; null for a pipeline not yet seen, which counts */
  pipelineCounted: boolean | null;
  category: string | null;
  market: string;
  reason: string | null;
  isClosed: boolean;
  createdAt: Instant;
  closedAt: Instant | null;
  deletedAt: Instant | null;
  recordUrl: string | null;
}

/** A kind's rule (connection_record_kind) */
export interface KindRuleFixture {
  connectionId: string;
  kindKey: string;
  pipelineId: string | null;
  category: string | null;
  isActive: boolean;
}

/** Whether a rule matches a record's pipeline and category (cma.kind_rule_matches) */
export function kindRuleMatches(rulePipeline: string | null, ruleCategory: string | null, pipeline: string | null, category: string | null): boolean {
  return (rulePipeline !== null || ruleCategory !== null) && (rulePipeline === null || rulePipeline === pipeline)
    && (ruleCategory === null || ruleCategory === category);
}

/** A record's kinds: the active kinds of its record type with an active rule of its connection that matches it (cma.record_kind_of) */
export function recordKindsOf(kinds: readonly (RecordKind & { sortOrder: number })[], rules: readonly KindRuleFixture[],
  r: Pick<CancellationTicketFixture, "connectionId" | "recordType" | "pipelineId" | "category">): string[] {
  return kinds.filter((k) => k.status === "active" && k.recordType === r.recordType
    && rules.some((x) => x.kindKey === k.key && x.connectionId === r.connectionId && x.isActive && kindRuleMatches(x.pipelineId, x.category, r.pipelineId, r.category)))
    .sort((a, b) => a.sortOrder - b.sortOrder || cmp(a.key, b.key)).map((k) => k.key);
}

/** A request with its business date and time, as cma.cancellations_page_of holds it */
export interface CancellationRecord extends CancellationTicketFixture {
  createdDate: DateKey;
  createdTime: string;
  daysToClose: number | null;
}

/**
 * The requests of the cancellation kind (cma.cancellation_records_of): of an active kind's record type, not deleted, of a
 * counted pipeline, created on or after the start date, matched by an active rule of the kind
 */
export function cancellationRecords(tickets: readonly CancellationTicketFixture[], kind: RecordKind | null, rules: readonly KindRuleFixture[],
  startDate: DateKey, zone: string): CancellationRecord[] {
  if (kind === null || kind.status !== "active") return [];
  return tickets.filter((t) => t.recordType === kind.recordType && t.deletedAt === null && t.pipelineCounted !== false
    && dateKeyInZone(t.createdAt, zone) >= startDate
    && rules.some((x) => x.kindKey === kind.key && x.isActive && x.connectionId === t.connectionId && kindRuleMatches(x.pipelineId, x.category, t.pipelineId, t.category)))
    .map((t) => ({ ...t, pipelineLabel: t.pipelineLabel ?? t.pipelineId, createdDate: dateKeyInZone(t.createdAt, zone), createdTime: timeInZone(t.createdAt, zone),
      daysToClose: t.isClosed && t.closedAt !== null ? Math.round(days(t.createdAt, t.closedAt) * 100 + 1e-9) / 100 : null }))
    .sort((a, b) => cmp(b.createdAt, a.createdAt) || cmp(a.sourceId, b.sourceId));
}

/** The figures of a set of requests in [from, to], the last date cut at `untilTime` (cma.cancellation_figures_from) */
export function cancellationFigures(rows: readonly CancellationRecord[], from: DateKey, to: DateKey, untilTime: string | null): CancellationFigures {
  const inP = rows.filter((r) => inPeriod(r.createdDate, r.createdTime, from, to, untilTime));
  return {
    requests: inP.length, open: inP.filter((r) => !r.isClosed).length, closed: inP.filter((r) => r.isClosed).length,
    medianDaysToClose: median1(inP.flatMap((r) => (r.isClosed && r.daysToClose !== null ? [r.daysToClose] : []))),
  };
}

const marketOrder = (a: string, b: string) => (a === "unknown" ? (b === "unknown" ? 0 : 1) : b === "unknown" ? -1 : cmp(a, b));

/** The cancellations page as cma.cancellations_page_of answers it; `allRequests` every request of the kind, for the history start */
export function cancellationsReport(requests: readonly CancellationRecord[], kind: RecordKind | null, reasonState: ReasonState,
  reasonLabels: ReadonlyMap<string, string>, startDate: DateKey, zone: string, from: DateKey, to: DateKey, group: FunnelGroup, market: string | null,
  prev: FunnelPrevious, limit: number): CancellationsReport {
  const lo = from < prev.from ? from : prev.from;
  const all = requests.filter((r) => r.createdDate >= lo && r.createdDate <= to && (market === null || r.market === market));
  const cur = all.filter((r) => inPeriod(r.createdDate, r.createdTime, from, to, null));
  const by = <K extends string>(list: readonly CancellationRecord[], keyOf: (r: CancellationRecord) => K) => {
    const m = new Map<K, CancellationRecord[]>();
    for (const r of list) m.set(keyOf(r), [...(m.get(keyOf(r)) ?? []), r]);
    return m;
  };
  const reasons = [...by(cur, (r) => r.reason ?? "\u0000").entries()].map(([v, list]) => {
    const value = v === "\u0000" ? null : v;
    return { value, label: value === null ? null : reasonLabels.get(value) ?? value, requests: list.length };
  }).sort((a, b) => (a.value === null ? 1 : 0) - (b.value === null ? 1 : 0) || b.requests - a.requests || cmp(a.label ?? "", b.label ?? "") || cmp(a.value ?? "", b.value ?? ""));
  const first = requests.reduce<DateKey | null>((m, r) => (m === null || r.createdDate < m ? r.createdDate : m), null);
  return {
    from, to, group, market, kind,
    current: cancellationFigures(cur, from, to, null), previous: cancellationFigures(all, prev.from, prev.to, untilTimeOf(prev, zone)),
    previousFrom: prev.from, previousTo: prev.to, previousPartial: prev.until !== null,
    byMarket: [...by(cur, (r) => r.market).entries()].sort((a, b) => marketOrder(a[0], b[0]))
      .map(([m, list]) => ({ ...cancellationFigures(list, from, to, null), market: m })),
    byPeriod: [...by(cur, (r) => `${group === "week" ? startOfWeek(r.createdDate) : r.createdDate}|${r.market}`).entries()]
      .map(([k, list]) => ({ ...cancellationFigures(list, from, to, null), key: k.slice(0, 10), market: k.slice(11) }))
      .sort((a, b) => cmp(a.key, b.key) || marketOrder(a.market, b.market)),
    reasonState: kind === null ? "none" : reasonState, reasons,
    list: {
      total: cur.length,
      rows: cur.slice(0, limit).map((r): CancellationListRow => ({ recordId: r.recordId, sourceId: r.sourceId, recordUrl: r.recordUrl, pipelineLabel: r.pipelineLabel ?? "",
        market: r.market, isClosed: r.isClosed, createdAt: r.createdAt, closedAt: r.closedAt, reason: r.reason })),
    },
    markets: [...new Set(all.map((r) => r.market))].sort(marketOrder),
    historyStart: first === null ? null : first < startDate ? startDate : first,
  };
}

// ---- Deals per person ----------------------------------------------------------------------------------------

/** The figures of a set of decided deals (cma.deal_person_figures_from): the amount won per currency, never summed across */
export function dealPersonFigures(rows: readonly FunnelDeal[]): DealPersonFigures {
  const won = rows.filter((r) => r.stageOutcome === "won");
  const per = new Map<string | null, { amount: number; deals: number }>();
  for (const r of won.filter((x) => x.amount !== null)) {
    const v = per.get(r.currency) ?? { amount: 0, deals: 0 };
    v.amount = Math.round((v.amount + r.amount!) * 100) / 100;
    v.deals += 1;
    per.set(r.currency, v);
  }
  return {
    won: won.length, lost: rows.filter((r) => r.stageOutcome === "lost").length, wonWithoutAmount: won.filter((r) => r.amount === null).length,
    amounts: [...per.entries()].sort((a, b) => (a[0] === null ? 1 : b[0] === null ? -1 : cmp(a[0], b[0]))).map(([currency, v]) => ({ currency, ...v })),
  };
}

/** Deals per person (cma.deals_per_person_of): the deals won or lost in the period per owner by name, never ranked; the not-linked row; the total */
export function dealsPerPerson(rows: readonly FunnelDeal[], from: DateKey, to: DateKey, nameOf: (userId: string) => string | null): { rows: DealPerson[]; total: DealPerson } {
  const cur = rows.filter((r) => (r.stageOutcome === "won" || r.stageOutcome === "lost") && r.closedDate !== null && inPeriod(r.closedDate, r.closedTime!, from, to, null));
  const people = new Map<string, FunnelDeal[]>();
  const unlinked: FunnelDeal[] = [];
  for (const r of cur) {
    if (r.ownerUserId !== null && nameOf(r.ownerUserId) !== null) people.set(r.ownerUserId, [...(people.get(r.ownerUserId) ?? []), r]);
    else unlinked.push(r);
  }
  const out: DealPerson[] = [...people.entries()].map(([userId, list]): DealPerson => ({ kind: "person", userId, name: nameOf(userId), unlinkedOwners: null, ...dealPersonFigures(list) }))
    .sort((a, b) => cmp(a.name ?? "", b.name ?? "") || cmp(a.userId ?? "", b.userId ?? ""));
  if (unlinked.length > 0) {
    out.push({ kind: "notLinked", userId: null, name: null, unlinkedOwners: new Set(unlinked.flatMap((r) => (r.ownerRef === null ? [] : [r.ownerRef]))).size,
      ...dealPersonFigures(unlinked) });
  }
  return { rows: out, total: { kind: "total", userId: null, name: null, unlinkedOwners: null, ...dealPersonFigures(cur) } };
}

/** The previous span of a period as the pages compare it: the dates of lib/reports' previousPeriod, cut at `now` while the period runs */
export function funnelPrevious(prev: { from: DateKey; to: DateKey; partial: boolean }, now: Instant): FunnelPrevious {
  return { from: prev.from, to: prev.to, until: prev.partial ? now : null };
}

// ---- The screen ------------------------------------------------------------------------------------------

/** Days with one decimal in the reader's language ("2.5 d"); a dash without */
export function fmtDays(value: number | null, locale: "en" | "nl", copy: Pick<Copy["funnel"], "daysValue">): string {
  if (value === null) return "–";
  return copy.daysValue.replace("{n}", new Intl.NumberFormat(locale === "nl" ? "nl-NL" : "en-GB", { minimumFractionDigits: 1, maximumFractionDigits: 1 }).format(value));
}

/** An amount in its own currency, never converted or summed with another; a currency the deal and market lack shows the bare number */
export function fmtAmount(amount: number, currency: string | null, locale: "en" | "nl"): string {
  const tag = locale === "nl" ? "nl-NL" : "en-GB";
  if (currency === null || !/^[A-Z]{3}$/.test(currency)) return new Intl.NumberFormat(tag, { maximumFractionDigits: 2 }).format(amount);
  return new Intl.NumberFormat(tag, { style: "currency", currency, maximumFractionDigits: 2 }).format(amount);
}

/** The stages of one pipeline, for the funnel's table and bars, in the database's order */
export function stagesByPipeline(stages: readonly FunnelStageRow[]): { pipeline: string; label: string; stages: FunnelStageRow[] }[] {
  const out: { pipeline: string; label: string; stages: FunnelStageRow[] }[] = [];
  for (const s of stages) {
    const last = out.at(-1);
    if (last && last.pipeline === s.pipeline) last.stages.push(s);
    else out.push({ pipeline: s.pipeline, label: s.pipelineLabel, stages: [s] });
  }
  return out;
}

/** The reason columns of the per-period table: the real reasons in their page order, the first `max`, the rest as Other */
export function periodReasonColumns(reasons: readonly LostReasonRow[], max: number): { columns: { value: string; label: string }[]; other: string[] } {
  return { columns: reasons.slice(0, max).map((r) => ({ value: r.value, label: r.label })), other: reasons.slice(max).map((r) => r.value) };
}

/** The per-period table of cancellations: one row per date or Monday, a column per market (the page's markets), the total */
export function cancellationPivot(byPeriod: CancellationsReport["byPeriod"]): { markets: string[]; rows: { key: DateKey; cells: Record<string, number>; total: number }[] } {
  const markets = [...new Set(byPeriod.map((r) => r.market))].sort(marketOrder);
  const keys = [...new Set(byPeriod.map((r) => r.key))].sort(cmp);
  return {
    markets,
    rows: keys.map((key) => {
      const cells = Object.fromEntries(byPeriod.filter((r) => r.key === key).map((r) => [r.market, r.requests]));
      return { key, cells, total: Object.values(cells).reduce((s, n) => s + n, 0) };
    }),
  };
}

/** The dates of a period's days or weeks, for a table without gaps: every date, or every Monday from the first's */
export function periodKeys(from: DateKey, to: DateKey, group: FunnelGroup): DateKey[] {
  const out: DateKey[] = [];
  for (let d = group === "week" ? startOfWeek(from) : from; d <= to; d = addDays(d, group === "week" ? 7 : 1)) out.push(d);
  return out;
}

/** The words the Funnel pages' client parts use (the filters); never the whole copy, which would travel in the page's payload */
export type FunnelClientCopy = { funnel: Pick<Copy["funnel"], "marketFilter" | "allMarkets" | "pipelineFilter" | "allPipelines" | "sourceFilter" | "allSources">;
  reports: Pick<Copy["reports"], "unknownMarket"> };
export function funnelClientCopy(copy: Copy): FunnelClientCopy {
  const f = copy.funnel;
  return {
    funnel: { marketFilter: f.marketFilter, allMarkets: f.allMarkets, pipelineFilter: f.pipelineFilter, allPipelines: f.allPipelines, sourceFilter: f.sourceFilter, allSources: f.allSources },
    reports: { unknownMarket: copy.reports.unknownMarket },
  };
}

/** The stage bars and the real reasons in the series' first colour; the data-quality and no-reason bars in one neutral hue (Pulse4all-Style 7.7: never a red) */
export const FUNNEL_BAR_CLASS = "bg-p4a-deepblue";
export const FUNNEL_NEUTRAL_CLASS = "bg-p4a-lightblue";
