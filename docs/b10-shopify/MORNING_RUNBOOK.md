# Morning runbook, B10: the Shopify adapter, the outbox worker and the phone hash (0008g)

**Ran on 13 October 2026.** Steps 2 and 3: 0008g in dev at 10:25:04 UTC and in prod at 10:25:39 UTC (`cma.schema_migration`), records `records/0008g-dev-2026-10-13` (`57` 12 PASS; provoked all 12 FAIL) and `records/0008g-prod-2026-10-13` (`31`, `33` and `37` reruns PASS). Step 4, the merge, is `Pulse4all-com/cma#114`. The steps below stay as written; README (Environments) holds the status.

Labels: **Browser**, **Terminal** (Cloud Shell, in `~/cma` unless stated), **Studio** (the instance named), **File** (a repository path). SQL and shell never share a block. Every step ends with what you should see. The local outputs are in `local-records/` (its `README.md` lists them).

**Order matters:** 0008g (`56`) runs in dev and prod before the ingest service is deployed from this merge: the adapter sends the phone hash, which the 0007b functions would silently drop. Merging deploys nothing of the ingest service (only `web/**` and `cloudbuild.yaml` trigger a build, and this pull request changes neither); the ingest is deployed by hand with `docs/ingest/deploy.sh`. `56` needs addition 0008f (`54`) in the same database; without it, it stops with `addition 0008f (54_uncounted_lines.sql) must run before 0008g` and applies nothing.

| Step | What | Elapsed |
|---|---|---|
| 1 | Review the pull request, run the ingest checks in Cloud Shell | 20 min |
| 2 | 0008g in dev with its verify | 10 min |
| 3 | 0008g in prod, then a read-only check | 10 min |
| 4 | Merge | 5 min |
| 5 | The ingest service and jobs in dev on the new image | 15 min |
| 6 | Optional: the dev store end to end (VENDOR_SETUP §3.3) | 45 min |
| 7 | The ingest service and jobs in prod; then `docs/ingest/PROD_RUNBOOK.md` phase 9 | per phase 9 |

---

## Helpers (define in every new Cloud Shell)

The helpers `cma_db` and `run_migration` of `docs/night-2026-10-13/MORNING_RUNBOOK.md`, section Helpers, unchanged: paste that block first.

Expected: `type cma_db run_migration` prints both functions.

## 1. Review the pull request and run the ingest checks

**Browser:** GitHub → Pulse4all-com/cma → Pull requests → "B10: Shopify adapter, subscription script, outbox worker and the order phone hash (0008g)". Read the description and the diff.

Expected: no change to `web/`, `cloudbuild.yaml` or `records/`; `db/36_commerce.sql` changes in its header comment only.

