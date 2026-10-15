/**
 * One email poll of one HubSpot connection (brief B17b; the job ingest-poll-email, every minute):
 * the engagements (email.mjs), then the conversations (conversations.mjs: catalogs and the owner map
 * hourly, the changed threads with their new messages and events, the open check every ten minutes).
 * Each part runs on its own: a failure in one (a 429, a timeout, a scope not yet accepted) leaves its
 * cursor where it was and the other part still runs; the run's error is the first part's code.
 *
 * A connection is served only when its settings hold email_poll true (cma.set_connection_settings),
 * so a deploy of the job polls nothing until the app's new scopes are accepted and the connection is
 * configured (docs/b17b-email-ingest/MORNING_RUNBOOK.md, step 3). A run stops starting new pages after
 * RUN_MS, so a run every minute does not pile up behind the last; the cursors carry the rest.
 */
import { SourceError } from "../../core/http.mjs";
import { warn } from "../../core/log.mjs";
import { hubspotClient, tokenOf } from "./read.mjs";
import { emailSettings, pollEmails } from "./email.mjs";
import { conversationsContext, pollThreads, openCheck } from "./conversations.mjs";

export const RUN_MS = 40_000;

const codeOf = (err) => (err instanceof SourceError ? err.code : typeof err?.code === "string" ? err.code : "email_error");

/** Whether the email poll serves the connection (its configuration from cma.connection_config). */
export function emailPollEnabled(config) {
  return emailSettings(config).enabled;
}

/** Answers { counts, error, detail }: sync_run counts, the first part's code, outcome counts per kind for the log. */
export async function pollEmail({ connection, store, budget, config, now = Date.now() }) {
  const counts = { fetched: 0, upserted: 0, stale: 0, skipped: 0, failed: 0 };
  const detail = {};
  const deadline = now + RUN_MS;
  const api = hubspotClient(await tokenOf(connection), budget);
  const start = await store.emailStartOf();
  const floorMs = start ? ((await store.tenantStartOf(start))?.getTime() ?? null) : null;
  let error = null;
  const part = async (name, fn) => {
    try {
      await fn();
    } catch (err) {
      counts.failed += 1;
      error ??= codeOf(err);
      warn("email poll part stopped", { connection: connection.connectionId, part: name, code: codeOf(err) });
    }
  };
  await part("engagements", () => pollEmails({ api, store, config, now, floorMs, deadline, counts, detail }));
  await part("conversations", async () => {
    const ctx = await conversationsContext({ api, store, config, now, counts, detail });
    await pollThreads(ctx, { now, floorMs, deadline });
    await openCheck(ctx, { now });
  });
  return { counts, error, detail };
}
