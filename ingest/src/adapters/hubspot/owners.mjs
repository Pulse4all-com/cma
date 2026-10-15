/**
 * Small id maps the email poll keeps between its runs (brief B17b), without a table: each job run is
 * a new process, so a map lives in the connection's sync cursors (cma.sync_cursor, at most 2 kB a
 * cursor): `<stream>` holds { refreshedAt, parts }, `<stream>:<n>` part n as "key:value,key:value".
 * Ids only, never a name or an address.
 *
 *   owners    HubSpot user id → owner id, from GET /crm/v3/owners (active and archived; the existing
 *             scope crm.objects.owners.read), refreshed hourly: an inbox conversation names its agent
 *             as an actor id A-<user id>, the CMA stores the owner id (cma.email_message.owner_ref)
 *   accounts  channel account id → inbox id (the conversations' catalog, conversations.mjs)
 *
 * An owner's email, first and last name are in the answer: dropped here, in memory, at once.
 */
const PART_MAX = 1800;
const ID = /^[0-9A-Za-z_-]{1,40}$/;

export const OWNERS_STREAM = "email:owners";
export const MAP_EVERY_MS = 60 * 60_000;

// ---- Pure ---------------------------------------------------------------------------------------

/** Owners (as the owners API answers them) → [[user id, owner id]], ids only. */
export function ownerPairs(owners) {
  const out = [];
  for (const o of owners ?? []) {
    const ownerId = String(o?.id ?? "");
    const userId = String(o?.userId ?? o?.userIdIncludingInactive ?? "");
    if (/^\d{1,30}$/.test(ownerId) && /^\d{1,30}$/.test(userId)) out.push([userId, ownerId]);
  }
  return out;
}

/** A map → parts of at most PART_MAX characters ("k:v,k:v"); pairs whose ids are not plain are left out. */
export function packMap(pairs) {
  const parts = [];
  let cur = "";
  for (const [k, v] of pairs) {
    if (!ID.test(String(k)) || !ID.test(String(v))) continue;
    const e = `${k}:${v}`;
    if (cur && cur.length + 1 + e.length > PART_MAX) {
      parts.push(cur);
      cur = "";
    }
    cur = cur ? `${cur},${e}` : e;
  }
  if (cur) parts.push(cur);
  return parts;
}

/** Parts → Map. */
export function unpackMap(parts) {
  const m = new Map();
  for (const p of parts ?? []) {
    for (const e of String(p ?? "").split(",")) {
      const i = e.indexOf(":");
      if (i > 0) m.set(e.slice(0, i), e.slice(i + 1));
    }
  }
  return m;
}

// ---- With the database ----------------------------------------------------------------------------

/** The map kept under stream, or null when it is older than everyMs (or was never written). */
export async function readMap(store, stream, now, everyMs = MAP_EVERY_MS) {
  const head = await store.cursor(stream);
  if (!head?.refreshedAt || now - Date.parse(head.refreshedAt) >= everyMs || !Number.isInteger(head.parts)) return null;
  const parts = [];
  for (let i = 0; i < head.parts; i += 1) parts.push((await store.cursor(`${stream}:${i}`))?.m ?? "");
  return unpackMap(parts);
}

/** Writes the map under stream: the parts first, then the head that names them. */
export async function writeMap(store, stream, pairs, now) {
  const parts = packMap(pairs);
  for (let i = 0; i < parts.length; i += 1) await store.setCursor(`${stream}:${i}`, { m: parts[i] });
  await store.setCursor(stream, { refreshedAt: new Date(now).toISOString(), parts: parts.length });
  return unpackMap(parts);
}

// ---- With HubSpot ---------------------------------------------------------------------------------

async function allOwners(api, archived) {
  const out = [];
  let after;
  for (let i = 0; i < 50; i += 1) {
    const r = await api.owners(after, archived);
    out.push(...ownerPairs(r?.results));
    after = r?.paging?.next?.after;
    if (!after) break;
  }
  return out;
}

/**
 * The owner map of a connection: the kept one while it is younger than an hour, else read again
 * (active owners, then archived ones, so an agent who left still resolves) and kept.
 */
export async function ownerMap(api, store, now) {
  const kept = await readMap(store, OWNERS_STREAM, now);
  if (kept) return kept;
  const pairs = [...(await allOwners(api, true)), ...(await allOwners(api, false))]; // an active owner wins over an archived one
  return writeMap(store, OWNERS_STREAM, pairs, now);
}
