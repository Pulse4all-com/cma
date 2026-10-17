# OPERATIONS: running the CMA in production

The runbook for the day after a deploy and for the morning after a bad night. It complements `docs/RUNBOOK.md`
(how a change is built, merged, released and verified) and does not repeat it: where RUNBOOK has the steps,
this file names the section. Written from the repository only (the two runbooks, `docs/ingest/README.md`,
`docs/ingest/PROD_RUNBOOK.md`, the deploy scripts under `docs/`, `cloudbuild.yaml`, README Environments and
infrastructure, Database connection budget, Release flow and Authentication, the code in `web/src` and
`ingest/src`) for the full IT audit of 17 October 2026 (`docs/audits/2026-10-17-full-audit/`). Nothing in
it was run against production; a command marked **untested here; dry-run first** has not been seen run in a
record or a runbook. Where a pull request of the audit changes a step, the step says so by name.

## Conventions

- Every block is labelled **Terminal** (Martin's own Linux terminal; for prod the Chromebook only, README
  Environments and infrastructure), **Studio** (Cloud SQL Studio, with the instance), **Browser** (a page or a
  click path) or **File** (a repository path). SQL and shell never share a block. One step at a time, each with
  what you should see.
- `--project` is always explicit (`p4a-cma-prod`, `p4a-cma-dev`); the region is `europe-west4`.
- Before a command marked **untested here; dry-run first**: read its `--help`, run the read-only form first
  (`list`, `describe`), and on anything that changes prod prefer the script in `docs/` that owns the resource.
- Secret names appear here; a secret value never appears anywhere: not in output you keep, not in a
  screenshot, not in a record. After `gcloud secrets versions access`, run `clear` (RUNBOOK 10a).
- A query that can return customer rows runs in Studio, never through the Auth Proxy in the terminal (README,
  Where a command runs).
- A record of a run (`records/`) holds shas, times and counts from Martin's own run; never a name, a key or a
  URL with a token.

## 1. The parts, and where each is deployed from

| Part | Where | Deployed by | Image |
|---|---|---|---|
| `cma-web` (the Workspace, `workspace.pulse4all.app`, behind IAP) | Cloud Run service, `p4a-cma-prod` | the Cloud Build trigger `cma-web-main` on every merge to `main` that touches `web/**` or `cloudbuild.yaml` (RUNBOOK 2 and 3; dev first with RUNBOOK 4) | `europe-west4-docker.pkg.dev/p4a-cma-prod/cma/web:<short sha>` |
| `cma-ingest` (`ingest.pulse4all.app`, no IAP, Cloud Armor) | Cloud Run service | `bash docs/ingest/deploy.sh prod --front ingest.pulse4all.app …` by hand, dev first from the same commit (`docs/ingest/README.md`, Deploy) | `…/cma/ingest:<short sha>` of the last commit under `ingest/` |
| `ingest-sweep`, `ingest-poll-forms`, `ingest-poll-email`, `ingest-reconcile`, `ingest-outbox`, `ingest-backfill` | Cloud Run jobs | `bash docs/ingest/deploy.sh prod --jobs` | the ingest image |
| `cma-close-forgotten-workdays` | Cloud Run job | `bash docs/scheduler/deploy.sh prod <short sha>` after a web deploy that changes the job | the web image |
| Cloud Scheduler: the three per-minute ingest jobs, `ingest-reconcile` (02:30 Europe/Amsterdam today; 03:30 once the pull request fix-ops is merged and `deploy.sh prod --jobs` has run), `cma-close-forgotten-workdays-hourly` (`0 * * * *`, UTC); `ingest-outbox` has no schedule or a paused one | `europe-west4` | the two deploy scripts | |
| `cma-nocodb` (read-only table browser, behind IAP) | Cloud Run service | `docs/nocodb/deploy.sh prod` (`--dry-run` first) | the pinned image of `docs/nocodb/service.template.yaml` |
| Load balancer `cma-web-urlmap`; backends `cma-web-backend` (IAP), `cma-ingest-backend` (Cloud Armor `cma-ingest-armor`), `cma-signed-out-backend` (a bucket) | global | `docs/ingest/front.sh` (`--dry-run`), `docs/signed-out/deploy.sh` (a dry run without `--apply`) | |
| `cma-prod-pg` (PostgreSQL 18, regional high availability, daily backups with point-in-time recovery) | Cloud SQL, `europe-west4` | migrations by hand in Studio, dev first (README, Release flow; RUNBOOK 7) | |

A web deploy is a merge (RUNBOOK 2); a failed build deploys nothing (RUNBOOK 3). An ingest deploy that builds
in prod is a sign dev was skipped: the image is built once and prod says `no build` when it runs what dev
tested. A configuration change of `cma-web` is a trigger export, edit, import and run (RUNBOOK 9), never a
Console edit.

## 2. The five-minute prod check

Run it after every merge that built prod, after every `deploy.sh prod` (service or jobs) and after any Console
change; it is also step 1 of the daily check (section 10). Stop at the first step that does not look right and
go to section 3.

1. **Browser:** Configuration → System health (`/configuration/health`; the page of pull requests #152 and
   #153, for `tenant.configure` holders). Until it is live, start at step 2.
   Expected: the version card shows the short sha you just merged, auth `IAP` and data `API`; the database
   probe `Fast`; the heartbeat `Fresh`; every source `Working`; every job row without `Failed`, `Stuck` or
   `Never ran`; the outbox without `needs_review` or `failed` rows. What each other state means: section 4.

2. **Terminal** (the sha that should be live; RUNBOOK 3)
   ```bash
   cd ~/cma && git switch -q main && git pull -q --ff-only && git log --oneline -1 && gcloud builds list --project=p4a-cma-prod --region=europe-west4 --limit=1 --format="table(status,substitutions.SHORT_SHA,createTime.date('%H:%M'))"
   ```
   Expected: the merge commit, then `SUCCESS` with the same 7-character short sha.

3. **Browser:** `https://workspace.pulse4all.app/` with your own account, through IAP.
   Expected: Welcome with your name in the top bar; bottom left of the rail the line `Version <short sha>` with
   the sha of step 2 (`CMA_VERSION`, set from `SHORT_SHA` by `cloudbuild.yaml`). An older sha means traffic
   still goes to an older revision or the build has not deployed yet: wait two minutes and reload once.

4. **Browser:** `https://workspace.pulse4all.app/api/health` in the same signed-in browser (the route sits
   behind IAP like every page; without an IAP session it answers a redirect to Google, which is right).
   Expected: `{"status":"ok","version":"<short sha>","auth":"iap","data":"api"}`. `"auth"` must be `iap` and
   `"data"` must be `api`; anything else is a wrong trigger substitution (RUNBOOK 9): roll back. Once pull
   request #154 is live the route answers `503` with `"status":"misconfigured"` and a `problems` list for a
   revision that cannot serve anyone, and once #155 is live such a revision never takes traffic (the startup
   probe on this route).

