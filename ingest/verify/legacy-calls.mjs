/**
 * Verifier: the legacy call import (addition 0008zg) without a database, against a fake HubSpot on the local machine, a
 * fake store that keeps the rows as cma.legacy_call_outcomes_upsert does (db/108; db/109 proves the SQL itself), and the
 * synthetic fixture verify/fixtures/legacy-calls/legacy-calls.csv: invented people, example.invalid addresses, made-up
 * numbers and customer ids.
 *
 *   node verify/legacy-calls.mjs [--provoke]
 *
 * Proves: the arguments (columns, meanings, the date format, the file's address, --min-customer-id-digits); the CSV (a byte order mark, ;, quotes
 * with a ; and a quote inside, CRLF, a blank row); the rows (the source by the marker, the cutover both ways, a date that
 * is no date, an unmapped label, the row numbers); E.164 only; the lookups (the primary email in any case, an additional
 * email confirmed by its list, a decoy refused, two contacts with one email; the phone by its national number with the
 * same national number in NL and GB, a national-format number confirmed with the row's region, more than five
 * candidates read as several); every match path through a whole run (email_phone, email, phone, customer_id by a store
 * customer and by a ref field, conflict, none) with the counts, the row numbers and the lookups counted per key in the
 * finished line and the progress line; the reconciliation of the current
 * rows; a rerun (the batch reused, the rows with a contact not searched again, a none filled); --unmatched skip (no none
 * or conflict row stored, the skipped counts and row numbers in the finished and the progress line, a rerun that inserts a
 * row that now matches, a row a store run wrote earlier left as it is); a dry run (no search, no
 * write, no run row); a pause at the daily floor and its resume; a portal without a property; the Cloud Storage reader;
 * and that the captured log, every run's answer and everything every store was given or holds (rows, upserts, the
 * reconciliation's items, counts, run rows, batches) hold none of the fixture's names, emails, phones or customer ids.
 */
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import http from "node:http";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { parsePhoneNumberFromString } from "libphonenumber-js";
import { expect, verdict, PROVOKE } from "./lib.mjs";

