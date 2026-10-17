/**
 * Verifier: the Aircall scripts (docs/ingest/aircall-webhook.mjs, docs/ingest/aircall-users.mjs) and
 * the replay tool's Aircall mode (tools/replay.mjs --adapter aircall) and its host guard (a URL that is
 * neither the local machine nor a run.app address is refused unless --allow-host insists; audit 17 October
 * 2026, 5.2-10), against a fake Aircall and HubSpot API and a fake `gcloud` on PATH (it serves secrets from files and keeps what `versions add`
 * reads on standard input). No network beyond localhost, no database, no real gcloud. Everything is
 * invented (example.com).
 *
 *   node verify/aircall-scripts.mjs             every check must PASS
 *   node verify/aircall-scripts.mjs --provoke   every check must FAIL
 */
import http from "node:http";
import { mkdtempSync, writeFileSync, readFileSync, existsSync, rmSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { expect, verdict, PROVOKE } from "./lib.mjs";

console.log(`verify/aircall-scripts.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

const here = path.dirname(fileURLToPath(import.meta.url));
const WEBHOOK = path.join(here, "../../docs/ingest/aircall-webhook.mjs");
const USERS = path.join(here, "../../docs/ingest/aircall-users.mjs");
const REPLAY = path.join(here, "../tools/replay.mjs");
const PROJECT = "p4a-cma-verify";
const CRED = { api_id: "fixture-api-id", api_token: "fixture-api-token-0001" };
const NEW_TOKEN = "fixture-new-webhook-token-0001";
const HS_TOKEN = "fixture-hubspot-token-0001";
const URL_OK = "https://ingest.example.com/aircall/key00000000000000000000000001";

// ---- The fake gcloud -------------------------------------------------------------------------------------
const dir = mkdtempSync(path.join(tmpdir(), "aircall-scripts-"));
const secrets = path.join(dir, "secrets");
writeFileSync(path.join(dir, "gcloud"), `#!/bin/bash
# fake gcloud: secrets versions access | describe | versions add (stdin kept in <name>.added)
d="${secrets}"
name=""; for a in "$@"; do case "$a" in --secret=*) name="\${a#--secret=}";; esac; done
if [ "$1 $2 $3" = "secrets versions access" ]; then cat "$d/$name" 2>/dev/null || exit 1; exit 0; fi
if [ "$1 $2" = "secrets describe" ]; then [ -f "$d/$3" ] && exit 0 || exit 1; fi
if [ "$1 $2 $3" = "secrets versions add" ]; then [ -n "$FAKE_GCLOUD_FAIL_ADD" ] && exit 1; cat >> "$d/$4.added"; echo "Created version [2] of the secret [$4]." >&2; exit 0; fi
exit 3
`);
chmodSync(path.join(dir, "gcloud"), 0o755);
await import("node:fs/promises").then((fs) => fs.mkdir(secrets));
const put = (name, value) => writeFileSync(path.join(secrets, name), value);
put("ingest-aircall-verify-token", JSON.stringify(CRED));
put("ingest-aircall-verify-signing", "");
put("ingest-hubspot-verify-token", HS_TOKEN);
const added = (name) => (existsSync(path.join(secrets, `${name}.added`)) ? readFileSync(path.join(secrets, `${name}.added`), "utf8") : null);

// ---- The fake APIs -----------------------------------------------------------------------------------------
const fake = { company: "Verify Company", webhooks: [], requests: [], users: [], owners: [], received: [] };
const AUTH = `Basic ${Buffer.from(`${CRED.api_id}:${CRED.api_token}`).toString("base64")}`;
const json = (res, status, body) => {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(body === null ? "" : JSON.stringify(body));
};
const server = http.createServer((req, res) => {
  let data = "";
  req.on("data", (c) => { data += c; });
  req.on("end", () => {
    const url = new URL(req.url, "http://x");
    const r = { method: req.method, path: url.pathname, query: Object.fromEntries(url.searchParams), auth: req.headers.authorization, body: data ? JSON.parse(data) : null };
    fake.requests.push(r);
    if (url.pathname.startsWith("/ingest/")) {
      fake.received.push(r.body);
      return json(res, 200, { received: 1, new: 1 });
    }
    if (url.pathname === "/crm/v3/owners") {
      if (r.auth !== `Bearer ${HS_TOKEN}`) return json(res, 401, {});
      return json(res, 200, { results: fake.owners });
    }
    if (r.auth !== AUTH) return json(res, 401, { error: "Unauthorized" });
    if (url.pathname === "/v1/company") return json(res, 200, { company: { name: fake.company, id: null, users_count: 3, numbers_count: 2 } });
    if (url.pathname === "/v1/webhooks" && req.method === "GET") return json(res, 200, { webhooks: fake.webhooks, meta: { next_page_link: null } });
    if (url.pathname === "/v1/webhooks" && req.method === "POST") {
      const w = { webhook_id: `bbbbbbbb-0000-4000-8000-00000000000${fake.webhooks.length + 1}`, direct_link: "https://api.example.com/v1/webhooks/x", created_at: "2026-10-13T08:00:00Z",
        custom_name: r.body.custom_name, url: r.body.url, active: true, token: NEW_TOKEN, events: r.body.events };
      fake.webhooks.push(w);
      return json(res, 201, { webhook: w });
    }
    let m;
    if ((m = /^\/v1\/webhooks\/([\w-]+)$/.exec(url.pathname)) && req.method === "DELETE") {
      const before = fake.webhooks.length;
      fake.webhooks = fake.webhooks.filter((w) => w.webhook_id !== m[1]);
      return before === fake.webhooks.length ? json(res, 404, {}) : json(res, 204, null);
    }
    if (url.pathname === "/v1/users") return json(res, 200, { users: fake.users, meta: { next_page_link: null } });
    json(res, 404, {});
  });
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const BASE = `http://127.0.0.1:${server.address().port}`;

function run(script, argv, env = {}) {
  return new Promise((resolve) => {
    const p = spawn(process.execPath, [script, ...argv], {
      env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, INGEST_AIRCALL_API_BASE: BASE, INGEST_HUBSPOT_API_BASE: BASE, ...env },
    });
    let out = "";
    let err = "";
    p.stdout.on("data", (c) => { out += c; });
    p.stderr.on("data", (c) => { err += c; });
    p.on("close", (code) => resolve({ code, out, err }));
  });
}
const hook = (extra = []) => run(WEBHOOK, ["--project", PROJECT, "--api-secret", "ingest-aircall-verify-token", "--account", "Verify Company", ...extra]);
const create = (url = URL_OK, extra = []) => hook(["--url", url, "--token-secret", "ingest-aircall-verify-signing", ...extra]);
const secretsShown = (r) => [NEW_TOKEN, CRED.api_token, CRED.api_id, AUTH, HS_TOKEN].some((t) => r.out.includes(t) || r.err.includes(t));

