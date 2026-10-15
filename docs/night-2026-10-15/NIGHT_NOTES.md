# Night notes, 14 to 15 October 2026: signed-out page outside IAP, invitations by email, the connection budget

Written by Claude Code while Martin was away. Everything was built and verified in the session's own container: PostgreSQL 18.4 with `db/00` to `65` in README order and then `66` and `67`, Node 22, the standalone build in mock and in api mode against that database. Nothing touched dev, prod, GCP, Secret Manager, Google Workspace or a vendor, and no infrastructure was applied. There is one branch, `night-2026-10-15` from `main` (as the brief names it), and one pull request. `records/` is untouched: the local outputs are in `local-records/`, and the real runs are Martin's.

**Migration numbers:** README Planned migrations and `db/` both ended at 0008k and `65`, so addition 0008l with `66` and `67` was free and is used.

## What was built

1. **The signed-out page (Part A).**
   - `web/signed-out/index.html` is one static file. It has inline CSS with the style guide's tokens, self-hosted Montserrat and the logo, and English or Dutch from the browser's languages, word for word the new `signedOut` keys in `copy.ts`.
   - Its CSP meta allows the one inline script by its hash only. It has no identity, no data, no cookie, no fetch or XHR, and nothing external.
   - "Log in" (`/`) has focus on load. "Use another account" goes to Google's `AddSession?continue=https://<location.host>/`. "log out of Google" goes to Google's `Logout`.
   - The display name and logo file are written in at upload, so no company name is in the repository.
2. **Log out by flag.**
   - `CMA_LOGOUT_TARGET` (`legacy`, the default, or `signed-out`) is read in `src/lib/config.ts` through `src/lib/logout.ts`.
   - `/logout/end` answers `/logout/done?gcp-iap-mode=CLEAR_LOGIN_COOKIE` (unset or `legacy`, unchanged) or `/signed-out?gcp-iap-mode=CLEAR_LOGIN_COOKIE`.
   - `cloudbuild.yaml` has the substitution `_LOGOUT_TARGET` (default `legacy`), checked in `check-config`, printed on the `config:` line and passed as `CMA_LOGOUT_TARGET` in the one `--set-env-vars`.
   - No access yet shows "Use another account" only with the flag on.
   - `proxy.ts` has no exception for `/signed-out`: cma-web never serves it, and a request that reaches cma-web gets the normal IAP check (comment, and proven by `verify:signed-out`).
3. **`docs/signed-out/`.**
   - `deploy.sh <dev|prod> --logo --name [--host] [--apply]` is a dry run by default. In order, it:
     1. checks the organisation's public access prevention policy and stops on enforcement;
     2. for prod, plans the URL map change from a read-only export before creating anything;
     3. creates the bucket with uniform access, `allUsers` objectViewer on that bucket only, the page and its two files under `Cache-Control: public, max-age=300`, and checks that the bucket holds exactly those three objects;
     4. creates the backend bucket without CDN, with the page's CSP plus `frame-ancestors 'none'`, `nosniff` and `no-referrer` as response headers;
     5. runs `url-maps validate` with generated tests, then the import;
     6. prints the restore command.
   - Dev gets the bucket only.
   - `urlmap.py` computes the two route rules (priority 1 with the query parameter to `cma-web-backend`, priority 2 to the bucket). It converts pathRules, stops on any other difference and derives the validate tests from the old matching.
   - `README.md` holds the flow, what is verified and what is not, the prod test plan a to e and the rollback.
4. **Addition 0008l Invitations (Part B1).**
   - `db/66_invitations.sql`:
     - `cma.invitation` through `setup_tenant_table` (RLS, audit, grants), never deleted.
     - The token's SHA-256 only, unique, hidden from `cma_app` by column grants and stripped from the audit row by a redefined `cma.audit_row()`.
     - The settings `auth.invitation_valid_days` (7, 1 to 30) and `auth.invitation_email_domains` (empty), validated by a redefined `cma.check_tenant_setting()`.
     - `cma.create_invitation`, `renew_invitation`, `revoke_invitation` and `invitations()`, the application's, under RLS and the role ceiling.
     - `cma.invitation_preview` (stable) and `cma.accept_invitation`, `SECURITY DEFINER`, owned by `cma_owner`, `search_path = pg_catalog, cma, pg_temp`. Acceptance creates the person through `cma.add_person`, `set_person_teams` and `set_person_skills`, acting as the inviter.
     - The view `cma_read.invitation` without the hash.
     - It refuses to run before 0008k, runs in one transaction and is rerun-safe.
   - `db/67_verify_invitations.sql` has 23 checks, the provoke switch, a verdict row, and is dev only (like `63` and `65`).
