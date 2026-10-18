/**
 * Verifier: the follow-up refresh job (jobs/refresh-follow-up.mjs, addition 0008s) end to end, against a database
 * with the dev seeds and 80_follow_up_snapshot.sql, with two sessions where one script in Cloud SQL Studio has one.
 *
 *   PGCONN="host=127.0.0.1 port=5433 dbname=cma user=<you> …" \
 *   CMA_DB_HOST=… CMA_DB_PORT=… CMA_DB_USER=… CMA_DB_PASSWORD=… node verify/refresh-follow-up.mjs            every check must PASS
 *   … node verify/refresh-follow-up.mjs --provoke                                                          every check must FAIL
 *
 * PGCONN is a psql connection string under your own login (the Auth Proxy, or the local cluster); the job runs
 * with the CMA_DB_* variables it would get on Cloud Run (or the local path; CMA_DB_SET_ROLE=cma_app for a personal
 * login). Proves: the job serves every tenant with a scheduler user and exits 0; one JSON line per tenant with its
 * id, the rows and duration_ms, and no @ anywhere; every tenant's snapshot computed just now with a succeeded
 * sync_run row whose rows match the line; while a second session holds the dev tenant's refresh lock, the job
 * skips that tenant (its line and its row say so) and refreshes the others; once the lock is gone, it refreshes it.
 *
 * Dev only: before anything runs, the database PGCONN points to must hold the dev seed's test person
 * (agent.two@example.com, db/03); otherwise the verifier refuses and exits 2. It writes only what the job writes
 * every minute in dev anyway: snapshots and run rows.
 */
import { execFileSync, spawn, spawnSync } from "node:child_process";

const PROVOKE = process.argv.includes("--provoke");
const PGCONN = process.env.PGCONN;
if (!PGCONN) {
  console.error("PGCONN (a psql connection string) is required");
  process.exit(2);
}
const sql = (text) => execFileSync("psql", [PGCONN, "-At", "-v", "ON_ERROR_STOP=1", "-c", "set role cma_owner", "-c", text], { encoding: "utf8" })
  .trim().split("\n").filter((l) => l !== "SET");

const devCheck = spawnSync("psql", [PGCONN, "-At", "-v", "ON_ERROR_STOP=1", "-c", "set role cma_owner", "-c",
  `select exists (select 1 from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                  where u.email = 'agent.two@example.com' and u.status = 'active')`], { encoding: "utf8" });
if (devCheck.status !== 0 || (devCheck.stdout ?? "").trim().split("\n").pop() !== "t") {
  console.error("refresh-follow-up verifier: refusing to run, the connected database is not dev (no active agent.two@example.com)");
  process.exit(2);
}

const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  const shown = (v) => String(typeof v === "string" ? v : JSON.stringify(v)).slice(0, 70);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(60)} got ${shown(actual)}${pass ? "" : `, wanted ${shown(want)}`}`);
}
function runJob() {
  const r = spawnSync(process.execPath, ["jobs/refresh-follow-up.mjs"], { encoding: "utf8", env: process.env });
  const out = (r.stdout + r.stderr).trim();
  const lines = out.split("\n").filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return { unparsed: l }; } });
  return { code: r.status, out, lines };
}
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

console.log(`verify/refresh-follow-up.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);
const tenants = sql(`select x.tenant_id from cma.app_user_external_id x join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id
                     join cma.tenant t on t.id = x.tenant_id
                     where x.system = 'scheduler' and x.external_id = 'scheduler' and u.status = 'active' and t.status = 'active' order by 1`);
const devTenant = sql(`select tenant_id from cma.app_user where email = 'agent.two@example.com' and status = 'active' limit 1`)[0];

// 1. One run: every tenant, one line each, the snapshot and the run row
const first = runJob();
const served = first.lines.filter((l) => l.message === "refresh-follow-up" && UUID.test(String(l.tenant_id))).map((l) => l.tenant_id).sort();
expect("the job exits 0 and writes one line per tenant", [first.code, JSON.stringify(served) === JSON.stringify(tenants)], [0, true], [1, true]);
expect("every line: the tenant's id, rows and duration_ms as numbers, refreshed",
  first.lines.every((l) => UUID.test(String(l.tenant_id)) && Number.isInteger(l.rows) && Number.isInteger(l.duration_ms) && l.refreshed === true), true, false);
