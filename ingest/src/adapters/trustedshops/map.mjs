/**
 * eTrusted channels and reviews → the canonical shapes of cma.ingest_upsert_review_channels and
 * cma.ingest_upsert_reviews (addition 0008ze). An allow list: only the fields named here are read, so the reviewer's
 * name and phone number, the review's title and text, and anything the API adds later never reach a canonical item,
 * raw, a log or the database. The reviewer's email is the one exception: it is handed back next to the item, for the
 * CRM contact match in memory (match.mjs), and is never part of the item.
 *
 *   channel   { channelId: id, name, locale }
 *   review    { reviewId: id, channelId: channelRef, type, state, isPublished (state APPROVED: the platform's published
 *             state, decided here so no vendor word lives in the database), rating (1 to 5), submittedAt, updatedAt,
 *             hasReply (a reply object is there), inviteEventType (event.type), transactionRef (transaction.reference
 *             when the connection's pattern accepts it), raw: id, channelRef, rating, type, state, submittedAt, updatedAt,
 *             inviteRef, event.type and transaction.reference only }
 *
 * A transaction reference is kept only when the connection setting transaction_ref_pattern accepts it (by default
 * DEFAULT_REF_PATTERN: letters, digits and # _ . : / -, 1 to 100 characters) and it holds no @ (addition 0008zf: in
 * prod a manual invite carried the reviewer's email address there, and the database refuses an @ in either place).
 * Otherwise it is left out of the item and of raw, and the review says refDropped; the value is never logged.
 */
export const OBJECT_TYPE = "review";
export const PUBLISHED_STATE = "APPROVED";
/** The default of the connection setting transaction_ref_pattern: never an @ or a space */
export const DEFAULT_REF_PATTERN = "^[A-Za-z0-9#_.:/-]{1,100}$";
const DEFAULT_REF = new RegExp(DEFAULT_REF_PATTERN);

const ID = /^[A-Za-z0-9_.:-]{1,100}$/;
const TOKEN = /^[A-Za-z0-9_.-]{1,40}$/;
// eslint-disable-next-line no-control-regex
const CONTROL = /[\u0000-\u001f\u007f]/;

export const idOf = (v) => (typeof v === "string" && ID.test(v.trim()) ? v.trim() : null);
const tokenOf = (v) => (typeof v === "string" && TOKEN.test(v.trim()) ? v.trim() : null);
const textOf = (v, max) => (typeof v === "string" && v.trim() && v.trim().length <= max && !CONTROL.test(v) ? v.trim() : null);

function timeOf(v) {
  if (typeof v !== "string" || !/^\d{4}-\d{2}-\d{2}T/.test(v)) return null;
  const ms = Date.parse(v);
  return Number.isFinite(ms) ? new Date(ms).toISOString() : null;
}

/** One channel of GET /channels → { channelId, name, locale }, or null without an id. */
export function channelItem(c) {
  const channelId = idOf(c?.id);
  if (!channelId) return null;
  return { channelId, name: textOf(c?.name, 200) ?? channelId, locale: textOf(c?.locale, 35) };
}

/**
 * A transaction reference as the review holds it → { reference, dropped }: the reference when it is text of at most 100
 * characters that the pattern accepts and holds no @, else null; dropped when the review held one that is not kept.
 */
export function referenceOf(v, pattern = DEFAULT_REF) {
  const held = v !== undefined && v !== null && !(typeof v === "string" && v.trim() === "");
  const text = textOf(v, 100);
  const reference = text !== null && !text.includes("@") && pattern.test(text) ? text : null;
  return { reference, dropped: held && reference === null };
}

/**
 * One review of GET /reviews → { item, email, refDropped } or null when it lacks an id, a channel, a submission time or
 * a rating from 1 to 5. email: the reviewer's email as the source holds it, or null; the caller keeps it in memory
 * only. refPattern: the connection's transaction_ref_pattern (client.mjs reviewSettings); refDropped: the review held
 * a reference the pattern refused, left out of the item and raw.
 */
export function reviewOf(r, { refPattern = DEFAULT_REF } = {}) {
  const reviewId = idOf(r?.id);
  const channelId = idOf(r?.channelRef);
  const submittedAt = timeOf(r?.submittedAt);
  const rating = typeof r?.rating === "number" ? r.rating : typeof r?.rating === "string" && /^\d(\.\d+)?$/.test(r.rating) ? Number(r.rating) : NaN;
  if (!reviewId || !channelId || !submittedAt || !(rating >= 1 && rating <= 5)) return null;
  const state = tokenOf(r?.state) ?? "unknown";
  const raw = { id: reviewId, channelRef: channelId, rating, type: tokenOf(r?.type), state: tokenOf(r?.state), submittedAt,
    updatedAt: timeOf(r?.updatedAt), inviteRef: idOf(r?.inviteRef) };
  const eventType = textOf(r?.event?.type, 60);
  const { reference, dropped: refDropped } = referenceOf(r?.transaction?.reference, refPattern);
  if (eventType) raw.event = { type: eventType };
  if (reference) raw.transaction = { reference };
  for (const k of Object.keys(raw)) if (raw[k] === null) delete raw[k];
  const reply = r?.reply;
  const item = {
    reviewId, channelId, type: tokenOf(r?.type) ?? "unknown", state, isPublished: state === PUBLISHED_STATE,
    rating: Math.round(rating * 100) / 100, submittedAt, updatedAt: timeOf(r?.updatedAt),
    hasReply: reply !== undefined && reply !== null && (typeof reply !== "object" || Object.keys(reply).length > 0),
    inviteEventType: eventType, transactionRef: reference, raw,
  };
  const email = typeof r?.customer?.email === "string" && r.customer.email.includes("@") ? r.customer.email : null;
  return { item, email, refDropped };
}
