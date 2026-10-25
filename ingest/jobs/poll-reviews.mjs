// Cloud Run job ingest-poll-reviews (hourly at minute 7): node jobs/poll-reviews.mjs [--connection <id>]. See src/jobs/poll-reviews.mjs.
// One execution at a time: a second one started while the first still runs logs "poll-reviews skipped" and exits 0.
import { main, parseArgs } from "../src/jobs/runner.mjs";
import { runPollReviews } from "../src/jobs/poll-reviews.mjs";

await main("poll-reviews", (argv) => {
  const a = parseArgs(argv, { connection: "uuid" });
  return runPollReviews({ connectionId: a.connection ?? null });
}, { lock: true });
