// Cloud Run job ingest-poll-subscriptions (every 5 minutes): node jobs/poll-subscriptions.mjs [--connection <id>]. See
// src/jobs/poll-subscriptions.mjs. One execution at a time: a second one started while the first still runs logs
// "poll-subscriptions skipped" and exits 0.
import { main, parseArgs } from "../src/jobs/runner.mjs";
import { runPollSubscriptions } from "../src/jobs/poll-subscriptions.mjs";

await main("poll-subscriptions", (argv) => {
  const a = parseArgs(argv, { connection: "uuid" });
  return runPollSubscriptions({ connectionId: a.connection ?? null });
}, { lock: true });
