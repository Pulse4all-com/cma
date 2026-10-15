/**
 * The email poll (brief B17b, every minute): per active connection whose adapter polls email (HubSpot
 * today) and whose settings switch it on (email_poll true), one sync_run row (job email_poll, stream
 * email): the CRM's email engagements modified since their cursor, then the inbox conversations (the
 * catalogs and the owner map hourly, the changed threads with their new messages and events, the open
 * check every ten minutes). The adapter does the source's part (src/adapters/hubspot/email-poll.mjs).
 * Logs: connection ids, counts per kind and codes; never an id of an email, thread or contact, a
 * subject, an address or a name.
 */
import { ADAPTERS } from "../adapters/index.mjs";
import { servedConnections, contextOf } from "../core/connection.mjs";
import { storeFor } from "../core/store.mjs";
import { JobBudget } from "../core/budget.mjs";
import { info, warn } from "../core/log.mjs";
import { codeOf, withRun } from "./runner.mjs";

export async function runPollEmail({ connectionId = null, adapters = ADAPTERS, now = null } = {}) {
  const started = Date.now();
  const connections = await servedConnections({ connectionId, actorLabel: "ingest:poll-email" });
  const total = { connections: 0, fetched: 0, upserted: 0, stale: 0, skipped: 0, failed: 0 };
  for (const c of connections) {
    const adapter = Object.hasOwn(adapters, c.adapter) ? adapters[c.adapter] : null;
    if (!adapter?.pollEmail) continue;
    const store = storeFor(contextOf(c), c.connectionId);
    try {
      const config = await store.config();
      if (!adapter.emailPollEnabled(config)) continue;
      total.connections += 1;
      let detail = {};
      const r = await withRun(store, { job: "email_poll", stream: "email", to: new Date() }, async (counts) => {
        const p = await adapter.pollEmail({ connection: c, store, budget: new JobBudget(adapter.rates), config, now: now ?? Date.now() });
        for (const k of Object.keys(counts)) counts[k] += p.counts[k] ?? 0;
        detail = p.detail ?? {};
        return { error: p.error };
      });
      for (const k of ["fetched", "upserted", "stale", "skipped"]) total[k] += r.counts[k];
      info("poll-email: connection", { connection: c.connectionId, ...r.counts, outcomes: detail, error: r.error ?? undefined });
      if (!r.ok) {
        total.failed += 1;
        warn("poll-email: connection failed", { connection: c.connectionId, code: r.error });
      }
    } catch (err) {
      total.failed += 1;
      warn("poll-email: run not recorded", { connection: c.connectionId, code: codeOf(err) });
    }
  }
  info("poll-email", { ...total, ms: Date.now() - started });
  return total;
}
