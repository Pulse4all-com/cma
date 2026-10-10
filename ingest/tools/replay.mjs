/**
 * Replays a webhook fixture to an ingest URL, signed as the source would sign it. For dev and local
 * runs with invented data only: never point it at prod with real ids.
 *
 *   node tools/replay.mjs --url <full webhook url> --fixture <file.json>
 *        (--secret-env <VAR> | --secret-file <path>) [--adapter hubspot] [--portal <id>] [--fresh]
 *
 *   --url          the address the source would call, for example https://cma-ingest-….run.app/hubspot/<key>;
 *                  it is also the URI that is signed
 *   --fixture      a JSON array of events (verify/fixtures/hubspot/*.json)
 *   --secret-env   the name of an environment variable holding the signing secret, or
 *   --secret-file  a file holding it (the secret is read, used to sign, and never printed)
 *   --portal       sets every event's portalId (the dev connection's account id)
 *   --fresh        new event ids and occurrence times now, so a second replay is not a duplicate
 *
 * Prints the HTTP status and the service's answer (counts only).
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
if (adapter !== "hubspot") fail(`no replay signing for adapter ${adapter} yet`);
let secret;
if (arg("secret-env")) secret = process.env[arg("secret-env")];
else if (arg("secret-file")) secret = readFileSync(arg("secret-file"), "utf8").replace(/\r?\n$/, "");
if (!secret) fail("the signing secret is needed: --secret-env <VAR> or --secret-file <path>");

let events = JSON.parse(readFileSync(fixture, "utf8"));
if (!Array.isArray(events)) events = [events];
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
