/**
 * The Content-Security-Policy, step 2 (brief N07, WP8; decision D11, 24 November 2026; the IT audit of 17 October 2026,
 * docs/audits/2026-10-17-full-audit): every page answer carries a policy with a fresh nonce for script-src, set by
 * proxy.ts on the request (Next reads the nonce from it and puts it on every script it renders) and on the answer.
 *
 *   script-src 'self' 'nonce-<per request>' 'strict-dynamic' 'sha256-<FIT_SCRIPT>'
 *     A script runs only when it carries this request's nonce (Next's own and the page's chunks), or was loaded by one
 *     that does ('strict-dynamic'; 'self' is the fallback a browser without CSP 3 reads instead). The desktop fit's inline
 *     script in <head> (src/lib/desktop-fit.ts) is static: allowed by its hash, so the root layout needs no request data.
 *     In development, 'unsafe-eval' too (React rebuilds server error stacks with eval; never in production).
 *   frame-ancestors 'none'; base-uri 'self'; form-action 'self'; object-src 'none'
 *     step 1, unchanged and repeated here: proxy.ts's header replaces next.config.ts's on the answers it passes on, so the
 *     answer carries one policy; next.config.ts's step 1 stays on the answers proxy.ts gives itself or never sees.
 * style-src is not set: inline style attributes (42 in web/src) and the fit's style element stay allowed (night N07: not
 * tightened tonight).
 *
 * Every page is rendered per request (the build lists only app.webmanifest and icon.png as static), so every page gets
 * its nonce; a page made static later would render without nonces and its scripts would be refused: verify:csp
 * checks the build's static routes.
 */
import { createHash, getRandomValues } from "node:crypto";
import { FIT_SCRIPT } from "./desktop-fit.ts";

/** The base64 sha256 of a script's exact text, as script-src names it */
export function scriptHash(text: string): string {
  return `'sha256-${createHash("sha256").update(text, "utf8").digest("base64")}'`;
}

export const FIT_SCRIPT_HASH = scriptHash(FIT_SCRIPT);

/** 16 random bytes in base64: unguessable and new for every request */
export function newNonce(): string {
  return Buffer.from(getRandomValues(new Uint8Array(16))).toString("base64");
}

/** Step 1's directives, the same as next.config.ts sends */
export const BASE_DIRECTIVES = "frame-ancestors 'none'; base-uri 'self'; form-action 'self'; object-src 'none'";

export function contentSecurityPolicy(nonce: string, opts: { dev?: boolean } = {}): string {
  const script = ["'self'", `'nonce-${nonce}'`, "'strict-dynamic'", FIT_SCRIPT_HASH, ...(opts.dev ? ["'unsafe-eval'"] : [])];
  return `script-src ${script.join(" ")}; ${BASE_DIRECTIVES}`;
}
