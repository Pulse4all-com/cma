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
   and `p4a-cma-dev`.

4. **Terminal**: Application Default Credentials, which `cloud-sql-proxy --auto-iam-authn` signs in with.

   ```bash
   gcloud auth application-default login
   gcloud auth application-default set-quota-project p4a-cma-prod
   ```

   Sign in as `martin@pulse4all.com` again. Expected as the last lines: `Credentials saved to file:
   [/home/datadriversdev/.config/gcloud/application_default_credentials.json]` and
   `Quota project "p4a-cma-prod" was added to ADC …`.

5. **Terminal**: GitHub as Pulse4all-DEV, also for `git`.

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

6. **Terminal**: the repository.

   ```bash
   gh repo clone Pulse4all-com/cma ~/cma && cd ~/cma && git log --oneline -1
   ```

   Expected: the latest commit on `main`.

7. **Terminal**: the rest of the toolset (Node 22, `psql` from PGDG, `cloud-sql-proxy` v2, `hs`).

   ```bash
   node -v; psql --version; cloud-sql-proxy --version; hs accounts list
   ```

   Expected: `v22.x` (as the Docker image), `psql (PostgreSQL) <version>`, `cloud-sql-proxy version 2.x`,
   and one HubSpot account, the test account `149511908`. The production portal is never added to `hs`
   on this device.

## 0. Start of every session

```bash
cd ~/cma && git switch main -q && git pull -q && git log --oneline -3
```

The logins stay until they expire or are revoked. If gcloud asks you to reauthenticate, repeat setup
step 3; if `cloud-sql-proxy` fails on its credentials, step 4; if `gh` says you are not logged in, step 5.

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
`theme`, `layout`, `iap-token`, `scheduler`) and every `db/` script the pull request adds, as in section 7.
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
cd ~/cma/web && node verify/api.mjs; echo "exit $?"              # ALL 111 PASS (since the night build of 8 October 2026)
node verify/api.mjs --provoke; echo "exit $?"                     # ALL 111 PROVOKED CHECKS FAILED, exit 0
```

The verifier clocks Agent Two in through the start route (a visit opens nothing since increment e) and
closes Agent Two's open past days itself (as the supervisor); no fixture runs first.
Keep outputs as evidence:
`node verify/api.mjs | tee ../records/<what>-dev-<date>/verify-api.txt`.

`verify:scheduler` against dev (inside 07:00-22:00 Amsterdam): it writes a test day through `PGCONN` and runs the
job's code locally, which reads `CMA_DB_*`; both must point at dev:

```bash
cma_db dev
export CMA_DB_HOST=127.0.0.1 CMA_DB_PORT=5433 CMA_DB_NAME=cma CMA_DB_USER=martin@pulse4all.com CMA_DB_SET_ROLE=cma_app
node verify/scheduler.mjs; echo "exit $?"     # ALL 10 PASS
```

It refuses a database without the dev seed (exit 2). Without `CMA_DB_*` the job step exits 1 and every close check fails.

The other verifiers (`copy`, `corrections`, `csv`, `dashboard`, `live`, `team`, `roster`, `import`, `theme`, `layout`, `iap-token`) run locally, the last two against a local server; see the header
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

## 7. Database work (Cloud SQL Studio)

Dev: `https://console.cloud.google.com/sql/instances/cma-dev-pg/studio?project=p4a-cma-dev`
Prod: `https://console.cloud.google.com/sql/instances/cma-prod-pg/studio?project=p4a-cma-prod`
Database `cma`, IAM database authentication. You log in as yourself (reader by default):

- read anything: start with `set role cma_owner;`, end with `reset role;`
- see exactly what the app sees: `set role cma_app;` plus `select set_config('app.tenant_id', '<uuid>', false);`
- a new migration: the next free number in `db/`, rerunnable, forward-only, with its verify script; run in
  dev, verify, records, then prod (README, Release flow)

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
