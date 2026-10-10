/**
 * The read-back budget (README Decision log, 9 October 2026: events logged and committed first, the
 * read-back within a 3-second budget, then 200). A Budget is a deadline; every outbound call takes
 * a signal that aborts at the deadline or after its own timeout, whichever comes first. What does
 * not finish in time is finished as failed ("timeout") and the sweeper reads it again with backoff.
 */
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

export function readbackBudgetMs() {
  const v = Number(process.env.INGEST_READBACK_BUDGET_MS ?? 3000);
  return Number.isFinite(v) && v > 0 && v <= 20_000 ? v : 3000;
}
