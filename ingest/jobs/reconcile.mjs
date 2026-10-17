// Cloud Run job ingest-reconcile (nightly, Europe/Amsterdam; the time is docs/ingest/deploy.sh's --reconcile-every):
//   node jobs/reconcile.mjs [--lookback-minutes <n>] [--connection <id>] [--object <type>]. See src/jobs/reconcile.mjs.
// One execution at a time: a second one started while the first still runs logs "reconcile skipped" and exits 0.
import { main, parseArgs } from "../src/jobs/runner.mjs";
import { runReconcile, DEFAULT_LOOKBACK_MINUTES } from "../src/jobs/reconcile.mjs";

await main("reconcile", (argv) => {
  const a = parseArgs(argv, { connection: "uuid", "lookback-minutes": "minutes", object: "text" });
  return runReconcile({ connectionId: a.connection ?? null, lookbackMinutes: a["lookback-minutes"] ?? DEFAULT_LOOKBACK_MINUTES, object: a.object ?? null });
}, { lock: true });
