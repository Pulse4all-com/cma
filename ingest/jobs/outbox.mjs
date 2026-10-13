// Cloud Run job ingest-outbox (every minute): node jobs/outbox.mjs [--connection <id>]. See src/jobs/outbox.mjs.
import { main, parseArgs } from "../src/jobs/runner.mjs";
import { runOutbox } from "../src/jobs/outbox.mjs";

await main("outbox", (argv) => {
  const a = parseArgs(argv, { connection: "uuid" });
  return runOutbox({ connectionId: a.connection ?? null });
});
