# The signed-out page outside IAP

Since the night of 14 to 15 October 2026 (README, Authentication; Decision log, 15 October 2026). Nothing of this is applied yet: the page, the script and the flag are in the repository, the bucket and the route are not, and Log out keeps landing on `/logout/done` until Martin switches the flag after the test plan below.

## Why

Log out ends the workday and sends the browser to IAP's cookie-clearing address (`gcp-iap-mode=CLEAR_LOGIN_COOKIE`, Google's "Using query parameters and headers"). IAP clears its cookie and redirects to the same address without the parameter. Today that address is `/logout/done`, a page of the app behind IAP: a browser with one Google account is signed straight back in, silently, and a browser with several accounts gets IAP's chooser before it can read anything. A person on a shared desk cannot hand the Workspace to a colleague, and someone with two Google accounts cannot switch.

The signed-out page is a static file served by the load balancer from a public bucket, outside IAP. After Log out the browser lands there, signed out of the Workspace, and stays there until the person chooses:

- **Log in** (`/`): IAP signs in again; with one Google account in the browser this is silent, with several Google shows its chooser.
- **Use another account**: Google's own add-account page, `https://accounts.google.com/AddSession?continue=https://<host>/`, which adds an account and returns to the Workspace, where IAP then shows the chooser.
- **Log out of Google** (in the shared-computer line): Google's own `https://accounts.google.com/Logout`. The Workspace itself never signs anyone out of Google; that stays the person's choice, and shared-desk security stays the desk's and Workspace's (Decision log).

Both Google addresses are Google's web pages opened by the browser, not an API.

## The flow

1. My day → Log out → confirm: `POST /logout/end` ends an open workday and answers `303 Location: /signed-out?gcp-iap-mode=CLEAR_LOGIN_COOKIE` (with `CMA_LOGOUT_TARGET=signed-out`; `legacy`, the default, keeps `/logout/done?…`).
2. The URL map's route rule priority 1 (prefix `/signed-out` and the query parameter `gcp-iap-mode=CLEAR_LOGIN_COOKIE`) sends that request to `cma-web-backend`, where IAP sees the parameter, clears its cookie and redirects to `/signed-out`.
3. Route rule priority 2 (prefix `/signed-out`) sends `/signed-out` to the backend bucket `cma-signed-out-backend`, which serves the object `signed-out` of `gs://p4a-cma-prod-signed-out` and the logo and Montserrat under `signed-out/`. No IAP, no cookie, no data.
4. No access yet and an invitation for another address show "Use another account" pointing at the same address as step 1, but only with the flag on.

`cma-web` never serves `/signed-out`: there is no route or file for it in the app, and `proxy.ts` gates it like every page, so a request that reaches `cma-web` without IAP's valid token is refused (401) and with one finds nothing (404). `web/verify/signed-out.mjs` proves both from the code.

## Files

