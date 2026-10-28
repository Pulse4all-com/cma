/**
 * The Airtable adapter for an asset register (addition 0008zj) as the jobs see it. Polling only and read only: the
 * server answers 404 on /airtable/<key> (kind poll), and nothing is ever written to Airtable. Every read loads its rows
 * in chunks (addition 0008zk): chunks from the setting assets_load_chunk (default 1,000, 100 to 5,000), halved after a
 * call slower than a third of the statement timeout (loadInChunks), each its own call of cma.ingest_load_device_chunk and
 * its own transaction under the pool's statement timeout (store.loadDeviceChunk; 0008zi's load, set-based), nothing
 * marked missing by a chunk. A full snapshot ends with the final step in slices: the run's
 * record ids sorted by their bytes, cut into slices of the same size, each its own call of cma.ingest_mark_devices_missing
 * with its range (store.markDevicesMissing), so the step's work per call is bounded however large the register grows. A
 * run that fails before that step marks nothing missing, and the chunks it loaded change nothing when the next run loads
 * them again.
 *
 *   pollDue, pollAssets   the job ingest-poll-assets (every 5 minutes): when due on assets_poll_interval_minutes
 *                         (default 15; cursor assets:cadence), the records modified after the cursor assets:modified less
 *                         five minutes (all records when there is none yet), loaded in chunks (nothing marked missing);
 *                         the cursor moves to the run's start. Paced at airtable_max_per_second (default 2)
 *   reconcileObjects, reconcile   the job ingest-reconcile (03:30): the full snapshot, every record of the table (never a
 *                         view: a view's filter would make the devices outside it look missing), loaded in chunks, then
 *                         the final step (a device the register no longer holds is marked missing); the cursor
 *                         assets:modified moves to the snapshot's start. Paced at airtable_full_max_per_second (default 4)
 *   backfillObjects, backfill, dryRun   the job ingest-backfill --object device [--dry-run]: the same full read on
 *                         demand; the dry run lists the table's fields (id, name, type: the mapping step of phase 14 is
 *                         generated from it, docs/ingest/airtable-fields.mjs), reads and counts (fetched, mapped, the
 *                         fields, date failures, values with an @, unknown fields, changed types) and writes nothing
 *   skipReason            a connection without a token secret name is loaded from files only (docs/import/devices.md):
 *                         the jobs skip it with one log line (code csv_only) and no run
 *
 * Before every read the mapping is checked: each property must be a field id (fld…; otherwise field_not_an_id, naming
 * it), each field must be in the table (GET /meta/bases/{base}/tables; otherwise unknown_field, naming the field's id:
 * it was deleted) and of the type the connection recorded when it first read it (otherwise field_type_changed, naming
 * the field's id and name and both types); the first read records the types (cma.ingest_record_field_types). A field
 * renamed in Airtable keeps its id and changes nothing. The log names fields, never a value. The base is the
 * connection's account id; the table the setting table_id (none: table_id_not_set); no mapped field: mapping_not_set.
 * A stored view_id is ignored and named once in the run's log (view_ignored). A full read that finds no record fails
 * empty_snapshot instead of marking every device missing; one whose paging expires fails paging_expired before it loads
 * anything, and the next run reads from the start.
 *
 * The run's counts are the load's, summed over its chunks and slices as each lands (rows, inserted, updated, unchanged,
 * missing_now, components_replaced, components_closed, unmapped_model, unmapped_status, unmapped_market,
 * customer_ref_invalid, refs_dropped), its phase times in milliseconds (stage_ms, map_ms, upsert_ms, components_ms,
 * missing_ms; cleanup_ms 0, as chunks stage nothing), the slowest call in milliseconds as the ingest measures it
 * (chunk_max_ms, the slowest chunk; slice_max_ms, the slowest slice of the final step: PROD_RUNBOOK 14.7 reads them
 * against half the statement timeout, 7,500 ms), the adaptive chunks of a read that sent any (chunk_size_min, the smallest
 * chunk size in force; chunk_halvings) and fetched, with upserted (inserted and
 * updated) and skipped (unchanged); the log line adds
 * mapped, the chunks and slices, the fields, date failures, values with an @, unreadable cells, duplicates and the
 * requests per endpoint. Never a token, a value or a record's content.
 */
