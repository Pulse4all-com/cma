/**
 * Aircall users → the Studio statements that put each agent's Aircall user id on their CMA person
 * (system aircall_user), for attribution and the data-quality check "telephony users without a
 * person" (DESIGN §3, §4.4; PROD_RUNBOOK 8.7; brief B9).
 *
 *   node docs/ingest/aircall-users.mjs --project <gcp project> --api-secret <Aircall token secret> \
 *        [--via-owners <HubSpot token secret>] [--also-domain <from>=<to>]...
 *
 * Reads the Aircall API key (JSON {"api_id","api_token"}) from Secret Manager with your own gcloud
 * login, held in memory and never printed, and lists the users through GET /v1/users (id and email,
 * in memory only).
 *
 * --via-owners <HubSpot token secret>: also lists the active HubSpot owners with that token (GET
 * /crm/v3/owners) and matches an Aircall user's email to an owner's email; per match one statement
 * that finds the person by the HubSpot owner id already on them (PROD_RUNBOOK 7.6), so no email is
 * in the output:
 *
 *   select cma.set_user_external_id(x.user_id, 'aircall_user', '<aircall user id>') from cma.app_user_external_id x where x.system = 'hubspot_owner' and x.external_id = '<owner id>';
 *
 * Without it, one statement per user by email, as hubspot-owners.mjs does:
 *
 *   select cma.set_user_external_id(u.id, 'aircall_user', '<aircall user id>') from cma.app_user u where u.email = '<email>';
 *
 * --also-domain <from>=<to> (repeatable): an address on <from> also matches the same local part on
 * <to>, in the email statement (u.email in (…)) and in the owner match, so a Newco agent whose
 * Aircall or HubSpot address is on another domain than their CMA identity is found too.
 *
 * Then on stderr: the count matched, and the Aircall user ids NOT matched (ids only, no emails), to be
 * linked by hand on Team → People → Linked accounts. Paste the statements into Studio after the
 * runbook's context block (a person who may edit the people concerned): row-level security keeps them
 * to that tenant, and a statement that matches no person changes nothing. Staff data: the output goes
 * to the terminal only, never to a file.
 *
 * INGEST_AIRCALL_API_BASE and INGEST_HUBSPOT_API_BASE (https, or http on localhost) replace the APIs'
 * addresses for fakes in the verifier (ingest/verify/aircall-scripts.mjs).
 */
import { execFileSync } from "node:child_process";

function arg(name) {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : undefined;
}
function args(name) {
  return process.argv.flatMap((a, i) => (a === `--${name}` ? [process.argv[i + 1]] : []));
}
const usage = "usage: node docs/ingest/aircall-users.mjs --project <gcp project> --api-secret <Aircall token secret> [--via-owners <HubSpot token secret>] [--also-domain <from>=<to>]...";
const SECRET = /^[A-Za-z0-9_-]{1,255}$/;
const project = arg("project");
const apiSecret = arg("api-secret");
const viaOwners = arg("via-owners");
if (!project || !/^[a-z][a-z0-9-]{4,29}$/.test(project) || !apiSecret || !SECRET.test(apiSecret) || (process.argv.includes("--via-owners") && !SECRET.test(viaOwners ?? ""))) {
  console.error(usage);
  process.exit(2);
}
const DOMAIN = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/;
const alsoDomain = new Map(); // <from> → <to>
for (const pair of args("also-domain")) {
  const [from, to, extra] = String(pair ?? "").toLowerCase().split("=");
  if (extra !== undefined || !DOMAIN.test(from ?? "") || !DOMAIN.test(to ?? "") || from === to || alsoDomain.has(from)) {
    console.error(`--also-domain ${pair ?? ""} is not <from>=<to> with two different domains, each <from> once`);
    console.error(usage);
    process.exit(2);
  }
  alsoDomain.set(from, to);
}

function checkedBase(value, fallback) {
  const b = new URL(value ?? fallback);
  if (b.protocol !== "https:" && !(b.protocol === "http:" && ["127.0.0.1", "localhost"].includes(b.hostname))) {
    console.error("an API base must be https");
    process.exit(2);
  }
  return b.origin;
}
const aircallBase = checkedBase(process.env.INGEST_AIRCALL_API_BASE, "https://api.aircall.io");
const hubspotBase = checkedBase(process.env.INGEST_HUBSPOT_API_BASE, "https://api.hubapi.com");

