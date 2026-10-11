/**
 * The read-back budget (README Decision log, 9 October 2026: events logged and committed first, the
 * read-back within a 3-second budget, then 200). A Budget is a deadline; every outbound call takes
 * a signal that aborts at the deadline or after its own timeout, whichever comes first. What does
 * not finish in time is finished as failed ("timeout") and the sweeper reads it again with backoff.
 */
import { Pace } from "./pace.mjs";

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
 */
export class JobBudget extends NoBudget {
  constructor(rates = {}, perCallMs = 20_000) {
    super();
    this.perCallMs = perCallMs;
    this.paces = new Map(Object.entries(rates).map(([kind, ms]) => [kind, new Pace(ms)]));
  }
  signal(perCallMs = this.perCallMs) {
    return AbortSignal.timeout(Math.max(perCallMs, this.perCallMs));
  }
  async pace(kind = "general") {
    await this.paces.get(kind)?.wait();
  }
}

export function readbackBudgetMs() {
  const v = Number(process.env.INGEST_READBACK_BUDGET_MS ?? 3000);
  return Number.isFinite(v) && v > 0 && v <= 20_000 ? v : 3000;
}
