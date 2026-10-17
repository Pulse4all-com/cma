// Cloud Run job ingest-sweep (every minute): node jobs/sweep.mjs [--connection <id>]. See src/jobs/sweep.mjs.
// One execution at a time: a second one started while the first still runs logs "sweep skipped" and exits 0.
import { main, parseArgs } from "../src/jobs/runner.mjs";
import { runSweep } from "../src/jobs/sweep.mjs";

await main("sweep", (argv) => {
  const a = parseArgs(argv, { connection: "uuid" });
  return runSweep({ connectionId: a.connection ?? null });
}, { lock: true });
