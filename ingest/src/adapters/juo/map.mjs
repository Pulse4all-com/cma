/**
 * Juo subscriptions and events → the canonical items of cma.ingest_upsert_subscriptions and
 * cma.ingest_upsert_subscription_events (addition 0008zl). A whitelist: only the fields named here are read, so a
 * subscription's delivery address, its customer's name, email and phone, its payment method's details (holder, account,
 * card digits, billing address), its custom attributes and items' titles, an event's actor name, an error message, a
 * free-text reason, an update's input and anything Juo adds later never reach an item, raw, a log or the database.
 *
 *   subscription  { sourceId: id, customerSourceId: customer (the store's customer id: digits, from a number, a text or
 *                 a gid; an expanded customer's id), status (Juo's status in lower case: active, paused, canceled,
 *                 expired, failed, merged, never-subscribed; cancelled reads canceled), currentCycle, nextBillingAt
 *                 (nextBillingDate), billingInterval (billingPolicy.interval in lower case: day, week, month, year),
 *                 billingIntervalCount (billingPolicy.intervalCount), amountPerCycle (the sum of the current items'
 *                 totalPrice, the items Juo has not canceled), currency (currencyCode), paymentInstrumentType (the
 *                 expanded paymentMethod.instrument.type only: a type naming paypal → paypal, one naming a card → card,
 *                 any other → other; none when the payment method is not expanded), sourceCreatedAt (createdAt),
 *                 pausedAt, canceledAt, sourceUpdatedAt (updatedAt), raw: those values under Juo's names }
 *   event         { sourceId: id, subscriptionSourceId: subscriptionId (else the owner's id when the owner is a
 *                 subscription), eventType, occurredAt, actorType (staff, customer, system, bulk for bulk-action, api;
 *                 none for unknown), actorSourceId (a staff actor's id only), cycleIndex, attempt, errorCode (a code:
 *                 letters, digits and _, upper case), reasonCode (a reason from REASON_CODES only), statusFrom,
 *                 statusTo, raw: id, type, occurredAt, subscriptionId, customerId, actorType, actorId, cycleIndex,
 *                 attempt, errorCode, reason, previousStatus, status and a renewal's orderId }
 *
 * The event types (Juo's GET event types, read 28 October 2026; docs/ingest/README.md, section Juo):
 *   subscription:renewed                          renewed        data.cycleIndex, data.orderId
 *   subscription:renew-failed                     renew_failed   data.reason, attempt, errorCode, cycleIndex (errorMessage
 *                                                                never read)
 *   subscription:cancelled (alias :canceled)      canceled       data.previousStatus → status_to canceled; data.reason is the
 *                                                                caller's free text, kept only as a code of REASON_CODES
 *   subscription:paused                           paused         data.previousStatus → paused
 *   subscription:resumed                          resumed        data.previousStatus → active
 *   subscription:reactivated                      reactivated    data.previousStatus → active
 *   subscription:updated with a status change     status_changed data.status → data.input.status (for example ACTIVE → FAILED,
 *                                                                the system's move to failed); an update without a
 *                                                                status, or with the same one, is no event of the CMA
 * Every other event is read (its subscription is read again by the poll) and not stored (counted skipped).
 *
 * A reason enters only as a code of REASON_CODES (Juo's own codes); anything else a reason holds (a cancellation's free
 * text above all) is dropped and the event says reasonDropped: counted (reason_dropped), the value never logged.
 */
export const OBJECT_SUBSCRIPTION = "subscription";
export const OBJECT_EVENT = "subscription_event";
export const STATUSES = ["active", "paused", "canceled", "expired", "failed", "merged", "never-subscribed"];
/** The reasons kept, as Juo writes them: its own codes, never a caller's text */
export const REASON_CODES = ["billing-attempt-failed"];
/** Juo's event type → the CMA's, and the status the type moves a subscription to */
export const EVENT_TYPES = {
  "subscription:renewed": { type: "renewed", to: null },
  "subscription:renew-failed": { type: "renew_failed", to: null },
  "subscription:cancelled": { type: "canceled", to: "canceled" },
  "subscription:canceled": { type: "canceled", to: "canceled" },
  "subscription:paused": { type: "paused", to: "paused" },
  "subscription:resumed": { type: "resumed", to: "active" },
  "subscription:reactivated": { type: "reactivated", to: "active" },
  "subscription:updated": { type: "status_changed", to: null },
};
const ACTORS = { staff: "staff", customer: "customer", system: "system", "bulk-action": "bulk", bulk: "bulk", api: "api" };
const INTERVALS = ["day", "week", "month", "year"];

