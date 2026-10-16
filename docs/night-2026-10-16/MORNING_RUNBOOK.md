# Morning runbook, 16 October 2026: N16-B (0008n tasks, 0008o follow-up)

Read `NIGHT_NOTES.md` first (ten minutes: what was built, the one change from the brief's letter, the questions). N16-A (PR #141) is merged as 23fe766, and `main` is merged into this branch twice: in the morning at 23fe766 (N16-A, #140, #143) and in the afternoon at f516aee (#146: `deploy.sh prod` refuses a service deploy without `--front`; #147: your own Linux terminal for CMA work; #144: the B17b records), so this runbook is N16-B alone. Labels: **Browser**, **Terminal** (Martin's own Linux terminal, Chromebook Linux or his Linux machine, in `~/cma` unless stated; a step against prod, `p4a-cma-prod` or `cma-prod-pg`, from the Chromebook only, and so is a build, which runs in `p4a-cma-prod`), **Studio** (the instance named), **File** (a repository path). SQL and shell never share a block. Through the Auth Proxy the terminal runs only the data map's schema snapshot (step 4), whose output is schema; every query that reads rows runs in Studio (README, Where a command runs). Every step ends with what you should see.

**Order matters.** Merging N16-B deploys `cma-web` to prod (trigger `cma-web-main`) and Welcome calls 0008o's functions on every load, so prod's `70` and `72` (then `02`) run **before** the merge (step 10, then 11); in dev the same, before the dev check. The ingest is deployed before the app version and the backfill in each environment (dev from this branch in step 5, prod from `main` in step 12): the task webhooks and the backfill's `--object task` need an ingest that knows tasks. The hand check on N16-B's web image (step 8) follows the merge (step 11): the branch's web image has no build of its own (step 8; README, Open decisions: a dev-only web build path, CMA-068).

**Deferred until the upload route exists (backlog CMA-067; Martin, 16 October 2026).** HubSpot project uploads go through GitHub Actions with HubSpot's official project actions, the live portal's key a GitHub environment secret limited to `main` with a required approval (README, Decision log, 16 October 2026); that is not built in this pull request. Until it exists only the app versions and their test tasks wait: step 6 in dev and the second half of `PROD_RUNBOOK.md` 11.2 in prod, each marked below. Everything else runs, in this order: steps 1 to 5, 7, the address of step 9, 10, 11, 8, the setting of step 9, 12 and 13. The task backfill (step 7, 11.3) needs only the new ingest image and the install's existing token, not the upload (step 7 says why).

**Task data before CMA-067 (accepted, Martin, 16 October 2026).** Right after the merge prod has no task rows; 11.3's backfill brings every task created or due since 1 September 2026 (`--from 2026-09-01`). Without the new app version no task webhook arrives, so from then on a change to a task appears the next morning, through the 02:30 reconcile (its 26-hour look-back), and a task deleted in HubSpot never arrives (a search lists live objects only): it stays in the CMA, and an open one keeps counting. Until CMA-067 the task figures on Follow-up, Waiting for you and Welcome are incomplete in that way (README, Open decisions: the task webhooks as a data prerequisite; Data first). No switch keeps tasks out meanwhile.

| Step | What | Elapsed |
|---|---|---|
| 1 | Review N16-B, build it in your own terminal | 25 min |
| 2 | Dev: `70`, `71` normal and provoked | 10 min |
| 3 | Dev: `72`, `02`, `73` normal and provoked; `41`, `53`, `69`, `71` again | 10 min |
| 4 | Refresh `docs/datamap/schema.json` from dev on this branch, rebuild the index | 10 min |
| 5 | The ingest in dev from this branch: service and jobs; health shows the branch's tag | 10 min |
| 6 | Deferred (CMA-067): the dev HubSpot app version; a test task reaches the ingest | 10 min |
| 7 | Dev backfill of tasks (after step 5); the counts | 10 min |
| 8 | After step 11: dev on the merge's image, a hand check of Follow-up, Welcome, the Live board, Sources, Exports | 20 min |
| 9 | The task address for `record_url_task` in dev; set it after step 11, on the merge's image | 5 min |
| 10 | Prod, before the merge: point-in-time recovery on; `70` twice, `72`, `02`, the read-only check of 11.1; records | 20 min |
| 11 | Merge N16-B; watch the `cma-web-main` build; Welcome in prod | 10 min |
| 12 | Prod ingest from `main` (service with its front, jobs); backfill of tasks (11.3); Sources and Exports settings (11.4); day one (11.5); the app version (11.2) deferred (CMA-067) | 35 min |
| 13 | README to the project, the Gem's README, the backlog | 15 min |

