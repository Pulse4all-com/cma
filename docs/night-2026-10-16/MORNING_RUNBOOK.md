# Morning runbook, 16 October 2026: N16-A (Workspace quick wins), N16-B (0008n tasks, 0008o follow-up)

Read `NIGHT_NOTES.md` first (ten minutes: what was built, the one change from the brief's letter, the questions). Labels: **Browser**, **Terminal** (Cloud Shell, in `~/cma` unless stated), **Studio** (the instance named), **File** (a repository path). SQL and shell never share a block. Every step ends with what you should see.

**Order matters.** N16-A has no migration and deploys on merge. N16-B's web reads the functions of 0008n and 0008o on Welcome, the Live board, Reports → Follow-up and Sources, so `70` and `72` run in dev **before** N16-B is checked in dev, and in prod **before** N16-B is merged; until then a merged `main` would show Welcome with an error. The HubSpot app version with the task subscriptions is uploaded in dev before the dev backfill and in prod after the prod migrations.

| Step | What | Elapsed |
|---|---|---|
| 1 | Review and merge N16-A (PR #141); watch the prod build; a hand check | 30 min |
| 2 | Review N16-B, build it in Cloud Shell | 25 min |
| 3 | Dev: `70`, `71` normal and provoked | 10 min |
| 4 | Dev: `72`, `02`, `73` normal and provoked; `41`, `69`, `71` again | 10 min |
| 5 | Refresh `docs/datamap/schema.json` from dev on the N16-B branch, rebuild the index | 10 min |
| 6 | Dev HubSpot app: render, upload, accept the update (46 subscriptions) | 10 min |
| 7 | Dev backfill of tasks; the counts | 10 min |
| 8 | Dev on the N16-B image: a hand check of Follow-up, Welcome, the Live board, Sources, Exports | 20 min |
| 9 | The task address for `record_url_task` in dev; set it | 5 min |
| 10 | Merge N16-B; prod: `70`, `72`, `02`, the read-only check; records | 20 min |
| 11 | Prod app version; prod backfill; the Sources settings; the Exports settings | 30 min |
| 12 | README to the project, the Gem's README, the backlog | 15 min |

---

## Helpers (define in every new Cloud Shell)

The helpers of `docs/night-2026-10-13/MORNING_RUNBOOK.md`, unchanged (`cma_db dev|prod` starts the Auth Proxy and sets `PGCONN`).

## 1. N16-A: review, merge, hand check

**Terminal**
```bash
cd ~/cma && gh pr checkout 141 && cd web && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run build 2>&1 | tail -3 && npm run typecheck && npm run lint && npm run verify:copy && npm run verify:preview && npm run verify:roster && npm run verify:layout && npm run verify:theme && npm run verify:hints; cd ~/cma
```
Expected: `found 0 vulnerabilities`, the build's route table, no type or lint error, `copy: PASS (1402 keys, en and nl)`, `preview: PASS (18 checks)`, `roster: PASS (36 checks)`, `layout: PASS (…)`, `theme: PASS (46 pages …)`, `hints: PASS (233 headers and 59 tiles …)`.

**Browser:** merge PR #141 (squash), watch the `cma-web-main` build, then workspace.pulse4all.app: W folds the rail, `?` hides the hints, the breadcrumbs above a report, Preview as → Agent shows the banner and five rail pages, Exit preview, My account's What your role allows, the roster's week as one range.

Expected: every one of them as described; nothing on Welcome changed otherwise.

## 2. N16-B: review and build

**Terminal**
```bash
cd ~/cma && gh pr checkout <N16-B number> && git log --oneline -6 && cd web && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run build 2>&1 | tail -3 && npm run typecheck && npm run lint && npm run verify:copy && npm run verify:follow-up && npm run verify:configuration && npm run verify:reports; npm run verify:datamap; cd ~/cma && cd ingest && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run lint && node verify/mapping.mjs | tail -1; cd ~/cma && node hubspot/verify/render.mjs | tail -1
```
Expected: the N16-A commits below N16-B's four; `copy: PASS (1601 keys, en and nl)`, `follow-up: PASS (25 checks)`, `ALL 92 PASS`, `ALL 75 PASS`; **`datamap: FAIL`** naming the three 0008n tables and the six 0008o views as not in `schema.json` (expected until step 5); `ALL 48 PASS` for the mapping, `ALL 33 PASS` for the render.

## 3. Dev: 0008n

**Studio (cma-dev-pg)**: `db/70_crm_tasks.sql` as one script, your own login.

Expected: `INSERT 0 1`, `COMMIT`. Run it once more: `INSERT 0 0`.

**Studio (cma-dev-pg)**: `db/71_verify_crm_tasks.sql`.

Expected: 20 rows `PASS` and the verdict row `PASS | 20 PASS, 0 FAIL`. Then with `verify.provoke` set to `'true'` in the script's first `set_config`: every row `FAIL`, the verdict `PROVOKED, NOT A PASS | 0 PASS, 20 FAIL`. Keep the outputs for `records/0008n-dev-<date>/`.

## 4. Dev: 0008o

**Studio (cma-dev-pg)**: `db/72_follow_up.sql`, then `db/02_seed_pulse4all.sql` again.

Expected: `INSERT 0 1`, `COMMIT`; `02` without an error.

**Studio (cma-dev-pg)**: `db/73_verify_follow_up.sql`, normal and provoked as in step 3.

Expected: `PASS | 21 PASS, 0 FAIL`; provoked `PROVOKED, NOT A PASS | 0 PASS, 21 FAIL`.

**Studio (cma-dev-pg)**: `41_verify_lead_metrics.sql`, `69_verify_email_activity.sql`, `71_verify_crm_tasks.sql` again.

Expected: `41` its two tenant rows `PASS`, `69` `29 PASS, 0 FAIL`, `71` `20 PASS, 0 FAIL`.

## 5. The data map

**Terminal** (on the N16-B branch, dev's proxy running)
```bash
cd ~/cma && cma_db dev && psql "$PGCONN" -X -At -f tools/datamap/schema.sql > docs/datamap/schema.json && node tools/datamap/build.mjs && cd web && npm run verify:datamap; cd ~/cma && git add docs/datamap && git commit -m "Data map: schema.json from dev after 0008n and 0008o" && git push
```
Expected: `datamap: PASS (75 tables, 95 views, all described; index.html current)` (72 + 3 tables; 89 + 6 views), the commit on the branch.

## 6. The dev HubSpot app

**Terminal**
```bash
node hubspot/render.mjs dev --target-url "https://<dev ingest host>/hubspot/<dev key>" && node hubspot/verify/render.mjs | tail -1 && cd hubspot/build/dev && hs project upload && cd ~/cma
```
Expected: `rendered dev: hubspot/build/dev`, `ALL 33 PASS`, the upload naming `CMA dev`, build and deploy succeeding.

**Browser:** `CMA dev` → Development → Projects → the app → the install → accept the update (no new scope; the webhooks tab lists nine `task` subscriptions among 46).

Expected: the install active; the token unchanged.

## 7. The dev backfill of tasks

**Terminal**
```bash
gcloud run jobs execute ingest-backfill --project=p4a-cma-dev --region=europe-west4 --args="--connection,<dev key>,--object,task,--since,2026-09-01" --wait
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

## 10. Merge N16-B, then prod's migrations

**Browser:** merge the N16-B pull request (squash) once steps 3 to 9 are green; watch the `cma-web-main` build **but do not open prod yet**.

**Studio (cma-prod-pg)**: `db/70_crm_tasks.sql`, then `db/72_follow_up.sql`, then `db/02_seed_pulse4all.sql`, then the read-only check of `docs/ingest/PROD_RUNBOOK.md` 11.1.

Expected: `INSERT 0 1`, `COMMIT` twice; `02` clean; the check's two migration rows, `true`, `true`, the three checks, eight settings.

Then `records/0008n-prod-<date>/` and `records/0008o-prod-<date>/` (and the dev ones from steps 3 and 4) from your outputs, and a small README pull request marking both as run.

## 11. Prod app version, backfill, settings

`docs/ingest/PROD_RUNBOOK.md` 11.2 (the app version), 11.3 (the backfill and its counts), 11.4 (Sources: the done statuses, the callback type, the response time per pipeline, `record_url_task`, the Unlinked calls check; Exports: the four settings with Arno and Kira), 11.5 (day one).

Expected: as each section says.

## 12. README, the Gem, the backlog

**File:** `README.md` of this branch is the project's README after the merge: replace the project README and re-upload it to the Gem.

**Backlog:** the rows of `NIGHT_NOTES.md` (CMA-004, -007, -015, -019, -036, -045, -046, -050, -052, -061 and the new rows; CMA-020 not started, CMA-017 Later).
