# The ingest service (`cma-ingest`)

The only write path into the CMA from outside Google Cloud (README Architecture, Ingest API; specification `docs/night-2026-10-10/DESIGN.md` §2, §5, §6). Code in `ingest/` (plain Node 22, ESM, `pg` and the Cloud SQL connector as `web/src/lib/db/client.ts` connects). This version has the HubSpot route (brief B7) and the jobs (brief B8); Aircall comes with B9, Shopify with B10.

## What it does

| Route | Does |
|---|---|
| `GET /health` | `{"ok":true,"version":"<short sha>"}`; no database |
| `POST /hubspot/<connection key>` | a HubSpot webhook batch: key → connection (`cma.ingest_connection`), v3 signature, events recorded and committed, objects read back within 3 seconds, then `200 {"received":n,"new":m}` |

Answers: unknown key, inactive connection, a connection of another adapter, an unknown route or a method other than POST → `404`, empty. A bad, missing or stale signature → `401`, empty, nothing written. A body over 1 MB → `413`. A body that is not JSON → `400`. A database error before the commit, or a signing secret that cannot be read → `500` (HubSpot sends again).

Per request, in this order (DESIGN §2, the 0006 pattern):

1. **Authenticate** before anything but the key lookup touches the database: `X-HubSpot-Signature-v3` = base64(HMAC-SHA256(client secret, `POST` + URI + body + timestamp)), `X-HubSpot-Request-Timestamp` at most 5 minutes off, compared in constant time. The URI is the public address HubSpot called: the service's own URLs are in `INGEST_PUBLIC_URLS` (deploy.sh sets both Cloud Run address forms; in prod with `--front <host>` the public host `https://<host>` comes first, so HubSpot signs the public host).
2. **Record** every event as a canonical event (`hs:<eventId>`, kind, object type and id, ids and timestamps only; the property value and the acting user are dropped), in one transaction, in batches of at most 500. An event of another portal is recorded as `ignored` with `raw.ignored = portal_mismatch` and never read back; so are association changes the CMA does not keep (only deal → contact, ticket → contact, call → contact and call → deal) and objects it does not read.
3. **Read back** within the budget (`INGEST_READBACK_BUDGET_MS`, 3000): deals and tickets by CRM v3 batch read with HubSpot's structural properties (pipeline, stage, owner, created, closed, modified) plus the properties configured in `cma.connection_field`, their contacts through the v4 associations batch read, the primary contact (labelled primary, else the one already held, else the lowest id) read with its configured properties; calls with their properties, the other party's number hashed (below) and dropped, their contacts and deals; contacts only when the CMA holds them (0006: never the contact base). Deletions mark the object deleted without a read; `contact.privacyDeletion` calls `cma.ingest_contact_forget()`. Pipelines with stages and the call outcome list (`/calling/v1/dispositions`) are refreshed at most hourly per connection.
4. **Upsert** through the 0006 and 0007 functions (stale guard on the source's updated time) and **finish** the events. A 429 finishes them as `failed` with `rate_limited`, a timeout with `timeout`, an HTTP error with `http_<status>`: the sweep job reads them again with backoff and parks them after `ingest.max_attempts`.

Without a market property mapped for a record type, a deal or ticket takes its primary contact's mapped country as market (and language), normalised by the market aliases (VENDOR_SETUP §1.1). A later change of the contact's country reaches the record at the record's next read (its own event or the nightly reconcile of B8).

**The keyed hash.** `HMAC-SHA256(pepper, E.164)` in hex; numbers normalised with libphonenumber, national formats with the connection setting `phone_default_region` (for example `GB`) as default region; a number that is not a possible phone number gets no hash. The pepper is per tenant: secret `ingest-hash-pepper-<tenant slug>`. Without it, calls are not read back (`pepper_unavailable`) until it exists.

**Logs** are JSON lines: connection id, adapter, counts, durations and error codes. Never payloads, contact or customer ids, numbers, emails, secrets or header values. With `INGEST_LOG_HEADER_NAMES=1` (dev) each webhook logs its header **names**, so the first delivery shows whether HubSpot sends `x-hubspot-signature-v3`.

## Jobs

Cloud Run jobs on the same image (`node jobs/<name>.mjs`), as `cma-ingest@<project>` with the service's database settings, started by Cloud Scheduler (Europe/Amsterdam) as `cma-ingest-scheduler@<project>`, which holds `run.invoker` on the three scheduled jobs only. Each serves every active connection of every tenant with an active Ingest user (`cma.find_tenants_for_identity('ingest', 'ingest')`, then the tenant's connections under row-level security, as the tenant's Ingest user), exits 0 when every connection was served and 1 when any failed (the others are still served). Logs: connection ids, counts, codes; never an email, a contact id or a token.

| Job | Schedule | Does | `sync_run` |
|---|---|---|---|
| `ingest-sweep` | every minute | per connection, due events (received, or failed with the backoff passed) claimed and read back in parts of 100 until none is due (at most about 45 seconds); records still without a contact in their first hour read again, at most every ten minutes; per tenant `cma.link_calls(now() − 2 h)` | `link_calls` on the tenant's first HubSpot connection (the events are the sweep's own audit) |
| `ingest-poll-forms` | every minute | the form catalog (`GET /marketing/v3/forms`) at most hourly into `cma.connection_form` (names only; counted, lead source, market and kept fields stay as configured); per counted, active form the submissions newest first, 50 per page, until the form's cursor (`forms:<guid>`: time and conversion id of the newest read), on its first poll until `intake.start_date`; the contact by a CRM search on the definition's email field (one → resolved, none → not_found, several → ambiguous, no email → no_email), the email in memory for that search only; page host and path, UTM parameters, kept fields only (never the email field) | `forms_poll`, stream `forms` |
| `ingest-reconcile` | 02:30 | per connection and object type (deal, ticket, crm_call, contact) everything modified in the last 26 hours by CRM search, read back like a webhook (stale guard: a newer row stays); contacts only when the CMA holds them; `--lookback-minutes <n>` shortens the look-back | `reconcile`, stream the object type |
| `ingest-backfill` | none | `--connection <id> --object <deal\|ticket\|crm_call\|form_submission\|contact> [--from <YYYY-MM-DD>]` (default `intake.start_date`, 00:00 in the tenant's zone): deals by `createdate` and then `closedate`, tickets by `createdate` and `closed_date`, calls by `hs_timestamp`, contacts the CMA holds, submissions of the counted forms; paced at half of HubSpot's documented limits (search one call per 400 ms, the rest one per 200 ms); resumable: the cursor (`backfill:<object>:<property>`) moves after every page and a run with the same start continues there | `backfill`, stream the object type |

Reconcile, backfill and the second read do not write themselves: what they find becomes a synthetic event (`sync:<type>:<id>:<modified time>`, kind `changed`) on the webhook's read-back and upserts. So an unchanged object is read once however often it is listed, a 429 in a backfill leaves its events to the sweep with backoff, and every object a job touched has its event row. A failed contact search in the forms poll writes nothing for that form and leaves its cursor, so the next run reads the same submissions again (they are idempotent on the conversion id). HubSpot's search returns at most 10,000 results per query; past that a new query starts at the last value seen. Deletions are not found by a search: they arrive by webhook.

## Configuration

| Where | What |
|---|---|
| `cma.upsert_connection('hubspot', name, <portal id>, <signing secret name>, <token secret name>)` | the connection and its key (runbook 2.2) |
| `cma.set_connection_field(...)` | the properties read and what they feed (runbook 2.2); nothing else is read |
| `cma.set_connection_settings(conn, '{"app_host":"…","phone_default_region":"GB"}')` | non-secret settings; `phone_default_region` for the call hash |
| Secret Manager | `<signing secret name>` (the app's client secret), `<token secret name>` (the static token), `ingest-hash-pepper-<tenant slug>` |

Environment (set by `deploy.sh`): `CMA_DB_INSTANCE`, `CMA_DB_USER` (`cma-ingest@<project>.iam`), `CMA_DB_NAME`, `CMA_DB_POOL_MAX`, `INGEST_VERSION`, `INGEST_PROJECT`, `INGEST_PUBLIC_URLS`, `INGEST_LOG_HEADER_NAMES` (dev 1, prod 0), `INGEST_READBACK_BUDGET_MS`; the jobs get the database settings, `INGEST_VERSION` and `INGEST_PROJECT` only. Local only: `CMA_DB_HOST`, `CMA_DB_PORT`, `CMA_DB_PASSWORD`, `CMA_DB_SET_ROLE`, `INGEST_SECRETS_DIR` (secrets as files), `INGEST_HUBSPOT_API_BASE` (a fake HubSpot on localhost; only https or localhost is accepted), `INGEST_PACE_FACTOR` (0 to 1: scales the jobs' pacing for a verifier run against a fake source).

## Deploy (Martin, Cloud Shell)

The image is built once, in `p4a-cma-prod`, never in dev (README Architecture, Build and deploy; Decision log, 5 October 2026): `gcloud builds submit` in europe-west4 as `cma-build@p4a-cma-prod.iam.gserviceaccount.com`, source staged in `gs://p4a-cma-prod-build-src` (the default staging bucket is in the US and the EU-only policy refuses it, HTTP 412 on `constraints/gcp.resourceLocations`), pushed to `europe-west4-docker.pkg.dev/p4a-cma-prod/cma/ingest:<short sha>`, the sha of the last commit that touched `ingest/` (`git log -1 --format=%h -- ingest/`), not HEAD, so a merge of docs or README only reuses the image dev tested (the script prints both shas when they differ). When that tag exists the build is skipped, so prod after dev runs exactly the bytes dev tested. Dev and prod both deploy that image by tag; dev has no repository and no build of its own and pulls through its Cloud Run service agent, which has Artifact Registry reader on the prod repository `cma`. Before a dev deploy the script checks that grant; when it is missing it stops and prints the command that adds it:

**Terminal** (only when the script printed it; the project number is dev's)
```bash
gcloud artifacts repositories add-iam-policy-binding cma --project=p4a-cma-prod --location=europe-west4 --member=serviceAccount:service-<dev project number>@serverless-robot-prod.iam.gserviceaccount.com --role=roles/artifactregistry.reader
```
Expected: the repository's updated policy; then rerun the deploy.

**Terminal** (in `~/cma`, on main)
```bash
git switch -q main && git pull -q --ff-only && bash docs/ingest/deploy.sh dev --tenant pulse4all-subscriptions --tenant pulse4all-invest
```
Expected: the APIs enabled, the service account and its database user (first time), `created ingest-hash-pepper-…` per tenant the first time and `accessor on …`, `service-…@serverless-robot-prod.iam.gserviceaccount.com reads europe-west4-docker.pkg.dev/p4a-cma-prod/cma`, the Cloud Build log (project `p4a-cma-prod`) ending in `SUCCESS` or `image … exists (sha256:…); no build`, the Cloud Run deploy, then a block with one Studio statement, the URL and `health: {"ok":true,"version":"<short sha>"}`.

**Studio (cma-dev-pg)**: paste the printed statement as is, once:
```sql
grant cma_app to "cma-ingest@p4a-cma-dev.iam";
```
Expected: `GRANT ROLE`.

After the two HubSpot secrets exist (runbook 2.4), grant the accessor by rerunning with `--secret` (or with the runbook's loop):

**Terminal**
```bash
bash docs/ingest/deploy.sh dev --secret ingest-hubspot-dev-signing --secret ingest-hubspot-dev-token
```
Expected: `accessor on ingest-hubspot-dev-signing`, `accessor on ingest-hubspot-dev-token`, a new revision.

For prod the same with `prod` (instance `cma-prod-pg`, min instances 1, max 5, no header logging), from the same commit as the dev deploy: the image already exists, so the output says `no build` and prod runs what dev tested.

**Public front in prod** (README Architecture, Ingest API; Decision log, 12 October 2026). In prod `cma-ingest` is reached as `https://ingest.pulse4all.app` through the web load balancer (backend `cma-ingest-backend` without IAP, Cloud Armor policy `cma-ingest-armor`, certificate `cma-ingest-cert` next to `cma-web-cert`, a host rule on `cma-web-urlmap`), and its ingress is `internal-and-cloud-load-balancing`, so the `run.app` address refuses everyone. Dev keeps `--ingress=all` and its `run.app` address. The full prod sequence is `docs/ingest/PROD_RUNBOOK.md`; the front alone, in this order:

**Terminal** (in `~/cma`, on main; the service first, so the front has something to point at)
```bash
bash docs/ingest/deploy.sh prod --front ingest.pulse4all.app --tenant pulse4all-subscriptions
```
Expected: as above, plus `ingress: internal-and-cloud-load-balancing`, `public URLs (signed by HubSpot): https://ingest.pulse4all.app,https://cma-ingest-…run.app,…` and `webhook address per connection: https://ingest.pulse4all.app/hubspot/<connection key>`; `health:` says `no answer yet` until the front, the record and the certificate exist.

**Terminal**
```bash
bash docs/ingest/front.sh prod --host ingest.pulse4all.app
```
Expected: lines `a.` to `e.` (`created` the first time, `exists` on a rerun), then the A record `ingest.pulse4all.app → <address of cma-web-ip>`, the certificate status (`PROVISIONING` at first) and the two checks. `--rate-per-minute <n>` changes the throttle (default 600 per IP).

**Browser:** IONOS → pulse4all.app → DNS → add an A record, host `ingest`, the printed address; the other records stay as they are.

**Terminal** (repeat until `ACTIVE`, up to an hour after the record)
```bash
gcloud compute ssl-certificates describe cma-ingest-cert --project=p4a-cma-prod --global --format="value(managed.status,managed.domainStatus)"
curl -sS -o /dev/null -w "%{http_code}\n" https://ingest.pulse4all.app/health
curl -sS -o /dev/null -w "%{http_code}\n" "$(gcloud run services describe cma-ingest --project=p4a-cma-prod --region=europe-west4 --format='value(status.url)')/health"
```
Expected: `ACTIVE	ingest.pulse4all.app=ACTIVE`, then `200` on the host and `404` on the `run.app` address (refused by the ingress setting, as seen in prod on 12 October 2026). Every later prod deploy of the service passes `--front ingest.pulse4all.app` again; without it the ingress would go back to `all`.

**The jobs** (after the service, from the same commit, so the image exists):

**Terminal** (in `~/cma`, on main)
```bash
bash docs/ingest/deploy.sh dev --jobs
```
Expected: `image … exists (sha256:…); no build`, four `gcloud run jobs deploy` results (`ingest-sweep`, `ingest-poll-forms`, `ingest-reconcile`, `ingest-backfill`), then `schedule ingest-sweep: * * * * * (Europe/Amsterdam)`, the same for `ingest-poll-forms` and `schedule ingest-reconcile: 30 2 * * * (Europe/Amsterdam)`, and the backfill command. The first time it also creates the service account `cma-ingest-scheduler`.

A backfill, per connection and object type (the connection id from `select connection_id, adapter, name from cma.connections_all();` in Studio):

**Terminal**
```bash
gcloud run jobs execute ingest-backfill --project=p4a-cma-dev --region=europe-west4 --wait --args=--connection,<connection id>,--object,deal,--from,2026-10-01
```
Expected: `Execution [ingest-backfill-…] has successfully completed.` Then the same with `ticket`, `crm_call`, `form_submission`. A failed execution can simply be run again with the same arguments: it continues where it stopped.

**The polling fallback** (NIGHT_NOTES D3, only if the first delivery shows no `x-hubspot-signature-v3`): webhooks off in the app, and the reconcile every two minutes over the last ten:

**Terminal**
```bash
bash docs/ingest/deploy.sh dev --jobs --reconcile-every "*/2 * * * *" --reconcile-lookback 10
```
Expected: `schedule ingest-reconcile: */2 * * * * (Europe/Amsterdam)`. Back to nightly: rerun `--jobs` without the two options.

For prod the same with `prod`.

## Checks

**Terminal**: health and the first delivery's header names (runbook 2.5):
```bash
curl -s "$(gcloud run services describe cma-ingest --project=p4a-cma-dev --region=europe-west4 --format='value(status.url)')/health"
gcloud run services logs read cma-ingest --project=p4a-cma-dev --region=europe-west4 --limit=30 | grep -E "webhook|authentication" | tail -10
```
Expected: `{"ok":true,"version":"<short sha>"}`; after a deal is created in `CMA dev`, a `webhook headers` line whose `headerNames` include `x-hubspot-signature-v3` and `x-hubspot-request-timestamp`, then a `webhook` line with `new` above 0. If the names lack `x-hubspot-signature-v3` and the requests end in `authentication failed` (`missing_header`), stop: the fallback (NIGHT_NOTES D3) is webhooks off and the reconcile job every two minutes, a schedule change in B8, not a weaker signature.

**Studio (cma-dev-pg)**: what the events did, if a delivery is missing in the tables:
```sql
set role cma_owner;
select object_type, kind, status, error, count(*) from cma.ingest_event group by 1, 2, 3, 4 order by 1, 2;
reset role;
```
Expected: `processed` rows; `failed` with `token_unavailable`, `pepper_unavailable` or `http_401`/`http_403` points at a secret, an accessor or a scope.

**Studio (cma-dev-pg)**: the jobs' runs and the forms:
```sql
set role cma_owner;
select job, stream, status, counts, error, started_at, finished_at from cma.sync_run order by started_at desc limit 20;
select source_form_id, submitted_at, page_host, page_path, utm, contact_resolution, kept_values from cma.form_submission order by submitted_at desc limit 10;
reset role;
```
Expected: `link_calls` and `forms_poll` rows every minute with `succeeded`, `reconcile` rows after 02:30, a `backfill` row per execution; submissions with a host, a path without query, the UTM values and a resolution. A `forms_poll` row `failed` with `rate_limited` resolves itself on a later run; `token_unavailable` points at the token secret's accessor; `http_403` at the `forms` scope.

**Terminal**: a job's log:
```bash
gcloud logging read 'resource.type=cloud_run_job AND resource.labels.job_name=ingest-sweep' --project=p4a-cma-dev --limit=10 --format='value(jsonPayload.message,jsonPayload.processed,jsonPayload.failed)'
```
Expected: `sweep` lines with counts every minute.

## People: HubSpot owners on CMA persons

**Terminal** (the token secret of the connection)
```bash
node docs/ingest/hubspot-owners.mjs --project p4a-cma-dev --token-secret ingest-hubspot-dev-token
```
Expected: one `select cma.set_user_external_id(u.id, 'hubspot_owner', '<owner id>') from cma.app_user u where u.email = '<owner email>';` per active owner, and a count on stderr. Paste them into **Studio** after the runbook's context block (a person holding `users.manage_all`); an owner who is not a CMA person matches no row. Staff data: the output stays in the terminal.

## Replay (dev and local only, invented data)

**Terminal** (in `~/cma/ingest`, after `npm ci`; the dev signing secret read into a variable without echo)
```bash
read -rsp "dev signing secret: " SIG; echo; export SIG
node tools/replay.mjs --url "<URL>/hubspot/<dev key>" --fixture verify/fixtures/hubspot/generic-batch.json --secret-env SIG --portal <CMA dev account id> --fresh
unset SIG
```
Expected: `200 {"received":10,"new":10}`. The fixture's ids do not exist in `CMA dev`, so the read-backs find nothing and finish `ignored`; it proves the signature path, not the data.

## Verifiers (in `ingest/`)

| Command | What | Needs |
|---|---|---|
| `npm test` | `verify/signature.mjs`, `verify/mapping.mjs`, `verify/hash.mjs` | nothing (pure) |
| `node verify/<name>.mjs --provoke` | every check must fail | nothing |
| `npm test` (also) | `verify/forms.mjs`: page host, path and UTM, the email kept out, kept fields, the poll's cursor stop, the search window, synthetic event keys, job arguments | nothing (pure) |
| `node verify/flow.mjs [--provoke]` | the service end to end against a fake HubSpot | a local PostgreSQL with `db/00…33`, see the file's header |
| `node verify/jobs-flow.mjs [--provoke]` | the jobs end to end against a fake HubSpot: sweep, forms poll, backfill with an interruption, reconcile, tenant isolation, no email stored or logged | a local PostgreSQL with `db/00…37`, see the file's header |

Each prints `ALL n PASS`, or with `--provoke` `ALL n PROVOKED CHECKS FAILED, as they must`.
