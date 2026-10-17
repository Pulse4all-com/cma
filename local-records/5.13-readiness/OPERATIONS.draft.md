# OPERATIONS (draft for docs/OPERATIONS.md): running the CMA in production

Draft written on 17 October 2026 by the readiness subagent of the full IT audit, from the repository only
(`docs/RUNBOOK.md`, `docs/ingest/README.md`, `docs/ingest/PROD_RUNBOOK.md`, `docs/ingest/deploy.sh`,
`docs/scheduler/deploy.sh`, `docs/ingest/alert.sh`, `docs/signed-out/README.md`, `docs/nocodb/README.md`,
`records/ingest-front-incident-2026-10-16`, `docs/a5-audits/MORNING_RUNBOOK.md`, README Architecture,
Environments, Release flow, Authentication, Open decisions; the code in `ingest/src`, `web/src`,
`cloudbuild.yaml`). Nothing here was run against prod. The lead reviews and places it.

Conventions (README, Where a command runs; CLAUDE.md, Instructions for Martin):

- Every block is labelled **Terminal** (Martin's own Linux terminal; for prod **the Chromebook only**, README
  line 328), **Studio** (Cloud SQL Studio, the instance named), **Browser** or **File**. SQL and shell never
  share a block. One step at a time, each with what you should see.
- `--project` is always explicit (`p4a-cma-prod`, `p4a-cma-dev`), the region is `europe-west4`.
- A command marked **untested here; dry-run first** has not been seen run in the docs or the records. Before a
  real run, read its `--help`, run the read-only form first (`list`, `describe`), and on anything that changes
  prod prefer the script in `docs/` that owns the resource.
- Secret NAMES appear here; a secret VALUE never appears anywhere: not in a command's output you keep, not
  in a screenshot, not in a record. After `gcloud secrets versions access`, run `clear` (RUNBOOK 10a).
- A query that can return customer rows runs in Studio, never through the Auth Proxy in the terminal.

The moving parts, for reference (from the scripts):

| Part | Where | Deployed by | Image |
|---|---|---|---|
| `cma-web` (the Workspace, `workspace.pulse4all.app`) | Cloud Run service, `p4a-cma-prod` | Cloud Build trigger `cma-web-main` on every merge to `main` touching `web/**` or `cloudbuild.yaml` | `europe-west4-docker.pkg.dev/p4a-cma-prod/cma/web:<short sha>` |
| `cma-ingest` (`ingest.pulse4all.app`) | Cloud Run service | `bash docs/ingest/deploy.sh prod --front ingest.pulse4all.app …` by hand, after dev | `…/cma/ingest:<short sha>` (the last commit that touched `ingest/`) |
| `ingest-sweep`, `ingest-poll-forms`, `ingest-poll-email`, `ingest-reconcile`, `ingest-outbox`, `ingest-backfill` | Cloud Run jobs | `bash docs/ingest/deploy.sh prod --jobs` | the same ingest image |
| `cma-close-forgotten-workdays` | Cloud Run job | `bash docs/scheduler/deploy.sh prod <short sha>` | the web image |
| Cloud Scheduler: `ingest-sweep`, `ingest-poll-forms`, `ingest-poll-email` (every minute), `ingest-reconcile` (02:30), all Europe/Amsterdam; `ingest-outbox` paused or absent; `cma-close-forgotten-workdays-hourly` (`0 * * * *`, UTC) | `europe-west4` | the two deploy scripts | |
| `cma-nocodb` | Cloud Run service behind IAP | `docs/nocodb/deploy.sh prod` | pinned NocoDB image |
| Load balancer `cma-web-urlmap`, backends `cma-web-backend` (IAP), `cma-ingest-backend` (Cloud Armor `cma-ingest-armor`), `cma-signed-out-backend` (bucket) | global | `docs/ingest/front.sh`, `docs/signed-out/deploy.sh` | |
| Database `cma-prod-pg` (PostgreSQL 18, HA, PITR, daily backups) | Cloud SQL, `europe-west4` | migrations by hand in Studio | |

---

## 1. The five-minute prod check (after every deploy; a standing step)

Run it after every merge that built prod, after every `deploy.sh prod` (service or jobs), and after any
Console change. Stop at the first step that does not look right and go to section 2 (roll back).