**Terminal** (the pull request's number from the page)
```bash
cd ~/cma && gh pr checkout <number> && cd ingest && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run lint && npm test 2>&1 | grep -E "^ALL|FAILED"; cd ~/cma
```
Expected: `found 0 vulnerabilities`, no lint output after the `eslint` line, and twelve lines `ALL n PASS` (18, 37, 26, 41, 20, 49, 27, 17, 53, 21, 21, 20), no `FAILED`. **Do not merge yet.**

## 2. Addition 0008g in dev

**Terminal** (still on the pull request's branch)
```bash
run_migration dev 56_commerce_phone_hash.sql 57_verify_commerce_phone_hash.sql 0008g-dev-$(date +%F) 37_verify_commerce.sql 33_verify_intake_core.sql 31_verify_ingest_crm_records.sql
```
Expected: `connected to cma as martin@pulse4all.com`; the last lines of `56` are `INSERT 0 1`, `COMMIT`, `RESET` (no `ERROR`); `57` ends with the verdict row `PASS | 12 PASS, 0 FAIL`; `provoked FAIL lines: 13` and the verdict `PROVOKED, NOT A PASS | 0 PASS, 12 FAIL`; `37_verify_commerce.sql: 2 PASS rows`, `33_verify_intake_core.sql: 2 PASS rows`, `31_verify_ingest_crm_records.sql: 2 PASS rows`. A `REFUSED` line means the session is not on dev: check `cma_db dev`.

## 3. Addition 0008g in prod

**Terminal** (point-in-time recovery on, as before every prod migration)
```bash
gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format="value(settings.backupConfiguration.pointInTimeRecoveryEnabled,settings.backupConfiguration.transactionLogRetentionDays)"
```
Expected: `True	7`.

`57` refuses prod (it writes throwaway tenants and runs in dev only, like `53` and `55`), so prod runs the migration and the earlier verifies, then a read-only check.

**Terminal**
```bash
rec=records/0008g-prod-$(date +%F); mkdir -p "$rec" && cma_db prod && psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/56_commerce_phone_hash.sql > "$rec/56.txt" 2>&1; tail -3 "$rec/56.txt"
for f in 37_verify_commerce.sql 33_verify_intake_core.sql 31_verify_ingest_crm_records.sql; do psql "$PGCONN" -v ON_ERROR_STOP=1 -f "db/$f" > "$rec/${f%%_*}-rerun.txt" 2>&1; echo "$f: $(grep -cE '\| PASS' "$rec/${f%%_*}-rerun.txt") PASS rows"; done
```
Expected: `connected to cma as martin@pulse4all.com`; `INSERT 0 1`, `COMMIT`, `RESET`; then `37_verify_commerce.sql: 2 PASS rows`, `33_verify_intake_core.sql: 2 PASS rows`, `31_verify_ingest_crm_records.sql: 2 PASS rows`. A rerun of `56` ends `INSERT 0 0`, `COMMIT`, `RESET`.

**Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select version, applied_at, applied_by from cma.schema_migration where version = '0008g';
select table_name, column_name, data_type, is_nullable from information_schema.columns
where table_schema = 'cma' and column_name = 'phone_hash' order by 1;
select indexname from pg_indexes where schemaname = 'cma' and indexname like 'commerce_%phone_hash_idx' order by 1;
select count(*) filter (where phone_hash is not null) as customers_with_hash, count(*) as customers from cma.commerce_customer;
reset role;
```
Expected: one row `0008g` with today's time and your login; two rows `commerce_customer | phone_hash | text | YES` and `commerce_order | phone_hash | text | YES`; `commerce_customer_phone_hash_idx` and `commerce_order_phone_hash_idx`; `0` customers with a hash (prod has no Shopify connection yet), and the customer count as it was (0 today).

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
Expected: the first builds the image once in `p4a-cma-prod` (`gcloud builds submit …`) and deploys the service (`health: {"ok":true,"version":"<sha>"}`); the second deploys five jobs, with `schedule ingest-outbox: * * * * * (Europe/Amsterdam)` among the schedules and `no build`.

**Terminal** (the outbox job in dev: nothing to send yet)
```bash
gcloud run jobs execute ingest-outbox --project=p4a-cma-dev --region=europe-west4 --wait && gcloud logging read 'resource.type=cloud_run_job AND resource.labels.job_name=ingest-outbox AND jsonPayload.message="outbox"' --project=p4a-cma-dev --limit=1 --format='value(jsonPayload.claimed,jsonPayload.sent,jsonPayload.failed)'
```
Expected: `has successfully completed`, then `0	0	0` (no write-back is pending in dev).

## 6. Optional: the dev store end to end

`docs/night-2026-10-10/VENDOR_SETUP.md` §3.3 (the dev store `cma-dev`, the app **CMA ingest dev** with Email and Phone selected, its test customers and orders), then `docs/ingest/PROD_RUNBOOK.md` 9.3 and 9.5 to 9.8 with `p4a-cma-dev`, `cma-dev-pg`, the secret `ingest-shopify-dev-signing`, the dev store's handle and the dev HubSpot connection (`select connection_id, adapter, name from cma.sources();` in Studio lists it); step 9.4 (Make) does not apply in dev. Not walked through: the Dev Dashboard's screens for the dev app.

Expected: the dev store's customers `test1`, `test2` and `test4` matched to the three HubSpot test contacts of `CMA dev` and their Contact-Shopify fields filled within two minutes; `nobody@example.com` unmatched (data quality); every order with `order_kind` `first` or `repeat` and a `phone_hash`; in Studio no email or phone number in any commerce row.

## 7. Prod

**Terminal** (on the merged `main`; always with `--front`)
```bash
bash docs/ingest/deploy.sh prod --front ingest.pulse4all.app --tenant pulse4all-subscriptions
bash docs/ingest/deploy.sh prod --jobs
```
Expected: the service on the image dev ran (`image … exists (sha256:…); no build`), `health: {"ok":true,…}` through the front, `run.app: 404 (refused)`; five jobs with the `ingest-outbox` schedule. The service now carries `INGEST_SHOPIFY_READBACK_BUDGET_MS=1500` (a new environment variable, set by `deploy.sh`).

Then `docs/ingest/PROD_RUNBOOK.md` phase 9 from 9.1: its gate is open once 0008g has run in prod (step 3) and this step has deployed the service and jobs.

**Records** (from this runbook): `records/0008g-dev-<date>/` (step 2) and `records/0008g-prod-<date>/` (step 3), committed through a pull request as before.
