// Cloud Run job ingest-backfill (manual): node jobs/backfill.mjs --connection <id> --object <type> [--from <YYYY-MM-DD>] [--again].
// See src/jobs/backfill.mjs.
import { main, parseArgs } from "../src/jobs/runner.mjs";
import { runBackfill } from "../src/jobs/backfill.mjs";

await main("backfill", (argv) => {
  const a = parseArgs(argv, { connection: "uuid", object: "text", from: "date", again: "flag" });
  return runBackfill({ connectionId: a.connection, object: a.object, from: a.from ?? null, again: a.again === true });
});