// ---- aircall-webhook.mjs ----------------------------------------------------------------------------------
let r = await run(WEBHOOK, ["--project", PROJECT, "--url", URL_OK, "--api-secret", "ingest-aircall-verify-token", "--token-secret", "ingest-aircall-verify-signing", "--account", "Another Company"]);
expect("webhook: another company's key → refused, nothing created", [r.code, /refused: .*"Verify Company", not "Another Company"/.test(r.err), fake.webhooks.length, fake.requests.some((x) => x.method === "POST")], [1, true, 0, false], [0, false, 1, true]);
r = await create("http://ingest.example.com/aircall/key00000000000000000000000001");
expect("webhook: a URL that is not https → usage, no API call", [r.code, fake.requests.length], [2, 1], [0, 2]);
r = await create("https://ingest.example.com/hubspot/key00000000000000000000000001");
expect("webhook: a URL that is not /aircall/<key> → usage", r.code, 2, 0);
r = await run(WEBHOOK, ["--project", PROJECT, "--url", URL_OK, "--api-secret", "ingest-aircall-verify-token", "--token-secret", "ingest-aircall-missing", "--account", "Verify Company"]);
expect("webhook: the signing secret does not exist yet → refused, nothing created", [r.code, /does not exist yet/.test(r.err), fake.webhooks.length], [1, true, 0], [0, false, 1]);
r = await create();
const w = fake.webhooks[0];
expect("webhook: created with the six events and the URL", [r.code, w?.url, w?.events], [0, URL_OK, ["call.created", "call.answered", "call.ended", "call.tagged", "call.untagged", "call.archived"]], [1, null, []]);
expect("…the token went to gcloud secrets versions add on standard input, exactly", added("ingest-aircall-verify-signing"), NEW_TOKEN, null);
expect("…the output names the webhook id, the events and the setting to add", [r.out.includes(`webhook ${w?.webhook_id}`), r.out.includes("call.archived"), r.err.includes(`webhook_id = ${w?.webhook_id}`)], [true, true, true], [false, false, false]);
expect("…and never the token or the API key", secretsShown(r), false, true);
r = await create();
expect("webhook: a second run for the same URL → refused, prints the existing id, nothing created", [r.code, r.out.includes(w?.webhook_id), fake.webhooks.length, /exists already/.test(r.err)], [1, true, 1, true], [0, false, 2, false]);
expect("…nothing stored a second time", added("ingest-aircall-verify-signing"), NEW_TOKEN, `${NEW_TOKEN}${NEW_TOKEN}`);
r = await hook(["--list", "--url", URL_OK]);
expect("webhook --list: the webhook with active and events, marked for --url, no token", [r.code, r.out.startsWith(`* ${w?.webhook_id}  active true`), secretsShown(r)], [0, true, false], [1, false, true]);
r = await create("https://ingest.example.com/aircall/key00000000000000000000000002", []);
const added2 = added("ingest-aircall-verify-signing");
rmSync(path.join(secrets, "ingest-aircall-verify-signing.added"));
expect("webhook: another connection's URL is its own webhook", [r.code, fake.webhooks.length, added2 === `${NEW_TOKEN}${NEW_TOKEN}`], [0, 2, true], [1, 1, false]);
r = await run(WEBHOOK, ["--project", PROJECT, "--url", "https://ingest.example.com/aircall/key00000000000000000000000003", "--api-secret", "ingest-aircall-verify-token", "--token-secret", "ingest-aircall-verify-signing", "--account", "Verify Company"]);
expect("…(a third, for the next check)", r.code, 0, 1);
const third = fake.webhooks[2]?.webhook_id;
r = await hook(["--delete", third]);
expect("webhook --delete <id>: deleted", [r.code, r.out.trim(), fake.webhooks.some((x) => x.webhook_id === third)], [0, `deleted ${third}`, false], [1, "", true]);
rmSync(path.join(secrets, "ingest-aircall-verify-signing.added"), { force: true });
const failing = await new Promise((resolve) => {
  const p = spawn(process.execPath, [WEBHOOK, "--project", PROJECT, "--url", "https://ingest.example.com/aircall/key00000000000000000000000004", "--api-secret", "ingest-aircall-verify-token",
    "--token-secret", "ingest-aircall-verify-signing", "--account", "Verify Company"], { env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, INGEST_AIRCALL_API_BASE: BASE, FAKE_GCLOUD_FAIL_ADD: "1" } });
  let out = "";
  let err = "";
  p.stdout.on("data", (c) => { out += c; });
  p.stderr.on("data", (c) => { err += c; });
  p.on("close", (code) => resolve({ code, out, err }));
});
expect("webhook: the token cannot be stored → exit 1 with the id to delete, the token not shown", [failing.code, /could not be stored.*--delete bbbbbbbb/.test(failing.err), secretsShown(failing)], [1, true, false], [0, false, true]);

