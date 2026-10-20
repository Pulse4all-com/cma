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
 * Welcome on open (addition 0008z, src/lib/session.ts): once the identity is known, a page opened as a
 * document without the browser-session cookie cma-session goes to / with a 303 and the cookie; / sets it.
 * The API, invitations, the Log out pages and No access yet are not redirected; in mock mode neither are
 * the verifiers' header requests, and ?as= starts the session on its 303 to the same path.
 *
 * Incoming x-cma-identity-* headers are always removed first, so nothing a
 * client sends can impersonate anyone; the app only ever sees what this file
 * set. IAP's own headers (the assertion and its plain identity headers) are
 * removed after verification too, so no page or route can read or log them. Static assets and the health route are not gated here (IAP in front of
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
import { onOpen, SESSION_COOKIE, SESSION_COOKIE_OPTIONS } from "@/lib/session";

/** Behind IAP with the Google-managed OAuth client every identity is a Google account */
const IAP_PROVIDER = "google";
/** IAP's own request headers: read here, never passed on to a page or route */
export const IAP_HEADERS = ["x-goog-iap-jwt-assertion", "x-goog-authenticated-user-email", "x-goog-authenticated-user-id"] as const;

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
    return opened(request, headers, { provider: IAP_PROVIDER, subject: verified.subject, email: verified.email }, false);
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
    // ?as= is mock mode's sign-in for a browser: it keeps its path (the verifiers rely on it) and starts the session
    res.cookies.set(SESSION_COOKIE, "1", SESSION_COOKIE_OPTIONS);
    return res;
  }

  const fromHeader = request.headers.get(MOCK_SUBJECT_HEADER);
  const fromCookie = request.cookies.get(MOCK_SUBJECT_COOKIE)?.value;
  const subject = fromHeader ?? fromCookie;
  if (subject === undefined || subject === null) return opened(request, headers, MOCK_IDENTITY, false);
  if (!MOCK_SUBJECT_RE.test(subject)) return badMockSubject();
  return opened(request, headers, mockIdentity(subject), fromHeader !== null);
}

/** Welcome on open (src/lib/session.ts): a page opened without the browser session goes to /; / starts the session */
function opened(request: NextRequest, headers: Headers, identity: Identity, mockHeader: boolean) {
  const decision = onOpen({
    method: request.method,
    pathname: request.nextUrl.pathname,
    fetchDest: request.headers.get("sec-fetch-dest"),
    accept: request.headers.get("accept"),
    rsc: request.headers.has("rsc") || request.headers.has("next-router-prefetch"),
    hasSession: request.cookies.has(SESSION_COOKIE),
    mockHeader,
  });
  if (decision === "welcome") {
    // Relative, as ?as= above: the visitor never sees the container's host
    const target = request.nextUrl.clone();
    target.pathname = "/";
    target.search = "";
    const res = NextResponse.redirect(target, 303);
    res.headers.set("cache-control", "no-store");
    res.cookies.set(SESSION_COOKIE, "1", SESSION_COOKIE_OPTIONS);
    return res;
  }
  const res = pass(headers, identity);
  if (decision === "start") res.cookies.set(SESSION_COOKIE, "1", SESSION_COOKIE_OPTIONS);
  return res;
}

function pass(headers: Headers, identity: Identity) {
  // The app never sees IAP's own headers: the assertion has done its work here and is a bearer proof for
  // its lifetime, and the plain identity headers are never to be trusted (README, Authentication), so
  // nothing downstream can read or log them (the IT audit of 17 October 2026)
  for (const name of IAP_HEADERS) headers.delete(name);
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