5. **Browser:** `https://ingest.pulse4all.app/health` (no IAP in front of the ingest).
   Expected: `{"ok":true,"version":"<ingest short sha>"}`, the sha `deploy.sh` printed (the last commit under
   `ingest/`, not necessarily the web sha).

6. **Terminal** (after an ingest deploy: the `run.app` address refuses everyone; PROD_RUNBOOK 7.1)
   ```bash
   curl -sS -o /dev/null -w "%{http_code}\n" "$(gcloud run services describe cma-ingest --project=p4a-cma-prod --region=europe-west4 --format='value(status.url)')/health"
   ```
   Expected: `404`. A `200` is the incident of 16 October 2026 (`records/ingest-front-incident-2026-10-16`):
   rerun `bash docs/ingest/deploy.sh prod --front ingest.pulse4all.app …` from `main`.

7. **Browser:** Time → Team hours (`/team/hours`), today.
   Expected: the day's rows for the people clocked in, totals at the bottom, no error banner, the page within
   a second or two.

8. **Browser:** one write, with your own account only: Time → My day (`/day`), change your status to another
   status and back.
   Expected: the status chip and the "since" time change at once, both times, no error. The two changes are
   real events on your own day and stay in the audit log, which is fine; never do this on a colleague's account
   or device (README, Authentication). Without `workday.own` on your account, skip and say so in the record.

9. **Browser:** Live → Live board (`/live/board`).
   Expected: everyone clocked in with a status and a running clock; your change of step 8 visible within the
   board's refresh; the inbound tiles with figures or "no calls yet", not an error.

10. **Terminal** (the sweep still logs; `docs/a5-audits/MORNING_RUNBOOK.md` steps 3 and 4)
    ```bash
    gcloud logging read 'resource.type=cloud_run_job AND resource.labels.job_name=ingest-sweep AND jsonPayload.message="sweep"' --project=p4a-cma-prod --freshness=10m --limit=3 --format='value(timestamp,jsonPayload.processed,jsonPayload.failed,jsonPayload.outboxPending)'
    ```
    Expected: three lines, the newest at most two minutes old, `failed` 0 and `outboxPending` 0.

Write what you saw (shas, times, counts) in `records/` only when it is a release record.

## 3. Roll back

### 3.1 `cma-web`: RUNBOOK 10

Traffic to the previous revision in seconds, no build: the two commands of RUNBOOK 10 (`revisions list`, then
`update-traffic … --to-revisions=<previous revision>=100`). Expected: `Traffic: 100% <previous revision>`;
then steps 3 and 4 of section 2 show the older sha. Then fix forward with a new commit; the next successful
build sends traffic to the new revision again. A revision carries the environment of its build (the trigger's
substitutions), so rolling back also rolls back `_LOGOUT_TARGET`, `_DATA_MODE` and the pool size to what that
revision had. Back to mock data as a last resort: RUNBOOK 10, last paragraph.

### 3.2 `cma-ingest` (untested here; dry-run first)

**Terminal**
```bash
gcloud run revisions list --service=cma-ingest --project=p4a-cma-prod --region=europe-west4 --limit=5 --format="table(metadata.name,metadata.creationTimestamp.date('%d %b %H:%M'),status.conditions[0].status,spec.containers[0].image.basename())"
```
Expected: the revisions with their image tags (`ingest:<short sha>`). Never pick a revision made before 16
October 2026 without `--front` (its `INGEST_PUBLIC_URLS` lacks the public host; the revision is named in
`records/ingest-front-incident-2026-10-16`). The ingress is a service-level setting and stays
`internal-and-cloud-load-balancing` whichever revision serves.

**Terminal**
```bash
gcloud run services update-traffic cma-ingest --project=p4a-cma-prod --region=europe-west4 --to-revisions=<previous revision>=100
```
Expected: `Traffic: 100% <previous revision>`; `https://ingest.pulse4all.app/health` shows that revision's sha;
the `run.app` check of section 2 step 6 still answers `404`.

Cleaner, when the previous good commit is known: deploy that commit again with the script, so every flag the
script sets (ingress, public URLs, budgets, boost) is set as the script sets it, and the image is pulled by tag
without a build. The script requires a clean `ingest/` tree and refuses a prod service deploy without
`--front`; once fix-ops is merged it also refuses a checkout that is not `main`, so a rollback by commit then
means a revert commit on `main` first.

**Terminal** (untested here; dry-run first)
```bash
cd ~/cma && git switch -q main && git pull -q --ff-only && git switch -q --detach <previous good commit> && bash docs/ingest/deploy.sh prod --front ingest.pulse4all.app --tenant pulse4all-subscriptions && git switch -q main
```
Expected: `image … exists (sha256:…); no build`, a new revision on the older tag, `ingress:
internal-and-cloud-load-balancing`, `health: {"ok":true,"version":"<older sha>"}`, `run.app: 404 (refused)`.
The `--secret` flags are not needed for a rollback: the accessor grants sit on the secrets, not on a revision.

### 3.3 The ingest jobs (untested here; dry-run first)

Which tag runs now:

