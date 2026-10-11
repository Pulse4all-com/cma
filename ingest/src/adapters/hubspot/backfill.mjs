/**
 * HubSpot backfill (DESIGN §2, §5): everything from a start date (`--from`, default the tenant's
 * intake.start_date), through the same read-back as a webhook, paced under half of HubSpot's limits
 * (read.mjs RATES) and resumable: after every page the stream's cursor (cma.sync_cursor) holds where
 * it stands, and a run with the same start continues there.
 *
 *   deal            CRM search by createdate, then by closedate (deals created earlier, closed since)
 *   ticket          by createdate, then closed_date
 *   crm_call        by hs_timestamp
 *   contact         the contacts the CMA holds (0006: never the contact base), by id
 *   form_submission every counted form's submissions (forms.mjs)
 *
 * Search streams: backfill:<object>:<property> = { from, value, done } (value: the last page's
 * highest property value, ms). A resumed query starts at that value; the objects at the boundary are
 * listed again and read once (their event keys are known).
 */
import { SourceError } from "../../core/http.mjs";
import { hubspotClient, tokenOf } from "./read.mjs";
import { searchPages } from "./reconcile.mjs";
import { backfillForms } from "./forms.mjs";

export const BACKFILL_STREAMS = { deal: ["createdate", "closedate"], ticket: ["createdate", "closed_date"], crm_call: ["hs_timestamp"] };
export const BACKFILL_OBJECTS = ["deal", "ticket", "crm_call", "form_submission", "contact"];

async function backfillSearch({ api, store, object, property, fromMs, untilMs, process }) {
  const stream = `backfill:${object}:${property}`;
  const cur = await store.cursor(stream);
  if (cur?.from === fromMs && cur.done) return;
  const start = cur?.from === fromMs && Number.isFinite(cur.value) ? Math.max(fromMs, cur.value) : fromMs;
  let last = start;
  for await (const page of searchPages(api, object, property, start, untilMs)) {
    if (page.items.length) await process(object, page.items);
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
export async function backfill({ connection, store, budget, object, fromMs, untilMs, process, counts }) {
  if (object === "form_submission") {
    await backfillForms({ connection, store, budget, fromMs, counts });
    return;
  }
  if (object === "contact") return backfillContacts({ store, fromMs, runAt: untilMs, process });
  const properties = BACKFILL_STREAMS[object];
  if (!properties) throw new SourceError("object_not_backfilled");
  const api = hubspotClient(await tokenOf(connection), budget);
  for (const property of properties) await backfillSearch({ api, store, object, property, fromMs, untilMs, process });
}
