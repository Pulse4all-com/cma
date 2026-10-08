/**
 * Verifier: the scheduler's job (jobs/close-forgotten-workdays.mjs, migration 0005a) end to end,
 * against a database with the dev seeds and a cma-web in mock auth mode on it.
 *
 *   PGCONN="host=127.0.0.1 port=5433 dbname=cma user=<you> …" BASE=http://localhost:8080 \
 *   CMA_DB_HOST=… CMA_DB_PORT=… CMA_DB_USER=… CMA_DB_PASSWORD=… node verify/scheduler.mjs            every check must PASS
 *   … node verify/scheduler.mjs --provoke                                                           every check must FAIL
 *
 * PGCONN is a psql connection string under your own login (the Auth Proxy in Cloud Shell, the local
 * cluster in the night): it writes a forgotten day for the test agent as the owner, on the first free
 * date more than 400 days back (the convention of verify/api.mjs; dev data, one day per run). The job
 * runs with the CMA_DB_* variables it would get on Cloud Run (or the local path). Proves: a forgotten
 * day is ended at its business day's end by a system event and stays flagged, today's open day is
 * untouched, a second run closes nothing, the log names no person.
 */
import { execFileSync, spawnSync } from "node:child_process";

const BASE = process.env.BASE ?? "http://localhost:8080";
const PROVOKE = process.argv.includes("--provoke");
const PGCONN = process.env.PGCONN;
if (!PGCONN) {
  console.error("PGCONN (a psql connection string) is required");
  process.exit(2);
}
const AGENT = "agent-two";
const SUPERVISOR = "supervisor";

const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  const shown = (v) => String(typeof v === "string" ? v : JSON.stringify(v)).slice(0, 60);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(52)} got ${shown(actual)}${pass ? "" : `, wanted ${shown(want)}`}`);
}
async function call(subject, path, init = {}) {
  const res = await fetch(BASE + path, { ...init, headers: { "x-cma-mock-subject": subject, ...(init.headers ?? {}) } });
  const text = await res.text();
  let body = null;
  try { body = JSON.parse(text); } catch { body = text; }
  return { status: res.status, body };
}
const get = (s, p) => call(s, p);
const sql = (text) => execFileSync("psql", [PGCONN, "-At", "-v", "ON_ERROR_STOP=1", "-c", "set role cma_owner", "-c", text], { encoding: "utf8" }).trim().split("\n").filter((l) => l !== "SET").pop() ?? "";
const daysAgo = (n) => new Date(Date.now() - n * 86_400_000).toISOString().slice(0, 10);

console.log(`verify/scheduler.mjs against ${BASE}${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);
const health = await get(AGENT, "/api/health");
if (health.status !== 200 || health.body?.auth !== "mock" || health.body?.data !== "api") {
  console.error(`Not a mock-auth, api-data cma-web at ${BASE}`);
  process.exit(2);
}
const meA = (await get(AGENT, "/api/v1/me")).body.data;

// A forgotten day: open, started 09:00 in the agent's zone on the first free date more than 400 days back
let freeDate = null;
for (let k = 0; k < 10 && !freeDate; k++) {
  const newest = 400 + k * 92;
  const taken = new Set(((await get(SUPERVISOR, `/api/v1/team/hours?from=${daysAgo(newest + 91)}&to=${daysAgo(newest)}&userId=${meA.userId}`)).body?.data?.days ?? []).map((d) => d.date));
  for (let i = 0; i < 92 && !freeDate; i++) if (!taken.has(daysAgo(newest + i))) freeDate = daysAgo(newest + i);
}
const forgotten = sql(`
  do $$
  declare v_tenant uuid := '${meA.tenantId}'; v_user uuid := '${meA.userId}'; v_zone text; v_day uuid; v_status uuid;
  begin
    perform set_config('app.tenant_id', v_tenant::text, true);
    perform set_config('app.user_id', v_user::text, true);
    perform set_config('app.actor_label', 'verify/scheduler.mjs', true);
    v_zone := cma.user_timezone(v_user);
    select id into v_status from cma.work_status where tenant_id = v_tenant and is_default;
    insert into cma.workday (tenant_id, user_id, business_date, timezone, started_at)
    values (v_tenant, v_user, '${freeDate}'::date, v_zone, ('${freeDate} 09:00'::timestamp) at time zone v_zone) returning id into v_day;
    insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source)
    values (v_tenant, v_day, v_user, 'start', v_status, ('${freeDate} 09:00'::timestamp) at time zone v_zone, 'user');
  end $$;
  select status || ' ' || coalesce(ended_at::text, 'open') from cma.workday where user_id = '${meA.userId}' and business_date = '${freeDate}';`);
expect("the forgotten day was written open as the owner", forgotten.startsWith("open"), true, false);

// Today's day is open and must stay so
await call(AGENT, "/api/v1/me/day/start", { method: "POST", headers: { "x-cma-request": "1" } });
const todayBefore = (await get(AGENT, "/api/v1/me/day")).body?.data;
expect("today's day is open before the job", todayBefore?.status, "working", "ended");

// The job, as it runs on Cloud Run
function runJob() {
  const r = spawnSync(process.execPath, ["jobs/close-forgotten-workdays.mjs"], { encoding: "utf8", env: process.env });
  return { code: r.status, out: (r.stdout + r.stderr).trim() };
}
const first = runJob();
expect("the job exits 0 and serves every tenant", [first.code, /\d+ tenant\(s\)/.test(first.out)], [0, true], [1, true]);
expect("the job closed exactly one day, the forgotten one", (first.out.match(/closed (\d+) day/g) ?? []).map((m) => m.replace(/\D/g, "")).sort().join(","), "0,1", "0,0");
expect("the job's log names the date and no person", [first.out.includes(freeDate), first.out.includes(meA.displayName), first.out.includes(meA.userId)], [true, false, false], [true, true, false]);

const day = (await get(SUPERVISOR, `/api/v1/team/days/${meA.userId}/${freeDate}`)).body?.data;
const endEvent = (day?.events ?? []).find((e) => e.kind === "end" && e.isEffective);
const dayEnd = sql(`select cma.business_day_end('${freeDate}'::date, '${day?.day?.timeZone ?? "UTC"}') at time zone 'UTC'`).replace(" ", "T") + "Z";
expect("the forgotten day is ended at its business day's end", [day?.day?.status, day?.day?.endedAt ? new Date(day.day.endedAt).toISOString() : null], ["ended", new Date(dayEnd).toISOString()], ["open", null]);
expect("the end is a system event", endEvent?.source ?? null, "system", "user");
expect("the day stays flagged for a manager", [day?.day?.needsCorrection, day?.day?.isCapped], [true, false], [false, false]);
expect("today's open day is untouched", (await get(AGENT, "/api/v1/me/day")).body?.data?.status, "working", "ended");

const second = runJob();
expect("a second run closes nothing", [second.code, (second.out.match(/closed (\d+) day/g) ?? []).map((m) => m.replace(/\D/g, "")).join(",")], [0, "0,0"], [0, "0,1"]);

// Leave the day as the scheduler left it (dev data: an ended, flagged day on a date 400 days back; not a check)

const passed = results.filter(Boolean).length;
const n = results.length;
if (PROVOKE) {
  const ok = passed === 0;
  console.log(`\n${ok ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
  process.exit(ok ? 0 : 1);
}
console.log(`\n${passed === n ? `ALL ${n} PASS` : `${n - passed} of ${n} FAILED`}`);
process.exit(passed === n ? 0 : 1);
