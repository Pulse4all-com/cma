/**
 * The reviews' poll, reconcile and backfill (addition 0008zd, brief B18). No webhook exists for reviews, so a review
 * reaches the CMA only by these reads. Every page takes one path: mapped (map.mjs: the reviewer's email in memory only),
 * upserted (cma.ingest_upsert_reviews: the stale guard, the order link and the order's customer's contact), the
 * alerts raised for what was written (cma.ingest_review_alerts), the contacts of the reviews without one looked up by
 * email (match.mjs). Each read refreshes the channel catalog first (a new channel lands without a market and
 * not counted).
 *
 *   poll       every channel the source holds: the reviews submitted after its cursor (reviews:<channel id>, the
 *              start of the last poll that walked it) less two hours, since a review can reach the API after its
 *              submission time; without a cursor the last reviews_reconcile_days. Due on the connection's
 *              reviews_poll_interval_minutes (default 60; cursor reviews:cadence). A new review without a contact is
 *              looked up; below the CRM's daily floor the lookups stop (deferred) and the poll goes on
 *   reconcile  the reviews submitted in the connection's last reviews_reconcile_days (default 30; or from the job's
 *              look-back when that is longer), read again: a changed state, a reply, a veto; every review still
 *              without a link is looked up again; the CRM's daily floor pauses it
 *   backfill   --object review from --from, else reviews.history_start_date, else all history (from 1 January 2000,
 *              before the platform held a review): per channel in id order, a year at a time from the oldest,
 *              resumable (cursor backfill:review = { from, channel, value, done }); a finished one reads nothing
 *              unless --again; every review without a link looked up; the CRM's daily floor pauses it. Each
 *              channel ends with a summary line: reviews read and stored in this run, and the channel's link levels
 *              and oldest and newest submission held
 *
 * A 429 fails the run (rate_limited) where it stands: the cursors of the channels already read have moved, the next
 * run carries on. The counts are sync_run's: fetched (reviews read), upserted (inserted or updated), stale, skipped
 * (unchanged, unreadable, or of a channel the catalog lacks), failed (lookups that failed); the run's log line has the
 * details (links, lookups, alerts).
 */
import { JobBudget } from "../../core/budget.mjs";
import { info } from "../../core/log.mjs";
import { SourceError } from "../../core/http.mjs";
import { reviewSettings } from "./client.mjs";
import { clientFor } from "./read.mjs";
import { OBJECT_TYPE, channelItem, reviewOf } from "./map.mjs";
import { crmSideOf, matchReviews } from "./match.mjs";

export const RECONCILE_OBJECTS = [OBJECT_TYPE];
export const BACKFILL_OBJECTS = [OBJECT_TYPE];
export const OVERLAP_MS = 2 * 60 * 60_000;
export const CADENCE_STREAM = "reviews:cadence";
export const BACKFILL_STREAM = `backfill:${OBJECT_TYPE}`;
export const HISTORY_FLOOR_MS = Date.parse("2000-01-01T00:00:00Z");
const DAY_MS = 24 * 60 * 60_000;
const SLACK_MS = 2 * 60_000;

export const pollStream = (channelId) => `reviews:${channelId}`;

/** The detail counts a run logs next to sync_run's counts. */
export function emptyDetail() {
  return { inserted: 0, updated: 0, unchanged: 0, unknownChannel: 0, unreadable: 0, linkedOrder: 0, lookups: 0, contacts: 0, noContact: 0,
    severalContacts: 0, lookupsDeferred: 0, lookupsFailed: 0, alerts: 0, channels: 0 };
}

/** Whether the poll is due: no poll yet, or the connection's interval (less two minutes of the schedule's slack) has passed. */
export async function pollDue({ store, now = Date.now() }) {
  const s = reviewSettings((await store.config())?.settings ?? {});
  const last = (await store.cursor(CADENCE_STREAM))?.at;
  return !Number.isFinite(last) || now - last >= s.intervalMinutes * 60_000 - SLACK_MS;
}

