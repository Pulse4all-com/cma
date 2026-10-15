# The signed-out page outside IAP

Since the night of 14 to 15 October 2026 (README, Authentication; Decision log, 15 October 2026). Live in prod since 15 October 2026, written down from Martin's report (`records/signed-out-prod-2026-10-15`): `deploy.sh prod --apply` at 06:01 UTC and again at 07:43 UTC for the page of `Pulse4all-com/cma#136`, the test plan below (a to e) passed, and `_LOGOUT_TARGET=signed-out` is set on the trigger `cma-web-main`, so Log out ends on the signed-out page.

## Why

Log out ends the workday and sends the browser to IAP's cookie-clearing address (`gcp-iap-mode=CLEAR_LOGIN_COOKIE`, Google's "Using query parameters and headers"). IAP clears its cookie and redirects to the same address without the parameter. Today that address is `/logout/done`, a page of the app behind IAP: a browser with one Google account is signed straight back in, silently, and a browser with several accounts gets IAP's chooser before it can read anything. A person on a shared desk cannot hand the Workspace to a colleague, and someone with two Google accounts cannot switch.

The signed-out page is a static file served by the load balancer from a public bucket, outside IAP. After Log out the browser lands there, signed out of the Workspace, and stays there until the person chooses:

- **Log in** (`/`): IAP signs in again; with one Google account in the browser this is silent, with several Google shows its chooser (which has its own "Use another account").
- **Add another account**: Google's own add-account form, plain `https://accounts.google.com/AddSession`, in a new tab (`target="_blank"`, `rel="noopener noreferrer"`) and without a return address: Google refuses a `continue` outside Google (Decision log, 15 October 2026). The person adds the account there, closes that tab and chooses Log in on this page, where Google's chooser now lists the new account. A caption under the link says so: "Opens Google in a new tab. Add the account there, close that tab, then Log in here and choose it." (Dutch: "Opent Google in een nieuw tabblad. Voeg daar het account toe, sluit dat tabblad en kies het hier bij Inloggen.")
- **Log out of Google** (in the shared-computer line): Google's own `https://accounts.google.com/Logout`. The Workspace itself never signs anyone out of Google; that stays the person's choice, and shared-desk security stays the desk's and Workspace's (Decision log).

Both Google addresses are Google's web pages opened by the browser, not an API.

## The flow

