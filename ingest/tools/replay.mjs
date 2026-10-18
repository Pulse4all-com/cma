/**
 * Replays a webhook fixture to an ingest URL, authenticated as the source would authenticate it. For
 * dev and local runs with invented data only: never point it at prod with real ids.
 *
 *   node tools/replay.mjs --url <full webhook url> --fixture <file.json>
 *        (--secret-env <VAR> | --secret-file <path>) [--adapter hubspot|aircall] [--portal <id>] [--fresh]
 *
 *   --url          the address the source would call, for example https://cma-ingest-….run.app/hubspot/<key>;
 *                  for HubSpot it is also the URI that is signed
 *   --fixture      a JSON array of events (verify/fixtures/hubspot/*.json, verify/fixtures/aircall/*.json)
 *   --secret-env   the name of an environment variable holding the signing secret, or
 *   --secret-file  a file holding it (the secret is read, used, and never printed)
 *   --adapter      hubspot (default): the batch in one request, signed with X-HubSpot-Signature-v3;
 *                  aircall: one request per event, the secret (the webhook token of the dev connection)
 *                  put in the body's token, as Aircall sends it
 *   --portal       hubspot: sets every event's portalId (the dev connection's account id)
 *   --fresh        hubspot: new event ids and occurrence times now; aircall: every timestamp of the
 *                  fixture (the event's and the call's) moved so the first call starts now; either
 *                  way a second replay is not a duplicate
 *   --allow-host   replay to a host other than the local machine or a run.app address. Without it such
 *                  a --url is refused before any request (exit 2): prod is reached through its public
 *                  front, never a run.app address, so a dev command pasted with the prod address stops
 *                  here (audit 17 October 2026, 5.2-10)
 *
 * A dev Aircall connection whose settings hold {"replay": true} reads the call from the event itself
 * (the service needs INGEST_ALLOW_REPLAY=1, which deploy.sh sets in dev only); without the setting the
 * service reads the call from Aircall's API, which knows none of the fixture's ids.
 *
 * Prints the HTTP status and the service's answer (counts only), one line per request.
 */
import { readFileSync } from "node:fs";
import { signV3 } from "../src/adapters/hubspot/verify.mjs";

function arg(name) {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : undefined;
}
const flag = (name) => process.argv.includes(`--${name}`);
function fail(message) {
  console.error(message);
  process.exit(2);
}

const url = arg("url");
const fixture = arg("fixture");
const adapter = arg("adapter") ?? "hubspot";
if (!url || !fixture) fail("usage: node tools/replay.mjs --url <url> --fixture <file> (--secret-env <VAR> | --secret-file <path>) [--portal <id>] [--fresh]");
if (adapter !== "hubspot" && adapter !== "aircall") fail(`no replay for adapter ${adapter}: hubspot or aircall`);
let secret;
if (arg("secret-env")) secret = process.env[arg("secret-env")];
else if (arg("secret-file")) secret = readFileSync(arg("secret-file"), "utf8").replace(/\r?\n$/, "");
if (!secret) fail("the signing secret is needed: --secret-env <VAR> or --secret-file <path>");
// Dev and local only: prod's run.app address refuses everyone (ingress), so run.app means dev in practice
const host = (() => { try { return new URL(url).hostname; } catch { return ""; } })();
const devOrLocal = host === "localhost" || host === "127.0.0.1" || host.endsWith(".run.app");
if (!devOrLocal && !flag("allow-host")) fail(`replay goes to a local service or a dev run.app address, not ${host || url}; add --allow-host to insist`);
if (!devOrLocal) console.error(`warning: replaying to ${host} (--allow-host)`);

let events = JSON.parse(readFileSync(fixture, "utf8"));
if (!Array.isArray(events)) events = [events];

if (adapter === "aircall") {
  // Every UNIX time of the fixture (the events' and the calls') moved by the same amount, so the first call starts now
  const TIME_KEYS = new Set(["timestamp", "started_at", "answered_at", "ended_at", "posted_at"]);
  const times = events.flatMap((e) => [e.data?.started_at, e.timestamp]).filter((v) => Number.isFinite(v) && v > 0);
  const shift = flag("fresh") && times.length ? Math.floor(Date.now() / 1000) - Math.min(...times) : 0;
  const moved = (v) => (Array.isArray(v) ? v.map(moved) : v && typeof v === "object"
    ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, TIME_KEYS.has(k) && Number.isFinite(x) && x > 0 ? x + shift : moved(x)])) : v);
  let failed = 0;
  for (const e of events) {
    const body = JSON.stringify({ ...moved(e), token: secret });
    const res = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body });
    const text = await res.text();
    console.log(`${res.status} ${String(e.event ?? "?").slice(0, 40)} ${text.slice(0, 200)}`);
    if (!res.ok) failed += 1;
  }
  secret = null;
  process.exit(failed ? 1 : 0);
}

const portal = arg("portal");
if (portal && !/^\d{1,20}$/.test(portal)) fail("--portal takes the account id (digits)");
const base = Date.now() * 10;
events = events.map((e, i) => ({
  ...e,
  ...(portal ? { portalId: Number(portal) } : {}),
  ...(flag("fresh") ? { eventId: base + i, occurredAt: Date.now() } : {}),
}));

const body = JSON.stringify(events);
const timestamp = String(Date.now());
const signature = signV3(secret, "POST", url, body, timestamp);
secret = null;
const res = await fetch(url, {
  method: "POST",
  headers: { "content-type": "application/json", "x-hubspot-request-timestamp": timestamp, "x-hubspot-signature-v3": signature },
  body,
});
const text = await res.text();
console.log(`${res.status} ${text.slice(0, 200)}`);
process.exit(res.ok ? 0 : 1);
