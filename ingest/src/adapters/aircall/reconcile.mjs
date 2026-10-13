/**
 * Aircall reconcile and backfill (DESIGN §2, §5): GET /v1/calls with from and to (UNIX seconds, the
 * call's creation) in windows of one day, ascending, 50 per page. Aircall's call list stops at 10,000
 * calls per query (developer.aircall.io, Calls: "use the from param as much as possible"), so a window
 * holding more is split in halves until it fits. Every listed call becomes a synthetic event
 * (sync:telephony_call:<id>:<fingerprint>) on the webhook's read-back and upserts, carrying the listed
 * object in memory: Aircall's list answers the full call, so it is not read a second time, and an
 * unchanged call (same fingerprint) is read once however often a job lists it.
 *
 * Both first check the account: GET /v1/company must name the company the connection pins
 * (external_account_id), else nothing is listed (account_mismatch).
 *
 *   reconcile  the look-back (26 hours by default), then the webhook: GET /v1/webhooks and the one
 *              whose id is the connection setting webhook_id. Not set → the run fails with
 *              webhook_id_not_set; not there → webhook_missing; its token is not the connection's
 *              signing secret → webhook_token_mismatch; inactive (Aircall disables a webhook after
 *              its deliveries kept failing) → re-activated with PUT active true and its own events
 *              (the token stays), recorded as the run's error webhook_reactivated, or webhook_inactive
 *              when that fails. A job never creates a webhook (a new one has a new token).
 *   backfill   --object telephony_call from intake.start_date (or --from), resumable: after every day
 *              the cursor backfill:telephony_call = { from, value, done } holds where it stands.
 *
 * A replay connection (dev, INGEST_ALLOW_REPLAY=1 and the setting replay) has no API: the reconcile
 * lists nothing and the backfill refuses (replay_connection).
 */
import { SourceError } from "../../core/http.mjs";
import { getSecret } from "../../core/secrets.mjs";
import { clientFor, assertAccount, replayOn } from "./read.mjs";
import { OBJECT_TYPE, EVENTS, fingerprint, idOf } from "./map.mjs";
import { sameToken } from "./verify.mjs";

export const RECONCILE_OBJECTS = [OBJECT_TYPE];
export const BACKFILL_OBJECTS = [OBJECT_TYPE];
const DAY_MS = 24 * 60 * 60_000;
const LIST_MAX = 10_000;
const MIN_WINDOW_S = 60;

/** Day windows [from, to) in ms between two instants. */
export function dayWindows(fromMs, toMs) {
  const out = [];
  for (let w = fromMs; w < toMs; w += DAY_MS) out.push([w, Math.min(w + DAY_MS, toMs)]);
  return out;
}

/**
 * The calls created in one window, page by page: yields [{ id, version, inline }]. A window over the
 * list's 10,000 cap is split in halves; one of a minute that still holds more is list_window_full.
 */
export async function* listWindow(api, fromMs, toMs) {
  const stack = [[Math.floor(fromMs / 1000), Math.floor(toMs / 1000)]];
  while (stack.length) {
    const [fromS, toS] = stack.shift();
    for (let page = 1; ; page += 1) {
      const at = new Date().toISOString();
      const { calls, meta } = await api.listCalls(fromS, toS, page);
      if (page === 1 && Number(meta.total) > LIST_MAX) {
        if (toS - fromS <= MIN_WINDOW_S) throw new SourceError("list_window_full");
        const mid = fromS + Math.floor((toS - fromS) / 2);
        stack.unshift([fromS, mid], [mid, toS]);
        break;
      }
      const items = calls.filter((c) => idOf(c?.id)).map((c) => ({ id: idOf(c.id), version: fingerprint(c), inline: { object: c, at, source: "api" } }));
      if (items.length) yield items;
      if (!calls.length || !meta.next_page_link || page >= LIST_MAX / 50) break;
    }
  }
}

/**
 * The webhook check: an error code, or null when the webhook is there, active and holds this
 * connection's token. An inactive one is re-activated (and that is the run's error, so it is seen).
 */
export async function checkWebhook(api, connection, settings) {
  const id = typeof settings?.webhook_id === "string" ? settings.webhook_id.trim() : "";
  if (!id) return "webhook_id_not_set";
  const hook = (await api.webhooks()).find((w) => String(w?.webhook_id ?? "") === id);
  if (!hook) return "webhook_missing";
  let secret = null;
  try {
    secret = await getSecret(connection.signingSecretName);
  } catch {
    return "signing_secret_unavailable";
  }
  const sameAsSecret = (token) => sameToken(typeof token === "string" ? token : "", secret);
  // The list shows each webhook's token (developer.aircall.io, Webhooks); compared when it is there
  if (hook.token !== undefined && hook.token !== null && !sameAsSecret(hook.token)) return "webhook_token_mismatch";
  if (hook.active === true) return null;
  const events = Array.isArray(hook.events) && hook.events.length ? hook.events : Object.keys(EVENTS);
  let updated;
  try {
    updated = await api.updateWebhook(id, { active: true, events });
  } catch {
    return "webhook_inactive";
  }
  if (updated?.active !== true) return "webhook_inactive";
  return updated.token === undefined || updated.token === null || sameAsSecret(updated.token) ? "webhook_reactivated" : "webhook_reactivated_token_changed";
}

/** Reconcile of telephony calls created between sinceMs and untilMs → process(items); answers { error } of the webhook check. */
export async function reconcile({ connection, store, budget, object, sinceMs, untilMs, process }) {
  if (object !== OBJECT_TYPE) throw new SourceError("object_not_reconciled");
  const settings = (await store.config())?.settings ?? {};
  if (replayOn(settings)) return undefined;
  const api = await clientFor(connection, settings, budget);
  await assertAccount(api, connection);
  for (const [w0, w1] of dayWindows(sinceMs, untilMs)) {
    for await (const items of listWindow(api, w0, w1)) await process(OBJECT_TYPE, items);
  }
  const error = await checkWebhook(api, connection, settings);
  return error ? { error } : undefined;
}

/** The backfill of telephony calls from fromMs up to untilMs (the run's start), a day at a time, resumable. */
export async function backfill({ connection, store, budget, object, fromMs, untilMs, process }) {
  if (object !== OBJECT_TYPE) throw new SourceError("object_not_backfilled");
  const settings = (await store.config())?.settings ?? {};
  if (replayOn(settings)) throw new SourceError("replay_connection");
  const stream = `backfill:${OBJECT_TYPE}`;
  const cur = await store.cursor(stream);
  if (cur?.from === fromMs && cur.done) return undefined;
  const start = cur?.from === fromMs && Number.isFinite(cur.value) ? Math.max(fromMs, cur.value) : fromMs;
  const api = await clientFor(connection, settings, budget);
  await assertAccount(api, connection);
  let last = start;
  for (const [w0, w1] of dayWindows(start, untilMs)) {
    for await (const items of listWindow(api, w0, w1)) await process(OBJECT_TYPE, items);
    last = w1;
    await store.setCursor(stream, { from: fromMs, value: last, done: false });
  }
  await store.setCursor(stream, { from: fromMs, value: last, done: true });
  return undefined;
}
