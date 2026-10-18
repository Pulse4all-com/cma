// Cloud Run job ingest-poll-email (every minute): node jobs/poll-email.mjs [--connection <id>]. See src/jobs/poll-email.mjs.
// One execution at a time: a second one started while the first still runs logs "poll-email skipped" and exits 0.
import { main, parseArgs } from "../src/jobs/runner.mjs";
import { runPollEmail } from "../src/jobs/poll-email.mjs";

await main("poll-email", (argv) => {
  const a = parseArgs(argv, { connection: "uuid" });
  return runPollEmail({ connectionId: a.connection ?? null });
}, { lock: true });