**Terminal**
```bash
for j in ingest-sweep ingest-poll-forms ingest-poll-email ingest-reconcile ingest-outbox ingest-backfill; do echo "$j $(gcloud run jobs describe "$j" --project=p4a-cma-prod --region=europe-west4 --format='value(template.template.containers[0].image)')"; done
```
Expected: six lines, all the same `…/cma/ingest:<short sha>`.

Preferred: `bash docs/ingest/deploy.sh prod --jobs` from the previous good commit (the same `git switch`
pattern as 3.2), so the jobs' environment (`INGEST_VERSION`, pool size, the reconcile's look-back) matches
the image. Expected: `no build`, six job deploys, the schedules unchanged, `schedule ingest-outbox: none` or
`paused`.

Quick alternative, one job at a time (the job keeps its command, arguments and environment; only the image
changes, so `INGEST_VERSION` in its log lines keeps naming the newer sha until the script runs again):

**Terminal**
```bash
gcloud run jobs update ingest-sweep --project=p4a-cma-prod --region=europe-west4 --image=europe-west4-docker.pkg.dev/p4a-cma-prod/cma/ingest:<previous short sha>
```
Expected: `Job [ingest-sweep] has been updated.` Repeat for the other five. The scheduler keeps calling the
job; the next minute runs the older image.

### 3.4 The forgotten-day job

It runs the web image; its deploy is its rollback:

**Terminal**
```bash
cd ~/cma && bash docs/scheduler/deploy.sh prod <previous web short sha>
```
Expected: `job cma-close-forgotten-workdays on europe-west4-docker.pkg.dev/p4a-cma-prod/cma/web:<sha>, schedule cma-close-forgotten-workdays-hourly hourly (UTC) in p4a-cma-prod`.

### 3.5 A database migration

There is no rollback of a migration: migrations are forward-only (README, Release flow). A mistake is a new
pair (`db/<n>_<name>.sql` and its verify). Point-in-time recovery is the last resort, a Console operation
Martin decides with the data of the whole instance in mind (section 11 rehearses it); it is not part of a
routine rollback.

## 4. The System health page: late, silent, failing

