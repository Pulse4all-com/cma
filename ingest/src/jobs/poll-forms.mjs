/**
 * The forms poll (DESIGN §5, every minute): per active connection whose adapter polls forms (HubSpot
 * today), one sync_run row (job forms_poll, stream forms): the catalog with the forms' fields refreshed
 * hourly, every polled form (whether or not it counts in Intake; addition 0008p) read until its cursor,
 * contacts resolved, submissions upserted with their choice answers, cursors moved; answers left out are
 * counted as dropped. The adapter does the source's part (src/adapters/hubspot/forms.mjs).
 */
import { ADAPTERS } from "../adapters/index.mjs";
import { servedConnections, contextOf } from "../core/connection.mjs";
import { storeFor } from "../core/store.mjs";
import { JobBudget } from "../core/budget.mjs";
import { info, warn } from "../core/log.mjs";
import { codeOf, withRun } from "./runner.mjs";

export async function runPollForms({ connectionId = null, adapters = ADAPTERS } = {}) {
  const started = Date.now();
  const connections = await servedConnections({ connectionId, actorLabel: "ingest:poll-forms" });
  const total = { connections: 0, fetched: 0, upserted: 0, skipped: 0, dropped: 0, failed: 0 };
  for (const c of connections) {
    const adapter = Object.hasOwn(adapters, c.adapter) ? adapters[c.adapter] : null;
    if (!adapter?.pollForms) continue;
    total.connections += 1;
    const store = storeFor(contextOf(c), c.connectionId);
    try {
      const r = await withRun(store, { job: "forms_poll", stream: "forms", to: new Date() }, async (counts) => {
        const p = await adapter.pollForms({ connection: c, store, budget: new JobBudget(adapter.rates) });
        for (const k of Object.keys(counts)) counts[k] += p.counts[k] ?? 0;
        // answers left out (no option of their field accounts for them): recorded only once there is one
        if (p.counts.dropped) counts.dropped = p.counts.dropped;
        return { error: p.error };
      });
      total.fetched += r.counts.fetched;
      total.upserted += r.counts.upserted;
      total.skipped += r.counts.skipped;
      total.dropped += r.counts.dropped ?? 0;
      if (!r.ok) {
        total.failed += 1;
        warn("poll-forms: connection failed", { connection: c.connectionId, code: r.error });
      }
    } catch (err) {
      total.failed += 1;
      warn("poll-forms: run not recorded", { connection: c.connectionId, code: codeOf(err) });
    }
  }
  info("poll-forms", { ...total, ms: Date.now() - started });
  return total;
}
