# CMA runbook

How to work on the CMA alone, from a Chromebook with only a browser. Everything runs in Cloud Shell
(`https://shell.cloud.google.com`); the console is for Cloud SQL Studio and looking around.
README.md explains *why*; this file is *how*. Commands carry `--project` themselves, so it does not
matter which project Cloud Shell is set to.

## 0. Start of every session

Cloud Shell keeps your home folder (`~/cma`, the GitHub login) but resets the machine after a while,
so Node 22 needs to be switched on again:

```bash
command -v nvm >/dev/null || source /usr/local/nvm/nvm.sh
nvm install 22 >/dev/null && nvm use 22 >/dev/null && node -v      # v22.x, same as the Docker image
cd ~/cma && git switch main -q && git pull -q && git log --oneline -3
```

If `gh` ever says you are not logged in: `gh auth login --hostname github.com --git-protocol https --web`
(code at https://github.com/login/device as Pulse4all-DEV, then Enter in Cloud Shell; never Ctrl+C).

## 1. Make a change (code, SQL, docs)

```bash
cd ~/cma && git switch -c <short-branch-name>
# edit with Cloud Shell's editor ("Open editor"), or upload a zip (⋮ → Upload) and:
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
nvm use 22
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

QUEUED → WORKING → SUCCESS takes 2 to 4 minutes. On FAILURE, read the cause:

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
the browser through Cloud Shell's **Web preview** (port 8080) with `/?as=supervisor` once to switch user.
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

The other verifiers (`copy`, `corrections`, `csv`, `dashboard`, `live`, `team`, `roster`, `theme`, `layout`, `iap-token`) run locally, the last two against a local server; see the header
of each script in `web/verify/` for its start command.

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

1. The person runs in **their own** Cloud Shell:
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
# edit the substitutions in /tmp/trigger.yaml (Cloud Shell editor or python), then check:
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

## 11. Before you finish

- `git status` in `~/cma` is clean, `main` is up to date, open branches are merged or deleted
- records for anything verified are in `records/<what>-<env>-<date>`
- a decision or a change in how things work goes into README.md (Decision log, Open decisions, the
  section concerned, the "Last updated" line)
