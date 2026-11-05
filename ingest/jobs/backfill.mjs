// Cloud Run job ingest-backfill (manual): node jobs/backfill.mjs --connection <id> --object <type>[,<type>…] [--from <YYYY-MM-DD>] [--again]
// [--dry-run] (an adapter with a dry run: an asset register's device, a store's subscription and subscription_event; reads and
// counts, writes nothing). Since addition 0008zq --adapter <hubspot|aircall|shopify|trustedshops|airtable|juo> in place of
// --connection (never both): every served connection of that adapter in one execution, in id order, each its own runs and
// budget; a skipped or failed connection is counted and the next still runs; the job exits 1 when any connection failed.
// See src/jobs/backfill.mjs.
import { main, parseArgs, UsageError } from "../src/jobs/runner.mjs";
import { runAdapterBackfill, runBackfill, runBackfills } from "../src/jobs/backfill.mjs";

await main("backfill", (argv) => {
  const a = parseArgs(argv, { connection: "uuid", adapter: "text", object: "text", from: "date", again: "flag", "dry-run": "flag" });
  if (a.connection && a.adapter) throw new UsageError("--connection and --adapter exclude each other: name one");
  if (!a.connection && !a.adapter) throw new UsageError("--connection <id> or --adapter <name> is required");
  if (a.adapter) {
    return runAdapterBackfill({ adapter: a.adapter, objects: a.object, from: a.from ?? null, again: a.again === true, dryRun: a["dry-run"] === true });
  }
  // one object as before (its totals in the finished line); a list (deal,ticket) one after the other on one budget
  if (!String(a.object ?? "").includes(",")) {
    return runBackfill({ connectionId: a.connection, object: a.object, from: a.from ?? null, again: a.again === true, dryRun: a["dry-run"] === true });
  }
  if (a["dry-run"]) throw new UsageError("--dry-run takes one --object");
  return runBackfills({ connectionId: a.connection, objects: a.object, from: a.from ?? null, again: a.again === true });
});
