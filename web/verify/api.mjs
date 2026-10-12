/**
 * Verifier: the API against the dev database (verify-by-breaking).
 *
 * Runs against a cma-web in mock auth mode with CMA_DATA_MODE=api, through the tunnel:
 *   gcloud run services proxy cma-web --project=p4a-cma-dev --region=europe-west4 --port=8080 &
 *   node verify/api.mjs              every check must PASS
 *   node verify/api.mjs --provoke    every check gets a deliberately wrong expectation and must FAIL
 * Env: BASE (default http://localhost:8080).
 *
 * Needs the dev seeds (06, 24) and migrations 0003 to 0003e, 0004, 0005 and 0008b, and runs between
 * 07:00 and 22:00 Amsterdam time (the workday window of the seed since 0008b). Ends the test supervisor's workday of today and, as
 * the supervisor, closes Agent Two's open past days (the verifier's own earlier logins) through the
 * corrections route, so no fixture runs first. Adds one day per run for Agent Two on the first free
 * date more than 400 days back (dev data). Safe to rerun on the same day.
 *
 * Themes: identity and tenant, ?as= in mock mode (a relative 303 with the cookie), Clock in as an
 * action (a visit opens nothing, the database refuses someone whose time is not kept), own data only,
 * corrections (team routes), an ended day stays ended, status changes from the tenant's own list, the
 * two export files in the tenant's format, time per status for the Dashboard (the same minutes as Team
 * hours), app links per person, the team now for the Live board (a person's own entry equals the
 * own-day read), the Team screen (migration 0004: who is listed and editable, roles, teams, skills,
 * adding a person) and the memberships for the Live board's team filter, the configuration screens
 * (migration 0005a: statuses, app links, absence types, coverage targets, settings; the admin only,
 * everything undone at the end), the own profile for My account (addition 0005b), and messaging
 * (migration 0008: the own inbox, since and limit, read and acknowledge on own rows only, sending as
 * messages.send to one named person, the stats; one message per run, dev data), and since addition
 * 0008e (night of 13 October 2026) the Sources, Markets and Alert rules screens and linked accounts on
 * People (every write undone at the end; one switched-off rule "API verifier rule" stays, dev data).
 */
const BASE = process.env.BASE ?? "http://localhost:8080";
const PROVOKE = process.argv.includes("--provoke");
/**
 * --reports runs only the intake reports' checks (B11, 12 October 2026). They read and write nothing a
 * fixture depends on, so they also run against a cma-web in mock data mode: the mock fixture has a
 * tenant with telephony and a shop and one without (invest-analyst).
 */
const ONLY_REPORTS = process.argv.includes("--reports");
/**
 * --sources runs only the checks of the Sources, Markets and Alert rules screens and of linked accounts on
 * People (addition 0008e, night of 13 October 2026). Every write is undone at the end, so they run against
 * dev, a local database or a cma-web in mock data mode alike.
 */
const ONLY_SOURCES = process.argv.includes("--sources");

// Dev seed subjects (system "mock")
const TWO_TENANTS = "agent-one";   // exists in two tenants: must never be guessed
const AGENT = "agent-two";
const SUPERVISOR = "supervisor";
const MANAGER = "manager";         // holds workday.export from the default ladder (0003b)
const ANALYST = "analyst";         // analytics: no workday.own, so the database keeps no time for them (0003d)
const ADMIN = "admin";             // admin (0004): users.manage_all and tenant.configure
const INVEST = "invest-analyst";   // B11: an analyst in a tenant without telephony or a shop (mock fixture, local fixture)
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
/** Clock in is an action (increment e): the start route, never a visit */
const start = (s, headers = { "x-cma-request": "1" }) => post(s, "/api/v1/me/day/start", headers);
const visit = (s, path) => call(s, path, { redirect: "follow" });
/**
 * Clock in a test user and answer the day. Outside the workday window (0008b) the clock-in is refused
 * with "the workday starts at HH:MI" (or the day comes back null): one FAIL line and exit 1, never a
 * crash on a missing day further on.
 */
async function clockIn(s, timeZone) {
  const r = await start(s);
  const startsAt = /^the workday starts at (\d\d:\d\d)$/.exec(r.body?.error?.message ?? "")?.[1] ?? null;
  const day = r.body?.data ?? null;
  if (!startsAt && day !== null) return day;
  const settings = (await get(s, "/api/v1/settings")).body?.data ?? [];
  const setting = (k) => String(settings.find((x) => x.key === k)?.value ?? "?").slice(0, 5);
  console.log(`FAIL  clock-in refused: outside the workday window (${startsAt ?? setting("workday.window_start")} to ${setting("workday.window_end")} ${timeZone}); run this verifier inside the window`);
  process.exit(1);
}

function dateKey(d, tz) {
  return new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(d);
}