0. **Browser** (once the System health page exists: Configuration → System health, this audit's increment).
   Open it first. Good: every row green or "as expected"; the version row shows the short sha you just
   merged; the jobs' last runs are minutes old; no parked events. Until the page exists, start at step 1.

1. **Terminal** (the short sha that should be live; RUNBOOK section 3)
   ```bash
   cd ~/cma && git switch -q main && git pull -q --ff-only && git log --oneline -1 && gcloud builds list --project=p4a-cma-prod --region=europe-west4 --limit=1 --format="table(status,substitutions.SHORT_SHA,createTime.date('%H:%M'))"
   ```
   Expected: the merge commit, then `SUCCESS` with the same 7-character short sha.

2. **Browser:** `https://workspace.pulse4all.app/` with your own account. Sign in through IAP (one account:
   silent; several: Google's chooser).
   Expected: Welcome, your name in the top bar; bottom left of the rail, under the shortcuts line, the line
   `Version <short sha>` with the sha of step 1 (`web/src/components/Shell.tsx`; `config.version` is
   `CMA_VERSION`, set from `SHORT_SHA` by `cloudbuild.yaml`). A different sha means traffic still goes to an
   older revision or the build has not deployed yet; wait two minutes and reload once.

3. **Browser:** `https://workspace.pulse4all.app/api/health` in the same signed-in browser (the route sits
   behind IAP like every page; `curl` without an IAP session answers 302 to Google, which is right).
   Expected: `{"status":"ok","version":"<short sha>","auth":"iap","data":"api"}`. `"auth"` must be `iap`
   and `"data"` must be `api`; anything else is a wrong trigger substitution (RUNBOOK section 9): stop and
   roll back.

4. **Browser:** `https://ingest.pulse4all.app/health` (no IAP in front of the ingest).
   Expected: `{"ok":true,"version":"<ingest short sha>"}`, where the sha is the one `deploy.sh` printed
   (the last commit under `ingest/`, not necessarily the web sha). After an ingest deploy also:
   **Terminal**
   ```bash
   curl -sS -o /dev/null -w "%{http_code}\n" "$(gcloud run services describe cma-ingest --project=p4a-cma-prod --region=europe-west4 --format='value(status.url)')/health"
   ```
   Expected: `404` (the `run.app` address refused by the ingress; PROD_RUNBOOK 7.1). A `200` here is the
   incident of 16 October 2026: rerun `deploy.sh prod --front ingest.pulse4all.app …`.

5. **Browser:** one read: Time → Team hours (`/team/hours`), today.
   Expected: the day's rows for the people clocked in, totals at the bottom, no error banner, the page
   within a second or two.

6. **Browser:** one write, with your own account only: Time → My day (`/day`): change your status to another
   status, then back to the one you had.
   Expected: the status chip and the "since" time change at once both times; no error. The two changes are
   real events on your own day and stay in the audit log, which is fine; never do this on a colleague's
   account or device (README, Authentication). If your account has no My day (no `workday.own`), skip this
   step and say so in the record.

7. **Browser:** Live → Live board (`/live/board`).
   Expected: everyone clocked in with their status and a running clock; your own status change of step 6 is
   visible within the board's refresh; the inbound tiles have figures or "no calls yet", not an error.

8. **Terminal** (the jobs still run: the sweep logged within the last few minutes)
   ```bash
   gcloud logging read 'resource.type=cloud_run_job AND resource.labels.job_name=ingest-sweep AND jsonPayload.message="sweep"' --project=p4a-cma-prod --freshness=10m --limit=3 --format='value(timestamp,jsonPayload.processed,jsonPayload.failed,jsonPayload.outboxPending)'
   ```
   Expected: three lines, the newest at most two minutes old, `failed` 0 and `outboxPending` 0 (A5 runbook
   step 3 and 4).

Record what you saw (shas, times, counts; no names, no URLs with tokens) in `records/` only when it is a
release record.

---

## 2. Roll back

### 2.1 `cma-web` (RUNBOOK section 10; seen in the docs)

Fastest: traffic to the previous revision, in seconds, without a build.

**Terminal**
```bash
gcloud run revisions list --service=cma-web --project=p4a-cma-prod --region=europe-west4 --limit=5 --format="table(metadata.name,metadata.creationTimestamp.date('%d %b %H:%M'),status.conditions[0].status)"
```
Expected: five revisions, newest first, `True` in the last column for the healthy ones. The previous good
one is the second row.

**Terminal**
```bash
gcloud run services update-traffic cma-web --project=p4a-cma-prod --region=europe-west4 --to-revisions=<previous revision>=100
```
Expected: `Traffic: 100% <previous revision>`. Then step 2 and 3 of section 1: the `Version` line and
`/api/health` show the older sha.

Then fix forward with a new commit. The next successful build sends traffic to the new revision again; by
hand that is `gcloud run services update-traffic cma-web … --to-latest`. Note: a revision carries its own
environment (the trigger substitutions of its build), so rolling back also rolls back `_LOGOUT_TARGET`,
`_DATA_MODE` and the pool size to what that revision had. A failed build deploys nothing: prod keeps the
previous version (RUNBOOK 3).

### 2.2 `cma-ingest` (untested here; dry-run first)

**Terminal**
```bash
gcloud run revisions list --service=cma-ingest --project=p4a-cma-prod --region=europe-west4 --limit=5 --format="table(metadata.name,metadata.creationTimestamp.date('%d %b %H:%M'),status.conditions[0].status,spec.containers[0].image.basename())"
```
Expected: the revisions with their image tags (`ingest:<short sha>`). Never pick `cma-ingest-00008` or
any revision made before 16 October 2026 without `--front` (its `INGEST_PUBLIC_URLS` lacks the public host:
`records/ingest-front-incident-2026-10-16`). The ingress is a service-level setting and stays
`internal-and-cloud-load-balancing` whichever revision serves.

**Terminal**
```bash
gcloud run services update-traffic cma-ingest --project=p4a-cma-prod --region=europe-west4 --to-revisions=<previous revision>=100
```
Expected: `Traffic: 100% <previous revision>`; then `https://ingest.pulse4all.app/health` shows that
revision's sha, and the `run.app` check of section 1 step 4 still answers `404`.

Cleaner, when the previous commit is known: deploy that commit again with the script, so every flag the
script sets (ingress, public URLs, budgets, boost) is set as the script sets it, and the image is pulled by
tag without a build (**untested here; dry-run first**; `deploy.sh` requires a clean `ingest/` tree and
refuses a prod service deploy without `--front`):

**Terminal**
```bash
cd ~/cma && git switch -q main && git pull -q --ff-only && git switch -q --detach <previous good commit> && bash docs/ingest/deploy.sh prod --front ingest.pulse4all.app --tenant pulse4all-subscriptions && git switch -q main
```
Expected: `image … exists (sha256:…); no build`, a new revision on the older tag, `ingress:
internal-and-cloud-load-balancing`, `health: {"ok":true,"version":"<older sha>"}`, `run.app: 404 (refused)`.
The `--secret` flags are not needed for a rollback (the accessor grants sit on the secrets, not on a revision).

### 2.3 The ingest jobs (untested here; dry-run first)

A job runs the image tag `deploy.sh --jobs` set (`--image="$IMAGE"` with `INGEST_VERSION=<sha>` in its
environment). The six jobs are `ingest-sweep`, `ingest-poll-forms`, `ingest-poll-email`, `ingest-reconcile`,
`ingest-outbox` and `ingest-backfill`.

Which tag runs now:

**Terminal**
```bash
for j in ingest-sweep ingest-poll-forms ingest-poll-email ingest-reconcile ingest-outbox ingest-backfill; do echo "$j $(gcloud run jobs describe "$j" --project=p4a-cma-prod --region=europe-west4 --format='value(template.template.containers[0].image)')"; done
```
Expected: six lines, all the same `…/cma/ingest:<short sha>`.

Preferred: the script from the previous commit, so the jobs' environment (`INGEST_VERSION`, pool size, the
reconcile's look-back) matches the image:

**Terminal**
```bash
cd ~/cma && git switch -q --detach <previous good commit> && bash docs/ingest/deploy.sh prod --jobs && git switch -q main
```
Expected: `image … exists …; no build`, six `gcloud run jobs deploy` results, the four schedules unchanged,
`schedule ingest-outbox: none` or `paused`.

Quick alternative, one job at a time (keeps the job's command, arguments and environment; only the image
changes, so `INGEST_VERSION` in its log lines keeps naming the newer sha until the script runs again):

**Terminal**
```bash
gcloud run jobs update ingest-sweep --project=p4a-cma-prod --region=europe-west4 --image=europe-west4-docker.pkg.dev/p4a-cma-prod/cma/ingest:<previous short sha>
```
Expected: `Job [ingest-sweep] has been updated.` Repeat for the other five. The scheduler keeps calling the
job; the next minute runs the older image.

### 2.4 The forgotten-day job (`cma-close-forgotten-workdays`)

It runs the web image. Its deploy is also its rollback:

**Terminal**
```bash
cd ~/cma && bash docs/scheduler/deploy.sh prod <previous web short sha>
```
Expected: `job cma-close-forgotten-workdays on europe-west4-docker.pkg.dev/p4a-cma-prod/cma/web:<sha>,
schedule cma-close-forgotten-workdays-hourly hourly (UTC) in p4a-cma-prod`.

### 2.5 A database migration

There is no rollback of a migration: migrations are forward-only (README, Release flow). A mistake is a new
migration pair. Point-in-time recovery is the last resort and is a Console operation Martin decides with the
data of the whole instance in mind; it is not part of a routine rollback.

---

## 3. Pause and resume a Cloud Scheduler job

Names (from `docs/ingest/deploy.sh` and `docs/scheduler/deploy.sh`): `ingest-sweep`, `ingest-poll-forms`,
`ingest-poll-email`, `ingest-reconcile`, `ingest-outbox` (already paused where it exists),
`cma-close-forgotten-workdays-hourly`. All in location `europe-west4`.

**Terminal** (what runs today)
```bash
gcloud scheduler jobs list --project=p4a-cma-prod --location=europe-west4 --format='table(name.basename(),schedule,timeZone,state,lastAttemptTime)'
```
Expected: the four ingest schedules `ENABLED` (`* * * * *` three times, `30 2 * * *`, Europe/Amsterdam),
`ingest-outbox` `PAUSED` or absent, `cma-close-forgotten-workdays-hourly` `0 * * * *` `Etc/UTC` `ENABLED`,
each `lastAttemptTime` recent.

**Terminal** (pause one; untested here; dry-run first, that is: run the `describe` above first)
```bash
gcloud scheduler jobs pause ingest-sweep --location=europe-west4 --project=p4a-cma-prod
```
Expected: the job listed as `PAUSED`. A paused schedule starts no execution; an execution already running
finishes on its own (the sweep's task timeout is 10 minutes, the reconcile's 60).

**Terminal** (resume)
```bash
gcloud scheduler jobs resume ingest-sweep --location=europe-west4 --project=p4a-cma-prod
```
Expected: `ENABLED`, and a `sweep` log line within two minutes (section 1 step 8). A rerun of
`deploy.sh prod --jobs` also resumes the four ingest schedules (it recreates or updates them `ENABLED`), so
a pause does not survive a jobs deploy.

What stops while each is paused (from `docs/ingest/README.md`, Jobs):

| Paused | Stops | Still happens | Catching up |
|---|---|---|---|
| `ingest-sweep` | the retry of failed events, the second read of records without a contact, the hourly Aircall catalogs, `link_calls` (calls to CRM calls), the outbox guard | webhooks still land and are read back inline within their budget | on resume the sweep claims everything due; the 02:30 reconcile covers 26 hours |
| `ingest-poll-forms` | form submissions | | the cursor continues where it stopped |
| `ingest-poll-email` | email engagements and inbox threads | | the cursors continue |
| `ingest-reconcile` | the nightly 26-hour catch-up, the Aircall webhook check, the Shopify subscription check | | run it by hand once: `gcloud run jobs execute ingest-reconcile --project=p4a-cma-prod --region=europe-west4 --wait` |
| `cma-close-forgotten-workdays-hourly` | the hourly close of days left open | | the close is idempotent and closes everything overdue at its next run or by hand: `gcloud run jobs execute cma-close-forgotten-workdays --project=p4a-cma-prod --region=europe-west4 --wait` |

When to pause:

- **A vendor incident** (HubSpot, Aircall or Shopify answering 5xx or 429 for a long stretch): pause
  `ingest-sweep`, `ingest-poll-forms` and `ingest-poll-email` so the jobs stop knocking every minute; the
  adapters already back off on a 429 and nothing retries in a loop, so this is a courtesy, not a fix. Resume
  when the vendor's status page is green. A pause longer than 26 hours needs a backfill afterwards
  (`ingest-backfill --args=--connection,<id>,--object,<type>,--from,<date>`; PROD_RUNBOOK 7.8, 8.8, 9.8).
- **A bad deploy of the ingest image**: pause the three per-minute jobs, roll back (section 2.3), resume.
  Nothing is lost: events wait in `cma.ingest_event` as `received` or `failed`.
- **The DST night, 24 to 25 October 2026** (the clock goes from 03:00 CEST back to 02:00 CET on Sunday 25
  October): `cma-close-forgotten-workdays-hourly` runs hourly in UTC and the close function works on the
  tenant's local window end (22:00) plus a grace of 60 minutes (seed `02`, 0008b), so the first close of
  Saturday's forgotten days falls after 23:00 local either way. Whether to pause the schedule that night
  and run the job by hand on Sunday morning is for the lead to decide from the DST findings (5.12); the
  function is idempotent, so a pause costs nothing but a later close. A day left open across the repeated
  hour is corrected on Team hours, where the editor asks which of the two 02:xx times is meant (README,
  API: the day editor).

---

## 4. Switch a connection off and on

A connection is a row of `cma.integration_connection` (`hubspot`, `aircall`, `shopify`, `automation`) with
a status `active` or `inactive`. The Workspace changes it on Configuration → Sources
(`web/src/lib/data/postgres.ts` calls `cma.set_connection_status(id, 'active' | 'inactive')`).

**Browser:** `https://workspace.pulse4all.app/configuration/sources` (needs `tenant.configure`) → the
connection → its status control → inactive → save.
Expected: the connection listed as inactive after a reload.

What stops when a connection is inactive (from the code, `ingest/src/core/connection.mjs` and
`ingest/src/server.mjs`):

- **Webhooks are answered `404`, empty, nothing written** (`cma.ingest_connection(key)` returns null for an
  inactive connection, exactly as for an unknown key; the service does not even read the signature). The
  vendor sees a failed delivery:
  - HubSpot retries failed deliveries with backoff for a limited time (its documentation; after that the
    events are gone from the webhook path and only the 02:30 reconcile's 26-hour look-back or a backfill
    brings the objects);
  - Aircall retries, and after repeated failures disables the webhook; the nightly reconcile re-activates
    it (`webhook_reactivated`) once the connection is active again;
  - Shopify retries 8 times over 4 hours and then **deletes the subscription**; the nightly reconcile
    recreates it (`subscriptions_recreated`) once the connection is active again. A Shopify connection
    switched off for more than about four hours therefore has no subscriptions until the next 02:30 after
    it is switched on, and the 26-hour look-back reads what was missed; off for longer than 26 hours means a
    backfill `--from` the day it was switched off;
  - the automation route (`POST /automation/<key>`, Make or n8n) gets `404` as well: the scenarios that
    send messages to agents error until the connection is back.
- **The jobs skip it**: `servedConnections()` lists `c.status = 'active'` only, so the sweep, the polls,
  the reconcile and a backfill naming it serve nothing for it (a backfill `--connection <id>` of an inactive
  connection finds no connection and does nothing).
- **Nothing is deleted**: its records, events and cursors stay; switching back on resumes from the cursors.

**Browser:** the same control → active → save. Then watch the next 02:30 `reconcile` rows (section 7) for
`subscriptions_recreated` or `webhook_reactivated`, which are the expected repair, not errors to fix.

Read-only check in Studio (ids and statuses only, no customer rows):

**Studio (cma-prod-pg)**
```sql
set role cma_owner;
select name, adapter, kind, status, key from cma.integration_connection order by adapter, name;
reset role;
```
Expected: one row per connection (`HubSpot Subscriptions`, `Aircall Subscriptions`, one per Shopify store,
`Automations Subs`), `status` as you set it. The key is an identifier, not a secret (the signature or
bearer is the proof), but it stays in Studio: never in a record, a PR or a chat.

Fallback switch in Studio, after the PROD_RUNBOOK context block (same Run):

**Studio (cma-prod-pg)**
```sql
select cma.set_connection_status('<connection id>', 'inactive');
reset role;
```
Expected: an empty result. `'active'` switches it back.

---

## 5. Rotate a secret

General rule (`ingest/src/core/secrets.mjs`): the service and the jobs read `versions/latest` of a secret
by NAME and cache the value for 5 minutes. A rotation is therefore "add a new version" (never edit or delete
the secret itself), and the old value stops being accepted at most 5 minutes later; disable the older
versions afterwards. The accessor grant sits on the secret, so no deploy is needed. Store a value only with
the `put_secret` function of PROD_RUNBOOK (hidden prompt, never echoed, never in history) or with
`openssl rand … | gcloud secrets versions add … --data-file=-` (generated, never shown).

**Terminal** (paste once per terminal session; from PROD_RUNBOOK, unchanged)
```bash
put_secret () {  # usage: put_secret <project> <name>   → hidden prompt, never echoed, never in history
  gcloud secrets describe "$2" --project="$1" >/dev/null 2>&1 || \
    gcloud secrets create "$2" --project="$1" --replication-policy=user-managed --locations=europe-west4 >/dev/null
  read -rsp "Paste value for $2 (hidden), then Enter: " v; echo
  printf %s "$v" | gcloud secrets versions add "$2" --project="$1" --data-file=- >/dev/null && echo "stored $2 (version added)"; unset v
}
```
Expected: no output; `type put_secret` prints the function.

After every rotation, disable the older versions (**untested here; dry-run first**, that is `list` first):

**Terminal**
```bash
gcloud secrets versions list <secret name> --project=p4a-cma-prod
gcloud secrets versions disable <older version number> --secret=<secret name> --project=p4a-cma-prod
```
Expected: the list with the newest `ENABLED`; each older one `DISABLED` after its command. Keep the newest
two enabled for the 5-minute window, then disable the older of the two.

### 5.1 HubSpot (two secrets, two steps each)

| Secret name | What it is | Read by | Where it comes from |
|---|---|---|---|
| `ingest-hubspot-subs-signing` | the client secret of the project app **CMA ingest prod** (the v3 signature of every webhook) | `cma-ingest` service, per webhook | live portal → Development → Projects → CMA ingest prod → the app → **Auth** tab (PROD_RUNBOOK 7.4) |
| `ingest-hubspot-subs-token` | the static access token of the app's Standard install (every read-back, the jobs, the owners script) | the service's read-back, all five ingest jobs, `hubspot-owners.mjs` | the app → **Distribution** → the Standard install's row → **Show** |

The client secret. Order: (1) in the **Browser**, rotate the client secret on the app's Auth tab (HubSpot
shows the new value; whether HubSpot keeps accepting the old one for a while is not written in our docs:
assume it does not). (2) At once, **Terminal**: `put_secret p4a-cma-prod ingest-hubspot-subs-signing`.
Between (1) and (2), and for up to 5 minutes after (2), every webhook fails the signature: `401`
`authentication failed` in the service log, and HubSpot retries them, so nothing is lost if (2) follows
within HubSpot's retry window. Check: the `authentication failed` lines stop and `webhook` lines with
`new` above 0 appear:

**Terminal**
```bash
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="cma-ingest" AND jsonPayload.message:*' --project=p4a-cma-prod --freshness=15m --limit=20 --format='value(timestamp,jsonPayload.message,jsonPayload.code)'
```
Expected: `webhook` lines; no `authentication failed` with code `signature_mismatch` after the new version
is 5 minutes old.

The token. Order: (1) **Browser**: on the install row, generate a new static token (HubSpot may invalidate
the old one at once). (2) **Terminal**: `put_secret p4a-cma-prod ingest-hubspot-subs-token`. (3) The check of
PROD_RUNBOOK 7.4 without showing it (expected `147946837`, the account type, `eu1`). Between (1) and (2) plus
5 minutes, read-backs fail `http_401` and the sweep retries them with backoff; a job run in that window
ends `failed` with `http_401` in `cma.sync_run` and the next minute's run succeeds. Nothing is lost.

### 5.2 Aircall (two secrets, two different procedures)

| Secret name | What it is | Rotation |
|---|---|---|
| `ingest-aircall-subs-token` | the API key as one line of JSON `{"api_id":"…","api_token":"…"}` (read-backs, catalogs, reconcile, backfill, the two scripts) | **Browser**: Aircall Dashboard → Integrations & API → API Keys → generate a new key; **Terminal**: `put_secret p4a-cma-prod ingest-aircall-subs-token` with the new pair as that JSON line; the check of PROD_RUNBOOK 8.2 (`200` on `/v1/company`, nothing shown); then delete the old key in Aircall. Between the two steps plus 5 minutes, read-backs fail `http_401` and the sweep retries |
| `ingest-aircall-subs-signing` | the webhook's token, which Aircall puts in every event and shows only when the webhook is created | not a value you choose: **rotating it means deleting and creating the webhook** (README Open decisions, line 2062; `docs/ingest/aircall-webhook.mjs`), never by a job |

The webhook token, in order (`<key>` is the Aircall connection's key from Sources; the script stores the
new token itself and never prints it):

**Terminal**
```bash
node docs/ingest/aircall-webhook.mjs --project p4a-cma-prod --api-secret ingest-aircall-subs-token --account Pulse4all --list
```
Expected: the company's webhooks, one of them the CMA's (`https://ingest.pulse4all.app/aircall/<key>`),
with its id; never a token.

**Terminal**
```bash
node docs/ingest/aircall-webhook.mjs --project p4a-cma-prod --api-secret ingest-aircall-subs-token --account Pulse4all --delete <webhook id>
```
Expected: `deleted <id>` and the note that the signing secret keeps the old token as a version.

**Terminal**
```bash
node docs/ingest/aircall-webhook.mjs --project p4a-cma-prod --url "https://ingest.pulse4all.app/aircall/<key>" --api-secret ingest-aircall-subs-token --token-secret ingest-aircall-subs-signing --account Pulse4all
```
Expected: `webhook <new id>`, the six events, and `-- token stored as a new version of
ingest-aircall-subs-signing (not shown)`. Then **Browser**: Configuration → Sources → Aircall Subscriptions →
Settings → `webhook_id` = the new id → Save. Between delete and create no event arrives (seconds); the
02:30 reconcile lists the last 26 hours of calls anyway. Disable the older secret versions afterwards.

### 5.3 Shopify (`ingest-shopify-app-signing`, one per app, shared by its stores)

PROD_RUNBOOK 9.3, quoted:

> Rotation (README Decision log, 13 October 2026, sixth Gemini audit FIND-02): the client secret is rotated in
> the Dev Dashboard (the app → Settings → Credentials), then the new value is added as a new version of
> `ingest-shopify-app-signing` with the `put_secret` line above; no Secret Manager rotation schedule (the
> service reads the latest version within five minutes, and Shopify retries a delivery refused meanwhile).

`docs/ingest/README.md`, Shopify, adds: "After a rotation of the client secret Shopify may sign with the
old one for up to an hour; a delivery the service refuses in that hour (401) is retried by Shopify (eight
times over four hours), so a rotation loses nothing once the new secret is the latest version in Secret
Manager." The same secret mints the API token (client credentials grant), so between the rotation and the
new version the jobs' Shopify reads fail `http_401` and resume by themselves.

### 5.4 The automation bearer (`ingest-automation-subs-secret`)

Read by the automation adapter as the bearer of `POST /automation/<key>` (constant-time compare; the key in
the path only finds the connection). The callers are the Make or n8n scenarios and CRM workflows that send
messages to agents (README Features 7, 0008a). There is no dual acceptance: within 5 minutes of the new
version only the new value works. Order, at a quiet hour: (1) **Terminal**, generated and never shown:
```bash
openssl rand -base64 32 | tr -d '\n' | gcloud secrets versions add ingest-automation-subs-secret --project=p4a-cma-prod --data-file=-
```
Expected: `Created version [n] of the secret [ingest-automation-subs-secret]`. (2) **Browser**: in each
scenario's HTTP module, replace the `Authorization: Bearer` value with the new one (read it once with
`gcloud secrets versions access latest --secret=ingest-automation-subs-secret --project=p4a-cma-prod`, then
`clear`). Until (2), and for up to 5 minutes after (1), the scenarios get `401` and Make shows the error on
the run. (3) Disable the older version.

