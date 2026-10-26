// Cloud Run job ingest-import-legacy-calls (manual, no schedule): node jobs/import-legacy-calls.mjs --connection <CRM
// connection id> --file gs://<bucket>/<object> --source-system <name> --cutover <YYYY-MM-DD> --date-format <DD-MM-YYYY>
// --columns <role=header,…> --meanings "<label>=<meaning key>;…" [--min-customer-id-digits <n>] [--unmatched store|skip] [--dry-run]. See
// src/jobs/import-legacy-calls.mjs and docs/import/legacy-calls.md. One execution at a time: a second one started while the first still runs logs
// "import-legacy-calls skipped" and exits 0.
import { main, parseArgs } from "../src/jobs/runner.mjs";
import { runImportLegacyCalls } from "../src/jobs/import-legacy-calls.mjs";

await main("import-legacy-calls", (argv) => runImportLegacyCalls(parseArgs(argv, {
  connection: "uuid", file: "text", "source-system": "text", cutover: "date", "date-format": "text", columns: "text", meanings: "text",
  "min-customer-id-digits": "text", unmatched: "text", "dry-run": "flag",
})), { lock: true });
