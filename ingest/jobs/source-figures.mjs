// Cloud Run job ingest-source-figures (hourly at minute 41): node jobs/source-figures.mjs [--connection <id>]. See
// src/jobs/source-figures.mjs. One execution at a time: a second one started while the first still runs logs
// "source-figures skipped" and exits 0.
import { main, parseArgs } from "../src/jobs/runner.mjs";
import { runSourceFigures } from "../src/jobs/source-figures.mjs";

await main("source-figures", (argv) => {
  const a = parseArgs(argv, { connection: "uuid" });
  return runSourceFigures({ connectionId: a.connection ?? null });
}, { lock: true });
