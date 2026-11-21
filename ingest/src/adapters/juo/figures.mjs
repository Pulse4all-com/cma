/**
 * Juo's own figures for a store (addition 0009zg, brief B39 continued, Part B39b): the analytics API's counts and amount,
 * stored beside the CMA's in cma.source_figure, so a missed read or a wrong rule shows on Data quality within a day. Read
 * only: POST /analytics/query is a read with a body, the one POST the client's allow-list takes (client.mjs). Juo's metric
 * keys live here and in source_metric only; the database knows the figures by the CMA's words (cma.source_figure_keys).
 *
 * The figures, each one query a store (the body as Juo's analytics API takes it: metric, grain, range {from, to} as
 * dates, inclusive, timezone, and per figure rollup, filter, dimensions or cohort):
 *   subscriptions_in_status   subscriptions:count, one query per status (active, paused, failed, canceled), filter
 *                             event.status_to eq the status, grain day, rollup last, yesterday to today: Juo's latest daily
 *                             snapshot, stored under today (the read's day). Juo writes the series forward once a day and
 *                             cannot recompute a past date, nor can the CMA: both are the state at the read
 *   recurring_amount_active   subscriptions:current-mrr, grain total, today: the active subscriptions' monthly amount now, in
 *                             the store's currency (Juo names none; the database takes the currency of the connection's
 *                             active subscriptions). Juo labels it money_minor; its values read as the currency's own unit
 *                             (a store's amount on 20 November 2026 against its active count: tens per subscription, not tenths), as the CMA stores amounts: stored as
 *                             given, and a factor of 100 would show as a gap on the first day
 *   renewals, purchases, pauses   subscriptions:renewed, :purchased, :pauses, grain day, yesterday to today
 *   transitions_to_churn      subscriptions:churned grouped by event.status_to (canceled, failed, expired), grain day
 *   renewal_survival          subscriptions:purchased as a retention cohort by order sequence (anchor subscription:purchased),
 *                             monthly cohorts and periods (Juo answers 501 for weekly cohorts: "only day and month", 21 Nov
 *                             2026), 24 periods, the last 24 months' cohorts, stored under the first day of the read's month
 * A flow's day without a row in Juo's answer is 0 (Juo leaves empty buckets out), so every day read is stored. Each
 * bucket's day is its start in the tenant's zone (the timezone sent), which holds whether Juo writes a bucket's start as
 * the zone's midnight or as the date at UTC midnight, for a zone at or east of UTC (every store today).
 *
 * Answers that skip a figure, counted per code and never failing the run: 400 and 501 (unsupported: a filter, a grain or
 * a metric this store's Juo does not take), a filter Juo reports as ignored (filter_ignored: the figure would not be
 * what it says), a value that is no number from 0 (bad_value), a stock figure without any value (no_value: Juo's daily
 * snapshot not written yet, never read as 0); 409 (analytics_off: analytics switched off for the store)
 * skips the store's remaining figures. Any other error (a key refused, a timeout, a 5xx) fails the run, which the next
 * hourly run repeats while the day's read is due.
 */
import { SourceError } from "../../core/http.mjs";

export const ANALYTICS_QUERY = "/analytics/query";
export const STATUSES_IN = ["active", "paused", "failed", "canceled"];
export const STATUSES_CHURN = ["canceled", "failed", "expired"];
export const SURVIVAL_PERIODS = 24;
/** The flow figures, as the daily read and the month backfill take them */
export const FLOWS = ["renewals", "transitions_to_churn", "purchases", "pauses"];

const DATE = /^\d{4}-\d{2}-\d{2}$/;
const COHORT = /^(\d{4})-(0[1-9]|1[0-2])$/;

/** YYYY-MM-DD of an instant in a zone */
export function dateIn(instant, timeZone) {
  const ms = typeof instant === "number" ? instant : Date.parse(instant);
  if (!Number.isFinite(ms)) return null;
  return new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(ms));
}