| File | What |
|---|---|
| `web/signed-out/index.html` | The page: one file, inline CSS (the style guide's tokens, Montserrat self-hosted), English and Dutch from the browser's language, word for word `copy.ts`'s `signedOut` keys. Its CSP: `default-src 'none'; img-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self'; script-src 'sha256-…'; base-uri 'none'; form-action 'none'`; the one inline script is allowed by its hash only. No identity, no data, no cookie, no request of its own. `{{DISPLAY_NAME}}` and `{{LOGO_FILE}}` are written in at upload, so no tenant or company name is in the repository |
| `docs/signed-out/deploy.sh` | `bash docs/signed-out/deploy.sh <dev\|prod> --logo <path> --name <display name> [--host <host>] [--apply]`: dry run by default (its header lists every step) |
| `docs/signed-out/urlmap.py` | The URL map change, computed locally from the map as exported: the two route rules, a check that nothing else differs, the url-map tests for `validate` |
| `web/src/lib/logout.ts` | `CMA_LOGOUT_TARGET` (`legacy`, `signed-out`), Log out's Location, the "Use another account" address |
| `web/verify/signed-out.mjs` | `npm run verify:signed-out`, pure, 11 checks, `--provoke` fails every one |

The font comes from `web/src/fonts/Montserrat-VF.ttf` (the app's own copy; `web/public/brand/` holds only the logos).

## Verified and not verified

Verified in the session's container (`docs/night-2026-10-15/local-records/`):

- the page in Chromium at 1280 and 390 px, English and Dutch from the browser's language, Log in focused, the font loaded, no CSP violation, no cookie; its CSP's hash equal to its script (`verify:signed-out`);
- `deploy.sh` against a fake `gcloud` that answers reads with canned data and refuses every change: the dry run calls nothing that changes anything, in prod and dev; it stops before anything when the organisation policy enforces public access prevention; it stops when a path matcher already has priority 1 or 2; with `--apply` (a permissive fake) it stops when the bucket holds an object besides the page and its two files; the page is rendered with the name HTML-escaped and the developer's note removed;
- `urlmap.py` on three map shapes: no host rule for the Workspace (the map's default service serves it, as the README describes), a host rule whose matcher uses pathRules (converted, tests derived from the old matching), a matcher whose priority 1 is taken (stopped);
- `/logout/end` with the flag unset, `legacy` and `signed-out` (`verify:signed-out`).

Not verified (needs prod, and Martin):

- that IAP, given `/signed-out?gcp-iap-mode=CLEAR_LOGIN_COOKIE` on `cma-web-backend`, clears its cookie and redirects to `/signed-out` (Google's documentation says it redirects to the address without the parameter; `/logout/done` behaves that way today, which is the evidence);
- that the load balancer evaluates the query-parameter match before IAP sees the request (the route rule decides the backend; IAP is the backend's);
- `gcloud compute url-maps validate` and `import` on the real map, `backend-buckets create --custom-response-header` (the flags are as documented, not run here), and the real map's shape (the README says the Workspace is served by the map's default service, with one host rule for `ingest.pulse4all.app`);
- Google's chooser and add-account flow after Log in and Use another account (test plan b and c).

## Prod test plan (Martin, after `deploy.sh prod --apply`)

Run in this order; stop at the first that does not hold and roll back (below).

| Step | Do | Expected |
|---|---|---|
| a | **Browser**, signed in to the Workspace: open `https://workspace.pulse4all.app/signed-out?gcp-iap-mode=CLEAR_LOGIN_COOKIE` | The address bar ends on `/signed-out` without the parameter; the page "You're logged out" (or Dutch) with the logo; no sign-in happened. Then open `https://workspace.pulse4all.app/`: IAP asks for a sign-in or signs in again (one account: silently) |
| b | **Browser** with one Google account: on the page, Log in; then again a, and Use another account | Log in signs in silently and lands on Welcome. Use another account opens Google's add-account page; after adding an account the browser returns to the Workspace and IAP shows the account chooser |
| c | **Browser** with two Google accounts signed in: a, then Log in | Google's account chooser |
| d | **Browser**: a, then "log out of Google" | Google's sign-out page; afterwards `https://mail.google.com` asks for a sign-in |
| e | **Terminal**: the other paths | `curl -sI https://ingest.pulse4all.app/health` answers as before (200 from cma-ingest); `curl -sI https://workspace.pulse4all.app/` answers 302 to IAP's sign-in, as before; `curl -sI https://workspace.pulse4all.app/signed-out` answers 200 with `content-type: text/html; charset=utf-8`, `cache-control: public, max-age=300` and the `content-security-policy` header; `curl -sI https://workspace.pulse4all.app/signed-out/logo-blue.png` 200 |

Only after a to e: set `_LOGOUT_TARGET=signed-out` on the trigger and rebuild (README, Build and deploy: export, edit, import, run). Then Log out once from My day: the browser lands on the signed-out page.

## Rollback

- The flag: `_LOGOUT_TARGET=legacy` (or remove it) on the trigger and rebuild; Log out lands on `/logout/done` again.
- The route: `gcloud compute url-maps import cma-web-urlmap --project=p4a-cma-prod --global --source=<the export deploy.sh printed> --quiet`.
- The bucket and the backend bucket may stay (nothing routes to them after the import above), or be deleted by hand: `gcloud compute backend-buckets delete cma-signed-out-backend --project=p4a-cma-prod`, then `gcloud storage rm -r gs://p4a-cma-prod-signed-out`.