import { info, warn } from "../../core/log.mjs";
import { SourceError } from "../../core/http.mjs";
import { assetSettings, LOAD_CHUNK_MIN } from "./client.mjs";
import { statementTimeoutMs } from "../../core/db.mjs";
import { clientFor, checkFields, modifiedAfter, fieldError, FIELD_ID } from "./read.mjs";
import { OBJECT_TYPE, mappingOf, fieldNames, rowOf } from "./map.mjs";

export const MODIFIED_STREAM = "assets:modified";
export const CADENCE_STREAM = "assets:cadence";
export const OVERLAP_MS = 5 * 60_000;
const SLACK_MS = 2 * 60_000;
const BASE = /^[A-Za-z0-9_-]{1,64}$/;
export const LOAD_COUNTS = ["rows", "inserted", "updated", "unchanged", "missing_now", "components_replaced", "components_closed",
  "unmapped_model", "unmapped_status", "unmapped_market", "customer_ref_invalid", "refs_dropped"];
/** The load's phase times (milliseconds, addition 0008zk), summed over a run's chunks */
export const PHASE_COUNTS = ["stage_ms", "map_ms", "upsert_ms", "components_ms", "missing_ms", "cleanup_ms"];
/** The slowest chunk and the slowest slice of a run (milliseconds of the call as the ingest measures it), the largest kept */
export const MAX_COUNTS = ["chunk_max_ms", "slice_max_ms"];

/** A connection without a token secret name is loaded from files: the jobs skip it (code csv_only). */
export function skipReason(connection) {
  return connection?.tokenSecretName ? null : "csv_only";
}

/** Whether the poll is due: no poll yet, or the connection's interval (less two minutes of the schedule's slack) has passed. */
export async function pollDue({ store, now = Date.now() }) {
  const s = assetSettings((await store.config())?.settings ?? {});
  const last = (await store.cursor(CADENCE_STREAM))?.at;
  return !Number.isFinite(last) || now - last >= s.intervalMinutes * 60_000 - SLACK_MS;
}

/** The detail counts a run logs next to sync_run's counts. */
export const emptyDetail = () => ({ fetched: 0, mapped: 0, duplicates: 0, dateFailures: 0, valuesWithAt: 0, unreadable: 0 });

/** Text sorted by its UTF-8 bytes: the database's collation "C", the order of the final step's slices */
export const byBytes = (a, b) => Buffer.compare(Buffer.from(a, "utf8"), Buffer.from(b, "utf8"));

/**
 * What every read needs: the settings, the mapping (by field id), the base and table, and the mapped fields checked
 * against the base's schema and the recorded types. Answers { api, s, mapping, names, check, baseId } (check:
 * checkFields' answer). A mapping is optional for the dry run only (mapping null, names []).
 */
async function prepare({ connection, store, budget, full, requireMapping = true }) {
  const config = await store.config();
  const settings = config?.settings ?? {};
  const s = assetSettings(settings);
  if (s.fallbacks.length) info("settings out of range, defaults used", { connection: connection.connectionId, settings: s.fallbacks });
  if (s.viewIgnored) info("view_id ignored: an asset register is read whole", { connection: connection.connectionId, code: "view_ignored", setting: "view_id" });
  const mapping = mappingOf(config);
  if (!mapping && requireMapping) throw new SourceError("mapping_not_set");
  if (!s.tableId) throw new SourceError("table_id_not_set");
  const baseId = String(connection.externalAccountId ?? "").trim();
  if (!BASE.test(baseId)) throw new SourceError("base_id_not_set");
  const names = mapping ? fieldNames(mapping) : [];
  const notIds = names.filter((n) => !FIELD_ID.test(n));
  if (notIds.length && requireMapping) {
    warn("airtable mapping not by field id", { connection: connection.connectionId, code: "field_not_an_id", field: notIds[0], notFieldIds: notIds.length });
    throw fieldError("field_not_an_id", notIds[0]);
  }
  const recorded = new Map((config?.fields ?? []).filter((f) => (f.slot ?? 1) === 1 && typeof f.property === "string")
    .map((f) => [f.property.trim(), f.sourceType ?? null]));
  const api = clientFor(connection, settings, budget, { full });
  const check = checkFields(await api.tables(baseId), s.tableId, names.filter((n) => FIELD_ID.test(n)), recorded);
  return { api, s, mapping, names, check, baseId, notIds };
}