/** The dates from one date to another, inclusive (YYYY-MM-DD) */
export function datesBetween(from, to) {
  const out = [];
  for (let d = Date.parse(`${from}T00:00:00Z`); d <= Date.parse(`${to}T00:00:00Z`); d += 86_400_000) out.push(new Date(d).toISOString().slice(0, 10));
  return out;
}

/** The first day of a date's month, and of the month n months before it */
export const monthStart = (date, back = 0) => {
  const d = new Date(`${date.slice(0, 7)}-01T00:00:00Z`);
  d.setUTCMonth(d.getUTCMonth() - back);
  return d.toISOString().slice(0, 10);
};

/** The last day of a date's month */
export const monthEnd = (date) => {
  const d = new Date(`${date.slice(0, 7)}-01T00:00:00Z`);
  d.setUTCMonth(d.getUTCMonth() + 1);
  return new Date(d.getTime() - 86_400_000).toISOString().slice(0, 10);
};

/** A flow figure's queries over a range of days: one per figure */
function flowQueries(figure, from, to, timezone) {
  const base = { grain: "day", range: { from, to }, timezone };
  switch (figure) {
    case "renewals": return [{ figure, metric: "subscriptions:renewed", body: { metric: "subscriptions:renewed", ...base } }];
    case "purchases": return [{ figure, metric: "subscriptions:purchased", body: { metric: "subscriptions:purchased", ...base } }];
    case "pauses": return [{ figure, metric: "subscriptions:pauses", body: { metric: "subscriptions:pauses", ...base } }];
    case "transitions_to_churn":
      return [{ figure, metric: "subscriptions:churned", body: { metric: "subscriptions:churned", ...base, dimensions: ["event.status_to"] } }];
    default: throw new SourceError("figure_unknown");
  }
}

/**
 * The queries of a day's read: { figure, metric, status?, body } each. dates: { today, yesterday, timezone } (the
 * tenant's zone, cma.source_figures_due_of)
 */
export function dailyQueries({ today, yesterday, timezone }) {
  if (!DATE.test(today) || !DATE.test(yesterday)) throw new SourceError("dates_invalid");
  const q = STATUSES_IN.map((status) => ({ figure: "subscriptions_in_status", metric: "subscriptions:count", status,
    body: { metric: "subscriptions:count", grain: "day", range: { from: yesterday, to: today }, timezone, rollup: "last",
      filter: { field: "event.status_to", operator: "eq", value: status } } }));
  q.push({ figure: "recurring_amount_active", metric: "subscriptions:current-mrr",
    body: { metric: "subscriptions:current-mrr", grain: "total", range: { from: today, to: today }, timezone } });
  for (const f of FLOWS) q.push(...flowQueries(f, yesterday, today, timezone));
  q.push({ figure: "renewal_survival", metric: "subscriptions:purchased",
    body: { metric: "subscriptions:purchased", grain: "month", range: { from: monthStart(today, SURVIVAL_PERIODS - 1), to: today }, timezone,
      cohort: { anchorEvent: "subscription:purchased", periodGrain: "month", measure: "retention", periodBasis: "order_sequence",
        periods: SURVIVAL_PERIODS } } });
  return q;
}

/** The queries of a backfill month: the flow figures over its days from..to */
export function monthQueries({ from, to, timezone }) {
  if (!DATE.test(from) || !DATE.test(to)) throw new SourceError("dates_invalid");
  return FLOWS.flatMap((f) => flowQueries(f, from, to, timezone));
}

const valueOf = (v) => (typeof v === "number" && Number.isFinite(v) && v >= 0 && v < 1e16 ? v : null);

/**
 * One answer mapped to items for cma.ingest_upsert_source_figures, or { skip: code }. query: one of dailyQueries or
 * monthQueries; dates: { today, timezone } and the range the query read.
 */