### 5.5 The hash peppers (`ingest-hash-pepper-pulse4all-subscriptions`; dev also `…-pulse4all-invest`): never rotated

Every stored phone hash is `HMAC-SHA256(pepper, E.164)`: `cma.crm_call.counterpart_hash`,
`cma.telephony_call.counterpart_hash`, `cma.commerce_customer.phone_hash`, `cma.commerce_order.phone_hash`.
A new pepper would make every hash computed from then on unequal to every hash stored before: calls would
no longer link to CRM calls across the boundary (`link_calls`), repeat missed calls would not match, orders
would not match earlier calls. The pepper is generated by `deploy.sh --tenant` (32 random bytes, never
shown) and has no "rotate" step on purpose. Treat it like the database itself: it changes only after a
suspected disclosure, and then as a planned project (new pepper, then a re-read of every call and order
through the backfills so the stored hashes are recomputed, with the gap in `link_calls` accepted and
written down). Never read its value.

### 5.6 `bq_reader` (`cma-prod-bq-reader-password`; untested here; dry-run first)

README (line 297) says the prod password is **not set yet** (dev was set on 11 October 2026). When it exists,
the rotation follows RUNBOOK 10a's pattern, chained so the secret changes only when the password did:

**Terminal**
```bash
NEWPW="$(openssl rand -base64 48 | tr -d '\n/+=' | cut -c1-36)-Ka7" && gcloud sql users set-password bq_reader --instance=cma-prod-pg --project=p4a-cma-prod --password="$NEWPW" && printf '%s' "$NEWPW" | gcloud secrets versions add cma-prod-bq-reader-password --project=p4a-cma-prod --data-file=- ; unset NEWPW
```
Expected: `Updating Cloud SQL user...done.` and `Created version [n] …`. Then **Browser**: BigQuery →
External connections → the prod connection → edit → the new password (the federation stores its own copy;
until it is updated, every federated query fails to authenticate). Then disable the older secret version.