// ---- aircall-users.mjs --------------------------------------------------------------------------------------
fake.users = [
  { id: 9200000001, name: "Invented One", email: "agent.one@example.com" },
  { id: 9200000002, name: "Invented Two", email: "Agent.Two@partner.example.com" },
  { id: 9200000003, name: "Invented Three", email: "agent.three@example.com" },
  { id: 9200000004, name: "Invented Four" },
];
fake.owners = [{ id: "7100000001", email: "agent.one@example.com" }, { id: "7100000002", email: "agent.two@example.com" }];
r = await run(USERS, ["--project", PROJECT, "--api-secret", "ingest-aircall-verify-token"]);
const lines = r.out.trim().split("\n");
expect("users: one email statement per Aircall user with an email", [r.code, lines.length, lines[0]], [0, 3, "select cma.set_user_external_id(u.id, 'aircall_user', '9200000001') from cma.app_user u where u.email = 'agent.one@example.com';"], [1, 4, ""]);
expect("…the user without an email listed as not matched, by id", r.err.includes("not matched (link by hand on Team → People → Linked accounts): 9200000004"), true, false);
r = await run(USERS, ["--project", PROJECT, "--api-secret", "ingest-aircall-verify-token", "--also-domain", "partner.example.com=example.com"]);
expect("users --also-domain: the other domain's address matches too", r.out.includes("where u.email in ('agent.two@partner.example.com', 'agent.two@example.com');"), true, false);
r = await run(USERS, ["--project", PROJECT, "--api-secret", "ingest-aircall-verify-token", "--via-owners", "ingest-hubspot-verify-token"]);
const via = r.out.trim().split("\n");
expect("users --via-owners: per match the statement through the HubSpot owner id, no email", [r.code, via, /@/.test(r.out)],
  [0, ["select cma.set_user_external_id(x.user_id, 'aircall_user', '9200000001') from cma.app_user_external_id x where x.system = 'hubspot_owner' and x.external_id = '7100000001';"], false], [1, [], true]);
