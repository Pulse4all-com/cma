/**
 * A review's CRM contact (addition 0008ze), kept in the CMA, never written to the CRM. The order comes first: the
 * database links a review whose transaction reference names one commerce order of the tenant to that order, and to its
 * customer's contact (0008h), in cma.ingest_upsert_reviews. A review without an order and without a contact is then
 * looked up by the reviewer's email in the CRM connection the reviews connection names (setting crm_connection_id),
 * through that CRM adapter's contact lookup (HubSpot: an exact search, lower case): exactly one contact → the link
 * (cma.set_review_contact, level contact); none or several → no link. The email lives in memory for the search only;
 * it is never logged, stored or answered.
 *
 * The CRM's daily floor (the CRM connection's api_daily_floor_pct, default 25): every search is guarded by it. A poll
 * stops searching below it and leaves the rest of its reviews without a contact (counted as deferred; the reconcile
 * looks again); a backfill or reconcile pauses with daily_floor and resumes later. A rate limit, a missed slot or a
 * timeout on the CRM stops the searches that follow (they would hit the same limit).
 */
import { SourceError } from "../../core/http.mjs";
import { contextOf } from "../../core/connection.mjs";
import { storeFor } from "../../core/store.mjs";
import { ADAPTERS } from "../index.mjs";

/**
 * The CRM side of a reviews connection: { crm, adapter, floorPct } or null when it names no active CRM connection of
 * an adapter that can look contacts up. floorPct: that CRM adapter's daily floor for the job, null without one.
 */
export async function crmSideOf(store, settings, job) {
  const id = typeof settings?.crm_connection_id === "string" ? settings.crm_connection_id.trim() : "";
  if (!id) return null;
  const crm = await store.crmConnection(id);
  const adapter = crm && Object.hasOwn(ADAPTERS, crm.adapter) ? ADAPTERS[crm.adapter] : null;
  if (!crm || !adapter?.crm) return null;
  const floorPct = adapter.dailyFloor ? await adapter.dailyFloor({ store: storeFor(contextOf(crm), crm.connectionId), connection: crm, job }) : null;
  return { crm, adapter, floorPct };
}

/**
 * The contacts of the reviews in `emails` (review id → email, in memory), set in the CMA. Answers counts { one, none,
 * several, error, deferred, linked }. With pause, daily_floor is thrown (the run pauses); without it, the reviews left
 * are counted as deferred. The map is emptied before it returns or throws.
 */
export async function matchReviews({ store, side, emails, budget, pause }) {
  const counts = { one: 0, none: 0, several: 0, error: 0, deferred: 0, linked: 0 };
  let stopped = null;
  try {
    for (const [reviewId, address] of emails) {
      if (stopped) {
        counts[stopped === "daily_floor" ? "deferred" : "error"] += 1;
        continue;
      }
      let found;
      try {
        found = await side.adapter.crm.findContactsByEmail({ connection: side.crm, email: address, budget });
      } catch (err) {
        const code = err instanceof SourceError ? err.code : "error";
        if (code === "daily_floor" && pause) throw err;
        if (code === "daily_floor" || code === "rate_limited" || code === "paced" || code === "timeout") stopped = code;
        counts[code === "daily_floor" ? "deferred" : "error"] += 1;
        continue;
      } finally {
        emails.delete(reviewId);
      }
      if (found.length === 1) {
        counts.one += 1;
        const outcome = await store.setReviewContact(reviewId, side.crm.connectionId, found[0]);
        if (outcome === "linked" || outcome === "relinked") counts.linked += 1;
      } else {
        counts[found.length ? "several" : "none"] += 1;
      }
    }
  } finally {
    emails.clear();
  }
  return counts;
}
