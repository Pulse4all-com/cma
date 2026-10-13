# Morning runbook, A5: the fifth and sixth Gemini audits

Labels: **Browser**, **Terminal** (Cloud Shell, in `~/cma` unless stated), **Studio** (the instance named), **File** (a repository path). SQL and shell never share a block. Every step ends with what you should see. The local outputs are in `local-records/` (its `README.md` lists them).

**What changes:** a Cloud Monitoring alert on Cloud Armor's 429s for the ingest backend (`docs/ingest/alert.sh`, new); a second Cloud Armor rule, 2,400 requests per minute per IP on `/shopify/` (`docs/ingest/front.sh`, rule 900 before rule 1000); `--cpu-boost` on the `cma-ingest` service (`docs/ingest/deploy.sh`, nothing else changes); the sweep's outbox guard (`ingest/`) with its Data quality row (`web/`); the Shopify secret's rotation line in `PROD_RUNBOOK.md` 9.3; README (Decision log, Architecture, Infrastructure, Verification, Open decisions). No migration, nothing under `db/`.

**Order matters:**
- Merging deploys `cma-web` to prod (the pull request touches `web/**`): the Data quality row. It reads `cma.outbox_action`, which prod has had since 0007c; nothing to run in the database first.
- The ingest service and jobs are deployed by hand from `main` after the merge (dev, then prod), as always; until then the sweep has no guard and the service no CPU boost.
- `front.sh` and `alert.sh` are independent of the deploys; run `front.sh` first, so the alert's text (rules 900 and 1000) is true when the alert exists.

| Step | What | Elapsed |
|---|---|---|
| 1 | Review the pull request, run the ingest checks and the two dry runs | 15 min |
| 2 | Merge, watch the web build | 10 min |
| 3 | The ingest service and jobs in dev | 15 min |
| 4 | The ingest service and jobs in prod | 10 min |
| 5 | Cloud Armor's `/shopify/` rule | 5 min |
| 6 | The 429 alert | 5 min |
| 7 | Data quality and the sweep's guard | 5 min |

---

## 1. Review the pull request and run the checks

**Browser:** GitHub → Pulse4all-com/cma → Pull requests → "A5: the fifth and sixth Gemini audits". Read the description and the diff.

Expected: nothing under `db/` or `records/`, no change to `cloudbuild.yaml` or `ingest/cloudbuild.yaml`; in `deploy.sh` one added line, `--cpu-boost`.

