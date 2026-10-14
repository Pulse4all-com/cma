# Morning runbook, 15 October 2026: invitations (0008l), the signed-out page, the connection budget

Read `NIGHT_NOTES.md` first (ten minutes: the decisions taken and the questions). Labels: **Browser**, **Terminal** (Cloud Shell, in `~/cma` unless stated), **Studio** (the instance named), **File** (a repository path). SQL and shell never share a block. Every step ends with what you should see.

**Order matters.** The merged web reads the functions of addition 0008l on People (the Invitations section) and on `/invite`, so 0008l runs in dev and prod from the pull request's branch **before** the merge; until it runs in prod, a merged `main` would show People with an error. The signed-out page needs nothing before the merge: the flag stays `legacy` (Log out unchanged) until steps 7 to 9 have passed. Invitations work without any of Part A's infrastructure.

| Step | What | Elapsed |
|---|---|---|
| 1 | Review the pull request, build it in Cloud Shell | 30 min |
| 2 | 0008l in dev with `67` normal and provoked, `63` and `65` again | 10 min |
| 3 | 0008l in prod with a read-only check | 10 min |
| 4 | Merge (flags off), watch the prod build; dev on the merged image | 15 min |
| 5 | The connection budget's real numbers in prod (a small README pull request) | 10 min |
| 6 | People → Invite in prod: an invitation per role, one accepted, the others revoked | 15 min |
| 7 | The Gemini audit of the bucket, the URL map change and the invitation flow | 30 min |
| 8 | `docs/signed-out/deploy.sh prod`: dry run, then `--apply` | 15 min |
| 9 | The signed-out test plan a to e | 15 min |
| 10 | `_LOGOUT_TARGET=signed-out`, rebuild | 10 min |

---

## Helpers (define in every new Cloud Shell)

The helpers of `docs/night-2026-10-13/MORNING_RUNBOOK.md`, unchanged.

**Terminal**
```bash
command -v nvm >/dev/null || source /usr/local/nvm/nvm.sh; nvm use 22 >/dev/null; cd ~/cma
cma_db () {  # usage: cma_db dev|prod  → starts the proxy once and sets PGCONN
  local env=$1 port; [ "$env" = dev ] && port=5433 || port=5434
  pgrep -f "cloud-sql-proxy.*cma-$env-pg" >/dev/null || \
    (cloud-sql-proxy --auto-iam-authn --port $port "p4a-cma-$env:europe-west4:cma-$env-pg" >/tmp/proxy-$env.log 2>&1 &)
  sleep 3
  export PGCONN="host=127.0.0.1 port=$port dbname=cma user=$(gcloud config get-value account 2>/dev/null) sslmode=disable"
  psql "$PGCONN" -Atc "select 'connected to ' || current_database() || ' as ' || current_user"
}
run_migration () {  # usage: run_migration <env> <nn_migration.sql> <nn_verify.sql> <records dir> [earlier verify files...]
  local env=$1 mig=$2 ver=$3 rec=$4; shift 4
  cd ~/cma && mkdir -p "records/$rec" && cma_db "$env" || return 1
  psql "$PGCONN" -v ON_ERROR_STOP=1 -f "db/$mig" > "records/$rec/${mig%%_*}.txt" 2>&1 && tail -3 "records/$rec/${mig%%_*}.txt"
  psql "$PGCONN" -v ON_ERROR_STOP=1 -f "db/$ver" > "records/$rec/${ver%%_*}.txt" 2>&1; tail -6 "records/$rec/${ver%%_*}.txt"
  sed "s/select set_config('verify.provoke', 'false', false);/select set_config('verify.provoke', 'true', false);/" "db/$ver" > /tmp/provoke.sql
  psql "$PGCONN" -v ON_ERROR_STOP=0 -f /tmp/provoke.sql > "records/$rec/${ver%%_*}-provoked.txt" 2>&1
  grep -cE "FAIL" "records/$rec/${ver%%_*}-provoked.txt" | sed 's/^/provoked FAIL lines: /'; grep -E "PROVOKED" "records/$rec/${ver%%_*}-provoked.txt" | tail -2
  for f in "$@"; do psql "$PGCONN" -v ON_ERROR_STOP=1 -f "db/$f" > "records/$rec/${f%%_*}-rerun.txt" 2>&1; echo "$f: $(grep -cE '\| PASS' "records/$rec/${f%%_*}-rerun.txt") PASS rows"; done
}
```
Expected: `v22.…` is active (`node -v`), no other output. `type cma_db run_migration` prints both functions.

