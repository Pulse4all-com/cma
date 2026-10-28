// Cloud Run job ingest-backfill (manual): node jobs/backfill.mjs --connection <id> --object <type>[,<type>…] [--from <YYYY-MM-DD>] [--again]
// [--dry-run] (an adapter with a dry run: an asset register's device, a store's subscription and subscription_event; reads and
// counts, writes nothing).
// See src/jobs/backfill.mjs.
import { main, parseArgs, UsageError } from "../src/jobs/runner.mjs";
import { runBackfill, runBackfills } from "../src/jobs/backfill.mjs";

await main("backfill", (argv) => {
  const a = parseArgs(argv, { connection: "uuid", object: "text", from: "date", again: "flag", "dry-run": "flag" });
  // one object as before (its totals in the finished line); a list (deal,ticket) one after the other on one budget
  if (!String(a.object ?? "").includes(",")) {
    return runBackfill({ connectionId: a.connection, object: a.object, from: a.from ?? null, again: a.again === true, dryRun: a["dry-run"] === true });
  }
  if (a["dry-run"]) throw new UsageError("--dry-run takes one --object");
  return runBackfills({ connectionId: a.connection, objects: a.object, from: a.from ?? null, again: a.again === true });
});