5. **The API (B2).**
   - `GET`/`POST /api/v1/team/invitations`, `POST …/{id}/renew` and `POST …/{id}/revoke`. Each checks `users.manage_agents` or `users.manage_all` before the database checks again.
   - A token appears only in the create and renew answers.
   - Both data layers are covered: Postgres, and the mock with a fixture per tenant (open, expired, accepted, revoked, a managing role's invitation, and one in the second tenant).
6. **People (B3).**
   - **Invite** (key V) sits next to Add a person. The dialog has email, name, language, role (the tenant's assignable roles within the inviter's ceiling, never the system role), employer, teams and skills.
   - Once created, it shows the link with **Copy link** and **Open in mail**. The mailto's subject and body come from `copy.ts` in the invitee's language: who invites, the Workspace, the role, the link, the expiry, and "sign in with this address".
   - An **Invitations** section lists state, expiry and who accepted or revoked, with New link and Revoke (second tap), and header hints.
7. **`/invite/<token>` (B4).**
   - It sits behind IAP, for a signed-in account that need not be a person, in the invitation's language, `no-referrer` and not indexed.
   - A GET never changes anything. It shows Join (Accept focused), another account (the invited and the current address, and "Use another account" or how to switch), expired, invalid, or another business line. A person of that business line goes to Welcome.
   - Accept is a same-origin form post to `/invite/accept` with the token in the body. It answers 303 to `/` or back to the link.
8. **Settings (B5)** are a section **Invitations** on Configuration → Exports (valid days, and domains as a comma list), saved through the settings route the database validates.
9. **Copy** has 95 new keys in English and Dutch (1371 in all).
10. **Part C:** README Infrastructure has a Database connection budget computed from the code:
    - prod: web 20, ingest 25, jobs 15, scheduler 2, NocoDB 20, BigQuery 5, team 10, 97 in all;
    - the sweep and form poll's worst-case overlap;
    - dev at 72 against `db-g1-small`;
    - `max_connections` left for Martin to fill in;
    - the rule that every change of instances, pools or job schedules updates the paragraph.

    No instance or pool was changed.
11. **README.** Every section the brief lists has been updated:
    - Data model: the 0008l section, rows `66` and `67`, Planned migrations, the Code paragraph `00` to `67`.
    - API: the routes, People, the invitation page, Log out and the signed-out page, Verification.
    - Authentication, Users and roles, Features (Team), Infrastructure, Build and deploy.
    - Seven Decision log rows of 15 October: the brief's three and four derived ones.
    - Open decisions, and the Last updated line.
12. **Verifiers.**
    - `verify:signed-out` (11 checks) and `verify:invitations` (27 checks) are pure.
    - `verify/api.mjs --invitations` has 15 checks and runs on request only, not in the full run.
    - Layout covers People with Invitations and the dialog for the admin and the manager, and `/invite` in five states.
    - Theme covers two `/invite` pages.
    - `CLAUDE.md` lists the two new pure verifiers with the others a session runs.

## Verification (outputs in `local-records/`)

| Check | Normal | Provoked |
|---|---|---|
| `npm ci`, `npm run typecheck`, `npm run lint`, `npm run build` (web) | clean, exit 0 | |
| `verify:copy` | PASS, 1371 keys (1276 + the 95 new), en and nl | FAIL, 5 problems |
| `verify:corrections` 31, `verify:csv` 16, `verify:dashboard` 17, `verify:live` 39, `verify:team` 26, `verify:roster` 31, `verify:configuration` 92, `verify:messages` 24, `verify:import` 23 (and `verify:reports` 75); none of them changed | ALL PASS | ALL PROVOKED CHECKS FAILED |
| `verify:signed-out` (new) | PASS, 11 checks | ALL 11 PROVOKED CHECKS FAILED |
| `verify:invitations` (new) | PASS, 27 checks | ALL 27 PROVOKED CHECKS FAILED |
| theme (mock, build) | PASS, 42 pages (the two `/invite` pages added) | FAIL, 6 problems |
| layout (mock, build) | PASS, the earlier states plus People with Invitations and the Invite dialog for the admin and the manager, and `/invite` open, another account, expired, invalid, another business line | FAIL, 29 problems (the earlier ones plus the Invitations table, the open link and its focus) |
| hints (mock, build) | PASS, 241 headers and 59 tiles on 20 pages | FAIL, 1 problem |
| `verify/api.mjs --invitations` (local database at `67` / mock data) | `ALL 15 PASS` / `ALL 15 PASS` | all failed / all failed |
| `verify/api.mjs --sources` 31, `--reports` 17, `--inbound` 16, `--calls` 19 (local database at `67` with `reports-fixture.sql`) | ALL PASS | all failed |
| `66` first run and rerun | clean (`INSERT 0 1`, then `INSERT 0 0`) | |
| `67` | 23 PASS, verdict PASS | `PROVOKED, NOT A PASS`, 0 PASS, 23 FAIL |
| `67` on a database without the dev seed | `REFUSED: not dev`, every block stopped | |
| nineteen mutations of `66`, each on a copy of the database | all caught by `67`, each named by its row (`mutations.txt`) | |
| `63` and `65` after `66` | 20 and 12 PASS rows | |
| `04` to `65` after `66` against the same verifies at `65` | 26 identical; `04`, `07`, `10`, `14` differ only by the new table, migration row and two settings in their listings | |
| `deploy.sh` against a fake `gcloud` | dry runs in dev and prod (three map shapes) make no changing call; stops on public access prevention and on a taken priority; with `--apply` (a permissive fake) stops on a foreign object in the bucket | |
| the page in Chromium (1280 and 390 px, en and nl) | Log in focused, the font loaded, no CSP violation, no cookie | |
| Log out with `_LOGOUT_TARGET` unset | `/logout/done?gcp-iap-mode=CLEAR_LOGIN_COOKIE` (`verify:signed-out`) | |

These checks were not run here, because they need a server, IAP or a real database:
- the full `verify/api.mjs`. Its only change is the health-check line (one variable for "a single group", same meaning) and the opt-in group. At 23:00 in Amsterdam it would have stopped on the workday window, as on 13 October.
- `verify:iap` and `verify:scheduler`.
- theme and layout against dev.
- every db/ script in dev or prod.
- a Docker build (the Dockerfile is unchanged).
- `gcloud` for real.
- the ingest verifiers (nothing under `ingest/` changed).

**Found and fixed on the way:**
- the mock answered 404 instead of the database's 403 for an invitation with the system role. It now refuses it as the database does. The final records come from the build after that fix.
- an old server process with stale mock state once failed layout. Every browser run now starts on a fresh server.

## Security review (Part D)

| Item | Result |
|---|---|
| Authentication on every new route | **PASS.** `proxy.ts`'s matcher gates `/api/v1/team/invitations…`, `/invite/…` and `/invite/accept` like every page. It strips the identity headers a client sends and sets them only from IAP's verified token. The routes read the identity through `forPrincipal` and `getIdentity`. No matcher exception was added, for `/signed-out` either (`verify:signed-out`). |
| Authorization | **PASS.** Each route checks `users.manage_agents` or `users.manage_all` first, and the database again (`CMA06` → 403) on create, renew, revoke and list. The ceiling is as in Add a person: a managing role needs `users.manage_all`. The system role is refused at creation and at acceptance, and `is_assignable` is checked explicitly because the owner bypasses the `protect_system` trigger (`67` B3, B4). Acceptance checks the inviter's rights again (B18). Accept itself needs no permission: the invitee is not a person yet, and the token plus the address match are the authorization. |
| Tenant isolation | **PASS.** RLS applies through `setup_tenant_table`. The application's functions run as the invoker in the caller's tenant. The two definer functions find the row by hash and act only on that row's tenant, with explicit tenant filters because the owner bypasses RLS. They set and restore the tenant context (B15). The other-tenant lookup is the owner's only (A3). |
| Token: entropy, hashing, single use, expiry, lookup | **PASS.** 32 bytes (43 url-safe characters) from 366 random bits of `gen_random_uuid()`, stored as SHA-256 hex under a unique index and looked up by hash. Only create and renew return it (B1, B16; the api check "never a token or hash"). `cma_app` cannot select the hash, and the audit never holds it. Single use is enforced by a row lock and `accepted_at` (B13). Expiry is checked at preview and at acceptance (B11). Renewal replaces the hash (B8) and revocation ends the link (B9). A token of another shape answers invalid without a database call. |
| No token, email or IP in logs or error messages | **PASS** for the application's logs. `/invite/accept` logs the SQLSTATE only. The API logs only 5xx and the functions' messages carry no address or token. The table's checks equal the functions' validation, so a check violation (whose detail would hold the row) cannot arise. The page and its links send no Referer (`no-referrer`). **OPEN:** the token is in the load balancer's and Cloud Run's request logs as part of `/invite/<token>`. That is accepted for now: a token works once, expires within days, only for the invited address's Google account, and only behind IAP. The better option, the token in the address's fragment (`#`, never sent to a server), needs IAP to keep a fragment through its sign-in, which is unverified (question 4). |
| CSRF on every POST | **PASS, one FIXED.** The API writes need `x-cma-request: 1` and refuse a cross-site `Sec-Fetch-Site`. `/invite/accept` and `/logout/end` accept a same-origin form post only (`src/lib/origin.ts`; the api check "Accept refuses a cross-site post"). **FIXED:** `/logout/end`'s own check threw on a malformed `Origin` (500); it now answers 403, and refuses any `Sec-Fetch-Site` other than `same-origin` or `none` even when `Origin` matches. |
| No open redirect | **PASS.** `/logout/end` answers one of two fixed relative addresses. `/invite/accept` answers `/` or `/invite/<token>` only after the token matched `^[A-Za-z0-9_-]{43}$`. The static page's `continue` is `https://` + `location.host` + `/`, URI-encoded. No request value becomes a Location. |
| GET never changes state | **PASS.** `invitation_preview` is `stable` (it cannot write) and the page only reads it (B17; the api check "changes nothing" reads the state before and after a visit by the right and a wrong account). Accept is POST only. |
| Account enumeration | **PASS.** Creation tells an inviter only whether the address is a person or has a pending invitation in their own business line, no more than Add a person already answers, and nothing about other business lines. The page's distinct states need the 256-bit token. "Another account" shows the invited address to someone who holds the link, as the brief asks. "Another business line" tells the visitor only about their own account. No route answers by address alone. |
| The static page's CSP; the public bucket's content | **PASS.** The CSP meta has `default-src 'none'`, the one script by hash, `form-action 'none'` and `base-uri 'none'`. The backend bucket repeats it as a header with `frame-ancestors 'none'`. `verify:signed-out` checks the hash against the script and that the page uses no cookie, fetch, XHR or anything external. `deploy.sh` uploads exactly the page, the logo and the font, takes PNG, WebP or JPEG only (an SVG on the Workspace's host could carry a script), and stops when the bucket holds anything else. **OPEN:** if the organisation policy enforces public access prevention, `deploy.sh` stops, and an exception is Martin's decision (question 7). |
| Dependencies added | **PASS.** None: `package.json` gains two scripts, and `package-lock.json` is unchanged. No `pgcrypto`. |
| Found in the review | **FIXED:** accepting with a sign-in that already works in another business line would have given it two tenants. That means "No access yet" in both until a tenant picker exists, so the person would have been locked out. The preview and acceptance now answer `other_tenant` and write nothing (DB, both data layers, copy, `67` B14, layout). **FIXED:** the definer functions' `search_path` ends with `pg_temp`, explicitly last. **FIXED:** acceptance acts as the link's last sender (`renewed_by`), so a renewal by someone else is checked against the renewer's rights (B8, mutation 17). |

## Decisions taken (README was silent: the conservative option each time; those that set behaviour are Decision log rows "to confirm with Martin", and each is a question below)

1. **Role ceiling exactly as Add a person.** A `users.manage_agents` holder may invite agent, supervisor and analytics, not only agent; a managing role needs `users.manage_all`. The brief says "exactly as add a person", and its verify line says "above agent". The database's rule is the former.
2. **One pending invitation per address and business line.** An expired one is renewed or revoked, not duplicated. An inactive person with the address is refused too ("reactivate them on People"), not only an active one.
3. **Acceptance acts as the inviter.** That is the last person who sent the link (the renewer, if renewed). Their permission and ceiling, the role's assignability and the domain are checked again at acceptance, and the audit names them (label `invitation`). Any refusal then is "invalid" and writes nothing. A person with the address added meanwhile never gets the sign-in id by address.
4. **The sign-in system is a parameter, and there is no name parameter.** `accept_invitation(token, system, id, email)` takes `google` behind IAP and `mock` in dev. IAP's token carries no name, so the person keeps the name the inviter typed.
5. **Teams and skills are optional for every role**, and skills need `skills.manage`, as on Edit person. Add a person sets neither, so there was no per-role rule to copy.
6. **The domain setting matches the exact domain**, not subdomains. It is checked at creation and at acceptance.
7. **The token generator.** It is SHA-256 over three `gen_random_uuid()` values instead of `gen_random_bytes()`. `pgcrypto` would need `CREATE EXTENSION`, which an IAM login acting as `cma_owner` cannot run on Cloud SQL.
8. **The settings sit on Configuration → Exports** (section Invitations). No Configuration → Settings page exists; the connected-call threshold set the precedent on 14 October.
9. **Accept posts to `/invite/accept`** with the token in the body. One route handler, the same-origin rule of `/logout/end`, and no server action.
10. **Another business line (`other_tenant`)** is a fifth page state, added after the review finding above.
11. **The bucket's layout.**
    - The page is the object `signed-out` (so `/signed-out` maps to it), with the logo and font under `signed-out/`. PNG, WebP or JPEG only.
    - The font comes from `web/src/fonts/Montserrat-VF.ttf`: `web/public/brand/` holds only the logos, though the brief named it.
    - The script stops on any other object.
12. **The visual reference.** "Finn's login page" is nowhere in the repository. The page follows the style guide and the existing No access page (Sand background, a white card, a Deep Blue primary button). Finn or Mark may want to compare.
13. **The branch is `night-2026-10-15`**, as the brief names it. The session's default branch name was not used.

## Questions for Martin (also in the morning runbook's Afterwards)

1. **Role ceiling.** Should a call center manager be able to invite supervisors and analytics, as Add a person allows, or agents only, as the brief's verify line says? If agents only, Add a person should change with it (one rule for both).
2. **Inactive people.** Is it right that an inactive person is reactivated on People instead of invited again?
3. **Domains for Pulse4all.** Should `auth.invitation_email_domains` be set to `pulse4all.com`? IAP admits only pulse4all.com accounts anyway, so it would only stop typos earlier.
4. **The token in request logs.** Is it acceptable as is (single use, days, one address, behind IAP)? Or should we test whether IAP keeps a `#fragment` through its sign-in, so that the token can move out of the path?
5. **Retention.** An invitation that was never accepted keeps the address and name for good, because rows are never deleted. Should the address and name be blanked after N days for expired and revoked ones (with Yordi, with the staff-data rule)?
6. **Automatic sending.** Should the Workspace send invitations itself later (a sender mailbox with Gmail API delegation, or a mail provider), or does Open in mail stay?
7. **Public access prevention.** If `deploy.sh prod` stops on it, should `p4a-cma-prod` get an exception for this one bucket?
8. **Dev's budget.** Dev's connection ceiling is 72 against 50. Should anything be lowered (for example NocoDB's pools in dev), or is that left as is because the real load is far below?
9. **The other decisions.** Does each of the rest stand: decisions 3 to 9 and 11?

## Left for the morning

- `MORNING_RUNBOOK.md` in this folder holds steps 1 to 10, in order:
  1. Review and build the pull request.
  2. Run 0008l in dev with `67` normal and provoked, then `63` and `65`.
  3. Run 0008l in prod with a read-only check.
  4. Merge (the flag stays `legacy`), then dev on the merged image with `--invitations`.
  5. Fill in `max_connections` and the connection counts.
  6. People → Invite in prod, per role.
  7. The Gemini audit (prompt included).
  8. `deploy.sh prod`, dry run then `--apply`.
  9. The test plan a to e.
  10. `_LOGOUT_TARGET=signed-out`.
- **Order matters:** 0008l must run in prod before the merge, because the merged People page reads `cma.invitations()`.
- Records of the real runs are Martin's to commit: `records/0008l-dev-<date>`, `records/0008l-prod-<date>` and the signed-out deploy.
- Each dev run of `verify/api.mjs --invitations` leaves its invitations revoked or accepted, and one deactivated person `API verifier …`.
