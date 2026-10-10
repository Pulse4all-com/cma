# The ingest service (`cma-ingest`)

The only write path into the CMA from outside Google Cloud (README Architecture, Ingest API; specification `docs/night-2026-10-10/DESIGN.md` §2, §5, §6). Code in `ingest/` (plain Node 22, ESM, `pg` and the Cloud SQL connector as `web/src/lib/db/client.ts` connects). This version (brief B7) has the HubSpot route; the jobs come with B8, Aircall with B9, Shopify with B10.

## What it does

| Route | Does |
|---|---|
| `GET /health` | `{"ok":true,"version":"<short sha>"}`; no database |
| `POST /hubspot/<connection key>` | a HubSpot webhook batch: key → connection (`cma.ingest_connection`), v3 signature, events recorded and committed, objects read back within 3 seconds, then `200 {"received":n,"new":m}` |

Answers: unknown key, inactive connection, a connection of another adapter, an unknown route or a method other than POST → `404`, empty. A bad, missing or stale signature → `401`, empty, nothing written. A body over 1 MB → `413`. A body that is not JSON → `400`. A database error before the commit, or a signing secret that cannot be read → `500` (HubSpot sends again).

Per request, in this order (DESIGN §2, the 0006 pattern):

1. **Authenticate** before anything but the key lookup touches the database: `X-HubSpot-Signature-v3` = base64(HMAC-SHA256(client secret, `POST` + URI + body + timestamp)), `X-HubSpot-Request-Timestamp` at most 5 minutes off, compared in constant time. The URI is the public address HubSpot called: the service's own URLs are in `INGEST_PUBLIC_URLS` (deploy.sh sets both Cloud Run address forms).
2. **Record** every event as a canonical event (`hs:<eventId>`, kind, object type and id, ids and timestamps only; the property value and the acting user are dropped), in one transaction, in batches of at most 500. An event of another portal is recorded as `ignored` with `raw.ignored = portal_mismatch` and never read back; so are association changes the CMA does not keep (only deal → contact, ticket → contact, call → contact and call → deal) and objects it does not read.
3. **Read back** within the budget (`INGEST_READBACK_BUDGET_MS`, 3000): deals and tickets by CRM v3 batch read with HubSpot's structural properties (pipeline, stage, owner, created, closed, modified) plus the properties configured in `cma.connection_field`, their contacts through the v4 associations batch read, the primary contact (labelled primary, else the one already held, else the lowest id) read with its configured properties; calls with their properties, the other party's number hashed (below) and dropped, their contacts and deals; contacts only when the CMA holds them (0006: never the contact base). Deletions mark the object deleted without a read; `contact.privacyDeletion` calls `cma.ingest_contact_forget()`. Pipelines with stages and the call outcome list (`/calling/v1/dispositions`) are refreshed at most hourly per connection.
4. **Upsert** through the 0006 and 0007 functions (stale guard on the source's updated time) and **finish** the events. A 429 finishes them as `failed` with `rate_limited`, a timeout with `timeout`, an HTTP error with `http_<status>`: the sweeper (B8) reads them again with backoff and parks them after `ingest.max_attempts`.

Without a market property mapped for a record type, a deal or ticket takes its primary contact's mapped country as market (and language), normalised by the market aliases (VENDOR_SETUP §1.1). A later change of the contact's country reaches the record at the record's next read (its own event or the nightly reconcile of B8).

**The keyed hash.** `HMAC-SHA256(pepper, E.164)` in hex; numbers normalised with libphonenumber, national formats with the connection setting `phone_default_region` (for example `GB`) as default region; a number that is not a possible phone number gets no hash. The pepper is per tenant: secret `ingest-hash-pepper-<tenant slug>`. Without it, calls are not read back (`pepper_unavailable`) until it exists.

**Logs** are JSON lines: connection id, adapter, counts, durations and error codes. Never payloads, contact or customer ids, numbers, emails, secrets or header values. With `INGEST_LOG_HEADER_NAMES=1` (dev) each webhook logs its header **names**, so the first delivery shows whether HubSpot sends `x-hubspot-signature-v3`.

## Configuration

| Where | What |
|---|---|
| `cma.upsert_connection('hubspot', name, <portal id>, <signing secret name>, <token secret name>)` | the connection and its key (runbook 2.2) |
| `cma.set_connection_field(...)` | the properties read and what they feed (runbook 2.2); nothing else is read |
| `cma.set_connection_settings(conn, '{"app_host":"…","phone_default_region":"GB"}')` | non-secret settings; `phone_default_region` for the call hash |
| Secret Manager | `<signing secret name>` (the app's client secret), `<token secret name>` (the static token), `ingest-hash-pepper-<tenant slug>` |

Environment (set by `deploy.sh`): `CMA_DB_INSTANCE`, `CMA_DB_USER` (`cma-ingest@<project>.iam`), `CMA_DB_NAME`, `CMA_DB_POOL_MAX`, `INGEST_VERSION`, `INGEST_PROJECT`, `INGEST_PUBLIC_URLS`, `INGEST_LOG_HEADER_NAMES` (dev 1, prod 0), `INGEST_READBACK_BUDGET_MS`. Local only: `CMA_DB_HOST`, `CMA_DB_PORT`, `CMA_DB_PASSWORD`, `CMA_DB_SET_ROLE`, `INGEST_SECRETS_DIR` (secrets as files), `INGEST_HUBSPOT_API_BASE` (a fake HubSpot on localhost; only https or localhost is accepted).

## Deploy (Martin, Cloud Shell)

**Terminal** (in `~/cma`, on main)
```bash
git switch -q main && git pull -q --ff-only && bash docs/ingest/deploy.sh dev --tenant pulse4all-subscriptions --tenant pulse4all-invest
```
Expected: the APIs enabled, the service account and its database user (first time), `created ingest-hash-pepper-…` per tenant the first time and `accessor on …`, the Cloud Build log ending in `SUCCESS`, the Cloud Run deploy, then a block with one Studio statement, the URL and `health: {"ok":true,"version":"<short sha>"}`.

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

For prod the same with `prod` (instance `cma-prod-pg`, min instances 1, max 5, no header logging).

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
| `node verify/flow.mjs [--provoke]` | the service end to end against a fake HubSpot | a local PostgreSQL with `db/00…33`, see the file's header |

Each prints `ALL n PASS`, or with `--provoke` `ALL n PROVOKED CHECKS FAILED, as they must`.
