#!/usr/bin/env node
/**
 * Legacy sessions to the CMA's staging shape (addition 0008d, docs/import/README.md).
 *
 *   node tools/legacy-sessions-to-staging.mjs <export.csv> --map <map.csv> --zone <IANA zone>
 *        --batch <key> --out <staging.csv> [--map-sql <person-map.sql>] [options]
 *
 *   node tools/legacy-sessions-to-staging.mjs <export.csv> --map-template <map.csv> [options]
 *        writes a map to fill in: one row per account of the export (steam_pid, steam_name, its
 *        sessions, first and last day), work_email and include empty. Extra columns are ignored.
 *
 * Reads a login and logout export of an earlier system and writes the file that is copied into
 * cma.import_session_staging: batch_key, external_person_id, external_person_name,
 * external_session_id, login_local, logout_local, role, with ISO local timestamps (no offset; the
 * batch names the zone). Plain Node, no dependencies.
 *
 * The export (defaults; every column name and the date format are options):
 *   --col-person-id   PersoneelsPID      the account's id in the earlier system
 *   --col-person-name Personeel          its name as that system shows it
 *   --col-login       Ingelogd           the login, local time
 *   --col-logout      Uitgelogd          the logout, local time; empty for a session never logged out
 *   --col-duration    Ingelogde tijd     the logged-in time as h:mm:ss, used for a consistency count only
 *   --col-session-id  Sessie-ID          the session's id, unique in the file
 *   --col-role        Functie            the account's role in that system (optional column)
 *   --date-format     d-m-yyyy hh:mm:ss  date tokens d dd m mm yyyy, time tokens h hh mm ss
 *   --delimiter       auto               ; , or tab; auto picks the one the header line holds most
 *   --dedupe-sessions latest-logout      off by default: a session id that appears more than once,
 *                                        each time with the same account and login, keeps the row
 *                                        with the latest logout (no logout counts as latest); the
 *                                        rows dropped are counted as sessions_deduplicated
 * Line ends CRLF or LF, an optional UTF-8 byte order mark, quoted fields as in RFC 4180.
 *
 * The map (a header, then one row per account): steam_pid,work_email,include
 *   include is yes or no (also true/false, 1/0, ja/nee). Accounts absent from the map or with
 *   include = no are dropped and counted. The tool never resolves an email: --map-sql writes the
 *   Studio statement that matches the included accounts' emails to people at load time.
 *
 * Refuses (exit 1, nothing written) a row without a person id, session id or login, a time that
 * does not parse, a logout before its login, a duplicate session id (with --dedupe-sessions: one
 * whose rows differ in account or login), and a local time that does not exist in the zone (the
 * spring clock change); the database refuses the last one too. Prints counts
 * only, never a name or an email.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export const DEFAULT_COLUMNS = {
  personId: "PersoneelsPID",
  personName: "Personeel",
  login: "Ingelogd",
  logout: "Uitgelogd",
  duration: "Ingelogde tijd",
  sessionId: "Sessie-ID",
  role: "Functie",
};
export const DEFAULT_DATE_FORMAT = "d-m-yyyy hh:mm:ss";
export const STAGING_HEADER = ["batch_key", "external_person_id", "external_person_name", "external_session_id", "login_local", "logout_local", "role"];

// ---- CSV ------------------------------------------------------------------------------------

/** The delimiter the header line holds most of: ; , or tab */
export function detectDelimiter(text) {
  const first = text.replace(/^﻿/, "").split(/\r?\n/, 1)[0] ?? "";
  const counts = [";", ",", "\t"].map((d) => [d, first.split(d).length - 1]);
  counts.sort((a, b) => b[1] - a[1]);
  return counts[0][1] > 0 ? counts[0][0] : ",";
}

/** RFC 4180 rows: quoted fields with "" for a quote, CRLF or LF, a leading byte order mark dropped */
export function parseCsv(text, delimiter) {
  const s = text.replace(/^﻿/, "");
  const rows = [];
  let row = [];
  let field = "";
  let quoted = false;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (quoted) {
      if (c === '"' && s[i + 1] === '"') { field += '"'; i++; }
      else if (c === '"') quoted = false;
      else field += c;
    } else if (c === '"' && field === "") quoted = true;
    else if (c === delimiter) { row.push(field); field = ""; }
    else if (c === "\n" || c === "\r") {
      if (c === "\r" && s[i + 1] === "\n") i++;
      row.push(field); field = "";
      if (row.length > 1 || row[0] !== "") rows.push(row);
      row = [];
    } else field += c;
  }
  if (field !== "" || row.length) { row.push(field); if (row.length > 1 || row[0] !== "") rows.push(row); }
  return rows;
}

