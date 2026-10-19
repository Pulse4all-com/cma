# CMA runbook

How to work on the CMA alone, from Martin's own Linux terminal: the Linux environment of his
Chromebook (Debian trixie, user `datadriversdev`) or his Linux machine, with the repository in `~/cma`.
Every shell command runs there (**Terminal**); the console is for Cloud SQL Studio and looking around.
A query that returns customer rows (names, emails, phones, addresses, order contents) runs in Cloud SQL
Studio only, never through the Auth Proxy in the terminal (README, Where a command runs).
README.md explains *why*; this file is *how*. Commands carry `--project` themselves, so it does not
matter which project gcloud is set to. This way of working dates from 16 October 2026 (README, Decision log).

## Setup (once per machine)

The toolset of README (Working on the code), in place on Martin's Chromebook since 16 October 2026.
On a new machine, one step at a time:

1. **Browser** (ChromeOS): Settings → About ChromeOS → Developers → Linux development environment, set it
   up with the user name `datadriversdev`. Expected: the Terminal app opens `datadriversdev@penguin:~$`.
   On the Linux machine this step falls away.

2. **Terminal**: the gcloud CLI from Google's apt repository.

   ```bash
   sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates gnupg curl
   curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
   echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list
   sudo apt-get update && sudo apt-get install -y google-cloud-cli && gcloud --version | head -1
   ```

   Expected: `Google Cloud SDK <version>`.

3. **Terminal**: log in and set the default project (dev, so a command that forgets `--project` lands in dev).

   ```bash
   gcloud auth login
   gcloud config set project p4a-cma-dev
   gcloud config list --format="value(core.account,core.project)"
   ```

   Sign in as `martin@pulse4all.com` in the tab it opens. Expected last line: `martin@pulse4all.com`
   and `p4a-cma-dev`. Once Application Default Credentials exist (step 4, or when you repeat this step
   later), `gcloud config set project` warns that the active project does not match the quota project
   in the ADC file (`p4a-cma-prod`, step 4): expected and harmless.

4. **Terminal**: Application Default Credentials, which `cloud-sql-proxy --auto-iam-authn` signs in with.

   ```bash
   gcloud auth application-default login
   gcloud auth application-default set-quota-project p4a-cma-prod
   ```

   Sign in as `martin@pulse4all.com` again. Expected as the last lines: `Credentials saved to file:
   [/home/datadriversdev/.config/gcloud/application_default_credentials.json]` and
   `Quota project "p4a-cma-prod" was added to ADC …`.

5. **Terminal**: the rest of the toolset. Node 22 from NodeSource's apt repository (source
   `/etc/apt/sources.list.d/nodesource.sources`):

   ```bash
   curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt-get install -y nodejs
   ```

   The GitHub CLI (`gh`) from GitHub's apt repository (source `/etc/apt/sources.list.d/github-cli.list`):
   follow the apt instructions at https://github.com/cli/cli/blob/trunk/docs/install_linux.md.
   The PostgreSQL client from PGDG (source `/etc/apt/sources.list.d/pgdg.list`): follow the apt
   instructions at https://www.postgresql.org/download/linux/debian/ and install the package
   `postgresql-client`. `cloud-sql-proxy` v2 and the HubSpot CLI `hs`: install source to be confirmed
   by Martin; the check below only. Then check all five:

   ```bash
   node -v; gh --version | head -1; psql --version; cloud-sql-proxy --version; hs accounts list
   ```

   Expected: `v22.x` (as the Docker image), `gh version <version>`, `psql (PostgreSQL) <version>`,
   `cloud-sql-proxy version 2.x`, and one HubSpot account, the test account `149511908`. The production
   portal is never added to `hs` on this device.