Configuration → System health (`/configuration/health`, pull requests #152 and #153; addition 0008r) shows
six cards: this application, the ingest heartbeat, the sources, the jobs, the outbox and the documents of the
build. Every state is derived from what the jobs leave behind in `cma.sync_run`, `cma.ingest_event` and the
outbox; nothing on the page pings a vendor. The two heartbeat thresholds are tenant settings on Configuration
→ Exports (`health.heartbeat_fresh_seconds`, 120 by default; `health.heartbeat_late_seconds`, 900). Refresh
with the page's button, not by reloading in a loop.

| Card and state | What it means | First check | What to do |
|---|---|---|---|
| Application: probe `Slow` (over 200 ms) | one trivial read took long: the database is busy or far | section 10, weekly step 2 (connections); Console → Cloud SQL → `cma-prod-pg` → CPU and connections | a leak or a slow statement: find the login far above its ceiling; a pull request fix-speed and 0008q (#151) reduce the heaviest reads |
| Application: probe `No answer` | the service cannot reach Cloud SQL | `cma-web` app lines (section 8): a 503 `database_unavailable` | RUNBOOK 6: the instance running, the service account still Cloud SQL Client and Instance User; a Cloud SQL maintenance restart passes within minutes |
| Heartbeat `Late` (older than the fresh threshold) | the sweep's last `link_calls` run is 2 to 15 minutes old: an execution is slow or a minute was skipped | section 2 step 10 (sweep lines); the jobs card | one late beat after a vendor blip is normal; late for three refreshes in a row: treat as `Silent` |
| Heartbeat `Silent` (older than the late threshold) or `No run yet` | the sweep is not running: the schedule paused, the job failing at start, the image broken, or Cloud Scheduler not invoking | section 5 (`scheduler jobs list`: `ENABLED`, a recent `lastAttemptTime`); then the sweep's log with `severity>=WARNING` | resume a paused schedule; a failing start after a deploy: roll the jobs back (3.3); `token_unavailable` or `pepper_unavailable` in the log: a secret or its accessor (section 7) |
| Source `Needs attention` | events parked for review, a job of this connection failed in the last day and recovered, or an active connection heard nothing for a day | Configuration → Sources → the connection: parked count, last event; the reconcile's codes (section 8) | parked events need a person (the sweep gives up after `ingest.max_attempts`); a day without events on a weekday is a vendor subscription question: wait for the next 02:30 reconcile, which recreates Shopify subscriptions and re-activates the Aircall webhook, or run it by hand (section 5) |
| Source `Failing` | a job's last run for this connection failed, or never succeeded | the jobs card: the row's error code | `http_401`/`http_403`: a token, scope or secret (section 7); `rate_limited`: resolves itself; `account_mismatch` or `webhook_token_mismatch`: the connection's settings against the vendor's account (`docs/ingest/README.md`, Aircall, Shopify) |
| Source `Off` | the connection is inactive | Configuration → Sources | section 6 says what stopped and how it catches up |
| Job `Failed` | the last execution exited 1: at least one connection failed | the error code on the row; the job's log (section 8) | the next schedule is the retry; a daily or hourly job: run it by hand once (section 5) after the cause is gone |
| Job `Stuck` (running over 15 minutes) | an execution did not finish its run row (the task timeout is 10 minutes for the per-minute jobs, 60 for the reconcile) | Console → Cloud Run → Jobs → the job → executions | a killed execution leaves the row `running`; once fix-ingest-reliability is merged a second execution of the same job exits at once instead of piling up; the row ages out of the page's 30-day window |
| Job `Never ran` | no run row in 30 days | is the job expected? (`ingest-backfill` and `ingest-outbox` run by hand only) | for a scheduled job: section 5 |
| Outbox `needs_review` or `failed` rows | contact write-backs the outbox gave up on, or failed and waiting | Reports → Data quality: "Updates still waiting" (`outbox_pending`) and `writeback_parked` | `ingest-outbox` has no schedule since 0008h: a pending row older than ten minutes is expected until a schedule or a manual run exists; parked rows need a person (`docs/ingest/README.md`, Outbox) |

Every state is also a Studio question, counts and codes only:

**Studio (cma-prod-pg)**
```sql
set role cma_owner;
select job, connection_id, status, error, started_at, finished_at from cma.sync_run order by started_at desc limit 30;
reset role;
```
Expected: `link_calls`, `forms_poll` and `email_poll` rows every minute, `succeeded`; a `reconcile` row after
02:30 (03:30 once fix-ops is live); `close_forgotten_workdays` rows hourly once 0008r has run.

## 5. Pause and resume a Cloud Scheduler job

Names: `ingest-sweep`, `ingest-poll-forms`, `ingest-poll-email`, `ingest-reconcile`, `ingest-outbox` (paused
where it exists), `cma-close-forgotten-workdays-hourly`. All in location `europe-west4`.

**Terminal** (what runs today)
```bash
gcloud scheduler jobs list --project=p4a-cma-prod --location=europe-west4 --format='table(name.basename(),schedule,timeZone,state,lastAttemptTime)'
```
Expected: the three per-minute ingest schedules `* * * * *` and the reconcile `30 2 * * *` (`30 3 * * *` once
fix-ops is live), Europe/Amsterdam, `ENABLED`; `ingest-outbox` `PAUSED` or absent;
`cma-close-forgotten-workdays-hourly` `0 * * * *` `Etc/UTC` `ENABLED`; every `lastAttemptTime` recent.

**Terminal** (pause one; untested here; dry-run first, that is: the `list` above first)
```bash
gcloud scheduler jobs pause ingest-sweep --location=europe-west4 --project=p4a-cma-prod
```
Expected: the job listed as `PAUSED`. A paused schedule starts no execution; one already running finishes on
its own (task timeout 10 minutes; the reconcile 60).

**Terminal** (resume)
```bash
gcloud scheduler jobs resume ingest-sweep --location=europe-west4 --project=p4a-cma-prod
```
Expected: `ENABLED`, and a `sweep` log line within two minutes (section 2 step 10). A rerun of `deploy.sh prod
--jobs` also resumes the ingest schedules, so a pause does not survive a jobs deploy.

**Terminal** (run a job once by hand, for example after a pause longer than its schedule)
```bash
gcloud run jobs execute ingest-reconcile --project=p4a-cma-prod --region=europe-west4 --wait
```
Expected: the execution ends `succeeded`; its `reconcile` rows appear in Studio (section 4). The same form
runs `cma-close-forgotten-workdays`, which is idempotent and closes everything overdue.

What stops while each is paused, and how it catches up (`docs/ingest/README.md`, Jobs):

| Paused | Stops | Catching up |
|---|---|---|
| `ingest-sweep` | the retry of failed events, the second read of records without a contact, the hourly Aircall catalogs, `link_calls` (the heartbeat), the outbox guard; webhooks still land and are read back inline within their budget | on resume the sweep claims everything due; the nightly reconcile covers 26 hours |
| `ingest-poll-forms` | form submissions | the cursor continues where it stopped |
| `ingest-poll-email` | email engagements and inbox threads | the cursors continue |
| `ingest-reconcile` | the nightly 26-hour catch-up, the Aircall webhook check, the Shopify subscription check | run it by hand once; a gap longer than 26 hours needs a backfill (`ingest-backfill --args=--connection,<id>,--object,<type>,--from,<date>`; PROD_RUNBOOK 7.8, 8.8, 9.8) |
| `cma-close-forgotten-workdays-hourly` | the hourly close of days left open | idempotent: the next run or a manual execution closes everything overdue |

When to pause:

- A vendor incident (HubSpot, Aircall or Shopify answering 5xx or 429 for a long stretch): pause the three
  per-minute jobs so they stop knocking; the adapters already back off and nothing retries in a loop, so this
  is a courtesy, not a fix. Resume when the vendor is green; longer than 26 hours means a backfill afterwards.
- A bad ingest image: pause the three per-minute jobs, roll back (3.3), resume. Nothing is lost: events wait in
  `cma.ingest_event` as `received` or `failed`.
- The clock change of 24 to 25 October 2026 (03:00 CEST becomes 02:00 CET): the forgotten-day job runs hourly
  in UTC and closes a day only once the tenant's window end plus the grace has passed (Pulse4all 22:00 plus
  60 minutes), so the night's repeated hour changes nothing in it (the audit's DST review, 5.12: no finding
  above Low). The reconcile's 02:30 falls in the repeated hour; fix-ops moves it to 03:30. If fix-ops is not
  live by Saturday 24 October, run the reconcile by hand on Sunday morning with the command above and check
  one `reconcile` row per connection in Studio.

## 6. Switch a connection off and on

A connection is a row of `cma.integration_connection` (`hubspot`, `aircall`, `shopify`, `automation`) with a
status `active` or `inactive`. The Workspace changes it on Configuration → Sources
(`cma.set_connection_status(id, 'active' | 'inactive')`).

**Browser:** `https://workspace.pulse4all.app/configuration/sources` (`tenant.configure`) → the connection →
its status control → inactive → save.
Expected: the connection listed as inactive after a reload; on System health it shows `Off`.

What stops while it is inactive (`ingest/src/core/connection.mjs`, `ingest/src/server.mjs`):

- Webhooks are answered `404`, empty, nothing written: `cma.ingest_connection(key)` returns nothing for an
  inactive connection, exactly as for an unknown key, before any signature is read. The vendor sees a failed
  delivery and applies its own retry rules. What the repository documents: Shopify retries eight times over
  four hours and then deletes the subscription, which the nightly reconcile recreates (`subscriptions_recreated`)
  once the connection is active again; Aircall disables a webhook whose deliveries keep failing, and the
  reconcile re-activates it (`webhook_reactivated`). The automation route (`POST /automation/<key>`) answers
  `404` too, so the scenarios that send messages to agents error until the connection is back.
