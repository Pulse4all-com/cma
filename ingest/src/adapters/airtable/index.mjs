/**
 * The Airtable adapter for an asset register (addition 0008zj) as the jobs see it. Polling only and read only: the
 * server answers 404 on /airtable/<key> (kind poll), and nothing is ever written to Airtable. Every read loads its rows
 * in chunks (addition 0008zk): chunks of the setting assets_load_chunk (default 1,000, 100 to 5,000), each its own call of
 * cma.ingest_load_device_chunk and its own transaction under the pool's statement timeout (store.loadDeviceChunk; 0008zi's
 * load, set-based), nothing marked missing by a chunk. A full snapshot ends with one call over the run's record ids,
 * cma.ingest_mark_devices_missing (store.markDevicesMissing). A run that fails before that call marks nothing missing,
 * and the chunks it loaded change nothing when the next run loads them again.
 *
 *   pollDue, pollAssets   the job ingest-poll-assets (every 5 minutes): when due on assets_poll_interval_minutes
 *                         (default 15; cursor assets:cadence), the records modified after the cursor assets:modified less
 *                         five minutes (all records when there is none yet), loaded in chunks (nothing marked missing);
 *                         the cursor moves to the run's start
 *   reconcileObjects, reconcile   the job ingest-reconcile (03:30): the full snapshot, every record of the table (or the
 *                         view_id setting's view), loaded in chunks, then the final call (a device the register no longer
 *                         holds is marked missing); the cursor assets:modified moves to the snapshot's start
 *   backfillObjects, backfill, dryRun   the job ingest-backfill --object device [--dry-run]: the same full read on
 *                         demand; the dry run reads and counts (fetched, mapped, the fields, date failures, values with
 *                         an @, unknown fields) and writes nothing
 *   skipReason            a connection without a token secret name is loaded from files only (docs/import/devices.md):
 *                         the jobs skip it with one log line (code csv_only) and no run
 *
 * Before every read the mapped fields are checked against the base's schema (GET /meta/bases/{base}/tables): a field
 * the table lacks fails the run with unknown_field, and the log names the field, never a value. The base is the
 * connection's account id; the table the setting table_id (none: table_id_not_set); no mapped field: mapping_not_set.
 * A full read that finds no record fails empty_snapshot instead of marking every device missing.
 *
 * The run's counts are the load's, summed over its chunks as each lands (rows, inserted, updated, unchanged, missing_now,
 * components_replaced, unmapped_model, unmapped_status, unmapped_market, customer_ref_invalid, refs_dropped), its phase
 * times in milliseconds (stage_ms, map_ms, upsert_ms, components_ms, missing_ms; cleanup_ms 0, as chunks stage nothing)
 * and fetched, with upserted (inserted and updated) and skipped (unchanged); the log line adds mapped, the chunks, the
 * fields, date failures, values with an @, unreadable cells, duplicates and the requests per endpoint. Never a token, a
 * value or a record's content.
 */
import { info, warn } from "../../core/log.mjs";
import { SourceError } from "../../core/http.mjs";
import { assetSettings } from "./client.mjs";
import { clientFor, checkFields, modifiedAfter, unknownField } from "./read.mjs";
import { OBJECT_TYPE, mappingOf, fieldNames, rowOf } from "./map.mjs";

export const MODIFIED_STREAM = "assets:modified";
export const CADENCE_STREAM = "assets:cadence";
export const OVERLAP_MS = 5 * 60_000;
const SLACK_MS = 2 * 60_000;
const BASE = /^[A-Za-z0-9_-]{1,64}$/;
export const LOAD_COUNTS = ["rows", "inserted", "updated", "unchanged", "missing_now", "components_replaced", "unmapped_model",
  "unmapped_status", "unmapped_market", "customer_ref_invalid", "refs_dropped"];
/** The load's phase times (milliseconds, addition 0008zk), summed over a run's chunks */
export const PHASE_COUNTS = ["stage_ms", "map_ms", "upsert_ms", "components_ms", "missing_ms", "cleanup_ms"];

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

/**
 * What every read needs: the settings, the mapping, the base and table, and the mapped fields checked against the
 * base's schema. Answers { api, s, mapping, names, check, baseId }; check.unknown lists the fields the table lacks.
 */
async function prepare({ connection, store, budget }) {
  const config = await store.config();
  const settings = config?.settings ?? {};
  const s = assetSettings(settings);
  if (s.fallbacks.length) info("settings out of range, defaults used", { connection: connection.connectionId, settings: s.fallbacks });
  const mapping = mappingOf(config);
  if (!mapping) throw new SourceError("mapping_not_set");
  if (!s.tableId) throw new SourceError("table_id_not_set");
  const baseId = String(connection.externalAccountId ?? "").trim();
  if (!BASE.test(baseId)) throw new SourceError("base_id_not_set");
  const api = clientFor(connection, settings, budget);
  const names = fieldNames(mapping);
  const check = checkFields(await api.tables(baseId), s.tableId, names);
  return { api, s, mapping, names, check, baseId };
}

