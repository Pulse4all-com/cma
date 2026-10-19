/**
 * The read-back budget (README Decision log, 9 October 2026: events logged and committed first, the
 * read-back within a 3-second budget, then 200). A Budget is a deadline; every outbound call takes
 * a signal that aborts at the deadline or after its own timeout, whichever comes first. What does
 * not finish in time is finished as failed ("timeout") and the sweeper reads it again with backoff.
 */
import { Pace } from "./pace.mjs";
import { SourceError } from "./http.mjs";

export class Budget {
  constructor(ms) {
    this.deadline = Date.now() + ms;
  }
  remaining() {
    return Math.max(0, this.deadline - Date.now());
  }
  expired() {
    return this.remaining() === 0;
  }
  /** An AbortSignal for one call: at most perCallMs, never past the deadline. */
  signal(perCallMs = 10_000) {
    return AbortSignal.timeout(Math.max(1, Math.min(perCallMs, this.remaining())));
  }
}

/** An unbounded budget for jobs (sweep, backfill): only the per-call timeout applies. */
export class NoBudget extends Budget {
  constructor() {
    super(0);
    this.deadline = Number.POSITIVE_INFINITY;
  }
  remaining() {
    return Number.POSITIVE_INFINITY;
  }
  signal(perCallMs = 30_000) {
    return AbortSignal.timeout(perCallMs);
  }
}

/**
 * A job's budget: no deadline, a longer per-call timeout (a search page or a batch of 100 can take a
 * few seconds), and the source's pacing. rates: { kind: interval ms } from the adapter; a call of an
 * unnamed kind is not paced.
 *
 * It also measures and guards the run's use of the source (backlog CMA-069, 18 October 2026). The
 * adapter's client counts every request per endpoint template (count: the method and the path with
 * its ids replaced, never an id or a query value), for the run's log line (usage). It hands over the
 * source's daily limit as a response states it (observeDaily: { limit, remaining }), when the source
 * sends one. With floorPct (backfill and reconcile; never a poll) guard() throws SourceError
 * daily_floor before the next request once the remaining calls fall below floorPct of the limit, so
 * the run pauses and the others sharing the limit keep their room; without a reading it never pauses.
 */
export class JobBudget extends NoBudget {
  constructor(rates = {}, perCallMs = 20_000, { floorPct = null } = {}) {
    super();
    this.perCallMs = perCallMs;
    this.paces = new Map(Object.entries(rates).map(([kind, ms]) => [kind, new Pace(ms)]));
    this.floorPct = floorPct;
    this.calls = new Map();
    this.daily = null;
  }
  signal(perCallMs = this.perCallMs) {
    return AbortSignal.timeout(Math.max(perCallMs, this.perCallMs));
  }
  async pace(kind = "general") {
    await this.paces.get(kind)?.wait();
  }
  count(endpoint) {
    this.calls.set(endpoint, (this.calls.get(endpoint) ?? 0) + 1);
  }
  /** The counts so far, to measure a part of the run (usage(since)) */
  mark() {
    return new Map(this.calls);
  }
  /**
   * The run's requests (or those since a mark): {} when there were none, else { apiCalls, api, daily }:
   * the total, per endpoint (sorted), and the last daily reading or not_received when the source sent none
   */
  usage(since = null) {
    const api = {};
    let apiCalls = 0;
    for (const [endpoint, n] of [...this.calls].sort(([a], [b]) => a.localeCompare(b))) {
      const d = n - (since?.get(endpoint) ?? 0);
      if (d > 0) {
        api[endpoint] = d;
        apiCalls += d;
      }
    }
    return apiCalls ? { apiCalls, api, daily: this.daily ?? "not_received" } : {};
  }
  observeDaily(reading) {
    if (reading) this.daily = reading;
  }
  belowFloor() {
    return this.floorPct !== null && this.daily !== null && this.daily.remaining < (this.daily.limit * this.floorPct) / 100;
  }
  guard() {
    if (this.belowFloor()) throw new SourceError("daily_floor");
  }
}

export function readbackBudgetMs() {
  const v = Number(process.env.INGEST_READBACK_BUDGET_MS ?? 3000);
  return Number.isFinite(v) && v > 0 && v <= 20_000 ? v : 3000;
}
