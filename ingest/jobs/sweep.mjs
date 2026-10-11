// Cloud Run job ingest-sweep (every minute): node jobs/sweep.mjs [--connection <id>]. See src/jobs/sweep.mjs.
import { main, parseArgs } from "../src/jobs/runner.mjs";
import { runSweep } from "../src/jobs/sweep.mjs";

await main("sweep", (argv) => {
  const a = parseArgs(argv, { connection: "uuid" });
  return runSweep({ connectionId: a.connection ?? null });
});
