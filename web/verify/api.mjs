/**
 * Verifier: the API against the dev database (verify-by-breaking).
 *
 * Runs against a cma-web in mock auth mode with CMA_DATA_MODE=api, through the tunnel:
 *   gcloud run services proxy cma-web --project=p4a-cma-dev --region=europe-west4 --port=8080 &
 *   node verify/api.mjs              every check must PASS
 *   node verify/api.mjs --provoke    every check gets a deliberately wrong expectation and must FAIL
 * Env: BASE (default http://localhost:8080).
 *
 * Needs the dev seed (06) and the fixture db/08_fixture_api_verify_dev.sql. Ends the test
 * supervisor's workday of today (dev data); safe to rerun on the same day.
 *
 * Themes: identity and tenant, own data only, a correction row, an ended day stays ended,
 * status changes from the tenant's own list.
 */
const BASE = process.env.BASE ?? "http://localhost:8080";
const PROVOKE = process.argv.includes("--provoke");

// Dev seed subjects (system "mock")
const TWO_TENANTS = "agent-one";   // exists in two tenants: must never be guessed
const AGENT = "agent-two";
const SUPERVISOR = "supervisor";
const NOBODY = "verify-nobody";
const SPOOF_TENANT = "00000000-0000-7000-8000-00000000beef";

async function call(subject, path, init = {}) {
  const res = await fetch(BASE + path, {
    ...init,
    redirect: init.redirect ?? "manual",
    headers: { "x-cma-mock-subject": subject, ...(init.headers ?? {}) },
  });
  const text = await res.text();
  let body = null;
  try { body = JSON.parse(text); } catch { body = text; }
  return { status: res.status, body };
}
const get = (s, p) => call(s, p);
const post = (s, p, headers = {}) => call(s, p, { method: "POST", headers });
const end = (s, headers = { "x-cma-request": "1" }) => post(s, "/api/v1/me/day/end", headers);
/** Opening the app is the login, and the login is clock-in */
const login = (s) => call(s, "/", { redirect: "follow" });

