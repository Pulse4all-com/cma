# The ingest service (`cma-ingest`)

The only write path into the CMA from outside Google Cloud (README Architecture, Ingest API; specification `docs/night-2026-10-10/DESIGN.md` §2, §5, §6). Code in `ingest/` (plain Node 22, ESM, `pg` and the Cloud SQL connector as `web/src/lib/db/client.ts` connects). This version has the HubSpot route (brief B7), the jobs (brief B8) and the Aircall route with its scripts (brief B9, section Aircall below); Shopify comes with B10.

## What it does

| Route | Does |
|---|---|
| `GET /health` | `{"ok":true,"version":"<short sha>"}`; no database |
| `POST /hubspot/<connection key>` | a HubSpot webhook batch: key → connection (`cma.ingest_connection`), v3 signature, events recorded and committed, objects read back within 3 seconds, then `200 {"received":n,"new":m}` |
| `POST /aircall/<connection key>` | one Aircall webhook event: key → connection, the body's `token` against the connection's signing secret, the event recorded and committed, the call read back from Aircall within 3 seconds, then `200 {"received":1,"new":0 or 1}` (section Aircall) |

Answers: unknown key, inactive connection, a connection of another adapter, an unknown route or a method other than POST → `404`, empty. A bad, missing or stale signature (Aircall: a missing or wrong token, or a body that is not JSON) → `401`, empty, nothing written. A body over 1 MB → `413`. A body that is not JSON → `400`. A database error before the commit, or a signing secret that cannot be read → `500` (HubSpot sends again).

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
| `ingest-sweep` | every minute | per connection, due events (received, or failed with the backoff passed) claimed and read back in parts of 100 until none is due (at most about 45 seconds); records still without a contact in their first hour read again, at most every ten minutes; Aircall's lines and tags at most hourly per connection; per tenant `cma.link_calls(now() − 2 h)` | `link_calls` on the tenant's first HubSpot connection (the events are the sweep's own audit) |
| `ingest-poll-forms` | every minute | the form catalog (`GET /marketing/v3/forms`) at most hourly into `cma.connection_form` (names only; counted, lead source, market and kept fields stay as configured); per counted, active form the submissions newest first, 50 per page, until the form's cursor (`forms:<guid>`: time and conversion id of the newest read), on its first poll until `intake.start_date`; the contact by a CRM search on the definition's email field (one → resolved, none → not_found, several → ambiguous, no email → no_email), the email in memory for that search only; page host and path, UTM parameters, kept fields only (never the email field) | `forms_poll`, stream `forms` |
| `ingest-reconcile` | 02:30 | per connection and object type (deal, ticket, crm_call, contact) everything modified in the last 26 hours by CRM search, read back like a webhook (stale guard: a newer row stays); contacts only when the CMA holds them; Aircall: the calls created in the look-back (`telephony_call`) and the webhook check (section Aircall); `--lookback-minutes <n>` shortens the look-back | `reconcile`, stream the object type |
| `ingest-backfill` | none | `--connection <id> --object <deal\|ticket\|crm_call\|form_submission\|contact\|telephony_call> [--from <YYYY-MM-DD>]` (`telephony_call` for an Aircall connection, section Aircall) (default `intake.start_date`, 00:00 in the tenant's zone): deals by `createdate` and then `closedate`, tickets by `createdate` and `closed_date`, calls by `hs_timestamp`, contacts the CMA holds, submissions of the counted forms; paced at half of HubSpot's documented limits (search one call per 400 ms, the rest one per 200 ms); resumable: the cursor (`backfill:<object>:<property>`) moves after every page and a run with the same start continues there | `backfill`, stream the object type |

Reconcile, backfill and the second read do not write themselves: what they find becomes a synthetic event (`sync:<type>:<id>:<modified time>`, kind `changed`) on the webhook's read-back and upserts. So an unchanged object is read once however often it is listed, a 429 in a backfill leaves its events to the sweep with backoff, and every object a job touched has its event row. A failed contact search in the forms poll writes nothing for that form and leaves its cursor, so the next run reads the same submissions again (they are idempotent on the conversion id). HubSpot's search returns at most 10,000 results per query; past that a new query starts at the last value seen. Deletions are not found by a search: they arrive by webhook.

## Configuration

| Where | What |
|---|---|
| `cma.upsert_connection('hubspot', name, <portal id>, <signing secret name>, <token secret name>)` | the connection and its key (runbook 2.2) |
| `cma.set_connection_field(...)` | the properties read and what they feed (runbook 2.2); nothing else is read |
| `cma.set_connection_settings(conn, '{"app_host":"…","phone_default_region":"GB"}')` | non-secret settings; `phone_default_region` for the call hash |
| Secret Manager | `<signing secret name>` (the app's client secret), `<token secret name>` (the static token), `ingest-hash-pepper-<tenant slug>` |
| `cma.upsert_connection('aircall', name, <company name>, <signing secret name>, <token secret name>)` | an Aircall connection (PROD_RUNBOOK 8.3): the account id is the company's name as `GET /v1/company` gives it (section Aircall) |
| `cma.set_connection_settings(conn, '{"webhook_id":"…"}')` (or Configuration → Sources → the connection → Settings) | Aircall: `webhook_id` (the reconcile's webhook check), `aircall_max_per_minute` (the pace, default 60), in dev `replay` |

Environment (set by `deploy.sh`): `CMA_DB_INSTANCE`, `CMA_DB_USER` (`cma-ingest@<project>.iam`), `CMA_DB_NAME`, `CMA_DB_POOL_MAX`, `INGEST_VERSION`, `INGEST_PROJECT`, `INGEST_PUBLIC_URLS`, `INGEST_LOG_HEADER_NAMES` (dev 1, prod 0), `INGEST_READBACK_BUDGET_MS`; the jobs get the database settings, `INGEST_VERSION` and `INGEST_PROJECT` only. `INGEST_ALLOW_REPLAY=1` on the service and the jobs in dev only (deploy.sh never sets it in prod; section Aircall, Replay in dev). Local only: `CMA_DB_HOST`, `CMA_DB_PORT`, `CMA_DB_PASSWORD`, `CMA_DB_SET_ROLE`, `INGEST_SECRETS_DIR` (secrets as files), `INGEST_HUBSPOT_API_BASE` and `INGEST_AIRCALL_API_BASE` (a fake HubSpot or Aircall on localhost; only https or localhost is accepted), `INGEST_PACE_FACTOR` (0 to 1: scales the jobs' pacing, and Aircall's, for a verifier run against a fake source).

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

## Aircall

The Aircall adapter (brief B9; DESIGN §2, §2.1, §4.2, §6), `ingest/src/adapters/aircall/`. The prod sequence is `docs/ingest/PROD_RUNBOOK.md` phase 8; this section is what each step relies on.

**Setup, once per Aircall company** (PROD_RUNBOOK 8.2 to 8.7): the API key into the token secret as one line of JSON `{"api_id":"…","api_token":"…"}` (Basic authentication on `https://api.aircall.io`); the connection with `cma.upsert_connection('aircall', <name>, <company name>, <signing secret>, <token secret>)` and its kind `telephony`; the signing secret created empty and both secrets granted to the service (`deploy.sh … --secret`); the webhook by `aircall-webhook.mjs`, which stores its token in the signing secret; the setting `webhook_id`; the lines' markets on Configuration → Sources; each agent's Aircall user id by `aircall-users.mjs`; the backfill.

**The account id is the company's name.** An Aircall event names no company, and `GET /v1/company` exposes no company id (in Pulse4all's account on 13 October 2026: `company.name` is `Pulse4all`, `company.id` is null). A request is pinned to its connection by the webhook's own token (one webhook per connection, its token in the connection's signing secret) and the opaque key in the path. The connection's `external_account_id` is the company's `name` exactly as `GET /v1/company` answers it, `Pulse4all` for Pulse4all's account: the value for PROD_RUNBOOK 8.3. `aircall-webhook.mjs --account <company name>` refuses to run when the API key answers for another company, so a key of another Aircall company is never wired to this connection, and the reconcile and the backfill make the same check first (`account_mismatch`, nothing listed). A renamed company in Aircall means updating the connection's account id (`upsert_connection` with the new name) before the next job.

**Per event** (one per request): the body's top-level `token` is compared in constant time (`crypto.timingSafeEqual` on equal-length buffers; another length is a failure) with the signing secret (Secret Manager, 5-minute cache); a failure is `401`, empty, nothing written. The event is recorded as `ac:<event>:<call id>:<timestamp>` (Aircall delivers at least once and not in order; the key absorbs the retries), ids and times only, never the token or the call object. Recorded and read back: `call.created` (kind `created`), `call.answered`, `call.ended`, `call.tagged`, `call.untagged`, `call.archived` (kind `changed`). Any other event, of a call or another resource, is recorded as `ignored` with `raw.ignored = event_not_handled` and never read back. Then, within the 3-second budget, the call is read with `GET /v1/calls/{id}` (a call Aircall does not know, 404, finishes `ignored`) into `cma.ingest_upsert_telephony_calls`: direction, status, missed reason, started, answered and ended (UNIX seconds to timestamps), duration, the user's id as `user_ref`, the line's id as `number_ref`, archived, the whole current tag set (tags opened and closed by difference), `raw` an allowlist (status, direction, missed_call_reason, duration, archived and the three times), and `source_version_at` the time of the read (the stale guard). The sweep reads a call once per batch however many of its events are due (in the webhook path each request carries one event, so each request reads once).

**The other party's number** (`raw_digits`) becomes the keyed hash (`HMAC-SHA256(pepper, E.164)`, `src/core/hash.mjs`) with the line's market (`cma.telephony_number.market`) as the default region for a national format, else the tenant's first active market (sort order, then code); it is never stored, logged or kept in an event. Without the tenant's pepper the call is not read (`pepper_unavailable`).

**Catalogs.** Lines (`GET /v1/numbers`: id, name, the company's own digits) and tags (`GET /v1/tags`: id, name) go into `cma.ingest_upsert_telephony_catalog`: from the sweep at most hourly per connection (cursor `catalogs`), and on the first event of a connection whose line catalog is empty. A line's market and counted flag and a tag's counted flag are configuration and stay (0007a); an entry Aircall no longer lists is archived. A catalog above 500 entries is not refreshed (logged as `catalog_too_large`). Pulse4all's account has 54 lines: each needs its market and counted flag on Configuration → Sources (no rule for lines yet).

**Pacing.** Aircall allows 120 requests per minute (developer.aircall.io: the API reference, Rate limiting, says per company; the best-practices page says per API key or OAuth token, and that exceeding it blocks access for 60 seconds). Pulse4all's account has three other keys in use by other integrations, so the adapter keeps to `aircall_max_per_minute` (a connection setting, default 60, at most 120; lower it on Configuration → Sources without a deploy), one pace per connection and process shared by the read-back, the catalogs, the reconcile and the backfill. The webhook path never waits past its budget for a slot (the event fails `paced` and the sweep reads it). On a 429 the rest of the batch is not tried: those events fail `rate_limited` and wait for their backoff, the log line `aircall rate limited` gives Aircall's `X-AircallApi-Limit`, `X-AircallApi-Remaining` and when calls resume, and the connection makes no call before `X-AircallApi-Reset` (at most 70 seconds; 60 without the header). Nothing retries in a loop. The pace is per process: the service and a job running at the same time can each use the limit, which stays under Aircall's 120 while the setting is 60 or less.

**Reconcile and backfill** list `GET /v1/calls?from&to` (UNIX seconds, the call's creation) in windows of one day, ascending, 50 per page; the list stops at 10,000 calls per query, so a window holding more is split in halves (`list_window_full` below a minute). The listing holds the full call, so a listed call is not read a second time: it becomes a synthetic event `sync:telephony_call:<id>:<fingerprint>` whose read-back takes the listed object (the fingerprint covers what the CMA keeps, never the number), so an unchanged call is written once however often it is listed. Reconcile: the calls created in the last 26 hours (a later change to an older call arrives by webhook only), then the webhook check: the webhook whose id is the setting `webhook_id` in `GET /v1/webhooks`. The run fails with `webhook_id_not_set` (no setting), `webhook_missing` (Aircall has no such webhook), `webhook_token_mismatch` (its token is not the signing secret: events would be refused), `webhook_inactive` (disabled and the re-activation failed) or `webhook_reactivated` (Aircall had disabled it after its deliveries kept failing: its documentation says after 50 retries in the API reference and after 10 failed attempts in the older webhook guide; the job set it active again with `PUT /v1/webhooks/{id}` and its own events, the token unchanged, and records that as the run's error so it is seen); `webhook_reactivated_token_changed` if Aircall ever answered the re-activation with another token (then run `aircall-webhook.mjs --delete` and create it again). A job never creates a webhook: a new one has a new token. Backfill: `--object telephony_call` from `intake.start_date` (or `--from`), resumable: the cursor `backfill:telephony_call` holds the last finished day and a run with the same start continues there.

**Never stored** (DESIGN §2.1): names, emails, the contact object, the participants, comments, recordings, voicemails, transcriptions, asset and short URLs, the other party's number (only its keyed hash), the webhook token and the API key. The user and the line are kept as ids; a line's own digits are the company's number.

**People.** `aircall-users.mjs --via-owners <HubSpot token secret>` matches each Aircall user's email to a HubSpot owner's email (in memory only) and prints, per match, the statement that puts the Aircall user id on the person who already holds that owner id (PROD_RUNBOOK 7.6, 8.7); without `--via-owners` one statement per user by email, as `hubspot-owners.mjs`. Both honour `--also-domain`, and list on stderr the Aircall user ids not matched (ids only) for Team → People → Linked accounts.

**Replay in dev.** There is no Aircall sandbox, so dev receives replayed fixtures (DESIGN §6.6): a dev connection with an invented signing secret (the token the replay puts in the body) and an invented token secret, and the setting `{"replay": true}`. The read-back then takes the call from the replayed event's own object, held in memory for that request only, with the event's time as its version (so an event replayed out of order is stale), and nothing calls Aircall (no catalogs, the reconcile lists nothing, the backfill refuses with `replay_connection`). Honoured only when the environment holds `INGEST_ALLOW_REPLAY=1`, which `deploy.sh dev` sets on the service and the jobs and `deploy.sh prod` never sets: in prod the setting does nothing and the call is read from Aircall's API. An event of a replay connection that the sweep picks up has no object any more and fails `replay_payload_gone`.

## Replay (dev and local only, invented data)

**Terminal** (in `~/cma/ingest`, after `npm ci`; the dev signing secret read into a variable without echo)
```bash
read -rsp "dev signing secret: " SIG; echo; export SIG
node tools/replay.mjs --url "<URL>/hubspot/<dev key>" --fixture verify/fixtures/hubspot/generic-batch.json --secret-env SIG --portal <CMA dev account id> --fresh
unset SIG
```
Expected: `200 {"received":10,"new":10}`. The fixture's ids do not exist in `CMA dev`, so the read-backs find nothing and finish `ignored`; it proves the signature path, not the data.

Aircall (a dev Aircall connection with the setting `{"replay": true}`; the signing secret's value read without echo):

**Terminal** (in `~/cma/ingest`)
```bash
read -rsp "dev Aircall signing secret: " SIG; echo; export SIG
node tools/replay.mjs --adapter aircall --url "<URL>/aircall/<dev key>" --fixture verify/fixtures/aircall/call-lifecycle.json --secret-env SIG --fresh
unset SIG
```
Expected: six lines `200 call.… {"received":1,"new":1}`; in **Studio (cma-dev-pg)** one `telephony_call` row for call `9100000001` with status `done`, archived, tag `9400000001` open and `9400000002` closed, `counterpart_hash` set. `verify/fixtures/aircall/not-handled.json` gives three `ignored` events (`event_not_handled`).

## Verifiers (in `ingest/`)

| Command | What | Needs |
|---|---|---|
| `npm test` | `verify/signature.mjs`, `verify/mapping.mjs`, `verify/hash.mjs` | nothing (pure) |
| `node verify/<name>.mjs --provoke` | every check must fail | nothing |
| `npm test` (also) | `verify/forms.mjs`: page host, path and UTM, the email kept out, kept fields, the poll's cursor stop, the search window, synthetic event keys, job arguments | nothing (pure) |
| `node verify/flow.mjs [--provoke]` | the service end to end against a fake HubSpot | a local PostgreSQL with `db/00…33`, see the file's header |
| `node verify/jobs-flow.mjs [--provoke]` | the jobs end to end against a fake HubSpot: sweep, forms poll, backfill with an interruption, reconcile, tenant isolation, no email stored or logged | a local PostgreSQL with `db/00…37`, see the file's header |
| `npm test` (also) | `verify/aircall-token.mjs` (right, wrong, missing and wrong-length tokens, timingSafeEqual in the code), `verify/aircall-mapping.mjs` (the six events and the unhandled ones, the call mapping and allowlist, the hash's region, the fingerprint, replay only with `INGEST_ALLOW_REPLAY=1`, the pace setting, the reset after a 429, day windows), `verify/aircall-scripts.mjs` (both scripts and the Aircall replay against fakes and a fake `gcloud`: the account check, the refusal on an existing webhook, the token piped to `versions add` and never printed, the owner match) | nothing (pure; localhost only) |
| `node verify/aircall-flow.mjs [--provoke]` | the Aircall adapter end to end against a fake Aircall: the route and its token, the six events, tags opened and closed, catalogs kept and hourly, out-of-order events, replay with and without the variable, five events read once, a 429 without retry, the hash's region, `link_calls` with a seeded CRM call, reconcile with the webhook check and the 10,000 split, the account check, the backfill resumed and paced, tenant isolation, no number, name, email or token stored or logged | a local PostgreSQL with `db/00…53`, see the file's header |

Each prints `ALL n PASS`, or with `--provoke` `ALL n PROVOKED CHECKS FAILED, as they must`.