const secretOf = (name) => execFileSync("gcloud", ["secrets", "versions", "access", "latest", `--secret=${name}`, `--project=${project}`],
  { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] }).trim();

async function getJson(url, authorization, what) {
  const res = await fetch(url, { headers: { authorization, accept: "application/json" } });
  if (!res.ok) {
    console.error(`${what} answered ${res.status}`);
    process.exit(1);
  }
  return res.json();
}

// Aircall users: id and email, in memory only
let key;
try {
  key = JSON.parse(secretOf(apiSecret));
} catch {
  console.error(`could not read ${apiSecret} as {"api_id","api_token"}`);
  process.exit(1);
}
let aircallAuth = `Basic ${Buffer.from(`${key?.api_id}:${key?.api_token}`).toString("base64")}`;
key = null;
const users = [];
for (let page = 1; page <= 100; page += 1) {
  const r = await getJson(`${aircallBase}/v1/users?per_page=50&page=${page}`, aircallAuth, "Aircall, for the users list,");
  users.push(...(r.users ?? []));
  if (!r.meta?.next_page_link || !(r.users ?? []).length) break;
}
aircallAuth = null;

const sqlText = (s) => s.replace(/'/g, "''");
const EMAIL = /^[^\s@']+@[^\s@']+$/;
const emailOf = (v) => {
  const e = String(v ?? "").trim().toLowerCase();
  return EMAIL.test(e) ? e : null;
};
/** The addresses an email stands for: itself, and the same local part on the --also-domain partner. */
function forms(email) {
  const [local, domain] = email.split("@");
  const out = new Set([email]);
  if (alsoDomain.has(domain)) out.add(`${local}@${alsoDomain.get(domain)}`);
  for (const [from, to] of alsoDomain) if (to === domain) out.add(`${local}@${from}`);
  return [...out];
}

const valid = users.map((u) => ({ id: String(u?.id ?? ""), email: emailOf(u?.email) })).filter((u) => /^\d{1,30}$/.test(u.id));
const unmatched = [];
let matched = 0;

if (viaOwners) {
  let token = secretOf(viaOwners);
  const owners = [];
  let after;
  do {
    const page = await getJson(`${hubspotBase}/crm/v3/owners?limit=100&archived=false${after ? `&after=${encodeURIComponent(after)}` : ""}`, `Bearer ${token}`, "HubSpot, for the owners list,");
    owners.push(...(page.results ?? []));
    after = page.paging?.next?.after;
  } while (after);
  token = null;
  const ownerByEmail = new Map();
  for (const o of owners) {
    const email = emailOf(o?.email);
    const id = String(o?.id ?? "");
    if (email && /^\d{1,30}$/.test(id) && !ownerByEmail.has(email)) ownerByEmail.set(email, id);
  }
  for (const u of valid) {
    const ownerIds = u.email ? [...new Set(forms(u.email).map((e) => ownerByEmail.get(e)).filter(Boolean))] : [];
    if (ownerIds.length !== 1) {
      unmatched.push(u.id);
      continue;
    }
    console.log(`select cma.set_user_external_id(x.user_id, 'aircall_user', '${u.id}') from cma.app_user_external_id x where x.system = 'hubspot_owner' and x.external_id = '${ownerIds[0]}';`);
    matched += 1;
  }
  console.error(`-- ${matched} Aircall user(s) matched to a HubSpot owner, of ${valid.length}`);
} else {
  for (const u of valid) {
    if (!u.email) {
      unmatched.push(u.id);
      continue;
    }
    const f = forms(u.email);
    const match = f.length > 1 ? `u.email in (${f.map((e) => `'${sqlText(e)}'`).join(", ")})` : `u.email = '${sqlText(u.email)}'`;
    console.log(`select cma.set_user_external_id(u.id, 'aircall_user', '${u.id}') from cma.app_user u where ${match};`);
    matched += 1;
  }
  console.error(`-- ${matched} statement(s) by email, of ${valid.length} Aircall user(s); a user who is not a CMA person matches no row`);
}
console.error(unmatched.length ? `-- not matched (link by hand on Team → People → Linked accounts): ${unmatched.join(", ")}` : "-- not matched: none");
