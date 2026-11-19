/**
 * Juo subscriptions, lines, products and events → the canonical items of cma.ingest_upsert_subscriptions,
 * cma.ingest_upsert_subscription_lines, cma.ingest_upsert_subscription_products, cma.ingest_upsert_subscription_events and
 * cma.ingest_upsert_billing_events (additions 0008zl, 0009w). A whitelist: only the fields named here are read, so a
 * subscription's delivery address, its customer's name, email and phone, its payment method's details (holder, account,
 * card digits, billing address), its and its lines' custom attributes, a line's title, a discount's code, an event's
 * actor name, an error message, a chargeback's reason message, a refund's note, a free-text reason, an update's input and
 * anything Juo adds later never reach an item, raw, a log or the database. A product's or variant's title and SKU are the
 * store's catalog text: kept up to 100 characters, left out (and counted) when they hold an @ or a control character.
 *
 *   subscription  { sourceId: id, sourceNumber (serial, #2502), customerSourceId: customer (the store's customer id:
 *                 digits, from a number, a text or a gid; an expanded customer's id), status (Juo's status in lower case:
 *                 active, paused, canceled, expired, failed, merged, never-subscribed; cancelled reads canceled),
 *                 currentCycle, nextBillingAt (nextBillingDate), billingInterval (billingPolicy.interval in lower case: day,
 *                 week, month, year), billingIntervalCount (billingPolicy.intervalCount), amountPerCycle (the sum of the
 *                 current items' totalPrice, the items Juo has not canceled), currency (currencyCode),
 *                 paymentInstrumentType (the expanded paymentMethod.instrument.type only, as one of INSTRUMENTS; none when
 *                 the payment method is not expanded), minCycles and maxCycles (billingPolicy's, else the highest of its
 *                 current lines'), discountCount (how many discounts; never a code), lineCount (the lines Juo has not
 *                 canceled), sourceCreatedAt (createdAt), pausedAt, canceledAt, sourceUpdatedAt (updatedAt), raw: those
 *                 values under Juo's names }
 *   line          { sourceId: item id, subscriptionSourceId, productSourceId (product), variantSourceId (variant), quantity,
 *                 amountPerCycle (totalPrice), currency (the subscription's), billingInterval and billingIntervalCount
 *                 (the line's billingPolicy, else the subscription's), minCycles, maxCycles, recurringCycleLimit (null:
 *                 every cycle; 1: a one-time add-on), canceledAt, raw } — never its title, subtitle or custom attributes
 *   variant       { productSourceId, variantSourceId, productTitle, variantTitle, sku, productStatus } from GET /products
 *   event         { sourceId: id, subscriptionSourceId: subscriptionId (else the owner's id when the owner is a
 *                 subscription), eventType, occurredAt, actorType (staff, customer, system, bulk for bulk-action, api;
 *                 none for unknown), actorSourceId (a staff actor's id only), cycleIndex, attempt, errorCode (a code:
 *                 letters, digits and _, upper case), reasonCode (a reason from REASON_CODES only), statusFrom, statusTo,
 *                 billingFromAt, billingToAt, causeCode, intervalFrom, intervalCountFrom, intervalTo, intervalCountTo,
 *                 linesAdded, linesRemoved, linesUpdated, relatedSubscriptionSourceId, operationSourceId (operationId),
 *                 orderSourceId (a renewal's data.orderId: the store's order, digits), raw }
 *   billing event { sourceId: id, kind, occurredAt, subscriptionSourceId (when Juo names it), customerSourceId
 *                 (customerId), orderSourceId (data.orderId: the store's order, digits), renewalSourceId (data.renewalId),
 *                 ownerSourceId (owner.id: the chargeback's, refund's or invoice's order's own id), amount and currency
 *                 (data.value or data.total), returnCode (a chargeback's data.reasonCode as a code: a SEPA return code
 *                 such as MD01: four upper-case letters or digits; a card dispute reason such as fraudulent from
 *                 CARD_DISPUTE_REASONS only; reasonMessage never read), instrumentType
 *                 (data.instrumentType as one of INSTRUMENTS), attempt, errorCode, partial (a refund's), raw }
 *
 * The event types (Juo's GET event-types, read 18 November 2026; docs/ingest/README.md, section Juo):
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
 *   subscription:purchased, :created              purchased, created
 *   subscription:migrated                         migrated       data.currentCycle → cycleIndex, data.nextBillingDate →
 *                                                                billingToAt
 *   subscription:skipped                          skipped        data.skippedDate → billingFromAt, data.nextBillingDate →
 *                                                                billingToAt
 *   subscription:next-billing-date-changed        billing_date_moved  data.from, data.to, data.cause (requested, skipped,
 *                                                                resumed, reactivated, reconciled)
 *   subscription:frequency-changed                interval_changed  data.from and data.to {interval, intervalCount}
 *   subscription:lines-changed                    lines_changed  the counts of data.added, removed, updated (ids not kept)
 *   subscription:line-added, -removed, -updated   lines_changed  1 added, removed or updated (the operation id pairs them
 *                                                                with a lines-changed of the same change)
 *   subscription:payment-method-changed           payment_method_changed  (the payment methods' ids not kept)
 *   subscription:discount-added, -removed, -updated, -code-applied, -free-shipping-applied
 *                                                 discount_changed  cause added, removed, updated, code_applied,
 *                                                                free_shipping (never the code or the value)
 *   subscription:merged-to, -from, split-to, -from merged_to, merged_from, split_to, split_from  the other subscription's
 *                                                                id when the payload names one
 *   subscription:update-failed                    update_failed  data.errorCode (never a message)
 *   subscription:chargeback-created, subscription:refund-created, -completed, -failed: the same chargeback or refund as
 *                                                 the billing family's chargeback:created and refund:*, so skipped and
 *                                                 counted duplicate_skipped
 * Every other event of the subscription family (the cancellation flow, a delivery address change) is read (its
 * subscription is read again by the poll) and not stored (counted skipped). Juo's renewal notice (renewal:notification-sent,
 * category notification) is never requested, so neither it nor its payload reaches the adapter: its payload names a
 * recipient, and mail activity reaches the CMA through the shared Gmail source, not through Juo (Decision log, 19 Nov 2026).
 *
 * The billing types (BILLING_KINDS): chargeback:created chargeback, refund:created refund_created, refund:completed
 * refund_completed, refund:failed refund_failed, invoice:placed invoice_placed, invoice:paid invoice_paid, invoice:overdue
 * invoice_overdue, invoice:payment-failed invoice_payment_failed, order:placement-failed order_placement_failed,
 * order:draft-created order_draft_created.
 *
 * A reason enters only as a code of REASON_CODES (Juo's own codes); anything else a reason holds (a cancellation's free
 * text above all) is dropped and the event says reasonDropped: counted (reason_dropped), the value never logged. A
 * chargeback's reason code out of the code form is dropped alike (returnCodeDropped, counted return_code_dropped). An
 * instrument type the mapping does not know is stored as other and named (instrumentUnknown: Juo's type name, counted
 * instrument_unknown).
 */