- The jobs skip it: only `status = 'active'` connections are served, so the sweep, the polls, the reconcile and
  a backfill naming it do nothing for it.
- Nothing is deleted: records, events and cursors stay; switching back on resumes from the cursors. Off for
  longer than 26 hours means a backfill `--from` the day it was switched off.

**Browser:** the same control → active → save. Then watch the next reconcile's rows for
`subscriptions_recreated` or `webhook_reactivated`: the expected repair, not errors.

Read-only check, ids and statuses only:

**Studio (cma-prod-pg)**
```sql
set role cma_owner;
select id, name, adapter, kind, status from cma.integration_connection order by adapter, name;
reset role;
```
Expected: one row per connection, `status` as you set it. The key column is an identifier, not a secret, but it
stays in Studio: never in a record, a PR or a chat.

## 7. Rotate a secret

General rule (`ingest/src/core/secrets.mjs`): the service and the jobs read `versions/latest` of a secret by
name and cache the value for 5 minutes. A rotation is "add a new version", never an edit or a delete of the
secret itself; the old value stops being accepted at most 5 minutes later. The accessor grant sits on the
secret, so no deploy is needed. Store a value only with the `put_secret` function of PROD_RUNBOOK (hidden
prompt, never echoed, never in history) or generated and piped (`openssl rand … | gcloud secrets versions add
… --data-file=-`), never typed into a command line.

After every rotation, disable the older versions (**untested here; dry-run first**: `list` first):

**Terminal**
```bash
gcloud secrets versions list <secret name> --project=p4a-cma-prod
```
Expected: the versions, the newest `ENABLED`.

**Terminal**
```bash
gcloud secrets versions disable <older version number> --secret=<secret name> --project=p4a-cma-prod
```
Expected: the version `DISABLED`. Keep the newest two enabled for the 5-minute window, then disable the older.

| Secret name | What it is | How to rotate |
|---|---|---|
| `ingest-hubspot-subs-signing` | the client secret of the prod project app (the v3 signature of every webhook) | **Browser:** rotate it on the app's Auth tab (PROD_RUNBOOK 7.4). At once, **Terminal:** `put_secret p4a-cma-prod ingest-hubspot-subs-signing`. Between the two steps plus 5 minutes every webhook fails the signature (`authentication failed`, `signature_mismatch` in the service log); the vendor's retries and the nightly reconcile cover the gap |
| `ingest-hubspot-subs-token` | the app's static access token (read-backs, the jobs, `hubspot-owners.mjs`) | **Browser:** generate a new token on the install row (PROD_RUNBOOK 7.4). **Terminal:** `put_secret p4a-cma-prod ingest-hubspot-subs-token`, then the check of PROD_RUNBOOK 7.4 (the portal id and the account type, never the token). In the gap read-backs fail `http_401` and the sweep retries them |
| `ingest-aircall-subs-token` | the API key as one JSON line | **Browser:** Aircall dashboard, a new API key. **Terminal:** `put_secret p4a-cma-prod ingest-aircall-subs-token` with the new pair as that JSON line; the check of PROD_RUNBOOK 8.2; then delete the old key in Aircall |
| `ingest-aircall-subs-signing` | the webhook's token, shown by Aircall only when the webhook is created | not a value you choose: rotating it means deleting and creating the webhook with `docs/ingest/aircall-webhook.mjs` (`--list`, `--delete <id>`, then the create form of PROD_RUNBOOK 8.4, which stores the new token as a new version itself); then Configuration → Sources → the Aircall connection → `webhook_id` = the new id |
| `ingest-shopify-app-signing` | the app's client secret, shared by its stores (the signature and the token grant) | PROD_RUNBOOK 9.3: rotate in the Dev Dashboard, then `put_secret p4a-cma-prod ingest-shopify-app-signing`; Shopify may sign with the old one for up to an hour and retries a refused delivery (`docs/ingest/README.md`, Shopify) |
| `ingest-automation-subs-secret` | the bearer of `POST /automation/<key>` | no dual acceptance. **Terminal:** `openssl rand -base64 32 \| tr -d '\n' \| gcloud secrets versions add ingest-automation-subs-secret --project=p4a-cma-prod --data-file=-`. **Browser:** each scenario's HTTP module gets the new bearer (read it once with `gcloud secrets versions access latest --secret=ingest-automation-subs-secret --project=p4a-cma-prod`, then `clear`). Until then the scenarios get `401` |
| `ingest-hash-pepper-pulse4all-subscriptions` (dev also the invest one) | the pepper of every stored phone hash | never rotated: a new pepper makes every new hash unequal to every stored one (calls to CRM calls, repeat callers, orders to calls). Only after a suspected disclosure, as a planned project with a full re-read through the backfills |
| `cma-prod-postgres-password` | the `postgres` login | RUNBOOK 10a, unchanged (the `-Ka7` suffix, the `&&` chain, the `unset`) |
| `cma-prod-bq-reader-password` | the `bq_reader` login (prod not set yet, README Data model: foundation) | RUNBOOK 10a's pattern with `bq_reader`; then **Browser:** BigQuery → External connections → the prod connection → the new password (**untested here; dry-run first**) |
| NocoDB's two secrets (`docs/nocodb/service.template.yaml`) | NocoDB's own JWT secret and encryption key | not rotated by a version add: a new encryption key makes the stored source credentials unreadable, so a rotation is a NocoDB re-setup (`docs/nocodb/README.md`) |

The service accounts have no keys (IAM database authentication; README Decision log) and the IAP client is
Google-managed: nothing to rotate there. Secret Manager data access logging is on in both projects since 13
October 2026, so every read of a secret value is in the audit log with who read it.

## 8. Where the logs are

A request log line can hold a URL with a token in it (`/invite/<token>`; `?as=` in dev), and Cloud Run's
request log keeps the URL (README Decision log, 12 October 2026). So: read app logs only (`textPayload` for
`cma-web`, `jsonPayload.*` for `cma-ingest` and the jobs), keep request logs for the status-code histogram
only (`httpRequest.status`, never `httpRequest.requestUrl`), and never paste a request log line into a record
or a chat. The `_Default` bucket keeps 30 days.