---

## Helpers (define in every new terminal tab)

The terminal is set up as `docs/RUNBOOK.md`, Setup (once per machine), describes: gcloud logged in as `martin@pulse4all.com`, Application Default Credentials with quota project `p4a-cma-prod` (the Auth Proxy signs in with them), Node 22 from NodeSource (installed system-wide, nothing to switch on), `psql`, `cloud-sql-proxy` v2 and `gh` as Pulse4all-DEV. A shell function lives only in the tab that defined it: paste this block in every tab that runs `cma_db` or `run_migration`. Step 4 uses `cma_db dev` (`cma_db dev|prod` starts the Auth Proxy once and sets `PGCONN`). This runbook runs `70` to `73` in Studio; `run_migration` runs a migration and its verify, normal and provoked, through the Auth Proxy into `records/` instead, and is here so the block is the same in every runbook. They are the helpers of `docs/night-2026-10-13/MORNING_RUNBOOK.md`, without their first line, which switched Node 22 on there.

**Terminal**
```bash
cd ~/cma && node -v
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
Expected: `v22.…` (from `node -v`), no other output; `type cma_db run_migration` then prints both functions.

`put_secret` (step 6 once it runs, only when HubSpot shows a new token) is the function at the top of `docs/ingest/PROD_RUNBOOK.md` (Before you start): define it in the same tab and run each `put_secret` on its own line (`hubspot/README.md`).

## 1. N16-B: review and build

**Terminal**
```bash
cd ~/cma && gh pr checkout 142 && git log --oneline -10 && cd web && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run build 2>&1 | tail -3 && npm run typecheck && npm run lint && npm run verify:copy && npm run verify:follow-up && npm run verify:configuration && npm run verify:reports; npm run verify:datamap; cd ~/cma && cd ingest && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run lint && node verify/mapping.mjs | tail -1 && node verify/deploy-script.mjs | tail -1; cd ~/cma && node hubspot/verify/render.mjs | tail -1
```
Expected: the log starts with the afternoon's commits on the runbooks, README and `verify/layout.mjs`, then the afternoon's merge of `main` (f1fc212, of f516aee, with #144, #147 and #146 under it); `copy: PASS (1601 keys, en and nl)`, `follow-up: PASS (25 checks)`, `ALL 92 PASS`, `ALL 75 PASS`; **`datamap: FAIL (10 problems)`** naming the three 0008n tables, the six 0008o views and the index (expected until step 4); `ALL 48 PASS` for the mapping, `ALL 10 PASS` for `deploy-script.mjs` (#146's guard, step 12), `ALL 33 PASS` for the render.

## 2. Dev: 0008n

**Studio (cma-dev-pg)**: `db/70_crm_tasks.sql` as one script, your own login.

Expected: `INSERT 0 1`, `COMMIT`. Run it once more: `INSERT 0 0`.

**Studio (cma-dev-pg)**: `db/71_verify_crm_tasks.sql`.

Expected: 20 rows `PASS` and the verdict row `PASS | 20 PASS, 0 FAIL`. Then with `verify.provoke` set to `'true'` in the script's first `set_config`: every row `FAIL`, the verdict `PROVOKED, NOT A PASS | 0 PASS, 20 FAIL`. Keep the outputs for `records/0008n-dev-<date>/`.

## 3. Dev: 0008o

**Studio (cma-dev-pg)**: `db/72_follow_up.sql`, then `db/02_seed_pulse4all.sql` again.

Expected: `INSERT 0 1` near the end and `COMMIT`; `02` ends without an error (its blocks print `DO`; the four follow-up settings are in place for both tenants).

**Studio (cma-dev-pg)**: `db/73_verify_follow_up.sql`, normal and provoked as in step 2.

Expected: `PASS | 21 PASS, 0 FAIL`; provoked `PROVOKED, NOT A PASS | 0 PASS, 21 FAIL`.

**Studio (cma-dev-pg)**: `41_verify_lead_metrics.sql`, `53_verify_sources_configuration.sql`, `69_verify_email_activity.sql`, `71_verify_crm_tasks.sql` again.

Expected: `41` its two tenant rows `PASS`, `53` `16 PASS, 0 FAIL`, `69` `29 PASS, 0 FAIL`, `71` `20 PASS, 0 FAIL`.

## 4. The data map

**Terminal** (on the N16-B branch, in a tab with the helpers; through the Auth Proxy to dev, `tools/datamap/schema.sql` prints schema only: every column's table, name and type, and the newest migration)
```bash
cd ~/cma && cma_db dev && psql "$PGCONN" -X -At -f tools/datamap/schema.sql > docs/datamap/schema.json && node tools/datamap/build.mjs && cd web && npm run verify:datamap; cd ~/cma && git add docs/datamap && git commit -m "Data map: schema.json from dev after 0008n and 0008o" && git push
```
Expected: `datamap: PASS (75 tables, 95 views, all described; index.html current)` (72 + 3 tables; 89 + 6 views), the commit on the branch.

## 5. The ingest in dev from this branch

Before the app version and the backfill: the task webhooks and `--object task` need an ingest that knows tasks. The script asks for a clean `ingest/`, not for `main`; the image tag is the last commit that touched `ingest/`.

**Terminal** (from the Chromebook: the image is built in `p4a-cma-prod`; on the N16-B branch)
```bash
cd ~/cma && git log -1 --format=%h -- ingest/ && bash docs/ingest/deploy.sh dev && bash docs/ingest/deploy.sh dev --jobs
```
Expected: the tag first (today `f1fc212`, the afternoon's merge of `main`, which brought `ingest/verify/deploy-script.mjs` and its line in `ingest/package.json`; the code under `ingest/src/` is the night's, tested at `8f729a7`); the first deploy builds the image once (`gcloud builds submit …`) and ends with `health: {"ok":true,"version":"f1fc212"}` (the same tag); the second deploys the jobs on that image (`no build`) with the schedules unchanged.

## 6. The dev HubSpot app (deferred until the upload route exists, backlog CMA-067)

**Deferred.** Skip this step until CMA-067's workflow exists: it uploads the app version, and its own runbook then replaces the upload below. The render, the install, the test task and the token check stay as written. Without this step no task webhook reaches dev; no other step that runs now needs it, the backfill of step 7 included.

**Terminal**
```bash
cd ~/cma && node hubspot/render.mjs dev --target-url "https://<dev ingest host>/hubspot/<dev key>" && node hubspot/verify/render.mjs | tail -1
```
Expected: `rendered dev: hubspot/build/dev`, `ALL 33 PASS`.

**The upload** runs through CMA-067's workflow, never with `hs project upload` on your own terminal, whose `hs` holds the test account only (README, Decision log, 16 October 2026). Expected, as `hubspot/README.md` step 3 says: the build and deploy of **CMA ingest dev** succeeding with both components.

**Browser:** live portal → Development → Projects → CMA ingest dev → the app → Distribution → Test installs → the row of `CMA dev`. If HubSpot offers an update, accept it (no new scope; the webhooks tab lists nine `task` subscriptions among 46). If it offers no update or reinstall for this webhooks-only change, the upload is enough.

**Browser:** in `CMA dev`, create a test task on a test contact (a title only, no body).

**Studio (cma-dev-pg)**, a few minutes later
```sql
set role cma_owner;
select object_type, kind, status, count(*) from cma.ingest_event where object_type = 'task' and recorded_at > now() - interval '15 minutes' group by 1, 2, 3 order by 1, 2, 3;
reset role;
```
Expected: at least one `task | created` row (`received`, or `processed` once the sweep ran; it runs every minute). If no task event arrives within minutes, the subscriptions did not reach the install: reinstall through Distribution → Test installs → **Add test install(s)** → tick `CMA dev`, as 15 October showed for the scopes, then create another test task. Check the token afterwards: it stays; if HubSpot shows a new one on the install's row → Show, store it with `put_secret p4a-cma-dev ingest-hubspot-dev-token` (`hubspot/README.md`).

## 7. The dev backfill of tasks

After step 5, without step 6. The backfill needs only the new ingest image (step 5 deploys it; an older image answers that the adapter does not backfill `task`) and the install's existing token: it lists the tasks with the CRM search and reads them back with their first contact, deal and ticket, with the tasks API's `crm.objects.contacts.read` and the read scopes the app already holds (`hubspot/README.md`, no extra scope); the task statuses and types fill from the rows. Until step 6, a change to a backfilled task appears the next morning and a deleted one stays (Task data before CMA-067).

The backfill takes the connection's id (a uuid), not its key, and `--from` with a date.

**Studio (cma-dev-pg)**
```sql
select c.id from cma.integration_connection c join cma.tenant t on t.id = c.tenant_id where t.slug = 'pulse4all-subscriptions' and c.adapter = 'hubspot' and c.status = 'active';
```
Expected: one uuid, the dev HubSpot connection.

**Terminal**
```bash
gcloud run jobs execute ingest-backfill --project=p4a-cma-dev --region=europe-west4 --args=--connection,<connection id>,--object,task,--from,2026-09-01 --wait
```
Expected: the job finishing with the stream `task` in its log.

**Studio (cma-dev-pg)**
```sql
set role cma_owner;
select count(*) as tasks, count(distinct owner_ref) as owners, min(source_created_at)::date as first_task from cma.crm_task;
select status_ref, count(*) from cma.crm_task group by 1 order by 1;
select type_ref, count(*) from cma.crm_task group by 1 order by 1;
select string_agg(k, ', ') as raw_keys from (select distinct jsonb_object_keys(raw) as k from cma.crm_task) x;
reset role;
```
Expected: the dev portal's tasks counted, the statuses and types it uses, and `raw_keys` without any body, subject, note or text key. Send me the three result blocks (counts and refs only) for `NIGHT_NOTES.md`'s record.

## 8. Dev on N16-B's web image: the hand check (after step 11)

The branch's web image has no build of its own. The night's command for it (`gcloud builds submit --config cloudbuild.yaml --project=p4a-cma-prod --substitutions=_DEPLOY=false .`) is not to be run, in that form or another: `cloudbuild.yaml` has no `_DEPLOY` substitution, so Cloud Build refuses the build, and every run of that file ends in its `deploy` step, which rolls `cma-web` in the project it runs in, so the same command without the substitution would deploy prod's `cma-web` with the file's defaults (`_DATA_MODE=mock`, an empty `_IAP_AUDIENCE`) instead of the trigger's. Dev runs the image prod's build made (`docs/RUNBOOK.md` section 4), so this step follows step 11, with the merge's short SHA (README, Open decisions: a dev-only web build path, CMA-068).

**Terminal** (`docs/RUNBOOK.md` section 4, after step 11's build is green; the service proxy on port 8080 reaches the web app, not the database)
```bash
sha=<the merge's short SHA from step 11>
gcloud run services update cma-web --project=p4a-cma-dev --region=europe-west4 \
  --image=europe-west4-docker.pkg.dev/p4a-cma-prod/cma/web:$sha 2>&1 | tail -1
