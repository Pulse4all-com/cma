import { createServer } from "node:http";
import { generateKeyPair, exportJWK, SignJWT } from "jose";

/**
 * Verifier: IAP token handling of the running app (verify-by-breaking).
 *
 * Start the app in iap mode against this script's key set, then run it:
 *   CMA_AUTH_MODE=iap CMA_DATA_MODE=mock IAP_AUDIENCE=$AUD \
 *   IAP_JWKS_URL=http://localhost:9999/jwks PORT=8094 node .next/standalone/server.js &
 *   node verify/iap-token.mjs
 * Env: BASE (default http://localhost:8094), JWKS_PORT (default 9999), AUD.
 * Every invalid token must get 401; a valid one 200 with the token's email;
 * a spoofed x-cma-identity header must never win. Exit code 1 on any failure.
 */
const AUD = process.env.AUD ?? "/projects/467777891162/global/backendServices/1234567890";
const JWKS_PORT = Number(process.env.JWKS_PORT ?? 9999);
const good = await generateKeyPair("ES256", { extractable: true });
const evil = await generateKeyPair("ES256", { extractable: true });
const jwk = { ...(await exportJWK(good.publicKey)), kid: "test-key", alg: "ES256", use: "sig" };

createServer((req, res) => {
  res.setHeader("content-type", "application/json");
  res.end(JSON.stringify({ keys: [jwk] }));
}).listen(9998);

async function token(opts = {}) {
  const key = opts.evil ? evil.privateKey : good.privateKey;
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({ email: "martin@pulse4all.com", hd: "pulse4all.com", ...(opts.claims ?? {}) })
    .setProtectedHeader({ alg: "ES256", kid: "test-key" })
    .setIssuer(opts.iss ?? "https://cloud.google.com/iap")
    .setAudience(opts.aud ?? AUD)
    .setSubject("accounts.google.com:118133858486581853996")
    .setIssuedAt(opts.iat ?? now)
    .setExpirationTime(opts.exp ?? now + 600)
    .sign(key);
}

const base = "http://localhost:8095";
async function hit(name, headers) {
  const r = await fetch(base + "/", { headers, redirect: "manual" });
  const body = await r.text();
  const who = body.match(/Signed in as<!-- --> <span[^>]*>([^<]*)/)?.[1] ?? "";
  console.log(name.padEnd(28), r.status, r.headers.get("x-cma-auth") ?? "", who);
  return r.status;
}

const results = [];
results.push(await hit("valid token", { "x-goog-iap-jwt-assertion": await token() }) === 200);
results.push(await hit("no token", {}) === 401);
results.push(await hit("wrong audience", { "x-goog-iap-jwt-assertion": await token({ aud: "/projects/1/global/backendServices/2" }) }) === 401);
results.push(await hit("wrong issuer", { "x-goog-iap-jwt-assertion": await token({ iss: "https://accounts.google.com" }) }) === 401);
results.push(await hit("expired", { "x-goog-iap-jwt-assertion": await token({ exp: Math.floor(Date.now()/1000) - 120 }) }) === 401);
results.push(await hit("future issue", { "x-goog-iap-jwt-assertion": await token({ iat: Math.floor(Date.now()/1000) + 600, exp: Math.floor(Date.now()/1000) + 1200 }) }) === 401);
results.push(await hit("wrong signer", { "x-goog-iap-jwt-assertion": await token({ evil: true }) }) === 401);
results.push(await hit("garbage", { "x-goog-iap-jwt-assertion": "abc.def.ghi" }) === 401);
results.push(await hit("spoofed identity, no token", { "x-cma-identity-sub": "accounts.google.com:1", "x-cma-identity-email": "ceo@pulse4all.com" }) === 401);
const spoof = await fetch(base + "/", { headers: { "x-goog-iap-jwt-assertion": await token(), "x-cma-identity-email": "ceo@pulse4all.com" } });
const spoofBody = await spoof.text();
const spoofOk = spoof.status === 200 && spoofBody.includes("martin@pulse4all.com") && !spoofBody.includes("ceo@pulse4all.com");
console.log("spoofed header + valid token".padEnd(28), spoof.status, spoofOk ? "identity from token, header ignored" : "FAIL");
results.push(spoofOk);
const health = await fetch(base + "/api/health");
console.log("health without token".padEnd(28), health.status);
results.push(health.status === 200);
const ok = results.every(Boolean);
console.log(ok ? "\nALL PASS" : "\nSOME FAILED");
process.exit(ok ? 0 : 1);
