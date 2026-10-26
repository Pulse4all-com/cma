/**
 * The legacy call import (addition 0008zg; manual, no schedule): one file of legacy call outcomes exported from a former
 * telephony system, read from a private Cloud Storage bucket into memory, checked row by row, each row of the former
 * system matched to at most one contact of a CRM connection and stored as a legacy call outcome; the rows of the
 * current telephony system are only reconciled against its calls. Nothing personal is stored or logged.
 *
 *   node jobs/import-legacy-calls.mjs --connection <CRM connection uuid> --file gs://<bucket>/<object>
 *     --source-system <name> --cutover <YYYY-MM-DD> --date-format <DD-MM-YYYY> --columns <role=header,…>
 *     --meanings "<label>=<meaning key>;…" [--min-customer-id-digits <n>] [--unmatched store|skip] [--dry-run]
 *
 * Every argument is configuration; nothing of a tenant, a vendor or a file is in the code:
 *   --columns    the file's headers per role: tag (the old system's tag text), date (the call's date), source_marker (a
 *                column filled only on rows of the former system), and optionally email, phone and customer_id. Every
 *                other column (names among them) is never read; the marker column is read only as filled or empty
 *   --meanings   the old system's tag texts and the tag meaning each one has (docs/definitions.md, Tag): the seven keys
 *                of cma.telephony_tag.meaning. A text is compared trimmed, with inner spaces collapsed, case included
 *   --cutover    the first day of the current telephony system
 *   --min-customer-id-digits   the fewest digits a customer id has to be looked up (1 to 20, default 10); a shorter id,
 *                or one that is not all digits, is not used
 *   --unmatched  store (default): a row matched to no single contact (none, conflict) is stored without one; skip: such a
 *                row is not written, only rows matched to exactly one contact are (a rerun with skip inserts a row that now
 *                matches; a row a store run wrote earlier is left as it is)
 *
 * Per row (the header is row 1; an empty row is skipped and not counted):
 *   source        a filled marker is the former system (legacy), an empty one the current system (current). A legacy
 *                 row dated on or after the cutover, or a current row dated before it, is refused (cutover); a date
 *                 that does not read in the --date-format is refused (date)
 *   current rows  reconciliation only: the phone (E.164) hashed with the tenant's pepper (core/hash.mjs) and the
 *                 calls of the current telephony system on that date with that hash and a current tag meaning
 *                 courtesy_completed_* counted (cma.legacy_call_reconcile): found or not found. Nothing is stored
 *   legacy rows   a tag text without a mapping is refused (unmapped), an empty one, one over 100 characters or one
 *                 with an @ too (label). Then matched to exactly one contact per key, through the CRM adapter's
 *                 lookups (HubSpot: match.mjs): the email (the primary email, then the additional emails) and the
 *                 phone (E.164 only: searched by its national number, the candidates confirmed by their full number).
 *                 Both find the same contact: email_phone; only one finds exactly one: that key's method; they find
 *                 different contacts: conflict (left unlinked). Neither: the customer id, when it has at least
 *                 --min-customer-id-digits digits, first among the tenant's store customers linked to a contact of
 *                 this CRM connection (0008h, no API call), then in the CRM connection's contact ref fields:
 *                 customer_id. Otherwise none. The lookups are counted (lookups: per key the rows looked up and those
 *                 that found one contact or several) in every progress line and the finished line, so a lookup that
 *                 never finds anything shows within the first hundred rows
 *
 * Pace and resume: the CRM's searches at its adapter's search pace and every request guarded by the connection's
 * api_daily_floor_pct, as a backfill; the outcomes written every 100 rows, each part its own transaction; one sync_run
 * row (job legacy_call_import, stream the source system). A run that reaches the daily floor writes what it matched,
 * finishes as succeeded with error daily_floor and exits 0; the same command later reuses the batch (the file's
 * SHA-256), skips the rows that hold a contact or were forgotten, and matches the others again. Before any lookup the
 * run checks that the portal holds the properties the lookups rely on (property_missing otherwise).
 *
 * --dry-run reads and checks the file, reconciles the current rows and checks the properties: it searches no contact
 * and writes nothing (no batch, no outcome, no sync_run row).
 *
 * Privacy: the email, the phone, the names and the customer id stay in memory only, in this run, and are dropped once
 * a row is matched; nothing here logs or stores them. The log lines and the finished line hold counts and row numbers
 * only: total, legacy, current, refused (with the row numbers per reason), the reconciliation's found and not found,
 * the stored rows per match method, and the row numbers of conflict and none; with --unmatched skip also the skipped rows
 * per method (skipped_none, skipped_conflict: in the log only, never in the batch's counts) and their row numbers.
 */