console.log(`verify/legacy-calls.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

const here = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE = readFileSync(path.join(here, "fixtures/legacy-calls/legacy-calls.csv"));
const secretsDir = mkdtempSync(path.join(tmpdir(), "legacy-calls-"));
writeFileSync(path.join(secretsDir, "fixture-hubspot-token"), "fixture-token-not-a-secret");
process.env.INGEST_SECRETS_DIR = secretsDir;
process.env.INGEST_PACE_FACTOR = "0";

// ---- The fake HubSpot: contacts with email, additional emails, phone and mobile phone, and a ref property ----------
const CONTACTS = [
  { id: "102", email: "fx.two@example.invalid", phone: "+31201110002" },
  { id: "103", email: "fx.three@example.invalid" },
  { id: "104", phone: "+31 20 111 0004" },
  { id: "204", phone: "+44 20 1110004" },                                   // the same national number in GB
  { id: "105", hs_additional_emails: "fx.old@example.invalid;fx.five@example.invalid" },
  { id: "205", hs_additional_emails: "xfx.five@example.invalid" },          // a decoy the token search finds too
  { id: "106", email: "fx.six@example.invalid" },
  { id: "116", mobilephone: "+31201110006" },
  { id: "108", fx_shop_customer_id: "9876543210987" },
  { id: "110", email: "fx.ten@example.invalid" },
  { id: "210", email: "fx.ten@example.invalid" },                           // two contacts with one email
  { id: "118", phone: "030 111 0018" },                                     // national format, normalised with NL
  { id: "119", email: "fx.nineteen@example.invalid", mobilephone: "+31 20 111 0019" },
  { id: "120", email: "fx.twenty@example.invalid" },
  ...["+31", "+44", "+32", "+49", "+33", "+34"].map((cc, i) => ({ id: `13${i}`, phone: `${cc}201110020` })), // six candidates
  { id: "121", email: "fx.twentyone@example.invalid" },
];
const national = (v) => {
  if (!v) return null;
  const p = String(v).trim().startsWith("+") ? parsePhoneNumberFromString(String(v)) : null;
  return p ? p.nationalNumber : String(v).replace(/\D/g, "").replace(/^0/, "");
};
const fake = { contacts: CONTACTS, searches: 0, requests: 0, missing: new Set(), dailyRemaining: () => 100_000, bodies: [] };
function matches(contact, f) {
  const v = String(f.value).toLowerCase();
  if (f.propertyName === "hs_searchable_calculated_phone_number") return national(contact.phone) === f.value;
  if (f.propertyName === "hs_searchable_calculated_mobile_number") return national(contact.mobilephone) === f.value;
  if (f.operator === "CONTAINS_TOKEN") return String(contact[f.propertyName] ?? "").toLowerCase().includes(v);
  return String(contact[f.propertyName] ?? "").toLowerCase() === v;
}
const server = http.createServer((req, res) => {
  let body = "";
  req.on("data", (c) => { body += c; });
  req.on("end", () => {
    fake.requests += 1;
    fake.bodies.push(body);
    res.setHeader("content-type", "application/json");
    res.setHeader("x-hubspot-ratelimit-daily", "1000");
    res.setHeader("x-hubspot-ratelimit-daily-remaining", String(fake.dailyRemaining()));
    const url = new URL(req.url, "http://fake");
    if (req.headers.authorization !== "Bearer fixture-token-not-a-secret") return res.writeHead(401).end("{}");
    const prop = /^\/crm\/v3\/properties\/contacts\/([a-z0-9_]+)$/.exec(url.pathname);
    if (req.method === "GET" && prop) {
      if (fake.missing.has(prop[1])) return res.writeHead(404).end("{}");
      return res.writeHead(200).end(JSON.stringify({ name: prop[1], type: "string" }));
    }
    if (req.method === "POST" && url.pathname === "/crm/v3/objects/contacts/search") {
      fake.searches += 1;
      const q = JSON.parse(body);
      const hits = fake.contacts.filter((c) => q.filterGroups.some((g) => g.filters.every((f) => matches(c, f))));
      return res.writeHead(200).end(JSON.stringify({ total: hits.length, results: hits.slice(0, q.limit).map((c) => ({ id: c.id, properties: {} })) }));
    }
    if (req.method === "POST" && url.pathname === "/crm/v3/objects/contacts/batch/read") {
      const q = JSON.parse(body);
      const results = q.inputs.map((i) => fake.contacts.find((c) => c.id === i.id)).filter(Boolean)
        .map((c) => ({ id: c.id, properties: Object.fromEntries(q.properties.map((p) => [p, c[p] ?? null])) }));
      return res.writeHead(200).end(JSON.stringify({ results }));
    }
    return res.writeHead(404).end("{}");
  });
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
process.env.INGEST_HUBSPOT_API_BASE = `http://127.0.0.1:${server.address().port}`;

const logs = [];
const { setLogSink } = await import("../src/core/log.mjs");
setLogSink((line) => logs.push(line));
const {
  parseColumns, parseMeanings, dateReader, configOf, parseCsv, rowsOf, e164Of, customerIdOf, runImportLegacyCalls, MEANINGS,
} = await import("../src/jobs/import-legacy-calls.mjs");
const { findContactsByAnyEmail, findContactsByPhone, LOOKUP_PROPERTIES } = await import("../src/adapters/hubspot/match.mjs");
const { parseGsUri, readObject } = await import("../src/core/storage.mjs");
const { ADAPTERS } = await import("../src/adapters/index.mjs");
const { JobBudget } = await import("../src/core/budget.mjs");
const { UsageError } = await import("../src/jobs/runner.mjs");
const { hashNumber } = await import("../src/core/hash.mjs");

const CRM = { tenantId: "00000000-0000-7000-8000-00000000f001", tenantSlug: "fixture-tenant", connectionId: "00000000-0000-7000-8000-00000000f002",
  adapter: "hubspot", externalAccountId: "fixture-portal", tokenSecretName: "fixture-hubspot-token", ingestUserId: "00000000-0000-7000-8000-00000000f003" };
const PEPPER = "fixture-pepper-not-a-secret";
const ARGS = {
  connection: CRM.connectionId, file: "gs://cma-import-fixture/legacy-calls.csv", "source-system": "legacyfixture", cutover: "2026-09-01",
  "date-format": "DD-MM-YYYY", columns: "tag=tags,date=timestamp call,phone=Phone,email=Email,customer_id=Customer ID,source_marker=Inlaaddatum",
  meanings: "Courtesy positief=courtesy_completed_positive;Courtesy neutraal=courtesy_completed_neutral;Courtesy negatief=courtesy_completed_negative",
};
const usage = (fn) => {
  try {
    fn();
    return "ok";
  } catch (err) {
    return err instanceof UsageError ? "usage" : "other";
  }
};

// ---- The fake store: the rows as cma.legacy_call_outcomes_upsert keeps them --------------------------------------------
function fakeStore() {
  const db = { runs: [], batches: [], rows: new Map(), finished: null, writes: [] };
  return {
    db,
    async config() { return { settings: { api_daily_floor_pct: 25 } }; },
    async runStart(job, stream) { db.runs.push({ job, stream, status: "running" }); return db.runs.length; },
    async runFinish(id, status, counts, error) { Object.assign(db.runs[id - 1], { status, counts: { ...counts }, error }); },
    async legacyBatchStart(system, sha, cutover) {
      db.writes.push(["start", system, sha, cutover]);
      const live = db.batches.find((b) => b.sha === sha);
      if (live) return { batchId: live.id, outcome: "reused" };
      db.batches.push({ id: `batch-${db.batches.length + 1}`, sha, system, cutover });
      return { batchId: db.batches.at(-1).id, outcome: "started" };
    },
    async legacyBatchRows() { return new Map([...db.rows].map(([k, v]) => [k, v.method])); },
    async upsertLegacyOutcomes(batchId, rows) {
      db.writes.push(["upsert", batchId, structuredClone(rows)]);
      const counts = {};
      for (const r of rows) {
        const old = db.rows.get(r.sourceRow);
        let outcome;
        if (!old) {
          db.rows.set(r.sourceRow, { on: r.occurredOn, meaning: r.meaning, label: r.sourceLabel, contact: r.contactId, method: r.matchMethod });
          outcome = "inserted";
        } else if (old.method === "forgotten") outcome = "forgotten";
        else if (old.contact) outcome = old.contact === r.contactId && old.method === r.matchMethod ? "unchanged" : "kept";
        else if (r.contactId) {
          Object.assign(old, { contact: r.contactId, method: r.matchMethod });
          outcome = "filled";
        } else if (old.method !== r.matchMethod) {
          old.method = r.matchMethod;
          outcome = "updated";
        } else outcome = "unchanged";
        counts[outcome] = (counts[outcome] ?? 0) + 1;
      }
      return counts;
    },
    async legacyBatchFinish(batchId, counts) {
      db.writes.push(["finish", batchId, counts]);
      db.finished = { ...counts, stored: db.rows.size };
      return db.finished;
    },
    async legacyReconcile(items) {
      db.writes.push(["reconcile", structuredClone(items)]);
      // one courtesy-completed call: the number of row 11 on 3 September 2026
      const known = hashNumber(PEPPER, "+31201110011");
      return new Map(items.map((i) => [i.item, i.hash === known && i.date === "2026-09-03" ? 1 : 0]));
    },
    async customerContacts(id) { return id === "1234567890123" ? ["107"] : []; },
    async contactRefProperties() { return ["fx_shop_customer_id"]; },
  };
}
// The store calls in flight at once, over every run: each call of the real store is one transaction, so at most one
// at a time is the job's one unit of work beside its advisory lock, the jobs' pool of 2 (Gemini audit of 28 October
// 2026, FIND-01)
const inFlight = { now: 0, peak: 0, calls: 0 };
const counted = (store) => new Proxy(store, {
  get(target, key, receiver) {
    const v = Reflect.get(target, key, receiver);
    if (typeof v !== "function") return v;
    return async (...a) => {
      inFlight.calls += 1;
      inFlight.now += 1;
      inFlight.peak = Math.max(inFlight.peak, inFlight.now);
      try {
        return await v.apply(target, a);
      } finally {
        inFlight.now -= 1;
      }
    };
  },
});
const seams = (store) => ({
  adapters: ADAPTERS, read: async () => Buffer.from(FIXTURE), secret: async () => PEPPER,
  served: async ({ connectionId }) => (connectionId === CRM.connectionId ? [CRM] : []), storeOf: () => counted(store),
});
// Every run's answer and the store it wrote to, for the privacy checks of section J
const seen = [];
async function importRun(args, store) {
  const out = await runImportLegacyCalls(args, seams(store));
  seen.push({ out, db: store.db });
  return out;
}
const rowsText = (db) => [...db.rows].sort(([a], [b]) => a - b).map(([k, v]) => `${k}:${v.method}:${v.contact ?? "-"}`).join(" ");

// ---- A. The arguments --------------------------------------------------------------------------------------------------
expect("A1 the columns: every role, a header with a space; unknown, doubled or missing roles refused",
  [JSON.stringify(parseColumns(ARGS.columns)), usage(() => parseColumns("tag=a,date=b")), usage(() => parseColumns(`${ARGS.columns},name=Voornaam`)),
    usage(() => parseColumns(`${ARGS.columns},tag=x`))],
  [JSON.stringify({ tag: "tags", date: "timestamp call", phone: "Phone", email: "Email", customer_id: "Customer ID", source_marker: "Inlaaddatum" }), "usage", "usage", "usage"],
  ["{}", "ok", "ok", "ok"]);
const m = parseMeanings("Courtesy  positief = courtesy_completed_positive; A=B=call_type");
expect("A2 the meanings: trimmed, spaces collapsed, the last = splits; an unknown key, an @ or a double meaning refused",
  [[...m].join("|"), MEANINGS.length, usage(() => parseMeanings("X=happy")), usage(() => parseMeanings("a@b=call_type")),
    usage(() => parseMeanings("X=call_type;X=not_reached")), usage(() => parseMeanings(""))],
  ["Courtesy positief,courtesy_completed_positive|A=B,call_type", 7, "usage", "usage", "usage", "usage"],
  ["", 6, "ok", "ok", "ok", "ok"]);
const dmy = dateReader("DD-MM-YYYY");
expect("A3 the date format: a time ignored, one digit allowed, 31 February and other orders refused; YYYY-MM-DD and MM/DD/YYYY read",
  [dmy("14-05-2025 10:23:00"), dmy("1-6-2025"), dmy("31-02-2026"), dmy("2025-05-14"), dmy(""), dateReader("YYYY-MM-DD")("2025-05-14T09:00"),
    dateReader("MM/DD/YYYY")("05/14/2025"), usage(() => dateReader("DD-MM-YY")), usage(() => dateReader("DD-DD-YYYY"))],
  ["2025-05-14", "2025-06-01", null, null, null, "2025-05-14", "2025-05-14", "usage", "usage"],
  [null, null, "2026-03-03", "2025-05-14", "", null, null, "ok", "ok"]);
expect("A5 --min-customer-id-digits: 10 by default, 1 to 20; 13 digits taken at 13, refused at 14",
  [configOf(ARGS).minCustomerIdDigits, configOf({ ...ARGS, "min-customer-id-digits": "13" }).minCustomerIdDigits,
    usage(() => configOf({ ...ARGS, "min-customer-id-digits": "0" })), usage(() => configOf({ ...ARGS, "min-customer-id-digits": "21" })),
    usage(() => configOf({ ...ARGS, "min-customer-id-digits": "1e1" })), customerIdOf("1234567890123", 13), customerIdOf("1234567890123", 14),
    rowsOf(parseCsv(FIXTURE.toString("utf8")), configOf({ ...ARGS, "min-customer-id-digits": "14" })).find((x) => x.row === 7).customerId],
  [10, 13, "usage", "usage", "usage", "1234567890123", null, null], [13, 10, "ok", "ok", "ok", null, "1234567890123", "1234567890123"]);
expect("A6 --unmatched: store by default, store or skip taken; anything else, or the bare flag, refused",
  [configOf(ARGS).unmatched, configOf({ ...ARGS, unmatched: "skip" }).unmatched, configOf({ ...ARGS, unmatched: "store" }).unmatched,
    usage(() => configOf({ ...ARGS, unmatched: "drop" })), usage(() => configOf({ ...ARGS, unmatched: true }))],
  ["store", "skip", "store", "usage", "usage"], ["skip", "store", "skip", "ok", "ok"]);
expect("A4 the file's address and the source system: gs:// only; a bad bucket, an http address, a bad source system refused",
  [JSON.stringify(parseGsUri("gs://cma-import-fixture/calls/courtesy.csv")), parseGsUri("gs://A/b"), parseGsUri("https://x/y"),
    usage(() => configOf({ ...ARGS, file: "/home/someone/file.csv" })), usage(() => configOf({ ...ARGS, "source-system": "Legacy" })),
    usage(() => configOf({ ...ARGS, cutover: undefined })), usage(() => configOf(ARGS))],
  [JSON.stringify({ bucket: "cma-import-fixture", object: "calls/courtesy.csv" }), null, null, "usage", "usage", "usage", "ok"],
  ["null", {}, {}, "ok", "ok", "ok", "usage"]);

// ---- B. The file and its rows --------------------------------------------------------------------------------------------
const records = parseCsv(FIXTURE.toString("utf8"));
const config = configOf(ARGS);
const rows = rowsOf(records, config);
expect("B1 the CSV: the byte order mark, ; as delimiter, a quoted ; and \"\" inside, CRLF, 21 records",
  [records[0][0], records.length, records[18][0], records[18][1], records[20].at(-1), records[16].length],
  ["Voornaam", 21, "Fixture; \"Negentien\"", "Persoon; Negentien", "11-08-2025", 8],
  ["﻿Voornaam", 20, "Fixture", "Persoon", "11-08-2025\r", 1]);
expect("B2 the rows: the blank one skipped, numbered from the header as row 1; the source by the marker",
  [rows.length, rows.map((r) => r.row).join(","), rows.filter((r) => r.source === "legacy").length, rows.filter((r) => r.source === "current").map((r) => r.row).join(",")],
  [19, "2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,18,19,20,21", 16, "11,12,14"],
  [20, "1,2,3", 17, "11,12"]);
expect("B3 the refusals: the cutover both ways (13, 14), unmapped (15), a date that is no date (16); a doubled space in a label mapped (19)",
  [rows.filter((r) => r.refused).map((r) => `${r.row}:${r.refused}`).join(" "), rows.find((r) => r.row === 19).meaning, rows.find((r) => r.row === 12).meaning],
  ["13:cutover 14:cutover 15:unmapped 16:date", "courtesy_completed_positive", null],
  ["", null, "courtesy_completed_positive"]);
expect("B4 E.164 only (spaces allowed); a national number, 00 and letters refused; a customer id of 10 or more digits only",
  [e164Of("+31 20 111 0002"), e164Of("020 111 0009"), e164Of("0031201110009"), e164Of("+31 twenty"), customerIdOf("1234567890123"), customerIdOf("12345"),
    customerIdOf("cus_FX10"), rows.find((r) => r.row === 9).phone],
  ["+31201110002", null, null, null, "1234567890123", null, null, null],
  [null, "+31201110009", "+31201110009", null, null, "12345", "cus_FX10", "+31201110009"]);
expect("B5 a missing column is a usage error naming its role",
  usage(() => rowsOf(parseCsv("a;b\n1;2\n"), config)), "usage", "ok");

// ---- C. The lookups ------------------------------------------------------------------------------------------------------
const budget = new JobBudget(ADAPTERS.hubspot.rates);
const before = fake.searches;
const lookups = [
  await findContactsByAnyEmail({ connection: CRM, email: "FX.Three@example.invalid ", budget }),
  await findContactsByAnyEmail({ connection: CRM, email: "fx.five@example.invalid", budget }),
  await findContactsByAnyEmail({ connection: CRM, email: "fx.ten@example.invalid", budget }),
  await findContactsByAnyEmail({ connection: CRM, email: "no-at-sign", budget }),
];
expect("C1 the email: the primary in any case; an additional one confirmed, its decoy left out; two contacts several; no @ no search",
  [lookups.map((x) => x.join("+")).join(" "), fake.searches - before],
  ["103 105 110+210 ", 4], ["103 105+205 110 ", 5]);
const phones = [
  await findContactsByPhone({ connection: CRM, e164: "+31201110004", budget }),
  await findContactsByPhone({ connection: CRM, e164: "+31301110018", budget }),
  await findContactsByPhone({ connection: CRM, e164: "+31201110020", budget }),
  await findContactsByPhone({ connection: CRM, e164: "020 111 0009", budget }),
];
const searchBody = JSON.parse(fake.bodies.filter((b) => b.includes("hs_searchable_calculated_phone_number")).at(0));
expect("C2 the phone: NL and GB share the national number, the NL one kept; a national-format number confirmed with NL; six candidates several",
  [phones.map((x) => x.join("+")).join(" "), searchBody.filterGroups.map((g) => `${g.filters[0].propertyName}=${g.filters[0].value}`).join(","), searchBody.limit],
  ["104 118 130+131 ", "hs_searchable_calculated_phone_number=201110004,hs_searchable_calculated_mobile_number=201110004", 5],
  ["104+204 118 130 ", "", 6]);
expect("C3 the properties the lookups rely on, checked on the portal", LOOKUP_PROPERTIES.join(","),
  "hs_additional_emails,hs_searchable_calculated_phone_number,hs_searchable_calculated_mobile_number,phone,mobilephone", "");

// ---- D. A dry run: no search, no write, no run row ------------------------------------------------------------------------
let store = fakeStore();
fake.searches = 0;
let r = await importRun({ ...ARGS, "dry-run": true }, store);
expect("D1 a dry run: the counts; refused rows per reason; the reconciliation; nothing searched, written or run",
  [r.total, r.legacy, r.current, r.refused, JSON.stringify(r.refusedRows), JSON.stringify(r.reconciliation), fake.searches,
    store.db.writes.filter((w) => w[0] !== "reconcile").length, store.db.runs.length, r.failed, r.methods],
  [19, 16, 3, 4, JSON.stringify({ cutover: [13, 14], unmapped: [15], date: [16] }), JSON.stringify({ found: 1, notFound: 1 }), 0, 0, 0, 0, undefined],
  [19, 16, 3, 0, "{}", "{}", 13, 1, 1, 1, {}]);
expect("D2 …the SHA-256 of the file, the reconciliation sent as hashes and dates only",
  [r.sha256, JSON.stringify(store.db.writes[0][1].map((i) => Object.keys(i).join("+")))],
  [createHash("sha256").update(FIXTURE).digest("hex"), JSON.stringify(["item+hash+date", "item+hash+date"])], ["", "[]"]);

// ---- E. A whole run: every match path ------------------------------------------------------------------------------------
store = fakeStore();
r = await importRun(ARGS, store);
const EXPECTED_ROWS = "2:email_phone:102 3:email:103 4:phone:104 5:email:105 6:conflict:- 7:customer_id:107 8:customer_id:108 9:none:- 10:none:- "
  + "18:phone:118 19:email_phone:119 20:email:120 21:email:121";
expect("E1 every match path stored: email_phone, email (primary and additional), phone (collision, national format), customer_id (store, ref field), conflict, none",
  rowsText(store.db), EXPECTED_ROWS, "");
expect("E2 …the stored rows' facts: date, meaning and label as the file and mapping say",
  [JSON.stringify(store.db.rows.get(2)), JSON.stringify(store.db.rows.get(19))],
  [JSON.stringify({ on: "2025-05-14", meaning: "courtesy_completed_positive", label: "Courtesy positief", contact: "102", method: "email_phone" }),
    JSON.stringify({ on: "2025-08-09", meaning: "courtesy_completed_positive", label: "Courtesy positief", contact: "119", method: "email_phone" })],
  ["", ""]);
expect("E3 the finished line: the counts per source and method, the row numbers of conflict, none and refused",
  [r.batchOutcome, r.total, r.legacy, r.current, r.refused, JSON.stringify(r.methods), r.conflictRows.join(","), r.noneRows.join(","), r.failed, r.error ?? null],
  ["started", 19, 16, 3, 4, JSON.stringify({ email_phone: 2, email: 4, phone: 2, customer_id: 2, none: 2, conflict: 1, forgotten: 0 }), "6", "9,10", 0, null],
  ["reused", 0, 0, 0, 0, "{}", "", "", 1, "x"]);
expect("E5 the lookups counted per key (rows looked up, one, several), in the finished line and the progress line",
  [JSON.stringify(r.lookups), logs.some((l) => l.includes("import-legacy-calls: progress") && l.includes(JSON.stringify(r.lookups)))],
  [JSON.stringify({ email: { searched: 10, one: 7, several: 1 }, phone: { searched: 6, one: 5, several: 1 }, customerId: { searched: 2, one: 2, several: 0 } }), true],
  ["{}", false]);
expect("E4 the batch's counts and the run's row: legacy_call_import, its stream, succeeded; commits in parts of at most 100",
  [JSON.stringify(store.db.finished), JSON.stringify(store.db.runs), store.db.writes.filter((w) => w[0] === "upsert").map((w) => w[2].length).join(",")],
  [JSON.stringify({ total: 19, legacy: 16, current: 3, refused: 4, current_found: 1, current_not_found: 1, stored: 13 }),
    JSON.stringify([{ job: "legacy_call_import", stream: "legacyfixture", status: "succeeded", counts: { fetched: 19, upserted: 13, stale: 0, skipped: 2, failed: 4 }, error: null }]),
    "13"],
  ["{}", "[]", "100"]);

// ---- F. A rerun: the batch reused, the rows with a contact not searched again, a none filled --------------------------------
fake.contacts = fake.contacts.filter((c) => c.id !== "210");
fake.searches = 0;
r = await importRun(ARGS, store);
expect("F1 a rerun: the batch reused; row 10 filled (its email now one contact); conflict and none searched again, the rest not",
  [r.batchOutcome, rowsText(store.db), fake.searches, JSON.stringify(r.written), store.db.batches.length],
  ["reused", EXPECTED_ROWS.replace("10:none:-", "10:email:110"), 5, JSON.stringify({ unchanged: 2, filled: 1 }), 1],
  ["started", EXPECTED_ROWS, 25, "{}", 2]);
fake.contacts.push({ id: "210", email: "fx.ten@example.invalid" });

// ---- F2. --unmatched skip: only the rows matched to exactly one contact are written --------------------------------------
const MATCHED_ROWS = EXPECTED_ROWS.split(" ").filter((x) => !/:(none|conflict):/.test(x)).join(" ");
const skipArgs = { ...ARGS, unmatched: "skip" };
store = fakeStore();
logs.length = 0;
r = await importRun(skipArgs, store);
expect("F2 skip: no none or conflict row stored; the skipped counts and row numbers in the finished line and the progress line; the batch's counts keep their keys",
  [rowsText(store.db), r.skipped_none, r.skipped_conflict, r.skippedNoneRows.join(","), r.skippedConflictRows.join(","), r.methods.none, r.methods.conflict,
    Object.keys(store.db.finished).sort().join(","), store.db.runs[0].counts.skipped, r.failed,
    logs.some((l) => l.includes("import-legacy-calls: progress") && l.includes('"skipped_none":2') && l.includes('"skipped_conflict":1'))],
  [MATCHED_ROWS, 2, 1, "9,10", "6", 0, 0, "current,current_found,current_not_found,legacy,refused,stored,total", 5, 0, true],
  [EXPECTED_ROWS, 0, 0, "", "", 2, 1, "", 2, 1, false]);
fake.contacts = fake.contacts.filter((c) => c.id !== "210");
r = await importRun(skipArgs, store);
expect("F3 a rerun with skip after a fixture contact gains the email (row 10's second contact gone): that row is inserted, the batch reused, the others as they were",
  [r.batchOutcome, rowsText(store.db), r.skipped_none, r.skippedNoneRows.join(","), r.skipped_conflict, JSON.stringify(r.written)],
  ["reused", `${MATCHED_ROWS} 10:email:110`.split(" ").sort((x, y) => parseInt(x) - parseInt(y)).join(" "), 1, "9", 1, JSON.stringify({ inserted: 1 })],
  ["started", MATCHED_ROWS, 2, "9,10", 0, "{}"]);
fake.contacts.push({ id: "210", email: "fx.ten@example.invalid" });
// a row a store run wrote earlier is left as it is by a skip run
const kept = fakeStore();
await importRun(ARGS, kept);
const before0 = rowsText(kept.db);
const writes0 = kept.db.writes.length;
r = await importRun(skipArgs, kept);
expect("F4 a skip run after a store run: the none and conflict rows it wrote stay as they are, and nothing about them is written again",
  [rowsText(kept.db), kept.db.writes.slice(writes0).filter((w) => w[0] === "upsert").flatMap((w) => w[2]).filter((x) => x.matchMethod === "none" || x.matchMethod === "conflict").length],
  [before0, 0], ["", 3]);

// ---- G. A pause at the daily floor, then the same command again ------------------------------------------------------------
store = fakeStore();
let n = 0;
fake.dailyRemaining = () => (n++ < 12 ? 900 : 100);
r = await importRun(ARGS, store);
const partial = store.db.rows.size;
expect("G1 below the daily floor: the run pauses as succeeded with daily_floor, keeps what it matched, the batch not finished",
  [r.paused, r.error, r.failed, store.db.runs[0].status, store.db.runs[0].error, partial > 0 && partial < 13, store.db.finished, typeof r.pausedAtRow],
  [true, "daily_floor", 0, "succeeded", "daily_floor", true, null, "number"],
  [undefined, null, 1, "failed", null, false, {}, "undefined"]);
fake.dailyRemaining = () => 900;
r = await importRun(ARGS, store);
expect("G2 …the same command later continues and ends where a whole run ends",
  [r.paused, r.batchOutcome, rowsText(store.db), store.db.finished?.stored, store.db.runs.map((x) => x.status).join(",")],
  [undefined, "reused", EXPECTED_ROWS, 13, "succeeded,succeeded"],
  [true, "started", "", 0, ""]);

// ---- H. A portal without a property the lookups rely on --------------------------------------------------------------------
store = fakeStore();
fake.missing.add("hs_searchable_calculated_mobile_number");
fake.searches = 0;
r = await importRun(ARGS, store);
const dry = await importRun({ ...ARGS, "dry-run": true }, fakeStore());
fake.missing.clear();
expect("H1 a missing property: the run fails with property_missing before any search or batch; the dry run says so too",
  [r.error, r.failed, JSON.stringify(r.missingProperties), fake.searches, store.db.batches.length, store.db.runs[0].status, dry.error, dry.failed],
  ["property_missing", 1, JSON.stringify(["hs_searchable_calculated_mobile_number"]), 0, 0, "failed", "property_missing", 1],
  [null, 0, "[]", 1, 1, "succeeded", null, 0]);

// ---- I. The Cloud Storage reader -------------------------------------------------------------------------------------------
const gcs = http.createServer((req, res) => {
  if (req.headers.authorization !== "Bearer fixture-gcs-token") return res.writeHead(401).end();
  if (req.url === "/storage/v1/b/cma-import-fixture/o/calls%2Fcalls.csv?alt=media") return res.writeHead(200).end("a;b\n1;2\n");
  if (req.url.startsWith("/storage/v1/b/cma-import-fixture/o/big.csv")) return res.writeHead(200).end("x".repeat(2048));
  return res.writeHead(404).end();
});
await new Promise((ok) => gcs.listen(0, "127.0.0.1", ok));
process.env.INGEST_STORAGE_API_BASE = `http://127.0.0.1:${gcs.address().port}`;
const token = async () => "fixture-gcs-token";
const codeOf = async (p) => p.then(() => "ok", (e) => e.code ?? "error");
expect("I1 the object read with the bearer token, its path encoded; 404 object_not_found; over the cap object_too_large",
  [(await readObject({ bucket: "cma-import-fixture", object: "calls/calls.csv" }, { token })).toString(),
    await codeOf(readObject({ bucket: "cma-import-fixture", object: "missing.csv" }, { token })),
    await codeOf(readObject({ bucket: "cma-import-fixture", object: "big.csv" }, { token, maxBytes: 1024 }))],
  ["a;b\n1;2\n", "object_not_found", "object_too_large"], ["", "ok", "ok"]);
gcs.close();

// ---- J. Nothing personal in the log, the answers or the stored rows ----------------------------------------------------------
const text = FIXTURE.toString("utf8");
const PERSONAL = [
  ...new Set([...text.matchAll(/fx\.[a-z.]+@example\.invalid/gi)].map((x) => x[0].toLowerCase())),
  ...new Set([...text.matchAll(/Persoon [A-Za-z]+/g)].map((x) => x[0])), "Negentien",
  ...new Set([...text.matchAll(/\+31[\d ]+/g)].map((x) => x[0].replace(/\s/g, ""))), "201110002", "111 0002", "1110018",
  "1234567890123", "9876543210987", "cus_FX10",
];
// every run of this file (dry, whole, rerun, paused and resumed, property missing): its answer, and everything its store
// was given or holds (the rows, the upserts, the reconciliation items, the finishes, the run rows)
const answers = JSON.stringify(seen.map((x) => x.out));
const stored = JSON.stringify(seen.map((x) => [[...x.db.rows.values()], x.db.writes, x.db.finished, x.db.runs, x.db.batches]));
const logText = logs.join("\n");
const leaks = (s) => PERSONAL.filter((p) => s.toLowerCase().includes(p.toLowerCase()));
expect("J1 the fixture holds the values the check looks for (emails, names, numbers, customer ids)", PERSONAL.length > 30, true, false);
expect("J2 the captured log holds none of them", leaks(logText), [], PERSONAL);
expect("J3 every run's answer (the finished line) holds none of them; eleven runs scanned", [leaks(answers), seen.length], [[], 11], [PERSONAL, 0]);
expect("J4 everything the stores were given or hold (rows, upserts, reconciliation, counts, run rows) holds none of them; rows present",
  [leaks(stored), seen.reduce((n, x) => n + x.db.rows.size, 0) > 30], [[], true], [PERSONAL, false]);
expect("J5 the log has progress and nothing but counts, row numbers and ids: no email, no +",
  [logs.some((l) => l.includes("import-legacy-calls: progress")), /@|\+\d/.test(logText)], [true, false], [false, true]);

server.close();
expect("K1 the import calls its store one call at a time, over every run: one unit of work beside its lock, the jobs' pool of 2",
  [inFlight.calls > 50, inFlight.peak], [true, 1], [false, 2]);
rmSync(secretsDir, { recursive: true, force: true });
verdict();
