/**
 * Verifier: HubSpot's v3 request signature (src/adapters/hubspot/verify.mjs), pure: no network, no
 * database. The secret and the bodies are fixture values.
 *
 *   node verify/signature.mjs             every check must PASS
 *   node verify/signature.mjs --provoke   every check must FAIL
 */
import { createHmac } from "node:crypto";
import { verifyV3, signV3, hubspotUri, SIGNATURE_HEADER, TIMESTAMP_HEADER } from "../src/adapters/hubspot/verify.mjs";
import { expect, verdict, PROVOKE } from "./lib.mjs";

console.log(`verify/signature.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

const SECRET = "fixture-client-secret-0000";
const URI = "https://ingest.example.com/hubspot/key0000000000000000000001";
const BODY = Buffer.from(JSON.stringify([{ eventId: 1, portalId: 9000001, objectId: 11, subscriptionType: "object.creation", objectTypeId: "0-3", occurredAt: 1791622800000 }]));
const NOW = 1791622800000;
const TS = String(NOW - 1000);

// Independent reference: HubSpot's documented construction, written out by hand
const reference = createHmac("sha256", SECRET).update(`POST${URI}${BODY.toString("utf8")}${TS}`).digest("base64");
const headers = (o = {}) => ({ [SIGNATURE_HEADER]: reference, [TIMESTAMP_HEADER]: TS, ...o });
const check = (o) => verifyV3({ method: "POST", uris: [URI], body: BODY, headers: headers(), secret: SECRET, now: NOW, ...o });

expect("signV3 equals the documented construction", signV3(SECRET, "POST", URI, BODY, TS), reference, "x");
expect("a valid v3 signature is accepted", check({}), { ok: true }, { ok: false, reason: "bad_signature" });
expect("the method is part of the signature", check({ method: "PUT" }).reason ?? "ok", "bad_signature", "ok");
expect("a wrong secret is refused", check({ secret: "another-secret" }), { ok: false, reason: "bad_signature" }, { ok: true });
expect("a timestamp 6 minutes old is refused", check({ now: NOW + 6 * 60_000 }), { ok: false, reason: "stale_timestamp" }, { ok: true });
expect("a timestamp 6 minutes ahead is refused", check({ now: NOW - 6 * 60_000 }), { ok: false, reason: "stale_timestamp" }, { ok: true });
expect("a timestamp 4 minutes old is accepted", check({ now: NOW + 4 * 60_000 }), { ok: true }, { ok: false, reason: "stale_timestamp" });
const tampered = Buffer.from(BODY.toString("utf8").replace("9000001", "9000002"));
expect("a tampered body is refused", check({ body: tampered }), { ok: false, reason: "bad_signature" }, { ok: true });
expect("a wrong URI is refused", check({ uris: [URI.replace("key0", "key1")] }), { ok: false, reason: "bad_signature" }, { ok: true });
expect("a query string is part of the URI", check({ uris: [`${URI}?x=1`] }).ok, false, true);
expect("one matching URI among the candidates is enough", check({ uris: ["https://other.example.com/hubspot/k", URI] }), { ok: true }, { ok: false, reason: "bad_signature" });
expect("a missing signature header is refused", check({ headers: { [TIMESTAMP_HEADER]: TS } }), { ok: false, reason: "missing_header" }, { ok: true });
expect("a missing timestamp header is refused", check({ headers: { [SIGNATURE_HEADER]: reference } }), { ok: false, reason: "missing_header" }, { ok: true });
expect("a non-numeric timestamp is refused", check({ headers: headers({ [TIMESTAMP_HEADER]: "yesterday" }) }), { ok: false, reason: "bad_timestamp" }, { ok: true });
expect("an empty secret is refused", check({ secret: "" }), { ok: false, reason: "bad_signature" }, { ok: true });
expect("a v1-style signature (hex SHA-256) is refused", check({ headers: headers({ [SIGNATURE_HEADER]: createHmac("sha256", SECRET).update(BODY).digest("hex") }) }).ok, false, true);
const encoded = "https://ingest.example.com/hubspot/key%3Aa%2Fb%40c?q=%2C%3B";
expect("HubSpot's decoded characters in the URI", hubspotUri(encoded), "https://ingest.example.com/hubspot/key:a/b@c?q=,;", encoded);
const sigEncoded = createHmac("sha256", SECRET).update(`POST${hubspotUri(encoded)}${BODY.toString("utf8")}${TS}`).digest("base64");
expect("a signature over the decoded URI is accepted", verifyV3({ method: "POST", uris: [encoded], body: BODY, headers: headers({ [SIGNATURE_HEADER]: sigEncoded }), secret: SECRET, now: NOW }).ok, true, false);

verdict();