/** The instant of a local time on a date in a zone, as ISO (away from a clock change, as every use here is) */
function localInstant(date, time, tz) {
  const guess = Date.parse(`${date}T${time}:00Z`);
  const name = new Intl.DateTimeFormat("en-US", { timeZone: tz, timeZoneName: "longOffset" })
    .formatToParts(new Date(guess)).find((p) => p.type === "timeZoneName")?.value ?? "GMT";
  const m = /GMT([+-])(\d{2}):(\d{2})/.exec(name);
  const offsetMin = m ? (m[1] === "-" ? -1 : 1) * (Number(m[2]) * 60 + Number(m[3])) : 0;
  return new Date(guess - offsetMin * 60_000).toISOString();
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
if (health.status !== 200 || health.body?.auth !== "mock" || !(health.body?.data === "api" || ((ONLY_REPORTS || ONLY_SOURCES) && health.body?.data === "mock"))) {
  console.error(`Not a mock-auth, ${ONLY_REPORTS || ONLY_SOURCES ? "api- or mock-data" : "api-data"} cma-web at ${BASE}: ${JSON.stringify(health.body)}`);
  process.exit(2);
}
if (ONLY_REPORTS) {
  await reportChecks();
  verdict();
}
if (ONLY_SOURCES) {
  await sourceChecks();
  verdict();
}

// ---- identity and tenant -------------------------------------------------------------------
expect("identity in two tenants is refused", (await get(TWO_TENANTS, "/api/v1/me")).status, 403, 200);
expect("unknown identity is refused", (await get(NOBODY, "/api/v1/me")).status, 403, 200);

const meA = (await get(AGENT, "/api/v1/me")).body.data;
const meS = (await get(SUPERVISOR, "/api/v1/me")).body.data;
const spoofed = await call(AGENT, `/api/v1/me?tenantId=${SPOOF_TENANT}`, { headers: { "x-cma-tenant-id": SPOOF_TENANT } });
expect("tenant comes from the identity only", spoofed.body?.data?.tenantId, meA.tenantId, SPOOF_TENANT);

// ---- ?as= in mock mode, 4 checks ----------------------------------------------------------------
// A browser picks its test identity with ?as=: a 303 to the same address without ?as=, relative
// (no host), with the cookie. No x-cma-mock-subject header here, so only ?as= and the cookie count.
const plain = (path, headers = {}) => fetch(BASE + path, { headers, redirect: "manual" });
const asParam = await plain(`/day?as=${SUPERVISOR}`);
expect("?as= is a 303 to the same path, relative",
  [asParam.status, asParam.headers.get("location"), (asParam.headers.get("set-cookie") ?? "").includes(`cma-mock-subject=${SUPERVISOR}`)],
  [303, "/day", true], [303, "http://localhost/day", true]);
const asKeeps = await plain(`/day?as=${SUPERVISOR}&date=2026-10-01`);
expect("?as= keeps the other parameters", [asKeeps.status, asKeeps.headers.get("location")],
  [303, "/day?date=2026-10-01"], [303, `/day?as=${SUPERVISOR}&date=2026-10-01`]);
const asBad = await plain("/day?as=Bad_Subject");
expect("an invalid ?as= is a 400", [asBad.status, asBad.headers.get("x-cma-auth")], [400, "bad-mock-subject"], [303, null]);
expect("the cookie from ?as= is honoured",
  (await plain("/day", { cookie: `cma-mock-subject=${SUPERVISOR}` })).status, 200, 303);

// ---- clock in is an action (increment e, addition 0003d), 7 checks ---------------------------
// The analyst holds performance.team and no workday.own: a visit to the landing page and to My day
// opens nothing, and the start route is refused by the database (CMA06), not by the route.
// Since addition 0008b a clock-in before the window start (07:00 for Pulse4all) is refused, so
// this verifier runs between 07:00 and 22:00 Amsterdam time (outside it, clockIn stops with one FAIL
// line); the refusal itself is proven by db/47_verify_workday_window.sql, because a clock-in
// before 07:00 cannot be forced here.
await visit(ANALYST, "/");
await visit(ANALYST, "/day");
expect("a visit opens no workday", (await get(ANALYST, "/api/v1/me/day")).body?.data ?? null, null, "a day");
expect("the database keeps no time for someone without a clock", (await start(ANALYST)).status, 403, 200);
expect("start needs the request header", (await start(AGENT, {})).status, 400, 200);
expect("cross-site start is refused",
  (await start(AGENT, { "x-cma-request": "1", "sec-fetch-site": "cross-site" })).status, 403, 200);
const today0 = dateKey(new Date(), meA.timeZone);
const started = await clockIn(AGENT, meA.timeZone);
const startedAgain = (await start(AGENT)).body?.data;
expect("start opens the own day today", [started?.date, started?.status === "working" || started?.status === "ended"],
  [dateKey(new Date(), meA.timeZone), true], [dateKey(new Date(), meA.timeZone), false]);
expect("a second start is the same day", startedAgain?.startedAt === started?.startedAt, true, false);
// The day's end (addition 0008b): the tenant's window end on the agent's date, 22:00 in Amsterdam
// for Pulse4all (Madrid keeps the same clock), so the clock on Welcome and My day stops there
const dayRead = (await get(AGENT, "/api/v1/me/day")).body?.data ?? null;
expect("the own day ends at the window end, 22:00",
  dayRead?.dayEndsAt ?? null, localInstant(dayRead?.date ?? today0, "22:00", "Europe/Amsterdam"),
  localInstant(dayRead?.date ?? today0, "23:00", "Europe/Amsterdam"));

// ---- own data only -------------------------------------------------------------------------
await clockIn(SUPERVISOR, meS.timeZone);
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
// minute after the day's last effective event (an earlier end is refused when the status checks
// changed the status that day): dev data whose length does not matter.
const leftovers = ((await teamHours(SUPERVISOR, daysAgo(91), today, meA.userId)).body?.data?.days ?? [])
  .filter((d) => d.status === "open" && d.date < today);
let notClosed = 0;
for (const d of leftovers) {
  const detail = (await get(SUPERVISOR, `/api/v1/team/days/${meA.userId}/${d.date}`)).body?.data;
  const last = Math.max(Date.parse(d.startedAt),
    ...(detail?.events ?? []).filter((e) => e.isEffective).map((e) => Date.parse(e.at)));
  const r = await correct(SUPERVISOR, meA.userId, d.date, {
    reason: "Verifier: closes its own login of that day (dev)",
    changes: [{ kind: "end", at: new Date(last + 60_000).toISOString() }],
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
// minutes from start to end, not a capped day. Since 0008b a day's counted time stops at the
// workday window end (workday.window_end in the zone, read as the window FAIL message does), so a
// past day that ended after it counts from start to the window end of its date. The database
// counts each stretch in whole seconds and sums them (cma.time_interval_all), so a day whose
// stretches are cut mid-second can count one minute less than floor(span / 60), as 2026-10-11 in
// dev did (575 against 576); that one minute is accepted and its dates are printed.
const hoursAfter = (await get(AGENT, `/api/v1/me/hours?${range}`)).body.data;
const past = hoursAfter.days.filter((d) => d.date < today);
const openPast = past.filter((d) => !d.endedAt).map((d) => d.date);
const windowSettings = (await get(AGENT, "/api/v1/settings")).body?.data ?? [];
const windowEnd = String(windowSettings.find((x) => x.key === "workday.window_end")?.value ?? "24:00").slice(0, 5);
const cappedPast = [];
const roundedPast = [];
const allExact = past.every((d) => {
  if (!d.endedAt) return false;
  const until = Math.min(Date.parse(d.endedAt), Date.parse(localInstant(d.date, windowEnd, meA.timeZone)));
  if (until < Date.parse(d.endedAt)) cappedPast.push(d.date);
  const expected = Math.floor((until - Date.parse(d.startedAt)) / 60000);
  if (d.minutes === expected - 1) roundedPast.push(d.date);
  return d.minutes >= expected - 1 && d.minutes <= expected;
});
if (openPast.length) console.log(`      (open past days ${openPast.join(", ")})`);
if (cappedPast.length) console.log(`      (counted to the window end ${windowEnd} ${meA.timeZone}: ${cappedPast.join(", ")})`);
if (roundedPast.length) console.log(`      (one minute less from per-stretch seconds: ${roundedPast.join(", ")})`);
expect("correction leaves no past day open or capped", [openPast.length, allExact, past.length > 0], [0, true, true], [1, false, true]);

// ---- an ended day stays ended --------------------------------------------------------------
expect("end needs the request header", (await end(SUPERVISOR, {})).status, 400, 200);
expect("cross-site end is refused",
  (await end(SUPERVISOR, { "x-cma-request": "1", "sec-fetch-site": "cross-site" })).status, 403, 200);

const ended = await end(SUPERVISOR);
const E = ended.body?.data?.endedAt ?? null;
expect("end ends the own day", ended.body?.data?.status, "ended", "working");

await visit(SUPERVISOR, "/");
const afterStart = (await start(SUPERVISOR)).body?.data;
expect("start on an ended day changes nothing", [afterStart?.status, afterStart?.endedAt], ["ended", E], ["working", null]);

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

// ---- time per status (addition 0003c), 6 checks ----------------------------------------------
// The Dashboard's read. Worked and paid minutes per past day must equal Team hours for the same
// person, because both come from the same stretches. Today is left out: its open stretch keeps
// running between two reads. Reading never clocks anyone in. No status key is assumed.
const statusTime = (s, q) => get(s, `/api/v1/team/status-time?${q}`);
expect("an agent cannot read time per status", (await statusTime(AGENT, exportRange)).status, 403, 200);

const stRes = await download(SUPERVISOR, `/api/v1/team/status-time?${exportRange}`);
let stRows = [];
try { stRows = JSON.parse(stRes.text).data?.rows ?? []; } catch { stRows = []; }
expect("the supervisor reads time per status, never cached",
  [stRes.status, stRes.headers.get("cache-control"), stRows.length > 0], [200, "no-store", true], [200, "public", true]);

const perDay = new Map();
for (const r of stRows) {
  const d = perDay.get(r.date) ?? { worked: 0, paid: 0 };
  if (r.isWorking) d.worked += r.seconds;
  if (r.isPaid) d.paid += r.seconds;
  perDay.set(r.date, d);
}
const pastTeamDays = teamDays.filter((d) => d.date < today);
const dayMismatches =
  pastTeamDays.filter((d) => {
    const x = perDay.get(d.date);
    return !x || Math.floor(x.worked / 60) !== d.minutes || Math.floor(x.paid / 60) !== d.paidMinutes;
  }).length +
  [...perDay.keys()].filter((date) => date < today && !pastTeamDays.some((d) => d.date === date)).length;
expect("worked and paid per past day equal Team hours", [dayMismatches, pastTeamDays.length > 0], [0, true], [1, true]);

expect("flags follow the tenant's own status list",
  stRows.every((r) => {
    const s = statusList.find((x) => x.key === r.statusKey);
    // A status retired since the stretch (statusActive false) is no longer in the active list the
    // agent sees; its history stays, with the flags as stored (seen 7 October 2026, when the
    // Subscriptions list replaced the universal 'available')
    return s ? s.isWorking === r.isWorking && s.isProductive === r.isProductive : r.statusActive === false;
  }), true, false);

const stAll = (await statusTime(SUPERVISOR, `from=${from}&to=${today}`)).body?.data?.rows ?? [];
expect("the person filter returns that person only",
  [new Set(stAll.map((r) => r.userId)).size > 1, stRows.every((r) => r.userId === meA.userId)], [true, true], [true, false]);

expect("time per status is bounded to 92 days",
  (await statusTime(SUPERVISOR, `from=${longStart}&to=${today}`)).status, 400, 200);

// ---- app links (addition 0003d), 2 checks -----------------------------------------------------
// The tenant's own list, filtered by the database on the person's permissions. No key or label is
// assumed: the dev seed carries one link that needs workday.team, so the supervisor sees more.
const linksA = (await get(AGENT, "/api/v1/me/app-links")).body?.data ?? [];
const linksS = (await get(SUPERVISOR, "/api/v1/me/app-links")).body?.data ?? [];
const linksN = await get(ANALYST, "/api/v1/me/app-links");
expect("a link that needs a permission is hidden from the agent",
  [linksA.length > 0, linksS.length > linksA.length, linksA.every((l) => linksS.some((x) => x.key === l.key))],
  [true, true, true], [true, false, true]);
expect("every link is https, for anyone with a role",
  [linksN.status, [...linksA, ...linksS, ...(linksN.body?.data ?? [])].every((l) => /^https:\/\//.test(l.address))],
  [200, true], [200, false]);

// ---- my profile (addition 0005b), 5 checks ---------------------------------------------------
// My account's read: the caller's own row only, whatever the request says, for anyone with access
const pA = (await get(AGENT, "/api/v1/me/profile")).body?.data ?? {};
const pS = (await get(SUPERVISOR, "/api/v1/me/profile")).body?.data ?? {};
const pN = await get(ANALYST, "/api/v1/me/profile");
expect("the profile is the caller's own row",
  [pA.userId === meA.userId, pS.userId === meS.userId, pA.userId !== pS.userId], [true, true, true], [true, true, false]);
expect("a query cannot pick another person's profile",
  (await get(AGENT, `/api/v1/me/profile?userId=${meS.userId}`)).body?.data?.userId, meA.userId, meS.userId);
expect("the profile names the person as /me does",
  [pA.displayName === meA.displayName, pA.organisationName === meA.organisationName, pA.timeZone === meA.timeZone],
  [true, true, true], [true, true, false]);
expect("the profile says whose time is kept",
  [pN.status, pN.body?.data?.timeKept, pA.timeKept, Array.isArray(pA.teams) && Array.isArray(pA.skills)],
  [200, false, true, true], [200, true, true, true]);
expect("an unknown identity gets no profile", (await get(NOBODY, "/api/v1/me/profile")).status, 403, 200);

// ---- team now (addition 0003e), 6 checks ---------------------------------------------------------
// The Live board's read. Agent Two's day is open (started above), the supervisor's too. A person's
// own entry must equal GET /api/v1/me/day field for field, because both come from the same
// stretches; the analyst reads but is not listed (no clock); nobody without monitoring.live reads.
const meN = (await get(ANALYST, "/api/v1/me")).body?.data ?? null;
const nowA = await get(AGENT, "/api/v1/team/now");
expect("an agent cannot read the team now", nowA.status, 403, 200);
const nowRes = await download(SUPERVISOR, "/api/v1/team/now");
let teamNow = { people: [], statusFlags: [] };
try { teamNow = JSON.parse(nowRes.text).data ?? teamNow; } catch { /* left empty */ }
expect("the supervisor reads the team now, never cached",
  [nowRes.status, nowRes.headers.get("cache-control"), teamNow.people.length > 0, teamNow.statusFlags.length > 0],
  [200, "no-store", true, true], [200, "public", true, true]);
const ownDay = (await get(AGENT, "/api/v1/me/day")).body?.data ?? null;
const agentEntry = teamNow.people.find((p) => p.userId === meA.userId) ?? null;
expect("the agent's own entry equals the own-day read", agentEntry?.day ?? null, ownDay, { ...ownDay, statusSince: null });
expect("the entry's status carries the day's status key with its flags",
  [agentEntry?.status?.key ?? null, typeof agentEntry?.status?.isWorking, typeof agentEntry?.status?.isPaid],
  [ownDay?.statusKey ?? null, "boolean", "boolean"], [ownDay?.statusKey ?? null, "boolean", "undefined"]);
expect("someone without a day today is listed as not clocked in",
  [teamNow.people.some((p) => p.day === null),
   teamNow.people.filter((p) => p.day === null).every((p) => p.status === null && !!p.timeZone && !!p.date)],
  [true, true], [true, false]);
const nowN = await get(ANALYST, "/api/v1/team/now");
expect("the analyst reads the board and is not on it",
  [nowN.status, (nowN.body?.data?.people ?? []).some((p) => p.userId === meN?.userId),
   (nowN.body?.data?.people ?? []).length === teamNow.people.length],
  [200, false, true], [200, true, true]);


// ---- the Team screen (migration 0004), 20 checks --------------------------------------------
// The manager holds users.manage_agents and skills.manage, the admin users.manage_all. No role,
// team or skill key is assumed: the checks read the tenant's own ladder and catalogs first.
const json = (s, method, path, body, headers = { "x-cma-request": "1" }) =>
  call(s, path, { method, headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });
const meM = (await get(MANAGER, "/api/v1/me")).body.data;
const meAdm = (await get(ADMIN, "/api/v1/me")).body.data;
const dirM = await get(MANAGER, "/api/v1/team/directory");
const dirAdm = await get(ADMIN, "/api/v1/team/directory");
const ids = (d) => (d.body?.data ?? []).map((p) => p.userId);
expect("an agent cannot read the directory", (await get(AGENT, "/api/v1/team/directory")).status, 403, 200);
expect("the manager lists the non-managing people and themselves, not the admin",
  [dirM.status, ids(dirM).includes(meA.userId), ids(dirM).includes(meM.userId), ids(dirM).includes(meAdm.userId)],
  [200, true, true, false], [200, true, true, true]);
expect("the admin lists everyone and may not edit themselves",
  [ids(dirAdm).includes(meM.userId), ids(dirAdm).includes(meAdm.userId),
   dirAdm.body?.data?.find((p) => p.userId === meAdm.userId)?.mayEdit, dirAdm.body?.data?.find((p) => p.userId === meM.userId)?.mayEdit],
  [true, true, false, true], [true, true, true, true]);
const teams = (await get(ADMIN, "/api/v1/team/teams")).body?.data ?? [];
const skills = (await get(ADMIN, "/api/v1/team/skills")).body?.data ?? [];
const rolesM = (await get(MANAGER, "/api/v1/team/roles")).body?.data ?? [];
const rolesAdm = (await get(ADMIN, "/api/v1/team/roles")).body?.data ?? [];
const agentDir = dirAdm.body?.data?.find((p) => p.userId === meA.userId);
expect("the directory's teams and skills come from the tenant's catalogs",
  [agentDir?.teams.length > 0, agentDir?.teams.every((t) => teams.some((x) => x.key === t.key)),
   agentDir?.skills.some((k) => k.level !== null && typeof k.levelName === "string"), agentDir?.skills.every((k) => skills.some((x) => x.key === k.key))],
  [true, true, true, true], [true, true, false, true]);
expect("the manager may assign non-managing roles only, the admin every role",
  [rolesM.some((r) => r.isManaging && r.assignable), rolesM.some((r) => !r.isManaging && r.assignable), rolesAdm.every((r) => r.assignable)],
  [false, true, true], [true, true, true]);
const orgs = await get(AGENT, "/api/v1/team/organisations");
expect("employers are listed with the zone a new person follows for any person of the tenant",
  [orgs.status, (orgs.body?.data ?? []).length > 0, (orgs.body?.data ?? []).every((o) => typeof o.timeZone === "string" && o.key && o.name)],
  [200, true, true], [403, true, true]);
const managingRole = rolesAdm.find((r) => r.isManaging && r.key !== meAdm.roleKey)?.key ?? rolesAdm.find((r) => r.isManaging)?.key;
const agentRole = agentDir?.roleKey;
expect("a role change needs the request header", (await json(ADMIN, "PUT", `/api/v1/team/directory/${meA.userId}/role`, { roleKey: agentRole }, {})).status, 400, 200);
expect("cross-site role change is refused",
  (await json(ADMIN, "PUT", `/api/v1/team/directory/${meA.userId}/role`, { roleKey: agentRole }, { "x-cma-request": "1", "sec-fetch-site": "cross-site" })).status, 403, 200);
expect("nobody changes their own role", (await json(ADMIN, "PUT", `/api/v1/team/directory/${meAdm.userId}/role`, { roleKey: agentRole })).status, 403, 200);
expect("the manager cannot assign a managing role", (await json(MANAGER, "PUT", `/api/v1/team/directory/${meA.userId}/role`, { roleKey: managingRole })).status, 403, 200);
expect("the manager cannot touch the admin", (await json(MANAGER, "PUT", `/api/v1/team/directory/${meAdm.userId}/active`, { active: false })).status, 403, 200);
expect("nobody deactivates themselves", (await json(ADMIN, "PUT", `/api/v1/team/directory/${meAdm.userId}/active`, { active: false })).status, 403, 200);
const originalTeams = agentDir?.teams.map((t) => t.key) ?? [];
const otherTeam = teams.find((t) => !originalTeams.includes(t.key))?.key ?? teams[0]?.key;
const changed = await json(ADMIN, "PUT", `/api/v1/team/directory/${meA.userId}/teams`, { teamKeys: [otherTeam] });
expect("the full team list replaces the memberships", changed.body?.data?.teams?.map((t) => t.key), [otherTeam], originalTeams);
const restored = await json(ADMIN, "PUT", `/api/v1/team/directory/${meA.userId}/teams`, { teamKeys: originalTeams });
expect("and restoring it gives the original list", (restored.body?.data?.teams?.map((t) => t.key) ?? []).sort(), [...originalTeams].sort(), [otherTeam]);
expect("an unknown team is a 404", (await json(ADMIN, "PUT", `/api/v1/team/directory/${meA.userId}/teams`, { teamKeys: ["verify-no-such-team"] })).status, 404, 200);
const scaled = skills.find((k) => k.levels.length > 0);
expect("a level outside the scale is refused",
  (await json(ADMIN, "PUT", `/api/v1/team/directory/${meA.userId}/skills`, { skills: [{ key: scaled?.key, level: 9 }] })).status, 400, 200);
expect("the supervisor cannot set skills", (await json(SUPERVISOR, "PUT", `/api/v1/team/directory/${meA.userId}/skills`, { skills: [] })).status, 403, 200);
// Add a person: rerun-safe for the same person and id; a different id for the same person is refused; a
// managing role needs users.manage_all. The fictional person stays in dev (inactive at the end).
const newPerson = { email: "verify-added@example.com", displayName: "Verify Added", organisationKey: orgs.body?.data?.[0]?.key,
  roleKey: agentRole, loginSystem: "mock", loginId: "verify-added-login" };
// An earlier run left this fictional person inactive: reactivate first, since add_person refuses an inactive person
const earlier = dirAdm.body?.data?.find((p) => p.email === newPerson.email);
if (earlier && !earlier.isActive) await json(ADMIN, "PUT", `/api/v1/team/directory/${earlier.userId}/active`, { active: true });
const add1 = await json(MANAGER, "POST", "/api/v1/team/directory", newPerson);
const add2 = await json(MANAGER, "POST", "/api/v1/team/directory", newPerson);
expect("adding the same person again answers the same id", [add1.status, add2.status, add1.body?.data?.userId === add2.body?.data?.userId], [201, 201, true], [201, 201, false]);
expect("a different login id for an existing person is refused", (await json(MANAGER, "POST", "/api/v1/team/directory", { ...newPerson, loginId: "verify-added-other" })).status, 409, 201);
expect("the manager cannot add a person with a managing role",
  (await json(MANAGER, "POST", "/api/v1/team/directory", { ...newPerson, email: "verify-added-manager@example.com", loginId: "verify-added-manager", roleKey: managingRole })).status, 403, 201);
const off = await json(ADMIN, "PUT", `/api/v1/team/directory/${add1.body?.data?.userId}/active`, { active: false });
expect("deactivating keeps the person listed as inactive", [off.status, off.body?.data?.isActive, off.body?.data?.timeKept], [200, false, false], [200, true, false]);
expect("an agent cannot read the memberships", (await get(AGENT, "/api/v1/team/memberships")).status, 403, 200);
const members = await get(SUPERVISOR, "/api/v1/team/memberships");
expect("the supervisor reads the memberships for the board's team filter",
  [members.status, (members.body?.data ?? []).some((m) => m.userId === meA.userId && teams.some((t) => t.key === m.teamKey))], [200, true], [200, false]);

// ---- bounds ---------------------------------------------------------------------------------
const longFrom = dateKey(new Date(Date.now() - 92 * 86_400_000), meA.timeZone);
// ---- the roster (migration 0005), 20 checks ----------------------------------------------------
// The manager plans (roster.manage), the agent reads their own published schedule (roster.view),
// the supervisor reads today's shifts for the board (monitoring.live). Two weeks ahead, on the
// agent's own team, so the fixture's weeks stay as they are; every cell written is cleared again.
const monday = (d) => { const x = new Date(d); x.setUTCDate(x.getUTCDate() - ((x.getUTCDay() + 6) % 7)); return x.toISOString().slice(0, 10); };
const plusDays = (key, n) => new Date(Date.parse(`${key}T00:00:00Z`) + n * 86_400_000).toISOString().slice(0, 10);
const thisMonday = monday(`${today}T00:00:00Z`);
const wk = plusDays(thisMonday, 14);
const wk2 = plusDays(thisMonday, 21);
const agentTeam = originalTeams[0];
const absenceTypes = (await get(AGENT, "/api/v1/roster/absence-types")).body?.data ?? [];
expect("any person reads the tenant's absence types", [absenceTypes.length > 0, absenceTypes.every((a) => a.key && a.name)], [true, true], [false, true]);
expect("an agent cannot read the planner", (await get(AGENT, `/api/v1/roster/weeks/${wk}?team=${agentTeam}`)).status, 403, 200);
expect("a week must start on a Monday", (await get(MANAGER, `/api/v1/roster/weeks/${plusDays(wk, 1)}?team=${agentTeam}`)).status, 400, 200);
const planner = await get(MANAGER, `/api/v1/roster/weeks/${wk}?team=${agentTeam}`);
expect("the manager reads the week with the agent on the grid",
  [planner.status, planner.body?.data?.header?.weekStart, planner.body?.data?.header?.teamKey, (planner.body?.data?.people ?? []).some((p) => p.userId === meA.userId)],
  [200, wk, agentTeam, true], [200, wk, agentTeam, false]);
const cellsPath = `/api/v1/roster/weeks/${wk}/cells`;
const shiftCell = { team: agentTeam, userId: meA.userId, date: wk, cell: { kind: "shift", start: "10:15", end: "18:00" } };
expect("a cell write needs the request header", (await json(MANAGER, "PUT", cellsPath, shiftCell, {})).status, 400, 200);
expect("a cross-site cell write is refused", (await json(MANAGER, "PUT", cellsPath, shiftCell, { "x-cma-request": "1", "sec-fetch-site": "cross-site" })).status, 403, 200);
expect("an agent cannot write a cell", (await json(AGENT, "PUT", cellsPath, shiftCell)).status, 403, 200);
const written = await json(MANAGER, "PUT", cellsPath, shiftCell);
expect("a shift is written and read back with its times", [written.status, written.body?.data?.kind, written.body?.data?.start, written.body?.data?.end], [200, "shift", "10:15:00", "18:00:00"], [200, "shift", "10:15", "18:00"]);
expect("the past is refused", (await json(MANAGER, "PUT", `/api/v1/roster/weeks/${plusDays(thisMonday, -7)}/cells`, { ...shiftCell, date: plusDays(thisMonday, -7) })).status, 400, 200);
expect("a date outside the week is refused", (await json(MANAGER, "PUT", cellsPath, { ...shiftCell, date: plusDays(wk, 7) })).status, 400, 200);
expect("a person not on this roster is refused", (await json(MANAGER, "PUT", cellsPath, { ...shiftCell, userId: meS.userId })).status, 400, 200);
expect("a shift that ends before it starts is refused", (await json(MANAGER, "PUT", cellsPath, { ...shiftCell, cell: { kind: "shift", start: "22:00", end: "06:00" } })).status, 400, 200);
expect("the same person on another roster that day is a conflict", (await json(MANAGER, "PUT", cellsPath, { ...shiftCell, team: null })).status, 409, 200);
const published1 = await json(MANAGER, "POST", `/api/v1/roster/weeks/${wk}/publish`, { team: agentTeam });
const own1 = (await get(AGENT, `/api/v1/me/roster?from=${wk}&to=${wk}`)).body?.data?.[0];
expect("after the publish the agent sees the shift", [published1.status, published1.body?.data?.status, own1?.isPublished, own1?.kind, own1?.start], [200, "published", true, "shift", "10:15:00"], [200, "draft", true, "shift", "10:15:00"]);
await json(MANAGER, "PUT", cellsPath, { ...shiftCell, cell: { kind: "absence", absenceKey: absenceTypes[0]?.key } });
const header2 = (await get(MANAGER, `/api/v1/roster/weeks/${wk}?team=${agentTeam}`)).body?.data?.header;
const own2 = (await get(AGENT, `/api/v1/me/roster?from=${wk}&to=${wk}`)).body?.data?.[0];
expect("an edit after the publish is flagged and the agent keeps the published shift", [header2?.changedSincePublish, own2?.kind, own2?.start], [true, "shift", "10:15:00"], [false, "absence", null]);
const published2 = await json(MANAGER, "POST", `/api/v1/roster/weeks/${wk}/publish`, { team: agentTeam });
const own3 = (await get(AGENT, `/api/v1/me/roster?from=${wk}&to=${wk}`)).body?.data?.[0];
expect("the second publish raises the version and the agent sees the absence", [published2.body?.data?.version > published1.body?.data?.version, own3?.kind, own3?.absenceKey], [true, "absence", absenceTypes[0]?.key], [false, "absence", absenceTypes[0]?.key]);
const copied = await json(MANAGER, "POST", `/api/v1/roster/weeks/${wk2}/copy`, { team: agentTeam, from: wk });
expect("copying the week carries the cell into the next one", [copied.status, copied.body?.data?.copied >= 1], [200, true], [200, false]);
const weeksList = (await get(MANAGER, `/api/v1/roster/weeks?team=${agentTeam}&from=${wk}&to=${plusDays(wk2, 6)}`)).body?.data ?? [];
expect("the weeks list shows both weeks with their states",
  [weeksList.find((w) => w.weekStart === wk)?.status, weeksList.find((w) => w.weekStart === wk2)?.status], ["published", "draft"], ["draft", "published"]);
expect("the own schedule has one row per day and is bounded to 92 days",
  [(await get(AGENT, `/api/v1/me/roster?from=${wk}&to=${plusDays(wk, 6)}`)).body?.data?.length, (await get(AGENT, `/api/v1/me/roster?from=${longFrom}&to=${today}`)).status], [7, 400], [6, 400]);
expect("the analyst holds no roster", (await get(ANALYST, `/api/v1/me/roster?from=${today}&to=${today}`)).status, 403, 200);
expect("an agent cannot read today's shifts", (await get(AGENT, "/api/v1/team/shifts-today")).status, 403, 200);
const shiftsToday = await get(SUPERVISOR, "/api/v1/team/shifts-today");
expect("the supervisor reads today's shifts with one row per person whose time is kept",
  [shiftsToday.status, (shiftsToday.body?.data ?? []).some((x) => x.userId === meA.userId), (shiftsToday.body?.data ?? []).some((x) => x.userId === meN?.userId)], [200, true, false], [200, true, true]);
// Leave the two weeks empty for the next run (dev data; not a check)
await json(MANAGER, "PUT", cellsPath, { ...shiftCell, cell: { kind: "clear" } });
await json(MANAGER, "PUT", `/api/v1/roster/weeks/${wk2}/cells`, { ...shiftCell, date: wk2, cell: { kind: "clear" } });
await json(MANAGER, "POST", `/api/v1/roster/weeks/${wk}/publish`, { team: agentTeam });

expect("hours range is bounded to 92 days", (await get(AGENT, `/api/v1/me/hours?from=${longFrom}&to=${today}`)).status, 400, 200);

// ---- configuration (migration 0005a), 24 checks --------------------------------------------------
// The admin configures (tenant.configure); the manager and the agent are refused by the database.
// Every write is undone at the end, so the dev tenant's configuration is as the run found it.
const cfg = "/api/v1/configuration";
const put = (s, path, body) => json(s, "PUT", path, body);
const statusesBefore = await get(ADMIN, `${cfg}/statuses`);
expect("an agent cannot read the status configuration", (await get(AGENT, `${cfg}/statuses`)).status, 403, 200);
expect("the manager cannot read it either (tenant.configure left the manager row in 0004)", (await get(MANAGER, `${cfg}/statuses`)).status, 403, 200);
expect("the admin reads every status with flags, default and usage",
  [statusesBefore.status, (statusesBefore.body?.data ?? []).filter((x) => x.isDefault).length, (statusesBefore.body?.data ?? []).every((x) => typeof x.usageCount === "number" && typeof x.isPaid === "boolean")],
  [200, 1, true], [200, 0, true]);
const verifyStatus = { key: "verify_0005a", name: "Verify status", isWorking: true, isProductive: false, isPaid: true, isBillable: false, sortOrder: 990 };
expect("a status write needs the request header", (await json(ADMIN, "PUT", `${cfg}/statuses`, verifyStatus, {})).status, 400, 200);
expect("a cross-site status write is refused", (await json(ADMIN, "PUT", `${cfg}/statuses`, verifyStatus, { "x-cma-request": "1", "sec-fetch-site": "cross-site" })).status, 403, 200);
expect("the manager cannot add a status", (await put(MANAGER, `${cfg}/statuses`, verifyStatus)).status, 403, 200);
const addedS = await put(ADMIN, `${cfg}/statuses`, verifyStatus);
expect("the admin adds a status and reads it back with its flags",
  [addedS.status, (addedS.body?.data ?? []).find((x) => x.key === verifyStatus.key)?.isBillable ?? null, (addedS.body?.data ?? []).find((x) => x.key === verifyStatus.key)?.usageCount ?? null],
  [200, false, 0], [200, true, 0]);
expect("a bad key is a 400", (await put(ADMIN, `${cfg}/statuses`, { ...verifyStatus, key: "Bad Key" })).status, 400, 200);
const editedS = await put(ADMIN, `${cfg}/statuses`, { ...verifyStatus, name: "Verify status renamed", isBillable: true });
expect("flags and name change while no time is recorded in it",
  [(editedS.body?.data ?? []).find((x) => x.key === verifyStatus.key)?.name, (editedS.body?.data ?? []).find((x) => x.key === verifyStatus.key)?.isBillable], ["Verify status renamed", true], ["Verify status", false]);
// A status with time behind it (the fixture's days): its flags are frozen, its name is not
const theDefault = (statusesBefore.body?.data ?? []).find((x) => x.isDefault);
const used = (statusesBefore.body?.data ?? []).find((x) => x.usageCount > 0 && x.isActive) ?? (statusesBefore.body?.data ?? []).find((x) => x.usageCount > 0);
expect("the flags of a status with time behind it are frozen (409)",
  (await put(ADMIN, `${cfg}/statuses`, { ...used, isPaid: !used?.isPaid })).status, 409, 200);
expect("the default cannot be retired (409)", (await put(ADMIN, `${cfg}/statuses/${theDefault?.key}/retired`)).status, 409, 200);
const nowDefault = await put(ADMIN, `${cfg}/statuses/${verifyStatus.key}/default`);
expect("the new status becomes the one default", (nowDefault.body?.data ?? []).filter((x) => x.isDefault).map((x) => x.key), [verifyStatus.key], [theDefault?.key]);
await put(ADMIN, `${cfg}/statuses/${theDefault?.key}/default`);
const retiredS = await put(ADMIN, `${cfg}/statuses/${verifyStatus.key}/retired`);
expect("retire keeps the status, inactive; the agent's list no longer offers it",
  [(retiredS.body?.data ?? []).find((x) => x.key === verifyStatus.key)?.isActive, ((await get(AGENT, "/api/v1/me/statuses")).body?.data ?? []).some((x) => x.key === verifyStatus.key)], [false, false], [true, false]);
expect("an unknown status is a 404", (await put(ADMIN, `${cfg}/statuses/verify_no_such/default`)).status, 404, 200);

// app links
const linksBefore = (await get(ADMIN, `${cfg}/app-links`)).body?.data ?? [];
const verifyLink = { key: "verify-0005a", label: "Verify link", address: "https://example.invalid/verify", permissionKey: "workday.team", sortOrder: 990 };
expect("the manager cannot read the link configuration", (await get(MANAGER, `${cfg}/app-links`)).status, 403, 200);
expect("a plain http address is a 400", (await put(ADMIN, `${cfg}/app-links`, { ...verifyLink, address: "http://example.invalid/" })).status, 400, 200);
expect("an unknown permission is a 404", (await put(ADMIN, `${cfg}/app-links`, { ...verifyLink, permissionKey: "no.such_permission" })).status, 404, 200);
await put(ADMIN, `${cfg}/app-links`, verifyLink);
expect("the link reaches the supervisor and not the agent",
  [((await get(SUPERVISOR, "/api/v1/me/app-links")).body?.data ?? []).some((l) => l.key === verifyLink.key), ((await get(AGENT, "/api/v1/me/app-links")).body?.data ?? []).some((l) => l.key === verifyLink.key)], [true, false], [false, false]);
const retiredL = await put(ADMIN, `${cfg}/app-links/${verifyLink.key}/retired`);
expect("a retired link stays listed inactive and leaves Welcome",
  [(retiredL.body?.data ?? []).find((l) => l.key === verifyLink.key)?.isActive, ((await get(SUPERVISOR, "/api/v1/me/app-links")).body?.data ?? []).some((l) => l.key === verifyLink.key)], [false, false], [true, true]);
expect("the permission catalog is read by the admin only",
  [(await get(MANAGER, `${cfg}/permissions`)).status, ((await get(ADMIN, `${cfg}/permissions`)).body?.data ?? []).some((p) => p.key === "tenant.configure")], [403, true], [200, true]);

// absence types, coverage targets, settings
await put(ADMIN, `${cfg}/absence-types`, { key: "verify_abs", name: "Verify absence", isPaid: false, sortOrder: 990 });
const retiredA = await put(ADMIN, `${cfg}/absence-types/verify_abs/retired`);
expect("an absence type is added and retired; the planner's list drops it",
  [(retiredA.body?.data ?? []).find((a) => a.key === "verify_abs")?.isActive, ((await get(AGENT, "/api/v1/roster/absence-types")).body?.data ?? []).some((a) => a.key === "verify_abs")], [false, false], [true, true]);
const workType = ((await get(ADMIN, "/api/v1/team/skills")).body?.data ?? []).find((x) => x.dimension === "work_type" && x.isActive);
const targetBefore = ((await get(ADMIN, `${cfg}/coverage-targets`)).body?.data ?? []).find((t) => t.teamKey === agentTeam && t.skillKey === workType?.key && t.weekday === 7)?.minCount ?? 0;
const setT = await put(ADMIN, `${cfg}/coverage-targets`, { teamKey: agentTeam, skillKey: workType?.key, weekday: 7, minCount: 9 });
expect("a coverage target is set per team, work type and weekday",
  (setT.body?.data ?? []).find((t) => t.teamKey === agentTeam && t.skillKey === workType?.key && t.weekday === 7)?.minCount ?? null, 9, targetBefore);
expect("weekday 8 is a 400", (await put(ADMIN, `${cfg}/coverage-targets`, { teamKey: agentTeam, skillKey: workType?.key, weekday: 8, minCount: 1 })).status, 400, 200);
await put(ADMIN, `${cfg}/coverage-targets`, { teamKey: agentTeam, skillKey: workType?.key, weekday: 7, minCount: targetBefore });
const sepBefore = ((await get(ADMIN, "/api/v1/settings")).body?.data ?? []).find((x) => x.key === "export.csv.separator");
const setS = await put(ADMIN, `${cfg}/settings`, { key: "export.csv.separator", value: "tab" });
expect("a setting is written and read back by any person",
  [setS.body?.data?.value, ((await get(AGENT, "/api/v1/settings")).body?.data ?? []).find((x) => x.key === "export.csv.separator")?.value], ["tab", "tab"], [sepBefore?.value, sepBefore?.value]);
expect("a value outside the catalog is a 400", (await put(ADMIN, `${cfg}/settings`, { key: "export.csv.separator", value: "pipe" })).status, 400, 200);
expect("the agent cannot write a setting", (await put(AGENT, `${cfg}/settings`, { key: "export.csv.separator", value: "comma" })).status, 403, 200);
await put(ADMIN, `${cfg}/settings`, { key: "export.csv.separator", value: sepBefore?.isDefault ? null : sepBefore?.value ?? null });
const graceReset = await put(ADMIN, `${cfg}/settings`, { key: "workday.auto_close_grace_minutes", value: null });
expect("the forgotten clock-out grace exists with its default", [graceReset.body?.data?.value, graceReset.body?.data?.isDefault], ["120", true], ["120", false]);
// Nothing of the run stays: the status and the link stay retired rows with no time behind them (dev data; not a check)
void linksBefore;

await sourceChecks();

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
// The colour needs isProductive; whether a pause is paid is not agent information
expect("the status list shows no pay or billing flags",
  [statuses.length > 0, statuses.every((s) => !("isPaid" in s) && !("isBillable" in s) && typeof s.isProductive === "boolean")],
  [true, true], [true, false]);

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
// The name as stored travels with the day, so a status retired while someone is in it is still
// named on My day and Welcome (increment f; the active list no longer carries it then)
expect("the own day names its current status",
  after?.statusName ?? null, target?.name ?? "(no other status to switch to)", before?.statusName ?? null);
expect("status since moves to the change",
  Date.parse(after?.statusSince ?? "") > Date.parse(before?.statusSince ?? before?.startedAt ?? ""), true, false);

expect("unknown status key is a 404",
  (await setStatus(AGENT, { key: "verify-no-such-status" })).status, 404, 200);

await end(SUPERVISOR);   // already ended above; ending again changes nothing
expect("an ended day refuses a status change",
  (await setStatus(SUPERVISOR, { key: target?.key })).status, 409, 200);

// Leave Agent Two in the status the run found (dev data; not a check)
if (before?.statusKey) await setStatus(AGENT, { key: before.statusKey });

// ---- messaging (migration 0008), 22 checks --------------------------------------------------
// One urgent message per run from the test supervisor to Agent Two (dev data), then read and
// acknowledged by Agent Two, so the stats show the whole path.
const inboxBefore = (await get(AGENT, "/api/v1/me/messages")).body?.data;
expect("the own inbox lists messages with an unread count",
  [Array.isArray(inboxBefore?.messages), typeof inboxBefore?.unreadCount], [true, "number"], [false, "number"]);
expect("a bad since is a 400", (await get(AGENT, "/api/v1/me/messages?since=yesterday")).status, 400, 200);
expect("a limit above 200 is a 400", (await get(AGENT, "/api/v1/me/messages?limit=201")).status, 400, 200);
const jsonPost = (s, path, body, headers = { "x-cma-request": "1" }) =>
  call(s, path, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });
const readIds = (s, ids, headers) => jsonPost(s, "/api/v1/me/messages/read", { ids }, headers);
const send = (s, body, headers) => jsonPost(s, "/api/v1/messages", body, headers);
const ackOf = (s, id, headers = { "x-cma-request": "1" }) => post(s, `/api/v1/me/messages/${id}/ack`, headers);
const NO_MESSAGE = "00000000-0000-7000-8000-00000000dead";
expect("marking read needs the request header", (await readIds(AGENT, [NO_MESSAGE], {})).status, 400, 200);
expect("cross-site marking read is refused",
  (await readIds(AGENT, [NO_MESSAGE], { "x-cma-request": "1", "sec-fetch-site": "cross-site" })).status, 403, 200);
expect("an agent cannot send", (await send(AGENT, { title: "verify", target: { everyone: true } })).status, 403, 201);
expect("a target without a group is a 400 before the database", (await send(SUPERVISOR, { title: "verify", target: {} })).status, 400, 201);
expect("an unknown team is a 404", (await send(SUPERVISOR, { title: "verify", target: { teams: ["verify-no-such-team"] } })).status, 404, 201);
const sent = await send(SUPERVISOR, { title: `API verifier ${new Date().toISOString().slice(0, 16)}`, body: "Sent by verify/api.mjs; acknowledged by the same run", urgency: "urgent", target: { users: [meA.userId] } });
const mid = sent.body?.data?.id;
expect("the supervisor sends an urgent message to one named person", [sent.status, sent.body?.data?.recipients], [201, 1], [403, 0]);
const inboxAfter = (await get(AGENT, "/api/v1/me/messages")).body?.data;
const mine = inboxAfter?.messages?.find((m) => m.id === mid);
expect("the recipient sees it unread, urgent, delivered by this read, title and body only",
  [!!mine, mine?.readAt ?? null, !!mine?.deliveredAt, mine?.urgency, mine?.ref ?? null], [true, null, true, "urgent", null], [false, null, false, "normal", null]);
expect("the unread count moved by one", inboxAfter?.unreadCount - inboxBefore?.unreadCount, 1, 0);
expect("the sender's own inbox does not hold it",
  (await get(SUPERVISOR, "/api/v1/me/messages")).body?.data?.messages?.some((m) => m.id === mid) ?? false, false, true);
expect("since lists only newer messages",
  (await get(AGENT, `/api/v1/me/messages?since=${encodeURIComponent(mine?.createdAt ?? "")}`)).body?.data?.messages?.some((m) => m.id === mid) ?? false, false, true);
expect("another person cannot read it for the recipient", (await readIds(SUPERVISOR, [mid])).body?.data?.changed, 0, 1);
expect("marking read changes one row, then none",
  [(await readIds(AGENT, [mid])).body?.data?.changed, (await readIds(AGENT, [mid])).body?.data?.changed], [1, 0], [0, 1]);
expect("acknowledging needs the request header", (await ackOf(AGENT, mid, {})).status, 400, 200);
expect("acknowledging a message that is not yours is a 404", (await ackOf(SUPERVISOR, mid)).status, 404, 200);
expect("the recipient acknowledges; a second time changes nothing", [(await ackOf(AGENT, mid)).status, (await ackOf(AGENT, mid)).status], [200, 200], [404, 404]);
const acked = (await get(AGENT, "/api/v1/me/messages")).body?.data?.messages?.find((m) => m.id === mid);
expect("read and acknowledged times are set and the count is back", [!!acked?.readAt, !!acked?.acknowledgedAt, inboxBefore?.unreadCount === (await get(AGENT, "/api/v1/me/messages")).body?.data?.unreadCount],
  [true, true, true], [false, false, false]);
const shift = (d, days) => dateKey(new Date(d.getTime() + days * 86_400_000), meA.timeZone);
const statsPath = `/api/v1/messages/stats?from=${shift(new Date(), -1)}&to=${shift(new Date(), 1)}`;
expect("stats need messages.send or performance.team", [(await get(AGENT, statsPath)).status, (await get(SUPERVISOR, statsPath)).status], [403, 200], [200, 403]);
const stat = (await get(SUPERVISOR, statsPath)).body?.data?.find((x) => x.id === mid);
expect("the stats count the one recipient: delivered, read, acknowledged, not by a rule",
  [stat?.recipients, stat?.delivered, stat?.read, stat?.acknowledged, stat?.byRule], [1, 1, 1, 1, false], [1, 0, 0, 0, true]);
expect("a stats range over 92 days is a 400", (await get(SUPERVISOR, `/api/v1/messages/stats?from=${shift(new Date(), -100)}&to=${shift(new Date(), 0)}`)).status, 400, 200);

await reportChecks();
verdict();

function verdict() {
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
}

// ---- sources, markets, alert rules and linked accounts (addition 0008e), 32 checks ------------------
// The admin configures sources, markets and rules (tenant.configure); linked accounts follow the People
// rule (users.manage_agents for non-managing people, users.manage_all for everyone, never oneself). Every
// write is undone at the end: settings, a pipeline, a call outcome, an alias, a holiday and two people's ids
// are put back as the run found them; the one rule the run writes ("API verifier rule", a record_assigned
// rule on a pipeline id no source has) is left switched off (dev data). The source checks need a
// connection: dev's CRM connection, or locally verify/reports-fixture.sql.
async function sourceChecks() {
  const sj = (s, method, path, body, headers = { "x-cma-request": "1" }) =>
    call(s, path, { method, headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });
  const cfgS = "/api/v1/configuration";
  const KNOWN = ["id", "key", "adapter", "name", "accountId", "kind", "heldKinds", "isActive", "signingSecretName", "tokenSecretName", "settings",
    "events24h", "eventsWaiting", "eventsParked", "lastEventAt", "pipelines", "forms", "callOutcomes", "fields", "lines", "tags", "storeHandle"].sort();

  expect("sources: an agent cannot read the connections", (await get(AGENT, `${cfgS}/sources`)).status, 403, 200);
  expect("sources: the manager cannot read them either", (await get(MANAGER, `${cfgS}/sources`)).status, 403, 200);
  const list = await get(ADMIN, `${cfgS}/sources`);
  const sources = list.body?.data ?? [];
  expect("sources: the admin reads every connection with its kind",
    [list.status, Array.isArray(list.body?.data), sources.every((c) => [null, "crm", "telephony", "commerce", "automation"].includes(c.kind) && Array.isArray(c.heldKinds))],
    [200, true, true], [403, false, true]);
  expect("sources: no secret value, only names and non-secret settings",
    sources.every((c) => JSON.stringify(Object.keys(c).sort()) === JSON.stringify(KNOWN) && Object.keys(c.settings ?? {}).every((k) => !/(secret|token|password|key)/i.test(k))),
    true, false);
  expect("sources: a malformed id is a 400, an unknown one a 404",
    [(await get(ADMIN, `${cfgS}/sources/not-an-id`)).status, (await get(ADMIN, `${cfgS}/sources/00000000-0000-7000-8000-00000000dead`)).status], [400, 404], [200, 200]);

  const src = sources.find((c) => c.kind === "crm") ?? sources.find((c) => c.heldKinds.includes("crm")) ?? sources[0];
  if (!src) {
    console.log("note  no connection in this tenant: the 10 checks on one connection are left out (load verify/reports-fixture.sql locally)");
  } else {
    const base = `${cfgS}/sources/${src.id}`;
    const one = await get(ADMIN, base);
    const d = one.body?.data;
    expect("sources: the admin opens one connection with its catalogs",
      [one.status, d?.connection?.id, ["pipelines", "forms", "callOutcomes", "lines", "tags", "fields", "writeback"].every((k) => Array.isArray(d?.[k]))],
      [200, src.id, true], [404, null, true]);
    const settingsBefore = d?.connection?.settings ?? {};
    expect("sources: a settings write needs the request header", (await sj(ADMIN, "PUT", `${base}/settings`, { settings: settingsBefore }, {})).status, 400, 200);
    expect("sources: a cross-site settings write is refused",
      (await sj(ADMIN, "PUT", `${base}/settings`, { settings: settingsBefore }, { "x-cma-request": "1", "sec-fetch-site": "cross-site" })).status, 403, 200);
    const secretTry = await sj(ADMIN, "PUT", `${base}/settings`, { settings: { ...settingsBefore, api_token: "x" } });
    expect("sources: a secret-looking settings key is a 400 and changes nothing",
      [secretTry.status, Object.keys((await get(ADMIN, base)).body?.data?.connection?.settings ?? {}).includes("api_token")], [400, false], [200, true]);
    expect("sources: the manager cannot write settings", (await sj(MANAGER, "PUT", `${base}/settings`, { settings: settingsBefore })).status, 403, 200);
    const written = await sj(ADMIN, "PUT", `${base}/settings`, { settings: { ...settingsBefore, verify_note: "api verifier" } });
    const restored = await sj(ADMIN, "PUT", `${base}/settings`, { settings: settingsBefore });
    expect("sources: a setting is written, read back and the settings restored",
      [written.body?.data?.connection?.settings?.verify_note, JSON.stringify(restored.body?.data?.connection?.settings) === JSON.stringify(settingsBefore)],
      ["api verifier", true], [undefined, true]);
    const notHeld = ["crm", "telephony", "commerce", "automation"].find((k) => src.heldKinds.length > 0 && !src.heldKinds.includes(k));
    expect("sources: a kind the connection's rows contradict is a 409",
      notHeld ? (await sj(ADMIN, "PUT", base, { kind: notHeld })).status : 409, 409, 200);
    const pipeline = d?.pipelines?.[0];
    if (pipeline) {
      const flipped = await sj(ADMIN, "PUT", `${base}/pipelines`, { recordType: pipeline.recordType, pipelineId: pipeline.pipelineId, isCounted: !pipeline.isCounted, isLead: pipeline.isLead });
      const back = await sj(ADMIN, "PUT", `${base}/pipelines`, { recordType: pipeline.recordType, pipelineId: pipeline.pipelineId, isCounted: pipeline.isCounted, isLead: pipeline.isLead });
      const find = (r) => (r.body?.data?.pipelines ?? []).find((p) => p.recordType === pipeline.recordType && p.pipelineId === pipeline.pipelineId);
      expect("sources: a pipeline's counted switch is written and put back",
        [find(flipped)?.isCounted, find(back)?.isCounted, find(back)?.isRouted, find(back)?.workType], [!pipeline.isCounted, pipeline.isCounted, pipeline.isRouted, pipeline.workType], [pipeline.isCounted, !pipeline.isCounted, null, null]);
    } else {
      console.log("note  the connection has no pipeline: the pipeline check is left out");
    }
    const form = d?.forms?.[0];
    if (form) {
      const bad = await sj(ADMIN, "PUT", `${base}/forms`, { forms: [
        { formId: form.formId, isCounted: !form.isCounted, leadSource: form.leadSource, market: form.market },
        { formId: form.formId, isCounted: form.isCounted, leadSource: form.leadSource, market: "ZZ" }] });
      const after = ((await get(ADMIN, base)).body?.data?.forms ?? []).find((f) => f.formId === form.formId);
      expect("sources: a form change with an unknown market is a 404 and writes nothing", [bad.status, after?.isCounted, after?.keptFields], [404, form.isCounted, form.keptFields], [200, !form.isCounted, []]);
    } else {
      console.log("note  the connection has no form: the form check is left out");
    }
    const outcome = d?.callOutcomes?.[0];
    if (outcome) {
      const o1 = await sj(ADMIN, "PUT", `${base}/call-outcomes`, { outcomes: [{ outcomeRef: outcome.outcomeRef, isConnected: !outcome.isConnected }] });
      const o2 = await sj(ADMIN, "PUT", `${base}/call-outcomes`, { outcomes: [{ outcomeRef: outcome.outcomeRef, isConnected: outcome.isConnected }] });
      const find = (r) => (r.body?.data?.callOutcomes ?? []).find((o) => o.outcomeRef === outcome.outcomeRef)?.isConnected;
      expect("sources: a call outcome's connected switch is written and put back", [find(o1), find(o2)], [!outcome.isConnected, outcome.isConnected], [outcome.isConnected, outcome.isConnected]);
    } else {
      console.log("note  the connection has no call outcome: the outcome check is left out");
    }
  }

  // markets
  expect("markets: an agent cannot read them", (await get(AGENT, `${cfgS}/markets`)).status, 403, 200);
  const mk = await get(ADMIN, `${cfgS}/markets`);
  const markets = mk.body?.data?.markets ?? [];
  expect("markets: the admin reads markets with aliases, office hours and holidays",
    [mk.status, markets.every((m) => /^[A-Z]{2}$/.test(m.code) && Array.isArray(m.aliases)), Array.isArray(mk.body?.data?.hours), Array.isArray(mk.body?.data?.holidays)],
    [200, true, true, true], [403, true, true, true]);
  expect("markets: UK is not a market code (use GB)",
    (await sj(ADMIN, "PUT", `${cfgS}/markets`, { code: "UK", name: "United Kingdom", timeZone: "Europe/London", languageCode: "en", currency: "GBP", sortOrder: 990 })).status, 400, 200);
  expect("markets: overlapping office hours are a 400",
    (await sj(ADMIN, "PUT", `${cfgS}/markets/hours`, { market: "*", days: [{ weekday: 7, hours: "09:00-13:00,12:00-17:00" }] })).status, 400, 200);
  const first = markets[0];
  if (first) {
    const alias = `verify alias ${Date.now() % 100000}`;
    const added = await sj(ADMIN, "PUT", `${cfgS}/markets/aliases`, { alias, code: first.code });
    const removed = await sj(ADMIN, "PUT", `${cfgS}/markets/aliases`, { alias, code: null });
    const again = await sj(ADMIN, "PUT", `${cfgS}/markets/aliases`, { alias, code: null });
    const has = (r) => (r.body?.data?.markets ?? []).find((m) => m.code === first.code)?.aliases.includes(alias);
    expect("markets: an alias is added, read back and removed; a second removal is a 404", [has(added), has(removed), again.status], [true, false, 404], [false, true, 200]);
    const day = `${new Date().getUTCFullYear() + 9}-01-02`;
    const hAdd = await sj(ADMIN, "PUT", `${cfgS}/markets/holidays`, { market: "*", day, name: "API verifier holiday" });
    const hDel = await sj(ADMIN, "PUT", `${cfgS}/markets/holidays`, { market: "*", day, name: null });
    const hHas = (r) => (r.body?.data?.holidays ?? []).some((h) => h.market === "*" && h.day === day);
    expect("markets: a holiday is added and removed again", [hHas(hAdd), hHas(hDel)], [true, false], [false, true]);
  } else {
    console.log("note  no market in this tenant: the alias and holiday checks are left out");
  }

  // alert rules
  expect("alert rules: the manager cannot read them", (await get(MANAGER, `${cfgS}/alert-rules`)).status, 403, 200);
  const rulesRead = await get(ADMIN, `${cfgS}/alert-rules`);
  expect("alert rules: the admin reads the rules and the pipelines a rule can name",
    [rulesRead.status, Array.isArray(rulesRead.body?.data?.rules), Array.isArray(rulesRead.body?.data?.pipelines), Number.isInteger(rulesRead.body?.data?.defaultMaxAgeMinutes)],
    [200, true, true, true], [403, true, true, true]);
  const RULE = "API verifier rule";
  const recordType = rulesRead.body?.data?.pipelines?.[0]?.recordType ?? "deal";
  const ruleBody = { name: RULE, trigger: "record_assigned", recordType, pipelineIds: ["verify-no-such-pipeline"], urgency: "normal", maxAgeMinutes: 5 };
  const ruleWritten = await sj(ADMIN, "PUT", `${cfgS}/alert-rules`, ruleBody);
  const rule = (ruleWritten.body?.data?.rules ?? []).find((r) => r.name === RULE);
  expect("alert rules: an assignment rule is written by name and listed",
    [ruleWritten.status, rule?.trigger, rule?.pipelineIds, rule?.maxAgeMinutes], [200, "record_assigned", ["verify-no-such-pipeline"], 5], [403, "record_created", [], null]);
  expect("alert rules: the same name for the other trigger is a 409",
    (await sj(ADMIN, "PUT", `${cfgS}/alert-rules`, { ...ruleBody, trigger: "record_created", audiencePermission: "leads.accept", matchLanguage: true, onlyClockedIn: true, fallbackPermission: null })).status, 409, 200);
  const off = rule ? await sj(ADMIN, "PUT", `${cfgS}/alert-rules/${rule.id}/enabled`, { enabled: false }) : null;
  expect("alert rules: a rule is switched off, never deleted", (off?.body?.data?.rules ?? []).find((r) => r.name === RULE)?.enabled, false, true);

  // linked accounts on People
  const la = "/api/v1/team/directory";
  expect("linked accounts: an agent cannot read them", (await get(AGENT, `${la}/linked-accounts`)).status, 403, 200);
  const linked = await get(MANAGER, `${la}/linked-accounts`);
  const systems = linked.body?.data?.systems ?? [];
  expect("linked accounts: the manager reads the systems and the ids held, never a sign-in id",
    [linked.status, systems.every((x) => /^[a-z0-9]+_(owner|user)$/.test(x.system)), (linked.body?.data?.accounts ?? []).every((a) => /_(owner|user)$/.test(a.system))],
    [200, true, true], [403, true, true]);
  const meMgr = (await get(MANAGER, "/api/v1/me")).body?.data;
  const meAdmin = (await get(ADMIN, "/api/v1/me")).body?.data;
  const meAgent = (await get(AGENT, "/api/v1/me")).body?.data;
  const sys = systems[0]?.system ?? "verify_owner";
  expect("linked accounts: the manager cannot link the admin (a managing person)",
    (await sj(MANAGER, "PUT", `${la}/${meAdmin?.userId}/linked-accounts`, { system: sys, externalId: "verify-1" })).status, 403, 200);
  expect("linked accounts: nobody links their own id",
    (await sj(MANAGER, "PUT", `${la}/${meMgr?.userId}/linked-accounts`, { system: sys, externalId: "verify-2" })).status, 403, 200);
  expect("linked accounts: an id with a space is a 400",
    (await sj(MANAGER, "PUT", `${la}/${meAgent?.userId}/linked-accounts`, { system: sys, externalId: "has space" })).status, 400, 200);
  // two people the manager may edit, from the manager's own directory (dev: the seed's agents; mock: the fixture team)
  const editable = ((await get(MANAGER, la)).body?.data ?? []).filter((x) => x.mayEdit && x.isActive);
  const [pa, pb] = editable;
  if (systems.length > 0 && pa && pb) {
    const held = (u) => (linked.body?.data?.accounts ?? []).find((a) => a.userId === u && a.system === sys)?.externalId ?? null;
    const aBefore = held(pa.userId);
    const bBefore = held(pb.userId);
    const id = `verify-${Date.now() % 1000000}`;
    const linkedNow = await sj(MANAGER, "PUT", `${la}/${pa.userId}/linked-accounts`, { system: sys, externalId: id });
    const taken = await sj(MANAGER, "PUT", `${la}/${pb.userId}/linked-accounts`, { system: sys, externalId: id });
    const after = (await get(MANAGER, `${la}/linked-accounts`)).body?.data?.accounts ?? [];
    const bAfter = after.find((a) => a.userId === pb.userId && a.system === sys)?.externalId ?? null;
    // put both back as the run found them
    if (bAfter !== bBefore) await sj(MANAGER, "PUT", `${la}/${pb.userId}/linked-accounts`, { system: sys, externalId: bBefore });
    await sj(MANAGER, "PUT", `${la}/${pa.userId}/linked-accounts`, { system: sys, externalId: aBefore });
    const aAfter = ((await get(MANAGER, `${la}/linked-accounts`)).body?.data?.accounts ?? []).find((a) => a.userId === pa.userId && a.system === sys)?.externalId ?? null;
    expect("linked accounts: the manager links a person; the same id for another person is a 409; put back",
      [(linkedNow.body?.data?.accounts ?? []).some((a) => a.userId === pa.userId && a.externalId === id), taken.status, bAfter === bBefore, aAfter === aBefore],
      [true, 409, true, true], [false, 200, true, true]);
  } else {
    console.log("note  no customer-records or telephony system, or fewer than two people the manager may edit: the link check is left out");
  }
}

// ---- intake reports (B11, migration 0007d), 16 checks, 17 with the tenant without sources ------
// Read only. Each route needs its function's permission (reports.view or performance.team; data
// quality reports.view or tenant.configure), answered 403 by the route and again by the database;
// at most 92 days; a group outside day, market, agent and pipeline is a 400; no row field is personal.
async function reportChecks() {
  const tz = "Europe/Amsterdam";
  const day = (offset) => dateKey(new Date(Date.now() + offset * 86_400_000), tz);
  const range = `from=${day(-29)}&to=${day(0)}`;
  const routes = [`/api/v1/reports/speed-to-lead?${range}&group=day`, `/api/v1/reports/speed-to-lead/rows?${range}`, `/api/v1/reports/intake?${range}`, "/api/v1/reports/data-quality"];
  const statuses = async (s) => Promise.all(routes.map(async (r) => (await get(s, r)).status));

  expect("reports: an agent is refused on every route", await statuses(AGENT), [403, 403, 403, 403], [200, 200, 200, 200]);
  expect("reports: the supervisor reads all but data quality", await statuses(SUPERVISOR), [200, 200, 200, 403], [200, 200, 200, 200]);
  expect("reports: the analyst reads all four", await statuses(ANALYST), [200, 200, 200, 200], [200, 200, 200, 403]);
  expect("reports: the manager reads data quality", (await get(MANAGER, routes[3])).status, 200, 403);
  const long = `from=${day(-92)}&to=${day(0)}`;
  expect("reports: more than 92 days is a 400 on every ranged route",
    await Promise.all([`/api/v1/reports/speed-to-lead?${long}&group=day`, `/api/v1/reports/speed-to-lead/rows?${long}`, `/api/v1/reports/intake?${long}`]
      .map(async (r) => (await get(ANALYST, r)).status)), [400, 400, 400], [200, 200, 200]);
  expect("reports: 92 days are answered", (await get(ANALYST, `/api/v1/reports/intake?from=${day(-91)}&to=${day(0)}`)).status, 200, 400);
  expect("reports: a backwards range is a 400", (await get(ANALYST, `/api/v1/reports/speed-to-lead/rows?from=${day(0)}&to=${day(-1)}`)).status, 400, 200);
  expect("reports: a group outside the four is a 400",
    await Promise.all(["owner", "week", "DAY"].map(async (g) => (await get(ANALYST, `/api/v1/reports/speed-to-lead?${range}&group=${g}`)).status)),
    [400, 400, 400], [200, 200, 200]);
  const grouped = await Promise.all(["day", "market", "agent", "pipeline"].map(async (g) => (await get(ANALYST, `/api/v1/reports/speed-to-lead?${range}&group=${g}`)).body?.data?.group));
  const plain = (await get(ANALYST, `/api/v1/reports/speed-to-lead?${range}`)).body?.data?.group;
  expect("reports: each group answers as itself, none means day", [...grouped, plain], ["day", "market", "agent", "pipeline", "day"], ["day", "day", "day", "day", "day"]);

  const rowsBody = (await get(ANALYST, `/api/v1/reports/speed-to-lead/rows?${range}`)).body;
  const rows = rowsBody?.data?.rows ?? [];
  const keys = new Set();
  const walk = (v) => { if (v && typeof v === "object") for (const [k, x] of Object.entries(v)) { keys.add(k.toLowerCase()); walk(x); } };
  walk(rowsBody);
  expect("reports: no field named email, phone, name or firstname in the rows",
    ["email", "phone", "name", "firstname"].filter((k) => keys.has(k)), [], ["name"]);
  expect("reports: statuses are called, not called open or closed",
    rows.every((r) => ["called", "not_called_open", "not_called_closed"].includes(r.status)), true, false);
  expect("reports: every record link is https or empty",
    rows.every((r) => r.recordUrl === null || /^https:\/\/\S+$/.test(r.recordUrl)), true, false);
  const byDay = (await get(ANALYST, `/api/v1/reports/speed-to-lead?${range}&group=day`)).body?.data?.rows ?? [];
  const sum = (xs, f) => xs.reduce((n, x) => n + f(x), 0);
  expect("reports: the summary by day adds up to the rows",
    [sum(byDay, (g) => g.deals), sum(byDay, (g) => g.called), sum(byDay, (g) => g.openNotCalled)],
    [rows.length, rows.filter((r) => r.status === "called").length, rows.filter((r) => r.status === "not_called_open").length],
    [rows.length + 1, -1, -1]);
  const byAgent = (await get(ANALYST, `/api/v1/reports/speed-to-lead?${range}&group=agent`)).body?.data?.rows ?? [];
  const unmapped = byAgent.filter((g) => g.groupKey === "unknown");
  expect("reports: agents not mapped are one group without a label, never an owner id",
    [unmapped.every((g) => g.groupLabel === null), sum(unmapped, (g) => g.deals), byAgent.every((g) => g.groupKey === "unknown" || /^[0-9a-f-]{36}$/.test(g.groupKey))],
    [true, rows.filter((r) => r.agentUserId === null).length, true], [false, -1, false]);

  // Not connected: a telephony or shop figure is null exactly when that source is not connected
  const consistent = (data) => {
    const c = data?.connections;
    if (typeof c?.telephony !== "boolean" || typeof c?.commerce !== "boolean") return false;
    return (data.rows ?? []).every((r) =>
      ["callsIn", "callsOut", "taggedCalls"].every((f) => (c.telephony ? Number.isInteger(r[f]) : r[f] === null)) &&
      ["newCustomers", "firstOrders", "repeatOrders", "renewals"].every((f) => (c.commerce ? Number.isInteger(r[f]) : r[f] === null)) &&
      ["formSubmissions", "dealsCreated", "dealsClosed", "ticketsCreated", "ticketsClosed"].every((f) => Number.isInteger(r[f])));
  };
  const intake = (await get(ANALYST, `/api/v1/reports/intake?${range}`)).body?.data;
  expect("reports: intake figures follow the tenant's connections", consistent(intake), true, false);
  const dq = (await get(ANALYST, routes[3])).body?.data ?? [];
  expect("reports: data quality lists each check once with a count",
    [dq.length > 0 && new Set(dq.map((c) => c.key)).size === dq.length, dq.every((c) => c.total === null || Number.isInteger(c.total)), dq.some((c) => c.key === "owner_without_person")],
    [true, true, true], [false, true, true]);

  // A tenant without telephony or a shop (the mock fixture and the local fixture; absent in dev)
  if ((await get(INVEST, "/api/v1/me")).status === 200) {
    const none = (await get(INVEST, `/api/v1/reports/intake?${range}`)).body?.data;
    expect("reports: without telephony and a shop those figures are null, never 0",
      [none?.connections, consistent(none), (none?.rows ?? []).some((r) => r.callsIn === 0 || r.renewals === 0)],
      [{ telephony: false, commerce: false }, true, false], [{ telephony: true, commerce: true }, true, false]);
  } else {
    console.log(`note  ${INVEST} has no access here: the check of a tenant without sources is left out`);
  }
}