pkill -f "run services proxy"; gcloud run services proxy cma-web --project=p4a-cma-dev \
  --region=europe-west4 --port=8080 >/tmp/proxy.log 2>&1 & sleep 6
curl -s localhost:8080/api/health; echo
```
Expected: the new revision serving 100 percent of traffic; then the health answer with `version` the merge's short SHA, auth `mock`, data `api`.

**Browser** (Chrome at `http://localhost:8080/?as=manager`; ChromeOS forwards the Linux environment's localhost):
1. Welcome: Needs attention with its lines (days not clocked out, leads past the target, tickets at risk or over, tasks overdue, missed callers); Waiting for you with a count.
2. The Live board: Follow-up now under the inbound tiles.
3. Reports → Follow-up: the tiles, the three tables with the links, Per person; K, O and S filter; the page refreshes every 10 seconds.
4. `?as=agent-two` → Welcome's Waiting for you → `/me/follow-up`.
5. `?as=admin` → Configuration → Sources → the HubSpot connection: Task statuses and Task types with the counts from step 7; the Response time column on the ticket pipelines; Configuration → Exports → Follow-up.

Expected: no error page; the counts on Welcome equal the tiles on Follow-up; an agent sees their own rows only; the task table holds step 7's tasks.

## 9. The task address for `record_url_task`

