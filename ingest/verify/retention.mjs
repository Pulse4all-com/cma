/**
 * Verifier (pure: no database, no network): the reconcile's purge of the run rows past their retention (addition 0009zt,
 * brief N07, decision D13; src/jobs/reconcile.mjs, purgeRunRows). On a mocked tenant transaction: batches while the
 * database answers more, at most the night's number of batches, each with its own lock and statement timeouts set
 * before the purge; a database without cma.sync_run_purge purges nothing and fails nothing; a batch that fails (a lock
 * timeout) stops the tenant's purge with its code and keeps what earlier batches deleted. The existence check names the
 * signature of the function's latest definition in db/ in run order (read from the scripts; a later drop without a new
 * create leaves none), and the mock confirms that signature only, so a check that names another one purges nothing here,
 * as it would in every database (25 November 2026). The parse takes each argument's second word (name, then type): it
 * reads 240's form (name type default x); an argument without a name, a mode word, a type of several words or with a
 * modifier reads wrong and fails the checks, never the other way round.
 *
 *   node verify/retention.mjs             every check must PASS
 *   node verify/retention.mjs --provoke   every check must FAIL
 */
import { readdirSync, readFileSync } from "node:fs";
import { setLogSink } from "../src/core/log.mjs";
import { PURGE_SIGNATURE, purgeRunRows } from "../src/jobs/reconcile.mjs";

const PROVOKE = process.argv.includes("--provoke");
const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(90)} got ${JSON.stringify(actual).slice(0, 80)}`);
}

/**
 * cma.sync_run_purge's signature as its latest definition in db/ creates it (the scripts in run order: by number), its
 * argument types only; null when a later script drops it without a new create, or none creates it
 */
const DB = new URL("../../db/", import.meta.url);
const scripts = readdirSync(DB).filter((f) => /^\d+_.*\.sql$/.test(f) && !/_verify_/.test(f))
  .sort((a, b) => parseInt(a, 10) - parseInt(b, 10) || a.localeCompare(b));
let SIGNATURE_DB = null;
for (const f of scripts) {
  const text = readFileSync(new URL(f, DB), "utf8");
  for (const m of text.matchAll(/(create(?: or replace)? function|drop function if exists) cma\.sync_run_purge\(([^)]*)\)/gi)) {
    const types = m[2].split(",").map((a) => a.trim()).filter(Boolean);
    const sig = `cma.sync_run_purge(${types.map((a) => (/^drop/i.test(m[1]) ? a.split(/\s+/)[0] : a.split(/\s+/)[1])).join(",")})`;
    if (/^create/i.test(m[1])) SIGNATURE_DB = sig;
    else if (sig === SIGNATURE_DB) SIGNATURE_DB = null;
  }
}

/** A tenant transaction answering the purge from a script of answers; records the statements */
function mockTx({ has = true, answers = [], failOn = -1 } = {}) {
  const log = [];
  let call = 0;
  const tx = async (ctx, fn) => {
    const q = {
      async query(text, values) {
        log.push(text.replace(/\s+/g, " ").slice(0, 60));
        // the database knows the function by the signature the migration created, and by no other
        if (/to_regprocedure/.test(text)) return { rows: [{ has: has && (values ?? [])[0] === SIGNATURE_DB }] };
        if (/cma\.sync_run_purge/.test(text)) {
          if (call === failOn) { call += 1; throw Object.assign(new Error("canceling statement due to lock timeout"), { code: "55P03" }); }
          const a = answers[call] ?? { deleted: 0, more: false };
          call += 1;
          return { rows: [{ r: { ...a, batch: values[0] } }] };
        }
        return { rows: [] };
      },
    };
    return fn(q);
  };
  return { tx, log };
}
const ctx = { tenantId: "01a10651-0000-7000-8000-000000000001", userId: "u", actorLabel: "ingest:hubspot" };

{
  const { tx, log } = mockTx({ answers: [{ deleted: 2000, more: true }, { deleted: 2000, more: true }, { deleted: 37, more: false }] });
  const r = await purgeRunRows(ctx, { tenantTx: tx });
  const order = log.filter((l) => !/to_regprocedure/.test(l)).slice(0, 3);
  expect("three batches until the database says no more; timeouts set before each purge", [r, order],
    [{ deleted: 4037, batches: 3, more: false }, ["set local lock_timeout = '2s'", "set local statement_timeout = '30s'", "select cma.sync_run_purge($1) as r"]],
    [{ deleted: 0 }, []]);
}
{
  const { tx } = mockTx({ answers: Array.from({ length: 9 }, () => ({ deleted: 10, more: true })) });
  const r = await purgeRunRows(ctx, { tenantTx: tx, batches: 4 });
  expect("at most the night's batches; more stays true for the next night", r, { deleted: 40, batches: 4, more: true }, { deleted: 90, batches: 9, more: false });
}
{
  const { tx } = mockTx({ has: false });
  const lines = [];
  setLogSink((line) => lines.push(JSON.parse(line)));
  const r = await purgeRunRows(ctx, { tenantTx: tx });
  setLogSink((line) => process.stdout.write(line + "\n"));
  const said = lines.map((l) => [l.severity, l.message, l.code ?? null]);
  expect("a database without the function: nothing purged, nothing failed, one warning that says so", [r, said],
    [{ deleted: 0, skipped: true }, [["WARNING", "reconcile: sync_run retention skipped", "function_missing"]]],
    [{ deleted: 0, error: "42883" }, []]);
}
expect("the existence check names the signature of the latest definition in db/", [PURGE_SIGNATURE === SIGNATURE_DB, SIGNATURE_DB],
  [true, "cma.sync_run_purge(integer,text,uuid)"], [false, "cma.sync_run_purge(integer)"]);
{
  const { tx } = mockTx({ answers: [{ deleted: 2000, more: true }], failOn: 1 });
  const r = await purgeRunRows(ctx, { tenantTx: tx });
  expect("a lock timeout stops the tenant's purge with its code, the first batch's deletes counted", r,
    { deleted: 2000, batches: 1, error: "db_55P03" }, { deleted: 0, batches: 0, more: false });
}

const passed = results.filter(Boolean).length;
if (PROVOKE) {
  console.log(passed === 0 ? `\nALL ${results.length} PROVOKED CHECKS FAILED, as they must` : `\n${passed} checks did not fail when provoked`);
  process.exit(passed === 0 ? 0 : 1);
}
console.log(`\n${passed === results.length ? `ALL ${results.length} PASS` : `${results.length - passed} of ${results.length} FAILED`}`);
process.exit(passed === results.length ? 0 : 1);