export const OBJECT_SUBSCRIPTION = "subscription";
export const OBJECT_PRODUCT = "subscription_product";
export const OBJECT_EVENT = "subscription_event";
export const OBJECT_BILLING = "billing_event";
export const STATUSES = ["active", "paused", "canceled", "expired", "failed", "merged", "never-subscribed"];
/** The reasons kept, as Juo writes them: its own codes, never a caller's text */
export const REASON_CODES = ["billing-attempt-failed"];
/** The payment instrument's types in the CMA's codes (cma.payment_instrument_type_ok) */
export const INSTRUMENTS = ["card", "paypal", "sepa_direct_debit", "ideal", "bancontact", "invoice", "other"];
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
  "subscription:purchased": { type: "purchased", to: null },
  "subscription:created": { type: "created", to: null },
  "subscription:migrated": { type: "migrated", to: null },
  "subscription:skipped": { type: "skipped", to: null },
  "subscription:next-billing-date-changed": { type: "billing_date_moved", to: null },
  "subscription:frequency-changed": { type: "interval_changed", to: null },
  "subscription:lines-changed": { type: "lines_changed", to: null },
  "subscription:line-added": { type: "lines_changed", to: null, lines: "linesAdded" },
  "subscription:line-removed": { type: "lines_changed", to: null, lines: "linesRemoved" },
  "subscription:line-updated": { type: "lines_changed", to: null, lines: "linesUpdated" },
  "subscription:payment-method-changed": { type: "payment_method_changed", to: null },
  "subscription:discount-added": { type: "discount_changed", to: null, cause: "added" },
  "subscription:discount-removed": { type: "discount_changed", to: null, cause: "removed" },
  "subscription:discount-updated": { type: "discount_changed", to: null, cause: "updated" },
  "subscription:discount-code-applied": { type: "discount_changed", to: null, cause: "code_applied" },
  "subscription:discount-free-shipping-applied": { type: "discount_changed", to: null, cause: "free_shipping" },
  "subscription:merged-to": { type: "merged_to", to: null },
  "subscription:merged-from": { type: "merged_from", to: null },
  "subscription:split-to": { type: "split_to", to: null },
  "subscription:split-from": { type: "split_from", to: null },
  "subscription:update-failed": { type: "update_failed", to: null },
};
/** The subscription family's copies of a billing event: skipped, counted duplicate_skipped */
export const DUPLICATE_TYPES = ["subscription:chargeback-created", "subscription:refund-created", "subscription:refund-completed",
  "subscription:refund-failed"];
