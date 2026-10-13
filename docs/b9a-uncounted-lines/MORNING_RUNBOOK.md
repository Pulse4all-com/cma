# Morning runbook, B9a: a telephony connection stores calls on its counted lines only (0008f)

Labels: **Browser**, **Terminal** (Cloud Shell, in `~/cma` unless stated), **Studio** (the instance named), **File** (a repository path). SQL and shell never share a block. Every step ends with what you should see. The local outputs are in `local-records/` (its `README.md` lists them).

**Order matters:** run `54` in dev, verify with `55`, run `54` in prod, then merge. The merged Sources page tells people that switching a line off removes its calls; that is true only once `54` has run in prod. `54` needs addition 0008e (`52`) in the same database; without it, it stops with `addition 0008e (52_sources_configuration.sql) must run before 0008f` and applies nothing.

| Step | What | Elapsed |
|---|---|---|
| 1 | Review the pull request, build it in Cloud Shell | 20 min |
| 2 | 0008f in dev with its verify | 10 min |
| 3 | 0008f in prod: count first, run, read-only check | 10 min |
| 4 | Merge, watch the prod build | 10 min |
| 5 | Browser check of the Lines section in prod (Cancel only) | 5 min |
| 6 | Optional: the ingest jobs on the new image (sync-run counts) | 10 min |

---

## Helpers (define in every new Cloud Shell)

The helpers `cma_db` and `run_migration` of `docs/night-2026-10-13/MORNING_RUNBOOK.md`, section Helpers, unchanged: paste that block first.

Expected: `type cma_db run_migration` prints both functions.

## 1. Review the pull request and build it

**Browser:** GitHub → Pulse4all-com/cma → Pull requests → "B9a: a telephony connection stores calls on its counted lines only (0008f)". Read the description and the diff; the screenshots are in `docs/b9a-uncounted-lines/local-records/web/screenshots/`.

Expected: one pull request from `b9a-uncounted-lines`; no change to `cloudbuild.yaml` or `records/`.

