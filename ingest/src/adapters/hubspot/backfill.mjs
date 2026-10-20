/**
 * HubSpot backfill (DESIGN §2, §5): everything from a start date (`--from`, default the tenant's
 * intake.start_date), through the same read-back as a webhook, paced under half of HubSpot's limits
 * (read.mjs RATES) and resumable: after every page the stream's cursor (cma.sync_cursor) holds where
 * it stands, and a run with the same start continues there (a finished one is walked again only by a run
 * with --again, src/jobs/backfill.mjs).
 *
 *   deal            CRM search by createdate, then by closedate (deals created earlier, closed since)
 *   ticket          by createdate, then closed_date
 *   crm_call        by hs_timestamp
 *   task            by hs_createdate, then by hs_timestamp (the due time: a task made before the start and
 *                   due after it; addition 0008n)
 *   contact         the contacts the CMA holds (0006: never the contact base; since 0008m also those an
 *                   email or inbox thread points to), by id, read with every mapped country slot
 *   form_submission every polled form's submissions, filling the answers of stored ones without them (forms.mjs)
 *   crm_email       email engagements by hs_timestamp, written as the email poll writes them (email.mjs)
 *   inbox_thread    inbox conversations by their latest message, with their messages (conversations.mjs)
 *                   Both default to cma.email_start_date_of (email.start_date, else intake.start_date)
 *                   and need the connection's email_poll setting
 *
 * Search streams: backfill:<object>:<property> = { from, value, done } (value: the last page's
 * highest property value, ms). A resumed query starts at that value; the objects at the boundary are
 * listed again and read once (their event keys are known).
 *
 * --again (since addition 0008za): every object the search streams list gets this run's version (againVersion), so
 * the stored deals and tickets are read again whether or not they changed, and the read-back writes what the adapter
 * now reads (their stage times, brief N21); an object both streams list is read once per run.
 */
import { SourceError } from "../../core/http.mjs";
import { hubspotClient, tokenOf } from "./read.mjs";
import { searchPages } from "./reconcile.mjs";
import { backfillForms } from "./forms.mjs";
import { backfillEmails } from "./email.mjs";
import { backfillThreads } from "./conversations.mjs";

export const BACKFILL_STREAMS = { deal: ["createdate", "closedate"], ticket: ["createdate", "closed_date"], crm_call: ["hs_timestamp"],
  task: ["hs_createdate", "hs_timestamp"] };
export const BACKFILL_OBJECTS = ["deal", "ticket", "crm_call", "task", "form_submission", "contact", "crm_email", "inbox_thread"];
const EMAIL_OBJECTS = new Set(["crm_email", "inbox_thread"]);

/** The default start of an object's backfill when --from is not given: the email objects' own; null for the rest (intake.start_date). */
export async function backfillFrom(object, store) {
  return EMAIL_OBJECTS.has(object) ? store.emailStartOf() : null;
}

/**
 * The version an --again run gives an object (addition 0008za): its modified time and the run, so an unchanged object
 * is read again by this run (once: its two streams list it with the same version) and by no later listing of it.
 * At most 40 characters, as every version (core/sync.mjs).
 */
export function againVersion(version, runAt) {
  return `${String(version ?? "unknown").slice(0, 24)}~a${runAt}`.slice(0, 40);
}

async function backfillSearch({ api, store, object, property, fromMs, untilMs, process, again = false, runAt = untilMs }) {
  const stream = `backfill:${object}:${property}`;
  const cur = await store.cursor(stream);
  if (cur?.from === fromMs && cur.done) return;
  const start = cur?.from === fromMs && Number.isFinite(cur.value) ? Math.max(fromMs, cur.value) : fromMs;
  let last = start;
  for await (const page of searchPages(api, object, property, start, untilMs)) {
    const items = again ? page.items.map((i) => ({ ...i, version: againVersion(i.version, runAt) })) : page.items;
    if (items.length) await process(object, items);
    if (page.last !== null) last = Math.max(last, page.last);
    await store.setCursor(stream, { from: fromMs, value: last, done: false });
  }
  await store.setCursor(stream, { from: fromMs, value: last, done: true });
}

async function backfillContacts({ store, fromMs, runAt, process }) {
  const stream = "backfill:contact";
  const cur = await store.cursor(stream);
  if (cur?.from === fromMs && cur.done) return;
  let after = cur?.from === fromMs ? (cur.after ?? null) : null;
  for (;;) {
    const ids = await store.heldContactIds(after, 500);
    if (!ids.length) break;
    // A run-specific version: every backfill run reads the held contacts again
    await process("contact", ids.map((id) => ({ id, version: `bf${runAt}` })));
    after = ids[ids.length - 1];
    await store.setCursor(stream, { from: fromMs, after, done: false });
  }
  await store.setCursor(stream, { from: fromMs, after, done: true });
}

/** The backfill of one object type from fromMs (ms) up to untilMs (the run's start). */
export async function backfill({ connection, store, budget, object, fromMs, untilMs, process, counts, again = false, runAt = untilMs }) {
  if (object === "form_submission") {
    await backfillForms({ connection, store, budget, fromMs, counts });
    return;
  }
  if (object === "contact") return backfillContacts({ store, fromMs, runAt: untilMs, process });
  if (object === "crm_email") return backfillEmails({ connection, store, budget, fromMs, untilMs, counts });
  if (object === "inbox_thread") return backfillThreads({ connection, store, budget, fromMs, untilMs, counts });
  const properties = BACKFILL_STREAMS[object];
  if (!properties) throw new SourceError("object_not_backfilled");
  const api = hubspotClient(await tokenOf(connection), budget);
  for (const property of properties) await backfillSearch({ api, store, object, property, fromMs, untilMs, process, again, runAt });
}
