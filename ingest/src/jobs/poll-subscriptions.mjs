/**
 * The subscriptions poll (addition 0008zl, brief B20; every 5 minutes, Europe/Amsterdam): per active connection whose
 * adapter polls a store's subscriptions (Juo today) and holds a token secret name, when due on its
 * subscriptions_poll_interval_minutes (default 5), one sync_run row (job subscriptions_poll, stream subscriptions): the
 * events of the store's subscriptions that occurred since the connection's cursor less five minutes, stored, then every
 * subscription those events touched read again and upserted (src/adapters/juo). A connection not due writes nothing. A
 * connection without a token secret name is not read: one log line (code key_not_set) and no run. One log line per
 * connection carries the counts (events_new, the subscriptions' outcomes, customers_unmatched, reason_dropped), the
 * details (events read, kept and skipped, by Juo's type; subscriptions read) and the requests per endpoint. Never a key
 * or a value. Like every job it runs with a pool of 2 (docs/ingest/deploy.sh): its advisory lock and one unit of work
 * at a time (db.mjs measurePool; verify/juo-flow.mjs D5 and P1).
 */
import { ADAPTERS } from "../adapters/index.mjs";
import { servedConnections, contextOf } from "../core/connection.mjs";
import { storeFor } from "../core/store.mjs";
import { JobBudget } from "../core/budget.mjs";
import { info, warn } from "../core/log.mjs";
import { codeOf, withRun } from "./runner.mjs";
import { measurePool } from "../core/db.mjs";

export function runPollSubscriptions(options) {
  return measurePool("poll-subscriptions", () => pollSubscriptionsJob(options));
}

async function pollSubscriptionsJob({ connectionId = null, adapters = ADAPTERS } = {}) {
  const started = Date.now();
  const connections = await servedConnections({ connectionId, actorLabel: "ingest:poll-subscriptions" });
  const total = { connections: 0, notServed: 0, notDue: 0, fetched: 0, eventsNew: 0, inserted: 0, updated: 0, unchanged: 0, failed: 0 };
  for (const c of connections) {
    const adapter = Object.hasOwn(adapters, c.adapter) ? adapters[c.adapter] : null;
    if (!adapter?.pollSubscriptions) continue;
    total.connections += 1;
    const skip = adapter.skipReason?.(c) ?? null;
    if (skip) {
      total.notServed += 1;
      info("poll-subscriptions: connection skipped", { connection: c.connectionId, code: skip });
      continue;
    }
    const store = storeFor(contextOf(c), c.connectionId);
    try {
      if (!(await adapter.pollDue({ store, now: Date.now() }))) {
        total.notDue += 1;
        continue;
      }
      const budget = new JobBudget(adapter.rates);
      let detail = {};
      const r = await withRun(store, { job: "subscriptions_poll", stream: "subscriptions", to: new Date() }, async (counts) => {
        detail = (await adapter.pollSubscriptions({ connection: c, store, budget, now: Date.now(), counts })).detail ?? {};
        return undefined;
      });
      info("poll-subscriptions: connection", { connection: c.connectionId, ...r.counts, ...detail, ...budget.usage(), error: r.error ?? undefined });
      total.fetched += r.counts.fetched ?? 0;
      total.eventsNew += r.counts.events_new ?? 0;
      for (const k of ["inserted", "updated", "unchanged"]) total[k] += r.counts[k] ?? 0;
      if (!r.ok) {
        total.failed += 1;
        warn("poll-subscriptions: connection failed", { connection: c.connectionId, code: r.error });
      }
    } catch (err) {
      total.failed += 1;
      warn("poll-subscriptions: run not recorded", { connection: c.connectionId, code: codeOf(err) });
    }
  }
  info("poll-subscriptions", { ...total, ms: Date.now() - started });
  return total;
}
