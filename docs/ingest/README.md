# The ingest service (`cma-ingest`)

The only write path into the CMA from outside Google Cloud (README Architecture, Ingest API; specification `docs/night-2026-10-10/DESIGN.md` §2, §5, §6). Code in `ingest/` (plain Node 22, ESM, `pg` and the Cloud SQL connector as `web/src/lib/db/client.ts` connects). This version has the HubSpot route (brief B7), the jobs (brief B8), the Aircall route with its scripts (brief B9, section Aircall below), and the Shopify route with its subscription script (brief B10, section Shopify below), which since B10.1 keeps each customer's CRM contact in the CMA and writes nothing back; the outbox worker of B10 stays, generic and unscheduled (section Outbox).

## What it does

| Route | Does |
|---|---|
| `GET /health` | `{"ok":true,"version":"<short sha>"}`; no database |
| `POST /hubspot/<connection key>` | a HubSpot webhook batch: key → connection (`cma.ingest_connection`), v3 signature, events recorded and committed, objects read back within 3 seconds, then `200 {"received":n,"new":m}` |
| `POST /aircall/<connection key>` | one Aircall webhook event: key → connection, the body's `token` against the connection's signing secret, the event recorded and committed, the call read back from Aircall within 3 seconds, then `200 {"received":1,"new":0 or 1}` (section Aircall) |
| `POST /shopify/<connection key>` | one Shopify webhook delivery: key → connection, `X-Shopify-Hmac-Sha256` over the raw body with the app's client secret, the event recorded and committed, the customer or order read back through GraphQL within the route's own 1.5-second budget, then `200 {"received":1,"new":0 or 1}` (section Shopify) |