/** Juo's billing type → the CMA's billing event kind */
export const BILLING_KINDS = {
  "chargeback:created": "chargeback",
  "refund:created": "refund_created",
  "refund:completed": "refund_completed",
  "refund:failed": "refund_failed",
  "invoice:placed": "invoice_placed",
  "invoice:paid": "invoice_paid",
  "invoice:overdue": "invoice_overdue",
  "invoice:payment-failed": "invoice_payment_failed",
  "order:placement-failed": "order_placement_failed",
  "order:draft-created": "order_draft_created",
};
const BILLING_CAUSES = ["requested", "skipped", "resumed", "reactivated", "reconciled"];
const ACTORS = { staff: "staff", customer: "customer", system: "system", "bulk-action": "bulk", bulk: "bulk", api: "api" };
const INTERVALS = ["day", "week", "month", "year"];

const ID = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,99}$/;
const TYPE = /^[a-z][a-z0-9-]*(:[a-z0-9/-]+)?$/;
const CODE = /^[A-Za-z][A-Za-z0-9_]{0,59}$/;
/** A return code: a payment scheme's four-character code (SEPA's ISO 20022 MD01, AM04); never anything that could hold an
 * account number or a name. A card dispute reason enters only from CARD_DISPUTE_REASONS */
const RETURN_CODE = /^[A-Z0-9]{4}$/;
/** The card schemes' dispute reasons a chargeback may carry, as the payment providers write them (a fixed list, as
 * REASON_CODES): any other word is dropped and counted return_code_dropped, so the dry run shows a new one */
export const CARD_DISPUTE_REASONS = ["bank_cannot_process", "check_returned", "credit_not_processed", "customer_initiated", "debit_not_authorized",
  "duplicate", "fraudulent", "general", "incorrect_account_details", "insufficient_funds", "noncompliant", "product_not_received",
  "product_unacceptable", "subscription_canceled", "unrecognized"];
const NUMBER = /^#?[A-Za-z0-9-]{1,30}$/;
const PRODUCT_STATUS = /^[a-z][a-z_]{0,19}$/;
/** An instrument type's name as the logs and the dry run show it: Juo's own word for the type, never a value */
export const TYPE_NAME = /^[A-Za-z][A-Za-z0-9_-]{0,39}$/;

export const idOf = (v) => (typeof v === "string" && ID.test(v.trim()) ? v.trim() : null);

/** An event's type as the logs and the dry run count it: a type name (subscription:renewed), else "unknown". */
export const eventTypeOf = (e) => (typeof e?.type === "string" && e.type.length <= 60 && TYPE.test(e.type) ? e.type : "unknown");

/** Whether an event is of the billing family (BILLING_KINDS). */
export const isBillingEvent = (e) => typeof e?.type === "string" && Object.hasOwn(BILLING_KINDS, e.type);

/** A store's customer id as digits: from a number, a digit text or a gid (gid://shopify/Customer/123); an object's id. */
export function customerIdOf(v) {
  if (v && typeof v === "object") return customerIdOf(v.id);
  const s = typeof v === "number" && Number.isSafeInteger(v) && v > 0 ? String(v) : typeof v === "string" ? v.trim() : "";
  const m = /^(?:gid:\/\/[a-z]+\/[A-Za-z]+\/)?(\d{1,30})$/.exec(s);
  return m ? m[1] : null;
}