### 5.7 `postgres` (`cma-prod-postgres-password`): RUNBOOK section 10a, unchanged

Seen run on 9 October 2026 (secret version 4). The command, the `-Ka7` suffix for the password policy, the
`&&` chain and the `unset` are in RUNBOOK 10a; disable the older versions afterwards; `clear` after any
`versions access`; never share the terminal output.

### 5.8 Not rotated here

`cma-prod-nocodb-jwt-secret` and `cma-prod-nocodb-encrypt-key` (NocoDB's own; a new encrypt key makes the
stored source credentials unreadable, so a rotation is a NocoDB re-setup, not a version add); the service
accounts have no keys (IAM database authentication; README Decision log, line 1671); the IAP client is
Google-managed.

---

## 6. Where logs and alerts are

**A request log line can hold a URL with a token in it** (`/invite/<token>` of an invitation, `?as=` in dev),
and Cloud Run's request log keeps the URL (README Decision log, 12 October 2026). So: read **app logs**
only (`textPayload` for `cma-web`, `jsonPayload.*` for `cma-ingest` and the jobs), keep request logs for the
status-code histogram only (`httpRequest.status`, never `httpRequest.requestUrl`), and never paste a request
log line into a record or a chat.

`cma-web` app lines (RUNBOOK section 6: they start with `[cma-data]`, `[cma-db]` or `[cma-api]`; a 503
`database_unavailable` means the service could not reach Cloud SQL):