/** The channel catalog from the source, then the channels the source still holds, in id order. */
async function refreshChannels(api, store, detail) {
  const items = (await api.channels()).map(channelItem).filter(Boolean);
  if (items.length) await store.upsertReviewChannels(items);
  const held = (await store.reviewChannels()).filter((c) => !c.deleted).map((c) => c.channelId).sort();
  detail.channels = held.length;
  return held;
}

/**
 * One page of reviews: mapped, upserted, the contacts looked up (every review without a link with lookAll, else the
 * new ones), the alerts raised. Answers the newest submission time of the page (ms).
 */
async function ingestPage({ store, side, rawItems, counts, detail, lookAll, budget, pause }) {
  const emails = new Map();
  try {
    const items = [];
    let newest = null;
    for (const r of rawItems) {
      const mapped = reviewOf(r);
      if (!mapped) {
        detail.unreadable += 1;
        continue;
      }
      items.push(mapped.item);
      if (mapped.email) emails.set(mapped.item.reviewId, mapped.email);
      newest = Math.max(newest ?? 0, Date.parse(mapped.item.submittedAt));
    }
    counts.fetched += rawItems.length;
    counts.skipped += rawItems.length - items.length;
    const rows = await store.upsertReviews(items);
    const changed = [];
    for (const row of rows) {
      if (row.outcome === "inserted" || row.outcome === "updated") {
        counts.upserted += 1;
        detail[row.outcome] += 1;
        changed.push(row.sourceId);
      } else if (row.outcome === "stale") {
        counts.stale += 1;
      } else {
        counts.skipped += 1;
        detail[row.outcome === "unknown_channel" ? "unknownChannel" : "unchanged"] += 1;
      }
      if (row.linkLevel === "order") detail.linkedOrder += 1;
    }
    // the alerts first: they do not wait on a contact, and a pause in the lookups below must not cost them
    if (changed.length) detail.alerts += await store.reviewAlerts(changed);
    // the reviews to look up: no order, no contact, an email, and new (a poll) or any (reconcile, backfill)
    const wanted = new Map(rows.filter((row) => row.linkLevel === "none" && emails.has(row.sourceId) && (lookAll || row.outcome === "inserted"))
      .map((row) => [row.sourceId, emails.get(row.sourceId)]));
    emails.clear();
    if (side && wanted.size) {
      const m = await matchReviews({ store, side, emails: wanted, budget, pause });
      detail.lookups += m.one + m.none + m.several + m.error;
      detail.contacts += m.one;
      detail.noContact += m.none;
      detail.severalContacts += m.several;
      detail.lookupsDeferred += m.deferred;
      detail.lookupsFailed += m.error;
      counts.failed += m.error;
    }
    wanted.clear();
    return newest;
  } finally {
    emails.clear();
  }
}

/** The CRM side and the budget its lookups run on: the job's own (reconcile, backfill), or one of its own with the floor (poll). */
async function crmOf(store, settings, job, budget) {
  const side = await crmSideOf(store, settings, job);
  if (!side) return { side: null, crmBudget: null };
  return { side, crmBudget: job === "poll" ? new JobBudget({}, undefined, { floorPct: side.floorPct }) : budget };
}

/** The poll of one connection: answers { counts, detail, usage } (usage: the CRM lookups' requests, when any). */
export async function pollReviews({ connection, store, budget, now = Date.now(), counts }) {
  const settings = (await store.config())?.settings ?? {};
  const s = reviewSettings(settings);
  const api = clientFor(connection, settings, budget);
  const { side, crmBudget } = await crmOf(store, settings, "poll", budget);
  const detail = emptyDetail();
  const channels = await refreshChannels(api, store, detail);
  for (const channelId of channels) {
    const cur = await store.cursor(pollStream(channelId));
    const since = (Number.isFinite(cur?.at) ? cur.at : now - s.reconcileDays * DAY_MS) - OVERLAP_MS;
    for await (const page of api.reviews(channelId, since, null)) {
      await ingestPage({ store, side, rawItems: page, counts, detail, lookAll: false, budget: crmBudget, pause: false });
    }
    await store.setCursor(pollStream(channelId), { at: Math.max(now, Number.isFinite(cur?.at) ? cur.at : 0) });
  }
  await store.setCursor(CADENCE_STREAM, { at: now });
  return { detail, usage: crmBudget && crmBudget !== budget ? crmBudget.usage() : {} };
}