/** A store's product or variant id: digits (from a number, a text or a gid; an object's id), else another id of the id form. */
export function catalogIdOf(v) {
  if (v && typeof v === "object") return catalogIdOf(v.id);
  return customerIdOf(v) ?? idOf(v);
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
const intervalOf = (v) => (typeof v === "string" && INTERVALS.includes(v.trim().toLowerCase()) ? v.trim().toLowerCase() : null);

/** A price or amount: a number or its digits as text, at least 0, two decimals; null otherwise. */
function moneyOf(v) {
  const p = typeof v === "number" ? v : typeof v === "string" && /^\d+(\.\d+)?$/.test(v.trim()) ? Number(v) : NaN;
  return Number.isFinite(p) && p >= 0 ? Math.round(p * 100) / 100 : null;
}
const currencyOf = (v) => (typeof v === "string" && /^[A-Z]{3}$/.test(v) ? v : null);

/**
 * An instrument's type as one of INSTRUMENTS: { code, unknown } where unknown is Juo's own type name when the mapping does
 * not know it (stored as other), else null. Juo writes types as credit-card, CreditCard, paypal, sepa-direct-debit,
 * SepaDirectDebit; null without a type.
 */
export function instrumentInfoOf(type) {
  if (typeof type !== "string" || !type.trim()) return null;
  const s = type.trim().toLowerCase().replace(/[^a-z]/g, "");
  const code = s.includes("paypal") ? "paypal" : s.includes("sepa") ? "sepa_direct_debit" : s === "ideal" ? "ideal"
    : s.includes("bancontact") ? "bancontact" : s.includes("invoice") ? "invoice" : s.includes("card") ? "card" : "other";
  return { code, unknown: code === "other" ? (TYPE_NAME.test(type.trim()) ? type.trim() : "unnamed") : null };
}

/** The payment instrument's type from the expanded payment method only (INSTRUMENTS); null without one. */
export function instrumentOf(paymentMethod) {
  const t = paymentMethod && typeof paymentMethod === "object" ? paymentMethod.instrument?.type : undefined;
  return instrumentInfoOf(t)?.code ?? null;
}

/** The current items: those Juo has not canceled. */
const currentItems = (items) => (Array.isArray(items) ? items.filter((it) => it && typeof it === "object" && !it.canceledAt) : []);

/** The sum of the current items' total prices, two decimals; null without a priced item. */
function amountOf(items) {
  let sum = null;
  for (const it of currentItems(items)) {
    const p = moneyOf(it.totalPrice);
    if (p !== null) sum = (sum ?? 0) + p;
  }
  return sum === null ? null : Math.round(sum * 100) / 100;
}

/** The highest of the current items' billing policy's cycle bound (minCycles or maxCycles); null when none states one. */
function linesCycles(items, key) {
  const v = currentItems(items).map((it) => wholeOf(it.billingPolicy?.[key], 0, 1000)).filter((x) => x !== null);
  return v.length ? Math.max(...v) : null;
}

const strip = (o) => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== null && v !== undefined));

/**
 * One subscription of GET /subscriptions → its item, or null without an id or a status of the seven. instrumentUnknown
 * (not part of the item: the adapter takes it out) names an instrument type the mapping does not know.
 */