import { createHash } from "node:crypto";
import { ADAPTERS } from "../adapters/index.mjs";
import { servedConnections, contextOf } from "../core/connection.mjs";
import { storeFor } from "../core/store.mjs";
import { JobBudget } from "../core/budget.mjs";
import { SourceError } from "../core/http.mjs";
import { getSecret } from "../core/secrets.mjs";
import { hashNumber, toE164 } from "../core/hash.mjs";
import { parseGsUri, readObject } from "../core/storage.mjs";
import { info } from "../core/log.mjs";
import { UsageError, withRun, PAUSE_CODE } from "./runner.mjs";

export const JOB = "legacy_call_import";
/** The tag meanings (docs/definitions.md, Tag): the check set of cma.telephony_tag.meaning and cma.legacy_call_outcome.meaning */
export const MEANINGS = ["not_reached", "incorrect_data", "call_type", "courtesy_attempt", "courtesy_completed_positive",
  "courtesy_completed_neutral", "courtesy_completed_negative"];
/** The column roles; true: required */
export const ROLES = { tag: true, date: true, source_marker: true, email: false, phone: false, customer_id: false };
export const METHODS = ["email_phone", "email", "phone", "customer_id", "none", "conflict", "forgotten"];
/** Methods a rerun never matches again: a contact is set, or the CRM deleted it for privacy */
const FINAL = new Set(["email_phone", "email", "phone", "customer_id", "forgotten"]);
export const COMMIT_EVERY = 100;
export const MIN_CUSTOMER_ID_DIGITS = 10;
/** What --unmatched takes: store the rows matched to no single contact (default) or skip them */
export const UNMATCHED = ["store", "skip"];

// ---- The arguments -------------------------------------------------------------------------------------------------

/** "tag=tags,date=timestamp call,…" → { role: header }; a UsageError for an unknown or doubled role or a required one missing */
export function parseColumns(spec) {
  const out = {};
  for (const part of String(spec ?? "").split(",")) {
    if (!part.trim()) continue;
    const at = part.indexOf("=");
    const role = (at > 0 ? part.slice(0, at) : part).trim();
    const header = at > 0 ? part.slice(at + 1).trim() : "";
    if (!Object.hasOwn(ROLES, role)) throw new UsageError(`--columns: unknown role ${role} (roles: ${Object.keys(ROLES).join(", ")})`);
    if (!header || header.length > 100) throw new UsageError(`--columns: ${role} needs a header of 1 to 100 characters`);
    if (Object.hasOwn(out, role)) throw new UsageError(`--columns: ${role} is named twice`);
    out[role] = header;
  }
  const missing = Object.keys(ROLES).filter((r) => ROLES[r] && !out[r]);
  if (missing.length) throw new UsageError(`--columns: ${missing.join(", ")} missing`);
  return out;
}

/** A tag text as compared: trimmed, inner white space collapsed to one space */
export function labelOf(text) {
  return String(text ?? "").replace(/\s+/g, " ").trim();
}

/** "<label>=<meaning>;…" → Map(label → meaning); the last = splits, so a label may hold one */
export function parseMeanings(spec) {
  const out = new Map();
  for (const part of String(spec ?? "").split(";")) {
    if (!part.trim()) continue;
    const at = part.lastIndexOf("=");
    const label = labelOf(at > 0 ? part.slice(0, at) : "");
    const meaning = (at > 0 ? part.slice(at + 1) : part).trim();
    if (!label || label.length > 100 || label.includes("@")) throw new UsageError("--meanings: a label is 1 to 100 characters without an @");
    if (!MEANINGS.includes(meaning)) throw new UsageError(`--meanings: ${meaning || "(empty)"} is no tag meaning (${MEANINGS.join(", ")})`);
    if (out.has(label) && out.get(label) !== meaning) throw new UsageError("--meanings: a label has two meanings");
    out.set(label, meaning);
  }
  if (!out.size) throw new UsageError("--meanings: no mapping");
  return out;
}

/**
 * A date format of the tokens DD (or D), MM (or M) and YYYY, each once, joined by one of - / . → a function from a
 * cell to YYYY-MM-DD, or null when the cell does not hold a calendar date in that format. A time after the date (after a
 * space or a T) is ignored.
 */
