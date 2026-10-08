# Morning runbook: releasing the night build of 8 to 9 October 2026

Four patches (or four branches with open PRs, if the night had a token), applied to `main` at `ff93b8e` in order, each its own pull request. The order per slice is the README's: migration in dev → migration in prod → merge → the same image on dev → the API verifier → a hand check in prod. Slice 1 is database only (no build); slice 2 is web (a merge builds and deploys prod); slice 3 is web plus the job's `gcloud`; slice 4 is documents. Read `NIGHT_NOTES.md` section 1 first.

Labels: **Studio** (Cloud SQL Studio, instance named; first statement `set role cma_owner;`), **Terminal** (Cloud Shell, `~/cma` unless stated), **Browser**, **File**. SQL and shell never share a block. Expected outputs are given after each block. Lessons of the first morning kept: define the helper in every new shell, `ls ~` before applying, `main` may have moved.

## 0. Start of the morning

**Browser:** Cloud Shell → ⋮ → Upload: `g-01-0005a.patch`, `g-02-configuration.patch`, `g-03-scheduler.patch`, `g-04-readme.patch` (they land in `~`).

**Terminal**
```bash
command -v nvm >/dev/null || source /usr/local/nvm/nvm.sh
nvm install 22 >/dev/null && nvm use 22 >/dev/null && node -v
ls ~/g-0*.patch
cd ~/cma && git switch main -q && git pull -q --ff-only && git log --oneline -1
git apply --check ~/g-01-0005a.patch && echo "g-01-0005a.patch applies"
```
Expected: four patch files; `ff93b8e README fifteenth pass …`; then `g-01-0005a.patch applies`. Patches 2 to 4 build on each other; the night applied all four in sequence on a fresh clone of `ff93b8e` and the tree came out identical to its branches. If `git pull` brings anything newer than `ff93b8e`, stop: the patches were cut against `ff93b8e`, and a newer `main` needs a rebase first.

**Terminal** (define in every new shell)
```bash
apply_night () {  # usage: apply_night <branch> <patch file>
  cd ~/cma && git switch -q -c "$1" && git am -q --committer-date-is-author-date "$2" && git log --oneline -1
}
```

## 1. Slice 1: migration 0005a, the configuration functions, the scheduler user, the forgotten-day close

### 1.1 Apply the patch

**Terminal**
```bash
apply_night g-01-0005a ~/g-01-0005a.patch
git show --stat --format= HEAD | tail -5
```
Expected: one commit "0005a: configuration functions, the scheduler user and the forgotten-day close"; files `db/18`, `db/26`, `db/27`, `records/0005a-dev-2026-10-08/README.md`.

### 1.2 Dev: run the migration, verify, rerun the earlier verifies

**Studio (cma-dev-pg, database cma)** — paste and run, one file at a time, in this order:
1. `db/26_configuration.sql` → last result: one row, migration `0005a` recorded (the NOTICE about `app_user_kind_check` not existing on the first run is expected).
2. `db/27_verify_configuration.sql` → last result (the verdict):

| tenant | scheduler_users | roles_with_close_forgotten | grace_minutes | active_statuses | active_links | verdict |
|---|---|---|---|---|---|---|
| pulse4all-invest | 1 | scheduler | 120 (default) | 5 | 2 | PASS |
| pulse4all-subscriptions | 1 | scheduler | 120 (default) | 7 | 3 | PASS |

(`active_links` is 3 on subscriptions in dev because the dev fixture `03` adds a team-sheet link; prod shows 2 and 2.)