export function subscriptionItem(s) {
  const sourceId = idOf(s?.id);
  const status = statusOf(s?.status);
  if (!sourceId || !status) return null;
  const instrument = instrumentInfoOf(s?.paymentMethod && typeof s.paymentMethod === "object" ? s.paymentMethod.instrument?.type : undefined);
  const number = typeof s?.serial === "string" && NUMBER.test(s.serial.trim()) ? s.serial.trim() : null;
  const item = {
    sourceId,
    sourceNumber: number,
    customerSourceId: customerIdOf(s?.customer),
    status,
    currentCycle: wholeOf(s?.currentCycle, 0, 1_000_000),
    nextBillingAt: timeOf(s?.nextBillingDate),
    billingInterval: intervalOf(s?.billingPolicy?.interval),
    billingIntervalCount: wholeOf(s?.billingPolicy?.intervalCount, 1, 1000),
    amountPerCycle: amountOf(s?.items),
    currency: currencyOf(s?.currencyCode),
    paymentInstrumentType: instrument?.code ?? null,
    minCycles: wholeOf(s?.billingPolicy?.minCycles, 0, 1000) ?? linesCycles(s?.items, "minCycles"),
    maxCycles: wholeOf(s?.billingPolicy?.maxCycles, 0, 1000) ?? linesCycles(s?.items, "maxCycles"),
    discountCount: Array.isArray(s?.discounts) ? Math.min(s.discounts.length, 1000) : null,
    lineCount: Array.isArray(s?.items) ? Math.min(currentItems(s.items).length, 1000) : null,
    sourceCreatedAt: timeOf(s?.createdAt),
    pausedAt: timeOf(s?.pausedAt),
    canceledAt: timeOf(s?.canceledAt),
    sourceUpdatedAt: timeOf(s?.updatedAt),
  };
  // the mapped values under Juo's names only; the status as Juo wrote it, when it is one of the seven
  item.raw = strip({ id: sourceId, status: s.status.trim(), customer: item.customerSourceId, currentCycle: item.currentCycle,
    nextBillingDate: item.nextBillingAt, billingInterval: item.billingInterval, billingIntervalCount: item.billingIntervalCount,
    amountPerCycle: item.amountPerCycle, currencyCode: item.currency, instrumentType: item.paymentInstrumentType,
    createdAt: item.sourceCreatedAt, updatedAt: item.sourceUpdatedAt, canceledAt: item.canceledAt, pausedAt: item.pausedAt,
    serial: item.sourceNumber, minCycles: item.minCycles, maxCycles: item.maxCycles, discountCount: item.discountCount,
    lineCount: item.lineCount });
  const out = strip(item);
  if (instrument?.unknown) Object.defineProperty(out, "instrumentUnknown", { value: instrument.unknown, enumerable: false });
  return out;
}

/**
 * A subscription's lines (items, canceled ones included) → line items: { lines, unreadable }. A line without an id is
 * unreadable. The interval is the line's own billing policy's, else the subscription's.
 */
export function lineItems(s) {
  const subscriptionSourceId = idOf(s?.id);
  const lines = [];
  let unreadable = 0;
  if (!subscriptionSourceId || !Array.isArray(s?.items)) return { lines, unreadable };
  const seen = new Set();
  for (const it of s.items) {
    const sourceId = it && typeof it === "object" ? idOf(it.id) : null;
    if (!sourceId || seen.has(sourceId)) {
      unreadable += 1;
      continue;
    }
    seen.add(sourceId);
    const item = {
      sourceId,
      subscriptionSourceId,
      productSourceId: catalogIdOf(it.product),
      variantSourceId: catalogIdOf(it.variant),
      quantity: wholeOf(it.quantity, 0, 100_000),
      amountPerCycle: moneyOf(it.totalPrice),
      currency: currencyOf(s?.currencyCode),
      billingInterval: intervalOf(it.billingPolicy?.interval) ?? intervalOf(s?.billingPolicy?.interval),
      billingIntervalCount: wholeOf(it.billingPolicy?.intervalCount, 1, 1000) ?? wholeOf(s?.billingPolicy?.intervalCount, 1, 1000),
      minCycles: wholeOf(it.billingPolicy?.minCycles, 0, 1000),
      maxCycles: wholeOf(it.billingPolicy?.maxCycles, 0, 1000),
      recurringCycleLimit: wholeOf(it.recurringCycleLimit, 1, 1000),
      canceledAt: timeOf(it.canceledAt),
    };
    item.raw = strip({ id: sourceId, subscriptionId: subscriptionSourceId, product: item.productSourceId, variant: item.variantSourceId,
      quantity: item.quantity, totalPrice: item.amountPerCycle, currencyCode: item.currency, interval: item.billingInterval,
      intervalCount: item.billingIntervalCount, minCycles: item.minCycles, maxCycles: item.maxCycles,
      recurringCycleLimit: item.recurringCycleLimit, canceledAt: item.canceledAt });
    lines.push(strip(item));
  }
  return { lines, unreadable };
}

/** A catalog text (a title, a SKU): trimmed, at most 100 characters; { value } or { dropped } for one with an @ or a control character. */
export function catalogTextOf(v) {
  if (typeof v !== "string" || !v.trim()) return { value: null, dropped: false };
  const s = v.trim();
  // every control, format and line or paragraph separator character: at least what the database's [[:cntrl:]] refuses
  if (s.includes("@") || /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u.test(s)) return { value: null, dropped: true };
  // cut by characters (code points), as the database counts them, never inside a surrogate pair
  return { value: Array.from(s).slice(0, 100).join(""), dropped: false };
}