export function dateReader(format) {
  const m = /^(DD|D|MM|M|YYYY)([-/.])(DD|D|MM|M|YYYY)\2(DD|D|MM|M|YYYY)$/.exec(String(format ?? "").trim());
  const tokens = m ? [m[1], m[3], m[4]].map((t) => t[0]) : [];
  if (!m || [...tokens].sort().join("") !== "DMY") throw new UsageError("--date-format: the tokens DD, MM and YYYY, each once, joined by - / or .");
  const sep = m[2];
  return (cell) => {
    const text = String(cell ?? "").trim().split(/[\sT]/)[0];
    const parts = text.split(sep);
    if (parts.length !== 3) return null;
    const v = {};
    for (let i = 0; i < 3; i += 1) {
      const want = tokens[i] === "Y" ? /^\d{4}$/ : /^\d{1,2}$/;
      if (!want.test(parts[i])) return null;
      v[tokens[i]] = Number(parts[i]);
    }
    const d = new Date(Date.UTC(v.Y, v.M - 1, v.D));
    if (d.getUTCFullYear() !== v.Y || d.getUTCMonth() !== v.M - 1 || d.getUTCDate() !== v.D) return null;
    return d.toISOString().slice(0, 10);
  };
}

/** The job's arguments, checked; a UsageError names the first that is wrong */
export function configOf(a) {
  const file = parseGsUri(a.file);
  if (!a.connection || !file) throw new UsageError("--connection and --file gs://<bucket>/<object> are required");
  const sourceSystem = String(a["source-system"] ?? "");
  if (!/^[a-z0-9_]{1,40}$/.test(sourceSystem)) throw new UsageError("--source-system: 1 to 40 lower-case letters, digits or _");
  if (!a.cutover) throw new UsageError("--cutover is required (YYYY-MM-DD)");
  const given = a["min-customer-id-digits"];
  const digits = given === undefined ? MIN_CUSTOMER_ID_DIGITS : /^\d{1,2}$/.test(String(given)) ? Number(given) : Number.NaN;
  if (!(digits >= 1 && digits <= 20)) throw new UsageError("--min-customer-id-digits: a whole number from 1 to 20");
  const unmatched = a.unmatched === undefined ? "store" : a.unmatched;
  if (!UNMATCHED.includes(unmatched)) throw new UsageError(`--unmatched: ${UNMATCHED.join(" or ")}`);
  return {
    connectionId: a.connection, file, sourceSystem, cutover: a.cutover, readDate: dateReader(a["date-format"]),
    columns: parseColumns(a.columns), meanings: parseMeanings(a.meanings), minCustomerIdDigits: digits, unmatched, dryRun: a["dry-run"] === true,
  };
}

// ---- The file ------------------------------------------------------------------------------------------------------

/**
 * CSV text → records (arrays of cells): RFC 4180 quotes, CRLF or LF, an optional byte order mark; the delimiter is the
 * one of ; , and tab that the header line holds most of outside quotes (, when it holds none).
 */
export function parseCsv(text) {
  const s = String(text).replace(/^\uFEFF/, "");
  const head = s.slice(0, Math.max(0, s.search(/\r?\n/)) || s.length);
  const outside = head.replace(/"[^"]*"/g, "");
  const delimiter = [";", ",", "\t"].map((d) => [d, outside.split(d).length - 1]).sort((x, y) => y[1] - x[1])[0];
  const sep = delimiter[1] > 0 ? delimiter[0] : ",";
  const records = [];
  let record = [];
  let cell = "";
  let quoted = false;
  for (let i = 0; i < s.length; i += 1) {
    const ch = s[i];
    if (quoted) {
      if (ch === "\"" && s[i + 1] === "\"") {
        cell += "\"";
        i += 1;
      } else if (ch === "\"") {
        quoted = false;
      } else {
        cell += ch;
      }
    } else if (ch === "\"" && cell === "") {
      quoted = true;
    } else if (ch === sep) {
      record.push(cell);
      cell = "";
    } else if (ch === "\n" || ch === "\r") {
      if (ch === "\r" && s[i + 1] === "\n") i += 1;
      record.push(cell);
      records.push(record);
      record = [];
      cell = "";
    } else {
      cell += ch;
    }
  }
  if (cell !== "" || record.length) {
    record.push(cell);
    records.push(record);
  }
  return records;
}