3. `db/18_verify_clock_in_app_links.sql` (changed: A5 accepts the app's insert and update since 0005a) → PASS on both tenants.

The provoked run and the records, from the Terminal through the Auth Proxy:

**Terminal**
```bash
cd ~/cma && mkdir -p records/0005a-dev-2026-10-09 && rm -f records/0005a-dev-2026-10-08/README.md && rmdir records/0005a-dev-2026-10-08 2>/dev/null
cloud-sql-proxy --auto-iam-authn --port 5433 p4a-cma-dev:europe-west4:cma-dev-pg >/tmp/proxy-dev.log 2>&1 &
sleep 4
PGCONN="host=127.0.0.1 port=5433 dbname=cma user=$(gcloud config get-value account) sslmode=disable"
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/27_verify_configuration.sql 2>&1 | tee records/0005a-dev-2026-10-09/verify-0005a.txt | tail -4
sed "s/select set_config('verify.provoke', 'false', false);/select set_config('verify.provoke', 'true', false);/" db/27_verify_configuration.sql > /tmp/27p.sql
psql "$PGCONN" -v ON_ERROR_STOP=0 -f /tmp/27p.sql 2>&1 | tee records/0005a-dev-2026-10-09/verify-0005a-provoke.txt | grep -E "FAIL|PROVOKED"
for f in 14_verify_tenant_settings 16_verify_team_status_time 18_verify_clock_in_app_links 20_verify_team_now 22_verify_teams_skills 25_verify_roster; do psql "$PGCONN" -v ON_ERROR_STOP=1 -At -f db/$f.sql 2>&1 | tail -1 | tee -a records/0005a-dev-2026-10-09/reruns.txt; done
sed "s/select set_config('verify.provoke', 'false', false);/select set_config('verify.provoke', 'true', false);/" db/18_verify_clock_in_app_links.sql > /tmp/18p.sql
psql "$PGCONN" -v ON_ERROR_STOP=0 -f /tmp/18p.sql 2>&1 | tee records/0005a-dev-2026-10-09/verify-0003d-provoke.txt | grep -E "FAIL|PROVOKED" | head -3
```
Expected: the verdict rows as above; provoked: `FAIL A2`, `FAIL B1`, then two verdict rows `PROVOKED, NOT A PASS`; the six reruns each end in `PASS`; `18` provoked: `FAIL A4`, `FAIL B2`, `PROVOKED, NOT A PASS`.

### 1.3 Prod: point-in-time recovery, the migration, verify

**Browser:** Console → SQL → cma-prod-pg → Backups: point-in-time recovery enabled (or take an on-demand backup first).

**Studio (cma-prod-pg, database cma)** — in this order:
1. `db/26_configuration.sql` → migration `0005a` recorded. This creates the Scheduler system user in both prod tenants; it holds no clock and never appears on People.
2. `db/27_verify_configuration.sql` → verdict PASS on both tenants (links 2 and 2).
3. `db/18_verify_clock_in_app_links.sql` → PASS on both tenants.

**Terminal**
```bash
cd ~/cma && mkdir -p records/0005a-prod-2026-10-09
cloud-sql-proxy --auto-iam-authn --port 5434 p4a-cma-prod:europe-west4:cma-prod-pg >/tmp/proxy-prod.log 2>&1 &
sleep 4
PGPROD="host=127.0.0.1 port=5434 dbname=cma user=$(gcloud config get-value account) sslmode=disable"
psql "$PGPROD" -v ON_ERROR_STOP=1 -f db/27_verify_configuration.sql 2>&1 | tee records/0005a-prod-2026-10-09/verify-0005a.txt | tail -4
psql "$PGPROD" -v ON_ERROR_STOP=0 -f /tmp/27p.sql 2>&1 | tee records/0005a-prod-2026-10-09/verify-0005a-provoke.txt | grep -E "FAIL|PROVOKED"
for f in 14_verify_tenant_settings 16_verify_team_status_time 18_verify_clock_in_app_links 20_verify_team_now 22_verify_teams_skills 25_verify_roster; do psql "$PGPROD" -v ON_ERROR_STOP=1 -At -f db/$f.sql 2>&1 | tail -1 | tee -a records/0005a-prod-2026-10-09/reruns.txt; done
```
Expected: as in dev.

### 1.4 Merge

**Terminal**
```bash
cd ~/cma && git add records && git commit -q -m "records: 0005a in dev and prod, 9 October 2026" && git push -q -u origin g-01-0005a
gh pr create --title "0005a: configuration functions, the scheduler user and the forgotten-day close" --body "Night build of 8 to 9 October 2026, slice 1. Migration and verify run in dev and prod this morning; records in this PR." --base main --head g-01-0005a
gh pr merge --squash --delete-branch
git switch main -q && git pull -q --ff-only && git log --oneline -1
```
Expected: a PR number, a merge, `main` one commit further. No build: nothing under `web/` changed.

## 2. Slice 2: the configuration screens

### 2.1 Apply, build, merge

**Terminal**
```bash
apply_night g-02-configuration ~/g-02-configuration.patch
git rebase -q main && git log --oneline -2
cd web && npm ci --no-audit --no-fund --ignore-scripts >/dev/null && npm run typecheck && npm run lint && npm run build 2>&1 | tail -3
npm run verify 2>&1 | grep -E "PASS|FAIL" | tail -12
```
Expected: the commit "Configuration screens (0005a): …" on top of the merged slice 1; typecheck, lint and build clean; the pure verifiers PASS (copy 500 keys, corrections 26, csv 15, dashboard 17, live 26, team 18, roster 31, configuration 30). Theme and layout need the local mock server: `cp -r .next/static .next/standalone/.next/ && cp -r public .next/standalone/` then `CMA_AUTH_MODE=mock CMA_DATA_MODE=mock PORT=8080 npm start` in a second tab; expected `theme: PASS (18 pages …)` and `layout: PASS (… the Configuration group for 5 identities …)`, which also writes `records/layout/*.png` for the commit.

**Terminal**
```bash
cd ~/cma && git add records/layout && git commit -q -m "records: layout screenshots with the Configuration group" ; git push -q -u origin g-02-configuration
gh pr create --title "Configuration screens (0005a)" --body "Night build of 8 to 9 October 2026, slice 2: the Configuration group with five screens, the routes under /api/v1/configuration, the configuration verifier, API verifier 138. Dev image and API verifier records follow in the slice's records PR." --base main --head g-02-configuration
gh pr merge --squash --delete-branch
git switch main -q && git pull -q --ff-only && git log --oneline -1
gcloud builds list --region=europe-west4 --project=p4a-cma-prod --limit=1 --format="table(id,status,substitutions.SHORT_SHA)"
```
Expected: the merge starts the build (about two minutes); `SUCCESS` with the new short SHA. If the webhook did not fire: `gcloud builds triggers run cma-web-main --region=europe-west4 --project=p4a-cma-prod --sha=$(git rev-parse HEAD)`.

### 2.2 Dev image and the API verifier

**Terminal**
```bash
SHA=$(cd ~/cma && git rev-parse --short HEAD)
gcloud run services update cma-web --project=p4a-cma-dev --region=europe-west4 --image=europe-west4-docker.pkg.dev/p4a-cma-prod/cma/web:$SHA --quiet
gcloud run services proxy cma-web --project=p4a-cma-dev --region=europe-west4 --port=8080 >/tmp/proxy-web.log 2>&1 &
sleep 6; curl -s http://localhost:8080/api/health
cd ~/cma && mkdir -p records/configuration-2026-10-09 && rm -f records/configuration-2026-10-09/README.md && cd web
node verify/api.mjs 2>&1 | tee ../records/configuration-2026-10-09/api-verify-138.txt | tail -1
node verify/api.mjs --provoke 2>&1 | tee ../records/configuration-2026-10-09/api-verify-138-provoke.txt | tail -1
```
Expected: `{"status":"ok","version":"<sha>","auth":"mock","data":"api"}`; `ALL 138 PASS`; `ALL 138 PROVOKED CHECKS FAILED, as they must`. The run leaves one retired status `verify_0005a` and one retired link `verify-0005a` in dev's subscriptions tenant (dev data; the next run reuses them).

### 2.3 Hand check in prod

**Browser:** workspace.pulse4all.app as Martin (admin): the rail shows **Configuration** after Reports with no numbers; `C` opens it and focuses Statuses; Enter opens it. On Statuses: the seven Subscriptions statuses with their flags, Available - Sales as the default, Time events on the ones with time behind them; Edit on such a status shows the flags disabled with the note. On Exports: the three Dutch settings, the preview `08-10-2026;A. Example;7,50` under the date of today, the grace at 120 (default). On App links: the two seeded links; replace the generic HubSpot and Aircall addresses with the exact portal addresses if you have them (the Open decision). As Finn (supervisor): no Configuration group; `/configuration/statuses` by hand shows "Configuration is for admins".

**Terminal**
```bash
cd ~/cma && git switch -q -c records-configuration && git add records/configuration-2026-10-09 && git commit -q -m "records: API verifier 138 on dev, configuration (9 October 2026)" && git push -q -u origin records-configuration && gh pr create --fill --base main && gh pr merge --squash --delete-branch && git switch main -q && git pull -q --ff-only
```

## 3. Slice 3: the scheduler

### 3.1 Apply, build, merge

**Terminal**
```bash
apply_night g-03-scheduler ~/g-03-scheduler.patch
git rebase -q main && git log --oneline -2
cd web && npm run typecheck && npm run lint && npm run build 2>&1 | tail -2 && ls .next/standalone/node_modules/@google-cloud
cd ~/cma && git push -q -u origin g-03-scheduler
gh pr create --title "The scheduler (0005a): a Cloud Run job on the web image, hourly from Cloud Scheduler" --body "Night build of 8 to 9 October 2026, slice 3: jobs/close-forgotten-workdays.mjs, the connector as a server-external package, verify/scheduler.mjs, docs/scheduler/deploy.sh." --base main --head g-03-scheduler
gh pr merge --squash --delete-branch
git switch main -q && git pull -q --ff-only && git log --oneline -1
gcloud builds list --region=europe-west4 --project=p4a-cma-prod --limit=1 --format="table(id,status,substitutions.SHORT_SHA)"
```
Expected: `cloud-sql-connector` listed under `@google-cloud` in the standalone output (the image carries it); the build `SUCCESS`.

### 3.2 Dev: the image, the job, the proof

**Terminal**
```bash
SHA=$(cd ~/cma && git rev-parse --short HEAD)
gcloud run services update cma-web --project=p4a-cma-dev --region=europe-west4 --image=europe-west4-docker.pkg.dev/p4a-cma-prod/cma/web:$SHA --quiet
cd ~/cma && docs/scheduler/deploy.sh dev $SHA
gcloud run jobs execute cma-close-forgotten-workdays --project=p4a-cma-dev --region=europe-west4 --wait
gcloud logging read 'resource.type=cloud_run_job AND resource.labels.job_name=cma-close-forgotten-workdays' --project=p4a-cma-dev --limit=10 --format='value(textPayload)'
```
Expected: the job and the schedule created; the execution completes; the log reads `close-forgotten-workdays: 2 tenant(s)`, then one line per tenant with its count (dev may close Agent Two's leftover day of the last API run; a figure, no name). If the job fails with a connection error, the dev service account `cma-web@p4a-cma-dev.iam.gserviceaccount.com` lacks Cloud SQL Client or its database user is not a `cma_app` member: both are set for the service since 5 October, so the job inherits them; check `gcloud run jobs describe … --format='value(spec.template.spec.template.spec.serviceAccountName)'`.

The end-to-end proof, with the web proxy from 2.2 still up (or started again) and the dev Auth Proxy on 5433:

**Terminal**
```bash
cd ~/cma && mkdir -p records/scheduler-2026-10-09 && rm -f records/scheduler-2026-10-09/README.md && cd web
export PGCONN="host=127.0.0.1 port=5433 dbname=cma user=$(gcloud config get-value account) sslmode=disable"
export CMA_DB_INSTANCE=p4a-cma-dev:europe-west4:cma-dev-pg CMA_DB_USER="$(gcloud config get-value account)" CMA_DB_NAME=cma CMA_DB_SET_ROLE=cma_app
node verify/scheduler.mjs 2>&1 | tee ../records/scheduler-2026-10-09/scheduler-verify.txt | tail -1
node verify/scheduler.mjs --provoke 2>&1 | tee ../records/scheduler-2026-10-09/scheduler-verify-provoke.txt | tail -1
gcloud logging read 'resource.type=cloud_run_job AND resource.labels.job_name=cma-close-forgotten-workdays' --project=p4a-cma-dev --limit=5 --format='value(textPayload)' > ../records/scheduler-2026-10-09/job-execution-log.txt
```
Expected: `ALL 10 PASS`; `ALL 10 PROVOKED CHECKS FAILED, as they must`. Here the job runs under your own IAM login through the connector with `CMA_DB_SET_ROLE=cma_app` (your login holds `cma_app` without inheritance; Cloud Run's service account inherits it and never sets this). Each run adds one ended, flagged day for Agent Two on a free date 400 days back (dev data).

### 3.3 Prod: the job and the schedule

**Terminal**
```bash
cd ~/cma && docs/scheduler/deploy.sh prod $SHA
gcloud run jobs execute cma-close-forgotten-workdays --project=p4a-cma-prod --region=europe-west4 --wait
gcloud logging read 'resource.type=cloud_run_job AND resource.labels.job_name=cma-close-forgotten-workdays' --project=p4a-cma-prod --limit=5 --format='value(textPayload)' | tee -a records/scheduler-2026-10-09/prod-first-execution.txt
```
Expected: `2 tenant(s)`, a count per tenant: prod holds the team's own days, so any day never clocked out before yesterday is closed now (the Decision log: Martin's and Finn's days of 5 to 7 October were corrected by hand already; expect `closed 0 day(s)` twice unless a day was left open). From now on the schedule runs every hour.

**Browser:** Team hours as Martin: a day the scheduler closed shows Not clocked out and Needs a correction, Correct opens it with the end row shown as entered by system; confirming it (Save with a reason) clears the flag.

**Terminal**
```bash
cd ~/cma && git switch -q -c records-scheduler && git add records/scheduler-2026-10-09 && git commit -q -m "records: the scheduler in dev and prod (9 October 2026)" && git push -q -u origin records-scheduler && gh pr create --fill --base main && gh pr merge --squash --delete-branch && git switch main -q && git pull -q --ff-only
```

## 4. Slice 4: README sixteenth pass, runbook and notes

**Terminal**
```bash
apply_night g-04-readme ~/g-04-readme.patch
git rebase -q main && git log --oneline -2 && tail -c 400 README.md
git push -q -u origin g-04-readme
gh pr create --title "README sixteenth pass (the night build of 8 to 9 October 2026)" --body "Migration 0005a, the configuration screens, the scheduler, the night's defaults in the Decision log; the morning runbook and the night notes under docs/night-2026-10-09." --base main --head g-04-readme
gh pr merge --squash --delete-branch
git switch main -q && git pull -q --ff-only && git log --oneline -1
```
Expected: `README.md` ends with `… (sixteenth pass, the second night build) …`. The README-only merge builds nothing (`web/**` untouched).

## 5. After the morning

- The scheduler's grace per tenant is on the Exports page; 120 minutes until Arno says otherwise.
- The retired `verify_0005a` status and `verify-0005a` link in dev, and the verifier's days 400 days back, are dev data.
- Record the dates you actually ran under `records/`; nothing is backdated.