/**
 * The checks that refuse a read: a mapped field the table lacks (unknown_field, its id), or one whose type changed
 * (field_type_changed, its id and name and both types). Then the types not recorded yet are recorded. The log names
 * fields, never a value.
 */
async function refuseOrRecord(connection, store, check) {
  if (check.unknown.length) {
    warn("airtable unknown field", { connection: connection.connectionId, code: "unknown_field", field: check.unknown[0], unknownFields: check.unknown.length });
    throw fieldError("unknown_field", check.unknown[0]);
  }
  if (check.changed.length) {
    const c = check.changed[0];
    warn("airtable field type changed", { connection: connection.connectionId, code: "field_type_changed", field: c.id, fieldName: c.name,
      was: c.was, now: c.now, changedFields: check.changed.length });
    throw fieldError("field_type_changed", c.id, c.name);
  }
  if (check.unrecorded.length) await store.recordFieldTypes(check.unrecorded);
}

/**
 * Every record the read lists, mapped to staging rows: { rows, detail }. A record listed twice (a page boundary moving
 * while the table changes) is kept once, its later copy; the rows are numbered from 2 in record id order, so a load
 * walks them in a fixed order. counts.fetched follows the pages, so a run that stops shows how far it got.
 */
async function readRows({ connection, prep, formula, counts }) {
  const { api, s, mapping, names, baseId, check } = prep;
  const detail = emptyDetail();
  const byId = new Map();
  try {
    for await (const page of api.records(baseId, s.tableId, { fields: names, formula })) {
      detail.fetched += page.length;
      if (counts) counts.fetched += page.length;
      for (const record of page) {
        const m = rowOf(record, mapping, { dateFormat: s.dateFormat });
        if (!m.row.source_id) {
          detail.unreadable += 1;
          continue;
        }
        detail.valuesWithAt += m.valuesWithAt;
        detail.dateFailures += m.dateFailures;
        detail.unreadable += m.unreadable;
        if (byId.has(m.row.source_id)) detail.duplicates += 1;
        byId.set(m.row.source_id, m.row);
      }
    }
  } catch (err) {
    if (err instanceof SourceError && err.field) {
      warn("airtable read refused", { connection: connection.connectionId, code: err.code, field: err.field, fieldName: check.names.get(err.field) });
    } else if (err instanceof SourceError && err.code === "paging_expired") {
      warn("airtable paging expired", { connection: connection.connectionId, code: "paging_expired", fetched: detail.fetched });
    }
    throw err;
  }
  const rows = [...byId.values()].sort((a, b) => (a.source_id < b.source_id ? -1 : a.source_id > b.source_id ? 1 : 0))
    .map((row, i) => ({ ...row, source_row: i + 2 }));
  byId.clear();
  detail.mapped = rows.length;
  return { rows, detail };
}

/**
 * A chunk's (or a slice's) counts added to the run's: each of the load's and its phase times, upserted (inserted and
 * updated) and skipped (unchanged); the call's milliseconds kept under its key (chunk_max_ms or slice_max_ms) when
 * the slowest so far. Called with nothing, it writes the keys as 0.
 */
function addLoad(counts, loaded = {}, slowest = null, ms = 0) {
  for (const k of [...LOAD_COUNTS, ...PHASE_COUNTS]) counts[k] = Number(counts[k] ?? 0) + Number(loaded?.[k] ?? 0);
  for (const k of MAX_COUNTS) counts[k] = Math.max(Number(counts[k] ?? 0), k === slowest ? Math.round(ms) : 0);
  counts.upserted = counts.inserted + counts.updated;
  counts.skipped = counts.unchanged;
}

/** A store call timed: [its answer, its milliseconds] */
async function timed(call) {
  const t0 = performance.now();
  const answer = await call();
  return [answer, performance.now() - t0];
}