/**
 * One product of GET /products → its variants' items: { variants, unreadable, textDropped }. A variant without an id (or
 * a product without one) is unreadable; a title or SKU with an @ or a control character is left out and counted.
 */
export function productItems(p) {
  const productSourceId = catalogIdOf(p?.id);
  const variants = [];
  let unreadable = 0;
  let textDropped = 0;
  if (!productSourceId || !Array.isArray(p?.variants)) return { variants, unreadable: Array.isArray(p?.variants) ? p.variants.length : 1, textDropped };
  const productTitle = catalogTextOf(p.title);
  const status = typeof p.status === "string" && PRODUCT_STATUS.test(p.status.trim().toLowerCase()) ? p.status.trim().toLowerCase() : null;
  for (const v of p.variants) {
    const variantSourceId = v && typeof v === "object" ? catalogIdOf(v.id) : null;
    if (!variantSourceId) {
      unreadable += 1;
      continue;
    }
    const variantTitle = catalogTextOf(v.title);
    const sku = catalogTextOf(v.sku);
    textDropped += [productTitle, variantTitle, sku].filter((t) => t.dropped).length;
    variants.push(strip({ productSourceId, variantSourceId, productTitle: productTitle.value, variantTitle: variantTitle.value,
      sku: sku.value, productStatus: status }));
  }
  return { variants, unreadable, textDropped };
}

/** The subscription an event belongs to: its subscriptionId, else its owner's id when the owner is a subscription. */
export function eventSubscriptionOf(e) {
  return idOf(e?.subscriptionId) ?? (typeof e?.owner?.entity === "string" && e.owner.entity.toLowerCase() === "subscription" ? idOf(e.owner.id) : null);
}

/** The other subscription of a merge or split: the first id of the payload's candidates that is not the event's own. */
function relatedOf(data, own) {
  const candidates = [data.targetSubscriptionId, data.sourceSubscriptionId, data.toSubscriptionId, data.fromSubscriptionId,
    data.subscription && typeof data.subscription === "object" ? data.subscription.id : data.subscription, data.subscriptionId, data.id];
  for (const c of candidates) {
    const id = idOf(c);
    if (id && id !== own) return id;
  }
  return null;
}

const countOf = (v) => (Array.isArray(v) ? Math.min(v.length, 1000) : null);

/**
 * One event of the subscription family → { item, reasonDropped } for an event the CMA keeps; { skip: 'type' } for an
 * event of another type (or an update without a status change); { skip: 'duplicate' } for the subscription family's copy
 * of a billing event; null when it lacks an id, a subscription or a time.
 */
export function eventItem(e) {
  const sourceId = idOf(e?.id);
  const subscriptionSourceId = eventSubscriptionOf(e);
  const occurredAt = timeOf(e?.occurredAt);
  const juoType = typeof e?.type === "string" && TYPE.test(e.type) ? e.type : null;
  if (!sourceId || !subscriptionSourceId || !occurredAt || !juoType) return null;
  if (DUPLICATE_TYPES.includes(juoType)) return { skip: "duplicate" };
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
  const t = known.type;
  const from = data.from && typeof data.from === "object" ? data.from : {};
  const to = data.to && typeof data.to === "object" ? data.to : {};
  const item = {
    sourceId, subscriptionSourceId, eventType: t, occurredAt, actorType, actorSourceId,
    cycleIndex: wholeOf(t === "migrated" ? data.currentCycle : data.cycleIndex, 0, 1_000_000), attempt: wholeOf(data.attempt, 1, 1000),
    errorCode, reasonCode, statusFrom, statusTo,
    billingFromAt: t === "billing_date_moved" ? timeOf(data.from) : t === "skipped" ? timeOf(data.skippedDate) : null,
    billingToAt: t === "billing_date_moved" ? timeOf(data.to) : t === "skipped" || t === "migrated" ? timeOf(data.nextBillingDate) : null,
    causeCode: t === "billing_date_moved" ? (typeof data.cause === "string" && BILLING_CAUSES.includes(data.cause.trim().toLowerCase())
      ? data.cause.trim().toLowerCase() : null) : known.cause ?? null,
    intervalFrom: t === "interval_changed" ? intervalOf(from.interval) : null,
    intervalCountFrom: t === "interval_changed" ? wholeOf(from.intervalCount, 1, 1000) : null,
    intervalTo: t === "interval_changed" ? intervalOf(to.interval) : null,
    intervalCountTo: t === "interval_changed" ? wholeOf(to.intervalCount, 1, 1000) : null,
    linesAdded: juoType === "subscription:lines-changed" ? countOf(data.added) : known.lines === "linesAdded" ? 1 : null,
    linesRemoved: juoType === "subscription:lines-changed" ? countOf(data.removed) : known.lines === "linesRemoved" ? 1 : null,
    linesUpdated: juoType === "subscription:lines-changed" ? countOf(data.updated) : known.lines === "linesUpdated" ? 1 : null,
    relatedSubscriptionSourceId: ["merged_to", "merged_from", "split_to", "split_from"].includes(t) ? relatedOf(data, subscriptionSourceId) : null,
    operationSourceId: idOf(e?.operationId),
    orderSourceId: orderId,
  };
  item.raw = strip({ id: sourceId, type: juoType, occurredAt, subscriptionId: subscriptionSourceId, customerId: customerIdOf(e?.customerId),
    actorType, actorId: actorSourceId, cycleIndex: item.cycleIndex, attempt: item.attempt, errorCode, reason: reasonCode,
    previousStatus: statusFrom, status: statusTo, orderId, billingFrom: item.billingFromAt, billingTo: item.billingToAt, cause: item.causeCode,
    intervalFrom: item.intervalFrom, intervalCountFrom: item.intervalCountFrom, intervalTo: item.intervalTo, intervalCountTo: item.intervalCountTo,
    linesAdded: item.linesAdded, linesRemoved: item.linesRemoved, linesUpdated: item.linesUpdated,
    relatedSubscriptionId: item.relatedSubscriptionSourceId, operationId: item.operationSourceId });
  return { item: strip(item), reasonDropped };
}

