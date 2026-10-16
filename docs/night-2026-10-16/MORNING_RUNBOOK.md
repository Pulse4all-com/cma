# Morning runbook, 16 October 2026: N16-B (0008n tasks, 0008o follow-up)

Read `NIGHT_NOTES.md` first (ten minutes: what was built, the one change from the brief's letter, the questions). N16-A (PR #141) is merged as 23fe766 and `main` is merged into this branch, so this runbook is N16-B alone. Labels: **Browser**, **Terminal** (Cloud Shell, in `~/cma` unless stated), **Studio** (the instance named), **File** (a repository path). SQL and shell never share a block. Every step ends with what you should see.

**Order matters.** Merging N16-B deploys `cma-web` to prod (trigger `cma-web-main`) and Welcome calls 0008o's functions on every load, so prod's `70` and `72` (then `02`) run **before** the merge (step 10, then 11); in dev the same, before the dev check. The ingest is deployed before the app version and the backfill in each environment (dev from this branch in step 5, prod from `main` in step 12): the task webhooks and the backfill's `--object task` need an ingest that knows tasks.

| Step | What | Elapsed |
|---|---|---|
| 1 | Review N16-B, build it in Cloud Shell | 25 min |
| 2 | Dev: `70`, `71` normal and provoked | 10 min |
| 3 | Dev: `72`, `02`, `73` normal and provoked; `41`, `53`, `69`, `71` again | 10 min |
| 4 | Refresh `docs/datamap/schema.json` from dev on this branch, rebuild the index | 10 min |
| 5 | The ingest in dev from this branch: service and jobs; health shows the branch's tag | 10 min |
| 6 | Dev HubSpot app: render, upload; a test task reaches the ingest, else reinstall | 10 min |
| 7 | Dev backfill of tasks; the counts | 10 min |
| 8 | Dev on the N16-B image: a hand check of Follow-up, Welcome, the Live board, Sources, Exports | 20 min |
| 9 | The task address for `record_url_task` in dev; set it | 5 min |
| 10 | Prod, before the merge: point-in-time recovery on; `70` twice, `72`, `02`, the read-only check of 11.1; records | 20 min |
| 11 | Merge N16-B; watch the `cma-web-main` build; Welcome in prod | 10 min |
| 12 | Prod ingest from `main` (service with its front, jobs); app version (11.2); backfill (11.3); Sources and Exports settings (11.4); day one (11.5) | 40 min |
| 13 | README to the project, the Gem's README, the backlog | 15 min |

---

## Helpers (define in every new Cloud Shell)

The helpers of `docs/night-2026-10-13/MORNING_RUNBOOK.md`, unchanged (`cma_db dev|prod` starts the Auth Proxy and sets `PGCONN`).

## 1. N16-B: review and build

**Terminal**
```bash
cd ~/cma && gh pr checkout 142 && git log --oneline -10 && cd web && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run build 2>&1 | tail -3 && npm run typecheck && npm run lint && npm run verify:copy && npm run verify:follow-up && npm run verify:configuration && npm run verify:reports; npm run verify:datamap; cd ~/cma && cd ingest && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run lint && node verify/mapping.mjs | tail -1; cd ~/cma && node hubspot/verify/render.mjs | tail -1
```
Expected: the log shows the merge of `main` (23fe766, N16-A) and the two morning fixes above N16-B's own commits; `copy: PASS (1601 keys, en and nl)`, `follow-up: PASS (25 checks)`, `ALL 92 PASS`, `ALL 75 PASS`; **`datamap: FAIL (10 problems)`** naming the three 0008n tables, the six 0008o views and the index (expected until step 4); `ALL 48 PASS` for the mapping, `ALL 33 PASS` for the render.

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

**Terminal** (on the N16-B branch, dev's proxy running)
```bash
cd ~/cma && cma_db dev && psql "$PGCONN" -X -At -f tools/datamap/schema.sql > docs/datamap/schema.json && node tools/datamap/build.mjs && cd web && npm run verify:datamap; cd ~/cma && git add docs/datamap && git commit -m "Data map: schema.json from dev after 0008n and 0008o" && git push
```
Expected: `datamap: PASS (75 tables, 95 views, all described; index.html current)` (72 + 3 tables; 89 + 6 views), the commit on the branch.

## 5. The ingest in dev from this branch

Before the app version and the backfill: the task webhooks and `--object task` need an ingest that knows tasks. The script asks for a clean `ingest/`, not for `main`; the image tag is the last commit that touched `ingest/`.

**Terminal** (on the N16-B branch)
```bash
cd ~/cma && git log -1 --format=%h -- ingest/ && bash docs/ingest/deploy.sh dev && bash docs/ingest/deploy.sh dev --jobs
```
Expected: the tag first (today `8f729a7`); the first deploy builds the image once (`gcloud builds submit …`) and ends with `health: {"ok":true,"version":"8f729a7"}` (the same tag); the second deploys the jobs on that image (`no build`) with the schedules unchanged.

## 6. The dev HubSpot app

**Terminal**
```bash
node hubspot/render.mjs dev --target-url "https://<dev ingest host>/hubspot/<dev key>" && node hubspot/verify/render.mjs | tail -1 && cd hubspot/build/dev && hs project upload && cd ~/cma
```
Expected: `rendered dev: hubspot/build/dev`, `ALL 33 PASS`, the upload naming `CMA dev`, build and deploy succeeding.

**Browser:** `CMA dev` → Development → Projects → the app → Distribution → Test installs → the row of `CMA dev`. If HubSpot offers an update, accept it (no new scope; the webhooks tab lists nine `task` subscriptions among 46). If it offers no update or reinstall for this webhooks-only change, the upload is enough.

**Browser:** in `CMA dev`, create a test task on a test contact (a title only, no body).

**Studio (cma-dev-pg)**, a few minutes later
```sql
set role cma_owner;
select object_type, kind, status, count(*) from cma.ingest_event where object_type = 'task' and recorded_at > now() - interval '15 minutes' group by 1, 2, 3 order by 1, 2, 3;
reset role;
```
Expected: at least one `task | created` row (`received`, or `processed` once the sweep ran; it runs every minute). If no task event arrives within minutes, the subscriptions did not reach the install: reinstall through Distribution → Test installs → **Add test install(s)** → tick `CMA dev`, as 15 October showed for the scopes, then create another test task. Check the token afterwards: it stays; if HubSpot shows a new one on the install's row → Show, store it with `put_secret p4a-cma-dev ingest-hubspot-dev-token` (`hubspot/README.md`).

## 7. The dev backfill of tasks

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

## 8. Dev on the N16-B image: the hand check

**Terminal**
```bash
gcloud builds submit --config cloudbuild.yaml --project=p4a-cma-prod --substitutions=_DEPLOY=false . 2>&1 | tail -3
```
(or your usual way of building the branch's image), then `gcloud run services update cma-web --project=p4a-cma-dev --region=europe-west4 --image=…/web:<short sha>` and `gcloud run services proxy cma-web --project=p4a-cma-dev --region=europe-west4 --port=8080`.

**Browser** (`http://localhost:8080/?as=manager`):
1. Welcome: Needs attention with its lines (days not clocked out, leads past the target, tickets at risk or over, tasks overdue, missed callers); Waiting for you with a count.
2. The Live board: Follow-up now under the inbound tiles.
3. Reports → Follow-up: the tiles, the three tables with the links, Per person; K, O and S filter; the page refreshes every 10 seconds.
4. `?as=agent-two` → Welcome's Waiting for you → `/me/follow-up`.
5. `?as=admin` → Configuration → Sources → the HubSpot connection: Task statuses and Task types with the counts from step 7; the Response time column on the ticket pipelines; Configuration → Exports → Follow-up.

Expected: no error page; the counts on Welcome equal the tiles on Follow-up; an agent sees their own rows only.

## 9. The task address for `record_url_task`

**Browser:** in `CMA dev`, open any task and copy its address. If it reads `https://app-eu1.hubspot.com/contacts/<portal id>/record/0-27/<task id>`, the template is `https://{app_host}/contacts/{account}/record/0-27/{id}` (with `app_host` set as for deals); if a task opens on its record's page instead, note the form and tell me (Open decisions).

**Browser:** Sources → the connection → Settings → add `record_url_task` with that template → the preview shows a link for the newest task → Save settings.

Expected: Reports → Follow-up's task rows carry a link that opens the task.

## 10. Prod's migrations, before the merge

Before the merge: merging deploys `cma-web` to prod and Welcome calls 0008o's functions on every load, so a merge first would show Welcome with an error until these ran.

**Terminal** (point-in-time recovery on, as before every prod migration)
```bash
gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format="value(settings.backupConfiguration.pointInTimeRecoveryEnabled,settings.backupConfiguration.transactionLogRetentionDays)"
```
Expected: `True	7`.

**Studio (cma-prod-pg)**: `db/70_crm_tasks.sql` (twice), then `db/72_follow_up.sql`, then `db/02_seed_pulse4all.sql`, then the read-only check of `docs/ingest/PROD_RUNBOOK.md` 11.1.

Expected: `70` `INSERT 0 1`, `COMMIT`, the second run `INSERT 0 0`; `72` `INSERT 0 1` near the end and `COMMIT`; `02` clean; the check's two migration rows, `true`, `true`, the three checks, eight settings.

Then `records/0008n-prod-<date>/` and `records/0008o-prod-<date>/` (and the dev ones from steps 2 and 3) from your outputs, and a small README pull request marking both as run.

## 11. Merge N16-B, watch the build

**Browser:** merge PR #142 (squash) once steps 1 to 10 are green; watch the `cma-web-main` build; then workspace.pulse4all.app.

Expected: the build green; Welcome loads with Needs attention and Waiting for you (counts or zero lines, no error); Reports → Follow-up in the rail after Speed to lead, its task table empty until step 12's backfill.

**Terminal**
```bash
cd ~/cma && git switch -q main && git pull -q --ff-only && git log -1 --format=%h -- ingest/
```
Expected: `main`'s ingest tag, the squash commit's short sha (the same code as the branch's `8f729a7`).

## 12. Prod: ingest from `main`, app version, backfill, settings, day one

Before the app version and the backfill, as in dev. `--front` stays on every prod service deploy: without it the service's ingress would open the run.app address.

**Terminal** (on `main`)
```bash
bash docs/ingest/deploy.sh prod --front ingest.pulse4all.app --tenant pulse4all-subscriptions && bash docs/ingest/deploy.sh prod --jobs
```
Expected: the image built once under `main`'s tag; `health: {"ok":true,"version":"<main's tag>"}` through `https://ingest.pulse4all.app/health` and `run.app: 404 (refused)`; the jobs on the same image (`no build`), the schedules unchanged.

Then `docs/ingest/PROD_RUNBOOK.md` 11.2 (the app version; a reinstall only if a test task does not reach the ingest), 11.3 (the backfill by connection id and its counts), 11.4 (Sources: the done statuses, the callback type, the response time per pipeline, `record_url_task`, the Unlinked calls check; Exports: the four settings with Arno and Kira), 11.5 (day one).

Expected: as each section says.

## 13. README, the Gem, the backlog

**File:** `README.md` of `main` after the merge is the project's README: replace the project README and re-upload it to the Gem.

**Backlog:** the rows of `NIGHT_NOTES.md` (CMA-004, -007, -015, -019, -036, -045, -046, -050, -052, -061 and the new rows; CMA-020 not started, CMA-017 Later).