1. My day → Log out → confirm: `POST /logout/end` ends an open workday and answers `303 Location: /signed-out?gcp-iap-mode=CLEAR_LOGIN_COOKIE` (with `CMA_LOGOUT_TARGET=signed-out`; `legacy`, the default, keeps `/logout/done?…`).
2. The URL map's route rule priority 1 (prefix `/signed-out` and the query parameter `gcp-iap-mode=CLEAR_LOGIN_COOKIE`) sends that request to `cma-web-backend`, where IAP sees the parameter, clears its cookie and redirects to `/signed-out`.
3. Route rule priority 3 (exactly `/signed-out`, or the prefix `/signed-out/`) sends `/signed-out` to the backend bucket `cma-signed-out-backend`, which serves the object `signed-out` of `gs://p4a-cma-prod-signed-out` and the logo and Montserrat under `signed-out/`. No IAP, no cookie, no data. Route rule priority 2 (exactly `/signed-out/`) answers a 302 redirect to `/signed-out`, because the bucket has no object `signed-out/` (Gemini audit of #128, finding 2.1). Any other path that starts with `/signed-out`, such as `/signed-outx`, matches none of the three and goes to the default, `cma-web-backend` behind IAP.
4. No access yet and an invitation for another address show "Use another account" pointing at the same address as step 1, but only with the flag on.

The bucket is public for reading an object by its name only: `allUsers` holds `roles/storage.legacyObjectReader` (`storage.objects.get`), not a role with `storage.objects.list`, so nobody can list what the bucket holds (Gemini audit of #128, finding 1.2). A name the bucket does not hold therefore answers 403 instead of 404, as Cloud Storage does for a caller who cannot list. `deploy.sh` stops when `allUsers` holds any other role on the bucket.

`cma-web` never serves `/signed-out`: there is no route or file for it in the app, and `proxy.ts` gates it like every page, so a request that reaches `cma-web` without IAP's valid token is refused (401) and with one finds nothing (404). `web/verify/signed-out.mjs` proves both from the code.

## Files

| File | What |
|---|---|
| `web/signed-out/index.html` | The page: one file, inline CSS (the style guide's tokens, Montserrat self-hosted), English and Dutch from the browser's language, word for word `copy.ts`'s `signedOut` keys. Its CSP: `default-src 'none'; img-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self'; script-src 'sha256-…'; base-uri 'none'; form-action 'none'`; the one inline script is allowed by its hash only. No identity, no data, no cookie, no request of its own. `{{DISPLAY_NAME}}` and `{{LOGO_FILE}}` are written in at upload, so no tenant or company name is in the repository |
| `docs/signed-out/deploy.sh` | `bash docs/signed-out/deploy.sh <dev\|prod> --logo <path> --name <display name> [--host <host>] [--apply]`: dry run by default (its header lists every step) |
| `docs/signed-out/urlmap.py` | The URL map change, computed locally from the map as exported: the three route rules (priorities 1 to 3 reserved; a matcher's converted pathRules from 10 on), a check that nothing else differs, the url-map tests for `validate` |
| `web/src/lib/logout.ts` | `CMA_LOGOUT_TARGET` (`legacy`, `signed-out`), Log out's Location, the "Use another account" address |
| `web/verify/signed-out.mjs` | `npm run verify:signed-out`, pure, 14 checks, `--provoke` fails every one; runs `urlmap.py` with `python3` on the fixture `web/verify/signed-out-urlmap.json` |

The font comes from `web/src/fonts/Montserrat-VF.ttf` (the app's own copy; `web/public/brand/` holds only the logos).

A change to the page's script changes its hash, so the page's CSP meta tag changes with it (`verify:signed-out` fails until it does) and so does the backend bucket's CSP header: rerun `deploy.sh prod --apply`, which uploads the page at c and updates the header at d. Between the two, for a few seconds, the old header blocks the new script; the page then shows its English markup without the script.

## Verified and not verified

Verified in the session's container (`docs/night-2026-10-15/local-records/`):

- the page in Chromium at 1280 and 390 px, English and Dutch from the browser's language, Log in focused, the font loaded, no CSP violation, no cookie; its CSP's hash equal to its script (`verify:signed-out`);
- `deploy.sh` against a fake `gcloud` that answers reads with canned data and refuses every change: the dry run calls nothing that changes anything, in prod and dev; it stops before anything when the organisation policy enforces public access prevention; it stops when a path matcher already has priority 1 or 2; with `--apply` (a permissive fake) it stops when the bucket holds an object besides the page and its two files; the page is rendered with the name HTML-escaped and the developer's note removed;
- `urlmap.py` on three map shapes: no host rule for the Workspace (the map's default service serves it, as the README describes), a host rule whose matcher uses pathRules (converted, tests derived from the old matching), a matcher whose priority 1 is taken (stopped);
- `/logout/end` with the flag unset, `legacy` and `signed-out` (`verify:signed-out`).

Verified after the Gemini audit of #128 (15 October 2026), in that pull request's container (not kept as records):

- `verify:signed-out`: `deploy.sh` grants `allUsers` `legacyObjectReader` and never names `objectViewer`; `urlmap.py` on the fixture plans exactly the three route rules, keeps the default service and the ingest host rule, writes the tests for `/signed-out/`, `/signed-outx` and `/signed-out/logo-blue.png`, changes nothing on a rerun, stops on a matcher with priority 3 taken and converts pathRules from priority 10;
- `deploy.sh` against the night's fake `gcloud`, its IAM policy answer varied: no bucket proposes the `legacyObjectReader` binding; an existing `legacyObjectReader` binding is kept; `allUsers` holding `objectViewer`, or `legacyBucketReader` beside `legacyObjectReader`, stops at b with the role named; an unreadable policy stops at b; every dry run made no changing call;
- `urlmap.py` on the night's three maps and on a map read back with the API's defaults written out (`stripQuery: false`, partial links): the rerun changes nothing; a priority 2 that redirects with 301 stops.

The first `deploy.sh prod --apply` (15 October 2026) stopped at b, at the bucket's create, and created nothing: `gcloud storage buckets create` takes `--public-access-prevention` (`--pap`) as a boolean flag (on means enforced) and refused `--public-access-prevention=inherited` with "ignored explicit argument 'inherited'". The create now passes `--no-public-access-prevention`, which leaves the bucket's public access prevention inherited. Verified in that fix's container:

- gcloud 570.0.0 refuses the old create with the same message (exit 2) and parses the new one. Every kind of `gcloud` command `deploy.sh` runs or prints (nineteen, the remove command of the STOP at b included) was tried with its requests sent to a closed proxy port, so none left the container: each got as far as its API request, and only the old create stopped at its arguments;
- the night's two fake `gcloud`s now refuse a value on `--public-access-prevention` or `--pap` as gcloud does: with `--apply` against the permissive fake, the old script stops at the create with gcloud's message and changes nothing, and the fixed script runs to `== done`;
- `verify:signed-out` (14 checks): `deploy.sh` passes no value to either flag, and its one bucket create passes `--no-public-access-prevention`.

Seen in prod on 15 October 2026 (written down from Martin's report):

- `https://accounts.google.com/AddSession?continue=https://workspace.pulse4all.app/` answers Google's "400. That's an error … malformed"; plain `https://accounts.google.com/AddSession` and `https://accounts.google.com/AddSession?continue=https://myaccount.google.com/` both show Google's add-account form. Google refuses a `continue` outside Google, so the page's link is plain `AddSession` in a new tab (Decision log, 15 October 2026);
- Log in (`/`) with several Google accounts in the browser shows Google's account chooser, which has its own "Use another account"; with one account it signs in silently;
- after the import, the URL map took a few minutes to take effect.

Verified for Add another account (15 October 2026), in that change's container: `verify:signed-out` (14 checks), whose links check wants plain `AddSession` with `target="_blank"` and `rel="noopener noreferrer"`, AddSession named once, no `continue` anywhere in the page or its script and no address set by the script, and whose `--provoke` puts the old continue line back and fails; the page in Chromium at 1280 px in English and 390 px in Dutch: the link and its caption (12 px, Footnote Grey) in the browser's language, the link's address unchanged by the script, Log in focused, no CSP violation.

Verified in prod on 15 October 2026 (written down from Martin's report, `records/signed-out-prod-2026-10-15`); until then these were not verified:

- IAP, given `/signed-out?gcp-iap-mode=CLEAR_LOGIN_COOKIE` on `cma-web-backend`, clears its cookie and redirects to `/signed-out`, and the load balancer's query-parameter match decides the backend before IAP sees the request (test plan a, and Log out after the flag; the address may end on `?__gcp_iap_oauth_prompt=1`);
- the redirect's url-map test expecting `http://<host>/signed-out` (a test names no scheme, and only `httpsRedirect`, not allowed on an HTTPS proxy's map, makes a redirect's expected URL `https`): `validate` passed with it, at both applies;
- `gcloud compute url-maps validate` and `import` on the real map and `backend-buckets create --custom-response-header` (and `update`); the real map's shape: the Workspace has no host rule (the map's default service serves it), so the plan added the path matcher `cma-web`, and it wrote 9 tests, the number the map the README describes gives (one other host rule, for `ingest.pulse4all.app`, without path rules);
- the whole add-account flow with the new link (test plan b, after `Pulse4all-com/cma#136`): Add another account opens Google's add-account form in a new tab, then Log in shows Google's chooser; a pulse4all.com account without a person ends on No access yet, an account outside the domain on IAP's own "You don't have access".

## Prod test plan (Martin, after `deploy.sh prod --apply`)

Run in this order; stop at the first that does not hold and roll back (below). Start a few minutes after the import: in prod on 15 October 2026 the URL map took a few minutes to take effect, and until then the old routes answer.

| Step | Do | Expected |
|---|---|---|
| a | **Browser**, signed in to the Workspace: open `https://workspace.pulse4all.app/signed-out?gcp-iap-mode=CLEAR_LOGIN_COOKIE` | The address bar ends on `/signed-out` without `gcp-iap-mode`, possibly with `?__gcp_iap_oauth_prompt=1`, which IAP adds when it clears its cookie (seen in prod, 15 October 2026); the page "You're logged out" (or Dutch) with the logo; no sign-in happened. Then open `https://workspace.pulse4all.app/`: IAP asks for a sign-in or signs in again (one account: silently) |
| b | **Browser** with one Google account: on the page, Log in; then again a, and Add another account; add an account in the new tab, close that tab, then Log in on the page | Log in signs in silently and lands on Welcome. Add another account opens Google's add-account form in a new tab; after adding the account and closing that tab, Log in shows Google's chooser; picking a pulse4all.com account without a person ends on No access yet; an account outside the domain gets IAP's own "You don't have access" |
| c | **Browser** with two Google accounts signed in: a, then Log in | Google's account chooser |
| d | **Browser**, in an Incognito window, because log out of Google signs out every account in the browser: a, then "log out of Google" | Google's sign-out page; afterwards `https://mail.google.com` asks for a sign-in |
| e | **Terminal**: the other paths | `curl -s -o /dev/null -w "%{http_code}" https://ingest.pulse4all.app/health` prints `200` (cma-ingest), as before (`/health` answers GET only, so `curl -I` gives 404); `curl -sI https://workspace.pulse4all.app/` answers 302 to IAP's sign-in, as before; `curl -sI https://workspace.pulse4all.app/signed-out` answers 200 with `content-type: text/html; charset=utf-8`, `cache-control: public, max-age=300` and the `content-security-policy` header; `curl -sI https://workspace.pulse4all.app/signed-out/logo-blue.png` 200; `curl -sI https://workspace.pulse4all.app/signed-out/` answers 302 with `location: https://workspace.pulse4all.app/signed-out` (`/signed-out/` redirects to `/signed-out`); `curl -sI https://workspace.pulse4all.app/signed-outx` answers 302 to IAP's sign-in, like `/` (`/signed-outx` asks for sign-in through IAP); `curl -s https://storage.googleapis.com/storage/v1/b/p4a-cma-prod-signed-out/o` answers an error (401 or 403) about `storage.objects.list`, not a list of objects |

Only after a to e: set `_LOGOUT_TARGET=signed-out` on the trigger and rebuild (README, Build and deploy: export, edit, import, run). Then Log out once from My day: the browser lands on the signed-out page. Done on 15 October 2026: Log out ends on `/signed-out` (with `?__gcp_iap_oauth_prompt=1`), and No access yet offers Use another account.

## Rollback

- The flag: `_LOGOUT_TARGET=legacy` (or remove it) on the trigger and rebuild; Log out lands on `/logout/done` again.
- The route: `gcloud compute url-maps import cma-web-urlmap --project=p4a-cma-prod --global --source=<the export deploy.sh printed> --quiet`.
- The bucket and the backend bucket may stay (nothing routes to them after the import above), or be deleted by hand: `gcloud compute backend-buckets delete cma-signed-out-backend --project=p4a-cma-prod`, then `gcloud storage rm -r gs://p4a-cma-prod-signed-out`.
