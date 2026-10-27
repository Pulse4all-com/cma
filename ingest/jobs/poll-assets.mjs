// Cloud Run job ingest-poll-assets (every 5 minutes): node jobs/poll-assets.mjs [--connection <id>]. See src/jobs/poll-assets.mjs.
// One execution at a time: a second one started while the first still runs logs "poll-assets skipped" and exits 0.
import { main, parseArgs } from "../src/jobs/runner.mjs";
import { runPollAssets } from "../src/jobs/poll-assets.mjs";

await main("poll-assets", (argv) => {
  const a = parseArgs(argv, { connection: "uuid" });
  return runPollAssets({ connectionId: a.connection ?? null });
}, { lock: true });
