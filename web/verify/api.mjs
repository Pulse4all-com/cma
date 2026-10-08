/**
 * Verifier: the API against the dev database (verify-by-breaking).
 *
 * Runs against a cma-web in mock auth mode with CMA_DATA_MODE=api, through the tunnel:
 *   gcloud run services proxy cma-web --project=p4a-cma-dev --region=europe-west4 --port=8080 &
 *   node verify/api.mjs              every check must PASS
 *   node verify/api.mjs --provoke    every check gets a deliberately wrong expectation and must FAIL
 * Env: BASE (default http://localhost:8080).
 *
 * Needs the dev seeds (06, 24) and migrations 0003 to 0003e, 0004 and 0005. Ends the test supervisor's workday of today and, as
 * the supervisor, closes Agent Two's open past days (the verifier's own earlier logins) through the
 * corrections route, so no fixture runs first. Adds one day per run for Agent Two on the first free
 * date more than 400 days back (dev data). Safe to rerun on the same day.
 *
 * Themes: identity and tenant, Clock in as an action (a visit opens nothing, the database refuses
 * someone whose time is not kept), own data only, corrections (team routes), an ended day stays
 * ended, status changes from the tenant's own list, the two export files in the tenant's format,
 * time per status for the Dashboard (the same minutes as Team hours), app links per person, the
 * team now for the Live board (a person's own entry equals the own-day read), the Team screen
 * (migration 0004: who is listed and editable, roles, teams, skills, adding a person) and the
 * memberships for the Live board's team filter.
 */
const BASE = process.env.BASE ?? "http://localhost:8080";
const PROVOKE = process.argv.includes("--provoke");

// Dev seed subjects (system "mock")
const TWO_TENANTS = "agent-one";   // exists in two tenants: must never be guessed
const AGENT = "agent-two";
const SUPERVISOR = "supervisor";
const MANAGER = "manager";         // holds workday.export from the default ladder (0003b)
const ANALYST = "analyst";         // analytics: no workday.own, so the database keeps no time for them (0003d)
const ADMIN = "admin";             // admin (0004): users.manage_all and tenant.configure
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

// ---- clock in is an action (increment e, addition 0003d), 6 checks ---------------------------
// The analyst holds performance.team and no workday.own: a visit to the landing page and to My day
// opens nothing, and the start route is refused by the database (CMA06), not by the route.
await visit(ANALYST, "/");
await visit(ANALYST, "/day");
expect("a visit opens no workday", (await get(ANALYST, "/api/v1/me/day")).body?.data ?? null, null, "a day");
expect("the database keeps no time for someone without a clock", (await start(ANALYST)).status, 403, 200);
expect("start needs the request header", (await start(AGENT, {})).status, 400, 200);
expect("cross-site start is refused",
  (await start(AGENT, { "x-cma-request": "1", "sec-fetch-site": "cross-site" })).status, 403, 200);
const started = (await start(AGENT)).body?.data;
const startedAgain = (await start(AGENT)).body?.data;
expect("start opens the own day today", [started?.date, started?.status === "working" || started?.status === "ended"],
  [dateKey(new Date(), meA.timeZone), true], [dateKey(new Date(), meA.timeZone), false]);
expect("a second start is the same day", startedAgain?.startedAt === started?.startedAt, true, false);

// ---- own data only -------------------------------------------------------------------------
await start(SUPERVISOR);
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
