// Cloud Run job ingest-backfill (manual): node jobs/backfill.mjs --connection <id> --object <type>[,<type>…] [--from <YYYY-MM-DD>] [--again].
// See src/jobs/backfill.mjs.
import { main, parseArgs } from "../src/jobs/runner.mjs";
import { runBackfill, runBackfills } from "../src/jobs/backfill.mjs";

await main("backfill", (argv) => {
  const a = parseArgs(argv, { connection: "uuid", object: "text", from: "date", again: "flag" });
  // one object as before (its totals in the finished line); a list (deal,ticket) one after the other on one budget
  if (!String(a.object ?? "").includes(",")) return runBackfill({ connectionId: a.connection, object: a.object, from: a.from ?? null, again: a.again === true });
  return runBackfills({ connectionId: a.connection, objects: a.object, from: a.from ?? null, again: a.again === true });
});