The address now (it needs nothing in the CMA); the setting after step 11, on the merge's image (step 8), once step 7's task rows are in: its preview shows a link for the newest task.

**Browser:** in `CMA dev`, open any task and copy its address. If it reads `https://app-eu1.hubspot.com/contacts/<portal id>/record/0-27/<task id>`, the template is `https://{app_host}/contacts/{account}/record/0-27/{id}` (with `app_host` set as for deals); if a task opens on its record's page instead, note the form and tell me (Open decisions).

**Browser** (on the merge's image of step 8): Sources → the connection → Settings → add `record_url_task` with that template → the preview shows a link for the newest task → Save settings.

Expected: Reports → Follow-up's task rows carry a link that opens the task.

## 10. Prod's migrations, before the merge

Before the merge: merging deploys `cma-web` to prod and Welcome calls 0008o's functions on every load, so a merge first would show Welcome with an error until these ran.

**Terminal** (from the Chromebook; point-in-time recovery on, as before every prod migration)
```bash
gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format="value(settings.backupConfiguration.pointInTimeRecoveryEnabled,settings.backupConfiguration.transactionLogRetentionDays)"
```
Expected: `True	7`.

**Studio (cma-prod-pg)**: `db/70_crm_tasks.sql` (twice), then `db/72_follow_up.sql`, then `db/02_seed_pulse4all.sql`, then the read-only check of `docs/ingest/PROD_RUNBOOK.md` 11.1.

Expected: `70` `INSERT 0 1`, `COMMIT`, the second run `INSERT 0 0`; `72` `INSERT 0 1` near the end and `COMMIT`; `02` clean; the check's two migration rows, `true`, `true`, the three checks, eight settings.

Then `records/0008n-prod-<date>/` and `records/0008o-prod-<date>/` (and the dev ones from steps 2 and 3) from your outputs, and a small README pull request marking both as run.

## 11. Merge N16-B, watch the build

**Browser:** merge PR #142 (squash) once steps 1 to 5, 7, the address of step 9 and step 10 are green (6 is deferred; 8 and the setting of step 9 follow the merge); watch the `cma-web-main` build; then workspace.pulse4all.app. Steps 8 and 9's setting follow, on dev with the merge's image.

Expected: the build green; Welcome loads with Needs attention and Waiting for you (counts or zero lines, no error); Reports → Follow-up in the rail after Speed to lead with its leads and tickets, its task table empty until step 12's backfill (11.3).

**Terminal**
```bash
cd ~/cma && git switch -q main && git pull -q --ff-only && git log -1 --format=%h -- ingest/
```
Expected: `main`'s ingest tag, the squash commit's short sha (the same code as the branch's `f1fc212`).

## 12. Prod: ingest from `main`, backfill, settings, day one (the app version deferred)

The ingest first, as in dev: the backfill's `--object task` needs it; the app version it also comes before is deferred (CMA-067). `--front` stays on every prod service deploy and never goes with `--jobs`, as `deploy.sh` requires since #146: a prod service deploy without `--front` stops before any gcloud call (exit 2), because without it the service's ingress would go to `all` and HubSpot's signatures over the public host would fail (`records/ingest-front-incident-2026-10-16`).

**Terminal** (from the Chromebook; on `main`)
```bash
bash docs/ingest/deploy.sh prod --front ingest.pulse4all.app --tenant pulse4all-subscriptions && bash docs/ingest/deploy.sh prod --jobs
```
Expected: the image built once under `main`'s tag; `ingress: internal-and-cloud-load-balancing (front https://ingest.pulse4all.app: …)`, `health: {"ok":true,"version":"<main's tag>"}` through `https://ingest.pulse4all.app/health` and `run.app: 404 (refused)`; the jobs on the same image (`no build`), the schedules unchanged. A line `prod service deploy needs --front <host> (ingest.pulse4all.app); …` means `--front` was left out, and `--front goes with the service deploy, not --jobs` that it went on the jobs: nothing was deployed, run the line as it stands.

Then `docs/ingest/PROD_RUNBOOK.md`:
- 11.2 after its first block (this deploy): deferred (CMA-067: the app version, its install and the test task).
- 11.3: the backfill of tasks by connection id with `--from 2026-09-01`, and its counts.
- 11.4: on Sources the done statuses, the callback type, the response time per ticket pipeline, `record_url_task` and the Unlinked calls check; on Exports the four settings with Arno and Kira.
- 11.5 (day one); the task figures are incomplete as Task data before CMA-067 says.

Expected: as each section says.

## 13. README, the Gem, the backlog

**File:** `README.md` of `main` after the merge is the project's README: replace the project README and re-upload it to the Gem.

**Backlog:** the rows of `NIGHT_NOTES.md` (CMA-004, -007, -015, -019, -036, -045, -046, -050, -052, -061 and the new rows; CMA-020 not started, CMA-017 Later; CMA-067, the HubSpot uploads through GitHub Actions, and CMA-068, a dev-only web build path, not started).
