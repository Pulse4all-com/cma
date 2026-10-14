/**
 * Request gate. Runs before every page and route (Node runtime), see matcher.
 *
 * iap mode:  verify x-goog-iap-jwt-assertion and pass the identity on to the
 *            app in x-cma-identity-* headers, provider "google". No valid
 *            token, no page. Mock header, cookie and ?as= are ignored.
 * mock mode: pass a test identity (provider "mock") on in the same headers.
 *            The subject is chosen per request, first match wins:
 *              1. ?as=<subject>          sets the cookie, 303 to the same path without ?as
 *              2. x-cma-mock-subject     for verifiers (curl through gcloud run services proxy)
 *              3. cookie cma-mock-subject for a browser after ?as=
 *              4. MOCK_IDENTITY          agent-one
 *            An invalid subject is a 400, never a silent fallback, so a typo
 *            in a test cannot quietly test the wrong user.
 *
 * Incoming x-cma-identity-* headers are always removed first, so nothing a
 * client sends can impersonate anyone; the app only ever sees what this file
 * set. Static assets and the health route are not gated here (IAP in front of
 * the load balancer still gates them).
 *
 * /signed-out (README, Authentication; docs/signed-out) is never served by cma-web: the load balancer
 * sends it to the public bucket, and its IAP-clearing form to IAP. The matcher has no exception for it,
 * so a request for it that reaches cma-web gets the same check as any page (no valid token, 401) and,
 * with a valid one, a 404 (web/verify/signed-out.mjs proves both from this file and the app's routes).
 */
import { NextResponse, type NextRequest } from "next/server";
import { config as appConfig } from "@/lib/config";
import { IDENTITY_HEADERS, MOCK_IDENTITY, mockIdentity, type Identity } from "@/lib/auth/identity";
import { IapVerifyError, verifyIapJwt } from "@/lib/auth/iap";

/** Behind IAP with the Google-managed OAuth client every identity is a Google account */
const IAP_PROVIDER = "google";

const MOCK_SUBJECT_HEADER = "x-cma-mock-subject";
const MOCK_SUBJECT_COOKIE = "cma-mock-subject";
const MOCK_SUBJECT_PARAM = "as";
/** Lower-case slug, as in db/06_seed_dev_time_model.sql */
const MOCK_SUBJECT_RE = /^[a-z0-9][a-z0-9-]{0,62}$/;

export async function proxy(request: NextRequest) {
  const headers = new Headers(request.headers);
  headers.delete(IDENTITY_HEADERS.provider);
  headers.delete(IDENTITY_HEADERS.subject);
  headers.delete(IDENTITY_HEADERS.email);
  headers.delete(MOCK_SUBJECT_HEADER);

  if (appConfig.authMode === "mock") return mock(request, headers);

  const token = request.headers.get("x-goog-iap-jwt-assertion");
  if (!token) return unauthenticated("missing");
  try {
    const verified = await verifyIapJwt(token, { audience: appConfig.iapAudience, jwksUrl: appConfig.iapJwksUrl });
    return pass(headers, { provider: IAP_PROVIDER, subject: verified.subject, email: verified.email });
  } catch (e) {
    // Log the underlying reason (jose error code or fetch failure), never the token
    const cause = e instanceof IapVerifyError && e.cause instanceof Error ? e.cause : undefined;
    const code = cause && "code" in cause ? ` ${String((cause as { code: unknown }).code)}` : "";
    console.warn(`iap: token rejected: ${e instanceof Error ? e.message : String(e)}${cause ? ` (${cause.name}${code}: ${cause.message})` : ""}`);
    return unauthenticated("invalid");
  }
}

function mock(request: NextRequest, headers: Headers) {
  const fromParam = request.nextUrl.searchParams.get(MOCK_SUBJECT_PARAM);
  if (fromParam !== null) {
    if (!MOCK_SUBJECT_RE.test(fromParam)) return badMockSubject();
    // Next turns a same-host absolute redirect into a relative Location, so the visitor never sees the container's host
    const target = request.nextUrl.clone();
    target.searchParams.delete(MOCK_SUBJECT_PARAM);
    const res = NextResponse.redirect(target, 303);
    res.headers.set("cache-control", "no-store");
    res.cookies.set(MOCK_SUBJECT_COOKIE, fromParam, { httpOnly: true, sameSite: "lax", secure: true, path: "/" });
    return res;
  }

  const fromHeader = request.headers.get(MOCK_SUBJECT_HEADER);
  const fromCookie = request.cookies.get(MOCK_SUBJECT_COOKIE)?.value;
  const subject = fromHeader ?? fromCookie;
  if (subject === undefined || subject === null) return pass(headers, MOCK_IDENTITY);
  if (!MOCK_SUBJECT_RE.test(subject)) return badMockSubject();
  return pass(headers, mockIdentity(subject));
}

function pass(headers: Headers, identity: Identity) {
  headers.set(IDENTITY_HEADERS.provider, identity.provider);
  headers.set(IDENTITY_HEADERS.subject, identity.subject);
  headers.set(IDENTITY_HEADERS.email, identity.email);
  return NextResponse.next({ request: { headers } });
}

function badMockSubject() {
  return new NextResponse("Invalid mock subject", {
    status: 400,
    headers: { "content-type": "text/plain; charset=utf-8", "x-cma-auth": "bad-mock-subject", "cache-control": "no-store" },
  });
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
