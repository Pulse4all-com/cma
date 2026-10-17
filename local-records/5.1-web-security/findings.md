# 5.1 Security of the web application (`web/`): raw findings

**Summary.** Examined `web/src/proxy.ts`, `web/src/lib/auth/*`, `web/src/lib/api/*`, all 103 route files (113 exported HTTP handlers, 52 of them writes), the two form-post routes, the server action, `next.config.ts`, the static signed-out page and its deploy script, the CSV builder, the invitation flow end to end (page, route, `lib/invitations.ts`, `db/66_invitations.sql`), every `href` built from data, the ignore files, the full git history (164 commits, 24.5 MB of patches, regex pass), both `package-lock.json` files, four `npm audit` runs and `npm outdated`; ran the pure verifiers `csv`, `invitations` and `preview` (observed: 17, 27 and 18 PASS). Static review and local runs only; nothing outside the repository was called. About two hours. Most important: the IAP path, CSRF guard, input validation, SQL parameterisation, URL validation and CSV defusing are sound and mechanically complete (0 unguarded writes, 0 unvalidated dynamic segments, 0 XSS sinks, 0 secrets in history); what remains is defence in depth: no Content-Security-Policy on the app, the IAP assertion forwarded to the app after verification, a personal-identifier-shaped test fixture in a public repository, a server action outside the one CSRF design, and a few ignore-file and dependency hygiene items. Nothing Critical or High.

Severity counts: Critical 0, High 0, Medium 1, Low 7, Info 8.

Legend for every sentence with a number: **observed** = I ran it here; **expected** = the code says so; **estimated** = reasoning.

---

### WEB-01: No Content-Security-Policy on the Workspace (the comment says "comes later"); the smallest safe first step is four directives
- Severity: Medium   Confidence: High   Effort: S (first step) / M (full policy)
- Component: `web/next.config.ts`
- Evidence: `web/next.config.ts:3-9` sets `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: same-origin`, `Permissions-Policy: camera=(), microphone=(), geolocation=()`; line 3: `// Security headers for every response. CSP comes with the first real data screen.` The first real data screen shipped on 5 October 2026 (README, Roadmap step 2). No `Content-Security-Policy` header anywhere in `web/src` or `next.config.ts` (observed: grep). By contrast the static signed-out page has a hash-based CSP (`web/signed-out/index.html:20`: `default-src 'none'; img-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self'; script-src 'sha256-…'; base-uri 'none'; form-action 'none'`) and `docs/signed-out/deploy.sh:237-241` repeats it with `frame-ancestors 'none'`, nosniff and `Referrer-Policy: no-referrer` on the backend bucket.
- Impact (in this system's context): The app renders only React-escaped text (no `dangerouslySetInnerHTML`, `innerHTML`, `eval` or `javascript:` anywhere in `web/src`; observed grep, 0 hits) and every data-built `href` is https-validated (see "clean"), so the realistic XSS surface today is a future regression or a dependency. A CSP is the control that limits the blast radius of exactly that. `X-Frame-Options: DENY` covers framing in every browser that matters; `frame-ancestors`, `base-uri`, `form-action` and `object-src` have no equivalent header. Without `form-action 'self'`, an injected `<form action="https://…">` or a base-tag injection could redirect a form post (the Log out and Accept forms are plain posts).
- Recommendation: Two steps. **Step 1 (safe for Next.js 16, no nonce needed, cannot break dev or prod because it sets no `script-src`/`style-src`):**
  ```diff
  --- a/web/next.config.ts
  +++ b/web/next.config.ts
  @@
   const securityHeaders = [
     { key: "X-Frame-Options", value: "DENY" },
     { key: "X-Content-Type-Options", value: "nosniff" },
     { key: "Referrer-Policy", value: "same-origin" },
     { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=()" },
  +  // First CSP step (audit 17 October 2026): no framing, no <base> or form-target hijack, no plugins.
  +  // script-src with a per-request nonce follows from proxy.ts (step 2); until then this is the whole policy.
  +  { key: "Content-Security-Policy", value: "frame-ancestors 'none'; base-uri 'self'; form-action 'self'; object-src 'none'" },
   ];
  ```
  `form-action 'self'` is compatible with both form posts: `/logout/end` answers 303 to `/signed-out?gcp-iap-mode=…` or `/logout/done?…` (`web/src/lib/logout.ts:28-30`, same origin), `/invite/accept` answers 303 to `/` or `/invite/<token>` (`web/src/app/invite/accept/route.ts:42-43`, same origin); Chrome also enforces `form-action` on the redirect after a submission, and both redirects stay on the Workspace's host (IAP's own redirect from `/signed-out?gcp-iap-mode=CLEAR_LOGIN_COOKIE` lands on `/signed-out`, same host). Verify in `verify/theme.mjs` or `verify/layout.mjs` (they already read response headers against a running server) that the header is present on `/`, `/api/v1/me` and the 401 from the proxy.
  **Step 2 (full policy, M):** generate a nonce per request in `proxy.ts` (`crypto.randomUUID()` → header `x-nonce` on the forwarded request and the `Content-Security-Policy` header on the response), read it in `src/app/layout.tsx` via `headers()` and pass it to `next/script`; policy `default-src 'self'; script-src 'nonce-<n>' 'strict-dynamic'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'; object-src 'none'`. `style-src 'unsafe-inline'` is needed for React `style={}` attributes and Next's inlined critical CSS; Tailwind v4 emits a stylesheet (fine under `'self'`). `strict-dynamic` lets Next's nonce'd bootstrap load its chunks. Pages must then be dynamic (they are: `connection()` in `access.tsx:19`), because a nonce cannot be prerendered. Test with `verify/theme.mjs` and the browser console before enabling report-only → enforce.
- README check: new (not in Open decisions; only the code comment at `next.config.ts:3`). Style: no UI change.
- Disproof attempt: Looked for any inline `<script>`/`<style>` the step-1 policy could block: none of the four directives touches scripts or styles. Looked for a form posting off-site or a `<base>` tag: none (`grep -rn '<base\|action="http'` in `web/src`: 0). Looked for `object`/`embed`: 0. Step 1 stands as risk-free; step 2 is work, hence M.

