/**
 * The Aircall webhook of one CMA connection (PROD_RUNBOOK 8.4; VENDOR_SETUP §2.3; brief B9).
 *
 *   node docs/ingest/aircall-webhook.mjs --project <gcp project> --url <full webhook url> \
 *        --api-secret <token secret name> --token-secret <signing secret name> --account <company name>
 *   node docs/ingest/aircall-webhook.mjs --project <gcp project> --api-secret <token secret name> --account <company name> --list [--url <full webhook url>]
 *   node docs/ingest/aircall-webhook.mjs --project <gcp project> --api-secret <token secret name> --account <company name> --delete <webhook id>
 *
 * Reads the Aircall API key (the token secret, JSON {"api_id","api_token"}) from Secret Manager with
 * your own gcloud login, held in memory and never printed. Every mode first checks the account: GET
 * /v1/company must name the company --account gives (the connection's external_account_id), else
 * nothing happens, so a key of another Aircall company is never wired to this connection.
 *
 * Create (the default): refuses when the signing secret does not exist yet (the runbook creates it
 * empty first) and when a webhook with this URL already exists (it prints that webhook's id: one
 * webhook per connection, else every event arrives twice); then POST /v1/webhooks with the six
 * events (call.created, call.answered, call.ended, call.tagged, call.untagged, call.archived), and
 * the token Aircall returns goes straight into `gcloud secrets versions add <signing secret>
 * --data-file=-` on standard input. Prints only the webhook id and its events, and the setting to
 * add. The token is never printed, logged or written anywhere else; Aircall shows it in this answer
 * only (the Dashboard does not).
 *
 * --list prints every webhook of the company: id, active, events and URL (never a token).
 * --delete <id> deletes one (DELETE /v1/webhooks/<id>).
 *
 * INGEST_AIRCALL_API_BASE (https, or http on localhost) replaces https://api.aircall.io for a fake
 * API in the verifier (ingest/verify/aircall-scripts.mjs).
 */
import { execFileSync, spawnSync } from "node:child_process";

const EVENTS = ["call.created", "call.answered", "call.ended", "call.tagged", "call.untagged", "call.archived"];
const usage = [
  "usage: node docs/ingest/aircall-webhook.mjs --project <gcp project> --url <full webhook url> --api-secret <token secret> --token-secret <signing secret> --account <company name>",
  "       … --project <gcp project> --api-secret <token secret> --account <company name> --list [--url <full webhook url>]",
  "       … --project <gcp project> --api-secret <token secret> --account <company name> --delete <webhook id>",
].join("\n");

function arg(name) {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : undefined;
}
const flag = (name) => process.argv.includes(`--${name}`);
function fail(message, code = 1) {
  console.error(message);
  process.exit(code);
}

const project = arg("project");
const url = arg("url");
const apiSecret = arg("api-secret");
const tokenSecret = arg("token-secret");
const account = (arg("account") ?? "").trim();
const list = flag("list");
const del = arg("delete");
const SECRET = /^[A-Za-z0-9_-]{1,255}$/;
const mode = list ? "list" : del !== undefined ? "delete" : "create";
if (!project || !/^[a-z][a-z0-9-]{4,29}$/.test(project) || !apiSecret || !SECRET.test(apiSecret) || !account || (list && del !== undefined)) fail(usage, 2);
if (mode === "create" && (!url || !tokenSecret || !SECRET.test(tokenSecret))) fail(usage, 2);
if (mode === "delete" && !/^[A-Za-z0-9-]{1,64}$/.test(del ?? "")) fail(`--delete takes a webhook id (as --list prints it)\n${usage}`, 2);
if (url !== undefined) {
  let u;
  try {
    u = new URL(url);
  } catch {
    fail(`--url ${url} is not a URL`, 2);
  }
  if (u.protocol !== "https:" || !/^\/aircall\/[A-Za-z0-9_-]{24,64}$/.test(u.pathname) || u.search || u.hash) {
    fail("--url must be https://<host>/aircall/<connection key>, without a query (the webhook address of PROD_RUNBOOK 8.4)", 2);
  }
}

const base = process.env.INGEST_AIRCALL_API_BASE ?? "https://api.aircall.io";
{
  const b = new URL(base);
  if (b.protocol !== "https:" && !(b.protocol === "http:" && ["127.0.0.1", "localhost"].includes(b.hostname))) fail("INGEST_AIRCALL_API_BASE must be https", 2);
}