const ID = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,99}$/;
const TYPE = /^[a-z][a-z0-9-]*(:[a-z0-9/-]+)?$/;
const CODE = /^[A-Za-z][A-Za-z0-9_]{0,59}$/;

export const idOf = (v) => (typeof v === "string" && ID.test(v.trim()) ? v.trim() : null);

/** An event's type as the logs and the dry run count it: a type name (subscription:renewed), else "unknown". */
export const eventTypeOf = (e) => (typeof e?.type === "string" && e.type.length <= 60 && TYPE.test(e.type) ? e.type : "unknown");

/** A store's customer id as digits: from a number, a digit text or a gid (gid://shopify/Customer/123); an object's id. */
export function customerIdOf(v) {
  if (v && typeof v === "object") return customerIdOf(v.id);
  const s = typeof v === "number" && Number.isSafeInteger(v) && v > 0 ? String(v) : typeof v === "string" ? v.trim() : "";
  const m = /^(?:gid:\/\/[a-z]+\/[A-Za-z]+\/)?(\d{1,30})$/.exec(s);
  return m ? m[1] : null;
}

/** Juo's status in the CMA's spelling, or null for one it does not know: lower case, _ as -, cancelled as canceled. */
export function statusOf(v) {
  if (typeof v !== "string") return null;
  const s = v.trim().toLowerCase().replace(/_/g, "-").replace(/^cancelled$/, "canceled");
  return STATUSES.includes(s) ? s : null;
}

function timeOf(v) {
  if (typeof v !== "string" || !/^\d{4}-\d{2}-\d{2}T/.test(v)) return null;
  const ms = Date.parse(v);
  return Number.isFinite(ms) ? new Date(ms).toISOString() : null;
}

const wholeOf = (v, min, max) => (Number.isInteger(v) && v >= min && v <= max ? v : null);

/** The payment instrument's type: paypal, card or other, from the expanded payment method only; null without one. */
export function instrumentOf(paymentMethod) {
  const t = paymentMethod && typeof paymentMethod === "object" ? paymentMethod.instrument?.type : undefined;
  if (typeof t !== "string" || !t.trim()) return null;
  const s = t.trim().toLowerCase();
  return s.includes("paypal") ? "paypal" : s.includes("card") ? "card" : "other";
}

/** The sum of the current items' total prices, two decimals; null without a priced item. */
function amountOf(items) {
  if (!Array.isArray(items)) return null;
  let sum = null;
  for (const it of items) {
    if (!it || typeof it !== "object" || it.canceledAt) continue;
    const p = typeof it.totalPrice === "number" ? it.totalPrice : typeof it.totalPrice === "string" && /^\d+(\.\d+)?$/.test(it.totalPrice) ? Number(it.totalPrice) : NaN;
    if (Number.isFinite(p) && p >= 0) sum = (sum ?? 0) + p;
  }
  return sum === null ? null : Math.round(sum * 100) / 100;
}

const strip = (o) => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== null && v !== undefined));

