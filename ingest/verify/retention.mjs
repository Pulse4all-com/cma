/**
 * Verifier (pure: no database, no network): the reconcile's purge of the run rows past their retention (addition 0009zt,
 * brief N07, decision D13; src/jobs/reconcile.mjs, purgeRunRows). On a mocked tenant transaction: batches while the
 * database answers more, at most the night's number of batches, each with its own lock and statement timeouts set
 * before the purge; a database without cma.sync_run_purge purges nothing and fails nothing; a batch that fails (a lock
 * timeout) stops the tenant's purge with its code and keeps what earlier batches deleted.
 *
 *   node verify/retention.mjs             every check must PASS
 *   node verify/retention.mjs --provoke   every check must FAIL
 */
import { purgeRunRows } from "../src/jobs/reconcile.mjs";

const PROVOKE = process.argv.includes("--provoke");
const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(90)} got ${JSON.stringify(actual).slice(0, 80)}`);
}

/** A tenant transaction answering the purge from a script of answers; records the statements */
function mockTx({ has = true, answers = [], failOn = -1 } = {}) {
  const log = [];
  let call = 0;
  const tx = async (ctx, fn) => {
    const q = {
      async query(text, values) {
        log.push(text.replace(/\s+/g, " ").slice(0, 60));
        if (/to_regprocedure/.test(text)) return { rows: [{ has }] };
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
  const r = await purgeRunRows(ctx, { tenantTx: tx });
  expect("a database before 0009zt: nothing purged, nothing failed", r, { deleted: 0, skipped: true }, { deleted: 0, error: "42883" });
}
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
