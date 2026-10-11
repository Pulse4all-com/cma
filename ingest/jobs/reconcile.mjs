// Cloud Run job ingest-reconcile (02:30 Europe/Amsterdam):
//   node jobs/reconcile.mjs [--lookback-minutes <n>] [--connection <id>] [--object <type>]. See src/jobs/reconcile.mjs.
import { main, parseArgs } from "../src/jobs/runner.mjs";
import { runReconcile, DEFAULT_LOOKBACK_MINUTES } from "../src/jobs/reconcile.mjs";

await main("reconcile", (argv) => {
  const a = parseArgs(argv, { connection: "uuid", "lookback-minutes": "minutes", object: "text" });
  return runReconcile({ connectionId: a.connection ?? null, lookbackMinutes: a["lookback-minutes"] ?? DEFAULT_LOOKBACK_MINUTES, object: a.object ?? null });
});