expect("no @ and no unparsed line in the job's output", [first.out.includes("@"), first.lines.some((l) => l.unparsed)], [false, false], [true, false]);
const fresh = sql(`select count(*) from cma.follow_up_snapshot s where s.computed_at > now() - interval '2 minutes'
                   and s.tenant_id in (${tenants.map((t) => `'${t}'`).join(",")})`)[0];
expect("every tenant's snapshot was computed just now", Number(fresh), tenants.length, 0);
const runRows = new Map(sql(`select distinct on (r.tenant_id) r.tenant_id || ' ' || r.status || ' ' || coalesce(r.counts ->> 'rows', '-')
                             from cma.sync_run r where r.job = 'refresh_follow_up' and r.started_at > now() - interval '2 minutes'
                             order by r.tenant_id, r.started_at desc`).map((l) => { const [t, ...rest] = l.split(" "); return [t, rest.join(" ")]; }));
expect("every tenant has a succeeded run row whose rows match its line",
  first.lines.every((l) => runRows.get(l.tenant_id) === `succeeded ${l.rows}`), true, false);

// 2. A second session holds the dev tenant's refresh lock (as a refresh that overran its minute would): the job skips
//    that tenant and serves the others
const HOLDER = "cma-verify-follow-up-lock";
const holder = spawn("psql", [PGCONN, "-At", "-v", "ON_ERROR_STOP=1", "-c", "set role cma_owner", "-c",
  `begin; select pg_advisory_xact_lock(cma.follow_up_lock_key('${devTenant}')); select pg_sleep(60); rollback;`],
  { stdio: "ignore", env: { ...process.env, PGAPPNAME: HOLDER } });
let held = false;
for (let i = 0; i < 50 && !held; i++) {
  held = sql(`select exists (select 1 from pg_locks l where l.locktype = 'advisory' and l.granted and l.pid <> pg_backend_pid()
              and l.objsubid = 1 and ((l.classid::bigint << 32) | l.objid::bigint) = cma.follow_up_lock_key('${devTenant}'))`)[0] === "t";
  if (!held) await new Promise((ok) => setTimeout(ok, 200));
}
const second = runJob();
// Ending the psql client leaves its server session asleep with the lock: end that session (your own login's, so under
// that login rather than cma_owner, and no superuser needed)
execFileSync("psql", [PGCONN, "-At", "-v", "ON_ERROR_STOP=1", "-c",
  `select count(pg_terminate_backend(pid)) from pg_stat_activity where application_name = '${HOLDER}' and pid <> pg_backend_pid()`], { encoding: "utf8" });
holder.kill();
const devLine = second.lines.find((l) => l.tenant_id === devTenant);
expect("the second session holds the dev tenant's lock", held, true, false);
expect("the job skips the locked tenant (WARNING, running) and exits 0",
  [second.code, devLine?.refreshed, devLine?.reason, devLine?.severity], [0, false, "running", "WARNING"], [0, true, null, "INFO"]);
expect("the job refreshes the other tenants meanwhile",
  second.lines.filter((l) => l.tenant_id !== devTenant).every((l) => l.refreshed === true), true, false);
const skippedRow = sql(`select r.status || ' ' || (r.counts ->> 'skipped') from cma.sync_run r where r.job = 'refresh_follow_up' and r.tenant_id = '${devTenant}'
                        order by r.started_at desc limit 1`)[0];
expect("the locked tenant's run row: succeeded, skipped", skippedRow, "succeeded 1", "succeeded 0");

// 3. The lock gone (the second session ended), the next run refreshes the tenant again
for (let i = 0; i < 50 && sql(`select count(*) from pg_stat_activity where application_name = '${HOLDER}' and pid <> pg_backend_pid()`)[0] !== "0"; i++) {
  await new Promise((ok) => setTimeout(ok, 200));
}
const third = runJob();
expect("once the lock is gone, the tenant is refreshed again", third.lines.find((l) => l.tenant_id === devTenant)?.refreshed ?? null, true, false);

const passed = results.filter(Boolean).length;
const n = results.length;
if (PROVOKE) {
  const ok = passed === 0;
  console.log(`\n${ok ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
  process.exit(ok ? 0 : 1);
}
console.log(`\n${passed === n ? `ALL ${n} PASS` : `${n - passed} of ${n} FAILED`}`);
process.exit(passed === n ? 0 : 1);