**Terminal** (the pull request's number from the page)
```bash
cd ~/cma && gh pr checkout <number> && cd web && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run build 2>&1 | tail -3; echo "build exit: ${PIPESTATUS[0]}"; cd ~/cma
```
Expected: the end of the route list, then `build exit: 0`. **Do not merge yet.**

## 2. Addition 0008f in dev

**Terminal** (still on the pull request's branch)
```bash
run_migration dev 54_uncounted_lines.sql 55_verify_uncounted_lines.sql 0008f-dev-$(date +%F) 35_verify_telephony.sql 33_verify_intake_core.sql 31_verify_ingest_crm_records.sql
```
Expected: `connected to cma as martin@pulse4all.com`; the last lines of `54` are an empty line, `COMMIT`, `RESET` (no `ERROR`); `55` ends with the verdict row `PASS | 17 PASS, 0 FAIL`; `provoked FAIL lines: 18` and the verdict `PROVOKED, NOT A PASS | 0 PASS, 17 FAIL`; `35_verify_telephony.sql: 2 PASS rows`, `33_verify_intake_core.sql: 2 PASS rows`, `31_verify_ingest_crm_records.sql: 2 PASS rows`. A `REFUSED` line means the session is not on dev: check `cma_db dev`.

**Terminal** (what the one-off of `54` removed in dev)
```bash
sed -n '/lines_not_counted/,/^(/p' records/0008f-dev-$(date +%F)/54.txt
```
Expected: one row per dev connection that has lines (tenant, connection, its id, lines not counted, calls, taggings and links removed), or `(0 rows)` when dev has no telephony lines. On dev's replay connection the counts are what its lines marked off held; zeros are fine.

## 3. Addition 0008f in prod

**Terminal** (point-in-time recovery on, as before every prod migration)
```bash
gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format="value(settings.backupConfiguration.pointInTimeRecoveryEnabled,settings.backupConfiguration.transactionLogRetentionDays)"
```
Expected: `True	7`.

**Studio (cma-prod-pg)** (read only: what `54` will remove)
```sql
set role cma_owner;
select t.slug, c.name as connection, n.number_ref, n.name as line,
       (select count(*) from cma.telephony_call x where x.tenant_id = n.tenant_id and x.connection_id = n.connection_id and x.number_ref = n.number_ref) as stored_calls
from cma.telephony_number n
join cma.integration_connection c on c.tenant_id = n.tenant_id and c.id = n.connection_id
join cma.tenant t on t.id = n.tenant_id
where not n.is_counted
order by 1, 2, 4;
reset role;
```
Expected: the five Invest lines marked not counted on 13 October (plus any internal or test line you switched off) on the Subscriptions Aircall connection, each with its stored calls. Note the total of `stored_calls`.

`55` refuses prod (it writes throwaway tenants and runs in dev only, like `53`), so prod runs the migration and the earlier verifies, then a read-only check.

**Terminal**
```bash
rec=records/0008f-prod-$(date +%F); mkdir -p "$rec" && cma_db prod && psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/54_uncounted_lines.sql > "$rec/54.txt" 2>&1; tail -3 "$rec/54.txt"; sed -n '/lines_not_counted/,/^(/p' "$rec/54.txt"
for f in 35_verify_telephony.sql 33_verify_intake_core.sql 31_verify_ingest_crm_records.sql; do psql "$PGCONN" -v ON_ERROR_STOP=1 -f "db/$f" > "$rec/${f%%_*}-rerun.txt" 2>&1; echo "$f: $(grep -cE '\| PASS' "$rec/${f%%_*}-rerun.txt") PASS rows"; done
```
Expected: `connected to cma as martin@pulse4all.com`; an empty line, `COMMIT`, `RESET`; then the one-off's result: one row for the Subscriptions Aircall connection, `pulse4all-subscriptions | <its name> | <its id> | 5 | <calls removed> | <taggings removed> | <links removed>` (5 or the number of lines the count above listed), where `calls removed` is the Invest-line calls: the total you noted, or a little more if calls arrived in between. Then `35_verify_telephony.sql: 2 PASS rows`, `33_verify_intake_core.sql: 2 PASS rows`, `31_verify_ingest_crm_records.sql: 2 PASS rows`. A rerun answers the same row with zeros.

**Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select version, applied_at, applied_by from cma.schema_migration where version = '0008f';
select tgname, tgenabled, tgfoid::regprocedure as fn from pg_trigger where tgrelid = 'cma.telephony_number'::regclass and tgname = 'remove_uncounted_calls';
select count(*) as calls_on_lines_not_counted
from cma.telephony_call t
join cma.telephony_number n on n.tenant_id = t.tenant_id and n.connection_id = t.connection_id and n.number_ref = t.number_ref
where not n.is_counted;
select table_name, count(*) as deletes, count(*) filter (where old_row ->> 'reason' = 'uncounted_line') as ids_only
from cma.audit_log where action = 'delete' and table_name in ('telephony_call', 'telephony_call_tag', 'call_link')
group by table_name order by 1;
reset role;
```
Expected: one row `0008f` with today's time and your login; `remove_uncounted_calls | O | cma.remove_calls_of_uncounted_line()`; `calls_on_lines_not_counted` 0; per table the deletes of step 3 with `deletes` equal to `ids_only` (`telephony_call` equal to the calls removed; no `call_link` row when none was linked).

## 4. Merge and watch the prod build

**Browser:** the pull request → **Squash and merge** (the title as it stands) → Confirm.

**Terminal** (`docs/RUNBOOK.md` section 3)
```bash
cd ~/cma && git switch -q main && git pull -q --ff-only && sha=$(git rev-parse --short HEAD) && echo $sha
gcloud builds list --project=p4a-cma-prod --region=europe-west4 --limit=1 --format="value(substitutions.SHORT_SHA,status)"
```
Expected: the merge's short SHA, then the same SHA with `WORKING`, later `SUCCESS` (rerun the second line every two minutes).

## 5. The Lines section in prod

**Browser:** `https://workspace.pulse4all.app/configuration/sources` → the Subscriptions Aircall connection → **Lines** → the info mark next to **Counted**.

Expected: the hint ends with `Calls on a line that does not count are not stored, and switching a line off removes its stored calls.` The five Invest lines show Counted off.

**Browser:** click the Counted box of a line that counts.

Expected: a dialog `Stop counting this line` with the line's name and the same sentence. Click **Cancel**: the line still counts and nothing changed. Do not confirm on a line that should count: confirming removes its stored calls, and switching it back on does not bring the earlier ones back with a backfill (README, Open decisions).

## 6. Optional: the ingest jobs on the new image

The pull request changes `ingest/src/core/sync.mjs`: reconcile and backfill runs count a call on a line that does not count as skipped instead of upserted. Nothing depends on it, and only the jobs run that file. At the next ingest deploy, or now:

**Terminal** (on the merged `main`)
```bash
cd ~/cma && bash docs/ingest/deploy.sh prod --jobs
```
Expected: as `docs/ingest/PROD_RUNBOOK.md` 7.2: the image tagged with this merge's SHA built once (`gcloud builds submit …`, then the jobs on it; on a second run `image … exists (sha256:…); no build`), four `gcloud run jobs deploy` results and the three schedules unchanged. Dev the same way with `dev` first if you want dev's jobs on it too.