**Terminal** (the pull request's number from the page)
```bash
cd ~/cma && gh pr checkout <number> && cd ingest && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run lint && npm test 2>&1 | grep -E "^ALL|FAILED"; cd ~/cma
```
Expected: `found 0 vulnerabilities` (or `added … packages`), no lint output after the `eslint` line, and twelve lines `ALL n PASS` (18, 37, 26, 41, 20, 49, 27, 17, 51, 21, 21, 20), no `FAILED`: unchanged, the guard's checks are in `verify/jobs-flow.mjs`, which needs a local database (`local-records/ingest/verify-jobs-flow.txt`: `ALL 71 PASS`).

**Terminal**
```bash
bash -n docs/ingest/alert.sh && bash -n docs/ingest/front.sh && bash -n docs/ingest/deploy.sh && echo syntax ok
bash docs/ingest/front.sh prod --host ingest.pulse4all.app --dry-run
bash docs/ingest/alert.sh prod --email <alert address> --dry-run | grep -E 'backend_target_name|alignmentPeriod|COMPARISON|"duration"'
```
Expected: `syntax ok`; the front's dry run lists `900  request.path.startsWith('/shopify/')  2400 requests per 60 s per IP, then 429`, `1000 … 600 …` and `default … allow`, then two `gcloud compute security-policies rules create` lines; the alert's four lines are the filter with `resource.labels.backend_target_name = \"cma-ingest-backend\"` and `metric.labels.response_code = 429`, `"alignmentPeriod": "300s",`, `"comparison": "COMPARISON_GT",` and `"duration": "60s",`. Neither dry run calls gcloud.

## 2. Merge and watch the web build

**Terminal**
```bash
gh pr merge <number> --squash --delete-branch && git switch -q main && git pull -q --ff-only && git log --oneline -1
```
Expected: the merge commit on top of `main`.

**Terminal** (repeat until it is not `WORKING`; `docs/RUNBOOK.md` section 3)
```bash
gcloud builds list --project=p4a-cma-prod --region=europe-west4 --limit=3 --format="table(status,substitutions.SHORT_SHA,createTime.date('%H:%M'))"
```
Expected: `SUCCESS` for the merge's short sha after 2 to 4 minutes; `cma-web` in prod then serves the Data quality row (step 7).

## 3. The ingest service and jobs in dev

**Terminal** (in `~/cma`, on `main`)
```bash
bash docs/ingest/deploy.sh dev --tenant pulse4all-subscriptions --tenant pulse4all-invest
```
Expected: as every dev deploy (`docs/ingest/README.md`, Deploy): `image … ingest:<short sha>` built in Cloud Build (`SUCCESS`; the merge touched `ingest/`, so this sha is new), the Cloud Run deploy, `health: {"ok":true,"version":"<short sha>"}`.

**Terminal**
```bash
bash docs/ingest/deploy.sh dev --jobs
```
Expected: `image … exists (sha256:…); no build`, the five job deploys, `schedule ingest-sweep: * * * * * (Europe/Amsterdam)` and the others, `schedule ingest-outbox: none (the job runs only when executed)` (or `paused`).

**Terminal**
```bash
gcloud run services describe cma-ingest --project=p4a-cma-dev --region=europe-west4 --format=json | grep -o '"run.googleapis.com/startup-cpu-boost": *"[a-z]*"'
```
Expected: `"run.googleapis.com/startup-cpu-boost": "true"`.

**Terminal** (two minutes after the jobs deploy: the sweep's totals now carry the guard's count)
```bash
gcloud logging read 'resource.type=cloud_run_job AND resource.labels.job_name=ingest-sweep AND jsonPayload.message="sweep"' --project=p4a-cma-dev --freshness=10m --limit=3 --format='value(timestamp,jsonPayload.outboxPending,jsonPayload.failed)'
```
Expected: lines ending in `0	0` (no overdue outbox action, no failure). An empty second column means the run is still on the old image: wait a minute and repeat.

## 4. The ingest service and jobs in prod

**Terminal** (always with `--front`)
```bash
bash docs/ingest/deploy.sh prod --front ingest.pulse4all.app --tenant pulse4all-subscriptions
```
Expected: `image … exists (sha256:…); no build` (prod runs what dev tested), `ingress: internal-and-cloud-load-balancing`, `health: {"ok":true,"version":"<short sha>"}`, `run.app: 404 (refused)`.

**Terminal**
```bash
bash docs/ingest/deploy.sh prod --jobs
```
Expected: `no build`, the five job deploys, the schedules as in dev, `ingest-outbox` without a schedule.

**Terminal**
```bash
gcloud run services describe cma-ingest --project=p4a-cma-prod --region=europe-west4 --format=json | grep -o '"run.googleapis.com/startup-cpu-boost": *"[a-z]*"'
gcloud logging read 'resource.type=cloud_run_job AND resource.labels.job_name=ingest-sweep AND jsonPayload.message="sweep"' --project=p4a-cma-prod --freshness=10m --limit=3 --format='value(timestamp,jsonPayload.outboxPending,jsonPayload.failed)'
```
Expected: `"run.googleapis.com/startup-cpu-boost": "true"`; then, a few minutes after the jobs deploy, lines ending in `0	0`.

## 5. Cloud Armor's `/shopify/` rule

**Terminal**
```bash
bash docs/ingest/front.sh prod --host ingest.pulse4all.app
```
Expected: steps `a.` to `e.` say `exists`; `c. rule 900 (create): /shopify/, 2400 requests per 60 s per IP, then 429` and `c. rule 1000 (update): every other request, 600 requests per 60 s per IP, then 429` (rule 1000 updated to the values it already has); the A record and the certificate `ACTIVE` as before.

**Terminal**
```bash
gcloud compute security-policies describe cma-ingest-armor --project=p4a-cma-prod --flatten='rules[]' --format='table(rules.priority,rules.match.expr.expression,rules.rateLimitOptions.rateLimitThreshold.count,rules.action)'
curl -sS -o /dev/null -w "%{http_code}\n" https://ingest.pulse4all.app/health
```
Expected: three rows, `900  request.path.startsWith('/shopify/')  2400  throttle`, `1000  600  throttle`, `2147483647  allow`; then `200`.

## 6. The 429 alert

The address is where the alert goes (a person or a group); it is passed on the command line and stored only in the notification channel.

**Terminal**
```bash
bash docs/ingest/alert.sh prod --email <alert address>
```
Expected: `a. email channel created: projects/p4a-cma-prod/notificationChannels/<id>` (or `exists`), `b. policy created: projects/p4a-cma-prod/alertPolicies/<id>`, then the check line `cma-ingest 429  True  resource.type = "https_lb_rule" AND … response_code = 429  300s  60s  projects/p4a-cma-prod/notificationChannels/<id>`. A rerun after a failed policy create (the channel was made before the policy) says `a. email channel exists: projects/p4a-cma-prod/notificationChannels/<id>`, then `b. policy created`. If it says it cannot list channels with `gcloud beta`, the beta component is missing (Cloud Shell has it). A rerun says `exists` and `policy updated`, never a second policy.

**Browser:** console → Monitoring → Alerting (project `p4a-cma-prod`) → Policies → `cma-ingest 429`.

Expected: enabled, one condition (`429 from the load balancer for cma-ingest-backend, summed over 5 minutes, above 0`, for 1 minute), the email channel; the condition's chart empty (no 429 counted).

Dev (optional, to try the script; dev has no load balancer, so the policy stays quiet there):

**Terminal**
```bash
bash docs/ingest/alert.sh dev --email <alert address>
```
Expected: the note `dev has no load balancer…`, then the same lines with `p4a-cma-dev`.

## 7. Data quality and the sweep's guard

**Browser:** `https://workspace.pulse4all.app/reports/data-quality` as an admin or analyst.

Expected: the checks as before; no row "Contact updates not sent" (it shows only while an outbox action waits ten minutes past its due time, and nothing enqueues one since 0008h).

**Terminal** (the guard's warnings since the deploy)
```bash
gcloud logging read 'resource.type=cloud_run_job AND resource.labels.job_name=ingest-sweep AND jsonPayload.code="outbox_pending"' --project=p4a-cma-prod --freshness=1d --limit=10 --format='value(timestamp,jsonPayload.connection,jsonPayload.outboxPending)'
```
Expected: nothing.

Open after this runbook (README, Open decisions): 2SV enforcement for the agents' unit, to check in the Admin console now (fifth audit FIND-06); container scanning (FIND-08); the audit images and legal entities with Yordi (FIND-05); a PII grep of the logs after the Shopify pilot store (sixth audit FIND-03).