6. **Terminal**: GitHub as Pulse4all-DEV, also for `git`.

   ```bash
   gh auth login --hostname github.com --git-protocol https --web
   gh auth setup-git
   gh auth status 2>&1 | head -3
   ```

   Copy the one-time code it prints, press Enter, and enter the code in the Chrome tab
   (https://github.com/login/device), signed in as Pulse4all-DEV. Expected: `Logged in to github.com
   account Pulse4all-DEV (/home/datadriversdev/.config/gh/hosts.yml)`. The ChromeOS Linux environment
   has no keyring, so the token sits in that file in plain text (README, Access rules, Credentials on the
   local terminal).

   Then the identity `git` writes into every commit, the same as the GitHub account:

   ```bash
   git config --global user.name "Pulse4all-DEV" && git config --global user.email "martin@pulse4all.com"
   git config --global --get user.name; git config --global --get user.email
   ```

   Expected: `Pulse4all-DEV` and `martin@pulse4all.com`.

7. **Terminal**: the repository.

   ```bash
   gh repo clone Pulse4all-com/cma ~/cma && cd ~/cma && git log --oneline -1
   ```

   Expected: the latest commit on `main`.

8. **Terminal**: the helpers `cma_db` (starts the Auth Proxy once and sets `PGCONN`) and `run_migration`
   (a migration and its verify, normal and provoked, into `records/`) in `~/.cma_helpers.sh`, sourced
   from `~/.bashrc`, so every new terminal tab has them. They are the Helpers block of the morning
   runbooks (since `docs/night-2026-10-16/MORNING_RUNBOOK.md`); a runbook's block then needs no pasting,
   unless it differs from the file.

   ```bash
   cat > ~/.cma_helpers.sh <<'EOF'
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
   EOF
   grep -q 'cma_helpers.sh' ~/.bashrc || echo '[ -f ~/.cma_helpers.sh ] && . ~/.cma_helpers.sh' >> ~/.bashrc
   bash -ic 'type -t cma_db run_migration'
   ```

   Expected: `function` twice. A tab opened before this step sources the file with `. ~/.cma_helpers.sh`.

   `cma_db: command not found` in a new terminal window: `. ~/.cma_helpers.sh` gets that window going.
   The usual cause is a `~/.bash_profile`: a login shell that finds it skips `~/.profile`, and with it
   the line there that sources `~/.bashrc`. The fix is one line in `~/.bash_profile`,
   `[ -f ~/.bashrc ] && . ~/.bashrc`; every window opened after it has the helpers.

   The data map's schema snapshot (`tools/datamap/schema.sql`) runs with `psql -X -qAt`: `-X` skips
   `~/.psqlrc`, `-q` keeps the `SET` of its `set role cma_owner` out of the output, `-At` prints the one
   line of JSON bare, so `docs/datamap/schema.json` holds that line alone:

   ```bash
   cd ~/cma && cma_db dev && psql "$PGCONN" -X -qAt -v ON_ERROR_STOP=1 -f tools/datamap/schema.sql > docs/datamap/schema.json && head -c 60 docs/datamap/schema.json; echo
   ```

   Expected: `connected to cma as martin@pulse4all.com`, then `{"generated_at" : "…`. Run it only on a
   branch whose migration has run in dev (CLAUDE.md, Database); on `main` it is a check, and
   `git checkout docs/datamap/schema.json` puts the file back.

9. **Terminal**: the gcloud component behind `gcloud run services proxy` (section 4, and the runbooks'
   service proxy on port 8080), from the apt repository of step 2. A gcloud installed through apt cannot
   install components itself, so without this package the proxy command stops at the missing
   `cloud-run-proxy` component.

   ```bash
   sudo apt-get install -y google-cloud-cli-cloud-run-proxy
   ```

   Expected: `Setting up google-cloud-cli-cloud-run-proxy …`, or `… is already the newest version` where
   it is installed.

10. **Terminal**: the browser the Playwright verifiers launch (`theme`, `layout`, `hints`; section 5),
    in `web/` after its `npm ci`. Rerun it after every Playwright update (a `web/package-lock.json` that
    moves `playwright`): each Playwright version expects its own browser build, and the verifiers stop
    with `Executable doesn't exist` until it is there.

    ```bash
    cd ~/cma/web && npm ci --no-audit --no-fund 2>&1 | tail -1 && npx playwright install chromium; ls ~/.cache/ms-playwright; cd ~/cma
    ```

    Expected: the download lines, then among the folders `chromium-<build>` and
    `chromium_headless_shell-<build>` (build 1243 for Playwright 1.63, the version `web/package-lock.json`
    holds on 17 October 2026; `records/b17d-prod-2026-10-17`).

## 0. Start of every session

```bash
cd ~/cma && git switch main -q && git pull -q && git log --oneline -3
```

The logins stay until they expire or are revoked. If gcloud asks you to reauthenticate, repeat setup
step 3; if `cloud-sql-proxy` fails on its credentials, step 4; if `gh` says you are not logged in, step 6.

## 1. Make a change (code, SQL, docs)

```bash
cd ~/cma && git switch -c <short-branch-name>
# edit in any editor of the Linux environment, or download a zip into the Linux files folder (~) and:
#   unzip -o ~/<file>.zip -d ~/cma
cd ~/cma/web && npm ci --no-audit --no-fund 2>&1 | tail -1     # only when package.json changed
npm run build 2>&1 | tail -15; echo "build exit: ${PIPESTATUS[0]}"   # must be 0
```

`npm run build` uses the repository's own TypeScript settings, exactly like Cloud Build. Red here means
red in Cloud Build: fix before committing.

## 2. Commit, pull request, merge

```bash
cd ~/cma && git add -A && git status --short          # check: only what you meant to change
git commit -m "<what and why, one line>" && git push -u origin HEAD
gh pr create --fill && gh pr view --web=false
gh pr merge --squash --delete-branch && git log --oneline -1
```

A merge to `main` that touches `web/**` or `cloudbuild.yaml` builds and deploys **prod** automatically.
README, `db/` and `records/` changes do not build.

## 2a. A pull request from Claude Code

Claude Code on the web (claude.ai/code) works on a branch and opens a pull request; it never merges.
It has already run the build, typecheck, lint and the pure verifiers; you run the rest and merge.

```bash
cd ~/cma && gh pr checkout <number>
cd ~/cma/web && npm ci --no-audit --no-fund 2>&1 | tail -1     # only when package.json changed
npm run build 2>&1 | tail -15; echo "build exit: ${PIPESTATUS[0]}"   # must be 0
```

When `web/` or `db/` changed, run the verifiers that need a server or a database (section 5: `api`,
`theme`, `layout`, `hints`, `iap-token`, `scheduler`, `round-trips`, `refresh-follow-up`) and every `db/` script the pull request adds, as in section 7.
Then merge:

```bash
gh pr merge <number> --squash --delete-branch && git log --oneline -1
```

A merge to `main` that touches `web/**` or `cloudbuild.yaml` builds and deploys **prod** automatically.

## 3. Watch the prod build

```bash
gcloud builds list --project=p4a-cma-prod --region=europe-west4 --limit=3 \
  --format="table(status,substitutions.SHORT_SHA,createTime.date('%H:%M'))"
```

QUEUED → WORKING → SUCCESS takes 2 to 4 minutes. The build itself appears 2 to 4 minutes after the
merge (3.5 minutes on 14 October 2026): look again at 4 minutes before you start the trigger by hand
(README, Release flow), because a manual run next to a late automatic one deploys the same image twice
(harmless). On FAILURE, read the cause:

```bash
id=$(gcloud builds list --project=p4a-cma-prod --region=europe-west4 --limit=1 --format="value(id)")
gcloud builds log "$id" --project=p4a-cma-prod --region=europe-west4 | grep -B2 -A8 -iE "error|failed" | head -40
```

A failed build deploys nothing; prod keeps the previous version.

## 4. Try a new image in dev first

Dev runs the image prod's build made, by its short SHA:

```bash
sha=<short sha from step 3>
gcloud run services update cma-web --project=p4a-cma-dev --region=europe-west4 \
  --image=europe-west4-docker.pkg.dev/p4a-cma-prod/cma/web:$sha 2>&1 | tail -1
pkill -f "run services proxy"; gcloud run services proxy cma-web --project=p4a-cma-dev \
  --region=europe-west4 --port=8080 >/tmp/proxy.log 2>&1 & sleep 6
curl -s localhost:8080/api/health; echo                         # version = $sha, auth mock, data api
```

Look at it as a test user: `curl -s -H "x-cma-mock-subject: agent-two" localhost:8080/api/v1/me`, or in
Chrome at http://localhost:8080 (ChromeOS forwards the Linux environment's localhost) with
`/?as=supervisor` once to switch user.
Test users: `agent-two`, `supervisor`, `manager`, `admin`, `analyst` (one tenant each; the analyst has no clock; `admin` since the night build of 8 October 2026), `agent-one` (two tenants: refused on purpose).

## 5. Verifiers

Against dev, through the proxy from step 4:

```bash
cd ~/cma/web && node verify/api.mjs; echo "exit $?"              # ALL n PASS: 271 in dev since addition 0008p (records/audit-2026-10-18), six notes for checks dev lacks an identity or a connection for
node verify/api.mjs --provoke; echo "exit $?"                     # ALL n PROVOKED CHECKS FAILED, exit 0
```

The verifier clocks Agent Two in through the start route (a visit opens nothing since increment e) and
closes Agent Two's open past days itself (as the supervisor); no fixture runs first.
Keep outputs as evidence:
`node verify/api.mjs | tee ../records/<what>-dev-<date>/verify-api.txt`.

`verify:round-trips` against dev (**Terminal**): the database cost of every page and polled route per test user, 46 requests,
against the budgets in `web/verify/round-trips.json`. The app reports that cost only with `CMA_DB_TRACE=1` and mock sign-in
(never in iap mode), so the variable is set on dev's `cma-web` for the run and removed right after it; each update makes a new
revision and keeps the image and the other variables. Dev must run an image with the trace (the speed fixes of the IT audit of
17 October 2026 or later) and be at `78` (0008r) for the System health row:

```bash
gcloud run services update cma-web --project=p4a-cma-dev --region=europe-west4 \
  --update-env-vars=CMA_DB_TRACE=1 2>&1 | tail -1
pkill -f "run services proxy"; gcloud run services proxy cma-web --project=p4a-cma-dev \
  --region=europe-west4 --port=8080 >/tmp/proxy.log 2>&1 & sleep 6
cd ~/cma/web && BASE=http://localhost:8080 node verify/round-trips.mjs; echo "exit $?"   # round-trips: PASS (46 requests ...), exit 0
BASE=http://localhost:8080 node verify/round-trips.mjs --provoke; echo "exit $?"         # round-trips: FAIL (92 problems), exit 1
gcloud run services update cma-web --project=p4a-cma-dev --region=europe-west4 \
  --remove-env-vars=CMA_DB_TRACE 2>&1 | tail -1
curl -s -D - -o /dev/null -H "x-cma-mock-subject: agent-two" localhost:8080/api/v1/me | grep -ci x-cma-db   # 0: off again
```

A FAIL names the page, the test user and the count over its budget. Dev's data differs from the seed in volume, not in the
number of reads per page; the documents route answers 404 while the image carries no documents, which the budget accepts.

`verify:scheduler` against dev (inside 07:00-22:00 Amsterdam): it writes a test day through `PGCONN` and runs the
job's code locally, which reads `CMA_DB_*`; both must point at dev:

```bash
cma_db dev
export CMA_DB_HOST=127.0.0.1 CMA_DB_PORT=5433 CMA_DB_NAME=cma CMA_DB_USER=martin@pulse4all.com CMA_DB_SET_ROLE=cma_app
node verify/scheduler.mjs; echo "exit $?"     # ALL 10 PASS
```

It refuses a database without the dev seed (exit 2). Without `CMA_DB_*` the job step exits 1 and every close check fails.

`verify:refresh-follow-up` against dev (addition 0008s): the same exports, then `node verify/refresh-follow-up.mjs`
(`ALL 10 PASS`). Once the job is deployed in dev, pause its schedule for the run and resume it after
(`gcloud scheduler jobs pause|resume cma-refresh-follow-up-minutely --project=p4a-cma-dev --location=europe-west4`),
so a scheduled refresh does not take the lock the verifier's second session holds (section 7a, step 3).

The other verifiers (`copy`, `corrections`, `csv`, `dashboard`, `live`, `team`, `roster`, `configuration`, `messages`, `import`, `datamap`, `reports`, `signed-out`, `invitations`, `preview`, `follow-up`, `health`, `boundaries`, `jobs`, `theme`, `layout`, `hints`, `iap-token`) run locally, `theme`, `layout` and `hints` against a local mock server on port 8080 and `iap-token` against a local server in iap mode that reads the script's test key set; see the header
of each script in `web/verify/` for its start command. Since B9a.1 `layout` clocks agent-two in, so it runs inside the mock's
workday window (07:00-22:00), as `verify:api` and `verify:scheduler` do.

## 6. Logs

```bash
gcloud run services logs read cma-web --project=p4a-cma-prod --region=europe-west4 --limit=50
gcloud run services logs read cma-web --project=p4a-cma-dev  --region=europe-west4 --limit=50
```

App messages start with `[cma-data]`, `[cma-db]` or `[cma-api]`. A 503 `database_unavailable` means the
service could not reach Cloud SQL; check the instance is running and the service account still has
Cloud SQL Client and Cloud SQL Instance User.

The request lines (**Terminal**): one JSON line per page request, RSC request and API request, with the route
pattern (`/api/v1/configuration/documents/[name]`, never the path; `null` when Next names none), the status,
the total and database milliseconds, and the transactions (`tx`) and statements (`rt`) the request cost.
Severity WARNING above 800 ms, ERROR on a 5xx. A request `proxy.ts` refuses itself (401) writes none.

```bash
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="cma-web" AND jsonPayload.message="request"' \
  --project=p4a-cma-prod --freshness=1h --limit=50 \
  --format='table(timestamp, severity, jsonPayload.route, jsonPayload.status, jsonPayload.rsc, jsonPayload.totalMs, jsonPayload.dbMs, jsonPayload.tx, jsonPayload.rt)'
```

Expected: a row for every page, RSC refresh and API call of the last hour; a Live poll reads
`/live/board 200 True <totalMs> <dbMs> <tx> <rt>`. Add `AND severity>=WARNING` to the filter for the slow ones only.

## 7. Database work (Cloud SQL Studio)

Dev: `https://console.cloud.google.com/sql/instances/cma-dev-pg/studio?project=p4a-cma-dev`
Prod: `https://console.cloud.google.com/sql/instances/cma-prod-pg/studio?project=p4a-cma-prod`
Database `cma`, IAM database authentication. You log in as yourself (reader by default):

- read anything: start with `set role cma_owner;`, end with `reset role;`
- see exactly what the app sees: `set role cma_app;` plus `select set_config('app.tenant_id', '<uuid>', false);`
- a new migration: the next free number in `db/`, rerunnable, forward-only, with its verify script; run in
  dev, verify, records, then prod (README, Release flow)

## 7a. Addition 0008s: the follow-up snapshot (18 October 2026)

Reports → Follow-up, the Live board's card and Welcome read a snapshot computed once a minute per tenant by
the job `cma-refresh-follow-up` (README, Data model: follow-up snapshot; The follow-up refresh). The job's
script ships in the web image, so it is deployed with the image of the merge that brings it. The order:
`80` in dev with its verifies, the data map and the job verifier from the branch, then `80` in prod just
before the merge, the merge, then the job in dev and prod. The web on `main` runs unchanged on the migrated
database (the same shapes; it ignores the new `computed_at`), but nothing refreshes the snapshot until the
job runs: keep the gap between the prod migration and the job's first run to the build's few minutes.

1. **Terminal** (dev, on the pull request's branch): the migration, its verify, provoked, and `73` and `79` again.

   ```bash
   cd ~/cma && git fetch origin && git checkout <branch> && git pull
   run_migration dev 80_follow_up_snapshot.sql 81_verify_follow_up_snapshot.sql 0008s-dev-2026-10-18 73_verify_follow_up.sql 79_verify_system_health.sql
   ```

   Expected: `INSERT 0 1`, `COMMIT`, `RESET` (a rerun says `INSERT 0 0`); the verdict `PASS | 19 PASS, 0 FAIL`;
   `provoked FAIL lines: 20` and `PROVOKED, NOT A PASS | 0 PASS, 19 FAIL`; `73_verify_follow_up.sql: 22 PASS rows`
   (21 checks and the verdict) and `79_verify_system_health.sql: 14 PASS rows` (13 and the verdict).

2. **Terminal** (dev, the same branch): the data map's schema snapshot and the page, committed to the branch.

   ```bash
   cd ~/cma && cma_db dev && psql "$PGCONN" -X -qAt -v ON_ERROR_STOP=1 -f tools/datamap/schema.sql > docs/datamap/schema.json && head -c 60 docs/datamap/schema.json; echo
   node tools/datamap/build.mjs && cd web && npm run verify:datamap; cd ~/cma
   git add docs/datamap/schema.json docs/datamap/index.html && git commit -m "Data map: schema snapshot from dev after 0008s" && git push
   ```

   Expected: `{"generated_at" : "…`, `datamap: wrote docs/datamap/index.html (… tables, … views)`, then
   `datamap: PASS (… tables, … views, all described; index.html current)`.

3. **Terminal** (dev, the same branch): the job, run from the branch against dev, proves the refresh and fills
   dev's snapshots (the job is not deployed in dev yet, so nothing else refreshes at the same time).

   ```bash
   cma_db dev
   export CMA_DB_HOST=127.0.0.1 CMA_DB_PORT=5433 CMA_DB_NAME=cma CMA_DB_USER=martin@pulse4all.com CMA_DB_SET_ROLE=cma_app
   cd ~/cma/web && node verify/refresh-follow-up.mjs; echo "exit $?"
   node verify/refresh-follow-up.mjs --provoke; echo "exit $?"
   ```

   Expected: `ALL 10 PASS`, exit 0; then `ALL 10 PROVOKED CHECKS FAILED, as they must`, exit 0. It refuses a
   database without the dev seed (exit 2).

4. **Studio** (cma-dev-pg): every tenant's snapshot, its age and size (ids, times and counts only).

   ```sql
   set role cma_owner;
   select t.slug, s.computed_at, s.duration_ms, (select count(*) from cma.follow_up_item i where i.tenant_id = s.tenant_id) as items
   from cma.follow_up_snapshot s join cma.tenant t on t.id = s.tenant_id order by 1;
   reset role;
   ```

   Expected: one row per tenant with a scheduler user, `computed_at` from step 3, `duration_ms` in the
   hundreds or low thousands.

5. **Terminal** (prod, just before the merge): the migration alone; `81`, `73` and `79` are dev only.

   ```bash
   cd ~/cma && mkdir -p records/0008s-prod-2026-10-18 && cma_db prod
   psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/80_follow_up_snapshot.sql > records/0008s-prod-2026-10-18/80.txt 2>&1; tail -3 records/0008s-prod-2026-10-18/80.txt
   ```

   Expected: `INSERT 0 1`, `COMMIT`, `RESET`.

6. **Browser**: merge the pull request (squash); the build deploys the web to prod (section 3). Note its short
   SHA.

7. **Terminal**: the job and its schedule, dev first, with the merge's image; then its first run in each.

   ```bash
   cd ~/cma && bash docs/scheduler/deploy-follow-up.sh dev <short sha>
   gcloud run jobs execute cma-refresh-follow-up --project=p4a-cma-dev --region=europe-west4 --wait 2>&1 | tail -2
   bash docs/scheduler/deploy-follow-up.sh prod <short sha>
   gcloud run jobs execute cma-refresh-follow-up --project=p4a-cma-prod --region=europe-west4 --wait 2>&1 | tail -2
   ```

   Expected per environment: `job cma-refresh-follow-up on …:<short sha>, schedule cma-refresh-follow-up-minutely
   every minute (UTC) in p4a-cma-…`, then gcloud's line that the execution has successfully completed (a
   scheduled run in the same minute may make it skip a tenant: harmless).

8. **Terminal** (prod): the job's lines, one per tenant: the tenant's id, rows and `duration_ms`.

   ```bash
   gcloud logging read 'resource.type=cloud_run_job AND resource.labels.job_name=cma-refresh-follow-up AND jsonPayload.message="refresh-follow-up"' \
     --project=p4a-cma-prod --freshness=10m --limit=10 \
     --format='table(timestamp, severity, jsonPayload.tenant_id, jsonPayload.rows, jsonPayload.duration_ms, jsonPayload.refreshed)'
   ```

   Expected: INFO rows, `refreshed` True, one per tenant per minute; a WARNING with `refreshed` False means a
   run overlapped the next one and skipped that tenant (harmless once; every minute means the refresh takes
   longer than a minute).

9. **Browser** (prod): Configuration → System health lists Refresh follow-up with a run in the last minute;
   Reports → Follow-up shows "Updated now" or "Updated … seconds ago" under the title and "Showing n of total"
   under each list; the request lines (section 6) show `/reports/follow-up` well under a second.

To pause the refresh (the figures then stand still and "Updated …" turns grey after three minutes):
`gcloud scheduler jobs pause cma-refresh-follow-up-minutely --project=p4a-cma-prod --location=europe-west4`
(**Terminal**); `resume` in place of `pause` starts it again.

## 8. Add a person to prod

Since the night build of 8 October 2026 this is a screen, not a script (`db/people_add_prod.template.sql` is retired).

1. The person runs, in **their own** terminal with the gcloud CLI signed in as themselves (Cloud Shell also
   works for them, but its weekly quota applies):
   `curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" https://www.googleapis.com/oauth2/v3/userinfo`
   and sends you the `sub` (digits only). The id travels once; it is never committed anywhere.
2. In the Workspace as an admin (or a manager, for a non-managing role): Team → People → Add a person (A):
   name, email, employer, role, sign-in provider `google` (prefilled behind IAP), the digits as the account id,
   the zone empty unless the person needs their own. Save. The person appears in the table at once.
3. They also need to pass the IAP gate: during the build only members of the `cma@pulse4all.com` group; an agent
   gets an IAP-only grant on `cma-web-backend` instead (README, Open decisions).
4. Teams and skills: Edit on their row. The roster shows them on their teams' weeks from then on.

## 9. Change prod configuration

The service's environment comes only from `cloudbuild.yaml` plus the trigger's substitutions; never edit
env vars on the Cloud Run service by hand (the next build undoes it).

```bash
gcloud beta builds triggers export cma-web-main --project=p4a-cma-prod --region=europe-west4 --destination=/tmp/trigger.yaml
cp /tmp/trigger.yaml /tmp/trigger.before.yaml
# edit the substitutions in /tmp/trigger.yaml (any editor, or python), then check:
diff /tmp/trigger.before.yaml /tmp/trigger.yaml
gcloud beta builds triggers import --project=p4a-cma-prod --region=europe-west4 --source=/tmp/trigger.yaml
gcloud builds triggers run cma-web-main --project=p4a-cma-prod --region=europe-west4 --branch=main
```

(`gcloud builds triggers update github` refuses this 2nd-gen trigger with INVALID_ARGUMENT.)

## 10. Something is wrong in prod: roll back

Fastest: send all traffic to the previous revision (seconds, no build):

```bash
gcloud run revisions list --service=cma-web --project=p4a-cma-prod --region=europe-west4 --limit=5 \
  --format="table(metadata.name,metadata.creationTimestamp.date('%d %b %H:%M'),status.conditions[0].status)"
gcloud run services update-traffic cma-web --project=p4a-cma-prod --region=europe-west4 --to-revisions=<previous revision>=100
```

Then fix forward with a new commit. The next build sends traffic to the new revision again
(`gcloud run services update-traffic … --to-latest` does that by hand).

Back to mock data in prod (screens keep working, nothing is saved): set `_DATA_MODE` to `mock` with
section 9 and run the trigger. Data already in Postgres stays where it is.

## 10a. Rotating the postgres password

In **Terminal**, with `INSTANCE` (`cma-dev-pg` or `cma-prod-pg`), `PROJECT` and `ENV` (`dev` or `prod`) replaced:

```bash
NEWPW="$(openssl rand -base64 48 | tr -d '\n/+=' | cut -c1-36)-Ka7" && gcloud sql users set-password postgres --instance=INSTANCE --project=PROJECT --password="$NEWPW" && printf '%s' "$NEWPW" | gcloud secrets versions add cma-ENV-postgres-password --project=PROJECT --data-file=- ; unset NEWPW
```

Then disable the older versions of the secret (`gcloud secrets versions list cma-ENV-postgres-password --project=PROJECT`, then `gcloud secrets versions disable VERSION --secret=cma-ENV-postgres-password --project=PROJECT` for each one except the newest).

- Cloud SQL's password policy needs a lowercase letter, an uppercase letter, a digit and a non-alphanumeric character; the `-Ka7` suffix guarantees all four.
- The commands are chained with `&&` so the secret is only updated if `set-password` succeeds; `unset` runs either way.
- After `gcloud secrets versions access`, always run `clear`, and never share the terminal output (a screenshot counts).
- Rotated: `cma-prod-pg` on 9 October 2026 (secret version 4), after the value appeared in a screenshot.

## 11. Before you finish

- `git status` in `~/cma` is clean, `main` is up to date, open branches are merged or deleted
- records for anything verified are in `records/<what>-<env>-<date>`
- a decision or a change in how things work goes into README.md (Decision log, Open decisions, the
  section concerned, the "Last updated" line)
