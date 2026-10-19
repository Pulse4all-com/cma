/**
 * Verifier (pure: no database, no network): the scheduler jobs through a dropped database connection
 * (jobs/lib/connection.mjs, jobs/refresh-follow-up.mjs, jobs/close-forgotten-workdays.mjs; 18 October 2026, after a
 * reset connection ended a refresh-follow-up execution in prod at 16:04 UTC). Each job runs on a mocked pool whose
 * clients answer the job's statements and can be made to fail: a reset on a given statement for a given tenant
 * (once or twice), a reset on connect, the server ending a client's session while it is out, an idle client's reset.
 * Proves: a connection error is retried once on a fresh connection, the broken one dropped, the run row kept (one per
 * tenant), and the run finished as succeeded; a second one fails the tenant and its run row (with the code), the
 * other tenants still served; any other error is never retried; an idle client's error is one warning line and no
 * crash; the run row's finish is retried on its own, never repeating the close. Invented ids only.
 *
 *   node verify/jobs.mjs             every check must PASS
 *   node verify/jobs.mjs --provoke   every check must FAIL
 */
import { EventEmitter } from "node:events";
import { codeOf, hearIdleErrors, isConnectionError, retryOnce } from "../jobs/lib/connection.mjs";
import { refreshTenants } from "../jobs/refresh-follow-up.mjs";
import { closeTenants } from "../jobs/close-forgotten-workdays.mjs";

