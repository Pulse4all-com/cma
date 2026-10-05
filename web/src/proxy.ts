/**
 * Request gate. Runs before every page and route (Node runtime), see matcher.
 *
 * iap mode:  verify x-goog-iap-jwt-assertion and pass the identity on to the
 *            app in x-cma-identity-* headers. No valid token, no page.
 * mock mode: pass the fixed test identity on in the same headers.
 *
 * Incoming x-cma-identity-* headers are always removed first, so nothing a
 * client sends can impersonate anyone; the app only ever sees what this file
 * set. Static assets and the health route are not gated here (IAP in front of
 * the load balancer still gates them).
 */
import { NextResponse, type NextRequest } from "next/server";
import { config as appConfig } from "@/lib/config";
import { IDENTITY_HEADERS, MOCK_IDENTITY } from "@/lib/auth/identity";
import { verifyIapJwt } from "@/lib/auth/iap";

export async function proxy(request: NextRequest) {
  const headers = new Headers(request.headers);
  headers.delete(IDENTITY_HEADERS.subject);
  headers.delete(IDENTITY_HEADERS.email);

  if (appConfig.authMode === "mock") {
    headers.set(IDENTITY_HEADERS.subject, MOCK_IDENTITY.subject);
    headers.set(IDENTITY_HEADERS.email, MOCK_IDENTITY.email);
    return NextResponse.next({ request: { headers } });
  }

  const token = request.headers.get("x-goog-iap-jwt-assertion");
  if (!token) return unauthenticated("missing");
  try {
    const identity = await verifyIapJwt(token, { audience: appConfig.iapAudience, jwksUrl: appConfig.iapJwksUrl });
    headers.set(IDENTITY_HEADERS.subject, identity.subject);
    headers.set(IDENTITY_HEADERS.email, identity.email);
    return NextResponse.next({ request: { headers } });
  } catch (e) {
    console.warn("iap: token rejected", e instanceof Error ? e.message : e);
    return unauthenticated("invalid");
  }
}

function unauthenticated(reason: "missing" | "invalid") {
  // Plain and short: behind IAP a person should never see this; a tool might
  return new NextResponse("Not authenticated", {
    status: 401,
    headers: { "content-type": "text/plain; charset=utf-8", "x-cma-auth": reason, "cache-control": "no-store" },
  });
}

export const config = {
  matcher: ["/((?!api/health|_next/static|_next/image|icon.png|brand/).*)"],
};
