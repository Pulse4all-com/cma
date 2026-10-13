/**
 * Verifier: Aircall's request authentication (src/adapters/aircall/verify.mjs and the adapter's
 * authenticate), pure: no network, no database. The tokens are fixture values.
 *
 *   node verify/aircall-token.mjs             every check must PASS
 *   node verify/aircall-token.mjs --provoke   every check must FAIL
 */
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { expect, verdict, PROVOKE } from "./lib.mjs";

console.log(`verify/aircall-token.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

const TOKEN = "fixture-aircall-webhook-token-0001";
const dir = mkdtempSync(path.join(tmpdir(), "aircall-token-"));
writeFileSync(path.join(dir, "ingest-aircall-verify-signing"), `${TOKEN}\n`);
process.env.INGEST_SECRETS_DIR = dir;
const { sameToken, verifyToken } = await import("../src/adapters/aircall/verify.mjs");
const { aircall } = await import("../src/adapters/aircall/index.mjs");

const body = (o) => Buffer.from(JSON.stringify({ resource: "call", event: "call.created", timestamp: 1791622801, data: { id: 9100000001 }, ...o }));
const check = (o, secret = TOKEN) => verifyToken({ body: body(o), secret });

expect("the right token is accepted", check({ token: TOKEN }), { ok: true }, { ok: false, reason: "bad_token" });
expect("a wrong token of the same length is refused", check({ token: TOKEN.replace(/1$/, "2") }), { ok: false, reason: "bad_token" }, { ok: true });
expect("a missing token is refused", check({}), { ok: false, reason: "missing_token" }, { ok: true });
expect("an empty token is refused", check({ token: "" }), { ok: false, reason: "missing_token" }, { ok: true });
expect("a token that is not a string is refused", check({ token: 1234 }), { ok: false, reason: "missing_token" }, { ok: true });
expect("a shorter token (a prefix of the right one) is refused", check({ token: TOKEN.slice(0, -1) }), { ok: false, reason: "bad_token" }, { ok: true });
expect("a longer token (the right one plus a character) is refused", check({ token: `${TOKEN}x` }), { ok: false, reason: "bad_token" }, { ok: true });
expect("the token inside data does not count", check({ data: { id: 1, token: TOKEN } }), { ok: false, reason: "missing_token" }, { ok: true });
expect("a body that is not JSON is refused", verifyToken({ body: Buffer.from("token=" + TOKEN), secret: TOKEN }), { ok: false, reason: "not_json" }, { ok: true });
expect("a JSON array is refused", verifyToken({ body: Buffer.from(JSON.stringify([{ token: TOKEN }])), secret: TOKEN }), { ok: false, reason: "not_json" }, { ok: true });
expect("an empty secret refuses everything", check({ token: TOKEN }, ""), { ok: false, reason: "bad_token" }, { ok: true });
expect("sameToken: different lengths are false without a compare", sameToken("abc", "abcd"), false, true);
expect("sameToken: multi-byte characters compare by bytes", sameToken("é", "e"), false, true);

// The adapter reads the connection's signing secret by name (5-minute cache) and answers the same
const connection = { connectionId: "c", signingSecretName: "ingest-aircall-verify-signing" };
expect("the adapter accepts its webhook's token", await aircall.authenticate({ body: body({ token: TOKEN }), connection }), { ok: true }, { ok: false });
expect("the adapter refuses another token", (await aircall.authenticate({ body: body({ token: "another-token-of-other-length" }), connection })).ok, false, true);
let unavailable = null;
try {
  await aircall.authenticate({ body: body({ token: TOKEN }), connection: { connectionId: "c", signingSecretName: "ingest-aircall-missing" } });
} catch (err) {
  unavailable = err?.name;
}
expect("an unreadable signing secret throws SecretUnavailable (the server answers 500)", unavailable, "SecretUnavailable", null);

// Code check: the compare is crypto.timingSafeEqual after a length check, and nothing compares the token with === or !==
const here = path.dirname(fileURLToPath(import.meta.url));
const source = readFileSync(path.join(here, "../src/adapters/aircall/verify.mjs"), "utf8");
// comments out, and `typeof x` (a type check, not a compare of values) folded away
const code = source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "").replace(/typeof\s+[\w.]+/g, "typeof_");
expect("verify.mjs imports timingSafeEqual from node:crypto", /import\s*\{\s*timingSafeEqual\s*\}\s*from\s*"node:crypto"/.test(code), true, false);
expect("…calls it on the two buffers", /timingSafeEqual\(a, b\)/.test(code), true, false);
expect("…after the length check", code.indexOf("a.length !== b.length") > -1 && code.indexOf("a.length !== b.length") < code.indexOf("timingSafeEqual(a, b)"), true, false);
expect("…and never compares a token with === or !==", /\b(token|secret|given|expected)\s*[!=]==|[!=]==\s*(token|secret|given|expected)\b/.test(code), false, true);

rmSync(dir, { recursive: true, force: true });
verdict();
