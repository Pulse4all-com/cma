/**
 * The outbox (DESIGN §4.3a, §5; migration 0007c; Cloud Run job ingest-outbox): per active connection
 * whose adapter writes contacts (HubSpot today), the due actions are claimed (50 at a
 * time, FOR UPDATE SKIP LOCKED, never two of one contact), the adapter applies them against the
 * contacts' current values and writes the difference in one batch update, and each action is
 * finished as sent with what was written and skipped, or failed with a short code (the claim already
 * set the backoff; the database parks an action after outbox.max_attempts for a person). Claims
 * repeat until fewer than 50 are due or the run's time is up.
 *
 * Generic and, since 0008h, unused: the CMA writes nothing back for a store's customers (README
 * Decision log, 13 October 2026), so nothing enqueues an action today and the job is deployed without
 * a schedule (docs/ingest/deploy.sh); it is kept for a write-back a later decision configures.
 *
 * The outbox rows are the job's audit (state, attempts, result, error, who resolved a parked one);
 * sync_run has no job value for it (migration 0007's vocabulary). Logs carry counts and codes only.
 */
import { ADAPTERS } from "../adapters/index.mjs";
import { servedConnections, contextOf } from "../core/connection.mjs";
import { storeFor } from "../core/store.mjs";
import { JobBudget } from "../core/budget.mjs";
import { info, warn } from "../core/log.mjs";
import { codeOf } from "./runner.mjs";

const CLAIM = 50;

export async function runOutbox({ connectionId = null, adapters = ADAPTERS, maxMs = 45_000, now = () => Date.now() } = {}) {
  const started = now();
  const connections = await servedConnections({ connectionId, actorLabel: "ingest:outbox" });
  const total = { connections: 0, claimed: 0, sent: 0, actionsFailed: 0, errors: {}, failed: 0 };
  for (const c of connections) {
    const adapter = Object.hasOwn(adapters, c.adapter) ? adapters[c.adapter] : null;
    if (!adapter?.writeContacts) continue;
    total.connections += 1;
    const store = storeFor(contextOf(c), c.connectionId);
    const budget = new JobBudget(adapter.rates);
    try {
      for (;;) {
        const actions = await store.outboxClaim(CLAIM);
        if (!actions.length) break;
        total.claimed += actions.length;
        const config = await store.config();
        let groups;
        try {
          groups = await adapter.writeContacts({ connection: c, config, actions, budget });
        } catch (err) {
          groups = [{ ids: actions.map((a) => a.action_id), outcome: "failed", result: null, error: codeOf(err) }];
        }
        // every claimed action is finished; one the adapter left out fails
        const covered = new Set(groups.flatMap((g) => g.ids));
        const missing = actions.filter((a) => !covered.has(a.action_id)).map((a) => a.action_id);
        if (missing.length) groups.push({ ids: missing, outcome: "failed", result: null, error: "not_handled" });
        await store.outboxFinish(groups);
        for (const g of groups) {
          if (g.outcome === "sent") total.sent += g.ids.length;
          else {
            total.actionsFailed += g.ids.length;
            total.errors[g.error] = (total.errors[g.error] ?? 0) + g.ids.length;
          }
        }
        if (actions.length < CLAIM || now() - started > maxMs) break;
      }
    } catch (err) {
      total.failed += 1;
      warn("outbox: connection failed", { connection: c.connectionId, adapter: c.adapter, code: codeOf(err) });
    }
  }
  info("outbox", { ...total, ms: now() - started });
  return total;
}
