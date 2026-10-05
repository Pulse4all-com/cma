/**
 * Verification of the signed identity token Identity-Aware Proxy adds to every
 * request it lets through (header x-goog-iap-jwt-assertion).
 *
 * Checks: signature against Google's IAP key set (ES256), issuer
 * https://cloud.google.com/iap, audience = this backend service, expiry and
 * issue time. The plain identity headers are never trusted (README,
 * Authentication). Pure function, no Next.js imports, so it is testable alone.
 */
import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from "jose";
import type { Identity } from "./identity";

export const IAP_ISSUER = "https://cloud.google.com/iap";
export const IAP_JWKS_URL = "https://www.gstatic.com/iap/verify/public_key-jwk";
const CLOCK_TOLERANCE_S = 30;

const keySets = new Map<string, JWTVerifyGetKey>();

function keySet(url: string): JWTVerifyGetKey {
  let ks = keySets.get(url);
  if (!ks) {
    ks = createRemoteJWKSet(new URL(url), { cooldownDuration: 30_000, cacheMaxAge: 600_000 });
    keySets.set(url, ks);
  }
  return ks;
}

export class IapVerifyError extends Error {
  constructor(message: string, override readonly cause?: unknown) {
    super(message);
    this.name = "IapVerifyError";
  }
}

export async function verifyIapJwt(
  token: string,
  opts: { audience: string; jwksUrl?: string },
): Promise<Identity> {
  if (!opts.audience) throw new IapVerifyError("IAP audience is not configured");
  let payload;
  try {
    ({ payload } = await jwtVerify(token, keySet(opts.jwksUrl ?? IAP_JWKS_URL), {
      issuer: IAP_ISSUER,
      audience: opts.audience,
      algorithms: ["ES256"],
      clockTolerance: CLOCK_TOLERANCE_S,
    }));
  } catch (e) {
    throw new IapVerifyError("IAP token did not verify", e);
  }
  // jose checks exp and nbf, not a future iat; IAP's test modes include one
  const now = Math.floor(Date.now() / 1000);
  if (typeof payload.iat !== "number" || payload.iat > now + CLOCK_TOLERANCE_S) {
    throw new IapVerifyError("IAP token issue time is missing or in the future");
  }
  if (typeof payload.sub !== "string" || typeof payload.email !== "string") {
    throw new IapVerifyError("IAP token lacks sub or email");
  }
  // sub is the stable Google account id, prefixed "accounts.google.com:"; stored as-is
  return { subject: payload.sub, email: payload.email.toLowerCase() };
}