const csvCell = (v) => (/[",\r\n]/.test(v) ? `"${v.replaceAll('"', '""')}"` : v);

// ---- times ----------------------------------------------------------------------------------

/**
 * A parser for one date format: "d-m-yyyy hh:mm:ss", "yyyy-mm-dd hh:mm:ss", "dd/mm/yyyy hh:mm".
 * The part before the space is the date (d, dd, m, mm, yyyy), the part after it the time (h, hh,
 * mm, ss), so mm is the month in the one and the minutes in the other. A day, month or hour reads
 * with one or two digits, padded or not; minutes and seconds need two.
 */
export function dateParser(format) {
  const [datePart, timePart = ""] = format.trim().split(/\s+/, 2);
  const groups = [];
  const esc = (ch) => ch.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&");
  const build = (part, tokens, isTime) => part.replace(new RegExp(`(${tokens.join("|")})|(.)`, "g"), (_, tok, other) => {
    if (other !== undefined) return esc(other);
    groups.push(tok);
    return tok === "yyyy" ? "(\\d{4})" : isTime && (tok === "mm" || tok === "ss") ? "(\\d{2})" : "(\\d{1,2})";
  });
  const dateRe = build(datePart, ["yyyy", "dd", "mm", "d", "m"], false);
  const dateGroups = groups.splice(0);
  const timeRe = timePart ? build(timePart, ["hh", "mm", "ss", "h"], true) : "";
  const timeGroups = groups.splice(0);
  const re = new RegExp(`^${dateRe}${timePart ? `\\s+${timeRe}` : ""}$`);
  return (value) => {
    const m = re.exec(value.trim());
    if (!m) return null;
    const v = { y: 0, mo: 0, d: 0, h: 0, mi: 0, s: 0 };
    dateGroups.forEach((g, i) => {
      const n = Number(m[i + 1]);
      if (g === "yyyy") v.y = n; else if (g[0] === "d") v.d = n; else v.mo = n;
    });
    timeGroups.forEach((g, i) => {
      const n = Number(m[dateGroups.length + i + 1]);
      if (g[0] === "h") v.h = n; else if (g === "mm") v.mi = n; else v.s = n;
    });
    const probe = new Date(Date.UTC(v.y, v.mo - 1, v.d, v.h, v.mi, v.s));
    if (probe.getUTCFullYear() !== v.y || probe.getUTCMonth() !== v.mo - 1 || probe.getUTCDate() !== v.d
        || probe.getUTCHours() !== v.h || probe.getUTCMinutes() !== v.mi || probe.getUTCSeconds() !== v.s) return null;
    const p = (n, w = 2) => String(n).padStart(w, "0");
    return `${p(v.y, 4)}-${p(v.mo)}-${p(v.d)}T${p(v.h)}:${p(v.mi)}:${p(v.s)}`;
  };
}

/** Seconds of "h:mm:ss" or "hh:mm", null when empty or malformed */
export function durationSeconds(value) {
  const m = /^\s*(\d+):(\d{2})(?::(\d{2}))?\s*$/.exec(value ?? "");
  return m ? Number(m[1]) * 3600 + Number(m[2]) * 60 + Number(m[3] ?? 0) : null;
}

const wallFormatters = new Map();

/** Wall clock of an instant in a zone, as an ISO local timestamp */
function wallClock(ms, zone) {
  let f = wallFormatters.get(zone);
  if (!f) {
    f = new Intl.DateTimeFormat("en-CA", {
      timeZone: zone, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23",
    });
    wallFormatters.set(zone, f);
  }
  const p = Object.fromEntries(f.formatToParts(new Date(ms)).map((x) => [x.type, x.value]));
  return `${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}:${p.second}`;
}

/** The instant a local time stands for in a zone (the earlier one in the repeated autumn hour), or null in the skipped spring hour */
export function instantOf(local, zone) {
  const asUtc = Date.parse(`${local}Z`);
  const offsetAt = (ms) => Date.parse(`${wallClock(ms, zone)}Z`) - ms;
  const candidates = [...new Set([offsetAt(asUtc - 86_400_000), offsetAt(asUtc + 86_400_000)])].sort((a, b) => b - a);
  for (const o of candidates) if (wallClock(asUtc - o, zone) === local) return asUtc - o;
  return null;
}

/** True when the local time occurs in the zone (false in the hour skipped at the spring change) */
export function existsInZone(local, zone) {
  return instantOf(local, zone) !== null;
}

/** Seconds between two ISO local timestamps in a zone, counting the clock change */
function localSeconds(from, to, zone) {
  return Math.round(((instantOf(to, zone) ?? 0) - (instantOf(from, zone) ?? 0)) / 1000);
}

// ---- the conversion -------------------------------------------------------------------------

const YES = new Set(["yes", "true", "1", "ja", "y"]);
const NO = new Set(["no", "false", "0", "nee", "n"]);

/** The map file: pid → { email, include } */
export function readMap(text) {
  const rows = parseCsv(text, detectDelimiter(text));
  const header = (rows.shift() ?? []).map((h) => h.trim().toLowerCase());
  const at = (name) => header.indexOf(name);
  if (at("steam_pid") < 0 || at("work_email") < 0 || at("include") < 0) {
    throw new Error("the map needs the header steam_pid,work_email,include");
  }
  const map = new Map();
  const problems = [];
  rows.forEach((r, i) => {
    const pid = (r[at("steam_pid")] ?? "").trim();
    const email = (r[at("work_email")] ?? "").trim().toLowerCase();
    const inc = (r[at("include")] ?? "").trim().toLowerCase();
    if (!pid) problems.push(`map line ${i + 2}: no steam_pid`);
    else if (map.has(pid)) problems.push(`map line ${i + 2}: steam_pid appears twice`);
    else if (!YES.has(inc) && !NO.has(inc)) problems.push(`map line ${i + 2}: include must be yes or no`);
    else if (YES.has(inc) && !/^[^@\s]+@[^@\s]+$/.test(email)) problems.push(`map line ${i + 2}: an included account needs a work email`);
    else map.set(pid, { email, include: YES.has(inc) });
  });
  return { map, problems };
}

/**
 * The export and the map to staging rows and counts. Pure: no file access.
 * options: { batch, zone, columns, dateFormat, delimiter, dedupeSessions }
 * dedupeSessions "latest-logout": per session id the row with the latest logout (an open one counts
 * as latest; on a tie the first), when every row of that id has the same account and login.
 */
export function convert(exportText, mapText, options) {
  const columns = { ...DEFAULT_COLUMNS, ...(options.columns ?? {}) };
  const delimiter = options.delimiter && options.delimiter !== "auto" ? options.delimiter : detectDelimiter(exportText);
  const parse = dateParser(options.dateFormat ?? DEFAULT_DATE_FORMAT);
  const { map, problems } = readMap(mapText);
  const rows = parseCsv(exportText, delimiter);
  const header = (rows.shift() ?? []).map((h) => h.trim());
  const col = Object.fromEntries(Object.entries(columns).map(([k, name]) => [k, header.indexOf(name)]));
  for (const k of ["personId", "login", "logout", "sessionId"]) {
    if (col[k] < 0) problems.push(`the export has no column "${columns[k]}" (${k})`);
  }
  if (problems.length) return { problems, rows: [], counts: null };

  const sessions = new Map();
  let deduplicated = 0;
  rows.forEach((r, i) => {
    const line = i + 2;
    const cell = (k) => (col[k] >= 0 ? (r[col[k]] ?? "").trim() : "");
    const pid = cell("personId");
    const sid = cell("sessionId");
    if (!pid) { problems.push(`line ${line}: no person id`); return; }
    if (!sid) { problems.push(`line ${line}: no session id`); return; }
    const earlier = sessions.get(sid);
    if (earlier && options.dedupeSessions !== "latest-logout") { problems.push(`line ${line}: session id ${sid} appears twice`); return; }
    const login = parse(cell("login"));
    const logoutText = cell("logout");
    const logout = logoutText ? parse(logoutText) : null;
    if (!login) { problems.push(`line ${line}: the login does not read as ${options.dateFormat ?? DEFAULT_DATE_FORMAT}`); return; }
    if (logoutText && !logout) { problems.push(`line ${line}: the logout does not read as ${options.dateFormat ?? DEFAULT_DATE_FORMAT}`); return; }
    if (logout && logout < login) { problems.push(`line ${line}: session ${sid} logs out before it logs in`); return; }
    for (const t of [login, logout]) {
      if (t && !existsInZone(t, options.zone)) problems.push(`line ${line}: session ${sid} at ${t.replace("T", " ")} does not exist in ${options.zone} (spring clock change)`);
    }
    const session = { pid, sid, login, logout, name: cell("personName"), role: cell("role"), duration: cell("duration") };
    if (earlier) {
      if (earlier.pid !== pid || earlier.login !== login) { problems.push(`line ${line}: session id ${sid} appears twice with another account or login`); return; }
      deduplicated++;
      // Map.set on a known key keeps its place, so the staging file keeps the export's order
      if (earlier.logout !== null && (logout === null || logout > earlier.logout)) sessions.set(sid, session);
      return;
    }
    sessions.set(sid, session);
  });

  const accounts = new Set();
  const dropped = { absent: new Set(), excluded: new Set() };
  const out = [];
  let open = 0;
  let durationOff = 0;
  let first = null;
  let last = null;
  for (const { pid, sid, login, logout, name, role, duration } of sessions.values()) {
    accounts.add(pid);
    const m = map.get(pid);
    if (!m) { dropped.absent.add(pid); continue; }
    if (!m.include) { dropped.excluded.add(pid); continue; }
    if (!logout) open++;
    const d = durationSeconds(duration);
    if (logout && d !== null && Math.abs(localSeconds(login, logout, options.zone) - d) > 60) durationOff++;
    const date = login.slice(0, 10);
    if (!first || date < first) first = date;
    if (!last || date > last) last = date;
    out.push([options.batch, pid, name, sid, login, logout ?? "", role]);
  }

  const included = new Set(out.map((r) => r[1]));
  const counts = {
    rows_read: rows.length,
    sessions_deduplicated: deduplicated,
    sessions_written: out.length,
    sessions_open: open,
    sessions_dropped: rows.length - deduplicated - out.length,
    accounts_in_export: accounts.size,
    accounts_written: included.size,
    accounts_absent_from_map: dropped.absent.size,
    accounts_excluded: dropped.excluded.size,
    map_rows_without_sessions: [...map.keys()].filter((p) => !accounts.has(p)).length,
    sessions_duration_differs: durationOff,
    period_from: first,
    period_to: last,
  };
  return { problems, rows: out, counts, included: [...included].sort().map((pid) => [pid, map.get(pid).email]) };
}

/** A map to fill in: every account of the export with its name, sessions and days; email and include empty */
export function mapTemplate(exportText, options) {
  const columns = { ...DEFAULT_COLUMNS, ...(options.columns ?? {}) };
  const delimiter = options.delimiter && options.delimiter !== "auto" ? options.delimiter : detectDelimiter(exportText);
  const parse = dateParser(options.dateFormat ?? DEFAULT_DATE_FORMAT);
  const rows = parseCsv(exportText, delimiter);
  const header = (rows.shift() ?? []).map((h) => h.trim());
  const at = (k) => header.indexOf(columns[k]);
  if (at("personId") < 0) return { problems: [`the export has no column "${columns.personId}" (personId)`], text: null, accounts: 0 };
  const accounts = new Map();
  for (const r of rows) {
    const pid = (r[at("personId")] ?? "").trim();
    if (!pid) continue;
    const a = accounts.get(pid) ?? { name: (r[at("personName")] ?? "").trim(), sessions: 0, first: null, last: null };
    const day = at("login") >= 0 ? parse((r[at("login")] ?? "").trim())?.slice(0, 10) ?? null : null;
    a.sessions++;
    if (day && (!a.first || day < a.first)) a.first = day;
    if (day && (!a.last || day > a.last)) a.last = day;
    accounts.set(pid, a);
  }
  const lines = [["steam_pid", "work_email", "include", "steam_name", "sessions", "first_day", "last_day"],
    ...[...accounts].sort(([a], [b]) => a.localeCompare(b, "en", { numeric: true }))
      .map(([pid, a]) => [pid, "", "", a.name, String(a.sessions), a.first ?? "", a.last ?? ""])];
  return { problems: [], text: lines.map((l) => l.map(csvCell).join(",")).join("\n") + "\n", accounts: accounts.size };
}

/** The staging file: a header, LF line ends, cells quoted where needed */
export function stagingCsv(rows) {
  return [STAGING_HEADER, ...rows].map((r) => r.map(csvCell).join(",")).join("\n") + "\n";
}

/** The Studio statement that maps the included accounts to people by email (one-off, admin only) */
export function personMapSql(batch, included) {
  const lit = (v) => `'${v.replaceAll("'", "''")}'`;
  const values = included.map(([pid, email]) => `    (${lit(pid)}, ${lit(email)})`).join(",\n");
  return `-- Person map for import batch ${batch}: run in Studio after the context block (set role cma_app,
-- app.tenant_id, app.user_id of a person holding tenant.configure). Rerun-safe. Delete this file after the load.
with m (external_person_id, email) as (values
${values}
),
ins as (
  insert into cma.import_person_map (batch_id, external_person_id, user_id)
  select b.id, m.external_person_id, u.id
  from m
  join cma.import_batch b on b.tenant_id = cma.current_tenant_id() and b.key = ${lit(batch)}
  join cma.app_user u on u.tenant_id = b.tenant_id and u.email = lower(m.email) and u.kind = 'person'
  on conflict do nothing
  returning external_person_id
)
select (select count(*) from m) as accounts_in_map,
       (select count(*) from ins) as rows_written,
       (select count(*) from m where not exists (select 1 from cma.app_user u
                                                 where u.tenant_id = cma.current_tenant_id() and u.email = lower(m.email))) as emails_without_person;
`;
}

// ---- the command ----------------------------------------------------------------------------

function args(argv) {
  const o = { files: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) o[a.slice(2)] = argv[++i];
    else o.files.push(a);
  }
  return o;
}

export function main(argv) {
  const o = args(argv);
  const [exportPath] = o.files;
  const columns = {};
  for (const [k, flag] of [["personId", "col-person-id"], ["personName", "col-person-name"], ["login", "col-login"], ["logout", "col-logout"],
                           ["duration", "col-duration"], ["sessionId", "col-session-id"], ["role", "col-role"]]) {
    if (o[flag]) columns[k] = o[flag];
  }
  const delimiter = o.delimiter === "tab" ? "\t" : o.delimiter;
  if (exportPath && o["map-template"]) {
    const t = mapTemplate(readFileSync(exportPath, "utf8"), { columns, dateFormat: o["date-format"], delimiter });
    if (t.problems.length) { console.error(`refused, nothing written: ${t.problems.join("; ")}`); return 1; }
    writeFileSync(o["map-template"], t.text);
    console.log(`accounts_in_export           ${t.accounts}\nmap to fill in               ${o["map-template"]}`);
    return 0;
  }
  if (!exportPath || !o.map || !o.zone || !o.batch || !o.out) {
    console.error("usage: legacy-sessions-to-staging.mjs <export.csv> --map <map.csv> --zone <IANA zone> --batch <key> --out <staging.csv> [--map-sql <file>] [--dedupe-sessions latest-logout]");
    return 2;
  }
  if (o["dedupe-sessions"] !== undefined && o["dedupe-sessions"] !== "latest-logout") {
    console.error("--dedupe-sessions takes one value: latest-logout");
    return 2;
  }
  if (!/^[a-z0-9_-]+$/.test(o.batch) || o.batch.length > 64) {
    console.error("the batch key is lowercase letters, digits, - and _, at most 64");
    return 2;
  }
  try { new Intl.DateTimeFormat("en", { timeZone: o.zone }); } catch { console.error(`unknown time zone ${o.zone}`); return 2; }
  const result = convert(readFileSync(exportPath, "utf8"), readFileSync(o.map, "utf8"),
    { batch: o.batch, zone: o.zone, columns, dateFormat: o["date-format"], delimiter, dedupeSessions: o["dedupe-sessions"] });
  if (result.problems.length) {
    console.error(`refused, nothing written: ${result.problems.length} problem(s)`);
    for (const p of result.problems.slice(0, 20)) console.error(`  ${p}`);
    if (result.problems.length > 20) console.error(`  … and ${result.problems.length - 20} more`);
    return 1;
  }
  writeFileSync(o.out, stagingCsv(result.rows));
  if (o["map-sql"]) writeFileSync(o["map-sql"], personMapSql(o.batch, result.included));
  for (const [k, v] of Object.entries(result.counts)) console.log(`${k.padEnd(28)} ${v}`);
  console.log(`staging file                 ${o.out}${o["map-sql"] ? `\nperson map statement         ${o["map-sql"]}` : ""}`);
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  process.exit(main(process.argv.slice(2)));
}
