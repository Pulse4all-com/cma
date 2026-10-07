/**
 * Verifier: the API against the dev database (verify-by-breaking).
 *
 * Runs against a cma-web in mock auth mode with CMA_DATA_MODE=api, through the tunnel:
 *   gcloud run services proxy cma-web --project=p4a-cma-dev --region=europe-west4 --port=8080 &
 *   node verify/api.mjs              every check must PASS
 *   node verify/api.mjs --provoke    every check gets a deliberately wrong expectation and must FAIL
 * Env: BASE (default http://localhost:8080).
 *
 * Needs the dev seed (06) and migrations 0003, 0003a and 0003b. Ends the test supervisor's workday of today and, as
 * the supervisor, closes Agent Two's open past days (the verifier's own earlier logins) through the
 * corrections route, so no fixture runs first. Adds one day per run for Agent Two on the first free
 * date more than 400 days back (dev data). Safe to rerun on the same day.
 *
 * Themes: identity and tenant, own data only, corrections (team routes), an ended day stays ended,
 * status changes from the tenant's own list, the two export files in the tenant's format.
 */
const BASE = process.env.BASE ?? "http://localhost:8080";
const PROVOKE = process.argv.includes("--provoke");

// Dev seed subjects (system "mock")
const TWO_TENANTS = "agent-one";   // exists in two tenants: must never be guessed
const AGENT = "agent-two";
const SUPERVISOR = "supervisor";
const MANAGER = "manager";         // holds workday.export from the default ladder (0003b)
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

// ---- corrections (cma.correct_workday), 12 checks ------------------------------------------
// The supervisor holds workday.team and is the approver of their own corrections (V1). No key or
// name is assumed: the start status is the tenant's default.
const statusList = (await get(AGENT, "/api/v1/me/statuses")).body?.data ?? [];
const defaultStatus = statusList.find((s) => s.isDefault);
const worked = (minutes) => (defaultStatus?.isWorking ? minutes : 0);
const daysAgo = (n) => dateKey(new Date(Date.now() - n * 86_400_000), meA.timeZone);
const teamHours = async (s, f, t, userId) =>
  (await get(s, `/api/v1/team/hours?from=${f}&to=${t}${userId ? `&userId=${userId}` : ""}`));