/** An E.164 number as the file may write it (spaces, dashes, dots or brackets allowed), or null: never a national number */
export function e164Of(cell) {
  const text = String(cell ?? "").replace(/[\s().-]/g, "");
  if (!/^\+[1-9]\d{6,14}$/.test(text)) return null;
  return toE164(text) === text ? text : null;
}

/** A customer id of at least minDigits digits and at most 20 (spaces allowed), or null */
export function customerIdOf(cell, minDigits = MIN_CUSTOMER_ID_DIGITS) {
  const text = String(cell ?? "").replace(/\s/g, "");
  return /^\d{1,20}$/.test(text) && text.length >= minDigits ? text : null;
}

/**
 * The records (the header first) → the rows to work with: { row, source, date, refused, label, meaning, email, phone,
 * customerId }. Only the mapped columns are read; the marker as filled or empty. The email, phone and customer id are
 * kept for legacy rows that are not refused, the phone also for current rows; nothing else of a record is kept.
 */
export function rowsOf(records, config) {
  const header = (records[0] ?? []).map((h) => String(h).trim());
  const index = {};
  for (const [role, name] of Object.entries(config.columns)) {
    const i = header.indexOf(name);
    if (i < 0) throw new UsageError(`the file has no column "${name}" (--columns ${role})`);
    index[role] = i;
  }
  const cellOf = (record, role) => (index[role] === undefined ? "" : String(record[index[role]] ?? ""));
  const rows = [];
  for (let n = 1; n < records.length; n += 1) {
    const record = records[n];
    if (!record.some((c) => String(c).trim() !== "")) continue;
    const row = { row: n + 1, source: cellOf(record, "source_marker").trim() !== "" ? "legacy" : "current", date: config.readDate(cellOf(record, "date")),
      refused: null, label: null, meaning: null, email: null, phone: null, customerId: null };
    if (!row.date) row.refused = "date";
    else if (row.source === "legacy" ? row.date >= config.cutover : row.date < config.cutover) row.refused = "cutover";
    if (!row.refused && row.source === "legacy") {
      const label = labelOf(cellOf(record, "tag"));
      if (!label || label.length > 100 || label.includes("@")) row.refused = "label";
      else if (!config.meanings.has(label)) row.refused = "unmapped";
      else {
        row.label = label;
        row.meaning = config.meanings.get(label);
        row.email = cellOf(record, "email").trim() || null;
        row.customerId = customerIdOf(cellOf(record, "customer_id"), config.minCustomerIdDigits);
      }
    }
    if (!row.refused) row.phone = e164Of(cellOf(record, "phone"));
    rows.push(row);
  }
  return rows;
}

// ---- Matching ------------------------------------------------------------------------------------------------------

/** The lookups' counts: per key the rows looked up and those that found one contact or several */
export const emptyLookups = () => ({ email: { searched: 0, one: 0, several: 0 }, phone: { searched: 0, one: 0, several: 0 },
  customerId: { searched: 0, one: 0, several: 0 } });

function tally(lookups, key, ids) {
  if (!lookups || ids === null) return;
  lookups[key].searched += 1;
  if (ids.length === 1) lookups[key].one += 1;
  else if (ids.length > 1) lookups[key].several += 1;
}

/**
 * One legacy row's contact: { method, contactId }. crm: the CRM adapter's lookups; connection: the CRM connection;
 * refProperties: its contact ref fields; lookups: the counts to add to (emptyLookups()). Throws the lookups'
 * SourceError (daily_floor among them).
 */
export async function matchRow({ row, crm, connection, store, refProperties, budget, lookups = null }) {
  const byEmail = row.email ? await crm.findContactsByAnyEmail({ connection, email: row.email, budget }) : null;
  tally(lookups, "email", byEmail);
  const byPhone = row.phone ? await crm.findContactsByPhone({ connection, e164: row.phone, budget }) : null;
  tally(lookups, "phone", byPhone);
  const email = byEmail?.length === 1 ? byEmail[0] : null;
  const phone = byPhone?.length === 1 ? byPhone[0] : null;
  if (email && phone) return email === phone ? { method: "email_phone", contactId: email } : { method: "conflict", contactId: null };
  if (email) return { method: "email", contactId: email };
  if (phone) return { method: "phone", contactId: phone };
  if (row.customerId) {
    let found = await store.customerContacts(row.customerId);
    if (!found.length && refProperties.length) {
      found = await crm.findContactsByProperties({ connection, properties: refProperties, value: row.customerId, budget });
    }
    tally(lookups, "customerId", found);
    if (found.length === 1) return { method: "customer_id", contactId: found[0] };
  }
  return { method: "none", contactId: null };
}