expect("…on stderr the count matched and the ids not matched, no emails", [r.err.includes("1 Aircall user(s) matched to a HubSpot owner, of 4"), r.err.includes("9200000002, 9200000003, 9200000004"), /@/.test(r.err)], [true, true, false], [false, false, true]);
r = await run(USERS, ["--project", PROJECT, "--api-secret", "ingest-aircall-verify-token", "--via-owners", "ingest-hubspot-verify-token", "--also-domain", "partner.example.com=example.com"]);
expect("users --via-owners --also-domain: the partner address matches the owner on the other domain", r.out.includes("'9200000002') from cma.app_user_external_id x where x.system = 'hubspot_owner' and x.external_id = '7100000002';"), true, false);
expect("…the HubSpot owners read with the HubSpot token, the users with the Aircall key", [fake.requests.filter((x) => x.path === "/crm/v3/owners").every((x) => x.auth === `Bearer ${HS_TOKEN}`), fake.requests.filter((x) => x.path === "/v1/users").every((x) => x.auth === AUTH)], [true, true], [false, false]);
expect("…and no secret printed by any run", secretsShown(r), false, true);

// ---- tools/replay.mjs --adapter aircall ----------------------------------------------------------------------
const fixture = path.join(here, "fixtures/aircall/call-lifecycle.json");
process.env.VERIFY_REPLAY_SECRET = "fixture-dev-webhook-token";
r = await run(REPLAY, ["--url", `${BASE}/ingest/aircall/key0000000000000000000000001`, "--fixture", fixture, "--secret-env", "VERIFY_REPLAY_SECRET", "--adapter", "aircall"], { VERIFY_REPLAY_SECRET: "fixture-dev-webhook-token" });
expect("replay --adapter aircall: one request per event, each 200", [r.code, fake.received.length, r.out.trim().split("\n").every((l) => l.startsWith("200 "))], [0, 6, true], [1, 1, false]);
expect("…the token in the body, as Aircall sends it, and never printed", [fake.received.every((b) => b.token === "fixture-dev-webhook-token"), r.out.includes("fixture-dev-webhook-token")], [true, false], [false, true]);
const original = JSON.parse(readFileSync(fixture, "utf8"));
expect("…without --fresh the fixture's times as they are", fake.received[0].timestamp, original[0].timestamp, original[0].timestamp + 1);
fake.received.length = 0;
const before = Math.floor(Date.now() / 1000);
await run(REPLAY, ["--url", `${BASE}/ingest/aircall/key0000000000000000000000001`, "--fixture", fixture, "--secret-env", "VERIFY_REPLAY_SECRET", "--adapter", "aircall", "--fresh"], { VERIFY_REPLAY_SECRET: "fixture-dev-webhook-token" });
const shift = fake.received[0].data.started_at - original[0].data.started_at;
expect("…with --fresh every time moved by the same amount, the first call starting now", [Math.abs(fake.received[0].data.started_at - before) <= 2, fake.received[4].timestamp - original[4].timestamp === shift, fake.received[4].data.ended_at - original[4].data.ended_at === shift],
  [true, true, true], [false, false, false]);

// The host guard: a public address is refused before any request; the same fake on a second loopback address
// (Linux answers on all of 127/8) stands in for a host that is neither 127.0.0.1 nor run.app
fake.received.length = 0;
r = await run(REPLAY, ["--url", "https://ingest.example.com/aircall/key0000000000000000000000001", "--fixture", fixture, "--secret-env", "VERIFY_REPLAY_SECRET", "--adapter", "aircall"], { VERIFY_REPLAY_SECRET: "fixture-dev-webhook-token" });
expect("replay: a host that is not the local machine or a run.app address → exit 2 before any request", [r.code, r.err.includes("replay goes to a local service or a dev run.app address, not ingest.example.com; add --allow-host to insist"), r.out, fake.received.length],
  [2, true, "", 0], [0, false, "200", 6]);
const mirror = http.createServer((req, res) => server.emit("request", req, res));
await new Promise((res) => mirror.listen(0, "127.0.0.2", res));
const ELSEWHERE = `http://127.0.0.2:${mirror.address().port}/ingest/aircall/key0000000000000000000000001`;
r = await run(REPLAY, ["--url", ELSEWHERE, "--fixture", fixture, "--secret-env", "VERIFY_REPLAY_SECRET", "--adapter", "aircall"], { VERIFY_REPLAY_SECRET: "fixture-dev-webhook-token" });
expect("replay: …127.0.0.2 is such a host: refused, nothing received", [r.code, fake.received.length], [2, 0], [0, 6]);
r = await run(REPLAY, ["--url", ELSEWHERE, "--fixture", fixture, "--secret-env", "VERIFY_REPLAY_SECRET", "--adapter", "aircall", "--allow-host"], { VERIFY_REPLAY_SECRET: "fixture-dev-webhook-token" });
expect("replay: --allow-host insists, with a warning naming the host, and the events arrive", [r.code, fake.received.length, r.err.includes("warning: replaying to 127.0.0.2 (--allow-host)"), r.out.includes("fixture-dev-webhook-token")], [0, 6, true, false], [2, 0, false, true]);
await new Promise((res) => mirror.close(res));

await new Promise((res) => server.close(res));
rmSync(dir, { recursive: true, force: true });
verdict();