Answers: unknown key, inactive connection, a connection of another adapter, an unknown route or a method other than POST → `404`, empty. A bad, missing or stale signature (Aircall: a missing or wrong token, or a body that is not JSON; Shopify: a missing, malformed or wrong HMAC) → `401`, empty, nothing written. A body over 1 MB → `413`. A body that is not JSON → `400`. A database error before the commit, or a signing secret that cannot be read → `500` (HubSpot sends again).

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
| `ingest-sweep` | every minute | per connection, due events (received, or failed with the backoff passed) claimed and read back in parts of 100 until none is due (at most about 45 seconds); records still without a contact in their first hour read again, at most every ten minutes; Aircall's lines and tags at most hourly per connection; per tenant `cma.link_calls(now() − 2 h)`; last, the outbox guard: per tenant the outbox actions of active connections still waiting ten minutes after they fell due, counted (`outboxPending`) and logged as a warning per connection (section Outbox) | `link_calls` on the tenant's first HubSpot connection (the events are the sweep's own audit) |
| `ingest-poll-forms` | every minute | the form catalog (`GET /marketing/v3/forms`) at most hourly into `cma.connection_form` (names only; counted, lead source, market and kept fields stay as configured); per counted, active form the submissions newest first, 50 per page, until the form's cursor (`forms:<guid>`: time and conversion id of the newest read), on its first poll until `intake.start_date`; the contact by a CRM search on the definition's email field (one → resolved, none → not_found, several → ambiguous, no email → no_email), the email in memory for that search only; page host and path, UTM parameters, kept fields only (never the email field) | `forms_poll`, stream `forms` |
| `ingest-reconcile` | 02:30 | per connection and object type (deal, ticket, crm_call, contact) everything modified in the last 26 hours by CRM search, read back like a webhook (stale guard: a newer row stays); contacts only when the CMA holds them; Aircall: the calls created in the look-back (`telephony_call`) and the webhook check (section Aircall); Shopify: the customers and orders updated in the look-back and the store's subscriptions, recreated when Shopify deleted one (section Shopify); `--lookback-minutes <n>` shortens the look-back | `reconcile`, stream the object type; Shopify also `subscriptions_check`, stream `webhooks` |
| `ingest-outbox` | no schedule (since 0008h) | per CRM connection (HubSpot), the due contact write-backs of 0007c claimed 50 at a time, applied against the contacts' current values by mode and written in one batch update, each finished as sent with what was written and skipped or failed with a short code; generic, and nothing enqueues an action today (section Outbox) | none: the outbox rows are its audit |
| `ingest-backfill` | none | `--connection <id> --object <deal\|ticket\|crm_call\|form_submission\|contact\|telephony_call\|commerce_customer\|commerce_order> [--from <YYYY-MM-DD>]` (`telephony_call` for an Aircall connection, section Aircall; `commerce_customer` and `commerce_order` for a Shopify connection, section Shopify) (default `intake.start_date`, 00:00 in the tenant's zone): deals by `createdate` and then `closedate`, tickets by `createdate` and `closed_date`, calls by `hs_timestamp`, contacts the CMA holds, submissions of the counted forms; paced at half of HubSpot's documented limits (search one call per 400 ms, the rest one per 200 ms); resumable: the cursor (`backfill:<object>:<property>`) moves after every page and a run with the same start continues there | `backfill`, stream the object type |

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
| `cma.upsert_connection('shopify', name, '<handle>.myshopify.com', <client secret name>, null)` | a Shopify store connection (PROD_RUNBOOK 9.6): the account id is the store's own domain, which every delivery names in `X-Shopify-Shop-Domain`; the signing secret is the app's client secret (one per app, shared by its stores); no token secret (the token is minted) |
| `cma.set_connection_settings(conn, '{"client_id":"…","api_version":"2026-10","shop_handle":"…","crm_connection_id":"<uuid>"}')` | Shopify: the app's client id (not a secret), the API version (default `2026-10`), the store handle, and the CRM connection its customers are matched to (no setting: no match, the links stay as they are) |
| `cma.upsert_commerce_store(conn, handle, name, market, currency, zone)` (or Sources → the connection → Store) | the store row: its market is the phone hash's default region; without it the store's events fail `store_not_configured` |
| `cma.set_connection_field(<CRM conn>, 'contact', 'ref', 'shopify', <property>, <slot>)` | the contact properties holding a Shopify customer id (PROD_RUNBOOK 7.3): the match's fallback when Email is withheld, and the refs data quality and lead to order read |
| `cma.set_writeback_field(<CRM conn>, field, property, mode, enabled, slot)` | the contact properties the outbox may write, and how; no runbook step sets one since 0008h (PROD_RUNBOOK 9.5, removed); the worker writes nothing else |

Environment (set by `deploy.sh`): `CMA_DB_INSTANCE`, `CMA_DB_USER` (`cma-ingest@<project>.iam`), `CMA_DB_NAME`, `CMA_DB_POOL_MAX`, `INGEST_VERSION`, `INGEST_PROJECT`, `INGEST_PUBLIC_URLS`, `INGEST_LOG_HEADER_NAMES` (dev 1, prod 0), `INGEST_READBACK_BUDGET_MS`, `INGEST_SHOPIFY_READBACK_BUDGET_MS` (1500, from 100 to 4000: the Shopify route's own inline budget); the jobs get the database settings, `INGEST_VERSION` and `INGEST_PROJECT` only. `INGEST_ALLOW_REPLAY=1` on the service and the jobs in dev only (deploy.sh never sets it in prod; section Aircall, Replay in dev). Local only: `CMA_DB_HOST`, `CMA_DB_PORT`, `CMA_DB_PASSWORD`, `CMA_DB_SET_ROLE`, `INGEST_SECRETS_DIR` (secrets as files), `INGEST_HUBSPOT_API_BASE`, `INGEST_AIRCALL_API_BASE` and `INGEST_SHOPIFY_API_BASE` (a fake HubSpot, Aircall or Shopify on localhost, the Shopify one a URL with `{shop}`; only https or localhost is accepted), `INGEST_PACE_FACTOR` (0 to 1: scales the jobs' pacing, and Aircall's, for a verifier run against a fake source).

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

The service's caps in both projects: min 1 and max 5 instances in prod, min 0 and max 2 in dev; concurrency 20; a database pool of 5 per instance (`CMA_DB_POOL_MAX`; 3 per job); 1 CPU and 512 MiB; a 30-second request timeout; and startup CPU boost (`--cpu-boost`, since 13 October 2026, sixth Gemini audit FIND-04: a new instance starts with extra CPU, so a cold start answers sooner). The route answers after its read-back, not before: Cloud Run throttles the CPU once the response is sent, so work after it would crawl (Decision log, 13 October 2026). To see the boost on the deployed service:

**Terminal**
```bash
gcloud run services describe cma-ingest --project=p4a-cma-prod --region=europe-west4 --format=json | grep -o '"run.googleapis.com/startup-cpu-boost": *"[a-z]*"'
```
Expected: `"run.googleapis.com/startup-cpu-boost": "true"` (the same with `p4a-cma-dev`).

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
Expected: lines `a.` to `e.` (`created` the first time, `exists` on a rerun; the two rules `c. rule 900 (create|update): /shopify/, 2400 requests per 60 s per IP, then 429` and `c. rule 1000 (create|update): every other request, 600 requests per 60 s per IP, then 429`), then the A record `ingest.pulse4all.app → <address of cma-web-ip>`, the certificate status (`PROVISIONING` at first) and the two checks. `--rate-per-minute <n>` changes rule 1000 (default 600 per IP), `--shopify-rate-per-minute <n>` rule 900 (default 2400 per IP).

**Cloud Armor rules** of `cma-ingest-armor` (README Decision log, 12 and 13 October 2026). Rules are evaluated by priority, the lowest number first, and a request a throttle rule matches stops there, so Shopify's deliveries count against rule 900 only:

| Priority | Matches | Per client IP | Over the limit |
|---|---|---|---|
| 900 (since 13 October 2026) | `request.path.startsWith('/shopify/')` | 2,400 requests per 60 seconds | `429` (deny-429) |
| 1000 (since 12 October 2026) | every other request (source IP ranges `*`) | 600 requests per 60 seconds | `429` (deny-429) |
| default | everything else | allow | |

Rule 900 exists because a store's renewal run sends its order and customer deliveries in a burst from Shopify's senders (sixth Gemini audit FIND-01); the general limit stays at 600 (about 2.5 requests per second at peak on 13 October 2026, no 429 in the last day). There is no IP allow-list: every source signs its requests, and a 429 makes HubSpot, Aircall and Shopify retry with backoff. Both rules are created by `front.sh`, or updated to its values when they exist, so a rerun is how a limit changes. What step c would send, without any gcloud call:

**Terminal**
```bash
bash docs/ingest/front.sh prod --host ingest.pulse4all.app --dry-run
```
Expected: the three rows above (900, 1000, default) and the two `gcloud compute security-policies rules create` commands (step c updates a rule that exists), the first with `--expression=request.path.startsWith('/shopify/')` and `--rate-limit-threshold-count=2400`, the second with `--src-ip-ranges=*` and `--rate-limit-threshold-count=600`, both `--action=throttle --exceed-action=deny-429 --enforce-on-key=IP`.

**Terminal** (after a real run: the rules in the policy)
```bash
gcloud compute security-policies describe cma-ingest-armor --project=p4a-cma-prod --flatten='rules[]' --format='table(rules.priority,rules.match.expr.expression,rules.rateLimitOptions.rateLimitThreshold.count,rules.action)'
```
Expected: three rows: `900  request.path.startsWith('/shopify/')  2400  throttle`, `1000  600  throttle` (no expression: it matches the source ranges `*`) and `2147483647  allow` (the default rule).

**The 429 alert** (README Decision log, 13 October 2026, fifth Gemini audit FIND-02). Cloud Armor answers a throttled request at the load balancer, so its 429s never reach the Cloud Run request log, and the backend's logging is off; the load balancer's request count holds them. `docs/ingest/alert.sh` creates the Cloud Monitoring alert policy `cma-ingest 429` on `loadbalancing.googleapis.com/https/request_count`, filtered to `backend_target_name = cma-ingest-backend` and `response_code = 429`, summed over 5 minutes and firing when the sum is above 0 for 1 minute (condition duration 60s: Cloud Monitoring requires a non-zero duration when missing data is treated as inactive, and one 429 keeps the 5-minute sum above 0 for about five minutes, so one 429 still fires), with an email channel (created when the project has none for the address). An existing policy with that name is updated, never duplicated. It uses `gcloud monitoring policies` (GA) and `gcloud beta monitoring channels` (channels exist only in beta and alpha); the policy goes in as JSON with `--policy`, so no policy file is kept. In dev the policy finds no series (no load balancer) and stays quiet.

**Terminal** (first what it would create, then the policy; the address is where alerts go, for example a group)
```bash
bash docs/ingest/alert.sh prod --email <address> --dry-run
bash docs/ingest/alert.sh prod --email <address>
```
Expected: the dry run prints the policy JSON: the filter with `resource.labels.backend_target_name = "cma-ingest-backend"` and `metric.labels.response_code = 429`, `"alignmentPeriod": "300s"` with `ALIGN_SUM` and `REDUCE_SUM`, `COMPARISON_GT` 0, `"duration": "60s"` and `"evaluationMissingData": "EVALUATION_MISSING_DATA_INACTIVE"`; the real run prints `a. email channel created|exists: projects/p4a-cma-prod/notificationChannels/<id>`, `b. policy created|updated: projects/p4a-cma-prod/alertPolicies/<id>`, and the check line `cma-ingest 429  True  <the filter>  300s  60s  <the channel>`. A rerun says `exists` and `updated`; a rerun after a failed policy create says `a. email channel exists` and `b. policy created`.

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

**Catalogs.** Lines (`GET /v1/numbers`: id, name, the company's own digits) and tags (`GET /v1/tags`: id, name) go into `cma.ingest_upsert_telephony_catalog`: from the sweep at most hourly per connection (cursor `catalogs`), and on the first event of a connection whose line catalog is empty. A line's market and counted flag and a tag's counted flag are configuration and stay (0007a); an entry Aircall no longer lists is archived. A catalog above 500 entries is not refreshed (logged as `catalog_too_large`). Pulse4all's account has 54 lines: each needs its market and counted flag on Configuration → Sources (no rule for lines yet). Since addition 0008f a connection stores calls on its counted lines only: a call on a line that does not count is read but not written (outcome `skipped_uncounted_line` in the `processed` log line; a reconcile or backfill run counts it as skipped), and switching a line off removes its stored calls. A new line arrives counted, so one Aircall company serving several tenants, each with its own connection and webhook, marks the other business lines' lines not counted (PROD_RUNBOOK 8.6).

**Pacing.** Aircall allows 120 requests per minute (developer.aircall.io: the API reference, Rate limiting, says per company; the best-practices page says per API key or OAuth token, and that exceeding it blocks access for 60 seconds). Pulse4all's account has three other keys in use by other integrations, so the adapter keeps to `aircall_max_per_minute` (a connection setting, default 60, at most 120; lower it on Configuration → Sources without a deploy), one pace per connection and process shared by the read-back, the catalogs, the reconcile and the backfill. The webhook path never waits past its budget for a slot (the event fails `paced` and the sweep reads it). On a 429 the rest of the batch is not tried: those events fail `rate_limited` and wait for their backoff, the log line `aircall rate limited` gives Aircall's `X-AircallApi-Limit`, `X-AircallApi-Remaining` and when calls resume, and the connection makes no call before `X-AircallApi-Reset` (at most 70 seconds; 60 without the header). Nothing retries in a loop. The pace is per process: the service and a job running at the same time can each use the limit, which stays under Aircall's 120 while the setting is 60 or less.

**Reconcile and backfill** list `GET /v1/calls?from&to` (UNIX seconds, the call's creation) in windows of one day, ascending, 50 per page; the list stops at 10,000 calls per query, so a window holding more is split in halves (`list_window_full` below a minute). The listing holds the full call, so a listed call is not read a second time: it becomes a synthetic event `sync:telephony_call:<id>:<fingerprint>` whose read-back takes the listed object (the fingerprint covers what the CMA keeps, never the number), so an unchanged call is written once however often it is listed. Reconcile: the calls created in the last 26 hours (a later change to an older call arrives by webhook only), then the webhook check: the webhook whose id is the setting `webhook_id` in `GET /v1/webhooks`. The run fails with `webhook_id_not_set` (no setting), `webhook_missing` (Aircall has no such webhook), `webhook_token_mismatch` (its token is not the signing secret: events would be refused), `webhook_inactive` (disabled and the re-activation failed) or `webhook_reactivated` (Aircall had disabled it after its deliveries kept failing: its documentation says after 50 retries in the API reference and after 10 failed attempts in the older webhook guide; the job set it active again with `PUT /v1/webhooks/{id}` and its own events, the token unchanged, and records that as the run's error so it is seen); `webhook_reactivated_token_changed` if Aircall ever answered the re-activation with another token (then run `aircall-webhook.mjs --delete` and create it again). A job never creates a webhook: a new one has a new token. Backfill: `--object telephony_call` from `intake.start_date` (or `--from`), resumable: the cursor `backfill:telephony_call` holds the last finished day and a run with the same start continues there.

**Never stored** (DESIGN §2.1): names, emails, the contact object, the participants, comments, recordings, voicemails, transcriptions, asset and short URLs, the other party's number (only its keyed hash), the webhook token and the API key. The user and the line are kept as ids; a line's own digits are the company's number.

**People.** `aircall-users.mjs --via-owners <HubSpot token secret>` matches each Aircall user's email to a HubSpot owner's email (in memory only) and prints, per match, the statement that puts the Aircall user id on the person who already holds that owner id (PROD_RUNBOOK 7.6, 8.7); without `--via-owners` one statement per user by email, as `hubspot-owners.mjs`. Both honour `--also-domain`, and list on stderr the Aircall user ids not matched (ids only) for Team → People → Linked accounts.

**Replay in dev.** There is no Aircall sandbox, so dev receives replayed fixtures (DESIGN §6.6): a dev connection with an invented signing secret (the token the replay puts in the body) and an invented token secret, and the setting `{"replay": true}`. The read-back then takes the call from the replayed event's own object, held in memory for that request only, with the event's time as its version (so an event replayed out of order is stale), and nothing calls Aircall (no catalogs, the reconcile lists nothing, the backfill refuses with `replay_connection`). Honoured only when the environment holds `INGEST_ALLOW_REPLAY=1`, which `deploy.sh dev` sets on the service and the jobs and `deploy.sh prod` never sets: in prod the setting does nothing and the call is read from Aircall's API. An event of a replay connection that the sweep picks up has no object any more and fails `replay_payload_gone`.

## Shopify

The Shopify adapter (briefs B10 and B10.1; DESIGN §2, §2.1, §4.3, §4.3a, §6; additions 0008g and 0008h), `ingest/src/adapters/shopify/`. The prod sequence is `docs/ingest/PROD_RUNBOOK.md` phase 9; this section is what each step relies on.

**Shopify's rules, checked on shopify.dev on 13 October 2026** (the pages: `shopify.dev/docs/api/usage/versioning`, `…/apps/build/webhooks`, `…/apps/build/webhooks/verify-deliveries`, `…/apps/build/webhooks/troubleshoot`, `…/apps/build/authentication-authorization/client-credentials-grant`, `…/apps/launch/protected-customer-data`, `…/apps/build/apis/graphql-admin/rate-limits`, `…/api/usage/access-scopes`):

- **API version.** `2026-10` is the latest stable version (released 1 October 2026, supported until 16 October 2027; `2027-01` is the release candidate). It is pinned as the default; a connection setting `api_version` overrides it. Shopify releases quarterly and supports a version for at least 12 months, so the setting moves once a year.
- **Delivery.** "Shopify has a one-second connection timeout and a five-second timeout for the entire request"; any answer other than 2xx, a redirect included, is a failure. "If Shopify receives no response or an error, it retries 8 times over the next 4 hours. After 8 consecutive failures, the subscription is automatically deleted if it was configured using the Admin API", and Shopify emails the app's emergency developer address. Deliveries are not in order and can arrive late (up to a day); Shopify recommends a reconciliation job, which the nightly reconcile is.
- **Headers.** `X-Shopify-Topic`, `X-Shopify-Hmac-Sha256`, `X-Shopify-Shop-Domain`, `X-Shopify-API-Version`, `X-Shopify-Webhook-Id`, `X-Shopify-Triggered-At`, `X-Shopify-Event-Id`. Shopify's duplicate key is `X-Shopify-Webhook-Id` (the same on every retry of a delivery); `X-Shopify-Event-Id` is shared by every delivery one merchant action causes. The CMA keys events by the webhook id (below), a deviation from DESIGN §2, which named the event id before this was checked.
- **HMAC.** Base64 HMAC-SHA256 of the raw body with the app's client secret. After a rotation of the client secret Shopify may sign with the old one for up to an hour; a delivery the service refuses in that hour (401) is retried by Shopify (eight times over four hours), so a rotation loses nothing once the new secret is the latest version in Secret Manager (the service reads it within five minutes).
- **Token.** Apps of the Dev Dashboard use the client credentials grant: `POST https://<shop>/admin/oauth/access_token`, form-encoded `grant_type=client_credentials`, `client_id`, `client_secret`; the answer is `{access_token, scope, expires_in}` with `expires_in` 86399 (24 hours), no refresh token (mint again). It works only for stores in the app's organisation (`shop_not_permitted` otherwise).
- **Protected customer data.** Level 1 is customer data without the protected fields; Name, Email, Phone and Address are requested one by one (Level 2). For a custom-distribution app both levels are "always available" (selected, not reviewed). A field the app is not granted is `null` in GraphQL (with an `ACCESS_DENIED` entry in `errors`) and redacted in webhook bodies. In Pulse4all's Dev Dashboard (14 October 2026) there was nothing to select: the custom-distribution app got every customer field (name, email, phone, address, device data) and the store owner's staff data automatically, so minimisation rests on what the adapter reads (of the protected fields, email and phone only) and on the client secret (README Decision log, 14 October 2026). Shopify still withholds the order's own `phone`: `CmaOrders` answers with a partial `ACCESS_DENIED`, which `client.mjs` reads as an empty field; the Dev Dashboard counts those answers as errors (about 51% for the NL store), the orders are complete. Since API version 2025-01 customer webhooks no longer carry the order count and amount spent, which is why the adapter reads the customer with every order (below).
- **Rate limit.** GraphQL is limited by query cost per app and store: a bucket that refills at the plan's restore rate (standard 100 points a second, Advanced 200, Plus 1,000, Enterprise 2,000), one query at most 1,000 points; every answer carries `extensions.cost.throttleStatus`. `read_orders` covers the last 60 days; older orders need `read_all_orders`, which the Dev Dashboard did not offer on 14 October 2026 and which has no API access requests page to ask for it (README Open decisions).

**Setup, once per app and per store** (PROD_RUNBOOK 9.1 to 9.8): the app's client secret into Secret Manager (`ingest-shopify-app-signing`, granted to the service); per store the connection (`upsert_connection('shopify', <name>, '<handle>.myshopify.com', 'ingest-shopify-app-signing', null)`, kind `commerce`), its settings (`client_id`, `api_version`, `shop_handle`, `crm_connection_id`), its store row with market, currency and zone, the renewal settings for its subscription app, the subscriptions by `shopify-subscribe.mjs`, the backfill.

**Per delivery** (one object per request): the HMAC of the raw body against the signing secret, compared in constant time (`crypto.timingSafeEqual` on the two base64 strings; another length is a failure); a failure is `401`, empty, nothing written. The event is recorded as `sh:<X-Shopify-Webhook-Id>` (without it `sh:<topic>:<X-Shopify-Event-Id>`, else a digest of the body), ids, the topic, the trigger time and the API version only, never the body. A delivery whose `X-Shopify-Shop-Domain` is not the connection's account is recorded as `ignored` with `portal_mismatch`; a topic other than the seven as `ignored` with `event_not_handled`. Kinds: `customers/create`, `orders/create` → `created`; `customers/update`, `orders/updated`, `orders/cancelled` → `changed`; `customers/delete`, `orders/delete` → `deleted` (no read: marked deleted at the event's time, the phone hash cleared). Then, within the route's own budget (`INGEST_SHOPIFY_READBACK_BUDGET_MS`, default 1500 ms, well inside Shopify's five seconds), the object is read back and written; what the budget does not cover fails for the sweep a minute later.

**Read-back** (`read.mjs`): orders by `nodes(ids)`, five a call: name, times, cancellation, test, currency and the five amounts, financial and fulfilment status, `sourceName` and the app's id (what the renewal settings name), tags, the visit that brought the order (`customerJourneySummary.firstVisit`, else `lastVisit`: the landing page reduced to host and path, the five UTM tags, the referrer's host), the first ten line items (the rest paged a hundred at a time, at most 500) and the order's customer with the customer's own fields. Then the prior order count, 25 orders a call: the customer's `numberOfOrders` minus `ordersCount(query: "customer_id:<id> AND created_at:>='<created>'")` (this order included), exact when Shopify's count is `EXACT`; when the search does not hold the new order yet (a count of 0), the order is written with `order_kind` unknown and its next read (an `orders/updated` delivery, the reconcile) counts again. Customers by `nodes(ids)`, fifty a call, unless an order of the batch brought them: state, locale, `numberOfOrders`, `amountSpent`, times, and in memory `defaultEmailAddress` and `defaultPhoneNumber` (Shopify deprecated the customer's `email` and `phone` fields). A customer or order Shopify no longer has finishes `ignored`.

**The phone** (addition 0008g; Decision log, 13 October 2026): the order's own `phone`, else its customer's `defaultPhoneNumber` (never a billing or shipping address phone: the adapter does not read addresses, although Shopify grants them; whether to read the shipping address's phone as a fallback is a README Open decision, Indirect sales), hashed with the tenant's pepper and the store's market as the default region, exactly as a call's other party (`src/core/hash.mjs`), into `phone_hash` on the order and on the customer; the number is dropped. When the store withholds Phone, the hash is null and nothing fails. Shopify withholds the order's own `phone` (above), so in practice an order's hash is its customer's: 339 of 501 orders of the NL store carried one on 14 October 2026. Without the tenant's pepper nothing is read (`pepper_unavailable`).

**The match, kept in the CMA** (`match.mjs`; addition 0008h; README Decision log, 13 October 2026): every customer read (on its own or with an order) is matched once per batch to a contact of the CRM connection named by the setting `crm_connection_id`, stopping at the first that answers: (1) known: the customer's link in the CMA (`commerce_customer.crm_contact_source_id`) to a contact of that connection, checked to still exist as itself by one batch read of every linked contact of the batch (the object id only; a contact deleted or merged into another is not there, and the customer goes on to the next steps), then the contacts the CMA holds whose refs hold the customer id (no CRM call either way, so repeat and renewal orders cost no search); (2) the customer's email, searched in the CRM (exact, lower case), then dropped; (3) when the store withholds Email: the contacts whose ref properties hold the customer id (the CRM connection's contact ref fields for `shopify`, `cma.set_connection_field(<CRM conn>, 'contact', 'ref', 'shopify', <property>, <slot>)`). Exactly one contact → the link set by `cma.set_commerce_customer_contact` (`linked`, `relinked` or `unchanged`; `matched_at` is the time of the match); none or several → the link cleared (`cleared`, or `unlinked` when there was none), counted as `match_none` or `match_several` in the `processed` log line (no ids). A deleted customer's link is cleared with its deletion (no read), and the CRM's privacy deletion of a contact (the HubSpot adapter's forget) clears every link to it (`cma.forget_commerce_contact_links`). **Nothing is written to the CRM**: the HubSpot–Shopify app writes the Shopify contact fields and creates a Self Serve deal per new order, one writer per property; no outbox action is enqueued. The searches keep to one per 400 ms per CRM connection and process (HubSpot allows five a second); a webhook never waits past its budget for one (`paced`, the sweep reads it). A CRM that cannot answer fails the event with `crm_<code>` and the sweep tries again. A store without `crm_connection_id` leaves its links as they are (`match_not_configured`).

**Pacing** (`client.mjs`): one cost-bucket estimate per shop and process, from Shopify's standard plan (1,000 points, 100 a second) until the shop's first answer, then the shop's own `throttleStatus`. A call takes its estimated cost before it is sent (the estimate may go below zero, so a burst queues). The webhook path waits for points only while a second of its budget is left for the call, else the event fails `throttled` and the sweep reads it; the jobs wait for the refill. A `THROTTLED` answer or a 429 empties the estimate and fails `rate_limited`. A renewal run's burst of orders is therefore answered at once (the flow verifier's burst of 200: every answer within a second) and read by the sweep within the bucket. One token per shop and app is minted for the whole process and burst and cached until five minutes before it expires; a 401 drops it.

**Reconcile, backfill and the subscription check** (`reconcile.mjs`): reconcile lists `customers` and `orders` with `updated_at` in the look-back (26 hours), sorted by `UPDATED_AT`, 100 a page, ids and times only; each becomes a synthetic event `sync:<type>:<id>:<updatedAt>` on the webhook's read-back, so an unchanged object is read once. Then the subscription check (sync_run `subscriptions_check`): the shop's `webhookSubscriptions` whose address ends in `/shopify/<connection key>`; all seven there → nothing; some missing (Shopify deletes a subscription after eight failed deliveries) → created again at the address of one that remains and the run's error is `subscriptions_recreated`, so it is seen; none left → `subscriptions_missing` (run `shopify-subscribe.mjs`; the job does not know the public address). Deliveries missed while a subscription was gone are covered by the 26-hour look-back. Backfill: `--object commerce_customer` or `commerce_order` from `intake.start_date` (or `--from`), `created_at` ascending, resumable from the cursor `backfill:<type>` after every page.

**Never stored** (DESIGN §2.1): names, email addresses, phone numbers (only the keyed hash), postal addresses, notes, the landing page's query beyond the five UTM tags, the referrer beyond its host, the client secret and the token. The flow verifier greps every database row of its run (the audit log included) and every log line for the fixture emails and numbers.

**The subscriptions** (`docs/ingest/shopify-subscribe.mjs`, run from Cloud Shell with your own gcloud login; the client secret is read from Secret Manager into memory and the token is minted for the run, neither printed):

**Terminal** (in `~/cma`; `<key>` is the store connection's key)
```bash
node docs/ingest/shopify-subscribe.mjs --project p4a-cma-prod --shop <handle>.myshopify.com --client-id <client id> --secret-name ingest-shopify-app-signing --url "https://ingest.pulse4all.app/shopify/<key>"
```
Expected: seven lines `created  gid://shopify/WebhookSubscription/<id>  <TOPIC>` (on a rerun `exists …`). `--list` prints every subscription of the shop (`*` marks the address of `--url`), `--delete <id>` deletes one, and `--source-names [--days 30]` prints the sales channels and apps of the store's recent orders with their counts (what the renewal settings name; no customer data).

## Outbox

The outbox worker (`ingest/src/jobs/outbox.mjs`, the job `ingest-outbox`; DESIGN §4.3a; migration 0007c) delivers CRM contact write-backs. **It is generic and, since 0008h, unused** (README Decision log, 13 October 2026): the CMA writes nothing back for a store's customers, so nothing enqueues an action, and `deploy.sh` deploys the job without a schedule (a schedule an earlier deploy made is paused). It stays for a write-back a later decision configures, with `verify/outbox-flow.mjs` proving it. Per CRM connection whose adapter writes contacts (HubSpot, `src/adapters/hubspot/write.mjs`): the due actions are claimed 50 at a time (`FOR UPDATE SKIP LOCKED`, never two of one contact), the contacts' current values of the enabled write-back properties are read in one batch read, each action is planned by mode, and the differences are written in one batch update:

- `always` writes when the value differs (`240` equals `240.00`); `if_empty` writes only into an empty property, so an agent's country, currency or language is never overwritten; `slot` (the customer id only) leaves the id where it already is, else fills slot 1, else slot 2, and writes nothing when both hold other ids (`slots_full`).
- The store and the two totals describe the customer in slot 1: written only when this customer's id is, or just became, slot 1.
- A property that is not an enabled write-back field of the connection is refused in code (`property_not_configured`), after the database already kept only enabled fields at the enqueue; a field disabled after the enqueue is not written.

Each action finishes as `sent` with its result (`written` and `skipped` properties with the reason, `ref` written, present or slots_full, and the `slot`), or `failed` with `rate_limited`, `timeout`, `http_<status>`, `contact_not_found` (the contact is gone from HubSpot) or `contact_rejected`; the claim set the next attempt already (1, 2, 4 … 60 minutes) and after `outbox.max_attempts` (8) the action is parked as `needs_review` for a person to retry or drop. The job reads and writes contact properties only; it never reads an email.

**Studio (cma-prod-pg)**: the outbox per state:
```sql
set role cma_owner;
select c.name, o.status, o.error, count(*), max(o.created_at) from cma.outbox_action o join cma.integration_connection c on c.id = o.connection_id group by 1, 2, 3 order by 1, 2;
reset role;
```
Expected today: no rows. Once a later decision configures a write-back and schedules the job: `sent` rows growing, `pending` only for the last minute, `needs_review` none (each needs a person: `select cma.outbox_resolve('<id>', 'retry' | 'drop');` after the context block).

**The outbox guard** (sixth Gemini audit FIND-05, 13 October 2026). Because the job has no schedule, an action enqueued now would wait unseen. The sweep (every minute) counts, per tenant and active connection, the actions the outbox still has to deliver (`pending`, `failed` for a retry, or `in_flight` from a run that never finished) that fell due more than ten minutes ago, returns the total as `outboxPending` and logs one warning per connection (`sweep: outbox actions overdue, ingest-outbox unscheduled or not running`, code `outbox_pending`, the connection id and the count; no action or contact id). The sweep cannot see Cloud Scheduler (`cma-ingest` holds no Scheduler role), so the missing schedule is read from the rows: a scheduled outbox claims due actions every minute, so ten minutes late means no run claimed them. Reports → Data quality shows the same count as the row "Contact updates not sent" (`outbox_pending`) while it is above 0 and hides it at 0. Expected today: no such warning and no such row.

**Terminal** (the guard's warnings of the last day)
```bash
gcloud logging read 'resource.type=cloud_run_job AND resource.labels.job_name=ingest-sweep AND jsonPayload.code="outbox_pending"' --project=p4a-cma-prod --freshness=1d --limit=10 --format='value(timestamp,jsonPayload.connection,jsonPayload.outboxPending)'
```
Expected: nothing. A line means actions are waiting: find what enqueued them (the Studio query above), then schedule the job (a `deploy.sh` change, Open decisions) or stop what enqueues them.

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
| `node verify/jobs-flow.mjs [--provoke]` | the jobs end to end against a fake HubSpot: sweep, the sweep's outbox guard (an action ten minutes overdue reported with one warning and no ids; a fresh one, another tenant's and a delivered one not), forms poll, backfill with an interruption, reconcile, tenant isolation, no email stored or logged | a local PostgreSQL with `db/00…38`, see the file's header |
| `npm test` (also) | `verify/aircall-token.mjs` (right, wrong, missing and wrong-length tokens, timingSafeEqual in the code), `verify/aircall-mapping.mjs` (the six events and the unhandled ones, the call mapping and allowlist, the hash's region, the fingerprint, replay only with `INGEST_ALLOW_REPLAY=1`, the pace setting, the reset after a 429, day windows), `verify/aircall-scripts.mjs` (both scripts and the Aircall replay against fakes and a fake `gcloud`: the account check, the refusal on an existing webhook, the token piped to `versions add` and never printed, the owner match) | nothing (pure; localhost only) |
| `npm test` (also) | `verify/shopify-signature.mjs` (the HMAC of the raw body: right, wrong secret, a changed byte, a re-serialised body, missing or malformed header, timingSafeEqual in the code), `verify/shopify-mapping.mjs` (the seven topics and their kinds, the webhook-id key and its fallbacks, shop pinning, unhandled topics, ids, the prior-count arithmetic including a customer with older orders and the search lag, customers and orders mapped with nothing personal, pages reduced to host, path and UTM, lines, the queries asking for no more than they need, the API version and the route's budget), `verify/shopify-client.mjs` (one token for five callers, cached, minted again within five minutes of its expiry, refusals; THROTTLED, ACCESS_DENIED, 401 and 429 answers; the cost bucket: a webhook never waiting past its budget, a job waiting, callers queueing), `verify/shopify-scripts.mjs` (`shopify-subscribe.mjs` against a fake Shopify and a fake `gcloud`: refusals, the seven topics with `uri`, a rerun creating nothing, a missing topic recreated, list, delete, source names, never the secret or the token), `verify/outbox.mjs` (the modes: `if_empty` keeps an agent's value, `slot` fills 1 then 2 and stops at full, the totals only with slot 1, `always` writes only a difference, a property not configured refused); `verify/hash.mjs` also proves an order's or customer's phone hashes like a call's | nothing (pure; localhost only) |
| `node verify/shopify-flow.mjs [--provoke]` | the Shopify adapter end to end against a fake Shopify (token grant, GraphQL with a cost bucket) and a fake HubSpot: the route and its HMAC, another shop and another topic ignored, duplicates, customers hashed and matched by email, held refs or the ref properties, the link kept in the CMA (set, reused by later orders with one batch read and no search, cleared when its contact is gone and none or two answer, moved to the survivor of a merge, cleared by the customer's deletion and by the CRM's privacy deletion), Email and Phone withheld, no match and two matches, no outbox row and no HubSpot write even with write-back fields enabled, orders first, repeat, renewal and unknown with lines paged, the token's cache and expiry, a burst of 200 deliveries answered within Shopify's five seconds and read by the sweep, reconcile, the subscription check, the backfill resumed, tenant isolation, no email or number in any database row or log | a local PostgreSQL with `db/00…58`, see the file's header |
| `node verify/outbox-flow.mjs [--provoke]` | the generic outbox worker against a fake HubSpot, with actions enqueued through the core's `writes.writebacks` (nothing in the CMA enqueues one today): a newer action superseding a pending one, a 429 with backoff then sent, the modes against the contacts' values, a field disabled after the enqueue, only enabled properties read and written, a contact gone, counts and codes only in the log | a local PostgreSQL with `db/00…58`, see the file's header |
| `node verify/aircall-flow.mjs [--provoke]` | the Aircall adapter end to end against a fake Aircall: the route and its token, the six events, tags opened and closed, catalogs kept and hourly, out-of-order events, replay with and without the variable, five events read once, a 429 without retry, the hash's region, `link_calls` with a seeded CRM call, reconcile with the webhook check and the 10,000 split, the account check, the backfill resumed and paced, tenant isolation, no number, name, email or token stored or logged | a local PostgreSQL with `db/00…53`, see the file's header |

Each prints `ALL n PASS`, or with `--provoke` `ALL n PROVOKED CHECKS FAILED, as they must`.