/** Drops a row's personal values (in place) */
function forget(row) {
  row.email = null;
  row.phone = null;
  row.customerId = null;
}

// ---- The run -------------------------------------------------------------------------------------------------------

/**
 * One import. opts: the parsed arguments (jobs/import-legacy-calls.mjs). The seams, for the verifier: adapters, read
 * (the object reader), secret (the secret reader), served (the connection lookup) and storeOf (a connection's store).
 * Answers the finished line's fields and failed (0 or 1).
 */
export async function runImportLegacyCalls(opts, {
  adapters = ADAPTERS, read = readObject, secret = getSecret, served = servedConnections, storeOf = (c) => storeFor(contextOf(c), c.connectionId),
} = {}) {
  const started = Date.now();
  const config = configOf(opts);
  const [c] = await served({ connectionId: config.connectionId, actorLabel: "ingest:import-legacy-calls" });
  if (!c) throw new UsageError("no active connection with that id (or its tenant or Ingest user is inactive)");
  const adapter = Object.hasOwn(adapters, c.adapter) ? adapters[c.adapter] : null;
  const crm = adapter?.crm;
  if (!crm?.findContactsByAnyEmail || !crm.findContactsByPhone || !crm.missingContactProperties) {
    throw new UsageError(`the ${c.adapter} adapter cannot look contacts up by email and phone`);
  }
  const store = storeOf(c);

  // The file: read into memory, its SHA-256, the rows; the bytes, text and records dropped at once
  let bytes = await read(config.file);
  const sha256 = createHash("sha256").update(bytes).digest("hex");
  let records = parseCsv(bytes.toString("utf8"));
  bytes = null;
  const rows = rowsOf(records, config);
  records = null;

  const out = {
    connection: c.connectionId, sourceSystem: config.sourceSystem, dryRun: config.dryRun, file: { bucket: config.file.bucket }, sha256,
    total: rows.length, legacy: rows.filter((r) => r.source === "legacy").length, current: rows.filter((r) => r.source === "current").length,
    refused: rows.filter((r) => r.refused).length, refusedRows: {}, reconciliation: { found: 0, notFound: 0 },
  };
  for (const r of rows.filter((x) => x.refused)) (out.refusedRows[r.refused] ??= []).push(r.row);

  // The current system's rows: reconciliation only (the phone hashed and dropped)
  const current = rows.filter((r) => r.source === "current" && !r.refused);
  if (current.length) {
    let pepper;
    try {
      pepper = await secret(`ingest-hash-pepper-${c.tenantSlug}`);
    } catch {
      throw new SourceError("pepper_unavailable");
    }
    const items = [];
    for (const r of current) {
      const hash = r.phone ? hashNumber(pepper, r.phone) : null;
      forget(r);
      if (hash) items.push({ item: r.row, hash, date: r.date });
    }
    pepper = null;
    const calls = items.length ? await store.legacyReconcile(items) : new Map();
    out.reconciliation.found = items.filter((i) => (calls.get(i.item) ?? 0) > 0).length;
    out.reconciliation.notFound = current.length - out.reconciliation.found;
  }

  const floorPct = adapter.dailyFloor ? await adapter.dailyFloor({ store, connection: c, job: "import-legacy-calls" }) : null;
  const budget = new JobBudget(adapter.rates, undefined, { floorPct });
  const legacy = rows.filter((r) => r.source === "legacy" && !r.refused);

  if (config.dryRun) {
    for (const r of legacy) forget(r);
    const missing = await crm.missingContactProperties({ connection: c, names: crm.lookupProperties ?? [], budget });
    const failed = missing.length ? 1 : 0;
    return { ...out, ...(missing.length ? { missingProperties: missing, error: "property_missing" } : {}), ...budget.usage(), ms: Date.now() - started, failed };
  }

  let batch = null;
  let missing = [];
  let pausedAt = null;
  const skipping = config.unmatched === "skip";
  const skipped = { none: [], conflict: [] };
  const run = await withRun(store, { job: JOB, stream: config.sourceSystem }, async (counts) => {
    // sync_run's counts: every row read; the refused ones failed; the current system's rows (reconciled, not stored)
    // and the rows not written again skipped; the rows written upserted
    counts.fetched = rows.length;
    counts.failed = out.refused;
    counts.skipped = current.length;
    missing = await crm.missingContactProperties({ connection: c, names: crm.lookupProperties ?? [], budget });
    if (missing.length) return { error: "property_missing" };
    batch = await store.legacyBatchStart(config.sourceSystem, sha256, config.cutover);
    const stored = await store.legacyBatchRows(batch.batchId);
    const refProperties = await store.contactRefProperties();
    const outcomes = {};
    out.lookups = emptyLookups();
    let buffer = [];
    let handled = 0;
    // the progress line: with skip, a line every 100 rows handled too, so a lookup that finds nothing still shows early
    const flush = async (lastRow, force = false) => {
      if (!buffer.length && !force) return;
      const part = buffer;
      buffer = [];
      if (part.length) for (const [k, v] of Object.entries(await store.upsertLegacyOutcomes(batch.batchId, part))) outcomes[k] = (outcomes[k] ?? 0) + v;
      info("import-legacy-calls: progress", { connection: c.connectionId, batch: batch.batchId, written: part.length, lastRow: part.at(-1)?.sourceRow ?? lastRow,
        lookups: out.lookups, ...(skipping ? { skipped_none: skipped.none.length, skipped_conflict: skipped.conflict.length } : {}) });
    };
    let error = null;
    try {
      for (const r of legacy) {
        if (FINAL.has(stored.get(r.row))) {
          forget(r);
          counts.skipped += 1;
          continue;
        }
        let m;
        try {
          m = await matchRow({ row: r, crm, connection: c, store, refProperties, budget, lookups: out.lookups });
        } catch (err) {
          if (err instanceof SourceError && err.code === PAUSE_CODE) {
            pausedAt = r.row;
            error = PAUSE_CODE;
            break;
          }
          throw err;
        } finally {
          forget(r);
        }
        handled += 1;
        if (skipping && (m.method === "none" || m.method === "conflict")) {
          skipped[m.method].push(r.row);
          counts.skipped += 1;
        } else {
          buffer.push({ sourceRow: r.row, occurredOn: r.date, meaning: r.meaning, sourceLabel: r.label, contactId: m.contactId, matchMethod: m.method });
        }
        if (buffer.length >= COMMIT_EVERY) await flush(r.row);
        else if (skipping && handled % COMMIT_EVERY === 0) await flush(r.row, true);
      }
    } finally {
      for (const r of legacy) forget(r);
      await flush(null);
    }
    counts.upserted = (outcomes.inserted ?? 0) + (outcomes.filled ?? 0) + (outcomes.updated ?? 0);
    counts.skipped += (outcomes.unchanged ?? 0) + (outcomes.kept ?? 0) + (outcomes.forgotten ?? 0);
    out.written = outcomes;
    if (error) return { error };
    out.counts = await store.legacyBatchFinish(batch.batchId, {
      total: out.total, legacy: out.legacy, current: out.current, refused: out.refused,
      current_found: out.reconciliation.found, current_not_found: out.reconciliation.notFound,
    });
    return undefined;
  });

  // What the batch holds now: the stored rows per match method, and the row numbers of conflict and none
  if (batch) {
    const stored = await store.legacyBatchRows(batch.batchId);
    out.batch = batch.batchId;
    out.batchOutcome = batch.outcome;
    out.methods = Object.fromEntries(METHODS.map((m) => [m, 0]));
    for (const m of stored.values()) out.methods[m] = (out.methods[m] ?? 0) + 1;
    const rowsWith = (m) => [...stored].filter(([, v]) => v === m).map(([k]) => k).sort((x, y) => x - y);
    out.conflictRows = rowsWith("conflict");
    out.noneRows = rowsWith("none");
  }
  if (skipping) {
    out.skipped_none = skipped.none.length;
    out.skipped_conflict = skipped.conflict.length;
    out.skippedNoneRows = skipped.none;
    out.skippedConflictRows = skipped.conflict;
  }
  return {
    ...out, ...(missing.length ? { missingProperties: missing } : {}), ...(pausedAt ? { pausedAtRow: pausedAt } : {}),
    run: run.counts, error: run.error ?? undefined, paused: run.paused || undefined, ...budget.usage(), ms: Date.now() - started, failed: run.ok ? 0 : 1,
  };
}