const PROVOKE = process.argv.includes("--provoke");
const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(72)} got ${JSON.stringify(actual).slice(0, 70)}${pass ? "" : `, wanted ${JSON.stringify(want).slice(0, 70)}`}`);
}

const T1 = "01a10651-0000-7000-8000-000000000001";
const T2 = "01a10651-0000-7000-8000-000000000002";
const USER = "01a10651-0000-7000-8000-0000000000aa";
const reset = () => Object.assign(new Error("read ECONNRESET"), { code: "ECONNRESET" });

/**
 * A mocked pg pool. faults: [{ on: regex of the statement, tenant, times, error: () => Error, emit: true }]; a fault
 * with emit sends the error as the client's 'error' event (the server ending the session) and then fails the
 * statement as pg does ("Connection terminated unexpectedly"). connectFaults: errors for the next connects.
 */
function mockPool({ faults = [], connectFaults = [] } = {}) {
  const pool = new EventEmitter();
  const state = { connects: 0, released: 0, dropped: 0, statements: [], runStarts: [], runFinishes: [] };
  let nextRun = 0;
  pool.state = state;
  pool.connect = async () => {
    state.connects += 1;
    if (connectFaults.length) throw connectFaults.shift()();
    const client = new EventEmitter();
    let tenant = null;
    client.release = (err) => { state.released += 1; if (err) state.dropped += 1; };
    client.query = async (text, values = []) => {
      if (/set_config\('app\.tenant_id'/.test(text)) tenant = values[0];
      state.statements.push({ text, tenant });
      const fault = faults.find((f) => f.times > 0 && f.on.test(text) && (!f.tenant || f.tenant === tenant));
      if (fault) {
        fault.times -= 1;
        if (fault.emit) {
          client.emit("error", fault.error());
          throw new Error("Connection terminated unexpectedly");
        }
        throw fault.error();
      }
      if (/find_tenants_for_identity/.test(text)) return { rows: [{ tenant_id: T1 }, { tenant_id: T2 }], rowCount: 2 };
      if (/from cma\.app_user_external_id/.test(text)) return { rows: [{ id: USER, slug: tenant === T1 ? "one" : "two" }], rowCount: 1 };
      if (/cma\.job_run_start|cma\.scheduler_run_start/.test(text)) {
        nextRun += 1;
        const id = `00000000-0000-7000-8000-${String(nextRun).padStart(12, "0")}`;
        state.runStarts.push({ tenant, id });
        return { rows: [{ id }], rowCount: 1 };
      }
      if (/cma\.refresh_follow_up\(\)/.test(text)) return { rows: [{ r: { refreshed: true, rows: 3, leads: 1, tickets: 1, tasks: 1, duration_ms: 7 } }], rowCount: 1 };
      if (/cma\.job_run_finish/.test(text)) {
        state.runFinishes.push({ tenant, id: values[0], status: /'failed'/.test(text) ? "failed" : "succeeded", detail: /'failed'/.test(text) ? values[1] : JSON.parse(values[1]).rows });
        return { rows: [], rowCount: 1 };
      }
      if (/cma\.scheduler_run_finish/.test(text)) {
        state.runFinishes.push({ tenant, id: values[0], status: values[1], detail: values[1] === "failed" ? values[3] : values[2] });
        return { rows: [], rowCount: 1 };
      }
      if (/cma\.close_forgotten_workdays/.test(text)) return { rows: [{ workday_id: "w1", user_id: "u1", business_date: "2026-10-17", ended_at: "2026-10-17T15:00:00Z" }], rowCount: 1 };
      return { rows: [], rowCount: 0 };
    };
    return client;
  };
  return pool;
}

const lines = [];
const log = (severity, fields) => lines.push({ severity, ...fields });
const out = { log: () => undefined, warn: (s) => lines.push({ severity: "WARNING", text: s }), error: (s) => lines.push({ severity: "ERROR", text: s }) };
const count = (pool, re, tenant) => pool.state.statements.filter((s) => re.test(s.text) && (!tenant || s.tenant === tenant)).length;
const finishes = (pool) => pool.state.runFinishes.map((f) => `${f.tenant === T1 ? "t1" : "t2"}:${f.status}:${f.detail}`);
const starts = (pool, tenant) => pool.state.runStarts.filter((s) => s.tenant === tenant).length;

// ---- What counts as a lost connection --------------------------------------------------------------
expect("connection errors: socket codes, class 08, 57P01, pg's own message",
  [reset(), { code: "08006" }, { code: "57P01" }, new Error("Connection terminated unexpectedly"), { code: "ETIMEDOUT" }].map(isConnectionError),
  [true, true, true, true, true], [false, false, false, false, false]);
expect("never a connection error: a statement timeout, a refusal, a constraint, nothing",
  [{ code: "57014" }, { code: "CMA04" }, { code: "23505" }, new Error("no active scheduler user"), null].map(isConnectionError),
  [false, false, false, false, false], [true, true, true, true, true]);
expect("the code in a log line or run row", [codeOf(reset()), codeOf(new Error("Connection terminated unexpectedly")), codeOf({ code: "57014" }), codeOf(new Error("x"))],
  ["ECONNRESET", "connection", "57014", "error"], ["error", "error", "error", "error"]);
let tries = 0;
const twice = await retryOnce(async () => { tries += 1; if (tries === 1) throw reset(); return "done"; }, { log: () => undefined }).catch((e) => e.code);
let tries2 = 0;
const notRetried = await retryOnce(async () => { tries2 += 1; throw Object.assign(new Error("timeout"), { code: "57014" }); }, { log: () => undefined }).catch((e) => e.code);
expect("retryOnce: a lost connection tried again, anything else not", [twice, tries, notRetried, tries2], ["done", 2, "57014", 1], ["ECONNRESET", 1, "done", 2]);

// ---- An idle client's reset -----------------------------------------------------------------------------
const bare = new EventEmitter();
let crashed = false;
try { bare.emit("error", reset()); } catch { crashed = true; }
const heard = new EventEmitter();
lines.length = 0;
hearIdleErrors(heard, log);
let heardCrashed = false;
try { heard.emit("error", reset()); } catch { heardCrashed = true; }
expect("idle reset: unheard it throws (the 16:04 crash), heard it is one warning line", [crashed, heardCrashed, lines.map((l) => `${l.severity}:${l.reason}:${l.error}`)],
  [true, false, ["WARNING:idle connection lost:ECONNRESET"]], [false, true, []]);

// ---- refresh-follow-up --------------------------------------------------------------------------------------
{
  const pool = mockPool();
  lines.length = 0;
  const r = await refreshTenants({ connect: pool.connect, log });
  expect("refresh: both tenants refreshed, one run row each, finished succeeded, every client released",
    [r, finishes(pool), starts(pool, T1), starts(pool, T2), pool.state.released === pool.state.connects, pool.state.dropped],
    [{ tenants: 2, failed: 0 }, ["t1:succeeded:3", "t2:succeeded:3"], 1, 1, true, 0], [{ tenants: 2, failed: 1 }, [], 2, 2, false, 1]);
}
{
  const pool = mockPool({ faults: [{ on: /cma\.refresh_follow_up\(\)/, tenant: T1, times: 1, error: reset }] });
  lines.length = 0;
  const r = await refreshTenants({ connect: pool.connect, log });
  expect("refresh, a reset in tenant 1's refresh: retried on a fresh connection, the broken one dropped",
    [r.failed, count(pool, /cma\.refresh_follow_up\(\)/, T1), pool.state.dropped, finishes(pool)], [0, 2, 1, ["t1:succeeded:3", "t2:succeeded:3"]],
    [1, 1, 0, ["t1:failed:ECONNRESET", "t2:succeeded:3"]]);
  expect("…its run row kept: one start for the tenant, not two; one warning line naming it",
    [starts(pool, T1), lines.filter((l) => l.severity === "WARNING").map((l) => `${l.tenant_id === T1}:${l.reason}:${l.error}`)],
    [1, ["true:connection lost, retried once:ECONNRESET"]], [2, []]);
}
{
  const pool = mockPool({ faults: [{ on: /cma\.refresh_follow_up\(\)/, tenant: T1, times: 2, error: reset }] });
  lines.length = 0;
  const r = await refreshTenants({ connect: pool.connect, log });
  expect("refresh, a reset twice: tenant 1 fails, its run row failed with the code; tenant 2 still served",
    [r, finishes(pool), lines.filter((l) => l.severity === "ERROR").map((l) => `${l.tenant_id === T1}:${l.error}`)],
    [{ tenants: 2, failed: 1 }, ["t1:failed:ECONNRESET", "t2:succeeded:3"], ["true:ECONNRESET"]],
    [{ tenants: 2, failed: 0 }, ["t1:succeeded:3", "t2:succeeded:3"], []]);
}
{
  const pool = mockPool({ faults: [{ on: /cma\.refresh_follow_up\(\)/, tenant: T1, times: 1, error: () => Object.assign(new Error("canceling statement due to statement timeout"), { code: "57014" }) }] });
  lines.length = 0;
  const r = await refreshTenants({ connect: pool.connect, log });
  expect("refresh, a statement timeout: never retried, the tenant failed with 57014, the client kept",
    [r.failed, count(pool, /cma\.refresh_follow_up\(\)/, T1), finishes(pool)[0], pool.state.dropped], [1, 1, "t1:failed:57014", 0], [0, 2, "t1:succeeded:3", 1]);
}
{
  const pool = mockPool({ faults: [{ on: /find_tenants_for_identity/, times: 1, error: reset }] });
  lines.length = 0;
  const r = await refreshTenants({ connect: pool.connect, log });
  expect("refresh, a reset reading the tenants: retried, both served", [r, count(pool, /find_tenants_for_identity/)], [{ tenants: 2, failed: 0 }, 2], [{ tenants: 0, failed: 0 }, 1]);
}
{
  const pool = mockPool({ connectFaults: [reset] });
  lines.length = 0;
  const r = await refreshTenants({ connect: pool.connect, log });
  expect("refresh, a reset on connect: retried, both served", [r, pool.state.connects >= 4], [{ tenants: 2, failed: 0 }, true], [{ tenants: 2, failed: 1 }, false]);
}
{
  const pool = mockPool({ faults: [{ on: /cma\.job_run_start/, tenant: T2, times: 1, emit: true, error: () => Object.assign(new Error("terminating connection due to administrator command"), { code: "57P01" }) }] });
  lines.length = 0;
  const r = await refreshTenants({ connect: pool.connect, log });
  expect("refresh, the server ends a client's session while it is out: that work's failure, retried, dropped",
    [r.failed, starts(pool, T2), pool.state.dropped, lines.filter((l) => l.severity === "WARNING").map((l) => l.error)], [0, 1, 1, ["57P01"]], [1, 0, 0, []]);
}

// ---- close-forgotten-workdays ---------------------------------------------------------------------------------
{
  const pool = mockPool();
  lines.length = 0;
  const r = await closeTenants({ connect: pool.connect, out });
  expect("close: both tenants closed, one run row each, finished succeeded with the count",
    [r, finishes(pool), starts(pool, T1), starts(pool, T2), pool.state.released === pool.state.connects],
    [{ tenants: 2, failed: 0 }, ["t1:succeeded:1", "t2:succeeded:1"], 1, 1, true], [{ tenants: 2, failed: 1 }, [], 2, 2, false]);
}
{
  const pool = mockPool({ faults: [{ on: /cma\.close_forgotten_workdays/, tenant: T1, times: 1, error: reset }] });
  lines.length = 0;
  const r = await closeTenants({ connect: pool.connect, out });
  expect("close, a reset in tenant 1's close: retried, its run row kept, finished succeeded",
    [r.failed, count(pool, /cma\.close_forgotten_workdays/, T1), starts(pool, T1), finishes(pool)[0], pool.state.dropped], [0, 2, 1, "t1:succeeded:1", 1],
    [1, 1, 2, "t1:failed:ECONNRESET", 0]);
}
{
  const pool = mockPool({ faults: [{ on: /cma\.close_forgotten_workdays/, tenant: T1, times: 2, error: reset }] });
  lines.length = 0;
  const r = await closeTenants({ connect: pool.connect, out });
  expect("close, a reset twice: tenant 1 fails, its run row failed with the code; tenant 2 still served",
    [r, finishes(pool), lines.filter((l) => l.severity === "ERROR").length], [{ tenants: 2, failed: 1 }, ["t1:failed:ECONNRESET", "t2:succeeded:1"], 1],
    [{ tenants: 2, failed: 0 }, ["t1:succeeded:1", "t2:succeeded:1"], 0]);
}
{
  const pool = mockPool({ faults: [{ on: /cma\.scheduler_run_finish/, tenant: T1, times: 1, error: reset }] });
  lines.length = 0;
  const r = await closeTenants({ connect: pool.connect, out });
  expect("close, a reset finishing the run row: the finish retried on its own, the close never repeated",
    [r.failed, count(pool, /cma\.close_forgotten_workdays/, T1), count(pool, /cma\.scheduler_run_finish/, T1), finishes(pool)[0]], [0, 1, 2, "t1:succeeded:1"],
    [1, 2, 1, "t1:failed:ECONNRESET"]);
}
{
  const pool = mockPool({ faults: [{ on: /cma\.close_forgotten_workdays/, tenant: T1, times: 1, error: () => Object.assign(new Error("not permitted"), { code: "CMA06" }) }] });
  lines.length = 0;
  const r = await closeTenants({ connect: pool.connect, out });
  expect("close, a refusal of the database: never retried, the tenant failed with its code",
    [r.failed, count(pool, /cma\.close_forgotten_workdays/, T1), finishes(pool)[0]], [1, 1, "t1:failed:CMA06"], [0, 2, "t1:succeeded:1"]);
}

const passed = results.filter(Boolean).length;
const n = results.length;
if (PROVOKE) {
  const ok = passed === 0;
  console.log(`\n${ok ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
  process.exit(ok ? 0 : 1);
}
console.log(`\n${passed === n ? `ALL ${n} PASS` : `${n - passed} of ${n} FAILED`}`);
process.exit(passed === n ? 0 : 1);
