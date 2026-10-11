// Cloud Run job ingest-poll-forms (every minute): node jobs/poll-forms.mjs [--connection <id>]. See src/jobs/poll-forms.mjs.
import { main, parseArgs } from "../src/jobs/runner.mjs";
import { runPollForms } from "../src/jobs/poll-forms.mjs";

await main("poll-forms", (argv) => {
  const a = parseArgs(argv, { connection: "uuid" });
  return runPollForms({ connectionId: a.connection ?? null });
});