/**
 * One event of the billing family → { item, returnCodeDropped, instrumentUnknown } for a billing type; { skip: 'type' }
 * for any other; null when it lacks an id or a time. A chargeback's reason code out of the code form is left out
 * (returnCodeDropped); its message is never read.
 */
export function billingEventItem(e) {
  const sourceId = idOf(e?.id);
  const occurredAt = timeOf(e?.occurredAt);
  const juoType = typeof e?.type === "string" && TYPE.test(e.type) ? e.type : null;
  if (!sourceId || !occurredAt || !juoType) return null;
  const kind = BILLING_KINDS[juoType];
  if (!kind) return { skip: "type" };
  const data = e?.data && typeof e.data === "object" ? e.data : {};
  const money = data.value && typeof data.value === "object" ? data.value : data.total && typeof data.total === "object" ? data.total : {};
  const codeHeld = kind === "chargeback" && typeof data.reasonCode === "string" ? data.reasonCode.trim() : null;
  const returnCode = codeHeld && (RETURN_CODE.test(codeHeld) || CARD_DISPUTE_REASONS.includes(codeHeld)) ? codeHeld : null;
  const instrument = instrumentInfoOf(data.instrumentType);
  const item = {
    sourceId, kind, occurredAt,
    subscriptionSourceId: eventSubscriptionOf(e),
    customerSourceId: customerIdOf(e?.customerId),
    orderSourceId: customerIdOf(data.orderId),
    renewalSourceId: idOf(data.renewalId),
    ownerSourceId: idOf(e?.owner?.id),
    amount: moneyOf(money.amount),
    currency: currencyOf(money.currencyCode),
    returnCode,
    instrumentType: instrument?.code ?? null,
    attempt: wholeOf(data.attempt, 1, 1000),
    errorCode: typeof data.errorCode === "string" && CODE.test(data.errorCode.trim()) ? data.errorCode.trim().toUpperCase() : null,
    partial: kind.startsWith("refund_") && typeof data.partial === "boolean" ? data.partial : null,
  };
  item.raw = strip({ id: sourceId, type: juoType, occurredAt, subscriptionId: item.subscriptionSourceId, customerId: item.customerSourceId,
    orderId: item.orderSourceId, renewalId: item.renewalSourceId, ownerId: item.ownerSourceId, amount: item.amount, currencyCode: item.currency,
    reasonCode: returnCode, instrumentType: item.instrumentType, attempt: item.attempt, errorCode: item.errorCode, partial: item.partial });
  return { item: strip(item), returnCodeDropped: Boolean(codeHeld) && !returnCode, instrumentUnknown: instrument?.unknown ?? null };
}
