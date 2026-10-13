/**
 * Verifier: Shopify's webhook HMAC (src/adapters/shopify/verify.mjs), pure: no network, no database.
 * The secret and the bodies are fixture values.
 *
 *   node verify/shopify-signature.mjs             every check must PASS
 *   node verify/shopify-signature.mjs --provoke   every check must FAIL
 */
import { createHmac } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { verifyHmac, signBody, sameDigest, HMAC_HEADER } from "../src/adapters/shopify/verify.mjs";
import { expect, verdict, PROVOKE } from "./lib.mjs";

console.log(`verify/shopify-signature.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

const SECRET = "fixture-shopify-client-secret-0001";
const BODY = Buffer.from(JSON.stringify({ id: 7100000001, admin_graphql_api_id: "gid://shopify/Customer/7100000001", updated_at: "2026-10-13T08:00:00Z" }));
// Independent reference: Shopify's documented construction (base64 HMAC-SHA256 of the raw body), written out by hand
const reference = createHmac("sha256", SECRET).update(BODY).digest("base64");
const check = (o = {}) => verifyHmac({ body: BODY, headers: { [HMAC_HEADER]: reference }, secret: SECRET, ...o });

expect("signBody equals the documented construction", signBody(SECRET, BODY), reference, "x");
expect("a valid HMAC is accepted", check(), { ok: true }, { ok: false, reason: "bad_signature" });
expect("the header name is X-Shopify-Hmac-Sha256 (as Node lower-cases it)", HMAC_HEADER, "x-shopify-hmac-sha256", "x-shopify-hmac");
expect("a wrong secret is refused", check({ secret: "another-secret" }), { ok: false, reason: "bad_signature" }, { ok: true });
expect("a body changed by one byte is refused", check({ body: Buffer.from(BODY.toString().replace("7100000001", "7100000002")) }), { ok: false, reason: "bad_signature" }, { ok: true });
expect("the raw bytes count: a re-serialised body (spaces) is refused", check({ body: Buffer.from(JSON.stringify(JSON.parse(BODY.toString()), null, 1)) }).reason ?? "ok", "bad_signature", "ok");
expect("a missing header is refused", check({ headers: {} }), { ok: false, reason: "missing_header" }, { ok: true });
expect("a header that is not a base64 SHA-256 digest is refused", check({ headers: { [HMAC_HEADER]: "abc" } }), { ok: false, reason: "missing_header" }, { ok: true });
expect("a hex digest (another encoding) is refused", check({ headers: { [HMAC_HEADER]: createHmac("sha256", SECRET).update(BODY).digest("hex") } }).ok, false, true);
expect("no secret: refused", check({ secret: "" }), { ok: false, reason: "bad_signature" }, { ok: true });
expect("surrounding whitespace in the header is tolerated", check({ headers: { [HMAC_HEADER]: ` ${reference} ` } }), { ok: true }, { ok: false });
expect("an empty body is signed as empty", verifyHmac({ body: Buffer.alloc(0), headers: { [HMAC_HEADER]: createHmac("sha256", SECRET).update("").digest("base64") }, secret: SECRET }), { ok: true }, { ok: false });
expect("sameDigest: equal strings", sameDigest(reference, reference), true, false);
expect("sameDigest: another length, no compare", sameDigest(reference, `${reference}A`), false, true);
expect("sameDigest: not strings", sameDigest(null, reference), false, true);

// The compare is constant time: the module compares with crypto.timingSafeEqual, never === on the digest
const here = path.dirname(fileURLToPath(import.meta.url));
const source = readFileSync(path.join(here, "../src/adapters/shopify/verify.mjs"), "utf8");
expect("the compare uses crypto.timingSafeEqual", /timingSafeEqual\(a, b\)/.test(source), true, false);
expect("…and no plain equality on the digest", /given\s*===\s*|===\s*expected|expected\s*===/.test(source), false, true);

verdict();