const correct = (s, userId, date, body, headers = { "x-cma-request": "1" }) =>
  call(s, `/api/v1/team/days/${userId}/${date}/corrections`, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
const anEnd = { reason: "Verifier check (dev)", changes: [{ kind: "end", at: new Date().toISOString() }] };

expect("an agent cannot read team hours", (await teamHours(AGENT, from, today)).status, 403, 200);

// ---- team people (cma.team_people), 2 checks: who Add day and the person filter can offer ------
expect("an agent cannot list the team", (await get(AGENT, "/api/v1/team/people")).status, 403, 200);
const people = await get(SUPERVISOR, "/api/v1/team/people");
expect("the supervisor lists the people, agent included",
  [people.status, (people.body?.data ?? []).some((p) => p.userId === meA.userId && !!p.timeZone)],
  [200, true], [200, false]);

// The verifier's logins of earlier days are forgotten clock-outs by now. It closes them itself, one
// minute after their start: dev data whose length does not matter.
const leftovers = ((await teamHours(SUPERVISOR, daysAgo(91), today, meA.userId)).body?.data?.days ?? [])
  .filter((d) => d.status === "open" && d.date < today);
let notClosed = 0;
for (const d of leftovers) {
  const r = await correct(SUPERVISOR, meA.userId, d.date, {
    reason: "Verifier: closes its own login of that day (dev)",
    changes: [{ kind: "end", at: new Date(Date.parse(d.startedAt) + 60_000).toISOString() }],
  });
  if (!(r.status === 200 && r.body?.data?.day?.status === "ended" && r.body?.data?.day?.hasCorrection)) notClosed++;
}
if (leftovers.length) console.log(`      (closed ${leftovers.length} leftover day(s): ${leftovers.map((d) => d.date).join(", ")})`);
expect("the supervisor closes open past days", notClosed, 0, 1);

expect("a correction needs the request header", (await correct(SUPERVISOR, meA.userId, today, anEnd, {})).status, 400, 200);
expect("cross-site correction is refused",
  (await correct(SUPERVISOR, meA.userId, today, anEnd, { "x-cma-request": "1", "sec-fetch-site": "cross-site" })).status, 403, 200);
expect("a correction needs a reason",
  (await correct(SUPERVISOR, meA.userId, today, { ...anEnd, reason: " " })).status, 400, 200);
expect("nobody corrects their own day", (await correct(SUPERVISOR, meS.userId, today, anEnd)).status, 403, 200);
expect("an agent cannot correct", (await correct(AGENT, meS.userId, today, anEnd)).status, 403, 200);
expect("an unknown person is a 404",
  (await correct(SUPERVISOR, "00000000-0000-7000-8000-00000000dead", daysAgo(1), {
    reason: "Verifier check (dev)", changes: [{ kind: "start", statusKey: defaultStatus?.key, at: new Date().toISOString() }],
  })).status, 404, 200);
expect("a future date is refused",
  (await correct(SUPERVISOR, meA.userId, daysAgo(-1), {
    reason: "Verifier check (dev)", changes: [{ kind: "start", statusKey: defaultStatus?.key, at: new Date().toISOString() }],
  })).status, 400, 200);

// Add day on the first free date more than 400 days back. Times in UTC with Z: 08:00 to 12:00 UTC
// lies inside that business day for every zone from UTC-7 to UTC+11.
let freeDate = null;
for (let k = 0; k < 10 && !freeDate; k++) {
  const newest = 400 + k * 92;
  const taken = new Set(((await teamHours(SUPERVISOR, daysAgo(newest + 91), daysAgo(newest), meA.userId)).body?.data?.days ?? [])
    .map((d) => d.date));
  for (let i = 0; i < 92 && !freeDate; i++) if (!taken.has(daysAgo(newest + i))) freeDate = daysAgo(newest + i);
}
const added = await correct(SUPERVISOR, meA.userId, freeDate, {
  reason: "Verifier: forgot to clock in (dev)",
  changes: [
    { kind: "start", statusKey: defaultStatus?.key, at: `${freeDate}T08:00:00Z` },
    { kind: "end", at: `${freeDate}T12:00:00Z` },
  ],
});
const addedDay = added.body?.data?.day;
expect("add day creates the missing day",
  [added.status, addedDay?.status, addedDay?.hasCorrection, addedDay?.minutes],
  [200, "ended", true, worked(240)],
  [404, null, false, 241]);

expect("an event before the start is refused",
  (await correct(SUPERVISOR, meA.userId, freeDate, {
    reason: "Verifier check (dev)", changes: [{ kind: "status", statusKey: defaultStatus?.key, at: `${freeDate}T07:00:00Z` }],
  })).status, 400, 200);

const oldEnd = (added.body?.data?.events ?? []).find((e) => e.kind === "end" && e.isEffective);
const moved = await correct(SUPERVISOR, meA.userId, freeDate, {
  reason: "Verifier: end time confirmed later (dev)",
  changes: [{ kind: "end", at: `${freeDate}T13:00:00Z`, supersedes: oldEnd?.id }],
});
const movedEvents = moved.body?.data?.events ?? [];
expect("a replaced event stays visible",
  [movedEvents.some((e) => e.id === oldEnd?.id && !e.isEffective),
   movedEvents.filter((e) => e.kind === "end" && e.isEffective).length,
   moved.body?.data?.day?.minutes],
  [true, 1, worked(300)],
  [false, 2, 241]);

// ---- no past day open ----------------------------------------------------------------------
// After the closing above, no past day may be open, and every past day must count its exact
// minutes from start to end, not a capped day.
const hoursAfter = (await get(AGENT, `/api/v1/me/hours?${range}`)).body.data;
const past = hoursAfter.days.filter((d) => d.date < today);
const openPast = past.filter((d) => !d.endedAt).map((d) => d.date);
const allExact = past.every((d) => d.endedAt && d.minutes === Math.floor((Date.parse(d.endedAt) - Date.parse(d.startedAt)) / 60000));
if (openPast.length) console.log(`      (open past days ${openPast.join(", ")})`);
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

// ---- exports (migration 0003b), 8 checks ------------------------------------------------------
// The files follow the tenant's own settings: the verifier reads them and assumes no format.
// Downloads never clock anyone in, so the manager is not logged in.
async function download(subject, path) {
  const res = await fetch(BASE + path, { headers: { "x-cma-mock-subject": subject }, redirect: "manual" });
  const bytes = new Uint8Array(await res.arrayBuffer());
  const text = new TextDecoder("utf-8", { ignoreBOM: true }).decode(bytes);
  return { status: res.status, headers: res.headers, bom: bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf, text };
}
const settingsRes = await get(AGENT, "/api/v1/settings");
const setting = (k) => (settingsRes.body?.data ?? []).find((x) => x.key === k)?.value;
expect("any person reads the tenant's export settings",
  [settingsRes.status, (settingsRes.body?.data ?? []).filter((x) => x.key.startsWith("export.csv.")).length],
  [200, 5], [200, 4]);
const SEP = { comma: ",", semicolon: ";", tab: "\t" }[setting("export.csv.separator")] ?? ",";
const exportRange = `from=${from}&to=${today}&userId=${meA.userId}`;

expect("an agent cannot download hours",
  (await download(AGENT, `/api/v1/team/exports/hours?${exportRange}`)).status, 403, 200);
expect("workday.team alone cannot download status changes",
  (await download(SUPERVISOR, `/api/v1/team/exports/status-changes?${exportRange}`)).status, 403, 200);

const hoursFile = await download(MANAGER, `/api/v1/team/exports/hours?${exportRange}`);
expect("the manager's hours file is a private download",
  [hoursFile.status, hoursFile.headers.get("content-type")?.startsWith("text/csv"), hoursFile.headers.get("cache-control"),
   hoursFile.headers.get("content-disposition")?.startsWith("attachment")],
  [200, true, "no-store", true], [200, true, "public", true]);

const hoursLines = hoursFile.text.replace(/^\uFEFF/, "").split("\r\n").filter(Boolean);
expect("the file follows the tenant's format",
  [hoursFile.bom, hoursLines[0]?.split(SEP).length],
  [setting("export.csv.utf8_bom") === "true", 11], [setting("export.csv.utf8_bom") !== "true", 11]);

const teamDays = (await teamHours(SUPERVISOR, from, today, meA.userId)).body?.data?.days ?? [];
expect("one hours row per day, as Team hours",
  [hoursLines.length - 1, teamDays.length > 0], [teamDays.length, true], [teamDays.length + 1, true]);

const statusFile = await download(MANAGER, `/api/v1/team/exports/status-changes?${exportRange}`);
const statusLines = statusFile.text.replace(/^\uFEFF/, "").split("\r\n").filter(Boolean);
expect("every day has at least one status stretch",
  [statusFile.status, statusLines[0]?.split(SEP).length, statusLines.length - 1 >= teamDays.length],
  [200, 13, true], [200, 13, false]);

const longStart = dateKey(new Date(Date.now() - 92 * 86_400_000), meA.timeZone);
expect("an export is bounded to 92 days",
  (await download(MANAGER, `/api/v1/team/exports/hours?from=${longStart}&to=${today}`)).status, 400, 200);

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