/** The first unknown field fails the read; the log names it (a field's name, never a value). */
function refuseUnknown(connection, check) {
  if (!check.unknown.length) return;
  warn("airtable unknown field", { connection: connection.connectionId, code: "unknown_field", field: check.unknown[0], unknownFields: check.unknown.length });
  throw unknownField(check.unknown[0]);
}

/**
 * Every record the read lists, mapped to staging rows: { rows, detail }. A record listed twice (a page boundary moving
 * while the table changes) is kept once, its later copy; the rows are numbered from 2 in record id order, so a load
 * walks them in a fixed order. counts.fetched follows the pages, so a run that stops shows how far it got.
 */
async function readRows({ connection, prep, formula, counts }) {
  const { api, s, mapping, names, baseId } = prep;
  const detail = emptyDetail();
  const byId = new Map();
  try {
    for await (const page of api.records(baseId, s.tableId, { fields: names, viewId: s.viewId, formula })) {
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
      warn("airtable read refused", { connection: connection.connectionId, code: err.code, field: err.field });
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
 * A chunk's (or the final call's) counts added to the run's: each of the load's and its phase times, upserted (inserted
 * and updated) and skipped (unchanged). Called with nothing, it writes the keys as 0.
 */
function addLoad(counts, loaded = {}) {
  for (const k of [...LOAD_COUNTS, ...PHASE_COUNTS]) counts[k] = Number(counts[k] ?? 0) + Number(loaded?.[k] ?? 0);
  counts.upserted = counts.inserted + counts.updated;
  counts.skipped = counts.unchanged;
}

/**
 * The rows loaded in chunks of the setting assets_load_chunk, each chunk its own call and transaction; the run's counts
 * follow each chunk, so a run that stops shows how far it got. Answers how many chunks were loaded.
 */
async function loadInChunks({ store, rows, chunk, counts }) {
  let chunks = 0;
  for (let i = 0; i < rows.length; i += chunk) {
    addLoad(counts, await store.loadDeviceChunk(rows.slice(i, i + chunk)));
    chunks += 1;
  }
  return chunks;
}

/** The poll of one connection: the records modified since the cursor less five minutes, a partial batch. */
export async function pollAssets({ connection, store, budget, now = Date.now(), counts }) {
  const prep = await prepare({ connection, store, budget });
  refuseUnknown(connection, prep.check);
  const cur = await store.cursor(MODIFIED_STREAM);
  const formula = Number.isFinite(cur?.at) ? modifiedAfter(cur.at - OVERLAP_MS) : null;
  const { rows, detail } = await readRows({ connection, prep, formula, counts });
  addLoad(counts);
  const chunks = await loadInChunks({ store, rows, chunk: prep.s.loadChunk, counts });
  await store.setCursor(MODIFIED_STREAM, { at: now });
  await store.setCursor(CADENCE_STREAM, { at: now });
  return { detail: { ...detail, chunks, fields: prep.names.length, changedSince: formula ? new Date(cur.at - OVERLAP_MS).toISOString() : "all" } };
}

/**
 * A full snapshot of one connection (the nightly reconcile, a backfill): every record loaded in chunks, then the final
 * call marks the connection's devices the run did not read missing. Nothing is marked when a chunk fails.
 */
async function fullSnapshot({ connection, store, budget, counts }) {
  const startedAt = Date.now();
  const prep = await prepare({ connection, store, budget });
  refuseUnknown(connection, prep.check);
  const { rows, detail } = await readRows({ connection, prep, formula: null, counts });
  if (!rows.length) throw new SourceError("empty_snapshot");
  addLoad(counts);
  const chunks = await loadInChunks({ store, rows, chunk: prep.s.loadChunk, counts });
  addLoad(counts, await store.markDevicesMissing(rows.map((r) => r.source_id)));
  await store.setCursor(MODIFIED_STREAM, { at: startedAt });
  return { ...detail, chunks, fields: prep.names.length };
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
 * The dry run of a full read: the schema check and every record mapped, nothing written (no staging, no load, no run,
 * no cursor). Answers the counts: fetched, mapped, fields (mapped), tableFields, dateFailures, valuesWithAt,
 * unreadable, duplicates, unknownFields (and their names: field names only). With an unknown field nothing is read.
 */
export async function dryRun({ connection, store, budget, object }) {
  if (object !== OBJECT_TYPE) throw new SourceError("object_not_backfilled");
  const prep = await prepare({ connection, store, budget });
  const base = { fields: prep.names.length, tableFields: prep.check.tableFields, unknownFields: prep.check.unknown.length };
  if (prep.check.unknown.length) return { ...emptyDetail(), ...base, unknownFieldNames: prep.check.unknown };
  const { rows, detail } = await readRows({ connection, prep, formula: null, counts: null });
  rows.length = 0;
  return { ...detail, ...base };
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