const isTimeout = (err) => err?.code === "57014";

/**
 * The rows loaded in chunks, each chunk its own call and transaction; the run's counts follow each chunk, so a run that
 * stops shows how far it got. The chunk size starts at the setting assets_load_chunk and adapts to the database (Decision
 * log, 28 October 2026): a call slower than a third of the ingest's statement timeout halves the next chunk, and a chunk
 * the timeout cancels (57014: nothing of it was written) is sent again once at half its size; a cancellation among those
 * rows again fails the run before its final step, so nothing is marked missing. The floor is the setting's, 100 rows.
 * The counts keep the smallest chunk size in force (chunk_size_min) and the halvings (chunk_halvings). Answers how many
 * chunks were loaded.
 */
async function loadInChunks({ connection, store, rows, chunk, counts }) {
  const slowMs = statementTimeoutMs() / 3;
  let size = chunk;
  let chunks = 0;
  let retryUntil = -1;
  if (!rows.length) return 0;
  counts.chunk_halvings = Number(counts.chunk_halvings ?? 0);
  counts.chunk_size_min = Math.min(Number(counts.chunk_size_min) || size, size);
  // answers whether the size dropped (at the floor it stays)
  const halve = () => {
    const next = Math.max(LOAD_CHUNK_MIN, Math.floor(size / 2));
    const dropped = next < size;
    if (dropped) counts.chunk_halvings += 1;
    size = next;
    counts.chunk_size_min = Math.min(counts.chunk_size_min, size);
    return dropped;
  };
  for (let i = 0; i < rows.length;) {
    const part = rows.slice(i, i + size);
    let loaded;
    let ms;
    try {
      [loaded, ms] = await timed(() => store.loadDeviceChunk(part));
    } catch (err) {
      if (!isTimeout(err) || i < retryUntil) throw err;
      retryUntil = i + part.length;
      halve();
      warn("airtable chunk cancelled by the statement timeout: sent again at half its size (at least 100 rows)",
        { connection: connection?.connectionId, code: "db_57014", rows: part.length, size, chunk: chunks + 1 });
      continue;
    }
    addLoad(counts, loaded, "chunk_max_ms", ms);
    i += part.length;
    chunks += 1;
    if (ms > slowMs && i < rows.length && halve()) {
      info("airtable chunk slow: the next one halved", { connection: connection?.connectionId, ms: Math.round(ms), size, chunk: chunks });
    }
  }
  return chunks;
}

/**
 * The final step of a full snapshot: the run's record ids sorted by their bytes and cut into slices of the chunk's size,
 * each its own call and transaction with its range: from (its first id; none for the first slice) and before (the next
 * slice's first id; none for the last). Together the slices cover every record id once, so every device the run did not
 * read is marked missing in exactly one of them. Answers how many slices were sent.
 */
export function slicesOf(sourceIds, size) {
  const ids = [...sourceIds].sort(byBytes);
  const slices = [];
  for (let i = 0; i < ids.length; i += size) {
    slices.push({ ids: ids.slice(i, i + size), from: i === 0 ? null : ids[i], before: i + size < ids.length ? ids[i + size] : null });
  }
  return slices;
}

async function markMissing({ store, rows, size, counts }) {
  const slices = slicesOf(rows.map((r) => r.source_id), size);
  for (const slice of slices) {
    const [marked, ms] = await timed(() => store.markDevicesMissing(slice.ids, slice.from, slice.before));
    addLoad(counts, marked, "slice_max_ms", ms);
  }
  return slices.length;
}

/** The poll of one connection: the records modified since the cursor less five minutes, a partial batch. */
export async function pollAssets({ connection, store, budget, now = Date.now(), counts }) {
  const prep = await prepare({ connection, store, budget, full: false });
  await refuseOrRecord(connection, store, prep.check);
  const cur = await store.cursor(MODIFIED_STREAM);
  const formula = Number.isFinite(cur?.at) ? modifiedAfter(cur.at - OVERLAP_MS) : null;
  const { rows, detail } = await readRows({ connection, prep, formula, counts });
  addLoad(counts);
  const chunks = await loadInChunks({ connection, store, rows, chunk: prep.s.loadChunk, counts });
  await store.setCursor(MODIFIED_STREAM, { at: now });
  await store.setCursor(CADENCE_STREAM, { at: now });
  return { detail: { ...detail, chunks, fields: prep.names.length, changedSince: formula ? new Date(cur.at - OVERLAP_MS).toISOString() : "all" } };
}

