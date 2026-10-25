/**
 * The Trusted Shops adapter (eTrusted API) as the jobs see it (addition 0008ze, brief B18). Polling only: a review
 * platform sends no webhook, so the server answers 404 on /trustedshops/<key> (kind poll) and nothing is written
 * through a route.
 *
 *   pollDue, pollReviews     the job ingest-poll-reviews (hourly at :07): the channel catalog, then each channel's
 *                            reviews after its cursor less two hours, on reviews_poll_interval_minutes
 *   reconcileObjects, reconcile   the job ingest-reconcile: the reviews of the last reviews_reconcile_days read again
 *   backfillObjects, backfill, backfillFrom   the job ingest-backfill: --object review from --from, else
 *                            reviews.history_start_date, else all history
 *   dailyFloor               the CRM connection's floor (its api_daily_floor_pct), which the contact lookups by email
 *                            respect: a reconcile or backfill pauses below it
 *   rates                    none: the adapter paces itself per connection (client.mjs)
 */
import { contextOf } from "../../core/connection.mjs";
import { storeFor } from "../../core/store.mjs";
import { ADAPTERS } from "../index.mjs";
import { pollDue, pollReviews, reconcile, backfill, RECONCILE_OBJECTS, BACKFILL_OBJECTS } from "./reconcile.mjs";

export const trustedshops = {
  name: "trustedshops",
  kind: "poll",
  holdsRecords: false,
  rates: {},
  pollDue,
  pollReviews,
  reconcileObjects: RECONCILE_OBJECTS,
  reconcile,
  backfillObjects: BACKFILL_OBJECTS,
  backfill,

  /** The backfill's start without --from: reviews.history_start_date, or all history when it is empty. */
  async backfillFrom(object, store) {
    const v = String((await store.settings())["reviews.history_start_date"] ?? "").trim();
    return v ? v : { allHistory: true };
  },

  /** The CRM connection's daily floor for the contact lookups (null without a CRM connection that names one). */
  async dailyFloor({ store, job }) {
    const id = String((await store.config())?.settings?.crm_connection_id ?? "").trim();
    const crm = id ? await store.crmConnection(id) : null;
    const adapter = crm && Object.hasOwn(ADAPTERS, crm.adapter) ? ADAPTERS[crm.adapter] : null;
    return adapter?.dailyFloor ? adapter.dailyFloor({ store: storeFor(contextOf(crm), crm.connectionId), connection: crm, job }) : null;
  },
};
