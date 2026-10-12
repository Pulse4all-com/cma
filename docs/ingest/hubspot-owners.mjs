/**
 * HubSpot owners → the Studio statements that put each owner's id on their CMA person (system
 * hubspot_owner), for speed-to-lead attribution (DESIGN §4.4).
 *
 *   node docs/ingest/hubspot-owners.mjs --project <gcp project> --token-secret <token secret name> [--also-domain <from>=<to>]...
 *
 * Reads the connection's static token from Secret Manager with your own gcloud login (the value is
 * held in memory and never printed), lists the active owners through GET /crm/v3/owners and prints,
 * per owner, one statement:
 *
 *   select cma.set_user_external_id(u.id, 'hubspot_owner', '<owner id>') from cma.app_user u where u.email = '<owner email>';
 *
 * --also-domain <from>=<to> (repeatable): for an owner whose email domain is <from>, the statement
 * matches either address, so a person whose CMA identity is on another domain is found too:
 *
 *   select cma.set_user_external_id(u.id, 'hubspot_owner', '<owner id>') from cma.app_user u where u.email in ('<local>@<from>', '<local>@<to>');
 *
 * For example --also-domain newcogroup.com=pulse4all.com: Newco agents are HubSpot owners as
 * @newcogroup.com, their CMA identity through IAP is @pulse4all.com. Owners on other domains get
 * the statement above, unchanged. An agent whose local part differs between the two addresses is
 * mapped by hand (GO_LIVE_RUNBOOK 3b).
 *
 * Paste them into Studio after the runbook's context block (set role cma_app with the tenant and a
 * person holding users.manage_all): row-level security keeps them to that tenant, and an owner who
 * is not a CMA person matches no row and changes nothing. Owners are staff (work emails); the
 * output goes to the terminal only, never to a file.
 */
import { execFileSync } from "node:child_process";

function arg(name) {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : undefined;
}
function args(name) {
  return process.argv.flatMap((a, i) => (a === `--${name}` ? [process.argv[i + 1]] : []));
}
const usage = "usage: node docs/ingest/hubspot-owners.mjs --project <gcp project> --token-secret <token secret name> [--also-domain <from>=<to>]...";
const project = arg("project");
const tokenSecret = arg("token-secret");
if (!project || !tokenSecret || !/^[a-z][a-z0-9-]{4,29}$/.test(project) || !/^[A-Za-z0-9_-]{1,255}$/.test(tokenSecret)) {
  console.error(usage);
  process.exit(2);
}
const DOMAIN = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/;
const alsoDomain = new Map();  // <from> → <to>
for (const pair of args("also-domain")) {
  const [from, to, extra] = String(pair ?? "").toLowerCase().split("=");
  if (extra !== undefined || !DOMAIN.test(from ?? "") || !DOMAIN.test(to ?? "") || from === to || alsoDomain.has(from)) {
    console.error(`--also-domain ${pair ?? ""} is not <from>=<to> with two different domains, each <from> once`);
    console.error(usage);
    process.exit(2);
  }
  alsoDomain.set(from, to);
}

let token = execFileSync("gcloud", ["secrets", "versions", "access", "latest", `--secret=${tokenSecret}`, `--project=${project}`],
  { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] }).trim();
const base = process.env.INGEST_HUBSPOT_API_BASE ?? "https://api.hubapi.com";

const owners = [];
let after;
do {
  const res = await fetch(`${base}/crm/v3/owners?limit=100&archived=false${after ? `&after=${encodeURIComponent(after)}` : ""}`,
    { headers: { authorization: `Bearer ${token}` } });
  if (!res.ok) {
    console.error(`HubSpot answered ${res.status} for the owners list`);
    process.exit(1);
  }
  const page = await res.json();
  owners.push(...(page.results ?? []));
  after = page.paging?.next?.after;
} while (after);
token = null;

const sqlText = (s) => s.replace(/'/g, "''");
let printed = 0;
for (const o of owners) {
  const id = String(o.id ?? "");
  const email = String(o.email ?? "").trim().toLowerCase();
  if (!/^\d{1,30}$/.test(id) || !/^[^\s@']+@[^\s@']+$/.test(email)) continue;
  const [local, domain] = email.split("@");
  const to = alsoDomain.get(domain);
  const match = to ? `u.email in ('${sqlText(email)}', '${sqlText(`${local}@${to}`)}')` : `u.email = '${sqlText(email)}'`;
  console.log(`select cma.set_user_external_id(u.id, 'hubspot_owner', '${id}') from cma.app_user u where ${match};`);
  printed += 1;
}
console.error(`-- ${printed} statement(s) for ${owners.length} active owner(s)`);
