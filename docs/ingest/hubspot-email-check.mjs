/**
 * What the email poll needs to know about a HubSpot account before it is switched on (brief B17b),
 * read with the connection's static token and printed as metadata and counts only:
 *
 *   node docs/ingest/hubspot-email-check.mjs --project <gcp project> --token-secret <token secret name> [--days 30]
 *
 *   1. the email engagement properties the ingest reads (GET /crm/v3/properties/emails): present or
 *      not, their type, and the option values of hs_email_direction and hs_email_status
 *   2. the candidates for the connection settings email_thread_property and email_origin_property:
 *      every email property whose name or label speaks of a thread, a sequence, an origin, a source,
 *      logging, an automation or a workflow, with its label, type and option values
 *   3. the actor id prefixes of the inbox conversations of the last --days days (default 30): per
 *      prefix the actor type HubSpot gives it (POST /conversations/v3/conversations/actors/batch/read)
 *      and how many actors have it. Never an actor id, a name or an address: the ids are held in
 *      memory to ask for their type, and only the prefix (the letters before the first hyphen) and
 *      the type are counted
 *   4. the conversations' inboxes (id, name, archived) and channels (id, name), so they can be configured
 *      (cma.set_inbox, cma.set_inbox_channel) before the first poll; a name that holds an address is
 *      not printed
 *
 * Reads the token from Secret Manager with your own gcloud login (held in memory, never printed).
 * Needs the app's scopes crm.objects.emails.read and conversations.read (a 403 names the call). Writes
 * nothing anywhere. Output to the terminal only.
 */
import { execFileSync } from "node:child_process";

function arg(name) {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : undefined;
}
const usage = "usage: node docs/ingest/hubspot-email-check.mjs --project <gcp project> --token-secret <token secret name> [--days 30]";
const project = arg("project");
const tokenSecret = arg("token-secret");
const days = Number(arg("days") ?? 30);
if (!project || !tokenSecret || !/^[a-z][a-z0-9-]{4,29}$/.test(project) || !/^[A-Za-z0-9_-]{1,255}$/.test(tokenSecret)
    || !Number.isInteger(days) || days < 1 || days > 365) {
  console.error(usage);
  process.exit(2);
}

let token = execFileSync("gcloud", ["secrets", "versions", "access", "latest", `--secret=${tokenSecret}`, `--project=${project}`],
  { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] }).trim();
const base = process.env.INGEST_HUBSPOT_API_BASE ?? "https://api.hubapi.com";
async function call(method, path, body) {
  const res = await fetch(`${base}${path}`, {
    method, headers: { authorization: `Bearer ${token}`, ...(body ? { "content-type": "application/json" } : {}) }, body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok && res.status !== 207) {
    console.error(`HubSpot answered ${res.status} for ${method} ${path.split("?")[0].replace(/\/\d+(\/|$)/g, "/<id>$1")}`);
    process.exit(1);
  }
  return res.json();
}
const pad = (s, n) => String(s ?? "").padEnd(n);
const options = (p) => (p?.options ?? []).map((o) => o.value).filter((v) => typeof v === "string" && !v.includes("@")).join(", ");

// 1 and 2: the properties
const props = (await call("GET", "/crm/v3/properties/emails"))?.results ?? [];
const byName = new Map(props.map((p) => [p.name, p]));
const USED = ["hs_timestamp", "hs_email_direction", "hs_email_status", "hubspot_owner_id", "hs_createdate", "hs_lastmodifieddate", "hs_email_subject", "hs_email_from_email"];
console.log("== 1. email engagement properties the ingest reads");
for (const name of USED) {
  const p = byName.get(name);
  console.log(`${pad(name, 28)} ${pad(p ? p.type : "", 12)} ${p ? "present" : "MISSING"}${p && options(p) ? `   options: ${options(p)}` : ""}`);
}
console.log("\n== 2. candidates for email_thread_property and email_origin_property");
const CANDIDATE = /thread|sequence|origin|source|logged|automat|workflow/i;
const candidates = props.filter((p) => CANDIDATE.test(p.name) || CANDIDATE.test(p.label ?? "")).sort((a, b) => a.name.localeCompare(b.name));
for (const p of candidates) console.log(`${pad(p.name, 40)} ${pad(JSON.stringify(p.label ?? ""), 40)} ${pad(p.type, 12)}${options(p) ? ` options: ${options(p)}` : ""}`);
if (!candidates.length) console.log("(none)");

// 3: the actor id prefixes
const after = new Date(Date.now() - days * 24 * 60 * 60_000).toISOString();
const ids = new Set();
let page;
let threads = 0;
for (let i = 0; i < 20; i += 1) {
  const qs = new URLSearchParams({ sort: "latestMessageTimestamp", latestMessageTimestampAfter: after, limit: "50", ...(page ? { after: page } : {}) });
  const r = await call("GET", `/conversations/v3/conversations/threads?${qs}`);
  for (const t of r?.results ?? []) {
    threads += 1;
    if (t.assignedTo) ids.add(String(t.assignedTo));
    let next;
    for (let j = 0; j < 10; j += 1) {
      const m = await call("GET", `/conversations/v3/conversations/threads/${encodeURIComponent(t.id)}/messages?limit=100${next ? `&after=${encodeURIComponent(next)}` : ""}`);
      for (const x of m?.results ?? []) for (const a of [x.createdBy, x.assignedTo, x.assignedFrom]) if (a) ids.add(String(a));
      next = m?.paging?.next?.after;
      if (!next) break;
    }
  }
  page = r?.paging?.next?.after;
  if (!page || threads >= 200) break;
}
const counts = new Map();
const list = [...ids];
for (let i = 0; i < list.length; i += 100) {
  const r = await call("POST", "/conversations/v3/conversations/actors/batch/read", { inputs: list.slice(i, i + 100) });
  for (const a of r?.results ?? []) {
    const prefix = /^([A-Za-z]{1,3})-/.exec(String(a.id ?? ""))?.[1] ?? "(none)";
    const k = `${prefix}|${String(a.type ?? "?")}`;
    counts.set(k, (counts.get(k) ?? 0) + 1);
  }
}
ids.clear();
console.log(`\n== 3. actor id prefixes in ${threads} thread(s) of the last ${days} days (prefix, HubSpot's type, actors)`);
for (const [k, n] of [...counts.entries()].sort()) {
  const [prefix, type] = k.split("|");
  console.log(`${pad(prefix, 8)} ${pad(type, 12)} ${n}`);
}
if (!counts.size) console.log("(no actors: no conversation in that period)");

// 4: inboxes and channels
const listAll = async (path) => {
  const out = [];
  let next;
  for (let i = 0; i < 20; i += 1) {
    const r = await call("GET", `/conversations/v3/conversations/${path}?limit=100${next ? `&after=${encodeURIComponent(next)}` : ""}`);
    out.push(...(r?.results ?? []));
    next = r?.paging?.next?.after;
    if (!next) break;
  }
  return out;
};
const nameOf = (n) => (String(n ?? "").includes("@") ? "(the name holds an address; not shown)" : JSON.stringify(String(n ?? "")));
console.log("\n== 4. inboxes (id, name, archived) and channels (id, name)");
for (const i of await listAll("inboxes")) console.log(`inbox    ${pad(i.id, 14)} ${pad(nameOf(i.name), 44)} ${i.archived === true ? "archived" : ""}`.trimEnd());
for (const c of await listAll("channels")) console.log(`channel  ${pad(c.id, 14)} ${nameOf(c.name)}`);
token = null;
