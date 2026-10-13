# Morning runbook, B10.1: the commerce contact link (0008h), nothing written back

**Ran on 13 October 2026.** Steps 2 and 3: 0008h in dev at 14:30:54 UTC and in prod at 14:31:27 UTC (`cma.schema_migration`), records `records/0008h-dev-2026-10-13` (`59` 13 PASS; provoked all 13 FAIL; `57` rerun 12 PASS) and `records/0008h-prod-2026-10-13` (`31`, `33` and `37` reruns PASS). Step 4, the merge, is `Pulse4all-com/cma#115`. The steps below stay as written; README (Environments) holds the status.

Labels: **Browser**, **Terminal** (Cloud Shell, in `~/cma` unless stated), **Studio** (the instance named), **File** (a repository path). SQL and shell never share a block. Every step ends with what you should see. The local outputs are in `local-records/` (its `README.md` lists them).

**What changes:** the CMA writes nothing back to HubSpot for Shopify (the HubSpot–Shopify app writes the Shopify contact fields and creates a Self Serve deal per new order; one writer per property). The Shopify match stays and is kept in the CMA: `cma.commerce_customer` gains the matched contact (addition 0008h). The outbox job `ingest-outbox` stays deployed but without a schedule (README Decision log, 13 October 2026).

**Order matters:**
- 0008g (`56`, brief B10) must have run in the database first; without it `58` stops with `addition 0008g (56_commerce_phone_hash.sql) must run before 0008h` and applies nothing. If B10's morning runbook (`docs/b10-shopify/MORNING_RUNBOOK.md`) has not run yet: run its steps 1 to 3 (0008g in dev and prod) first and skip its steps 5 to 7; this runbook deploys the newer code.
- 0008h (`58`) runs in dev and prod **before** the ingest service is deployed from this merge. The new service calls `cma.forget_commerce_contact_links` with every HubSpot privacy deletion and `cma.set_commerce_customer_contact` with every Shopify customer it reads; deployed before `58`, a HubSpot privacy deletion would fail (`db_42883`) until it runs.
- Merging deploys nothing of the ingest service (only `web/**` and `cloudbuild.yaml` trigger a build, and this pull request changes neither); the ingest is deployed by hand with `docs/ingest/deploy.sh`.

| Step | What | Elapsed |
|---|---|---|
| 1 | Review the pull request, run the ingest checks in Cloud Shell | 20 min |
| 2 | 0008h in dev with its verify | 10 min |
| 3 | 0008h in prod, then a read-only check | 10 min |
| 4 | Merge | 5 min |
| 5 | The ingest service and jobs in dev on the new image | 15 min |
| 6 | Optional: the dev store end to end (VENDOR_SETUP §3.3) | 45 min |
| 7 | The ingest service and jobs in prod; then `docs/ingest/PROD_RUNBOOK.md` phase 9 | per phase 9 |

---

## Helpers (define in every new Cloud Shell)

The helpers `cma_db` and `run_migration` of `docs/night-2026-10-13/MORNING_RUNBOOK.md`, section Helpers, unchanged: paste that block first.

Expected: `type cma_db run_migration` prints both functions.

## 1. Review the pull request and run the ingest checks

**Browser:** GitHub → Pulse4all-com/cma → Pull requests → "B10.1: keep the Shopify customer's CRM contact in the CMA, write nothing back (0008h)". Read the description and the diff.

Expected: no change to `web/`, `cloudbuild.yaml` or `records/`; `db/57_verify_commerce_phone_hash.sql` changes in its check A3 only (it accepts the three columns of 0008h once 0008h is recorded); no other script that has run in prod changes.