/** The reconcile of one connection: its last reviews_reconcile_days (or the job's longer look-back) read again. */
export async function reconcile({ connection, store, budget, object, sinceMs, untilMs, counts }) {
  if (object !== OBJECT_TYPE) throw new SourceError("object_not_reconciled");
  const settings = (await store.config())?.settings ?? {};
  const s = reviewSettings(settings);
  const api = clientFor(connection, settings, budget);
  const { side, crmBudget } = await crmOf(store, settings, "reconcile", budget);
  const detail = emptyDetail();
  const from = Math.min(sinceMs, untilMs - s.reconcileDays * DAY_MS);
  for (const channelId of await refreshChannels(api, store, detail)) {
    for await (const page of api.reviews(channelId, from - 1, untilMs)) {
      await ingestPage({ store, side, rawItems: page, counts, detail, lookAll: true, budget: crmBudget, pause: true });
    }
  }
  info("reconcile: reviews", { connection: connection.connectionId, ...detail });
  return undefined;
}

/** Year windows [from, to) in ms between two instants, oldest first. */
export function yearWindows(fromMs, toMs) {
  const out = [];
  for (let w = fromMs; w < toMs;) {
    const d = new Date(w);
    const next = Math.min(Date.UTC(d.getUTCFullYear() + 1, 0, 1), toMs);
    out.push([w, next]);
    w = next;
  }
  return out;
}

/**
 * The backfill of one connection's reviews from fromMs (null: all history) up to untilMs, per channel in id order and a
 * year at a time, resumable from backfill:review; a finished one with the same start reads nothing.
 */
export async function backfill({ connection, store, budget, object, fromMs, untilMs, counts }) {
  if (object !== OBJECT_TYPE) throw new SourceError("object_not_backfilled");
  const from = Number.isFinite(fromMs) ? fromMs : null;
  const cur = await store.cursor(BACKFILL_STREAM);
  if (cur && cur.from === from && cur.done) return undefined;
  const same = cur && cur.from === from && !cur.done;
  const settings = (await store.config())?.settings ?? {};
  const api = clientFor(connection, settings, budget);
  const { side, crmBudget } = await crmOf(store, settings, "backfill", budget);
  const detail = emptyDetail();
  const channels = await refreshChannels(api, store, detail);
  let i = same && cur.channel ? channels.findIndex((id) => id >= cur.channel) : 0;
  if (i < 0) i = channels.length;
  for (; i < channels.length; i += 1) {
    const channelId = channels[i];
    const resumeAt = same && cur.channel === channelId && Number.isFinite(cur.value) ? cur.value : null;
    const read = { fetched: counts.fetched, upserted: counts.upserted };
    for (const [w0, w1] of yearWindows(resumeAt ?? from ?? HISTORY_FLOOR_MS, untilMs)) {
      for await (const page of api.reviews(channelId, w0 - 1, w1)) {
        await ingestPage({ store, side, rawItems: page, counts, detail, lookAll: true, budget: crmBudget, pause: true });
      }
      await store.setCursor(BACKFILL_STREAM, { from, channel: channelId, value: w1, done: false });
    }
    info("backfill: review channel", { connection: connection.connectionId, channel: channelId, read: counts.fetched - read.fetched,
      stored: counts.upserted - read.upserted, ...(await store.reviewChannelSummary(channelId)) });
    await store.setCursor(BACKFILL_STREAM, { from, channel: channels[i + 1] ?? null, value: null, done: false });
  }
  await store.setCursor(BACKFILL_STREAM, { from, done: true });
  info("backfill: reviews", { connection: connection.connectionId, ...detail });
  return undefined;
}
