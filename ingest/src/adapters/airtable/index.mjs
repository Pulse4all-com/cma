/**
 * The Airtable adapter for an asset register (addition 0008zj) as the jobs see it. Polling only and read only: the
 * server answers 404 on /airtable/<key> (kind poll), and nothing is ever written to Airtable. Every read takes 0008zi's
 * path: the rows staged under a batch key of their own in cma.device_import_staging and loaded by
 * cma.ingest_load_device_snapshot (the load cma.load_device_snapshot shares), in one transaction (store.loadDevices).
 *
 *   pollDue, pollAssets   the job ingest-poll-assets (every 5 minutes): when due on assets_poll_interval_minutes
 *                         (default 15; cursor assets:cadence), the records modified after the cursor assets:modified less
 *                         five minutes (all records when there is none yet), loaded as a partial batch (is_full false:
 *                         nothing marked missing); the cursor moves to the run's start
 *   reconcileObjects, reconcile   the job ingest-reconcile (03:30): the full snapshot, every record of the table (or the
 *                         view_id setting's view), loaded with is_full true (a device the register no longer holds is
 *                         marked missing); the cursor assets:modified moves to the snapshot's start
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
 * The run's counts are the load's (rows, inserted, updated, unchanged, missing_now, components_replaced, unmapped_model,
 * unmapped_status, unmapped_market, customer_ref_invalid, refs_dropped) and fetched, with upserted (inserted and
 * updated) and skipped (unchanged); the log line adds mapped, the fields, date failures, values with an @, unreadable
 * cells, duplicates and the requests per endpoint. Never a token, a value or a record's content.
 */
import { randomBytes } from "node:crypto";
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

/** A batch key of one run: lower case, at most 64 characters, never reused (0008zi's staging rule). */
export function batchKeyOf(kind, now = Date.now()) {
  return `ingest-${kind}-${now.toString(36)}-${randomBytes(4).toString("hex")}`;
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

/** The load's counts into the run's: each of the load's, upserted (inserted and updated) and skipped (unchanged). */
function addLoad(counts, loaded) {
  for (const k of LOAD_COUNTS) counts[k] = Number(loaded?.[k] ?? 0);
  counts.upserted = counts.inserted + counts.updated;
  counts.skipped = counts.unchanged;
}

/** The poll of one connection: the records modified since the cursor less five minutes, a partial batch. */
export async function pollAssets({ connection, store, budget, now = Date.now(), counts }) {
  const prep = await prepare({ connection, store, budget });
  refuseUnknown(connection, prep.check);
  const cur = await store.cursor(MODIFIED_STREAM);
  const formula = Number.isFinite(cur?.at) ? modifiedAfter(cur.at - OVERLAP_MS) : null;
  const { rows, detail } = await readRows({ connection, prep, formula, counts });
  addLoad(counts, rows.length ? await store.loadDevices(batchKeyOf("poll", now), rows, false) : {});
  await store.setCursor(MODIFIED_STREAM, { at: now });
  await store.setCursor(CADENCE_STREAM, { at: now });
  return { detail: { ...detail, fields: prep.names.length, changedSince: formula ? new Date(cur.at - OVERLAP_MS).toISOString() : "all" } };
}

/** A full snapshot of one connection (the nightly reconcile, a backfill): every record, is_full true. */
async function fullSnapshot({ connection, store, budget, counts, kind }) {
  const startedAt = Date.now();
  const prep = await prepare({ connection, store, budget });
  refuseUnknown(connection, prep.check);
  const { rows, detail } = await readRows({ connection, prep, formula: null, counts });
  if (!rows.length) throw new SourceError("empty_snapshot");
  addLoad(counts, await store.loadDevices(batchKeyOf(kind, startedAt), rows, true));
  await store.setCursor(MODIFIED_STREAM, { at: startedAt });
  return { ...detail, fields: prep.names.length };
}

export const RECONCILE_OBJECTS = [OBJECT_TYPE];
export const BACKFILL_OBJECTS = [OBJECT_TYPE];

export async function reconcile({ connection, store, budget, object, counts }) {
  if (object !== OBJECT_TYPE) throw new SourceError("object_not_reconciled");
  const detail = await fullSnapshot({ connection, store, budget, counts, kind: "night" });
  info("reconcile: devices", { connection: connection.connectionId, ...detail });
  return undefined;
}

export async function backfill({ connection, store, budget, object, counts }) {
  if (object !== OBJECT_TYPE) throw new SourceError("object_not_backfilled");
  const detail = await fullSnapshot({ connection, store, budget, counts, kind: "backfill" });
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