**Terminal** (the pull request's number from the page)
```bash
cd ~/cma && gh pr checkout <number> && cd ingest && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run lint && npm test 2>&1 | grep -E "^ALL|FAILED"; cd ~/cma
```
Expected: `found 0 vulnerabilities`, no lint output after the `eslint` line, and twelve lines `ALL n PASS` (18, 37, 26, 41, 20, 49, 27, 17, 51, 21, 21, 20), no `FAILED`. **Do not merge yet.**

## 2. Addition 0008h in dev

**Studio (cma-dev-pg)** (read only: 0008g is there)
```sql
set role cma_owner;
select version from cma.schema_migration where version in ('0008g', '0008h') order by 1;
reset role;
```
Expected: `0008g` only. Without it: B10's runbook steps 2 and 3 first (see Order matters).

**Terminal** (still on the pull request's branch)
```bash
run_migration dev 58_commerce_contact_link.sql 59_verify_commerce_contact_link.sql 0008h-dev-$(date +%F) 57_verify_commerce_phone_hash.sql 37_verify_commerce.sql 33_verify_intake_core.sql 31_verify_ingest_crm_records.sql
```
Expected: `connected to cma as martin@pulse4all.com`; the last lines of `58` are `INSERT 0 1`, `COMMIT`, `RESET` (no `ERROR`); `59` ends with the verdict row `PASS | 13 PASS, 0 FAIL`; `provoked FAIL lines: 14` and the verdict `PROVOKED, NOT A PASS | 0 PASS, 13 FAIL`; `57_verify_commerce_phone_hash.sql: 13 PASS rows`, `37_verify_commerce.sql: 2 PASS rows`, `33_verify_intake_core.sql: 2 PASS rows`, `31_verify_ingest_crm_records.sql: 2 PASS rows`. A `REFUSED` line means the session is not on dev: check `cma_db dev`.

## 3. Addition 0008h in prod

**Terminal** (point-in-time recovery on, as before every prod migration)
```bash
gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format="value(settings.backupConfiguration.pointInTimeRecoveryEnabled,settings.backupConfiguration.transactionLogRetentionDays)"
```
Expected: `True	7`.

`59` and `57` refuse prod (they write throwaway tenants and run in dev only), so prod runs the migration and the earlier verifies, then a read-only check.

**Terminal**
```bash
rec=records/0008h-prod-$(date +%F); mkdir -p "$rec" && cma_db prod && psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/58_commerce_contact_link.sql > "$rec/58.txt" 2>&1; tail -3 "$rec/58.txt"
for f in 37_verify_commerce.sql 33_verify_intake_core.sql 31_verify_ingest_crm_records.sql; do psql "$PGCONN" -v ON_ERROR_STOP=1 -f "db/$f" > "$rec/${f%%_*}-rerun.txt" 2>&1; echo "$f: $(grep -cE '\| PASS' "$rec/${f%%_*}-rerun.txt") PASS rows"; done
```
Expected: `connected to cma as martin@pulse4all.com`; `INSERT 0 1`, `COMMIT`, `RESET`; then `37_verify_commerce.sql: 2 PASS rows`, `33_verify_intake_core.sql: 2 PASS rows`, `31_verify_ingest_crm_records.sql: 2 PASS rows`. A rerun of `58` ends `INSERT 0 0`, `COMMIT`, `RESET`.

**Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select version, applied_at, applied_by from cma.schema_migration where version = '0008h';
select column_name, data_type, is_nullable from information_schema.columns
where table_schema = 'cma' and table_name = 'commerce_customer' and column_name in ('crm_connection_id', 'crm_contact_source_id', 'matched_at') order by 1;
select indexname from pg_indexes where schemaname = 'cma' and indexname = 'commerce_customer_crm_contact_idx';
select p.oid::regprocedure as function, has_function_privilege('cma_app', p.oid, 'execute') as app, has_function_privilege('public', p.oid, 'execute') as public
from pg_proc p where p.oid in ('cma.set_commerce_customer_contact(uuid,text,uuid,text)'::regprocedure, 'cma.forget_commerce_contact_links(uuid,text)'::regprocedure) order by 1;
select count(*) as customers, count(crm_contact_source_id) as linked from cma.commerce_customer;
select count(*) as writeback_fields from cma.writeback_field;
reset role;
```
Expected: one row `0008h` with today's time and your login; three rows `crm_connection_id | uuid | YES`, `crm_contact_source_id | text | YES`, `matched_at | timestamp with time zone | YES`; `commerce_customer_crm_contact_idx`; both functions with `app` `t` and `public` `f`; the customer count as it was (0 while phase 9 has not started) and `linked` 0; `writeback_fields` 0 (more than 0 means the old phase 9.5 ran: `docs/ingest/PROD_RUNBOOK.md` 9.5 says how to disable them).

## 4. Merge

**Browser:** the pull request → **Squash and merge** (the title as it stands) → Confirm.

**Terminal**
```bash
cd ~/cma && git switch -q main && git pull -q --ff-only && git log -1 --format=%h -- ingest/
```
Expected: the merge's short SHA (the image tag `deploy.sh` will use). No Cloud Build runs: the merge touches neither `web/` nor `cloudbuild.yaml`.

## 5. The ingest in dev

**Terminal** (on the merged `main`; the accessor grants of earlier deploys stay, so no `--secret` is needed)
```bash
bash docs/ingest/deploy.sh dev
bash docs/ingest/deploy.sh dev --jobs
```
Expected: the first builds the image once in `p4a-cma-prod` (`gcloud builds submit …`) and deploys the service (`health: {"ok":true,"version":"<sha>"}`); the second deploys five jobs with `no build`, and for the outbox job `schedule ingest-outbox: paused (nothing to deliver since 0008h)` when B10's deploy had scheduled it, else `schedule ingest-outbox: none (the job runs only when executed)`. This is a schedule change, not an environment variable change.

**Terminal** (the outbox schedule in dev)
```bash
gcloud scheduler jobs describe ingest-outbox --project=p4a-cma-dev --location=europe-west4 --format='value(state)' 2>&1 | tail -1
```
Expected: `PAUSED`, or `NOT_FOUND` in the error line when no deploy ever scheduled it.

## 6. Optional: the dev store end to end

`docs/night-2026-10-10/VENDOR_SETUP.md` §3.3 (the dev store `cma-dev`, the app **CMA ingest dev** with Email and Phone selected, its test customers and orders), then `docs/ingest/PROD_RUNBOOK.md` 9.3 and 9.6 to 9.8 with `p4a-cma-dev`, `cma-dev-pg`, the secret `ingest-shopify-dev-signing`, the dev store's handle and the dev HubSpot connection (`select connection_id, adapter, name from cma.sources();` in Studio lists it). Not walked through: the Dev Dashboard's screens for the dev app.

Expected: the bridge check of 9.8 shows the dev store's customers `test1`, `test2` and `test4` with a contact (the three HubSpot test contacts of `CMA dev`) and `nobody@example.com` without; `outbox_actions` 0; in `CMA dev` the three contacts' Contact-Shopify properties unchanged by the CMA (it writes none); every order with `order_kind` `first` or `repeat` and a `phone_hash`; in Studio no email or phone number in any commerce row.

## 7. Prod

**Terminal** (on the merged `main`; always with `--front`)
```bash
bash docs/ingest/deploy.sh prod --front ingest.pulse4all.app --tenant pulse4all-subscriptions
bash docs/ingest/deploy.sh prod --jobs
```
Expected: the service on the image dev ran (`image … exists (sha256:…); no build`), `health: {"ok":true,…}` through the front, `run.app: 404 (refused)`; five jobs, and for the outbox job `schedule ingest-outbox: paused (nothing to deliver since 0008h)` or `none (the job runs only when executed)`. No environment variable changes in this brief (`INGEST_SHOPIFY_READBACK_BUDGET_MS=1500` came with B10).

Then `docs/ingest/PROD_RUNBOOK.md` phase 9 from 9.1: its gate is open once 0008g and 0008h have run in prod (step 3) and this step has deployed the service and jobs. Steps 9.4 and 9.5 are removed (no Make change, no write-back fields).

**Records** (from this runbook): `records/0008h-dev-<date>/` (step 2) and `records/0008h-prod-<date>/` (step 3), committed through a pull request as before.
