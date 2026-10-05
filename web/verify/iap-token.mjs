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
 * a spoofed x-cma-identity header must never win; the mock subject switch
 * (header, ?as=) must do nothing in iap mode. Exit code 1 on any failure.
 */
const AUD = process.env.AUD ?? "/projects/467777891162/global/backendServices/1234567890";
const JWKS_PORT = Number(process.env.JWKS_PORT ?? 9999);
const good = await generateKeyPair("ES256", { extractable: true });
const evil = await generateKeyPair("ES256", { extractable: true });
const jwk = { ...(await exportJWK(good.publicKey)), kid: "test-key", alg: "ES256", use: "sig" };

createServer((req, res) => {
  res.setHeader("content-type", "application/json");
  res.end(JSON.stringify({ keys: [jwk] }));
}).listen(JWKS_PORT);

async function token(opts = {}) {
  const key = opts.evil ? evil.privateKey : good.privateKey;
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({ email: "martin@pulse4all.com", hd: "pulse4all.com", ...(opts.claims ?? {}) })
    .setProtectedHeader({ alg: "ES256", kid: "test-key" })
    .setIssuer(opts.iss ?? "https://cloud.google.com/iap")
    .setAudience(opts.aud ?? AUD)
    .setSubject(opts.sub ?? "accounts.google.com:118133858486581853996")
    .setIssuedAt(opts.iat ?? now)
    .setExpirationTime(opts.exp ?? now + 600)
    .sign(key);
}

const base = process.env.BASE ?? "http://localhost:8094";
async function hit(name, headers, path = "/") {
  const r = await fetch(base + path, { headers, redirect: "manual" });
  const body = await r.text();
  const who = body.match(/Signed in as<!-- --> <span[^>]*>([^<]*)/)?.[1] ?? "";
  console.log(name.padEnd(32), r.status, r.headers.get("x-cma-auth") ?? "", who);
  return { status: r.status, body };
}
const status = async (...a) => (await hit(...a)).status;
/** 200, the token's identity shown, the spoofed one nowhere */
const tokenWins = ({ status, body }) =>
  status === 200 && body.includes("martin@pulse4all.com") && !body.includes("ceo@pulse4all.com") && !body.includes("manager@example.com");

const results = [];
results.push(await status("valid token", { "x-goog-iap-jwt-assertion": await token() }) === 200);
results.push(await status("no token", {}) === 401);
results.push(await status("wrong audience", { "x-goog-iap-jwt-assertion": await token({ aud: "/projects/1/global/backendServices/2" }) }) === 401);
results.push(await status("wrong issuer", { "x-goog-iap-jwt-assertion": await token({ iss: "https://accounts.google.com" }) }) === 401);
results.push(await status("expired", { "x-goog-iap-jwt-assertion": await token({ exp: Math.floor(Date.now()/1000) - 120 }) }) === 401);
results.push(await status("future issue", { "x-goog-iap-jwt-assertion": await token({ iat: Math.floor(Date.now()/1000) + 600, exp: Math.floor(Date.now()/1000) + 1200 }) }) === 401);
results.push(await status("wrong signer", { "x-goog-iap-jwt-assertion": await token({ evil: true }) }) === 401);
results.push(await status("garbage", { "x-goog-iap-jwt-assertion": "abc.def.ghi" }) === 401);
results.push(await status("sub without google prefix", { "x-goog-iap-jwt-assertion": await token({ sub: "118133858486581853996" }) }) === 401);
results.push(await status("sub not a numeric id", { "x-goog-iap-jwt-assertion": await token({ sub: "accounts.google.com:agent-one" }) }) === 401);
results.push(await status("spoofed identity, no token", { "x-cma-identity-provider": "mock", "x-cma-identity-sub": "agent-one", "x-cma-identity-email": "ceo@pulse4all.com" }) === 401);
results.push(tokenWins(await hit("spoofed email + valid token", { "x-goog-iap-jwt-assertion": await token(), "x-cma-identity-email": "ceo@pulse4all.com" })));
results.push(tokenWins(await hit("spoofed provider + valid token", { "x-goog-iap-jwt-assertion": await token(), "x-cma-identity-provider": "mock", "x-cma-identity-sub": "manager" })));
results.push(tokenWins(await hit("mock header in iap mode", { "x-goog-iap-jwt-assertion": await token(), "x-cma-mock-subject": "manager" })));
results.push(tokenWins(await hit("?as= in iap mode (no 303)", { "x-goog-iap-jwt-assertion": await token() }, "/?as=manager")));
const health = await fetch(base + "/api/health");
console.log("health without token".padEnd(32), health.status);
results.push(health.status === 200);
const ok = results.every(Boolean);
console.log(ok ? "\nALL PASS" : "\nSOME FAILED");
process.exit(ok ? 0 : 1);
