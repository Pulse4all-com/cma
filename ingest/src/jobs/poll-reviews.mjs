/**
 * The reviews poll (addition 0008zd, brief B18; hourly at minute 7, Europe/Amsterdam): per active connection whose
 * adapter polls reviews (Trusted Shops today) and is due on its reviews_poll_interval_minutes (default 60), one
 * sync_run row (job reviews_poll, stream reviews): the channel catalog, then each channel's reviews submitted after its
 * cursor less two hours, upserted with their order links, the new ones without a contact looked up by email (in
 * memory), the alerts raised (src/adapters/trustedshops/reconcile.mjs). A connection not due writes nothing. One log
 * line per connection carries the counts, the details (links, lookups, alerts), the run's requests per endpoint and
 * the CRM lookups' daily reading. A poll never pauses: below the CRM's daily floor it stops looking contacts up.
 */
import { ADAPTERS } from "../adapters/index.mjs";
import { servedConnections, contextOf } from "../core/connection.mjs";
import { storeFor } from "../core/store.mjs";
import { JobBudget } from "../core/budget.mjs";
import { info, warn } from "../core/log.mjs";
import { codeOf, withRun } from "./runner.mjs";

export async function runPollReviews({ connectionId = null, adapters = ADAPTERS } = {}) {
  const started = Date.now();
  const connections = await servedConnections({ connectionId, actorLabel: "ingest:poll-reviews" });
  const total = { connections: 0, notDue: 0, fetched: 0, upserted: 0, stale: 0, skipped: 0, failed: 0 };
  for (const c of connections) {
    const adapter = Object.hasOwn(adapters, c.adapter) ? adapters[c.adapter] : null;
    if (!adapter?.pollReviews) continue;
    total.connections += 1;
    const store = storeFor(contextOf(c), c.connectionId);
    try {
      if (!(await adapter.pollDue({ store, now: Date.now() }))) {
        total.notDue += 1;
        continue;
      }
      const budget = new JobBudget(adapter.rates);
      let detail = {};
      let crm = {};
      const r = await withRun(store, { job: "reviews_poll", stream: "reviews", to: new Date() }, async (counts) => {
        const p = await adapter.pollReviews({ connection: c, store, budget, now: Date.now(), counts });
        detail = p.detail ?? {};
        crm = p.usage ?? {};
        return undefined;
      });
      info("poll-reviews: connection", { connection: c.connectionId, ...r.counts, ...detail, ...budget.usage(),
        ...(crm.apiCalls ? { crmApiCalls: crm.apiCalls, crmApi: crm.api, crmDaily: crm.daily } : {}), error: r.error ?? undefined });
      for (const k of ["fetched", "upserted", "stale", "skipped"]) total[k] += r.counts[k];
      if (!r.ok) {
        total.failed += 1;
        warn("poll-reviews: connection failed", { connection: c.connectionId, code: r.error });
      }
    } catch (err) {
      total.failed += 1;
      warn("poll-reviews: run not recorded", { connection: c.connectionId, code: codeOf(err) });
    }
  }
  info("poll-reviews", { ...total, ms: Date.now() - started });
  return total;
}
