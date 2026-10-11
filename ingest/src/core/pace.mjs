/**
 * Pacing for the jobs (DESIGN §5: backfill throttled under each source's rate limit). A Pace lets
 * one call through per interval: wait() resolves when the next slot is due. The adapter names its
 * intervals per kind of call (for example general and search) from the source's documented limits,
 * at half the documented rate; the webhook path does not pace (it reads a handful of objects).
 *
 * INGEST_PACE_FACTOR (0 to 1, default 1) scales every interval: the verifiers set it low so a run
 * against a fake source takes seconds. Never set on Cloud Run.
 */
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export function paceFactor() {
  const v = Number(process.env.INGEST_PACE_FACTOR ?? 1);
  return Number.isFinite(v) && v >= 0 && v <= 1 ? v : 1;
}

export class Pace {
  constructor(intervalMs) {
    this.interval = Math.max(0, intervalMs * paceFactor());
    this.next = 0;
  }
  async wait() {
    const now = Date.now();
    const at = Math.max(now, this.next);
    this.next = at + this.interval;
    if (at > now) await sleep(at - now);
  }
}