**Terminal** (RUNBOOK 6, as written; it prints request lines too, so read it on screen and keep nothing)
```bash
gcloud run services logs read cma-web --project=p4a-cma-prod --region=europe-west4 --limit=50
```
Expected: mostly request lines and the occasional `[cma-…]` line.

**Terminal** (app lines only; untested here; dry-run first)
```bash
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="cma-web" AND textPayload:"[cma-"' --project=p4a-cma-prod --freshness=1h --limit=50 --format='value(timestamp,textPayload)'
```
Expected: only `[cma-data]`, `[cma-db]`, `[cma-api]` lines, or nothing.

`cma-ingest` and the jobs (JSON lines: connection id, adapter, counts, durations, codes; never payloads or
header values; `docs/ingest/README.md`, Logs):

**Terminal** (the service's app lines)
```bash
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="cma-ingest" AND jsonPayload.message:*' --project=p4a-cma-prod --freshness=1h --limit=30 --format='value(timestamp,jsonPayload.message,jsonPayload.code,jsonPayload.new,jsonPayload.ms)'
```
Expected: `webhook` lines with `new` and `ms`; `authentication failed` lines are strangers or a rotation in
progress (section 5).

**Terminal** (the sweep's warnings of the last day; A5 runbook step 7, as written)
```bash
gcloud logging read 'resource.type=cloud_run_job AND resource.labels.job_name=ingest-sweep AND jsonPayload.code="outbox_pending"' --project=p4a-cma-prod --freshness=1d --limit=10 --format='value(timestamp,jsonPayload.connection,jsonPayload.outboxPending)'
```
Expected: nothing.

**Terminal** (any job's last lines; `docs/ingest/deploy.sh` prints this form)
```bash
gcloud logging read 'resource.type=cloud_run_job AND resource.labels.job_name=ingest-reconcile' --project=p4a-cma-prod --freshness=1d --limit=20 --format='value(timestamp,jsonPayload.message,jsonPayload.code)'
```
Expected: the 02:30 run's lines; codes `subscriptions_recreated`, `webhook_reactivated` are repairs;
`webhook_token_mismatch`, `account_mismatch`, `token_unavailable`, `pepper_unavailable` need a person.

**Terminal** (the forgotten-day job; `docs/scheduler/deploy.sh` prints this form)
```bash
gcloud logging read 'resource.type=cloud_run_job AND resource.labels.job_name=cma-close-forgotten-workdays' --project=p4a-cma-prod --freshness=1d --limit=20 --format='value(timestamp,textPayload)'
```
Expected: one short line per hourly run, most of them closing nothing.

**Terminal** (status codes of the public ingest endpoint, no URLs; PROD_RUNBOOK 7.9)
```bash
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="cma-ingest" AND httpRequest.status>0' --project=p4a-cma-prod --freshness=1d --format='value(httpRequest.status)' | sort | uniq -c
```
Expected: mostly `200`; a few `401` or `404` are strangers; `500` points at the database or a secret.
Cloud Armor's `429`s never reach this log (answered at the load balancer); they show only in the alert below.

**Browser:** Console → Logging → Logs Explorer (project `p4a-cma-prod`) for anything else; filter on the
resource and on `jsonPayload.message` or `textPayload`, and leave the request log (`logName` ending in
`requests`) out of a saved query.

Alerts today: one policy, **`cma-ingest 429`** (Console → Monitoring → Alerting → Policies), on the load
balancer's request count for `cma-ingest-backend` with `response_code = 429`, summed over 5 minutes, firing
above 0 for 1 minute, auto-closing after 30 minutes without a 429, to the email channel "CMA ingest alerts"
(`docs/ingest/alert.sh`; the address is in the channel only). A rerun of `alert.sh prod --email <address>`
updates it, never duplicates it. Budget alerts email the billing admins (dev €75, prod €150 per month;
README line 331). Secret Manager Data Access logging (`DATA_READ`) is on in both projects since 13 October
2026, so every read of a secret value is in the audit log with who read it.

Alerts this audit proposes: see READINESS.md, alerts (placeholder: the lead fills it from the 5.4/5.5
findings; candidates are a job that has not logged for n minutes, `failed` above 0 for a sweep, `500`s on
`cma-web`, the certificate status, the connection count).

---

## 7. The operator's daily and weekly check

### Daily (5 minutes, in the morning)

1. **Browser:** Configuration → System health (once it exists; until then steps 2 to 4 cover it).
   Expected: everything green; the jobs' last runs minutes old; the version you expect.
2. **Browser:** Reports → Data quality (`/reports/data-quality`).
   Expected: the checks as yesterday; no row "Contact updates not sent" (`outbox_pending`) and no parked
   write-backs (`writeback_parked`); the other rows (tickets without owner or market, unlinked task owners,
   shop customers without a contact) not jumping. Then Configuration → Sources → each connection: the event
   counts, `needs_review` at 0 (events parked after `ingest.max_attempts`; each needs a person).
3. **Terminal:** the sweep's warnings (section 6, `outbox_pending` command) and the reconcile's codes
   (section 6, `ingest-reconcile` command).
   Expected: nothing, and a 02:30 run without `webhook_*` or `account_mismatch` codes.
4. **Terminal:** the scheduler's last executions.
   ```bash
   gcloud scheduler jobs list --project=p4a-cma-prod --location=europe-west4 --format='table(name.basename(),state,lastAttemptTime,status.code)'
   ```
   Expected: `ENABLED`, `lastAttemptTime` within the last hour (the forgotten-day job) or minute (the
   ingest jobs), `status.code` empty or 0.
5. **Browser:** Team hours, yesterday: days marked "needs correction" (the forgotten-day close) are the
   manager's to review today.

### Weekly (15 minutes, Monday)

1. **Browser:** Console → Billing → Budgets & alerts, and the month-to-date cost of `p4a-cma-prod` and
   `p4a-cma-dev`. Expected: inside the budgets (prod €150, dev €75); the first full month on the dedicated
   core decides whether prod's budget is raised (README line 145).
2. **Studio (cma-prod-pg)**, the connection budget (README, Database connection budget; `max_connections` 100):
   ```sql
   select coalesce(usename, '(background)') as login, coalesce(datname, '') as database, count(*) as connections
   from pg_stat_activity group by 1, 2 order by 3 desc;
   ```
   Expected: `cma-web@…` and `cma-ingest@…` only while busy (at most 20 and 25), `cma-nocodb@…` at most 6,
   `cloudsqladmin` a few, your own login, the background processes. A login far above its ceiling is a leak.
3. **Terminal:** backups and the instance.
   ```bash
   gcloud sql backups list --instance=cma-prod-pg --project=p4a-cma-prod --limit=8 --format='table(windowStartTime.date("%d %b %H:%M"),type,status)'
   gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format='value(state,settings.availabilityType,settings.backupConfiguration.enabled,settings.backupConfiguration.pointInTimeRecoveryEnabled,settings.maintenanceVersion)'
   ```
   Expected: one `AUTOMATED` `SUCCESSFUL` backup per day; `RUNNABLE REGIONAL True True <version>`.
   (**untested here; dry-run first**: the field names are gcloud's documented ones, check `--help`.)
4. **Terminal:** certificates and the alert.
   ```bash
   gcloud compute ssl-certificates list --project=p4a-cma-prod --global --format='table(name,managed.status,managed.domainStatus,expireTime.date("%d %b %Y"))'
   gcloud monitoring policies list --project=p4a-cma-prod --format='table(displayName,enabled)'
   ```
   Expected: `cma-web-cert` and `cma-ingest-cert` `ACTIVE`, expiry weeks away (Google renews them);
   `cma-ingest 429  True`.
5. **Terminal:** dependencies. The build does not print an audit summary today (`cloudbuild.yaml` has no
   audit step and the runbook installs with `--no-audit`), so run it yourself on `main`:
   ```bash
   cd ~/cma/web && npm audit --omit=dev 2>&1 | tail -3; cd ~/cma/ingest && npm audit --omit=dev 2>&1 | tail -3
   ```
   Expected: `found 0 vulnerabilities` for what ships; the known 5 high advisories live under
   `eslint-config-next` (a devDependency; README Open decisions, line 2010) and show only without
   `--omit=dev`. Never `npm audit fix --force`. A new advisory in what ships is a backlog item, reviewed with
   the next Next.js update.
6. **Browser:** Admin console → Security → 2-Step Verification for the agents' unit (README Open decisions,
   line 2051) until it is settled; GitHub → the repository's ruleset `main` still requires a pull request.

---

## 8. Who is contacted (roles only)

| Situation | First | Then |
|---|---|---|
| The Workspace does not load, a deploy went wrong, data looks wrong | Martin (owner of the CMA, the Google Cloud projects and the repository) | Martin decides on a rollback (section 2) and tells the manager |
| Agents cannot work in the Workspace | Arno (manager of the call center): the agents' Plan B applies (`PLAN_B`) | Arno tells Martin |
| A question of data protection, retention, employee monitoring, a possible disclosure of personal data | Yordi (compliance and data protection), through Martin | Martin writes it in the Decision log |
| A Google Cloud outage or a Cloud SQL, Cloud Run, IAP or load balancer fault that is not ours | Google Cloud support through the Console (Support → Cases) and the Google Cloud status page, by Martin | |
| HubSpot, Aircall or Shopify not delivering | the vendor's status page first; the data catches up by itself (sections 3 and 4) | the vendor's support, by Martin or the team member who owns that account |
| A finding about figures (hours, pay, KPIs) | Arno for hours and corrections; Kira for the KPIs; Peter for Invest | Martin |

No phone numbers or addresses here: the team's directory holds them.

---

## 9. Prod-only cautions

- **Terminal work against prod runs from the Chromebook only**; the Linux machine is not used for prod
  (README line 328, Martin, 16 October 2026). Cloud Shell is no longer used (README Decision log, 16 October
  2026); older docs that say "Cloud Shell" mean the Chromebook terminal.
- **A query that returns customer rows runs in Studio, never in the terminal**; the terminal's proxy runs
  only `db/` scripts and verifiers whose output is schema, counts and ids (README, Where a command runs).
- **Console changes to `cma-ingest` are emergency fixes only**, and they set exactly the values `deploy.sh`
  sets (ingress `internal-and-cloud-load-balancing`, `INGEST_PUBLIC_URLS` with `https://ingest.pulse4all.app`
  first): the next `deploy.sh prod --front …` replaces every environment variable anyway (README Decision
  log, 16 October 2026; `records/ingest-front-incident-2026-10-16`).
- **Never edit `cma-web`'s environment in the Console**: it comes from `cloudbuild.yaml` plus the trigger's
  substitutions, and the next build undoes a Console edit (RUNBOOK 9). A configuration change is the
  trigger export, edit, import, run.
- **Never a prod service deploy of the ingest without `--front ingest.pulse4all.app`**; the script refuses
  it since 16 October 2026, so a refusal is the guard working, not an error to work around.
- **Dev first, prod from the same commit**: the ingest image is built once in prod and dev deploys it by
  tag, so a prod deploy says `no build` when it runs what dev tested. A prod deploy that builds is a sign
  dev was skipped.
- **Never push to `main`**; it accepts pull requests only, Martin squash-merges, and a merge touching
  `web/**` or `cloudbuild.yaml` deploys prod at once (CLAUDE.md).
- **No secret value, personal id, email address, phone number or hash value** in a record, a PR, a chat or a
  screenshot; secret names only. Records hold values from real runs only, written from Martin's report.
- **Migrations are forward-only**; a mistake is a new pair (`db/<n>_<name>.sql` and its verify), never an
  edit of one that has run.