let key;
try {
  key = JSON.parse(execFileSync("gcloud", ["secrets", "versions", "access", "latest", `--secret=${apiSecret}`, `--project=${project}`],
    { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] }));
} catch {
  fail(`could not read ${apiSecret} as {"api_id","api_token"} (gcloud secrets versions access)`);
}
if (typeof key?.api_id !== "string" || typeof key?.api_token !== "string") fail(`${apiSecret} does not hold {"api_id","api_token"}`);
const authorization = `Basic ${Buffer.from(`${key.api_id}:${key.api_token}`).toString("base64")}`;
key = null;

/** One API call; the answer's body only as JSON, never printed (a webhook's answer holds its token). */
async function api(method, path, body) {
  const res = await fetch(`${base}${path}`, {
    method,
    headers: { authorization, accept: "application/json", ...(body ? { "content-type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  if (!res.ok) fail(`Aircall answered ${res.status} for ${method} ${path.split("?")[0]}`);
  return text ? JSON.parse(text) : null;
}

async function webhooks() {
  const out = [];
  for (let page = 1; page <= 20; page += 1) {
    const r = await api("GET", `/v1/webhooks?per_page=50&page=${page}`);
    out.push(...(r?.webhooks ?? []));
    if (!r?.meta?.next_page_link || !(r?.webhooks ?? []).length) break;
  }
  return out;
}

const show = (w) => `${w.webhook_id}  active ${w.active === true}  events ${(w.events ?? []).join(",") || "(all)"}  ${w.url}`;

// The account: the key must answer for the company the connection pins
const company = (await api("GET", "/v1/company"))?.company;
const name = typeof company?.name === "string" ? company.name.trim() : "";
if (name !== account) fail(`refused: the API key in ${apiSecret} belongs to the Aircall company "${name}", not "${account}" (the connection's account id); nothing done`);

if (mode === "list") {
  const all = await webhooks();
  for (const w of all) console.log(`${url && w.url === url ? "* " : "  "}${show(w)}`);
  console.error(`-- ${all.length} webhook(s) of ${name}${url ? "; * marks the one for --url" : ""}`);
  process.exit(0);
}

if (mode === "delete") {
  await api("DELETE", `/v1/webhooks/${encodeURIComponent(del)}`);
  console.log(`deleted ${del}`);
  console.error("-- the signing secret keeps the old token as a version; the next create adds the new one");
  process.exit(0);
}

// Create
const described = spawnSync("gcloud", ["secrets", "describe", tokenSecret, `--project=${project}`], { stdio: ["ignore", "ignore", "ignore"] });
if (described.status !== 0) fail(`refused: the secret ${tokenSecret} does not exist yet in ${project} (create it empty first: PROD_RUNBOOK 8.4); nothing created`);
const existing = (await webhooks()).filter((w) => w.url === url);
if (existing.length) {
  for (const w of existing) console.log(show(w));
  fail(`refused: a webhook for this URL exists already (above); nothing created. One webhook per connection: to start again, --delete <id>, then run this again`);
}
const created = (await api("POST", "/v1/webhooks", { custom_name: "CMA ingest", url, events: EVENTS }))?.webhook;
let token = created?.token;
if (!created?.webhook_id || typeof token !== "string" || !token) fail(`Aircall created no webhook with a token${created?.webhook_id ? ` (id ${created.webhook_id}: delete it with --delete ${created.webhook_id})` : ""}`);
const stored = spawnSync("gcloud", ["secrets", "versions", "add", tokenSecret, `--project=${project}`, "--data-file=-"], { input: token, stdio: ["pipe", "ignore", "inherit"] });
token = null;
if (stored.status !== 0) fail(`the webhook ${created.webhook_id} exists, but its token could not be stored in ${tokenSecret}: delete it (--delete ${created.webhook_id}) and run this again`);
console.log(`webhook ${created.webhook_id}`);
console.log(`events  ${(created.events ?? EVENTS).join(", ")}`);
console.error(`-- token stored as a new version of ${tokenSecret} (not shown). Next: the connection setting webhook_id = ${created.webhook_id} (Configuration → Sources → the connection → Settings)`);