---

## 1. Review the pull request and build it

**Browser:** GitHub → Pulse4all-com/cma → Pull requests → "Night 15 October: signed-out page, invitations, connection budget". Read the description and the diff; the night's outputs are under `docs/night-2026-10-15/local-records/`, the screenshots in its `web/screenshots/` and `signed-out/screenshots/` folders.

Expected: one pull request from `night-2026-10-15`; `cloudbuild.yaml` changed only by the new substitution `_LOGOUT_TARGET` (default `legacy`), its check in `check-config` and `CMA_LOGOUT_TARGET` in `--set-env-vars`; nothing under `ingest/` or `records/`.

**Terminal** (the pull request's number from the page)
```bash
cd ~/cma && gh pr checkout <number> && cd web && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run build 2>&1 | tail -5; echo "build exit: ${PIPESTATUS[0]}"; npm run -s verify:invitations | tail -1; npm run -s verify:signed-out | tail -1; cd ~/cma
```
Expected: the route list with `/api/v1/team/invitations`, `/api/v1/team/invitations/[id]/renew`, `/api/v1/team/invitations/[id]/revoke`, `/invite/[token]` and `/invite/accept`, then `build exit: 0`, `invitations: PASS (27 checks)`, `signed-out: PASS (11 checks)`. **Do not merge yet.**

## 2. Addition 0008l in dev

`66` refuses to run before 0008k. If B16.1's morning runbook (`docs/b16-1-history-start/MORNING_RUNBOOK.md`) has not run `64` in dev and prod yet, run that first.

**Studio (cma-dev-pg)**
```sql
set role cma_owner;
select version from cma.schema_migration where version in ('0008j', '0008k', '0008l') order by 1;
reset role;
```
Expected: `0008j` and `0008k`, no `0008l`.

**Terminal** (still on the pull request's branch)
```bash
run_migration dev 66_invitations.sql 67_verify_invitations.sql 0008l-dev-$(date +%F) 63_verify_calls_overview.sql 65_verify_calls_history_start.sql
```
Expected: `connected to cma as martin@pulse4all.com`; the last lines of `66` are `INSERT 0 1`, `COMMIT`, `RESET` (no `ERROR`); `67` ends with the verdict row `PASS | 23 PASS, 0 FAIL`; `provoked FAIL lines: 24` and `PROVOKED, NOT A PASS | 0 PASS, 23 FAIL` (every check fails, plus the verdict's count); `63_verify_calls_overview.sql: 20 PASS rows`, `65_verify_calls_history_start.sql: 12 PASS rows`. A `REFUSED` line means the session is not on dev: check `cma_db dev`. `addition 0008k (64_calls_history_start.sql) must run before 0008l` means 0008k is missing: see above.

## 3. Addition 0008l in prod

**Terminal** (point-in-time recovery on, as before every prod migration)
```bash
gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format="value(settings.backupConfiguration.pointInTimeRecoveryEnabled,settings.backupConfiguration.transactionLogRetentionDays)"
```
Expected: `True	7`.

`67`, `63` and `65` refuse prod (they write throwaway tenants), so prod runs the migration, then a read-only check in Studio.

**Terminal**
```bash
rec=records/0008l-prod-$(date +%F); mkdir -p "$rec" && cma_db prod && psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/66_invitations.sql > "$rec/66.txt" 2>&1; tail -3 "$rec/66.txt"
```
Expected: `connected to cma as martin@pulse4all.com`, then `INSERT 0 1`, `COMMIT`, `RESET` (on a rerun `INSERT 0 0`).

**Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select version, applied_at, applied_by from cma.schema_migration where version = '0008l';
select key, value_type, default_value from cma.setting where key like 'auth.invitation%' order by 1;
select p.oid::regprocedure as fn, pg_get_userbyid(p.proowner) as owner, p.prosecdef as definer, p.proconfig as config,
       has_function_privilege('cma_app', p.oid, 'execute') as app, has_function_privilege('cma_readonly', p.oid, 'execute') as reader
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'cma' and p.proname in ('create_invitation', 'renew_invitation', 'revoke_invitation', 'invitations',
  'invitation_preview', 'accept_invitation', 'invitation_other_tenant')
order by 1;
select has_column_privilege('cma_app', 'cma.invitation', 'token_hash', 'select') as app_reads_hash,
       has_table_privilege('cma_app', 'cma.invitation', 'delete') as app_deletes,
       (select count(*) from cma.invitation) as invitations;
reset role;
```
Expected: one row `0008l` with today's time and your login; `auth.invitation_email_domains | text | ` (empty) and `auth.invitation_valid_days | integer | 7`; seven functions, every owner `cma_owner`, `definer` true only for `invitation_preview` and `accept_invitation` with config `{"search_path=pg_catalog, cma, pg_temp"}`, `app` true on every row but `invitation_other_tenant` (false), `reader` false on every row; `app_reads_hash` false, `app_deletes` false, `invitations` 0.

## 4. Merge, watch the prod build, dev on the merged image

**Browser:** the pull request → **Squash and merge** (the title as it stands) → Confirm.

**Terminal** (`docs/RUNBOOK.md` section 3; wait 4 minutes before running the trigger by hand, as README Release flow says)
```bash
cd ~/cma && git switch -q main && git pull -q --ff-only && sha=$(git rev-parse --short HEAD) && echo $sha
gcloud builds list --project=p4a-cma-prod --region=europe-west4 --limit=1 --format="value(substitutions.SHORT_SHA,status)"
gcloud builds log $(gcloud builds list --project=p4a-cma-prod --region=europe-west4 --limit=1 --format="value(id)") --project=p4a-cma-prod --region=europe-west4 | grep "^config:"
```
Expected: the merge's short SHA, then the same SHA with `WORKING`, later `SUCCESS` (rerun the second line every two minutes); the config line ends `logout=legacy` (the trigger has no `_LOGOUT_TARGET`, so the file's default applies: Log out is unchanged).

**Terminal** (dev on the merged image; the invitation checks of the API verifier, run only on request)
```bash
gcloud run services update cma-web --project=p4a-cma-dev --region=europe-west4 \
  --image=europe-west4-docker.pkg.dev/p4a-cma-prod/cma/web:$sha 2>&1 | tail -1
pkill -f "run services proxy"; gcloud run services proxy cma-web --project=p4a-cma-dev \
  --region=europe-west4 --port=8080 >/tmp/proxy.log 2>&1 & sleep 6
curl -s localhost:8080/api/health; echo
cd ~/cma/web && mkdir -p ../records/0008l-dev-$(date +%F) && node verify/api.mjs --invitations | tee ../records/0008l-dev-$(date +%F)/verify-api-invitations.txt | tail -1; node verify/api.mjs --invitations --provoke | tail -1; cd ~/cma
```
Expected: the new revision serving 100 %; `version` = `$sha`, `auth` `mock`, `data` `api`; `ALL 15 PASS` and `ALL 15 PROVOKED CHECKS FAILED, as they must`. Each run leaves its invitations revoked or accepted and one deactivated person `API verifier …` (`invitee-api-<time>@example.com`, system `mock`) on dev's People: dev data, as the switched-off alert rule of `--sources`. The full `verify:api` (inside 07:00 to 22:00 Amsterdam time) is unchanged by this pull request and runs as before when you next run it.

## 5. The connection budget's real numbers

**Studio (cma-prod-pg)**
```sql
show max_connections;
```
Expected: one number; write it down.

**Studio (cma-prod-pg)**
```sql
select coalesce(usename, '(background)') as login, coalesce(application_name, '') as app, count(*) as connections
from pg_stat_activity group by 1, 2 order by 3 desc;
```
Expected: a few rows: `cma-web@p4a-cma-prod.iam` (`cma-web`), `cma-ingest@p4a-cma-prod.iam`, `cma-nocodb@p4a-cma-prod.iam` if NocoDB is running, your own login, Cloud SQL's own; the sum well below the budget's 97 and below `max_connections`.

**File:** `README.md`, Infrastructure, Database connection budget: replace **to be filled in by Martin** by the value and the date (for example "100 on 15 October 2026"); then a small pull request "README: max_connections in the connection budget" (no build: README only).

## 6. People → Invite in prod

You need a second pulse4all.com Google account that is not a person in either business line (IAP admits pulse4all.com accounts; an account that already works in Invest is refused with "Your account already works in another business line").

**Browser:** `https://workspace.pulse4all.app` as yourself (admin) → Team → **People**.

1. The **Invitations** section under the people: "No invitations yet". **Invite** (V) opens the dialog: Role lists Agent, Analytics, Supervisor, Call center manager, Administrator (never Scheduler).
2. One invitation per role. One pending invitation per address is allowed, so use the second account's real address for the one you accept and `+` addresses for the others, which you revoke (they never need to arrive): `<second>@pulse4all.com` as **Agent**, then `<second>+supervisor@pulse4all.com`, `+analytics`, `+manager` and `+admin` with those roles; employer Pulse4all; language as you like. Expected after each: "Invitation ready" with the link `https://workspace.pulse4all.app/invite/<43 characters>`, Copy link and Open in mail. For the agent's, **Open in mail**: your mail client opens a message to the second account with the subject "Your invitation to the Workspace of …" and the link, the role and the expiry in its body; send it.
3. The list shows five open invitations with State Open and Expires in seven days.
4. In a private window signed in as the second account, open the link from the mail. Expected: "Join Pulse4all Subscriptions" (or the tenant's name), "… as Agent", **Accept** focused. Before accepting, open the same link in your own (admin) window: you are taken to Welcome (you are a person there), and the list still says Open.
5. Accept (Enter). Expected: Welcome for the second account, as an agent. People: the new person, role Agent, employer Pulse4all; the invitation Accepted by them, now.
6. Revoke the four `+` invitations: Revoke, then the same button again ("Tap again to revoke"). Expected: State Revoked, revoked by you, now. Open one of their links in the private window: "This invitation link does not work".
7. Afterwards: Edit person on the test agent → Active off → Save (people are never deleted).

## 7. The Gemini audit

**Browser:** Gemini (the auditor used for the first six audits) with the repository's public URL and the pull request's number. Paste the prompt below as it stands, the number filled in. File the answer in `docs/night-2026-10-15/` as `GEMINI_AUDIT.md` (a records pull request), and send me the findings before step 8 if any is high or critical.

**File** (the prompt)
```text
You are a security auditor. Audit one change to the Contactcenter-Management-App (CMA) of Pulse4all, the public GitHub
repository Pulse4all-com/cma, pull request #<number> (merged to main on 15 October 2026). The CMA is a Next.js 16 app on
Cloud Run behind a global external Application Load Balancer with Identity-Aware Proxy (IAP), on Cloud SQL PostgreSQL 18
with row-level security per tenant. Read README.md sections Authentication, Infrastructure (Signed-out page, Database
connection budget), Data model: invitations (addition 0008l), API (People, The invitation page, Log out and the
signed-out page) and the Decision log rows of 15 October 2026 first.

Scope, three parts, nothing else:

1. The public bucket and the static page: web/signed-out/index.html, docs/signed-out/deploy.sh, docs/signed-out/urlmap.py,
   docs/signed-out/README.md. The bucket <project>-signed-out is public (allUsers objectViewer) and is served on the
   Workspace's own host at /signed-out through a backend bucket. Check: what else could ever be readable or served from
   it; whether anything served there can run script with the Workspace's origin; the page's CSP (meta tag and the
   backend bucket's response header), its inline script and the hash; cookies, storage and requests (there must be none);
   the two Google addresses (AddSession with continue=https://<location.host>/, Logout) and whether they can be turned
   into an open redirect; whether deploy.sh can leave the bucket or the load balancer in an unsafe state when a step
   fails halfway, and whether its dry run truly changes nothing.

2. The URL map change on cma-web-urlmap (planned by docs/signed-out/urlmap.py, applied by deploy.sh): two route rules
   for the Workspace's host, priority 1 prefix /signed-out with the query parameter gcp-iap-mode=CLEAR_LOGIN_COOKIE to
   cma-web-backend (IAP), priority 2 prefix /signed-out to the backend bucket; the default service and the host rule of
   ingest.pulse4all.app unchanged. Check: whether any request can reach cma-web without IAP because of these rules
   (path normalisation, encoded characters such as %2F or %2E, dot segments, case, a second query parameter, a trailing
   slash, the host header); whether the planner's conversion of pathRules to routeRules keeps the same matching; whether
   its structural check and the url-map tests would catch a wrong plan; the rollback.

3. The invitation flow: db/66_invitations.sql (cma.invitation, cma.create_invitation, cma.renew_invitation,
   cma.revoke_invitation, cma.invitations, and the two SECURITY DEFINER functions cma.invitation_preview and
   cma.accept_invitation), db/67_verify_invitations.sql, web/src/app/api/v1/team/invitations/**, web/src/app/invite/**,
   web/src/lib/invitations.ts, web/src/lib/origin.ts, the invitation methods of web/src/lib/data/postgres.ts,
   web/src/proxy.ts. Check: token entropy (32 bytes from three gen_random_uuid() through SHA-256), storage (SHA-256 only,
   unreadable by the application role, absent from the audit log), single use, expiry, lookup by hash; that acceptance
   binds the Google account id only when IAP's verified email equals the invited address and never matches a person by
   address; tenant confinement of the SECURITY DEFINER functions (they set the tenant context themselves; can a caller
   influence them through settings, search_path, temporary objects or a crafted token?); privilege escalation through
   the role (the inviter's ceiling users.manage_agents versus users.manage_all, the system role scheduler, a role or an
   inviter that changed after the invitation was made, a renewal by another person); CSRF on the three POST routes and
   on POST /invite/accept (a plain form post with a same-origin check); open redirects; GET /invite changing state;
   account enumeration through answers or timing; the token in request logs (Cloud Run, the load balancer) and in
   Referer headers; personal data kept forever in never-deleted invitation rows (GDPR).

For every finding give: a number, the severity (critical, high, medium, low, info), the file and line, a concrete attack
or failure scenario with the requests or inputs, and the smallest fix. Say explicitly which of the checks above you found to be
in order (no finding). Do not propose moving any of this into HubSpot, and do not propose anything that puts a secret in code.
```
Expected: an answer with numbered findings; none high or critical before step 8.

## 8. `deploy.sh prod`: dry run, then apply

**Terminal**
```bash
cd ~/cma && bash docs/signed-out/deploy.sh prod --logo web/public/brand/logo-blue.png --name "Pulse4all" 2>&1 | tee ~/signed-out-dry-run.txt | grep -E "^(a|b|c|d|e)\.|^\+|STOP|^=="
```
Expected: `a. storage.publicAccessPrevention is not enforced for p4a-cma-prod`; `e. cma-web-urlmap exported to ~/cma-web-urlmap-<time>.yaml` with the restore command; `e. plan: workspace.pulse4all.app has no host rule (the map's default service serves it): add path matcher cma-web …` (or, if the map has a host rule for the Workspace, `the two route rules added to path matcher …`); `e. check: apart from the two route rules … the map is as exported`; lines starting with `+` for: the bucket's create, the allUsers binding, three uploads, the backend bucket's create and the URL map's import; `e. validate runs with --apply, once cma-signed-out-backend exists`; `== dry run done`. A `STOP` line: nothing was changed; send it to me. `a. STOP: the organisation policy storage.publicAccessPrevention is enforced`: a public bucket is impossible there; Part A waits for your decision on an exception.

**Terminal** (the same with `--apply`)
```bash
cd ~/cma && bash docs/signed-out/deploy.sh prod --logo web/public/brand/logo-blue.png --name "Pulse4all" --apply 2>&1 | tee ~/signed-out-apply.txt | grep -E "^(a|b|c|d|e)\.|STOP|^==|ERROR"
```
Expected: the same plan; `c. gs://p4a-cma-prod-signed-out holds exactly: signed-out signed-out/Montserrat-VF.ttf signed-out/logo-blue.png`; `e. validate: the map loads and every test passes`; `== done`. Keep the export file the script names: it is the rollback (`docs/signed-out/README.md`, Rollback).

## 9. The signed-out test plan

**File:** `docs/signed-out/README.md`, Prod test plan, steps a to e, in that order. Stop at the first that does not hold and roll back (same file, Rollback).

Expected: a to e as the table there says; in short: `/signed-out?gcp-iap-mode=CLEAR_LOGIN_COOKIE` ends on `/signed-out`, signed out; Log in is silent with one account and shows Google's chooser with two; Use another account goes through Google's add-account page; Log out of Google signs the browser out of Google; `ingest.pulse4all.app` and every other path behave as before.

## 10. `_LOGOUT_TARGET=signed-out`

**Terminal** (the trigger's substitutions, as README Build and deploy describes: export, edit, import, run)
```bash
cd ~ && gcloud beta builds triggers export cma-web-main --project=p4a-cma-prod --region=europe-west4 --destination=cma-web-main.yaml
grep -n "_LOGOUT_TARGET\|substitutions:" cma-web-main.yaml
```
Expected: the `substitutions:` line and no `_LOGOUT_TARGET` yet.

**File:** `~/cma-web-main.yaml`: under `substitutions:` add the line `  _LOGOUT_TARGET: signed-out` (two spaces, like the others).

**Terminal**
```bash
cd ~ && gcloud beta builds triggers import --project=p4a-cma-prod --region=europe-west4 --source=cma-web-main.yaml && gcloud builds triggers run cma-web-main --project=p4a-cma-prod --region=europe-west4 --branch=main
```
Expected: the trigger imported, then a build; its config line ends `logout=signed-out` and it ends `SUCCESS`.

**Browser:** Workspace → My day → Log out → Log out. Expected: the browser ends on `https://workspace.pulse4all.app/signed-out`, "You're logged out", not signed in again. No access yet (an account without a person) now offers "Use another account".

---

## Afterwards

- **Records:** `records/0008l-dev-<date>/` (step 2, and step 4's `verify-api-invitations.txt`), `records/0008l-prod-<date>/` (step 3, with the Studio output of steps 3 and 5 pasted into a `studio.txt`), and the signed-out run (`~/signed-out-dry-run.txt`, `~/signed-out-apply.txt`, the export's name, the test plan's outcome) as `records/signed-out-prod-<date>/`, committed as a records pull request; values from your runs only.
- **Answers** to the questions in `NIGHT_NOTES.md` (Questions for Martin), each a small follow-up once decided:
  1. may a call center manager invite supervisors and analytics (as Add a person), or agents only;
  2. an inactive person is reactivated on People, not invited again;
  3. `auth.invitation_email_domains` = `pulse4all.com` for Pulse4all, or empty;
  4. the token in request logs as is, or a test whether IAP keeps a `#fragment` through its sign-in;
  5. retention of never-accepted invitations' address and name (with Yordi);
  6. automatic sending later, or Open in mail stays;
  7. an exception to public access prevention for the signed-out bucket, if step 8 stops on it;
  8. dev's connection ceiling of 72 against 50;
  9. the night's other derived decisions (NIGHT_NOTES, Decisions taken 3 to 9 and 11).