/** One subscription of GET /subscriptions → its item, or null without an id or a status of the seven. */
export function subscriptionItem(s) {
  const sourceId = idOf(s?.id);
  const status = statusOf(s?.status);
  if (!sourceId || !status) return null;
  const interval = typeof s?.billingPolicy?.interval === "string" ? s.billingPolicy.interval.trim().toLowerCase() : null;
  const item = {
    sourceId,
    customerSourceId: customerIdOf(s?.customer),
    status,
    currentCycle: wholeOf(s?.currentCycle, 0, 1_000_000),
    nextBillingAt: timeOf(s?.nextBillingDate),
    billingInterval: INTERVALS.includes(interval) ? interval : null,
    billingIntervalCount: wholeOf(s?.billingPolicy?.intervalCount, 1, 1000),
    amountPerCycle: amountOf(s?.items),
    currency: typeof s?.currencyCode === "string" && /^[A-Z]{3}$/.test(s.currencyCode) ? s.currencyCode : null,
    paymentInstrumentType: instrumentOf(s?.paymentMethod),
    sourceCreatedAt: timeOf(s?.createdAt),
    pausedAt: timeOf(s?.pausedAt),
    canceledAt: timeOf(s?.canceledAt),
    sourceUpdatedAt: timeOf(s?.updatedAt),
  };
  // the mapped values under Juo's names only; the status as Juo wrote it, when it is one of the seven
  item.raw = strip({ id: sourceId, status: s.status.trim(), customer: item.customerSourceId, currentCycle: item.currentCycle,
    nextBillingDate: item.nextBillingAt, billingInterval: item.billingInterval, billingIntervalCount: item.billingIntervalCount,
    amountPerCycle: item.amountPerCycle, currencyCode: item.currency, instrumentType: item.paymentInstrumentType,
    createdAt: item.sourceCreatedAt, updatedAt: item.sourceUpdatedAt, canceledAt: item.canceledAt, pausedAt: item.pausedAt });
  return strip(item);
}

/** The subscription an event belongs to: its subscriptionId, else its owner's id when the owner is a subscription. */
export function eventSubscriptionOf(e) {
  return idOf(e?.subscriptionId) ?? (typeof e?.owner?.entity === "string" && e.owner.entity.toLowerCase() === "subscription" ? idOf(e.owner.id) : null);
}

/**
 * One event of GET /events → { item, reasonDropped } for an event the CMA keeps; { skip: 'type' } for an event of
 * another type (or an update without a status change); null when it lacks an id, a subscription or a time.
 */
export function eventItem(e) {
  const sourceId = idOf(e?.id);
  const subscriptionSourceId = eventSubscriptionOf(e);
  const occurredAt = timeOf(e?.occurredAt);
  const juoType = typeof e?.type === "string" && TYPE.test(e.type) ? e.type : null;
  if (!sourceId || !subscriptionSourceId || !occurredAt || !juoType) return null;
  const known = EVENT_TYPES[juoType];
  if (!known) return { skip: "type" };
  const data = e?.data && typeof e.data === "object" ? e.data : {};
  let statusFrom = null;
  let statusTo = known.to;
  if (known.type === "status_changed") {
    statusTo = statusOf(data.input && typeof data.input === "object" ? data.input.status : null);
    statusFrom = statusOf(data.status);
    if (!statusTo || statusTo === statusFrom) return { skip: "type" };
  } else if (known.to) {
    statusFrom = statusOf(data.previousStatus);
  }
  const actorRaw = typeof e?.actor === "string" ? e.actor : e?.actor?.type;
  const actorType = typeof actorRaw === "string" ? ACTORS[actorRaw.trim().toLowerCase()] ?? null : null;
  const actorSourceId = actorType === "staff" && e?.actor && typeof e.actor === "object" ? idOf(typeof e.actor.id === "number" ? String(e.actor.id) : e.actor.id) : null;
  const reasonHeld = typeof data.reason === "string" ? data.reason.trim() : null;
  const reasonCode = reasonHeld && REASON_CODES.includes(reasonHeld) ? reasonHeld : null;
  const reasonDropped = Boolean(reasonHeld) && !reasonCode;
  const errorCode = typeof data.errorCode === "string" && CODE.test(data.errorCode.trim()) ? data.errorCode.trim().toUpperCase() : null;
  const orderId = known.type === "renewed" ? customerIdOf(data.orderId) : null;
  const item = {
    sourceId, subscriptionSourceId, eventType: known.type, occurredAt, actorType, actorSourceId,
    cycleIndex: wholeOf(data.cycleIndex, 0, 1_000_000), attempt: wholeOf(data.attempt, 1, 1000), errorCode, reasonCode, statusFrom, statusTo,
  };
  item.raw = strip({ id: sourceId, type: juoType, occurredAt, subscriptionId: subscriptionSourceId, customerId: customerIdOf(e?.customerId),
    actorType, actorId: actorSourceId, cycleIndex: item.cycleIndex, attempt: item.attempt, errorCode, reason: reasonCode,
    previousStatus: statusFrom, status: statusTo, orderId });
  return { item: strip(item), reasonDropped };
}