function dateKey(d, tz) {
  return new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(d);
}
function localHHMM(iso, tz) {
  return new Intl.DateTimeFormat("en-GB", { timeZone: tz, hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).format(new Date(iso));
}

const results = [];
/** expect(name, actual, expected, provoked): in --provoke the provoked expectation is used and must fail */
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  const shown = (v) => String(typeof v === "string" ? v : JSON.stringify(v)).slice(0, 60);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(44)} got ${shown(actual)}${pass ? "" : `, wanted ${shown(want)}`}`);
}

console.log(`verify/api.mjs against ${BASE}${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

const health = await get(AGENT, "/api/health");
if (health.status !== 200 || health.body?.auth !== "mock" || health.body?.data !== "api") {
  console.error(`Not a mock-auth, api-data cma-web at ${BASE}: ${JSON.stringify(health.body)}`);
  process.exit(2);
}

// ---- identity and tenant -------------------------------------------------------------------
expect("identity in two tenants is refused", (await get(TWO_TENANTS, "/api/v1/me")).status, 403, 200);
expect("unknown identity is refused", (await get(NOBODY, "/api/v1/me")).status, 403, 200);

const meA = (await get(AGENT, "/api/v1/me")).body.data;
const meS = (await get(SUPERVISOR, "/api/v1/me")).body.data;
const spoofed = await call(AGENT, `/api/v1/me?tenantId=${SPOOF_TENANT}`, { headers: { "x-cma-tenant-id": SPOOF_TENANT } });
expect("tenant comes from the identity only", spoofed.body?.data?.tenantId, meA.tenantId, SPOOF_TENANT);

// ---- own data only -------------------------------------------------------------------------
await login(AGENT);
await login(SUPERVISOR);
const dayA = (await get(AGENT, "/api/v1/me/day")).body.data;
const dayS = (await get(SUPERVISOR, "/api/v1/me/day")).body.data;
expect("two users have two different days", dayA.startedAt === dayS.startedAt, false, true);

const today = dateKey(new Date(), meA.timeZone);
const from = dateKey(new Date(Date.now() - 13 * 86_400_000), meA.timeZone);
const range = `from=${from}&to=${today}`;
const hoursA = (await get(AGENT, `/api/v1/me/hours?${range}`)).body.data;
const hoursS = (await get(SUPERVISOR, `/api/v1/me/hours?${range}`)).body.data;
const todayIn = (h, d) => h.days.find((x) => x.date === d)?.startedAt ?? null;
expect("hours show the caller's own day",
  [todayIn(hoursA, dayA.date), todayIn(hoursS, dayS.date)],
  [dayA.startedAt, dayS.startedAt],
  [dayS.startedAt, dayA.startedAt]);

const redirected = (await get(SUPERVISOR, `/api/v1/me/hours?${range}&userId=${meA.userId}&user=${AGENT}`)).body.data;
expect("a user parameter cannot redirect hours", redirected, hoursS, hoursA);

// ---- a correction row ----------------------------------------------------------------------
// The seed leaves Agent Two a forgotten clock-out (open, capped at the end of its day); the fixture
// closes it with a supervisor correction. Afterwards no past day may be open, and every past day
// must count its exact minutes from start to end, not a capped day.
const past = hoursA.days.filter((d) => d.date < today);
const openPast = past.filter((d) => !d.endedAt).map((d) => d.date);
const allExact = past.every((d) => d.endedAt && d.minutes === Math.floor((Date.parse(d.endedAt) - Date.parse(d.startedAt)) / 60000));
if (openPast.length) console.log(`      (open past days ${openPast.join(", ")}: run db/08_fixture_api_verify_dev.sql in Cloud SQL Studio on dev)`);
expect("correction leaves no past day open or capped", [openPast.length, allExact, past.length > 0], [0, true, true], [1, false, true]);

// ---- an ended day stays ended --------------------------------------------------------------
expect("end needs the request header", (await end(SUPERVISOR, {})).status, 400, 200);
expect("cross-site end is refused",
  (await end(SUPERVISOR, { "x-cma-request": "1", "sec-fetch-site": "cross-site" })).status, 403, 200);

const ended = await end(SUPERVISOR);
const E = ended.body?.data?.endedAt ?? null;
expect("end ends the own day", ended.body?.data?.status, "ended", "working");

await login(SUPERVISOR);
const afterLogin = (await get(SUPERVISOR, "/api/v1/me/day")).body.data;
expect("login after end does not reopen", [afterLogin.status, afterLogin.endedAt], ["ended", E], ["working", null]);

const again = await end(SUPERVISOR);
expect("a second end changes nothing", again.body?.data?.endedAt === E, true, false);

const logout = await post(SUPERVISOR, "/logout/end", { "sec-fetch-site": "same-origin" });
const afterLogout = (await get(SUPERVISOR, "/api/v1/me/day")).body.data;
expect("log out on an ended day changes nothing", [logout.status, afterLogout.endedAt === E], [303, true], [303, false]);

expect("the other user's day is untouched", (await get(AGENT, "/api/v1/me/day")).body.data.status, "working", "ended");

// ---- bounds ---------------------------------------------------------------------------------
const longFrom = dateKey(new Date(Date.now() - 92 * 86_400_000), meA.timeZone);
expect("hours range is bounded to 92 days", (await get(AGENT, `/api/v1/me/hours?from=${longFrom}&to=${today}`)).status, 400, 200);

// ---- verdict --------------------------------------------------------------------------------

// ---- work status (cma.set_status), 7 checks ------------------------------------------------------------
// Agent Two's day today is open (only the supervisor's day was ended above). No key or name is
// assumed: the verifier picks from the tenant's own list.
const setStatus = (s, body, headers = { "x-cma-request": "1" }) =>
  call(s, "/api/v1/me/status", {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
  });

const statuses = (await get(AGENT, "/api/v1/me/statuses")).body?.data ?? [];
expect("status list has exactly one default", statuses.filter((s) => s.isDefault).length, 1, 0);

const before = (await get(AGENT, "/api/v1/me/day")).body?.data;
const target = statuses.find((s) => s.key !== before?.statusKey);
expect("status change needs the request header",
  (await setStatus(AGENT, { key: target?.key }, {})).status, 400, 200);
expect("cross-site status change is refused",
  (await setStatus(AGENT, { key: target?.key }, { "x-cma-request": "1", "sec-fetch-site": "cross-site" })).status, 403, 200);

await setStatus(AGENT, { key: target?.key });
const after = (await get(AGENT, "/api/v1/me/day")).body?.data;
expect("status change is stored on the own day",
  after?.statusKey ?? null, target?.key ?? "(no other status to switch to)", before?.statusKey ?? null);
expect("status since moves to the change",
  Date.parse(after?.statusSince ?? "") > Date.parse(before?.statusSince ?? before?.startedAt ?? ""), true, false);

expect("unknown status key is a 404",
  (await setStatus(AGENT, { key: "verify-no-such-status" })).status, 404, 200);

await end(SUPERVISOR);   // already ended above; ending again changes nothing
expect("an ended day refuses a status change",
  (await setStatus(SUPERVISOR, { key: target?.key })).status, 409, 200);

// Leave Agent Two in the status the run found (dev data; not a check)
if (before?.statusKey) await setStatus(AGENT, { key: before.statusKey });

const passed = results.filter(Boolean).length;
const n = results.length;
if (PROVOKE) {
  const ok = passed === 0;
  console.log(`\n${ok ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
  process.exit(ok ? 0 : 1);
} else {
  const ok = passed === n;
  console.log(`\n${ok ? `ALL ${n} PASS` : `${n - passed} of ${n} FAILED`}`);
  process.exit(ok ? 0 : 1);
}