export function itemsOf(query, answer, { today, timezone }) {
  if (!answer || typeof answer !== "object" || !Array.isArray(answer.series)) return { skip: "bad_response" };
  const ignored = answer.meta?.ignoredFilters;
  if (Array.isArray(ignored) ? ignored.length > 0 : ignored && typeof ignored === "object" && Object.keys(ignored).length > 0) {
    return { skip: "filter_ignored" };
  }
  const { figure, metric, body } = query;
  const series = answer.series.filter((p) => p && typeof p === "object");
  const item = (businessDate, dims, value, unit = "count") => ({ figureKey: figure, sourceMetric: metric, businessDate, dims, value, unit });
  if (figure === "subscriptions_in_status") {
    const last = series.filter((p) => Number.isFinite(Date.parse(p.start))).sort((a, b) => Date.parse(b.start) - Date.parse(a.start))[0];
    if (!last) return { skip: "no_value" };
    const v = valueOf(last.value);
    return v === null ? { skip: "bad_value" } : { items: [item(today, { status: query.status }, v)] };
  }
  if (figure === "recurring_amount_active") {
    if (!series.length) return { skip: "no_value" };
    const v = valueOf(series[0].value);
    return v === null ? { skip: "bad_value" } : { items: [item(today, {}, Math.round(v * 100) / 100, "amount")] };
  }
  if (figure === "renewal_survival") {
    const items = [];
    for (const p of series) {
      const m = COHORT.exec(String(p.dimensions?.cohort ?? ""));
      const period = p.dimensions?.period;
      if (!m || !Number.isInteger(period) || period < 1 || period > SURVIVAL_PERIODS) continue;
      const v = valueOf(p.value);
      if (v === null) return { skip: "bad_value" };
      items.push(item(monthStart(today), { cohort_start: `${m[1]}-${m[2]}-01`, period }, v));
    }
    return { items };
  }
  // a flow: every day of the range, 0 where Juo has no row; churn per status of STATUSES_CHURN (others left out)
  const days = datesBetween(body.range.from, body.range.to);
  const keys = figure === "transitions_to_churn" ? STATUSES_CHURN : [null];
  const sums = new Map(days.flatMap((d) => keys.map((k) => [`${d}|${k}`, 0])));
  for (const p of series) {
    const d = dateIn(p.start, timezone);
    const k = figure === "transitions_to_churn" ? p.dimensions?.["event.status_to"] : null;
    if (!sums.has(`${d}|${k}`)) continue;
    const v = valueOf(p.value);
    if (v === null) return { skip: "bad_value" };
    sums.set(`${d}|${k}`, sums.get(`${d}|${k}`) + v);
  }
  return { items: [...sums].map(([key, v]) => {
    const [d, k] = key.split("|");
    return item(d, k === "null" ? {} : { status: k }, v);
  }) };
}

/** The skip code of a source error, or null when the error fails the run */
export function skipCodeOf(err) {
  if (!(err instanceof SourceError)) return null;
  if (err.code === "http_400" || err.code === "http_501") return "unsupported";
  if (err.code === "http_409") return "analytics_off";
  return null;
}

/**
 * Runs queries against the API and maps them: { items, skipped: { code: n }, queries }. A 409 skips the remaining queries
 * (analytics off for the store); any error skipCodeOf does not name is thrown.
 */
export async function runQueries(api, queries, dates) {
  const items = [];
  const skipped = {};
  let off = false;
  for (const q of queries) {
    if (off) {
      skipped.analytics_off = (skipped.analytics_off ?? 0) + 1;
      continue;
    }
    let answer;
    try {
      answer = await api.query(ANALYTICS_QUERY, q.body);
    } catch (err) {
      const code = skipCodeOf(err);
      if (!code) throw err;
      skipped[code] = (skipped[code] ?? 0) + 1;
      if (code === "analytics_off") off = true;
      continue;
    }
    const m = itemsOf(q, answer, dates);
    if (m.skip) skipped[m.skip] = (skipped[m.skip] ?? 0) + 1;
    else items.push(...m.items);
  }
  return { items, skipped, queries: queries.length };
}