/**
 * A full snapshot of one connection (the nightly reconcile, a backfill): every record loaded in chunks, then the final
 * step in slices marks the connection's devices the run did not read missing. Nothing is marked when a chunk fails.
 */
async function fullSnapshot({ connection, store, budget, counts }) {
  const startedAt = Date.now();
  const prep = await prepare({ connection, store, budget, full: true });
  await refuseOrRecord(connection, store, prep.check);
  const { rows, detail } = await readRows({ connection, prep, formula: null, counts });
  if (!rows.length) throw new SourceError("empty_snapshot");
  addLoad(counts);
  const chunks = await loadInChunks({ connection, store, rows, chunk: prep.s.loadChunk, counts });
  const slices = await markMissing({ store, rows, size: prep.s.loadChunk, counts });
  await store.setCursor(MODIFIED_STREAM, { at: startedAt });
  return { ...detail, chunks, slices, fields: prep.names.length };
}

export const RECONCILE_OBJECTS = [OBJECT_TYPE];
export const BACKFILL_OBJECTS = [OBJECT_TYPE];

export async function reconcile({ connection, store, budget, object, counts }) {
  if (object !== OBJECT_TYPE) throw new SourceError("object_not_reconciled");
  const detail = await fullSnapshot({ connection, store, budget, counts });
  info("reconcile: devices", { connection: connection.connectionId, ...detail });
  return undefined;
}

export async function backfill({ connection, store, budget, object, counts }) {
  if (object !== OBJECT_TYPE) throw new SourceError("object_not_backfilled");
  const detail = await fullSnapshot({ connection, store, budget, counts });
  info("backfill: devices", { connection: connection.connectionId, ...detail });
  return undefined;
}

/**
 * The dry run of a full read: nothing written (no load, no run, no cursor, no recorded type). Answers tableFieldList,
 * the table's fields ({ id, name, type }: field names and types, never a value; the mapping step of phase 14 is
 * generated from it), and the counts: fetched, mapped, fields (mapped), tableFields, dateFailures, valuesWithAt,
 * unreadable, duplicates, unknownFields and typeChangedFields (with their ids: unknownFieldNames, typeChanged),
 * notFieldIds. Without a mapping, or with a mapped field the table lacks, a changed type or a property that is no field
 * id, nothing is read.
 */
export async function dryRun({ connection, store, budget, object }) {
  if (object !== OBJECT_TYPE) throw new SourceError("object_not_backfilled");
  const prep = await prepare({ connection, store, budget, full: true, requireMapping: false });
  const base = { fields: prep.names.length, tableFields: prep.check.tableFields, unknownFields: prep.check.unknown.length,
    typeChangedFields: prep.check.changed.length, notFieldIds: prep.notIds.length, tableFieldList: prep.check.list };
  const refused = !prep.mapping || prep.check.unknown.length || prep.check.changed.length || prep.notIds.length;
  if (refused) {
    return { ...emptyDetail(), ...base, mappingSet: Boolean(prep.mapping), unknownFieldNames: prep.check.unknown,
      typeChanged: prep.check.changed, notFieldIdNames: prep.notIds };
  }
  const { rows, detail } = await readRows({ connection, prep, formula: null, counts: null });
  rows.length = 0;
  return { ...detail, ...base, mappingSet: true };
}

export const airtable = {
  name: "airtable",
  kind: "poll",
  holdsRecords: false,
  rates: {},
  skipReason,
  pollDue,
  pollAssets,
  reconcileObjects: RECONCILE_OBJECTS,
  reconcile,
  backfillObjects: BACKFILL_OBJECTS,
  backfill,
  /** device is always read whole: a backfill takes no --from */
  wholeObjects: [OBJECT_TYPE],
  backfillFrom: async () => ({ allHistory: true }),
  dryRun,
};