**Terminal** (`cma-web` app lines; untested here; dry-run first. RUNBOOK 6's `services logs read` also works
but prints request lines)
```bash
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="cma-web" AND textPayload:"[cma-"' --project=p4a-cma-prod --freshness=1h --limit=50 --format='value(timestamp,textPayload)'
```
Expected: only `[cma-data]`, `[cma-db]`, `[cma-api]` lines, or nothing. A 503 `database_unavailable` means
the service could not reach Cloud SQL (RUNBOOK 6).

**Terminal** (`cma-ingest` app lines: connection id, adapter, counts, durations, codes; never a payload)
```bash
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="cma-ingest" AND jsonPayload.message:*' --project=p4a-cma-prod --freshness=1h --limit=30 --format='value(timestamp,jsonPayload.message,jsonPayload.code,jsonPayload.new,jsonPayload.ms)'
```
Expected: `webhook` lines with `new` and `ms`; `authentication failed` lines are strangers or a rotation in
progress (section 7).

**Terminal** (the sweep's outbox warnings of the last day; `docs/a5-audits/MORNING_RUNBOOK.md` step 7)
```bash
gcloud logging read 'resource.type=cloud_run_job AND resource.labels.job_name=ingest-sweep AND jsonPayload.code="outbox_pending"' --project=p4a-cma-prod --freshness=1d --limit=10 --format='value(timestamp,jsonPayload.connection,jsonPayload.outboxPending)'
```
Expected: nothing.

**Terminal** (any job's last lines; `docs/ingest/deploy.sh` prints this form)
```bash
gcloud logging read 'resource.type=cloud_run_job AND resource.labels.job_name=ingest-reconcile' --project=p4a-cma-prod --freshness=1d --limit=20 --format='value(timestamp,jsonPayload.message,jsonPayload.code)'
```
Expected: the nightly run's lines. `subscriptions_recreated` and `webhook_reactivated` are repairs;
`webhook_token_mismatch`, `account_mismatch`, `token_unavailable` and `pepper_unavailable` need a person.

**Terminal** (the forgotten-day job; `docs/scheduler/deploy.sh` prints this form)
```bash
gcloud logging read 'resource.type=cloud_run_job AND resource.labels.job_name=cma-close-forgotten-workdays' --project=p4a-cma-prod --freshness=1d --limit=20 --format='value(timestamp,textPayload)'
```
Expected: one short line per hourly run, most of them closing nothing.

**Terminal** (status codes of the public ingest endpoint, no URLs; PROD_RUNBOOK 7.9)
```bash
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="cma-ingest" AND httpRequest.status>0' --project=p4a-cma-prod --freshness=1d --format='value(httpRequest.status)' | sort | uniq -c
```
Expected: mostly `200`; a few `401` or `404` are strangers; `500` points at the database or a secret. Cloud
Armor's `429`s never reach this log (answered at the load balancer); they show only in the alert of section 9.

**Browser:** Console → Logging → Logs Explorer (`p4a-cma-prod`) for anything else: filter on the resource and
on `jsonPayload.message` or `textPayload`, and leave the request log (`logName` ending in `requests`) out of a
saved query. Build logs: RUNBOOK 3.

## 9. Alerts: today, and the set to create

Today one policy exists, `cma-ingest 429` (Console → Monitoring → Alerting → Policies): the load balancer's
request count for `cma-ingest-backend` with `response_code = 429`, summed over 5 minutes, firing above 0,
auto-closing after 30 minutes, to the email channel "CMA ingest alerts" (`docs/ingest/alert.sh`; the address
is in the channel only; a rerun of `alert.sh prod --email <alert address>` updates it, never duplicates it).
Budget alerts email the billing admins (dev €75, prod €150 per month; README Environments and infrastructure).
Secret Manager data access logging is on. Nothing watches errors, latency, the jobs, the database or the
certificates (audit finding INFRA-06).

The set to create, all in `p4a-cma-prod`, all to the existing channel "CMA ingest alerts" (or a second email
channel for the Workspace, if Martin prefers two). The thresholds are starting points; each policy carries a
documentation text that names the first check. Create them in the Console as below, one at a time, and
check the list after each; the equivalent JSON for `gcloud monitoring policies create` is in the audit's
infrastructure findings (INFRA-06), to be folded into `docs/ingest/alert.sh` as a table of policies with
`--only <name>` and its existing `--dry-run` once each has been created once by hand.

**Terminal** (before and after each policy)
```bash
gcloud monitoring policies list --project=p4a-cma-prod --format='table(displayName,enabled)'
```
Expected before: one row, `cma-ingest 429  True`. After each step below: one more row with the name given.

**Browser:** Console → Monitoring → Alerting → Create policy, for each of the following. Expected after Save:
the policy listed, enabled, with the channel attached; no incident open (a new policy on a healthy system
stays quiet).

| Policy name | Metric and filter | Condition | Documentation text (the first check) |
|---|---|---|---|
| `cma-web-backend 5xx ratio` and `cma-ingest-backend 5xx ratio` | `loadbalancing.googleapis.com/https/request_count`, resource `https_lb_rule`, `backend_target_name` = the backend, numerator `response_code_class = 500`, denominator all codes | ratio above 2 % over a 5-minute window, for 5 minutes; auto-close 30 minutes | revisions list, the app lines (section 8), Cloud SQL connections; RUNBOOK 10 when a deploy caused it |
| `cma-web-backend p95 latency` and `cma-ingest-backend p95 latency` | `loadbalancing.googleapis.com/https/backend_latencies` for the backend, aligner delta, reducer 95th percentile | web above 2000 ms, ingest above 5000 ms, for 10 minutes | Cloud SQL CPU and connections first, then the slow routes |
| `cma jobs failing` | `run.googleapis.com/job/completed_execution_count`, resource `cloud_run_job`, `result = failed`, grouped by `job_name` | the per-minute jobs (`ingest-sweep`, `ingest-poll-forms`, `ingest-poll-email`): 3 or more failed executions in 15 minutes; `ingest-reconcile` and `cma-close-forgotten-workdays`: one failed execution in an hour | the job's log with `severity>=WARNING` (section 8); the codes in `docs/ingest/README.md`, Jobs |
| `cma-prod-pg capacity` | `cloudsql.googleapis.com/database/cpu/utilization`, `memory/utilization`, `disk/utilization`, `network/connections` for `p4a-cma-prod:cma-prod-pg` | CPU above 80 % for 10 minutes; memory above 90 % for 10 minutes; disk above 80 % for an hour; connections above 80 for 5 minutes (the budget's ceiling is 86 of 93 usable; README, Database connection budget) | the `pg_stat_activity` count per login (section 10, weekly step 2); raising `max_connections` is rejected (Decision log, 15 October 2026) |
| `cma front reachability and certificates` | two uptime checks first (Monitoring → Uptime checks): `ingest.pulse4all.app/health`, HTTPS, every 5 minutes, status 2xx, SSL validation on; `workspace.pulse4all.app/`, status 2xx or 3xx (IAP's redirect is the right "alive" answer there). Then `monitoring.googleapis.com/uptime_check/check_passed` and `time_until_ssl_cert_expires` | the check failing from two or more regions for 10 minutes; a certificate under 15 days from expiry | `gcloud compute ssl-certificates describe cma-web-cert` or `cma-ingest-cert` `--global` (`managed.status`, `managed.domainStatus`); the DNS A record |

Six checker regions once every 5 minutes stay far under Cloud Armor's 600 requests per minute per IP. The
p95 per route (the SLOs S2 and S3 of READINESS) needs the request timing log line and a log-based distribution
metric the pull request fix-speed adds; until then the backend latency above is the one latency signal.

## 10. Daily and weekly checks

### Daily (five minutes, in the morning)

1. **Browser:** section 2 step 1 (System health), or steps 2 to 5 of section 2 until the page is live.
2. **Browser:** Reports → Data quality (`/reports/data-quality`).
   Expected: the rows as yesterday; no "Updates still waiting" count and no parked write-backs; tickets without
   owner or market, unlinked task owners and shop customers without a contact not jumping. Then Configuration →
   Sources → each connection: events in the last 24 hours above 0 on a working day, parked events at 0 (each
   parked event needs a person).
3. **Terminal:** the sweep's `outbox_pending` warnings and the reconcile's codes (section 8).
   Expected: nothing, and a nightly run without `webhook_*`, `account_mismatch` or `*_unavailable` codes.
4. **Terminal:** the scheduler's last attempts (section 5, the `list` command).
   Expected: every schedule `ENABLED`, `lastAttemptTime` within the last hour (the forgotten-day job) or
   minute (the ingest jobs).
5. **Browser:** Time → Team hours, yesterday: days marked as needing correction (the forgotten-day close) are
   the manager's to review today.

### Weekly (fifteen minutes, Monday)

1. **Browser:** Console → Billing → Budgets & alerts, and the month-to-date cost of `p4a-cma-prod` and
   `p4a-cma-dev`. Expected: inside the budgets (prod €150, dev €75); the first full month on the dedicated
   core (the October bill) decides whether prod's budget is raised (README Environments and infrastructure).
2. **Studio (cma-prod-pg)**, the connection budget (`max_connections` 100, 93 usable):
   ```sql
   select coalesce(usename, '(background)') as login, coalesce(datname, '') as database, count(*) as connections
   from pg_stat_activity group by 1, 2 order by 3 desc;
   ```
   Expected: `cma-web@…` at most 20 and `cma-ingest@…` at most 25 (and only while busy), `cma-nocodb@…` at
   most 6, `cloudsqladmin` a few, your own login, the background processes. A login far above its ceiling is a
   leak.
3. **Terminal:** backups and the instance (**untested here; dry-run first**: the field names are gcloud's
   documented ones, check `--help`).
   ```bash
   gcloud sql backups list --instance=cma-prod-pg --project=p4a-cma-prod --limit=8 --format='table(windowStartTime.date("%d %b %H:%M"),type,status)'
   ```
   Expected: one `AUTOMATED` `SUCCESSFUL` backup per day.
   ```bash
   gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format='value(state,settings.availabilityType,settings.backupConfiguration.enabled,settings.backupConfiguration.pointInTimeRecoveryEnabled)'
   ```
   Expected: `RUNNABLE REGIONAL True True`. The maintenance window is week 2, Sunday 02:00 UTC in prod (week 1
   in dev); Google announces an update in the Console.
4. **Terminal:** certificates and the alert policies.
   ```bash
   gcloud compute ssl-certificates list --project=p4a-cma-prod --global --format='table(name,managed.status,managed.domainStatus,expireTime.date("%d %b %Y"))'
   ```
   Expected: `cma-web-cert` and `cma-ingest-cert` `ACTIVE`, expiry weeks away (Google renews them). Then the
   `policies list` of section 9. Expected: every policy of section 9 `True`.
5. **Terminal:** dependencies, on `main`. The build prints no audit summary (`cloudbuild.yaml` has no audit
   step; the Dockerfiles install with `--no-audit`).
   ```bash
   cd ~/cma/web && npm audit --omit=dev 2>&1 | tail -3; cd ~/cma/ingest && npm audit --omit=dev 2>&1 | tail -3
   ```
   Expected: `found 0 vulnerabilities` for what ships; the known high advisories live under
   `eslint-config-next` (a devDependency; README Open decisions) and show only without `--omit=dev`. Never
   `npm audit fix --force`. Once fix-ops is merged, Dependabot opens one grouped minor-and-patch pull request
   per project per month; a major stays by hand.
6. **Browser:** until each is settled: Admin console → Security → 2-Step Verification, the agents' unit
   (README Open decisions; READINESS, gates); GitHub → the repository's ruleset on `main` still requires a
   pull request.

## 11. Restore drill (quarterly; dev first, then prod)

Backups and point-in-time recovery are configured and confirmed before every prod migration (README, Release
flow), but no restore has ever been performed (audit finding INFRA-07). High availability covers a zone
failure; a bad migration, an `update` without a `where` or a dropped table is what point-in-time recovery is
for, and the first time should not be under pressure. The drill clones the instance to a point in time,
checks it, and deletes the clone the same hour. A prod clone holds real staff data: Martin alone, from the
Chromebook, deleted the same hour. All of it **untested here; dry-run first**; the dev run is the dry run for
prod. Cloud SQL has no dry run for a clone.

1. **Terminal** (clone dev to ten minutes ago; 5 to 15 minutes, estimated)
   ```bash
   ts=$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ); echo "$ts"; gcloud sql instances clone cma-dev-pg cma-dev-pg-drill --project=p4a-cma-dev --point-in-time="$ts"
   ```
   Expected: the timestamp, then an operation that ends with `cma-dev-pg-drill` listed `RUNNABLE` by
   `gcloud sql instances list --project=p4a-cma-dev`. The clone carries the source's flags, databases and
   users (IAM users included, expected from Cloud SQL's clone semantics), so your own IAM login works in
   Studio on it.
2. **Studio (cma-dev-pg-drill)**, counts only:
   ```sql
   set role cma_owner;
   select (select count(*) from cma.tenant) as tenants, (select count(*) from cma.app_user) as users, (select max(recorded_at) from cma.ingest_event) as last_event;
   reset role;
   ```
   Expected: the counts `cma-dev-pg` had at the timestamp, `last_event` at or before it. Then run
   `db/04_verify.sql` as it is and the newest verify script. Expected: the PASS lines the dev records show.
3. **Terminal** (delete the clone the same hour; deletion protection comes along with the clone)
   ```bash
   gcloud sql instances patch cma-dev-pg-drill --project=p4a-cma-dev --no-deletion-protection --quiet && gcloud sql instances delete cma-dev-pg-drill --project=p4a-cma-dev --quiet && gcloud sql instances list --project=p4a-cma-dev --format='value(name)'
   ```
   Expected: `Deleted [...cma-dev-pg-drill]` and the list shows `cma-dev-pg` only. Cost: the dev tier for about
   an hour, a few cents; a prod clone (`db-custom-1-3840`, regional) for an hour, under one euro (estimated).
4. **File** `records/restore-drill-<YYYY-MM-DD>/README.md`, written from Martin's report only: the
   environment, the clone command's start and end times, the counts seen and whether they matched, the verify
   verdicts, the delete time, the recovery time observed (clone command to verified database), what to change
   in this section, the next drill's quarter. No secret, no personal data, no invented value.
5. **File** README: a Decision log row ("restore drill every quarter, dev then prod; recorded in
   `records/restore-drill-<date>`") and a sentence in Release flow next to "confirm point-in-time recovery is on".

The prod run is the same with `cma-prod-pg`, `cma-prod-pg-drill` and `p4a-cma-prod`, on a quiet hour, and it
is the one that proves the recovery time that matters.

## 12. Who is contacted (roles)

| Situation | First | Then |
|---|---|---|
| The Workspace does not load, a deploy went wrong, data looks wrong | Martin (owner of the CMA, the Google Cloud projects and the repository) | Martin decides on a rollback (section 3) and tells the call center manager |
| Agents cannot work in the Workspace | the call center manager: Plan B applies (`docs/PLAN_B.md`) | the manager tells Martin |
| A question of data protection, retention, employee monitoring, a possible disclosure of personal data | compliance and data protection, through Martin | Martin writes the outcome in the Decision log |
| A Google Cloud outage or a Cloud SQL, Cloud Run, IAP or load balancer fault that is not ours | Google Cloud support through the Console (Support → Cases) and the status page, by Martin | |
| HubSpot, Aircall or Shopify not delivering | the vendor's status page first; the data catches up by itself (sections 5 and 6) | the vendor's support, by Martin or the team member who owns that account |
| A finding about figures (hours, pay, KPIs) | the call center manager for hours and corrections; the head of call center for the KPIs | Martin |

No phone numbers or addresses here: the team's directory holds them.

## 13. Prod-only cautions

- Terminal work against prod runs from the Chromebook only; the Linux machine is not used for prod (README
  Environments and infrastructure, 16 October 2026). Cloud Shell is no longer used; older docs that say "Cloud
  Shell" mean the Chromebook terminal.
- A query that returns customer rows runs in Studio, never in the terminal; the terminal's proxy runs only
  `db/` scripts and verifiers whose output is schema, counts and ids (README, Where a command runs).
- Console changes to `cma-ingest` are emergency fixes only, and they set exactly the values `deploy.sh` sets
  (ingress `internal-and-cloud-load-balancing`, `INGEST_PUBLIC_URLS` with `https://ingest.pulse4all.app`
  first): the next `deploy.sh prod --front …` replaces every environment variable anyway (README Decision log,
  16 October 2026).
- Never edit `cma-web`'s environment in the Console: it comes from `cloudbuild.yaml` plus the trigger's
  substitutions, and the next build undoes a Console edit (RUNBOOK 9). Once #155 is live, `min-instances=1`,
  the startup probe and the CPU boost are in the file as well.
- Never a prod service deploy of the ingest without `--front ingest.pulse4all.app`; the script refuses it since
  16 October 2026 (and a non-`main` checkout once fix-ops is live), so a refusal is the guard working.
- Dev first, prod from the same commit: a prod deploy that builds is a sign dev was skipped.
- Never push to `main`; it accepts pull requests only, Martin squash-merges, and a merge touching `web/**` or
  `cloudbuild.yaml` deploys prod at once (the repository's working rules).
- No secret value, personal id, email address, phone number or hash value in a record, a PR, a chat or a
  screenshot; secret names only. Records hold values from real runs only, written from Martin's report.
- Migrations are forward-only; a mistake is a new pair, never an edit of one that has run.