### WEB-02: The invitation token in the request path reaches the request logs (already open); the least invasive mitigation is a log exclusion, not a protocol change
- Severity: Low   Confidence: High   Effort: S (exclusion) / M (fragment + POST)
- Component: `web/src/app/invite/[token]/page.tsx`, `web/src/app/invite/accept/route.ts`, `db/66_invitations.sql`
- Evidence: Token: 43 url-safe base64 characters = 32 bytes, SHA-256 of three `gen_random_uuid()` (`db/66_invitations.sql:257-263`, 366 bits of CSPRNG input → 256-bit token); only its SHA-256 is stored (`:171`, `:266-271`, unique index `:198`); validity `auth.invitation_valid_days` 1 to 30, default 7 (`:74`, `:453`); single use by `accepted_at` under `for update of i` (`:683-684`, `:693-696`); bound to the IAP-verified address (`:705-708`: `if v_email <> inv.email then 'wrong_account'`) and refused for a sign-in already in another tenant (`:697-700`). The page sets `referrer: "no-referrer"` and `robots: noindex` (`page.tsx:14`) and reads through the stable `cma.invitation_preview` only (`:30`); Accept is a same-origin form post with the token in the body (`page.tsx:48-49`, `route.ts:17-30`), the 303 Location is built only after `INVITE_TOKEN_RE` matched (`route.ts:28, :42`). Nothing logs the token (`route.ts:37` logs the SQLSTATE only).
- Impact (in this system's context): **Replay by a Cloud Logging reader who also passes IAP, within validity:** opening `/invite/<token>` gives them the preview only (workspace name, role name and the invited address: `wrong_account`, `:638-640`); accepting needs a sign-in whose IAP-verified address *is* the invited one, i.e. control of the invitee's Google account, in which case they also hold the invitation mail. So the residual risk is (a) disclosure of who was invited to which workspace with which role to anyone with `roles/logging.viewer` on the project plus any pulse4all.com account, and (b) a slightly longer window for an attacker who compromises the invitee's Google account during validity. Both small; the README's acceptance is justified. This is distinct from the 12 October 2026 decision (ingest request logs stay; no personal data in a path): a token is a secret, not personal data, and that decision is about `cma-ingest`.
- Recommendation: Least invasive and provable without touching the protocol: a **log exclusion** on the `_Default` sink for the invitation path, on both logs that keep the URL. **Console-only (Martin), Terminal, dry-run first:**
  ```
  gcloud logging sinks describe _Default --project=<prod project> --format='value(exclusions)'
  ```
  Expected output: the existing exclusions (possibly empty). Then:
  ```
  gcloud logging sinks update _Default --project=<prod project> \
    --add-exclusion='name=cma-web-invite-path,filter=httpRequest.requestUrl:"/invite/" AND (resource.type="cloud_run_revision" OR resource.type="http_load_balancer")'
  ```
  Expected output: `Updated [_Default].` Note the trade-off in the README (Open decisions bullet): the status codes of `/invite/*` requests are then not in the request log either; `/invite/accept` (the POST, no token in its path) could be kept by narrowing the filter to `httpRequest.requestUrl:"/invite/" AND NOT httpRequest.requestUrl:"/invite/accept"`. If Martin prefers the protocol change: fragment (`/invite#<token>`) + a small client that posts the token to `/invite/accept` and renders the preview from the answer; IAP's sign-in redirect chain ends in a 302 to the original URL without a fragment in `Location`, so browsers carry the fragment over (RFC 7231 §7.1.2), but as the README says this is unverified in IAP and would need a prod test; `verify/invitations.mjs` could prove the page reads `location.hash` and never puts the token in a path, but not IAP's behaviour. Also worth a line in the Open decision: lowering `auth.invitation_valid_days` to 2 or 3 for Pulse4all shrinks the window at no cost (tenant setting, not code).
- README check: already open (Open decisions, "The invitation token in request logs", README:2114; eighth Gemini audit 3.2; `docs/night-2026-10-15/NIGHT_NOTES.md` question 4). New information: the log-exclusion option is not listed there and is cheaper than the fragment approach; the 12 Oct 2026 decision on ingest logs does not cover it.
- Disproof attempt: Tried to find a way for a token holder with another pulse4all.com account to accept or to learn more than the preview: `accept_invitation` refuses on address mismatch before any write (`:705`), and the preview exposes no ids. Tried to find the token in any log line: `/invite/accept` logs the SQLSTATE only; `respond.ts:63` logs 5xx detail of API routes, none of which takes the token. Stands as Low.

### WEB-03: Test fixtures in `web/verify/iap-token.mjs` carry a real-looking staff address and a 21-digit Google-account-shaped `sub`, in a public repository
- Severity: Low   Confidence: Medium   Effort: S
- Component: `web/verify/iap-token.mjs:16, 30, 34, 51, 62, 64-65`
- Evidence: Line 30 signs the test token with a staff member's `pulse4all.com` address and `hd`; line 34 sets the default `sub` to `accounts.google.com:` plus a 21-digit number whose digit distribution (7 distinct digits) looks like a real Google account id, unlike the obviously synthetic fixtures in `db/67_verify_invitations.sql` (observed: 20 values there, all with 2 to 4 distinct digits, starting `80…` or `10…`). The same 21-digit value was committed earlier in `web/src/lib/auth/identity.ts` at `804786a` as the mock identity's subject (observed via `git show`, since replaced by `agent-one`). Line 16's default audience holds the real project number (an identifier, not a secret; it is also in `web/.env.example`). Rule 2 of the brief forbids writing the values here; none is reproduced.
- Impact (in this system's context): A Google `sub` is a stable personal identifier; README (Authentication) says ids "are pasted into the Studio editor when running, never committed". If this is a real account's id, it is a committed personal identifier in a public repository (CMA-038 proposes flipping it private). It is not a credential: nothing can be signed or impersonated with it, and the app matches on provider + subject only after IAP has proven the token. If it is synthetic, this is noise. I cannot tell statically.
- Recommendation: Replace both fixtures with obviously synthetic values, as `db/67` does, and keep the verifier's behaviour (the removed lines are shown as placeholders on purpose):
  ```diff
  --- a/web/verify/iap-token.mjs
  +++ b/web/verify/iap-token.mjs
  @@ line 30
  -  return new SignJWT({ email: "<the committed staff address>", hd: "pulse4all.com", ...(opts.claims ?? {}) })
  +  return new SignJWT({ email: "verify-iap@example.com", hd: "example.com", ...(opts.claims ?? {}) })
  @@ line 34
  -    .setSubject(opts.sub ?? "accounts.google.com:<the committed 21-digit value>")
  +    .setSubject(opts.sub ?? "accounts.google.com:100000000000000000001")
  @@ line 51
  -  status === 200 && body.includes("<the committed staff address>") && !body.includes("<the committed spoof address>") && !body.includes("manager@example.com");
  +  status === 200 && body.includes("verify-iap@example.com") && !body.includes("ceo@example.com") && !body.includes("manager@example.com");
  ```
  plus the same synthetic digits in the "sub without google prefix" case (line 62) and `ceo@example.com` in the two spoof headers (lines 64-65). The lead may ask Martin whether the committed value is his; if so, the history keeps it until the repository is private or rewritten, which is his call (CMA-038).
- README check: new; related to Open decisions bullet "The repository is public until launch … the README and `records/` name staff" (README:2031) and CMA-038.
- Disproof attempt: Checked whether the verifier needs a real address (the app lowercases and displays the email only, `iap.ts:75`, and matches on `sub`; in `CMA_DATA_MODE=mock` `findPrincipal` does not look up the subject): any value works. Checked that `db/67` fixtures are synthetic by shape (observed). Stands as Low with Medium confidence on whether the value is real.

### WEB-04: After verification the proxy forwards IAP's assertion and IAP's plain identity headers to the app unchanged
- Severity: Low   Confidence: High   Effort: S
- Component: `web/src/proxy.ts:41-45, 84-89`
- Evidence: `proxy.ts:41` copies every incoming header; lines 42-45 delete only `x-cma-identity-provider`, `x-cma-identity-sub`, `x-cma-identity-email` and `x-cma-mock-subject`; line 88 forwards the rest, so `x-goog-iap-jwt-assertion`, `x-goog-authenticated-user-email` and `x-goog-authenticated-user-id` reach every page and route. Nothing in `web/src` or `web/jobs` reads any `x-goog-*` header other than the proxy's `request.headers.get("x-goog-iap-jwt-assertion")` (observed: grep, 0 other hits), and nothing logs request headers (observed: `console.*(…headers` 0 hits).
- Impact (in this system's context): Today none, because nothing downstream reads or logs them. Defence in depth: the assertion is a bearer proof of identity valid for its `exp` (IAP issues ~10-minute tokens); a future `console.error(request.headers)` in a route, or a dependency that logs headers on error, would put a replayable token into Cloud Logging, and a future reader of `x-goog-authenticated-user-email` would re-introduce the plain-header trust the README forbids. Removing them after verification makes both impossible by construction, which is how the `x-cma-*` headers are already treated (comment at `proxy.ts:16-18`). Not a weakening of verification: the token is verified first, then dropped.
- Recommendation:
  ```diff
  --- a/web/src/proxy.ts
  +++ b/web/src/proxy.ts
  @@ function pass(headers: Headers, identity: Identity) {
  +  // The app never sees IAP's own headers: the token has done its work here, and the plain identity
  +  // headers are never to be trusted (README, Authentication), so nothing downstream can read or log them
  +  headers.delete("x-goog-iap-jwt-assertion");
  +  headers.delete("x-goog-authenticated-user-email");
  +  headers.delete("x-goog-authenticated-user-id");
     headers.set(IDENTITY_HEADERS.provider, identity.provider);
  ```
  Provable by `verify/iap-token.mjs` only indirectly (it reads the page body); a direct proof is a pure check in a `verify/boundaries.mjs` (WEB-09) that `proxy.ts` deletes the three names before `NextResponse.next`.
- README check: new. Authentication says "incoming copies are stripped" of the `x-cma-*` headers; this extends the same rule to IAP's headers.
- Disproof attempt: Checked whether any server component or the data layer uses the assertion for a second check (no), whether `x-goog-authenticated-user-*` is used for display (no: `identity.email` comes from the verified token via `x-cma-identity-email`). Stands as Low, pure defence in depth.

### WEB-05: What `web/verify/iap-token.mjs` does not cover
- Severity: Info   Confidence: High   Effort: S
- Component: `web/verify/iap-token.mjs`, `web/src/lib/auth/iap.ts`
- Evidence: The verifier covers: valid, missing, wrong audience, wrong issuer, expired, future `iat`, wrong signer, garbage, `sub` without prefix, `sub` not numeric, spoofed `x-cma-identity-*` with and without a token, mock header and `?as=` in iap mode, health without a token (lines 54-71, 16 cases). Not covered, with the expected outcome from the code: **alg=none** (jose refuses: `algorithms: ["ES256"]`, `iap.ts:53`); **HS256 signed with the public key** (jose refuses: algorithm not allowed and the JWK is `EC`, so no key-type confusion is possible); **wrong `typ`** (jose does not check `typ` unless asked; the app does not either, harmless); **`nbf` in the future** (jose refuses with clockTolerance 30 s); **unknown `kid` / rotation** (jose: `JWKSNoMatchingKey` → one reload unless within the 30 s cooldown → 401; `jose/dist/webapi/jwks/remote.js:66-72`); **token for another backend** is the "wrong audience" case, covered; **missing `iat`** (`iap.ts:61` refuses); **missing `email`** (`iap.ts:64` refuses); **`sub` with more than 64 digits** (`iap.ts:72` refuses); **header name case variants** (Node normalises to lower case: no issue); **duplicate `x-goog-iap-jwt-assertion` headers** (`Headers.get` joins them with `, ` → not a JWT → 401); **key-set fetch failure** (see WEB-08: `jwtVerify` rejects → 401); **upper-case email lowercased** (`iap.ts:75`); **a valid token on an API route** (only `/` is hit). All of these are expected from the code, none observed.
- Impact: The verifier is a verify-by-breaking script against a running server; its gaps are in cases the libraries already refuse. Worth adding the cheap ones (alg=none, HS256, nbf, unknown kid, missing iat/email, duplicate header) so a future jose major or a changed option cannot silently widen the gate.
- Recommendation: Seven more `results.push(...)` lines in the same style, each expecting 401; `alg: "none"` needs a hand-built token (`base64url(header).base64url(payload).`), HS256 a raw `crypto.createHmac("sha256", <public JWK as bytes>)` over the signing input (jose's `importJWK` would refuse an EC key for HS256, so build the signature by hand). Also note the verifier needs a server, so it stays Martin's (CLAUDE.md).
- README check: new. Authentication lists exactly the eight covered cases.
- Disproof attempt: Read `iap.ts` and the jose remote JWKS code for each case; all refuse. No gap found in the code, only in the test list.

### WEB-06: End workday on My day uses a server action outside the app's one CSRF design, while the guarded route for it exists
- Severity: Low   Confidence: High   Effort: S
- Component: `web/src/app/actions.ts`, `web/src/components/WorkdayPanel.tsx:23, 122`, `web/src/app/api/v1/me/day/end/route.ts`
- Evidence: `actions.ts:1-14` (`"use server"`, the only such file: observed grep) ends the caller's own workday via `getAccess()` and `data().endWorkday`, then `revalidatePath`. `WorkdayPanel.tsx:122` calls it; the same component sends every other write through `fetch` with `x-cma-request: 1` (`:111`). `POST /api/v1/me/day/end` exists with `assertSameSiteWrite` (`route.ts:9`; the ordering check below counts it among the 52 guarded writes) and is what `verify/api.mjs:103` tests. Next.js protects server actions itself: `node_modules/next/dist/server/app-render/action-handler.js:438-462` compares the `Origin` host with `x-forwarded-host` or `host` and aborts with "Invalid Server Actions request" on a mismatch; a request without `Origin` is let through with a warning (browsers always send `Origin` on a cross-site POST, so a browser-borne CSRF is refused). No `experimental.serverActions.allowedOrigins` is configured (observed: `next.config.ts` has none), so only the request's own host is allowed.
- Impact: CSRF-safe today, by Next's check. The cost is two mechanisms for one rule: `assertSameSiteWrite` (custom header + `Sec-Fetch-Site`) is what the README, the verifiers and `origin.ts` describe, and `verify/api.mjs` cannot exercise a server action. A reviewer auditing "every write has the guard" (the lead's mechanical list) finds one write that does not, and has to reason about Next internals and the load balancer's `Host`/`x-forwarded-host` behaviour instead (see WEB-15). The principal is taken server-side (`actions.ts:7-10`), so there is no authorisation gap.
- Recommendation: Replace the action with the existing route and delete `actions.ts`:
  ```diff
  --- a/web/src/components/WorkdayPanel.tsx
  +++ b/web/src/components/WorkdayPanel.tsx
  @@
  -import { endWorkdayAction } from "@/app/actions";
  @@
  -      await endWorkdayAction();
  +      const res = await fetch("/api/v1/me/day/end", { method: "POST", headers: { "x-cma-request": "1" } });
  +      if (!res.ok) { /* the panel's existing error path */ }
  +      router.refresh();
  ```
  (exact lines to be fitted to the component's existing `send` helper at `:109-111`; `router.refresh()` replaces `revalidatePath`). Then `verify/boundaries.mjs` (WEB-09) can assert `"use server"` appears nowhere. If the action stays, document in README (API, "Rules in every call") that server actions rely on Next's Origin/Host check and that `allowedOrigins` must stay unset.
- README check: new (README describes the custom-header guard for "every write"; the action is not mentioned).
- Disproof attempt: Checked whether Next's check can be bypassed from a browser: it needs a request with no `Origin` header, which a cross-site `fetch`/form POST never produces; `Origin: null` (sandboxed iframe) is compared as the string `null` and mismatches the host → refused. Stands as Low (hygiene with a real benefit: one guard, one verifier).

### WEB-07: The CSRF guard runs after the principal lookup, so a refused cross-site write still costs a database transaction
- Severity: Info   Confidence: High   Effort: S
- Component: `web/src/lib/api/respond.ts:53-85`; all 52 write handlers
- Evidence: Every write calls `assertSameSiteWrite(request)` as the first line *inside* the `forPrincipal` callback (e.g. `me/preview/route.ts:17-18`, `team/directory/route.ts:34-35`, `messages/route.ts:16-17`; observed by the ordering script: 52 of 52 handlers have the guard before any body read, none without it). `forPrincipal` first awaits `getAccess()` (`respond.ts:55`), which runs `findPrincipal` (two transactions: `withoutTenant` for the tenant lookup, then the tenant's `app_user`) before the callback runs.
- Impact: Correctness is unaffected (the guard still refuses before the body is read or anything is written). A forged cross-site request from an authenticated browser costs one principal lookup; behind IAP and with the LB in front this is not a meaningful DoS vector. It is the kind of ordering a reviewer expects the other way round, and it would let the guard answer 403/400 even when the database is down (today such a request gets 503).
- Recommendation: Make `forPrincipal` take an optional pre-check, or simply call `assertSameSiteWrite(request)` before `return forPrincipal(…)` in the 52 handlers (a mechanical edit; `ApiError` thrown outside `forPrincipal` would then need the same `fail()` mapping, so the cleaner change is a `forPrincipal(handler, { write: request })` option that runs the guard first and maps the error). Low priority.
- README check: new.
- Disproof attempt: Confirmed no handler reads the body or writes before the guard (observed, 52/52). Info only.

### WEB-08: Key-set fetch behaviour: fails closed, with an availability coupling to `www.gstatic.com` after ten minutes
- Severity: Info   Confidence: High   Effort: –
- Component: `web/src/lib/auth/iap.ts:25-34`, `jose@6.2.12` `dist/webapi/jwks/remote.js`
- Evidence: `createRemoteJWKSet(url, { cooldownDuration: 30_000, cacheMaxAge: 600_000 })` (`iap.ts:30`), one instance per URL per process (`:25-33`). In jose (observed in the installed source, `remote.js:42-72`): the first verification and every verification once the cached set is older than `cacheMaxAge` **awaits a reload** (`:66`); concurrent requests share one in-flight fetch (`pendingFetch`, `:51-60`); the fetch has a 5 s timeout (`:42`, default) and throws `JWKSTimeout`/`JOSEError` on a non-200 or bad JSON (`:16-24`); an unknown `kid` triggers one reload unless the set is younger than `cooldownDuration` (`:69-72`). A thrown reload error propagates out of `jwtVerify` → `IapVerifyError` → `unauthenticated("invalid")`, 401 with `x-cma-auth: invalid` and a `console.warn` naming the jose error code (`proxy.ts:54-59`, never the token).
- Impact: **Fails closed**, as it should: no key set, no page. The consequence is that once the cached set is older than ten minutes, a `www.gstatic.com` outage or an egress problem makes every request a 401 until a fetch succeeds (jose does not fall back to the stale set after `cacheMaxAge`). Key rotation is handled (unknown `kid` → reload once, bounded by the 30 s cooldown against a flood of bad `kid`s). The 5 s timeout bounds the latency of a slow fetch to one request per instance.
- Recommendation: None to the code (raising `cacheMaxAge` would trade security for availability and is not proposed). For the record in README (Authentication): "key set cached 10 minutes per instance, refetched on expiry or an unknown key id, 5 s timeout; a failed fetch is a 401, not a pass". A Cloud Monitoring alert on the `iap: token rejected` warning rate (log-based metric) would show such an outage; that is Console-only and the lead's section 5.4/5.5 may own it.
- README check: new (Authentication does not describe the caching).
- Disproof attempt: Looked for any path where a stale or missing set lets a token through: none; `local` is only called after a successful reload or within `cacheMaxAge`. Info.

### WEB-09: The import boundaries hold with one blur (`CmaDbError` from `@/lib/db/client` in pages, routes and the mock); a pure `verify/boundaries.mjs` would keep them
- Severity: Low   Confidence: High   Effort: S
- Component: `web/src/lib/db/client.ts`, `web/src/app/configuration/sources/[id]/page.tsx:5`, `web/src/app/invite/accept/route.ts:3`, `web/src/lib/api/respond.ts:4`, `web/src/lib/data/mock.ts:7`
- Evidence (observed greps): `pg` and `@google-cloud/cloud-sql-connector` are imported only in `src/lib/db/client.ts` (plus `jobs/`); `@/lib/auth/iap` only in `src/proxy.ts`; `@/lib/data/postgres` only in `src/lib/data/index.ts`; `process.env` only in `src/lib/config.ts` and `src/lib/db/client.ts`; `next/headers` in `src/lib/auth/identity.ts` and `src/components/Shell.tsx:17` (UI cookies for the rail and hints, `:55-57`, not identity); `"use server"` only in `src/app/actions.ts`; `"use client"` in 39 components; no `x-goog-*` read outside the proxy. The one blur: four files import `CmaDbError` from `@/lib/db/client`, the module that also owns the pool and the connector. `client.ts` is `server-only` (`:1`), so this cannot leak to the client bundle, and `mock.ts` importing it means the mock data layer pulls in `pg` at module load (harmless on the server, but it couples the mock to the real driver).
- Impact: Boundaries are a design rule of this codebase (README, API: "the identity comes from proxy.ts only, the principal from the data layer only"), enforced today by convention and review. One grep-based verifier makes the rule mechanical and cheap to keep, like `verify/signed-out.mjs` already does for the proxy's matcher (`verify/signed-out.mjs:218-227`).
- Recommendation: (1) Move `CmaSqlState`, `CMA_SQLSTATE`, `CmaDbError` and `translateDbError` into `src/lib/db/errors.ts` (pure, no imports) and re-export them from `client.ts`; the four importers switch to `@/lib/db/errors`. (2) Add `web/verify/boundaries.mjs` (pure, `node verify/boundaries.mjs`, PASS/FAIL per rule, `--provoke` flips the fixtures as the other verifiers do) with these rules, each a regex over `src/**`:
  1. `from "pg"` and `from "@google-cloud/cloud-sql-connector"` only in `src/lib/db/client.ts`.
  2. `from "@/lib/db/client"` only in `src/lib/data/postgres.ts` (after step 1).
  3. `from "@/lib/auth/iap"` only in `src/proxy.ts`.
  4. `from "@/lib/data/postgres"` and `from "@/lib/data/mock"` only in `src/lib/data/index.ts`.
  5. `process.env` only in `src/lib/config.ts` and `src/lib/db/client.ts`.
  6. `from "next/headers"` only in `src/lib/auth/identity.ts` and `src/components/Shell.tsx`.
  7. Every `route.ts` exporting `POST|PUT|PATCH|DELETE` contains `assertSameSiteWrite(request)` or `isSameOriginPost(` *before* the first `jsonBody(`/`request.json(`/`request.formData(` in the same handler (the awk I ran, as a rule).
  8. Every `route.ts` under `src/app/api/v1` calls `forPrincipal(`; `/api/health` is the one route that may not.
  9. No `dangerouslySetInnerHTML`, `innerHTML`, `eval(`, `new Function(` or `javascript:` in `src/**`.
  10. Every `fetch(` with `method: "POST"|"PUT"` in `src/components/**` carries `x-cma-request` (directly or via a `HEADERS` constant in the same file).
  11. `"use server"` appears in no file (after WEB-06), or only in `src/app/actions.ts` until then.
  12. `proxy.ts` deletes `x-cma-identity-provider`, `x-cma-identity-sub`, `x-cma-identity-email`, `x-cma-mock-subject`, and (after WEB-04) the three `x-goog-*` names, before `NextResponse.next`.
  13. No `x-goog-authenticated-user` string in `src/**`.
  Add it to `npm run verify` and to the CLAUDE.md list of pure verifiers.
- README check: new.
- Disproof attempt: Ran every grep above; the only hits are the four `CmaDbError` imports and Shell's UI cookies. Stands as Low (hygiene with a real benefit).

### WEB-10: Dependencies and supply chain: 5 high advisories are dev-only with no non-breaking fix (already open); runtime trees are clean; Dependabot proposal
- Severity: Low   Confidence: High   Effort: S
- Component: `web/package.json`, `web/package-lock.json`, `ingest/package.json`, `ingest/package-lock.json`
- Evidence (observed, 17 October 2026, JSON saved under `/var/tmp/5.1/`): `web` `npm audit --omit=dev`: 0 vulnerabilities (181 prod, 96 optional deps). `web` `npm audit`: 5 high, all one chain `eslint-config-next@16.3.8 → @next/eslint-plugin-next → fast-glob → micromatch → braces` (advisory 1240992, "braces vulnerable to stack-exhaustion denial of service through deeply nested patterns"); `fixAvailable` on all five is `{ name: "eslint-config-next", version: "14.2.35", isSemVerMajor: true }`, i.e. **the only fix npm knows is a major downgrade; `npm audit fix` without `--force` would change nothing** (expected from the JSON; not run). `ingest`: 0 vulnerabilities in both runs (165 prod, 80 dev). `npm outdated` web: `next` and `eslint-config-next` 16.3.8 → 16.4.2 (wanted stays 16.3.8: pinned exact), `react`/`react-dom` 19.2.8 → 19.3.1 (pinned), `@google-cloud/cloud-sql-connector` 1.12.0 → 1.12.1, `playwright` 1.63.0 → 1.64.1, `@types/node` 20.19.43 (latest 26.x; runtime is Node 22), `eslint` 9 → 10, `typescript` 5.9.3 → 7.0.2; ingest: `cloud-sql-connector` 1.12.0 → 1.12.1, `eslint`/`@eslint/js` 9 → 10. Lockfiles: `lockfileVersion: 3` in both; every `resolved` points at `https://registry.npmjs.org/` (0 exceptions in either); `web` has 6 entries without `integrity`/`resolved`, all optional sub-dependencies of `@tailwindcss/oxide-wasm32-wasi` (`@emnapi/*`, `@napi-rs/wasm-runtime`, `@tybys/wasm-util`, `tslib`), the usual npm shape for a platform package that is not installed on linux-x64; `ingest` 0. `npm ls --all | grep -c deduped`: web 552, ingest 111. Duplicate majors (web): `minimatch` 3/9/10, `brace-expansion` 1/2/5, `semver` 6/7, `lru-cache` 5/10, `picomatch` 2/4, `debug` 3/4, `json5` 1/2, `globals` 14/16, `eslint-visitor-keys` 3/4/5, `ignore` 5/7, `balanced-match` 1/4, the `string-width`/`strip-ansi`/`ansi-*`/`wrap-ansi`/`emoji-regex` pairs, and the Google auth stack `gaxios` 7/8, `gcp-metadata` 8/9, `google-auth-library` 10/11, `google-logging-utils` 1/2 (the last four also in ingest). `engines`: `node >=22` in both; no `.npmrc` with `engine-strict`. Dockerfile: `npm ci --no-audit --no-fund` from the lockfile, three stages, non-root `app` user, standalone output, `images.unoptimized` (no sharp), `poweredByHeader: false`.
- Impact: Nothing vulnerable ships in either image (observed: both `--omit=dev` runs are 0). The 5 high advisories are a lint-time DoS in a devDependency and remain exactly as README's Open decision says: no fix exists short of a major downgrade. The duplicate majors are the ordinary eslint/Next/Google tooling spread, not a risk. The missing `integrity` on six optional wasm entries means `npm ci` cannot verify them if a platform ever selects them; today it never does on the build image (linux-x64 alpine). `@types/node@20` against Node 22 only risks missing types.
- Recommendation: (1) Leave the audit as is (settled). (2) Pin review cadence with Dependabot, monthly, grouped minor+patch, no auto-merge, labels; proposed `.github/dependabot.yml` (the repo has no `.github/` yet, observed):
  ```yaml
  # Dependabot (audit 17 October 2026): monthly, grouped minor+patch, one PR per project, never auto-merged.
  # Majors arrive as separate PRs and are reviewed with the README's Open decision on npm audit.
  version: 2
  updates:
    - package-ecosystem: npm
      directory: /web
      schedule:
        interval: monthly
        day: monday
        time: "06:00"
        timezone: Europe/Amsterdam
      open-pull-requests-limit: 3
      labels: [dependencies, web]
      commit-message:
        prefix: "deps(web)"
      groups:
        web-minor-patch:
          patterns: ["*"]
          update-types: [minor, patch]
      ignore:
        # next, react and react-dom are pinned exactly and move together, by hand, with a prod check
        - dependency-name: next
        - dependency-name: eslint-config-next
        - dependency-name: react
        - dependency-name: react-dom
    - package-ecosystem: npm
      directory: /ingest
      schedule:
        interval: monthly
        day: monday
        time: "06:00"
        timezone: Europe/Amsterdam
      open-pull-requests-limit: 3
      labels: [dependencies, ingest]
      commit-message:
        prefix: "deps(ingest)"
      groups:
        ingest-minor-patch:
          patterns: ["*"]
          update-types: [minor, patch]
    - package-ecosystem: docker
      directory: /web
      schedule:
        interval: monthly
      labels: [dependencies, web]
  ```
  Note for Martin: a Dependabot PR touching `web/**` does not deploy by itself (main only accepts PRs and he squash-merges); each merge *does* deploy prod (CLAUDE.md), so the monthly cadence and the `ignore` of the pinned four keep the deploy decision his. GitHub's Dependabot alerts (Settings → Code security) are a Console-only switch for him and complement this file. (3) Small: `web/.npmrc` with `engine-strict=true` and `@types/node` to `^22` (devDependency, no runtime effect).
- README check: already open for the audit (Open decisions, README:2010; CMA-035). The Dependabot proposal and `.npmrc`/`@types/node` are new.
- Disproof attempt: Re-read the audit JSON for a non-major `fixAvailable` (none: all five say `isSemVerMajor: true`). Checked that no `resolved` escapes the registry (0) and that the six integrity-less entries are optional and platform-specific (all under `oxide-wasm32-wasi`). Stands.

### WEB-11: Ignore-file coverage gaps for the people template, environment files and `local-records/`
- Severity: Low   Confidence: High   Effort: S
- Component: `.gitignore`, `.gcloudignore`, `web/.dockerignore`, `ingest/.dockerignore`, `ingest/.gitignore`
- Evidence (observed): Root `.gitignore` ignores `db/people_add_*.sql` (keeping the template), `hubspot/build/`, `docs/import/*.csv`, `tools/*.csv`; it does not ignore `.env*` at the root or under `ingest/` (only `web/.gitignore:33` has `.env*`). `ingest/.gitignore` holds `node_modules/` only. `.gcloudignore` (used by a manual `gcloud builds submit`, not by the trigger) leaves out `.git`, `web/node_modules`, `web/.next`, `records`, `*.zip`, but not `db/people_add_*.sql`, `local-records`, `ingest/node_modules`, `.env*`, and has no `#!include:.gitignore` line. `ingest/.dockerignore` excludes `node_modules`, `verify`, `tools`, `.gitignore`, `eslint.config.mjs` but not `.env*` or `.git`; `web/.dockerignore` excludes `.env*`, `.git`, `verify`, `records`, `*.md`. History check: no `.env` file was ever committed except `web/.env.example` (values empty; it holds the project number as a comment), `db/people_add_*.sql` only as the template, `hubspot/build/` never (observed: `git log --all --name-only`).
- Impact: Today nothing has leaked (history clean, observed). The gaps are the paths by which it could: a filled-in `db/people_add_prod.sql` on Martin's machine would be uploaded by a manual `gcloud builds submit` (the trigger builds from GitHub, so only the manual path); an `ingest/.env` created for a local run would be committed by `git add -A` and copied into the ingest image by `docker build`. `local-records/` is tracked (see WEB-12).
- Recommendation:
  ```diff
  --- a/.gitignore
  +++ b/.gitignore
  @@
  +# Environment files anywhere (web/.gitignore already has its own); the example file stays
  +.env
  +.env.*
  +!.env.example
  +!web/.env.example
  --- a/.gcloudignore
  +++ b/.gcloudignore
  @@
   .git
  +#!include:.gitignore
   web/node_modules
   web/.next
  +ingest/node_modules
   records
  +local-records
   *.zip
  --- a/ingest/.dockerignore
  +++ b/ingest/.dockerignore
  @@
   node_modules
  +.env
  +.env.*
  +.git
   verify
  ```
- README check: new. Related: the public-repository bullet (README:2031) and CMA-038.
- Disproof attempt: Searched the full history for `.env` files (only the example), for `people_add_*.sql` (only the template), for key files (`.pem`, `.p12`, service-account JSON: none). The gaps are prospective, hence Low.

### WEB-12: `local-records/` is tracked by git in a public repository
- Severity: Info   Confidence: High   Effort: S
- Component: repository root; `local-records/**`
- Evidence: `git status --short` shows `M local-records/5.6-speed-measured/…` and untracked `local-records/5.3-database/` etc. (observed), i.e. the directory is not ignored and parts of it are already committed on the session branch. The brief's preamble treats it as the audit's raw-findings area; the public-repository rule (preamble 7; README:2031) applies to anything pushed.
- Impact: Lead's call, not a web finding as such: raw findings may name staff roles, measured figures or Critical/High detail that the brief says belongs only in the final session message until fixed. Not a vulnerability.
- Recommendation: Either add `local-records/` to `.gitignore` before any branch is pushed, or make the lead's consolidation pass the only thing that leaves the sandbox. Noted here so it is not lost.
- README check: new (process).
- Disproof attempt: Checked `git check-ignore local-records` (not ignored) and the branch's tracked files. Info.

### WEB-13: `cloudbuild.yaml` defaults `_DATA_MODE: mock` and `_IAP_AUDIENCE: ""`; fail-closed holds for auth, not for data
- Severity: Info   Confidence: High   Effort: S
- Component: `cloudbuild.yaml:68, 75-87`
- Evidence: Line 68 sets all service env vars from substitutions; defaults (lines 75-87): `_AUTH_MODE: iap` (good: a trigger that forgets it still verifies tokens), `_IAP_AUDIENCE: ""` (good: `iap.ts:47` throws "IAP audience is not configured" → every request 401, fail closed), `_DATA_MODE: mock` (a trigger that forgets it runs prod on in-memory mock data behind real IAP), `_LOGOUT_TARGET: legacy`. The prod trigger `cma-web-main` overrides them (README, Release flow); the file is the fallback.
- Impact: No exposure: mock data holds no real person, and `findPrincipal` in mock mode cannot match a Google `sub`, so a real visitor gets "no access yet" (expected). It is a configuration trap, not a hole: the README says unset `CMA_DATA_MODE` means `api`, which the app honours (`config.ts:23`), but this file's default says `mock`, so the two "fail closed" statements differ by one word.
- Recommendation: `_DATA_MODE: api` as the file default (a CONFIG CHANGE in the brief's sense: it changes a substitution default, so it needs its own labelled section and Martin's confirmation that the trigger sets `_DATA_MODE` explicitly, which README says it does). Not applied.
- README check: new; touches "Release flow" and CLAUDE.md "Never change cloudbuild.yaml substitutions … without saying so".
- Disproof attempt: Confirmed `_AUTH_MODE` and `_IAP_AUDIENCE` defaults fail closed (they do). Info.

### WEB-14: `/api/health` exposes the running mode and version; exempt from the proxy, still behind the load balancer and IAP
- Severity: Info   Confidence: High   Effort: –
- Component: `web/src/app/api/health/route.ts`, `web/src/proxy.ts:107`
- Evidence: Answers `{ status: "ok", version: <git SHA>, auth: "iap"|"mock", data: "api"|"mock" }` with `cache-control: no-store`; no database round trip (the `ping()` in `db/client.ts:238` is not used by it; observed). The proxy's matcher excludes `api/health`, `_next/static`, `_next/image`, `icon.png`, `brand/` (`:107`). Cloud Run ingress is `internal-and-cloud-load-balancing` and IAP sits on `cma-web-backend` (README, Authentication), so an external caller still passes IAP; only Cloud Run's own probes and the deploy's smoke test reach it directly.
- Impact: The SHA and the two modes are not sensitive (the repository is public; the modes are the README's). No user data, no database state. Fine as is.
- Recommendation: None. If a database check is ever added to it, keep it off the proxy-exempt route or rate-limit it, so an unauthenticated probe cannot drive connections.
- README check: new (README does not mention `/api/health`; it could, in one line under Release flow).
- Disproof attempt: Checked for data access in the route (none). Info.

### WEB-15: `isSameOriginPost`'s fallback compares `Origin` with the request's `Host`, which behind the load balancer may be the container's host
- Severity: Info   Confidence: Medium   Effort: S
- Component: `web/src/lib/origin.ts:12-20`, `web/src/app/logout/end/route.ts:17-21`, `web/src/app/invite/accept/route.ts:17-21`
- Evidence: `isSameOriginPost` passes on `Sec-Fetch-Site: same-origin`, refuses any other non-null value, and only without the header compares `new URL(origin).host` with the `host` header (`origin.ts:13-19`). Comments in `logout.ts:12-13` and `proxy.ts:67` say the request's own host behind the load balancer is the container's, not the public domain. If so, a browser that sends no `Sec-Fetch-Site` (Safari before 16.4, Firefox before 90, Chrome before 76) would have its legitimate `Origin: https://workspace…` compared with the container host and be refused (fail closed). Modern browsers all send `Sec-Fetch-Site`, and `verify/api.mjs:406` tests the same-origin header path only.
- Impact: No security weakening: the fallback can only refuse, never admit a cross-site post (an attacker cannot set `Origin` to the container host from a browser). Availability for very old browsers only; the Workspace is desktop, keyboard-first and Pulse4all-managed, so this is theoretical. Next's server-action check uses `x-forwarded-host` first (`action-handler.js:351-366`), which suggests the LB does forward the public host there; `isSameOriginPost` does not read `x-forwarded-host`.
- Recommendation: Either read `x-forwarded-host` before `host` in the two routes (Google's external HTTPS load balancer sets it; a client cannot override it through the LB), or document the fallback as "modern browsers only" in `origin.ts`. Verify in prod which header carries the public host (Martin can compare the LB's request log `httpRequest.requestUrl` with a dev request's view).
- README check: new.
- Disproof attempt: Tried to construct an admit path: none; the function is monotone towards refusal. Info.

### WEB-16: Six lockfile entries without `integrity` (optional wasm sub-dependencies)
- Severity: Info   Confidence: High   Effort: –
- Component: `web/package-lock.json`
- Evidence: See WEB-10; all six under `node_modules/@tailwindcss/oxide-wasm32-wasi/node_modules/*`, `optional: true`, no `resolved`.
- Impact: None on the build image; a WASI fallback platform would install them unverified.
- Recommendation: None now; regenerate the lockfile on the next Tailwind bump and see whether npm fills them.
- README check: new. Info.

---

## Checked and found clean (with evidence)

- **IAP verification is ES256-only, issuer-, audience-, exp-, nbf- and future-iat-checked:** `iap.ts:50-55` (`algorithms: ["ES256"]`, `issuer`, `audience`, `clockTolerance: 30`), `:60-63` (`iat` missing or > now+30 s refused), `:64-66` (`sub`/`email` strings required), `:69-74` (`sub` must be `accounts.google.com:` + 1–64 digits; anything else refused, never guessed), `:47` (empty audience refused). Issuer and JWKS URL are constants (`:12-13`); the JWKS override `IAP_JWKS_URL` is read from env only (`config.ts:27`) and `.env.example` says to leave it empty in prod.
- **Mock mode only when explicit:** `config.ts:14-23`: unset or empty `CMA_AUTH_MODE` → `iap`, any other value than `iap|mock` throws at startup; same for `CMA_DATA_MODE` → `api`; `CMA_LOGOUT_TARGET` typo throws (`logout.ts:21-25`). `proxy.ts:47` branches on `appConfig.authMode === "mock"` only.
- **Every incoming identity header is stripped before anything else:** `proxy.ts:41-45` deletes `x-cma-identity-provider`, `-sub`, `-email` and `x-cma-mock-subject` on every request in both modes; `pass()` sets them from the verified result only (`:84-89`). `getIdentity()` reads only those three (`identity.ts:106-113`). No `x-goog-authenticated-user-*` read anywhere (observed grep).
- **Mock subject switch is inert in iap mode:** `?as=`, header and cookie are read only inside `mock()` (`proxy.ts:63-82`), reached only when `authMode === "mock"`; an invalid subject is a 400, never a fallback (`:66, :80`); the `?as=` 303 target is `request.nextUrl.clone()` minus the parameter (same URL, `:68-70`), cookie `httpOnly, sameSite: lax, secure, path /` (`:72`). Mock identities carry provider `mock` and the dev seed stores subjects under system `mock` (`identity.ts:71-83`), so a mock subject can never match a Google row.
- **Preview as role never widens and the database checks real permissions:** `preview.ts:45-48` intersection; `:56-71` unknown role, ill-formed key, or a non-admin → no preview; `canPreview` from the real set (`:61`); `identity.ts:125-126` keeps `real` and passes the narrowed principal to screens and routes; `respond.ts:58` gives routes the narrowed one and `{ real: true }` only to `/me/preview`; `cma.current_user_id()` is the real user in every transaction (`db/client.ts:215-225`). Cookie set by `POST /api/v1/me/preview` only, `httpOnly, secure, sameSite lax, path /, maxAge 12 h` (`me/preview/route.ts:27-29`), cleared on Log out (`logout/end/route.ts:34`), role key validated by regex and against `listRoles(me)` (`:21-25`). Observed: `verify:preview` 18 PASS.
- **CSRF guard on every state-changing route:** mechanical list (observed): 113 exported handlers in 103 route files; 52 `POST|PUT` handlers under `/api/v1` all import and call `assertSameSiteWrite(request)` before any body read (awk ordering check: 52 ok, 0 `NO_GUARD`, 0 `BODY_BEFORE_GUARD`); no `PATCH`/`DELETE`/`OPTIONS` exists; no `export const GET = …` style handlers (0). The two plain-form posts `/logout/end` and `/invite/accept` use `isSameOriginPost` first (`:17-21` in both). Every GET and write under `/api/v1` goes through `forPrincipal` (observed: 101 of 101 v1 routes; `/api/health` is the one route without it by design). All 15 client `fetch` writes send `x-cma-request: 1` (observed grep of `fetch(` with `method: "POST"|"PUT"`: ClockInCard, PersonDialog, DayEditor, configuration/shared, InviteDialog, WorkdayPanel, RosterPlanner, MessageComposer, PreviewControls, Inbox, InvitationsSection, MessageCenter). `verify/api.mjs` exercises the cross-site refusal on seven writes (lines 226, 307, 392, 601, 661, 712, 800).
- **`assertSameSiteWrite` design is sound:** `respond.ts:77-85`: refuses any `Sec-Fetch-Site` other than `same-origin` or `none` (so `same-site` from a sibling host is refused too), then requires the custom header. Allowing `none` is correct: it marks user-initiated navigations (address bar, bookmark), which a cross-site page cannot produce for a `fetch`, and a navigation cannot carry a custom header anyway, so the second check still applies. Without `Sec-Fetch-Site` (old browser, curl) only the header check holds, which is enough because the app grants no CORS (`Access-Control-Allow-*` nowhere in `web/src` or `next.config.ts`, observed), so a foreign origin's preflight for `x-cma-request` fails.
- **Input validation:** `respond.ts:97-133, 151-160`: `dateParam` (regex + round-trip check), `uuidParam` (canonical form, lower-cased), `teamRangeParams` (from ≤ to, ≤ 92 days), `jsonBody` (object only). Every dynamic segment is validated (observed list: `[id]` → `uuidParam`, `[userId]` → `uuidParam`, `[date]` → `dateParam`, `[key]` → `checkKey` with a regex and ≤ 40 chars, `[dimension]` → `checkDimension`, `[weekStart]` → `weekStartParam`; 33 of 33 files). `lib/api/configuration.ts` checks shape and bounds for every configuration body (21 regexes, 11 length limits, 8 integer checks; e.g. `checkLinkInput` requires `^https://\S+$` ≤ 2000, `checkSettingInput` value ≤ 100, `checkSettingsInput` refuses keys containing secret/token/password/key and objects over 4 kB via `settingsProblem`). `lib/api/forms.ts`, `calls.ts`, `roster.ts` delegate to `lib/reports` and `lib/sources` parsers (market `^[A-Z]{2}$`, answer value ≤ 200, field name regex). Messages: title ≤ 120, body ≤ 500 (`lib/messages.ts:15-16, 59-61`); corrections reason 3–500 (`corrections/route.ts:66-67`); directory POST: email regex ≤ 200, loginSystem token ≤ 40, loginId ≤ 200 no spaces, keys by regex, displayName ≤ 100, timeZone ≤ 60 (`team/directory/route.ts:36-48`); invitations: `parseInvitationInput` (`lib/invitations.ts:83-114`) with team keys ≤ 50, skills ≤ 100, level 1–9 integer. Time zones are validated by the database (`cma.is_timezone`, `db/05_time_model.sql:73-82, 207`). `?limit` on the inbox is capped at 200 (`me/messages/route.ts:9, 15`).
- **No body field reaches SQL as text:** `postgres.ts` has 159 `query(` sites, all with `$n` placeholders (observed sample); the only template interpolations are module constants `OWN`, `TODAY`, `HEADER`, `OWNER_JOIN` and `dateSql`, which is "TODAY or a bound parameter, never caller text" (`postgres.ts:40-53, 66-69, 751`). Transactions set `app.tenant_id/user_id/actor_label` with `set_config(..., true)` per transaction (`db/client.ts:215-225`), so a pooled connection cannot carry a tenant over.
- **Error responses leak no SQL text, stack or internal ids:** `respond.ts:31-33, 36-45, 59-68`: `ApiError` → its code and message; `CmaDbError` → the fixed `CMA_SQLSTATE` wording (`db/client.ts:39-46`), the database's own message only to `console.error` for 5xx (`:63`); anything else → `{ code: "internal", message: "Internal error" }`. `translateDbError` maps connection SQLSTATEs to 503 and the rest to 500 (`db/client.ts:64-78`). `/invite/accept` logs the SQLSTATE only (`:37`). Consistent codes: CMA01→403, CMA02→404, CMA03→409, CMA04→400, CMA05→500, CMA06→403, DB_UNAVAILABLE→503.
- **`cache-control: no-store` on personal data:** every `ok()`/`fail()`/`csvFile()` answer (`respond.ts:18, 28, 32, 139-148`), the proxy's 401/400 (`proxy.ts:94, 102`), the preview 204 (`:26`), `/invite/accept` and `/logout/end` answers, `/api/health`. CSV: `content-disposition: attachment` with a sanitised ASCII filename and `nosniff` (`respond.ts:145-146`); filenames are built from validated dates only (`forms_<from>_<to>.csv`, `hours_…`, `status-changes_…`).
- **XSS:** 0 `dangerouslySetInnerHTML|innerHTML|outerHTML|insertAdjacentHTML|document.write|javascript:|eval(|new Function(` in `web/src` and `web/signed-out` (observed). `copy.ts` has no HTML in any copy value (the 4 regex hits are TypeScript type syntax at lines 10, 1829, 1831, 3652). User text (message title/body, correction reasons, names, notes, form field labels) renders as JSX text children (`Inbox.tsx:122-123`, `MessageCenter.tsx:248`, `FormsParts.tsx:255`), React-escaped. The one `<pre>` (`ExportsConfig.tsx:132`) shows a CSV preview as text.
- **Every `href` built from data is https-validated at the source:** app links `address` has a table check `^https://\S+$` ≤ 2000 (`db/17_clock_in_app_links.sql:314`) and the upsert function repeats it (`db/26_configuration.sql:516-517`), the route too (`configuration.ts:47-49`); message `ref_url` check `^https://\S+$` ≤ 500 (`db/42_messaging.sql:105`); `cma.record_url()` refuses a filled template that is not `^https://[^\s{}]+$` ≤ 500 (`db/42_messaging.sql:251`) and the web preview mirrors it exactly, also constraining `{app_host}`, `{account}` and `{id}` (`lib/sources.ts:87-99`); the invitation link requires an https origin or localhost (`lib/invitations.ts:117-127`); the mailto is percent-encoded (`:159-165`). All external anchors carry `target="_blank" rel="noopener noreferrer"` (`ReportParts.tsx:108-110`, `Inbox.tsx:128-131`, `MessageCenter.tsx:255`, `page.tsx:275-277`, `SourceConfig.tsx:192`). Internal `Link href={{ pathname, query }}` objects use fixed pathnames.
- **CSV formula injection:** `csv.ts:58-60` prefixes `=`, `+`, `-`, `@`, tab and CR with an apostrophe; applied to every person-typed cell (`displayName`, `organisationName`, `statusName`, `formName`, category name/code: `:120-121, 149-152, 190-191`); `timeZone` (IANA, database-validated) and `market` (`^[A-Z]{2}$`) cannot start with a trigger character; numbers are `String(n)`; `quote()` handles separator, quote and line breaks (`:63-65`). `verify/csv.mjs:48-49, 72-80, 121-134` covers `=`, `+`, `-`, `@`, tab and a formula-shaped form name with a separator inside; CR-start is implemented but not in the verifier (trivial to add). Observed: `verify:csv` ALL 17 PASS. Cosmetic only: modern Excel shows the leading apostrophe literally; the formula is still defused.
- **Open redirects:** every `redirect(` and `Location` is a fixed relative path or built from validated data: `access.tsx:25` `/no-access`; `day/page.tsx:22`, `hours/page.tsx:16`, `schedule/page.tsx:25` → `firstPage()` from the navigation model (`lib/nav.ts:222-224`, fixed hrefs); `messages/send/page.tsx:24` `/messages`; `invite/[token]/page.tsx:32` `/`; `invite/accept/route.ts:42` `/` or `/invite/<token>` after `INVITE_TOKEN_RE`; `logout/end/route.ts:32` → `logoutLocation()` one of two fixed strings (`logout.ts:28-30`); the proxy's `?as=` 303 is the same URL minus the parameter (mock mode only). No `Location` or `redirect` reads `host`, `x-forwarded-host`, `Referer` or a query parameter (observed grep). `/signed-out` is never served by `cma-web` (no route, no file; the matcher gates it; `verify/signed-out.mjs:218-227` proves it from the source).
- **Static signed-out page:** hash-based CSP with `default-src 'none'`, `base-uri 'none'`, `form-action 'none'`, `referrer no-referrer`, `noindex` (`web/signed-out/index.html:18-22`); the deploy script derives the response-header CSP from the page and adds `frame-ancestors 'none'`, nosniff, `Referrer-Policy: no-referrer` (`docs/signed-out/deploy.sh:203, 237-241`), public read by object name only (`:157-185`). Already reviewed by the eighth Gemini audit (1.3 inline script, Low).
- **Health route matcher exemption:** `proxy.ts:107` exempts `api/health`, `_next/static`, `_next/image`, `icon.png`, `brand/` only; every page and route under `/api/v1`, `/invite`, `/logout` is gated.
- **Invitation token hygiene:** never in a list (`invitationFromDb` picks named fields, `lib/invitations.ts:231-255`; `cma.invitations()` returns no token or hash, `db/66:536-580`); the audit log drops `token_hash` from both images (`db/66:216-237`); `cma_app` may select every column except `token_hash` (`:208-211`); preview and accept are `SECURITY DEFINER` owned by `cma_owner` with a fixed `search_path` (`:656-659, 761-762`). Observed: `verify:invitations` PASS (27 checks).
- **Secret scan of the full history:** 164 commits, 24.5 MB of added/removed lines (observed). 0 hits for AWS keys, PEM blocks (`-----BEGIN`), Slack, HubSpot `pat-*`, Shopify `shpat_/shpss_`, GitHub `ghp_/gho_`, JWTs (`eyJ….`), `postgres://`/`postgresql://`, `host=…password=`, Google API keys (`AIza`), OAuth client secrets (`GOCSPX-`), `sk-` keys. 10 `password[:=]` hits, all `password: process.env.<NAME> || undefined` or the roles script's comment "login user without a password" (values masked when inspected, none literal). Numeric 20–21-digit values near `google|sub`: the `db/67` fixtures (synthetic by shape) and the one verifier fixture of WEB-03. No `.env` beyond `web/.env.example` (empty values), no `db/people_add_*.sql` beyond the template, no `hubspot/build/`, no `.pem/.p12/.key` or service-account JSON ever committed. Tools: `detect-secrets`/`gitleaks` were not installed (network policy allows npm and GitHub; I did not try to download binaries, as a regex pass over the full patch was sufficient and reproducible); commands in "Commands run".
- **Runtime dependency trees:** `npm audit --omit=dev` is 0/0 for `web` and `ingest` (observed); lockfiles v3, all from `registry.npmjs.org`; `npm ci` from the lockfile in the Dockerfile; non-root runtime user.

## Not checked / could not check

- Behaviour of a running server in iap mode (`verify:iap`, `verify:api`, `verify:theme`, `verify:layout`): they need a server or a database and `npm run build` is reserved for the lead; all statements about them are "expected from the code" plus the verifiers' own source.
- Whether the load balancer forwards the public host in `Host` or `x-forwarded-host` to `cma-web` (WEB-15): a prod observation only Martin can make.
- Whether the 21-digit fixture of WEB-03 is a real account id (statically undecidable; Martin knows).
- Request-log retention and exclusions on the prod project (WEB-02): Console-only.
- Whether GitHub Dependabot alerts are switched on for the repository (Console-only; `gh` was not used).
- The ingest service's own security (area 5.2).

## Commands run (outcome summary)

- `find web/src/app -name route.ts` + per-file grep of exported methods, `assertSameSiteWrite`, `forPrincipal`, `isSameOriginPost`: 103 files, 113 handlers, 52 writes guarded, 0 bypass.
- awk ordering check (guard line vs first body read per handler): 52 ok, 0 not ok.
- Dynamic-segment validation grep over 33 `[param]` routes: all validated.
- XSS sink grep (`dangerouslySetInnerHTML|innerHTML|…`): 0 hits; `copy.ts` HTML grep: 0 copy values (4 type-syntax lines).
- `href={…}` grep and source tracing to `db/17`, `db/26`, `db/42`, `lib/sources.ts`: all https-validated.
- Boundary greps (`pg`, connector, `@/lib/db/client`, `@/lib/auth/iap`, `@/lib/data/postgres`, `next/headers`, `process.env`, `x-goog-`, `"use server"`, `"use client"`): as reported in WEB-09.
- `npm audit --omit=dev --json` and `npm audit --json` in `web/` and `ingest/` (saved to `/var/tmp/5.1/audit-*.json`): web prod 0, web all 5 high (dev chain, `isSemVerMajor: true`), ingest 0/0.
- `npm outdated` in both: as listed in WEB-10. `npm ls --all | grep -c deduped`: 552 / 111. Lockfile analysis with `node -e`: v3, 0 off-registry `resolved`, 6 / 0 entries without integrity.
- `git log -p --all > /var/tmp/5.1/history.patch` (24,570,769 bytes) + regex passes over added lines (16 patterns); `git log --all --name-only` for `.env`, `people_add_*.sql`, `hubspot/build/`, key files; `git show 804786a:web/src/lib/auth/identity.ts` (masked).
- `npm run -s verify:csv` → ALL 17 PASS; `verify:invitations` → PASS (27 checks); `verify:preview` → PASS (18 checks).
- Reads: `proxy.ts`, `iap.ts`, `identity.ts`, `config.ts`, `preview.ts`, `respond.ts`, `origin.ts`, `logout.ts`, `csv.ts`, `invitations.ts`, `sources.ts` (part), `reports.ts` (part), `configuration.ts` (part), `forms.ts`, `calls.ts`, `db/client.ts`, `next.config.ts`, `actions.ts`, `health/route.ts`, `logout/*`, `invite/*`, `verify/iap-token.mjs`, `verify/csv.mjs`, `verify/invitations.mjs` (header), `verify/api.mjs` (greps), `verify/signed-out.mjs` (greps), `web/signed-out/index.html` (head), `docs/signed-out/deploy.sh` (greps), `db/66_invitations.sql` (token, preview, accept), `cloudbuild.yaml` (env lines), the ignore files, `Dockerfile`, `jose` `jwks/remote.js`, Next `action-handler.js:351-462`, README sections Authentication (1561-1624), API paragraphs, Decision log 12 Oct 2026 (line 1871), Open decisions (2008-2200, greps), `docs/night-2026-10-15/GEMINI_AUDIT.md` and `NIGHT_NOTES.md` (greps).
